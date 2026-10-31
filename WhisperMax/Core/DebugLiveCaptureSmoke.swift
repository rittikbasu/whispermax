#if DEBUG
import AppKit
import Darwin
import Foundation

@MainActor
final class DebugLiveCaptureSmoke {
    static let defaultsKey = "WhisperMaxDebugLiveCaptureSmokeDirectory"

    private enum Action: String, Decodable {
        case start
        case stop
        case cancel
    }

    private struct Command: Decodable {
        let runID: String
        let sequence: Int
        let action: Action
    }

    private struct State: Codable {
        let runID: String
        let commandSequence: Int
        let commandStatus: String
        let phase: String
        let insertionMethod: String?
        let issue: String?
        let capturedInsertionTargetBundleIdentifier: String?
        let frontmostBundleIdentifier: String?
    }

    private let directory: URL
    private let runID: String
    private var controller: AppController?
    private var pollingTask: Task<Void, Never>?
    private var lastCommandSequence = 0
    private var lastPublishedState: String?
    private var commandStatus = "waiting"
    private var commandIssue: String?

    static func consumeOptInDirectory() -> URL? {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: defaultsKey) else { return nil }
        defaults.removeObject(forKey: defaultsKey)
        defaults.synchronize()

        let directory = URL(fileURLWithPath: path).standardizedFileURL
        let temporaryRoot = URL(fileURLWithPath: "/private/tmp", isDirectory: true).standardizedFileURL
        let directoryNamePrefix = "whispermax-live-capture-"
        guard directory.deletingLastPathComponent().standardizedFileURL.path == temporaryRoot.path,
              directory.lastPathComponent.hasPrefix(directoryNamePrefix),
              let runID = UUID(uuidString: String(directory.lastPathComponent.dropFirst(directoryNamePrefix.count))),
              runID.uuidString.lowercased() == String(directory.lastPathComponent.dropFirst(directoryNamePrefix.count)).lowercased(),
              isPrivateDirectory(directory),
              isAbsent(directory.appendingPathComponent("command.json")),
              isAbsent(directory.appendingPathComponent("state.json")) else {
            return nil
        }

        return directory
    }

    static func runPrivateControlDirectoryIntegrationCheck(controller: AppController) async -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: defaultsKey) == nil else { return false }

        let staleRunID = UUID().uuidString.lowercased()
        let staleDirectory = URL(
            fileURLWithPath: "/private/tmp/whispermax-live-capture-\(staleRunID)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: staleDirectory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }

        defer { try? FileManager.default.removeItem(at: staleDirectory) }

        do {
            let staleCommand = Data("{\"runID\":\"\(staleRunID)\",\"sequence\":1,\"action\":\"start\"}".utf8)
            try staleCommand.write(to: staleDirectory.appendingPathComponent("command.json"), options: .atomic)
            _ = chmod(staleDirectory.appendingPathComponent("command.json").path, 0o600)
        } catch {
            return false
        }

        defaults.set(staleDirectory.path, forKey: defaultsKey)
        defaults.synchronize()
        guard consumeOptInDirectory() == nil,
              defaults.object(forKey: defaultsKey) == nil,
              FileManager.default.fileExists(atPath: staleDirectory.appendingPathComponent("command.json").path) else {
            return false
        }

        let runID = UUID().uuidString.lowercased()
        let directory = URL(
            fileURLWithPath: "/private/tmp/whispermax-live-capture-\(runID)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            return false
        }

        defer {
            defaults.removeObject(forKey: defaultsKey)
            defaults.synchronize()
            try? FileManager.default.removeItem(at: directory)
        }

        defaults.set(directory.path, forKey: defaultsKey)
        defaults.synchronize()
        guard let acceptedDirectory = consumeOptInDirectory(),
              acceptedDirectory.path == directory.standardizedFileURL.path else {
            return false
        }

        let smoke = DebugLiveCaptureSmoke(directory: acceptedDirectory)
        smoke.start(controller: controller)
        defer { smoke.stop() }

        let stateURL = acceptedDirectory.appendingPathComponent("state.json")
        for _ in 0..<100 {
            if smoke.isPrivateRegularFile(stateURL),
               let data = try? Data(contentsOf: stateURL),
               let state = try? JSONDecoder().decode(State.self, from: data),
               state.runID == runID,
               state.commandSequence == 0,
               state.phase == "loadingModel",
               !FileManager.default.fileExists(atPath: acceptedDirectory.appendingPathComponent("command.json").path) {
                return true
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return false
    }

    init(directory: URL) {
        self.directory = directory
        runID = String(directory.lastPathComponent.dropFirst("whispermax-live-capture-".count)).lowercased()
    }

    func start(controller: AppController) {
        self.controller = controller
        pollingTask = Task { [weak self] in
            await self?.pollForCommands()
        }
    }

    func stop() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func pollForCommands() async {
        while !Task.isCancelled {
            guard let controller else { return }
            if let command = readCommand(), command.sequence > lastCommandSequence {
                handle(command, controller: controller)
            }
            publishState(for: controller.phase)
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    private func readCommand() -> Command? {
        let url = directory.appendingPathComponent("command.json")
        guard isPrivateRegularFile(url),
              let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size <= 4096,
              let data = try? Data(contentsOf: url) else {
            return nil
        }

        guard let command = try? JSONDecoder().decode(Command.self, from: data),
              command.runID == runID,
              command.sequence > 0 else {
            return nil
        }
        return command
    }

    private func handle(_ command: Command, controller: AppController) {
        lastCommandSequence = command.sequence
        commandIssue = nil

        switch command.action {
        case .start:
            guard controller.phase == .ready || controller.phase.isInsertedPhase || controller.phase.isErrorPhase else {
                commandStatus = "rejected"
                commandIssue = "startRequiresReady"
                publishState(for: controller.phase, force: true)
                return
            }
            commandStatus = "accepted"
            Task { @MainActor [weak controller] in
                await controller?.toggleRecording()
            }

        case .stop:
            guard controller.phase == .recording else {
                commandStatus = "rejected"
                commandIssue = "stopRequiresRecording"
                publishState(for: controller.phase, force: true)
                return
            }
            commandStatus = "accepted"
            Task { @MainActor [weak controller] in
                await controller?.toggleRecording()
            }

        case .cancel:
            commandStatus = "accepted"
            controller.cancelRecording()

        }

        publishState(for: controller.phase, force: true)
    }

    private func publishState(for phase: RecordingPhase, force: Bool = false) {
        let phaseName: String
        let insertionMethod: String?
        let issue: String?
        switch phase {
        case .loadingModel:
            phaseName = "loadingModel"
            insertionMethod = nil
            issue = nil
        case .ready:
            phaseName = "ready"
            insertionMethod = nil
            issue = nil
        case .starting:
            phaseName = "starting"
            insertionMethod = nil
            issue = nil
        case .cancellingStart:
            phaseName = "cancellingStart"
            insertionMethod = nil
            issue = nil
        case .recording:
            phaseName = "recording"
            insertionMethod = nil
            issue = nil
        case .transcribing:
            phaseName = "transcribing"
            insertionMethod = nil
            issue = nil
        case .inserted(let method):
            phaseName = "inserted"
            insertionMethod = method.rawValue
            issue = nil
        case .error(let recorderIssue):
            phaseName = "error"
            insertionMethod = nil
            issue = Self.issueCode(for: recorderIssue)
        }

        let capturedInsertionTargetBundleIdentifier = controller?.debugCapturedInsertionTargetBundleIdentifier
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let signature = "\(lastCommandSequence):\(commandStatus):\(phaseName):\(insertionMethod ?? ""):\(issue ?? commandIssue ?? ""):\(capturedInsertionTargetBundleIdentifier ?? ""):\(frontmostBundleIdentifier ?? "")"
        guard force || signature != lastPublishedState else { return }
        lastPublishedState = signature

        let state = State(
            runID: runID,
            commandSequence: lastCommandSequence,
            commandStatus: commandStatus,
            phase: phaseName,
            insertionMethod: insertionMethod,
            issue: issue ?? commandIssue,
            capturedInsertionTargetBundleIdentifier: capturedInsertionTargetBundleIdentifier,
            frontmostBundleIdentifier: frontmostBundleIdentifier
        )
        guard let data = try? JSONEncoder().encode(state) else { return }

        let stateURL = directory.appendingPathComponent("state.json")
        do {
            try data.write(to: stateURL, options: .atomic)
            _ = chmod(stateURL.path, 0o600)
        } catch {
            NSLog("WhisperMax debug capture smoke could not write its state file.")
        }
    }

    private static func issueCode(for issue: RecorderIssue) -> String {
        switch issue {
        case .microphonePermissionRequired:
            return "microphonePermissionRequired"
        case .noSpeechDetected:
            return "noSpeechDetected"
        case .speechDetectionUnavailable:
            return "speechDetectionUnavailable"
        case .recordingStartFailed:
            return "recordingStartFailed"
        case .generic:
            return "generic"
        }
    }

    private static func isPrivateDirectory(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
        return info.st_uid == getuid()
            && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR)
            && (info.st_mode & 0o077) == 0
    }

    private static func isAbsent(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { path in
            if lstat(path, &info) == 0 { return false }
            return errno == ENOENT
        }
    }

    private func isPrivateRegularFile(_ url: URL) -> Bool {
        var info = stat()
        guard url.path.withCString({ lstat($0, &info) }) == 0 else { return false }
        return info.st_uid == getuid()
            && (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG)
            && (info.st_mode & 0o077) == 0
    }
}
#endif
