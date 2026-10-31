import AppKit
import CoreAudio
import Foundation
import Observation

private enum WaveformHistory {
    static let sampleCount = 40
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
    case starting
    case cancellingStart
    case recording
    case transcribing
    case inserted(InsertionMethod)
    case error(RecorderIssue)

    var isInsertedPhase: Bool {
        if case .inserted = self { return true }
        return false
    }

    var isErrorPhase: Bool {
        if case .error = self { return true }
        return false
    }
}

enum RecorderIssue: Equatable {
    case microphonePermissionRequired
    case noSpeechDetected
    case speechDetectionUnavailable
    case recordingStartFailed(String)
    case generic(String)

    private var presentation: (statusMessage: String, title: String, subtitle: String?, autoDismissDelay: TimeInterval) {
        switch self {
        case .microphonePermissionRequired:
            return (
                "Microphone access is required for local dictation.",
                "Microphone access needed",
                nil,
                4.2
            )
        case .noSpeechDetected:
            return (
                "No speech detected.",
                "No speech detected",
                "Try speaking a little louder or closer to the mic",
                2.2
            )
        case .speechDetectionUnavailable:
            return (
                "Speech detection is unavailable. Restart WhisperMax and try again.",
                "Couldn’t analyze speech",
                "Restart WhisperMax and try again",
                3.5
            )
        case .recordingStartFailed(let message):
            return (
                message,
                "Couldn’t start recording",
                "Check your microphone and try again",
                2.4
            )
        case .generic(let message):
            return (message, "Try again", "Recorder reset", 1.8)
        }
    }

    var statusMessage: String { presentation.statusMessage }

    var title: String { presentation.title }

    var subtitle: String? { presentation.subtitle }

    var autoDismissDelay: TimeInterval { presentation.autoDismissDelay }
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
    case dictionary
    case settings
}

struct TranscriptEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date
    let duration: TimeInterval
    let insertionMethod: InsertionMethod
    let insertionTargetName: String?
    let insertionTargetBundleIdentifier: String?
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
    private let wordDictionaryStore = WordDictionaryStore()
    private let inputDeviceService = AudioInputDeviceService()
    private let inputPreferenceStore = AudioInputPreferenceStore()
    private let updateController: AppUpdateController
    let permissionsManager = PermissionsManager()
    private let insertionService = TextInsertionService()
    private let recorder = AudioRecorderService()
    private var recordingCallbackCoordinator = RecordingCallbackCoordinator()
    private let speechActivityService = SpeechActivityService()
    private let debugRecordingStore = DebugRecordingStore()

    private var transcriptionEngine: PhononCoreMLEngine?
    private var modelPreparationTask: Task<Void, Never>?
    private var requiresModelDownloadRepair = false
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionShutdown: (id: UUID, task: Task<Void, Never>)?
    private var isStartingRecording = false
    private var shouldCancelRecordingStart = false
    private var preRecordingSystemDefaultInputDeviceID: AudioObjectID?
    private var recordingPinnedDeviceID: AudioObjectID?
    private var permissionMonitorTask: Task<Void, Never>?
    private var permissionMonitorBoostUntil: Date?
    private var accessibilityNotificationObserver: NSObjectProtocol?
    private var menuFeedbackResetTask: Task<Void, Never>?
    private var pendingDeleteResetTask: Task<Void, Never>?
    private var pendingPhaseResetTask: Task<Void, Never>?
    private var pendingInsertionTarget: InsertionTargetContext?
    private(set) var transcribingAnimationStartTime: TimeInterval?

#if DEBUG
    var appleVoiceProcessingDiagnosticEnabled = false
    var speechGateBypassDiagnosticEnabled = false
    var microphoneAccessRequestOverrideForTesting: (@MainActor () async -> Bool)?
    var appleVoiceProcessingDiagnosticStatus = "No voice-processing attempt yet." {
        didSet {
            UserDefaults.standard.set(appleVoiceProcessingDiagnosticStatus, forKey: "AppleVoiceProcessingDiagnosticStatus")
        }
    }
#endif

    var phase: RecordingPhase = .loadingModel {
        didSet {
            if phase != oldValue {
                pendingPhaseResetTask?.cancel()
                pendingPhaseResetTask = nil
            }
            if phase == .transcribing, oldValue != .transcribing {
                transcribingAnimationStartTime = Date.timeIntervalSinceReferenceDate
            } else if phase != .transcribing {
                transcribingAnimationStartTime = nil
            }
            phaseDidChange?(phase)
        }
    }

    var phaseDidChange: ((RecordingPhase) -> Void)?
    var onOnboardingComplete: (() -> Void)?

    // MARK: - Onboarding

    private enum ModelSetupState: Equatable {
        case idle
        case downloading(Double)
        case ready
        case failed(String)
    }

    private enum SpeechGate {
        static let minimumPeakProbability: Float = 0.5
    }

    var hasCompletedOnboarding: Bool = false
    var onboardingMode: OnboardingMode = .full
    var onboardingStep: OnboardingStep = .download
    private var modelSetupState: ModelSetupState = .idle

    private var modelDownloader: PhononModelDownloader?

    var onboardingSteps: [OnboardingStep] {
        guard onboardingMode == .modelRepair, !shouldResumePermissionsStep else {
            return OnboardingStep.allCases
        }

        return [.download, .ready]
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

    var isDownloadComplete: Bool {
        if case .ready = modelSetupState {
            return true
        }
        return false
    }

    var isModelPrepared: Bool {
        phase == .ready && transcriptionEngine != nil
    }

    func startModelSetup(forceDownload: Bool = false) {
        if case .downloading = modelSetupState {
            return
        }

        let shouldForceDownload = forceDownload || requiresModelDownloadRepair
        if !shouldForceDownload {
            if case .ready = modelSetupState, hasUsableModelAvailable {
                startModelPreparation()
                return
            }

            if ModelLocator.hasInstalledPhononModel {
                markModelSetupReady()
                return
            }
        }

        beginModelDownload()

        let downloader = PhononModelDownloader()
        modelDownloader = downloader

        downloader.onProgress = { [weak self] progress in
            self?.modelSetupState = .downloading(progress)
        }
        downloader.onComplete = { [weak self] in
            self?.modelDownloader = nil
            self?.markModelSetupReady()
        }
        downloader.onError = { [weak self] message in
            self?.modelDownloader = nil
            self?.modelSetupState = .failed(message)
        }

        downloader.start()
    }

    func retryDownload() {
        modelDownloader = nil
        modelSetupState = .idle
        startModelSetup(forceDownload: requiresModelDownloadRepair)
    }

    func pauseModelDownload() async {
        await modelDownloader?.pause()
    }

    func advanceOnboarding() {
        if onboardingMode == .modelRepair, onboardingStep == .download, isDownloadComplete {
            onboardingStep = shouldResumePermissionsStep ? .permissions : .ready
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

        guard isModelPrepared else {
            startModelPreparation()
            return
        }

        hasCompletedOnboarding = true
        onboardingMode = .full
        FileManager.default.createFile(
            atPath: ModelLocator.onboardingCompleteFileURL.path,
            contents: nil
        )

        onOnboardingComplete?()

        startModelPreparation()
    }

    func loadOnboardingState() {
        let hasSentinel = FileManager.default.fileExists(
            atPath: ModelLocator.onboardingCompleteFileURL.path
        )
        let hasModel = ModelLocator.hasInstalledPhononModel
        hasCompletedOnboarding = hasSentinel && hasModel

        if hasSentinel && !hasModel {
            onboardingMode = .modelRepair
            onboardingStep = .download
            modelSetupState = .idle
            return
        }

        onboardingMode = .full

        if hasModel {
            modelSetupState = .ready
            onboardingStep = shouldResumePermissionsStep ? .permissions : .ready
        } else {
            modelSetupState = .idle
            onboardingStep = .download
        }
    }

    private var shouldResumePermissionsStep: Bool {
        !permissionsManager.isMicrophoneGranted || !permissionsManager.isAccessibilityGranted
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
    var wordDictionary: [WordDictionaryEntry] = []
    var inputDevices: [AudioInputDevice] = []
    var statusText: String = "Loading local model..."
    var modelPreparationError: String?
    var modelDisplayName: String = "Phonon-2"
    var modelPath: String = ""
    var historyRetentionLimit: HistoryRetentionLimit = .defaultLimit
    var hotkeyDisplay: String = "⌥ Space"
    var hotkeyInstructionText: String = "Option + Space"
    var accessibilityGranted = false
    var microphoneGranted = false
    var microphonePermissionState: MicrophonePermissionState = .notDetermined
    var defaultInputDeviceID: AudioObjectID = kAudioObjectUnknown
    var inputPreference: AudioInputPreference = .systemDefault
    var menuFeedbackMessage: String?
    var pendingTranscriptDeletion: PendingTranscriptDeletion?
    var canCheckForUpdates = false
    var availableUpdate: AvailableAppUpdate?
    var insertionTargetName: String?
    var insertionTargetIcon: NSImage?

    init(updateController: AppUpdateController = AppUpdateController()) {
        self.updateController = updateController
        configureRecorderCallbacks()
        configureInputDeviceObservation()
        configurePermissionObservation()
        configureUpdateObservation()
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

    var sortedWordDictionary: [WordDictionaryEntry] {
        wordDictionary.sorted {
            $0.text.localizedCaseInsensitiveCompare($1.text) == .orderedAscending
        }
    }

    var formattedDuration: String {
        let total = Int(recordingDuration.rounded(.down))
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    var needsSetup: Bool {
        !microphoneGranted
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

        return preferredPinnedInput.resolvedDevice(in: inputDevices) == nil ? preferredPinnedInput : nil
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

    var appVersionDisplay: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(shortVersion) (\(buildVersion))"
    }

    var updatePrimaryDescription: String {
        if let availableUpdate {
            return "Update \(availableUpdate.version) available"
        }

        return "Current version \(appVersionDisplay)"
    }

    var updateSecondaryDescription: String {
        if availableUpdate != nil {
            return "Current version \(appVersionDisplay) · checks automatically"
        }

        return "Checks for updates automatically"
    }

    var updateActionTitle: String {
        guard let availableUpdate else {
            return "Check for Updates…"
        }

        return availableUpdate.isSimulated ? "View Update" : "Install Update…"
    }

    var shouldShowHomeUpdatePill: Bool {
        sidebarSelection == .home && availableUpdate != nil
    }

    var menuPrimaryActionTitle: String {
        switch phase {
        case .loadingModel:
            return "Loading Model…"
        case .starting:
            return "Cancel Start"
        case .cancellingStart:
            return "Cancelling…"
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
        case .loadingModel, .cancellingStart, .transcribing:
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
        if phase == .starting {
            return "Starting microphone…"
        }

        if phase == .cancellingStart {
            return "Cancelling recording start…"
        }

        if !microphoneGranted {
            return "Grant microphone access to start dictation"
        }

        if let modelPreparationError {
            return modelPreparationError
        }

        switch phase {
        case .loadingModel:
            return "Loading local model…"
        case .ready:
            return readySubtitle
        case .starting:
            return "Starting microphone…"
        case .cancellingStart:
            return "Cancelling recording start…"
        case .recording:
            return "Listening…"
        case .transcribing:
            return "Transcribing locally…"
        case .inserted(let method):
            switch method {
            case .accessibility, .clipboard:
                return insertionStatusText(verb: "Pasted", target: pendingInsertionTarget)
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
            ModelLocator.cleanTemporaryRecordings()
        } catch {
            setError("Could not prepare whispermax storage.")
            return
        }

        loadOnboardingState()
        inputPreference = inputPreferenceStore.load()
        loadHistory()
        wordDictionary = wordDictionaryStore.load()
        refreshInputDevices()
        refreshPermissions()
        startPermissionMonitoring()
        syncUpdateState()
        statusText = idleStatusText

        guard hasCompletedOnboarding else { return }

        startModelPreparation()
        Task { await requestInitialPermissionsIfNeeded() }
    }

    func refreshPermissions() {
        boostPermissionMonitoring(for: 2.5)
        syncPermissionState()
    }

    func promptForAccessibility() {
        boostPermissionMonitoring(for: 10)
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
            migratePinnedInputPreferenceIfNeeded()
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
        let pinnedPreference = PinnedAudioInputPreference(device: device)

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

        return preferredPinnedInput.matches(device)
    }

    func openAccessibilitySettings() {
        boostPermissionMonitoring(for: 10)
        permissionsManager.openAccessibilitySettings()
        refreshPermissions()
    }

    func openMicrophoneSettings() {
        permissionsManager.openMicrophoneSettings()
    }

    func beginMicrophonePermissionFlow() {
        boostPermissionMonitoring(for: 10)

        Task {
            switch permissionsManager.microphonePermissionState {
            case .authorized:
                microphoneGranted = true
            case .notDetermined:
                microphoneGranted = await permissionsManager.requestMicrophoneAccess()
            case .needsSettings, .unavailable:
                openMicrophoneSettings()
            }

            refreshPermissions()
        }
    }

    func checkForUpdates() {
        updateController.checkForUpdates()
    }

    func openAvailableUpdate() {
        guard let availableUpdate else {
            updateController.checkForUpdates()
            return
        }

        if availableUpdate.isSimulated, let releaseNotesURL = availableUpdate.releaseNotesURL {
            NSWorkspace.shared.open(releaseNotesURL)
        } else {
            updateController.checkForUpdates()
        }
    }

    func refreshUpdateState() {
        updateController.refreshState()
        syncUpdateState()
    }

    func toggleRecording() async {
        switch phase {
        case .starting:
            cancelRecording()
        case .cancellingStart, .transcribing:
            return
        case .recording:
            stopRecording()
        default:
            await startRecording()
        }
    }

    func startRecording() async {
        guard !isStartingRecording else { return }

        guard phase != .loadingModel else {
            statusText = "Still loading the local model…"
            return
        }

        guard phase != .starting,
              phase != .cancellingStart,
              phase != .recording,
              phase != .transcribing else { return }

        guard transcriptionEngine != nil else {
            phase = .loadingModel
            statusText = "The model is still loading."
            startModelPreparation()
            return
        }

        isStartingRecording = true
        shouldCancelRecordingStart = false
        phase = .starting
        statusText = "Starting…"
        defer {
            isStartingRecording = false
            shouldCancelRecordingStart = false
        }

        microphoneGranted = await requestMicrophoneAccessForRecording()
        do {
            try checkRecordingStartCancellation()
        } catch {
            finishCancelledRecordingStart()
            return
        }
        guard microphoneGranted else {
            setRecorderIssue(.microphonePermissionRequired)
            return
        }

#if DEBUG
        let voiceProcessingEnabled = appleVoiceProcessingDiagnosticEnabled
#else
        let voiceProcessingEnabled = false
#endif

        var recordingID: UUID?
        var recorderStarted = false
        do {
            try checkRecordingStartCancellation()
            let switchedInputDevice = prepareInputDeviceForRecording()
            recordingDuration = 0
            lastTranscript = ""
            pendingInsertionTarget = insertionService.captureTargetContext()
            resetWaveform(active: true)
            let nextRecordingID = UUID()
            recordingID = nextRecordingID
            guard recordingCallbackCoordinator.beginRecording(nextRecordingID) else {
                throw AudioRecorderService.RecorderError.alreadyRecording
            }

            try await startRecorderWithRecovery(
                afterSwitchingInputDevice: switchedInputDevice,
                voiceProcessingEnabled: voiceProcessingEnabled,
                recordingID: nextRecordingID
            )
            recorderStarted = true
            try checkRecordingStartCancellation()
            guard recordingCallbackCoordinator.acceptsMeter(for: nextRecordingID) else {
                recorder.cancel()
                recorderStarted = false
                if phase.isErrorPhase { return }
                throw AudioRecorderService.RecorderError.couldNotStartRecording
            }
#if DEBUG
            if voiceProcessingEnabled {
                appleVoiceProcessingDiagnosticStatus = "Voice-processed capture started."
            }
#endif
            statusText = "Listening…"
            phase = .recording
        } catch is CancellationError {
            if recorderStarted { recorder.cancel() }
            if let recordingID { recordingCallbackCoordinator.abandonRecording(recordingID) }
            finishCancelledRecordingStart()
        } catch {
            if let recordingID { recordingCallbackCoordinator.abandonRecording(recordingID) }
            handleRecordingStartFailure()
#if DEBUG
            if voiceProcessingEnabled {
                appleVoiceProcessingDiagnosticStatus = (error as? AudioRecorderService.RecorderError)?.logDescription
                    ?? Self.diagnosticDescription(for: error)
                appleVoiceProcessingDiagnosticEnabled = false
            }
#endif
            let message = (error as? AudioRecorderService.RecorderError)?.errorDescription
                ?? "Failed to start recording."
            setRecorderIssue(.recordingStartFailed(message))
        }
    }

#if DEBUG
    private static func diagnosticDescription(for error: Error) -> String {
        let error = error as NSError
        return "recorder.start: \(error.domain) (\(error.code)): \(error.localizedDescription)"
    }

    func runRecordingStartCancellationIntegrationCheck() async -> Bool {
        guard ModelLocator.hasInstalledPhononModel else { return false }

        if transcriptionEngine == nil {
            phase = .loadingModel
            startModelPreparation()
            await modelPreparationTask?.value
        }

        guard transcriptionEngine != nil else { return false }

        microphoneAccessRequestOverrideForTesting = {
            try? await Task.sleep(for: .milliseconds(500))
            return true
        }
        defer { microphoneAccessRequestOverrideForTesting = nil }

        phase = .error(.generic("Earlier test state"))
        transitionToReady(after: 0.02)
        let startTask = Task { @MainActor in
            await self.startRecording()
        }
        for _ in 0..<100 where phase != .starting {
            await Task.yield()
        }
        guard phase == .starting else {
            await startTask.value
            return false
        }

        await toggleRecording()
        try? await Task.sleep(for: .milliseconds(50))
        let cancellationStateSurvivedOldReset = phase == .cancellingStart
        await startTask.value
        return cancellationStateSurvivedOldReset
            && phase == .ready
            && recordingCallbackCoordinator.activeRecordingID == nil
    }

    func runDelayedPhaseResetIntegrationCheck() async -> Bool {
        let oldError = RecorderIssue.generic("Earlier test state")
        let currentError = RecorderIssue.generic("Current test state")
        phase = .error(oldError)
        transitionToReady(after: 0.02)
        phase = .error(currentError)
        transitionToReady(after: 0.2)

        try? await Task.sleep(for: .milliseconds(60))
        let currentErrorWasPreserved = phase == .error(currentError)
        try? await Task.sleep(for: .milliseconds(180))
        return currentErrorWasPreserved && phase == .ready
    }

    func runPendingFinishCancellationIntegrationCheck() -> Bool {
        let recordingID = UUID()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("whispermax-cancelled-finish-\(recordingID.uuidString).caf")
        do {
            try Data([0x01]).write(to: fileURL)
        } catch {
            return false
        }

        guard recordingCallbackCoordinator.beginRecording(recordingID),
              recordingCallbackCoordinator.stopRecording(recordingID) else {
            try? FileManager.default.removeItem(at: fileURL)
            return false
        }

        pendingInsertionTarget = nil
        phase = .transcribing
        cancelRecording()
        handleRecordingFinished(
            from: fileURL,
            configuration: AudioCaptureConfiguration(
                recordingID: recordingID,
                voiceProcessingEnabled: false,
                preferredMicrophoneMode: "standard",
                activeMicrophoneMode: "standard",
                sampleRate: 16_000,
                channelCount: 1
            )
        )

        return !FileManager.default.fileExists(atPath: fileURL.path)
            && phase == (transcriptionEngine == nil ? .loadingModel : .ready)
            && recordingCallbackCoordinator.activeRecordingID == nil
    }

    func runEarlyRecorderErrorIntegrationCheck() -> Bool {
        let recordingID = UUID()
        guard recordingCallbackCoordinator.beginRecording(recordingID) else { return false }

        phase = .starting
        let message = "Synthetic immediate recorder error"
        handleRecordingError(recordingID: recordingID, message: message)
        let errorWasHandled = phase == .error(.generic(message))
            && recordingCallbackCoordinator.activeRecordingID == nil

        phase = transcriptionEngine == nil ? .loadingModel : .ready
        statusText = idleStatusText
        return errorWasHandled
    }

    func runStaleTapBufferIntegrationCheck() -> Bool {
        recorder.runStaleTapBufferIntegrationCheck()
    }
#endif

    func stopRecording() {
        guard phase == .recording else {
            return
        }

        guard let recordingID = recordingCallbackCoordinator.activeRecordingID,
              recordingCallbackCoordinator.stopRecording(recordingID) else {
            recorder.cancel()
            handleRecordingStartFailure()
            setRecorderIssue(.recordingStartFailed("Recording could not be stopped. Try again."))
            return
        }

        statusText = "Transcribing locally…"
        phase = .transcribing
        recorder.stop()
    }

    func cancelRecording() {
        switch phase {
        case .starting:
            shouldCancelRecordingStart = true
            phase = .cancellingStart
            statusText = "Cancelling…"
        case .cancellingStart:
            return
        case .recording:
            if let recordingID = recordingCallbackCoordinator.activeRecordingID {
                recordingCallbackCoordinator.abandonRecording(recordingID)
            }
            recorder.cancel()
            restoreSystemInputAfterRecordingIfNeeded()
            pendingInsertionTarget = nil
            recordingDuration = 0
            resetWaveform(active: false)
            phase = transcriptionEngine == nil ? .loadingModel : .ready
            statusText = idleStatusText
        case .transcribing:
            if let transcriptionTask {
                transcriptionTask.cancel()
            } else if let recordingID = recordingCallbackCoordinator.activeRecordingID,
                      recordingCallbackCoordinator.cancelPendingFinish(recordingID) {
                statusText = "Cancelling…"
            }
        default:
            return
        }
    }

    func clearHistory() {
        history.removeAll()
        saveHistory()
    }

    func setHistoryRetentionLimit(_ limit: HistoryRetentionLimit) {
        guard historyRetentionLimit != limit else {
            return
        }

        historyRetentionLimit = limit
        historyStore.saveRetentionLimit(limit)
        saveHistory()
    }

    private func loadHistory() {
        historyRetentionLimit = historyStore.loadRetentionLimit()
        let loadedHistory = historyStore.load()
        history = historyStore.pruned(loadedHistory, limit: historyRetentionLimit)

        if loadedHistory.count != history.count {
            historyStore.save(history)
        }
    }

    private func saveHistory() {
        history = historyStore.pruned(history, limit: historyRetentionLimit)
        historyStore.save(history)
    }

    func filteredWordDictionary(matching query: String) -> [WordDictionaryEntry] {
        let trimmedQuery = normalizedDictionaryTerm(query)
        guard !trimmedQuery.isEmpty else {
            return sortedWordDictionary
        }

        return sortedWordDictionary.filter {
            $0.text.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    func canAddWordDictionaryEntry(_ rawText: String) -> Bool {
        let normalized = normalizedDictionaryTerm(rawText)
        guard !normalized.isEmpty else {
            return false
        }

        return !containsWordDictionaryEntry(normalized)
    }

    func containsWordDictionaryEntry(_ rawText: String) -> Bool {
        let normalized = normalizedDictionaryTerm(rawText)
        guard !normalized.isEmpty else {
            return false
        }

        return wordDictionary.contains {
            $0.text.compare(normalized, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    func addWordDictionaryEntry(_ rawText: String) {
        let normalized = normalizedDictionaryTerm(rawText)
        guard canAddWordDictionaryEntry(normalized) else {
            return
        }

        wordDictionary.append(
            WordDictionaryEntry(
                id: UUID(),
                text: normalized,
                createdAt: Date()
            )
        )
        wordDictionaryStore.save(wordDictionary)
    }

    func deleteWordDictionaryEntry(_ entry: WordDictionaryEntry) {
        wordDictionary.removeAll { $0.id == entry.id }
        wordDictionaryStore.save(wordDictionary)
    }

    func deleteEntry(_ entry: TranscriptEntry) {
        history.removeAll { $0.id == entry.id }
        saveHistory()

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
        saveHistory()
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
            _ = try? await insertionService.insert(entry.text)
        }
    }

    private func configureRecorderCallbacks() {
        recorder.onMeter = { [weak self] recordingID, level, duration in
            guard let self,
                  self.recordingCallbackCoordinator.acceptsMeter(for: recordingID) else { return }
            self.recordingDuration = duration
            self.pushWaveform(level: CGFloat(level))
        }

        recorder.onFinish = { [weak self] url, configuration in
            guard let self else { return }
            self.handleRecordingFinished(from: url, configuration: configuration)
        }

        recorder.onError = { [weak self] recordingID, message in
            self?.handleRecordingError(recordingID: recordingID, message: message)
        }
    }

    private func handleRecordingFinished(from url: URL, configuration: AudioCaptureConfiguration) {
        guard let recordingID = configuration.recordingID else {
            try? FileManager.default.removeItem(at: url)
            return
        }

        switch recordingCallbackCoordinator.finishRecording(recordingID) {
        case .stale:
            try? FileManager.default.removeItem(at: url)
        case .discard:
            try? FileManager.default.removeItem(at: url)
            finishCancelledPendingRecording()
        case .transcribe:
            transcriptionTask = Task { @MainActor [weak self] in
                await self?.transcribeAndInsert(from: url, audioConfiguration: configuration)
            }
        }
    }

    private func handleRecordingError(recordingID: UUID, message: String) {
        switch recordingCallbackCoordinator.failRecording(recordingID) {
        case .stale:
            return
        case .cancelled:
            finishCancelledPendingRecording()
        case .present:
            pendingInsertionTarget = nil
            restoreSystemInputAfterRecordingIfNeeded()
            setError(message)
        }
    }

    private func finishCancelledPendingRecording() {
        restoreSystemInputAfterRecordingIfNeeded()
        pendingInsertionTarget = nil
        recordingDuration = 0
        resetWaveform(active: false)
        phase = transcriptionEngine == nil ? .loadingModel : .ready
        statusText = idleStatusText
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

    private func configureUpdateObservation() {
        updateController.onStateChange = { [weak self] in
            Task { @MainActor [weak self] in
                self?.syncUpdateState()
            }
        }
    }

    private func startPermissionMonitoring() {
        guard permissionMonitorTask == nil else {
            return
        }

        permissionMonitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.syncPermissionState()

                let isBoostActive = (self.permissionMonitorBoostUntil ?? .distantPast) > Date()
                let intervalMilliseconds: UInt64 = (isBoostActive || !self.microphoneGranted) ? 350 : 1500
                try? await Task.sleep(for: .milliseconds(intervalMilliseconds))
            }
        }
    }

    private func boostPermissionMonitoring(for duration: TimeInterval) {
        let nextDeadline = Date().addingTimeInterval(duration)
        if let existingDeadline = permissionMonitorBoostUntil, existingDeadline > nextDeadline {
            return
        }

        permissionMonitorBoostUntil = nextDeadline
    }

    private func syncUpdateState() {
        canCheckForUpdates = updateController.canCheckForUpdates
        availableUpdate = updateController.availableUpdate
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

    private func normalizedDictionaryTerm(_ rawText: String) -> String {
        rawText.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var preferredTranscriptionTerms: [String] {
        wordDictionary.map(\.text)
    }

    private func prepareInputDeviceForRecording() -> Bool {
        refreshInputDevices()
        preRecordingSystemDefaultInputDeviceID = nil
        recordingPinnedDeviceID = nil

        guard let preferredPinnedInput else {
            return false
        }

        guard let pinnedDevice = preferredPinnedInput.resolvedDevice(in: inputDevices) else {
            setMenuFeedback("\(preferredPinnedInput.name) unavailable. Using System Default")
            return false
        }

        let pinnedDeviceID = pinnedDevice.audioObjectID

        recordingPinnedDeviceID = pinnedDeviceID

        guard defaultInputDeviceID != pinnedDeviceID else {
            return false
        }

        let originalDefaultInputDeviceID = defaultInputDeviceID

        do {
            try inputDeviceService.setDefaultInputDevice(pinnedDeviceID)
            preRecordingSystemDefaultInputDeviceID = originalDefaultInputDeviceID
            refreshInputDevices()
            return true
        } catch {
            recordingPinnedDeviceID = nil
            setMenuFeedback("Couldn’t switch to \(preferredPinnedInput.name). Using System Default")
            return false
        }
    }

    private func startRecorderWithRecovery(
        afterSwitchingInputDevice switchedInputDevice: Bool,
        voiceProcessingEnabled: Bool,
        recordingID: UUID
    ) async throws {
        try checkRecordingStartCancellation()
        if switchedInputDevice {
            try await Task.sleep(for: .milliseconds(220))
            try checkRecordingStartCancellation()
            refreshInputDevices()
        }

        var retryDelayMilliseconds = switchedInputDevice ? 180 : 120
        var lastError: Error?

        for attempt in 0..<3 {
            try checkRecordingStartCancellation()
            do {
                try recorder.start(
                    voiceProcessingEnabled: voiceProcessingEnabled,
                    recordingID: recordingID
                )
                return
            } catch let recorderError as AudioRecorderService.RecorderError {
                lastError = recorderError
                NSLog("Recorder start attempt %d failed: %@", attempt + 1, recorderError.logDescription)

                if case .alreadyRecording = recorderError {
                    throw recorderError
                }

                guard !voiceProcessingEnabled, attempt < 2 else {
                    throw recorderError
                }

                refreshInputDevices()
                try await Task.sleep(for: .milliseconds(retryDelayMilliseconds))
                try checkRecordingStartCancellation()
                retryDelayMilliseconds *= 2
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                NSLog("Recorder start attempt %d failed with unexpected error: %@", attempt + 1, error.localizedDescription)

                guard !voiceProcessingEnabled, attempt < 2 else {
                    throw error
                }

                refreshInputDevices()
                try await Task.sleep(for: .milliseconds(retryDelayMilliseconds))
                try checkRecordingStartCancellation()
                retryDelayMilliseconds *= 2
            }
        }

        throw lastError ?? AudioRecorderService.RecorderError.couldNotStartRecording
    }

    private func checkRecordingStartCancellation() throws {
        try Task.checkCancellation()
        if shouldCancelRecordingStart {
            throw CancellationError()
        }
    }

    private func finishCancelledRecordingStart() {
        handleRecordingStartFailure()
        recordingDuration = 0
        resetWaveform(active: false)
        phase = transcriptionEngine == nil ? .loadingModel : .ready
        statusText = idleStatusText
    }

    private func requestMicrophoneAccessForRecording() async -> Bool {
#if DEBUG
        if let microphoneAccessRequestOverrideForTesting {
            return await microphoneAccessRequestOverrideForTesting()
        }
#endif
        return await permissionsManager.requestMicrophoneAccess()
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
        guard ModelLocator.hasInstalledPhononModel else {
            enterModelRepairMode()
            startModelSetup()
            return
        }

        modelPath = ModelLocator.phononModelURL.path
        modelDisplayName = "Phonon-2"
        let engine = PhononCoreMLEngine(modelURL: ModelLocator.phononModelURL)
        transcriptionEngine = engine

        do {
            let startedAt = Date.timeIntervalSinceReferenceDate
            try await engine.prepare()
            guard await speechActivityService.prepare() else {
                await engine.shutdown()
                transcriptionEngine = nil
                showModelPreparationError(RecorderIssue.speechDetectionUnavailable.statusMessage)
                return
            }
            let elapsedMilliseconds = (Date.timeIntervalSinceReferenceDate - startedAt) * 1_000
            NSLog("WhisperMax ASR model ready: %@ %.0f ms", modelDisplayName, elapsedMilliseconds)
            modelPreparationError = nil
            phase = .ready
            statusText = idleStatusText
        } catch {
            await engine.shutdown()
            transcriptionEngine = nil
            guard !Task.isCancelled else { return }
            showModelPreparationError("Failed to prepare the local Phonon model: \(error.localizedDescription)")
        }
    }

    func retryModelPreparation() {
        guard modelPreparationError != nil, modelPreparationTask == nil else { return }
        modelPreparationError = nil
        phase = .loadingModel
        statusText = "Checking local model…"
        let modelURL = ModelLocator.phononModelURL
        modelPreparationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.modelPreparationTask = nil }

            let isValid = await Task.detached(priority: .userInitiated) {
                PhononModelPackage.isValidInstallation(at: modelURL)
            }.value
            guard !Task.isCancelled else { return }

            guard isValid else {
                requiresModelDownloadRepair = true
                enterModelRepairMode()
                startModelSetup(forceDownload: true)
                return
            }

            await preloadModel()
        }
    }

    private func showModelPreparationError(_ message: String) {
        modelPreparationError = message
        phase = .loadingModel
        statusText = message
    }

    private func startModelPreparation() {
        guard modelPreparationTask == nil, transcriptionEngine == nil else { return }

        modelPreparationTask = Task { @MainActor [weak self] in
            await self?.preloadModel()
            self?.modelPreparationTask = nil
        }
    }

    func shutdownTranscriptionEngine() {
        guard let engine = transcriptionEngine else { return }
        transcriptionTask?.cancel()
        transcriptionEngine = nil
        let activeTranscription = transcriptionTask
        let shutdownID = UUID()
        let shutdownTask = Task { @MainActor in
            if let activeTranscription {
                await activeTranscription.value
            }
            await engine.shutdown()
        }
        transcriptionShutdown = (shutdownID, shutdownTask)
    }

    func shutdownTranscriptionEngineAndWait() async {
        let engineBeingPrepared = transcriptionEngine
        modelPreparationTask?.cancel()
        if let modelPreparationTask {
            await modelPreparationTask.value
            self.modelPreparationTask = nil
        }

        transcriptionTask?.cancel()
        if let transcriptionTask {
            await transcriptionTask.value
            self.transcriptionTask = nil
        }

        if let shutdown = transcriptionShutdown {
            await shutdown.task.value
            if transcriptionShutdown?.id == shutdown.id {
                transcriptionShutdown = nil
            }
        }

        guard let engine = transcriptionEngine ?? engineBeingPrepared else { return }
        transcriptionEngine = nil
        await engine.shutdown()
    }

    private func requestInitialPermissionsIfNeeded() async {
        if permissionsManager.microphoneAuthorizationStatus == .notDetermined {
            microphoneGranted = await permissionsManager.requestMicrophoneAccess()
        } else {
            microphoneGranted = permissionsManager.isMicrophoneGranted
        }

        refreshPermissions()
    }

    private func transcribeAndInsert(
        from url: URL,
        audioConfiguration: AudioCaptureConfiguration
    ) async {
        defer {
            let wasCancelled = Task.isCancelled
            try? FileManager.default.removeItem(at: url)
            restoreSystemInputAfterRecordingIfNeeded()
            pendingInsertionTarget = nil
            transcriptionTask = nil
            if wasCancelled {
                phase = transcriptionEngine == nil ? .loadingModel : .ready
                statusText = idleStatusText
                recordingDuration = 0
                resetWaveform(active: false)
            }
        }

        guard let transcriptionEngine else {
            captureDebugRecording(
                from: url,
                audioConfiguration: audioConfiguration,
                result: .error,
                transcript: nil,
                insertionMethod: nil,
                issueMessage: nil,
                errorMessage: "The local speech model is not ready.",
                diagnostics: nil,
                chunks: [],
                transcriptionPasses: []
            )
            setError("The local speech model is not ready.")
            return
        }

        do {
#if DEBUG
            let diagnoseVoiceProcessing = appleVoiceProcessingDiagnosticEnabled
            let bypassSpeechGate = speechGateBypassDiagnosticEnabled
#else
            let diagnoseVoiceProcessing = false
            let bypassSpeechGate = false
#endif
            let diagnostics = try await speechActivityService.analyzeSpeech(from: url)
            let debugChunkPlans: [DebugRecordingChunkPlan] = []

#if DEBUG
            if diagnoseVoiceProcessing || bypassSpeechGate {
                let peakProbability = diagnostics.speechRegions.map(\.maxProbability).max() ?? 0
                appleVoiceProcessingDiagnosticStatus = String(
                    format: "Capture voice processing %@ · %.0f Hz / %u ch · VAD %@, %d regions, max %.2f · gate %@.",
                    audioConfiguration.voiceProcessingEnabled ? "active" : "inactive",
                    audioConfiguration.sampleRate,
                    audioConfiguration.channelCount,
                    diagnostics.mode.rawValue,
                    diagnostics.speechRegions.count,
                    peakProbability,
                    bypassSpeechGate ? "bypassed" : "enforced"
                )
            }
#endif

            guard diagnostics.mode != .bypass || bypassSpeechGate else {
                let issue = RecorderIssue.speechDetectionUnavailable
                captureDebugRecording(
                    from: url,
                    audioConfiguration: audioConfiguration,
                    result: .error,
                    transcript: nil,
                    insertionMethod: nil,
                    issueMessage: issue.statusMessage,
                    errorMessage: nil,
                    diagnostics: diagnostics,
                    chunks: debugChunkPlans,
                    transcriptionPasses: []
                )
                setRecorderIssue(issue)
                return
            }

            let hasDetectedSpeech = diagnostics.speechRegions.contains(where: {
                $0.maxProbability >= SpeechGate.minimumPeakProbability
            })
            guard hasDetectedSpeech || bypassSpeechGate else {
                captureDebugRecording(
                    from: url,
                    audioConfiguration: audioConfiguration,
                    result: .noSpeech,
                    transcript: nil,
                    insertionMethod: nil,
                    issueMessage: RecorderIssue.noSpeechDetected.statusMessage,
                    errorMessage: nil,
                    diagnostics: diagnostics,
                    chunks: debugChunkPlans,
                    transcriptionPasses: []
                )
                setNoSpeechDetected()
                return
            }

            let output = try await transcriptionEngine.transcribe(url: url)
            NSLog("WhisperMax ASR warm inference: %@ %.0f ms", modelDisplayName, output.inferenceDuration * 1_000)

            let cleanedTranscript = TranscriptFormatter.normalize(
                output.text,
                preferredTerms: preferredTranscriptionTerms
            )
            guard !cleanedTranscript.isEmpty else {
#if DEBUG
                if bypassSpeechGate {
                    appleVoiceProcessingDiagnosticStatus = "VAD gate bypassed; Phonon returned no text."
                }
#endif
                captureDebugRecording(
                    from: url,
                    audioConfiguration: audioConfiguration,
                    result: .noSpeech,
                    transcript: nil,
                    insertionMethod: nil,
                    issueMessage: RecorderIssue.noSpeechDetected.statusMessage,
                    errorMessage: nil,
                    diagnostics: diagnostics,
                    chunks: debugChunkPlans,
                    transcriptionPasses: []
                )
                setNoSpeechDetected()
                return
            }

            let transcriptionPasses = [DebugRecordingTranscriptionPass(
                index: 0,
                accepted: true,
                transcript: cleanedTranscript,
                selectedDuration: diagnostics.originalDuration
            )]

            try Task.checkCancellation()
            let insertionMethod = try await insertionService.insert(cleanedTranscript, target: pendingInsertionTarget)
            try Task.checkCancellation()
            lastTranscript = cleanedTranscript
            let storesInsertionTarget = insertionMethod != .copied
            let audioDuration = diagnostics.originalDuration

            let entry = TranscriptEntry(
                id: UUID(),
                text: cleanedTranscript,
                createdAt: Date(),
                duration: audioDuration,
                insertionMethod: insertionMethod,
                insertionTargetName: storesInsertionTarget ? pendingInsertionTarget?.displayName : nil,
                insertionTargetBundleIdentifier: storesInsertionTarget ? pendingInsertionTarget?.bundleIdentifier : nil,
                modelName: modelDisplayName
            )

            history.insert(entry, at: 0)
            saveHistory()

            if let startedAt = transcribingAnimationStartTime {
                let elapsedMilliseconds = (Date.timeIntervalSinceReferenceDate - startedAt) * 1_000
                NSLog("WhisperMax ASR stop-to-insert: %@ %.0f ms", modelDisplayName, elapsedMilliseconds)
            }

            switch insertionMethod {
            case .accessibility, .clipboard:
                statusText = insertionStatusText(verb: "Pasted", target: pendingInsertionTarget)
            case .copied:
                statusText = "Copied to clipboard."
            }
            captureDebugRecording(
                from: url,
                audioConfiguration: audioConfiguration,
                result: debugCaptureResult(for: insertionMethod),
                transcript: cleanedTranscript,
                insertionMethod: insertionMethod,
                issueMessage: nil,
                errorMessage: nil,
                diagnostics: diagnostics,
                chunks: debugChunkPlans,
                transcriptionPasses: transcriptionPasses
            )
            insertionTargetName = insertionMethod == .copied ? nil : pendingInsertionTarget?.displayName
            insertionTargetIcon = insertionMethod == .copied ? nil : pendingInsertionTarget?.icon
            phase = .inserted(insertionMethod)
            transitionToReady(after: 0.9)
        } catch {
            guard !Task.isCancelled else { return }
            captureDebugRecording(
                from: url,
                audioConfiguration: audioConfiguration,
                result: .error,
                transcript: nil,
                insertionMethod: nil,
                issueMessage: nil,
                errorMessage: error.localizedDescription,
                diagnostics: nil,
                chunks: [],
                transcriptionPasses: []
            )
            setError(error.localizedDescription)
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

    private func setNoSpeechDetected() {
        setRecorderIssue(.noSpeechDetected)
    }

    private func handleRecordingStartFailure() {
        restoreSystemInputAfterRecordingIfNeeded()
        pendingInsertionTarget = nil
    }

    private func setRecorderIssue(_ issue: RecorderIssue) {
        statusText = issue.statusMessage
        phase = .error(issue)
        recordingDuration = 0
        resetWaveform(active: false)
        transitionToReady(after: issue.autoDismissDelay)
    }

    private func transitionToReady(after delay: TimeInterval) {
        pendingPhaseResetTask?.cancel()
        pendingPhaseResetTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard let self else { return }
            guard self.phase != .starting,
                  self.phase != .cancellingStart,
                  self.phase != .recording,
                  self.phase != .transcribing else {
                return
            }

            self.phase = self.transcriptionEngine == nil ? .loadingModel : .ready
            self.statusText = self.idleStatusText
            self.insertionTargetName = nil
            self.insertionTargetIcon = nil
            self.recordingDuration = 0
            self.resetWaveform(active: false)
            self.pendingPhaseResetTask = nil
        }
    }

    private func insertionStatusText(verb: String, target: InsertionTargetContext?) -> String {
        guard let displayName = target?.displayName, !displayName.isEmpty else {
            return "\(verb) into your app."
        }

        return "\(verb) into \(displayName)."
    }

    private var idleStatusText: String {
        if !microphoneGranted {
            return "Grant microphone access to start dictation."
        }

        return transcriptionEngine == nil ? "Loading local model..." : "Ready when you are"
    }

    private func syncPermissionState() {
        microphonePermissionState = permissionsManager.microphonePermissionState
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
        ModelLocator.hasInstalledPhononModel
    }

    private func beginModelDownload() {
        modelSetupState = .downloading(0)
    }

    private func markModelSetupReady() {
        modelDownloader = nil
        requiresModelDownloadRepair = false
        try? FileManager.default.removeItem(at: ModelLocator.phononDownloadResumeDataURL)
        try? FileManager.default.removeItem(at: ModelLocator.phononDownloadResumeAssetURL)
        modelSetupState = .ready
        startModelPreparation()
    }

    private func enterModelRepairMode() {
        hasCompletedOnboarding = false
        onboardingMode = .modelRepair
        onboardingStep = .download
        modelSetupState = .idle
        modelPreparationError = nil
        shutdownTranscriptionEngine()
        modelPath = ""
        phase = .loadingModel
        statusText = "Speech model needs to be set up again."
    }

    private func migratePinnedInputPreferenceIfNeeded() {
        guard case .pinned(let pinnedPreference) = inputPreference,
              pinnedPreference.needsUIDMigration,
              let resolvedDevice = pinnedPreference.resolvedDevice(in: inputDevices)
        else {
            return
        }

        let migratedPreference = PinnedAudioInputPreference(device: resolvedDevice)
        inputPreference = .pinned(migratedPreference)
        inputPreferenceStore.save(inputPreference)
    }

    private var transcriptToCopy: String? {
        let trimmedLastTranscript = lastTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedLastTranscript.isEmpty {
            return trimmedLastTranscript
        }

        return history.first?.text
    }

    private func debugCaptureResult(for insertionMethod: InsertionMethod) -> DebugRecordingCaptureResult {
        switch insertionMethod {
        case .accessibility:
            return .inserted
        case .clipboard:
            return .clipboard
        case .copied:
            return .copied
        }
    }

    private func captureDebugRecording(
        from audioURL: URL,
        audioConfiguration: AudioCaptureConfiguration,
        result: DebugRecordingCaptureResult,
        transcript: String?,
        insertionMethod: InsertionMethod?,
        issueMessage: String?,
        errorMessage: String?,
        diagnostics: SpeechActivityDiagnostics?,
        chunks: [DebugRecordingChunkPlan],
        transcriptionPasses: [DebugRecordingTranscriptionPass]
    ) {
        debugRecordingStore.capture(
            audioURL: audioURL,
            recordingDuration: diagnostics?.originalDuration ?? recordingDuration,
            result: result,
            transcript: transcript,
            insertionMethod: insertionMethod,
            issueMessage: issueMessage,
            errorMessage: errorMessage,
            audioConfiguration: audioConfiguration,
            diagnostics: diagnostics,
            chunks: chunks,
            transcriptionPasses: transcriptionPasses
        )
    }

}
