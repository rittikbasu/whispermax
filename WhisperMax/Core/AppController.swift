import AppKit
import CoreAudio
import Foundation
import Observation

private enum WaveformHistory {
    static let sampleCount = 84
    static let activeFloor: CGFloat = 0.0012
    static let idleFloor: CGFloat = 0.0008
}

enum InsertionMethod: String, Codable, Equatable {
    case accessibility = "Direct Insert"
    case clipboard = "Clipboard Fallback"
}

enum RecordingPhase: Equatable {
    case loadingModel
    case ready
    case recording
    case transcribing
    case inserted(InsertionMethod)
    case error(String)
}

enum OnboardingStep: Int, CaseIterable {
    case download
    case permissions
    case ready
}

enum SidebarSelection: String, CaseIterable {
    case home
    case history
    case settings
}

struct TranscriptEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date
    let duration: TimeInterval
    let insertionMethod: InsertionMethod
    let modelName: String
}

@MainActor
@Observable
final class AppController {
    private let historyStore = HistoryStore()
    private let inputDeviceService = AudioInputDeviceService()
    private let inputPreferenceStore = AudioInputPreferenceStore()
    let permissionsManager = PermissionsManager()
    private let insertionService = TextInsertionService()
    private let recorder = AudioRecorderService()

    private var whisperEngine: WhisperEngine?
    private var preRecordingSystemDefaultInputDeviceID: AudioObjectID?
    private var recordingPinnedDeviceID: AudioObjectID?
    private var permissionRefreshTask: Task<Void, Never>?
    private var menuFeedbackResetTask: Task<Void, Never>?
    private var hasPromptedAccessibilityThisLaunch = false
    private var pendingInsertionTarget: InsertionTargetContext?

    var phase: RecordingPhase = .loadingModel {
        didSet {
            phaseDidChange?(phase)
        }
    }

    var phaseDidChange: ((RecordingPhase) -> Void)?
    var onOnboardingComplete: (() -> Void)?

    // MARK: - Onboarding

    var hasCompletedOnboarding: Bool = false
    var onboardingStep: OnboardingStep = .download
    var downloadProgress: Double = 0
    var isDownloading: Bool = false

    private var downloadSimulationTask: Task<Void, Never>?

    var isDownloadComplete: Bool { downloadProgress >= 1.0 }

    func startSimulatedDownload() {
        guard !isDownloading, !isDownloadComplete else { return }
        isDownloading = true
        downloadProgress = 0

        downloadSimulationTask = Task { [weak self] in
            let totalSteps = 60
            for step in 1...totalSteps {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .milliseconds(50))

                await MainActor.run {
                    guard let self else { return }
                    let base = Double(step) / Double(totalSteps)
                    let wobble = Double.random(in: -0.008...0.008)
                    self.downloadProgress = min(base + wobble, 1.0)
                }
            }

            await MainActor.run {
                guard let self else { return }
                self.downloadProgress = 1.0
                self.isDownloading = false
            }
        }
    }

    func advanceOnboarding() {
        guard let nextIndex = OnboardingStep(rawValue: onboardingStep.rawValue + 1) else {
            completeOnboarding()
            return
        }
        onboardingStep = nextIndex
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        FileManager.default.createFile(
            atPath: ModelLocator.onboardingCompleteFileURL.path,
            contents: nil
        )

        onOnboardingComplete?()

        Task {
            await preloadModel()
        }
    }

    func loadOnboardingState() {
        hasCompletedOnboarding = FileManager.default.fileExists(
            atPath: ModelLocator.onboardingCompleteFileURL.path
        )
    }

    // MARK: - Main State

    var sidebarSelection: SidebarSelection = .home
    var waveformLevels: [CGFloat] = Array(
        repeating: WaveformHistory.idleFloor,
        count: WaveformHistory.sampleCount
    )
    var recordingDuration: TimeInterval = 0
    var lastTranscript: String = ""
    var searchText: String = ""
    var history: [TranscriptEntry] = []
    var inputDevices: [AudioInputDevice] = []
    var statusText: String = "Loading local model..."
    var modelDisplayName: String = "Whisper Large V3 Turbo"
    var modelPath: String = ""
    var hotkeyDisplay: String = "⌥ Space"
    var hotkeyInstructionText: String = "Option + Space"
    var accessibilityGranted = false
    var microphoneGranted = false
    var defaultInputDeviceID: AudioObjectID = kAudioObjectUnknown
    var inputPreference: AudioInputPreference = .systemDefault
    var menuFeedbackMessage: String?

    init() {
        configureRecorderCallbacks()
        configureInputDeviceObservation()
    }

    var filteredHistory: [TranscriptEntry] {
        let trimmedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return history
        }

        return history.filter { entry in
            entry.text.localizedCaseInsensitiveContains(trimmedQuery)
                || entry.modelName.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    var formattedDuration: String {
        let total = Int(recordingDuration.rounded(.down))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var needsSetup: Bool {
        !microphoneGranted || !accessibilityGranted
    }

    var defaultInputDeviceName: String {
        inputDevices.first(where: { $0.audioObjectID == defaultInputDeviceID })?.name ?? "No Input Device"
    }

    var canCopyLastTranscript: Bool {
        transcriptToCopy != nil
    }

    var prefersSystemDefaultInput: Bool {
        if case .systemDefault = inputPreference {
            return true
        }
        return false
    }

    var preferredPinnedInput: PinnedAudioInputPreference? {
        if case .pinned(let pinnedPreference) = inputPreference {
            return pinnedPreference
        }
        return nil
    }

    var unavailablePinnedInput: PinnedAudioInputPreference? {
        guard let preferredPinnedInput else {
            return nil
        }

        let isAvailable = inputDevices.contains { $0.audioObjectID == preferredPinnedInput.resolvedAudioObjectID }
        return isAvailable ? nil : preferredPinnedInput
    }

    var activeInputDisplayName: String {
        defaultInputDeviceName
    }

    var preferredInputDisplayName: String {
        switch inputPreference {
        case .systemDefault:
            return "System Default"
        case .pinned(let pinnedPreference):
            return "Pinned — \(pinnedPreference.name)"
        }
    }

    var inputMenuLabel: String {
        switch inputPreference {
        case .systemDefault:
            return "System Default"
        case .pinned(let pinnedPreference):
            return unavailablePinnedInput == nil
                ? pinnedPreference.name
                : "\(pinnedPreference.name) Unavailable"
        }
    }

    var menuPrimaryActionTitle: String {
        switch phase {
        case .loadingModel:
            return "Loading Model…"
        case .ready, .inserted, .error:
            return "Start Recording"
        case .recording:
            return "Stop Recording"
        case .transcribing:
            return "Transcribing…"
        }
    }

    var isMenuPrimaryActionEnabled: Bool {
        switch phase {
        case .loadingModel, .transcribing:
            return false
        default:
            return true
        }
    }

    private var readySubtitle: String {
        let hour = Calendar.current.component(.hour, from: Date())
        switch hour {
        case 5..<12: return "Morning. What's on your mind?"
        case 12..<17: return "Afternoon. Keep talking."
        case 17..<21: return "Evening. Last thoughts?"
        default: return "Late night. We're listening."
        }
    }

    var homeSubtitle: String {
        if !microphoneGranted {
            return "Grant microphone access to start dictation"
        }

        if !accessibilityGranted {
            return "Allow Accessibility to insert text automatically"
        }

        switch phase {
        case .loadingModel:
            return "Loading local model…"
        case .ready:
            return readySubtitle
        case .recording:
            return "Listening…"
        case .transcribing:
            return "Transcribing locally…"
        case .inserted:
            return "Inserted into your app"
        case .error(let message):
            return message
        }
    }

    func launch() {
        do {
            try ModelLocator.prepareDirectories()
        } catch {
            setError("Could not prepare whispermax storage.")
            return
        }

        loadOnboardingState()
        inputPreference = inputPreferenceStore.load()
        history = historyStore.load().sorted { $0.createdAt > $1.createdAt }
        refreshInputDevices()
        refreshPermissions()
        statusText = idleStatusText

        guard hasCompletedOnboarding else { return }

        Task {
            await requestInitialPermissionsIfNeeded()
            await preloadModel()
        }
    }

    func refreshPermissions() {
        permissionRefreshTask?.cancel()
        accessibilityGranted = permissionsManager.isAccessibilityGranted
        microphoneGranted = permissionsManager.isMicrophoneGranted

        guard phase != .recording, phase != .transcribing else {
            return
        }

        statusText = idleStatusText

        if !accessibilityGranted {
            permissionRefreshTask = Task { @MainActor [weak self] in
                await self?.pollAccessibilityPermission()
            }
        }
    }

    func promptForAccessibility() {
        hasPromptedAccessibilityThisLaunch = true
        permissionsManager.promptForAccessibility()
        refreshPermissions()
    }

    func refreshInputDevices() {
        do {
            let snapshot = try inputDeviceService.snapshot()
            inputDevices = snapshot.devices
            defaultInputDeviceID = snapshot.defaultDeviceID
        } catch {
            inputDevices = []
            defaultInputDeviceID = kAudioObjectUnknown
        }
    }

    func useSystemDefaultInput() {
        guard !prefersSystemDefaultInput else {
            return
        }

        inputPreference = .systemDefault
        inputPreferenceStore.save(inputPreference)
        setMenuFeedback("Using System Default")
    }

    func pinInputDevice(_ device: AudioInputDevice) {
        let pinnedPreference = PinnedAudioInputPreference(audioObjectID: device.audioObjectID, name: device.name)

        guard inputPreference != .pinned(pinnedPreference) else {
            return
        }

        inputPreference = .pinned(pinnedPreference)
        inputPreferenceStore.save(inputPreference)
        setMenuFeedback("Pinned \(device.name)")
    }

    func isPreferredInput(_ device: AudioInputDevice) -> Bool {
        guard let preferredPinnedInput else {
            return false
        }

        return device.audioObjectID == preferredPinnedInput.resolvedAudioObjectID
    }

    func openAccessibilitySettings() {
        permissionsManager.openAccessibilitySettings()
        refreshPermissions()
    }

    func openMicrophoneSettings() {
        permissionsManager.openMicrophoneSettings()
    }

    func toggleRecording() async {
        switch phase {
        case .recording:
            stopRecording()
        case .transcribing:
            return
        default:
            await startRecording()
        }
    }

    func startRecording() async {
        guard case .loadingModel = phase else {
            breakIfModelUnavailable()

            microphoneGranted = await permissionsManager.requestMicrophoneAccess()
            guard microphoneGranted else {
                setError("Microphone access is required for local dictation.")
                return
            }

            if !accessibilityGranted {
                promptForAccessibility()
            }

            do {
                prepareInputDeviceForRecording()
                recordingDuration = 0
                lastTranscript = ""
                pendingInsertionTarget = insertionService.captureTargetContext()
                resetWaveform(active: true)
                try recorder.start()
                statusText = "Listening…"
                phase = .recording
            } catch {
                setError("Failed to start recording.")
            }

            return
        }

        statusText = "Still loading the local model…"
    }

    func stopRecording() {
        guard phase == .recording else {
            return
        }

        statusText = "Transcribing locally…"
        phase = .transcribing
        recorder.stop()
    }

    func cancelRecording() {
        guard phase == .recording else {
            return
        }

        recorder.cancel()
        restoreSystemInputAfterRecordingIfNeeded()
        pendingInsertionTarget = nil
        recordingDuration = 0
        resetWaveform(active: false)
        phase = whisperEngine == nil ? .loadingModel : .ready
        statusText = idleStatusText
    }

    func clearHistory() {
        history.removeAll()
        historyStore.save(history)
    }

    func deleteEntry(_ entry: TranscriptEntry) {
        history.removeAll { $0.id == entry.id }
        historyStore.save(history)
    }

    func copy(_ entry: TranscriptEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    func copyLastTranscript() {
        guard let transcriptToCopy else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcriptToCopy, forType: .string)
        setMenuFeedback("Copied last transcript")
    }

    func reinsert(_ entry: TranscriptEntry) {
        do {
            _ = try insertionService.insert(entry.text)
        } catch {
            setError("Failed to reinsert transcript.")
        }
    }

    private func configureRecorderCallbacks() {
        recorder.onMeter = { [weak self] level, duration in
            guard let self else { return }
            self.recordingDuration = duration
            self.pushWaveform(level: CGFloat(level))
        }

        recorder.onFinish = { [weak self] url in
            Task { @MainActor [weak self] in
                await self?.transcribeAndInsert(from: url)
            }
        }

        recorder.onError = { [weak self] message in
            self?.setError(message)
        }
    }

    private func configureInputDeviceObservation() {
        inputDeviceService.startObserving { [weak self] in
            Task { @MainActor [weak self] in
                self?.refreshInputDevices()
            }
        }
    }

    private func prepareInputDeviceForRecording() {
        refreshInputDevices()
        preRecordingSystemDefaultInputDeviceID = nil
        recordingPinnedDeviceID = nil

        guard let preferredPinnedInput else {
            return
        }

        let pinnedDeviceID = preferredPinnedInput.resolvedAudioObjectID
        guard inputDevices.contains(where: { $0.audioObjectID == pinnedDeviceID }) else {
            setMenuFeedback("\(preferredPinnedInput.name) unavailable. Using System Default")
            return
        }

        recordingPinnedDeviceID = pinnedDeviceID

        guard defaultInputDeviceID != pinnedDeviceID else {
            return
        }

        let originalDefaultInputDeviceID = defaultInputDeviceID

        do {
            try inputDeviceService.setDefaultInputDevice(pinnedDeviceID)
            preRecordingSystemDefaultInputDeviceID = originalDefaultInputDeviceID
            refreshInputDevices()
        } catch {
            recordingPinnedDeviceID = nil
            setMenuFeedback("Couldn’t switch to \(preferredPinnedInput.name). Using System Default")
        }
    }

    private func restoreSystemInputAfterRecordingIfNeeded() {
        guard let preRecordingSystemDefaultInputDeviceID else {
            recordingPinnedDeviceID = nil
            return
        }

        defer {
            self.preRecordingSystemDefaultInputDeviceID = nil
            self.recordingPinnedDeviceID = nil
        }

        refreshInputDevices()

        guard let recordingPinnedDeviceID else {
            return
        }

        guard defaultInputDeviceID == recordingPinnedDeviceID else {
            return
        }

        guard inputDevices.contains(where: { $0.audioObjectID == preRecordingSystemDefaultInputDeviceID }) else {
            return
        }

        do {
            try inputDeviceService.setDefaultInputDevice(preRecordingSystemDefaultInputDeviceID)
            refreshInputDevices()
        } catch {
            // If restoration fails, preserve recording behavior rather than surfacing a blocking error.
        }
    }

    private func preloadModel() async {
        guard let modelURL = ModelLocator.preferredModelURL() else {
            setError("No local Whisper model was found. Place ggml-large-v3-turbo.bin in Application Support/WhisperMax/Models or keep Superwhisper installed.")
            return
        }

        modelPath = modelURL.path
        whisperEngine = WhisperEngine(modelURL: modelURL)

        do {
            try await whisperEngine?.prepare()
            phase = .ready
            statusText = idleStatusText
        } catch {
            setError("Failed to load the local Whisper model.")
        }
    }

    private func requestInitialPermissionsIfNeeded() async {
        if permissionsManager.microphoneAuthorizationStatus == .notDetermined {
            microphoneGranted = await permissionsManager.requestMicrophoneAccess()
        } else {
            microphoneGranted = permissionsManager.isMicrophoneGranted
        }

        refreshPermissions()

        if !accessibilityGranted && !hasPromptedAccessibilityThisLaunch {
            hasPromptedAccessibilityThisLaunch = true
            try? await Task.sleep(for: .milliseconds(450))
            permissionsManager.promptForAccessibility()
            refreshPermissions()
        }
    }

    private func transcribeAndInsert(from url: URL) async {
        defer {
            try? FileManager.default.removeItem(at: url)
            restoreSystemInputAfterRecordingIfNeeded()
            pendingInsertionTarget = nil
        }

        guard let whisperEngine else {
            setError("The local Whisper engine is not ready.")
            return
        }

        do {
            let rawText = try await whisperEngine.transcribe(audioURL: url)
            let cleaned = TranscriptFormatter.normalize(rawText)

            guard !cleaned.isEmpty else {
                setError("No speech was detected.")
                return
            }

            let insertionMethod = try insertionService.insert(cleaned, target: pendingInsertionTarget)
            lastTranscript = cleaned

            let entry = TranscriptEntry(
                id: UUID(),
                text: cleaned,
                createdAt: Date(),
                duration: recordingDuration,
                insertionMethod: insertionMethod,
                modelName: modelDisplayName
            )

            history.insert(entry, at: 0)
            historyStore.save(history)

            statusText = insertionMethod == .accessibility
                ? "Inserted directly."
                : "Pasted and restored clipboard."
            phase = .inserted(insertionMethod)
            transitionToReady(after: 0.9)
        } catch {
            setError(error.localizedDescription)
        }
    }

    private func breakIfModelUnavailable() {
        if whisperEngine == nil {
            statusText = "The model is still loading."
        }
    }

    private func pushWaveform(level: CGFloat) {
        let clampedLevel = max(0, min(level, 1.0))
        let previous = waveformLevels.last ?? WaveformHistory.activeFloor
        let gatedLevel = clampedLevel < 0.015 ? 0 : clampedLevel
        let responsiveness: CGFloat = gatedLevel > previous ? 0.34 : 0.20
        let smoothedLevel = previous + (gatedLevel - previous) * responsiveness
        waveformLevels.append(smoothedLevel)
        if waveformLevels.count > WaveformHistory.sampleCount {
            waveformLevels.removeFirst(waveformLevels.count - WaveformHistory.sampleCount)
        }
    }

    private func resetWaveform(active: Bool) {
        waveformLevels = Array(
            repeating: active ? WaveformHistory.activeFloor : WaveformHistory.idleFloor,
            count: WaveformHistory.sampleCount
        )
    }

    private func setError(_ message: String) {
        statusText = message
        phase = .error(message)
        transitionToReady(after: 1.8)
    }

    private func transitionToReady(after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.phase != .recording, self.phase != .transcribing else { return }
            self.phase = self.whisperEngine == nil ? .loadingModel : .ready
            self.statusText = self.idleStatusText
            self.recordingDuration = 0
            self.resetWaveform(active: false)
        }
    }

    private var idleStatusText: String {
        if !microphoneGranted {
            return "Grant microphone access to start dictation."
        }

        if !accessibilityGranted {
            return "Allow Accessibility for automatic insertion."
        }

        return whisperEngine == nil ? "Loading local model..." : "Ready when you are"
    }

    private func pollAccessibilityPermission() async {
        let delays: [Duration] = [
            .milliseconds(250),
            .milliseconds(800),
            .milliseconds(1600),
            .milliseconds(3000),
            .milliseconds(4500),
        ]

        for delay in delays {
            try? await Task.sleep(for: delay)

            guard !Task.isCancelled else {
                return
            }

            let isGranted = permissionsManager.isAccessibilityGranted
            if isGranted {
                accessibilityGranted = true
                statusText = idleStatusText
                return
            }
        }
    }

    private func setMenuFeedback(_ message: String) {
        menuFeedbackResetTask?.cancel()
        menuFeedbackMessage = message
        NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .default)

        menuFeedbackResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.2))
            guard !Task.isCancelled else {
                return
            }

            await MainActor.run {
                guard let self else { return }
                self.menuFeedbackMessage = nil
            }
        }
    }

    private var transcriptToCopy: String? {
        let trimmedLastTranscript = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLastTranscript.isEmpty {
            return trimmedLastTranscript
        }

        return history.first?.text
    }
}
