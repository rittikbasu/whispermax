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
    case copied = "Copied to Clipboard"
}

enum RecordingPhase: Equatable {
    case loadingModel
    case ready
    case recording
    case transcribing
    case inserted(InsertionMethod)
    case error(RecorderIssue)
}

enum RecorderIssue: Equatable {
    case microphonePermissionRequired
    case generic(String)

    var statusMessage: String {
        switch self {
        case .microphonePermissionRequired:
            return "Microphone access is required for local dictation."
        case .generic(let message):
            return message
        }
    }

    var title: String {
        switch self {
        case .microphonePermissionRequired:
            return "Microphone access needed"
        case .generic:
            return "Try again"
        }
    }

    var subtitle: String? {
        switch self {
        case .microphonePermissionRequired:
            return nil
        case .generic:
            return "Recorder reset"
        }
    }

    var autoDismissDelay: TimeInterval {
        switch self {
        case .microphonePermissionRequired:
            return 4.2
        case .generic:
            return 1.8
        }
    }
}

enum OnboardingStep: Int, CaseIterable {
    case download
    case permissions
    case ready
}

enum OnboardingMode: Equatable {
    case full
    case modelRepair
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

struct PendingTranscriptDeletion: Equatable {
    let token = UUID()
    let entries: [TranscriptEntry]

    var count: Int {
        entries.count
    }

    var title: String {
        count == 1 ? "Transcript deleted" : "\(count) transcripts deleted"
    }
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
    private var permissionMonitorTask: Task<Void, Never>?
    private var accessibilityNotificationObserver: NSObjectProtocol?
    private var menuFeedbackResetTask: Task<Void, Never>?
    private var pendingDeleteResetTask: Task<Void, Never>?
    private var pendingInsertionTarget: InsertionTargetContext?

    var phase: RecordingPhase = .loadingModel {
        didSet {
            phaseDidChange?(phase)
        }
    }

    var phaseDidChange: ((RecordingPhase) -> Void)?
    var onOnboardingComplete: (() -> Void)?

    // MARK: - Onboarding

    enum ModelSource {
        case ownPath        // already at WhisperMax's canonical path
        case superwhisper   // found in SuperWhisper, hardlinked across
        case downloaded     // freshly downloaded from HuggingFace
    }

    private enum ModelSetupState: Equatable {
        case idle
        case downloading(Double)
        case ready(ModelSource)
        case failed(String)
    }

    var hasCompletedOnboarding: Bool = false
    var onboardingMode: OnboardingMode = .full
    var onboardingStep: OnboardingStep = .download
    private var modelSetupState: ModelSetupState = .idle

    private var modelDownloader: ModelDownloader?

    var onboardingSteps: [OnboardingStep] {
        onboardingMode == .modelRepair ? [.download] : OnboardingStep.allCases
    }

    var downloadProgress: Double {
        switch modelSetupState {
        case .downloading(let progress):
            return progress
        case .ready:
            return 1.0
        case .idle, .failed:
            return 0
        }
    }

    var isDownloading: Bool {
        if case .downloading = modelSetupState {
            return true
        }
        return false
    }

    var downloadError: String? {
        if case .failed(let message) = modelSetupState {
            return message
        }
        return nil
    }

    var modelSource: ModelSource? {
        if case .ready(let source) = modelSetupState {
            return source
        }
        return nil
    }

    var isDownloadComplete: Bool {
        if case .ready = modelSetupState {
            return true
        }
        return false
    }

    func startModelSetup() {
        if case .downloading = modelSetupState {
            return
        }

        if case .ready = modelSetupState, hasUsableModelAvailable {
            return
        }

        // Already at our own path
        if FileManager.default.fileExists(atPath: ModelLocator.appLocalModelURL.path) {
            markModelSetupReady(.ownPath)
            return
        }

        // Found in SuperWhisper — hardlink to our path (instant, zero extra disk space)
        if FileManager.default.fileExists(atPath: ModelLocator.superwhisperModelURL.path) {
            do {
                try FileManager.default.createDirectory(
                    at: ModelLocator.modelsDirectory, withIntermediateDirectories: true)
                try FileManager.default.linkItem(
                    at: ModelLocator.superwhisperModelURL, to: ModelLocator.appLocalModelURL)
                markModelSetupReady(.superwhisper)
            } catch {
                // Different volume — hardlink not possible, fall through to download
            }
            if isDownloadComplete { return }
        }

        // No model found anywhere — download from HuggingFace
        beginModelDownload()

        let downloader = ModelDownloader()
        modelDownloader = downloader

        downloader.onProgress = { [weak self] progress in
            self?.modelSetupState = .downloading(progress)
        }
        downloader.onComplete = { [weak self] in
            self?.modelDownloader = nil
            self?.markModelSetupReady(.downloaded)
        }
        downloader.onError = { [weak self] message in
            self?.modelDownloader = nil
            self?.modelSetupState = .failed(message)
        }

        downloader.start()
    }

    func retryDownload() {
        modelDownloader?.cancel()
        modelDownloader = nil
        modelSetupState = .idle
        startModelSetup()
    }

    func pauseModelDownload() {
        modelDownloader?.pause()
    }

    func advanceOnboarding() {
        if onboardingMode == .modelRepair, onboardingStep == .download, isDownloadComplete {
            completeOnboarding()
            return
        }

        guard let nextIndex = OnboardingStep(rawValue: onboardingStep.rawValue + 1) else {
            completeOnboarding()
            return
        }
        onboardingStep = nextIndex
    }

    func completeOnboarding() {
        guard hasUsableModelAvailable else {
            enterModelRepairMode()
            startModelSetup()
            return
        }

        hasCompletedOnboarding = true
        onboardingMode = .full
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
        let hasSentinel = FileManager.default.fileExists(
            atPath: ModelLocator.onboardingCompleteFileURL.path
        )
        let hasUsableModel = hasUsableModelAvailable

        hasCompletedOnboarding = hasSentinel && hasUsableModel
        onboardingMode = hasSentinel && !hasUsableModel ? .modelRepair : .full
        onboardingStep = .download

        if !hasCompletedOnboarding {
            modelSetupState = .idle
        }
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
    var pendingTranscriptDeletion: PendingTranscriptDeletion?

    init() {
        configureRecorderCallbacks()
        configureInputDeviceObservation()
        configurePermissionObservation()
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
        case .inserted(let method):
            switch method {
            case .accessibility:
                return "Inserted into your app"
            case .clipboard:
                return "Pasted into your app"
            case .copied:
                return "Copied to clipboard"
            }
        case .error(let issue):
            return issue.statusMessage
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
        startPermissionMonitoring()
        statusText = idleStatusText

        guard hasCompletedOnboarding else { return }

        Task {
            await requestInitialPermissionsIfNeeded()
            await preloadModel()
        }
    }

    func refreshPermissions() {
        syncPermissionState()
    }

    func promptForAccessibility() {
        permissionsManager.promptForAccessibility()
        refreshPermissions()
    }

    func beginAccessibilityPermissionFlow() {
        promptForAccessibility()
        openAccessibilitySettings()
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
                setRecorderIssue(.microphonePermissionRequired)
                return
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

        if let pendingTranscriptDeletion {
            self.pendingTranscriptDeletion = PendingTranscriptDeletion(
                entries: pendingTranscriptDeletion.entries + [entry]
            )
        } else {
            pendingTranscriptDeletion = PendingTranscriptDeletion(entries: [entry])
        }

        schedulePendingDeletionDismissal()
    }

    func undoPendingDeletion() {
        guard let pendingTranscriptDeletion else {
            return
        }

        pendingDeleteResetTask?.cancel()
        pendingDeleteResetTask = nil
        self.pendingTranscriptDeletion = nil

        history.append(contentsOf: pendingTranscriptDeletion.entries)
        history.sort { $0.createdAt > $1.createdAt }
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
        Task { @MainActor in
            _ = await insertionService.insert(entry.text)
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

    private func configurePermissionObservation() {
        accessibilityNotificationObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.accessibility.api"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.syncPermissionState()
            }
        }
    }

    private func startPermissionMonitoring() {
        guard permissionMonitorTask == nil else {
            return
        }

        permissionMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.syncPermissionState()
                try? await Task.sleep(for: .milliseconds(1500))
            }
        }
    }

    private func schedulePendingDeletionDismissal() {
        pendingDeleteResetTask?.cancel()
        pendingDeleteResetTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(4.25))
            guard !Task.isCancelled else {
                return
            }

            self?.pendingTranscriptDeletion = nil
            self?.pendingDeleteResetTask = nil
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
            enterModelRepairMode()
            startModelSetup()
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

            let insertionMethod = await insertionService.insert(cleaned, target: pendingInsertionTarget)
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

            switch insertionMethod {
            case .accessibility:
                statusText = "Inserted directly."
            case .clipboard:
                statusText = "Pasted and restored clipboard."
            case .copied:
                statusText = "Copied to clipboard."
            }
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
        setRecorderIssue(.generic(message))
    }

    private func setRecorderIssue(_ issue: RecorderIssue) {
        statusText = issue.statusMessage
        phase = .error(issue)
        recordingDuration = 0
        resetWaveform(active: false)
        transitionToReady(after: issue.autoDismissDelay)
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

    private func syncPermissionState() {
        accessibilityGranted = permissionsManager.isAccessibilityGranted
        microphoneGranted = permissionsManager.isMicrophoneGranted

        guard phase != .recording, phase != .transcribing else {
            return
        }

        statusText = idleStatusText
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

    private var hasUsableModelAvailable: Bool {
        ModelLocator.preferredModelURL() != nil
    }

    private func beginModelDownload() {
        modelSetupState = .downloading(0)
    }

    private func markModelSetupReady(_ source: ModelSource) {
        modelDownloader = nil
        try? FileManager.default.removeItem(at: ModelLocator.downloadResumeDataURL)
        modelSetupState = .ready(source)
    }

    private func enterModelRepairMode() {
        hasCompletedOnboarding = false
        onboardingMode = .modelRepair
        onboardingStep = .download
        modelSetupState = .idle
        whisperEngine = nil
        phase = .loadingModel
        statusText = "Speech model needs to be set up again."
    }

    private var transcriptToCopy: String? {
        let trimmedLastTranscript = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLastTranscript.isEmpty {
            return trimmedLastTranscript
        }

        return history.first?.text
    }
}
