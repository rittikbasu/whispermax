import Foundation
import Darwin

struct QwenMLXConfiguration: Sendable {
    let pythonURL: URL
    let modelURL: URL
    let workerURL: URL
}

actor QwenMLXEngine: SpeechTranscriptionEngine {
    private enum ProcessTerminator {
        static func terminateAndWait(_ process: Process) async -> Bool {
            guard process.isRunning else { return true }

            process.terminate()
            guard await waitForExit(process, timeout: .seconds(2)) else {
                _ = kill(process.processIdentifier, SIGKILL)
                return await waitForExit(process, timeout: .seconds(2))
            }

            return true
        }

        private static func waitForExit(_ process: Process, timeout: Duration) async -> Bool {
            let deadline = ContinuousClock.now + timeout
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(25))
            }
            return !process.isRunning
        }
    }

    private struct WorkerMessage: Decodable {
        let type: String
        let requestID: String?
        let text: String?
        let message: String?
        let inferenceSeconds: Double?

        enum CodingKeys: String, CodingKey {
            case type
            case requestID = "request_id"
            case text
            case message
            case inferenceSeconds = "inference_seconds"
        }
    }

    private struct ReadinessWaiter {
        let generation: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private struct PendingRequest {
        let generation: UUID
        let continuation: CheckedContinuation<SpeechTranscriptionOutput, Error>
    }

    private struct WorkerTermination {
        let id: UUID
        let task: Task<Bool, Never>
    }

    private enum EngineError: LocalizedError {
        case unavailable
        case workerExited(Int32)
        case invalidResponse
        case startupTimedOut
        case transcriptionTimedOut
        case worker(String)

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The Qwen transcription worker is not ready."
            case .workerExited(let status):
                return "The Qwen transcription worker stopped (\(status))."
            case .invalidResponse:
                return "The Qwen transcription worker returned an invalid response."
            case .startupTimedOut:
                return "The Qwen transcription worker did not finish loading."
            case .transcriptionTimedOut:
                return "Qwen did not finish transcribing this recording."
            case .worker(let message):
                return message
            }
        }
    }

    private let configuration: QwenMLXConfiguration
    private var process: Process?
    private var inputPipe: Pipe?
    private var outputPipe: Pipe?
    private var workerGeneration: UUID?
    private var workerTermination: WorkerTermination?
    private var readinessWaiter: ReadinessWaiter?
    private var pendingRequests: [String: PendingRequest] = [:]
    private var startupTimeoutTask: Task<Void, Never>?
    private var requestTimeoutTask: Task<Void, Never>?
    private var outputBuffer = Data()
    private var isReady = false

    init(configuration: QwenMLXConfiguration) {
        self.configuration = configuration
    }

    func prepare() async throws {
        try Task.checkCancellation()

        if let workerTermination {
            let stopped = await workerTermination.task.value
            if stopped, self.workerTermination?.id == workerTermination.id {
                self.workerTermination = nil
            }
            guard stopped else {
                throw EngineError.worker("The previous Qwen worker could not be stopped.")
            }
            try Task.checkCancellation()
        }

        if isReady, process?.isRunning == true {
            return
        }

        if let process {
            guard !process.isRunning else { throw EngineError.unavailable }
            await resetWorker()
        }

        let generation = UUID()
        let worker = Process()
        let input = Pipe()
        let output = Pipe()
        worker.executableURL = configuration.pythonURL
        worker.arguments = ["-u", configuration.workerURL.path, "--model", configuration.modelURL.path]

        var environment = [
            "HOME": NSHomeDirectory(),
            "HF_HUB_OFFLINE": "1",
            "TRANSFORMERS_OFFLINE": "1",
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "PYTHONNOUSERSITE": "1",
            "PYTHONUNBUFFERED": "1"
        ]
        let parentEnvironment = ProcessInfo.processInfo.environment
        for key in ["PATH", "TMPDIR"] {
            environment[key] = parentEnvironment[key]
        }
        worker.environment = environment
        worker.standardInput = input
        worker.standardOutput = output
        worker.standardError = FileHandle.nullDevice

        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            Task { await self?.receive(data, generation: generation) }
        }
        worker.terminationHandler = { [weak self] terminatedProcess in
            let status = terminatedProcess.terminationStatus
            Task { await self?.workerTerminated(status: status, generation: generation) }
        }

        process = worker
        inputPipe = input
        outputPipe = output
        workerGeneration = generation

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                readinessWaiter = ReadinessWaiter(generation: generation, continuation: continuation)
                startupTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(120))
                    } catch {
                        return
                    }
                    await self?.workerStartupTimedOut(generation: generation)
                }

                do {
                    try worker.run()
                } catch {
                    readinessWaiter = nil
                    startupTimeoutTask?.cancel()
                    startupTimeoutTask = nil
                    output.fileHandleForReading.readabilityHandler = nil
                    try? input.fileHandleForWriting.close()
                    try? output.fileHandleForReading.close()
                    process = nil
                    inputPipe = nil
                    outputPipe = nil
                    workerGeneration = nil
                    outputBuffer.removeAll(keepingCapacity: false)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancelPreparation(generation: generation) }
        }
    }

    func transcribe(
        input: SpeechTranscriptionInput,
        prompt: String?,
        includeTokenDiagnostics: Bool,
        maxTokens: Int
    ) async throws -> SpeechTranscriptionOutput {
        guard case .originalAudio(let audioURL) = input else {
            throw EngineError.worker("Qwen prototype requires the original recording file.")
        }

        try await prepare()
        guard
            isReady,
            process?.isRunning == true,
            let generation = workerGeneration,
            let inputPipe,
            pendingRequests.isEmpty
        else {
            throw EngineError.unavailable
        }

        let requestID = UUID().uuidString
        let boundedTokenLimit = max(1, min(maxTokens, 8_192))
        let payload: [String: Any] = [
            "type": "transcribe",
            "request_id": requestID,
            "audio_path": audioURL.path,
            "max_tokens": boundedTokenLimit
        ]
        var message = try JSONSerialization.data(withJSONObject: payload)
        message.append(0x0A)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<SpeechTranscriptionOutput, Error>) in
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }

                pendingRequests[requestID] = PendingRequest(
                    generation: generation,
                    continuation: continuation
                )
                requestTimeoutTask = Task { [weak self] in
                    do {
                        try await Task.sleep(for: .seconds(600))
                    } catch {
                        return
                    }
                    await self?.workerRequestTimedOut(requestID: requestID, generation: generation)
                }

                do {
                    try inputPipe.fileHandleForWriting.write(contentsOf: message)
                } catch {
                    requestTimeoutTask?.cancel()
                    requestTimeoutTask = nil
                    pendingRequests.removeValue(forKey: requestID)
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            Task { await self.cancel(requestID: requestID, generation: generation) }
        }
    }

    func shutdown() async {
        await resetWorker(terminate: true, pendingError: CancellationError())
    }

    private func receive(_ data: Data, generation: UUID) async {
        guard workerGeneration == generation else { return }
        outputBuffer.append(data)
        guard outputBuffer.count <= 1_048_576 else {
            await resetWorker(terminate: true, pendingError: EngineError.invalidResponse)
            return
        }

        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(WorkerMessage.self, from: line) else {
                await resetWorker(terminate: true, pendingError: EngineError.invalidResponse)
                return
            }

            switch message.type {
            case "ready":
                guard let waiter = readinessWaiter, waiter.generation == generation else {
                    await resetWorker(terminate: true, pendingError: EngineError.invalidResponse)
                    return
                }
                isReady = true
                readinessWaiter = nil
                startupTimeoutTask?.cancel()
                startupTimeoutTask = nil
                waiter.continuation.resume()
            case "startup_error":
                await resetWorker(
                    terminate: true,
                    pendingError: EngineError.worker(message.message ?? "Qwen could not load its local model.")
                )
                return
            case "result", "error":
                guard
                    let requestID = message.requestID,
                    let request = pendingRequests.removeValue(forKey: requestID),
                    request.generation == generation
                else {
                    await resetWorker(terminate: true, pendingError: EngineError.invalidResponse)
                    return
                }
                requestTimeoutTask?.cancel()
                requestTimeoutTask = nil

                if message.type == "error" {
                    request.continuation.resume(
                        throwing: EngineError.worker(message.message ?? "Qwen could not transcribe this recording.")
                    )
                } else {
                    request.continuation.resume(returning: SpeechTranscriptionOutput(
                        text: message.text ?? "",
                        whisperDiagnostics: nil,
                        inferenceDuration: message.inferenceSeconds
                    ))
                }
            default:
                await resetWorker(terminate: true, pendingError: EngineError.invalidResponse)
                return
            }
        }
    }

    private func cancelPreparation(generation: UUID) async {
        guard workerGeneration == generation, readinessWaiter != nil else { return }
        await resetWorker(terminate: true, pendingError: CancellationError())
    }

    private func workerStartupTimedOut(generation: UUID) async {
        guard workerGeneration == generation, readinessWaiter != nil else { return }
        await resetWorker(terminate: true, pendingError: EngineError.startupTimedOut)
    }

    private func cancel(requestID: String, generation: UUID) async {
        guard
            workerGeneration == generation,
            let request = pendingRequests.removeValue(forKey: requestID)
        else {
            return
        }
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil
        request.continuation.resume(throwing: CancellationError())
        await resetWorker(terminate: true)
    }

    private func workerRequestTimedOut(requestID: String, generation: UUID) async {
        guard
            workerGeneration == generation,
            let request = pendingRequests.removeValue(forKey: requestID)
        else {
            return
        }
        requestTimeoutTask = nil
        request.continuation.resume(throwing: EngineError.transcriptionTimedOut)
        await resetWorker(terminate: true)
    }

    private func workerTerminated(status: Int32, generation: UUID) async {
        guard workerGeneration == generation else { return }
        await resetWorker(pendingError: EngineError.workerExited(status))
    }

    private func resetWorker(terminate: Bool = false, pendingError: Error = EngineError.unavailable) async {
        startupTimeoutTask?.cancel()
        startupTimeoutTask = nil
        requestTimeoutTask?.cancel()
        requestTimeoutTask = nil

        if let readinessWaiter {
            self.readinessWaiter = nil
            readinessWaiter.continuation.resume(throwing: pendingError)
        }
        failPendingRequests(with: pendingError)

        let worker = process
        outputPipe?.fileHandleForReading.readabilityHandler = nil
        try? inputPipe?.fileHandleForWriting.close()
        try? outputPipe?.fileHandleForReading.close()
        process?.terminationHandler = nil
        process = nil
        inputPipe = nil
        outputPipe = nil
        workerGeneration = nil
        outputBuffer.removeAll(keepingCapacity: false)
        isReady = false

        if terminate, let worker, worker.isRunning, workerTermination == nil {
            let termination = WorkerTermination(
                id: UUID(),
                task: Task {
                    await ProcessTerminator.terminateAndWait(worker)
                }
            )
            workerTermination = termination
        }

        if terminate, let termination = workerTermination {
            let stopped = await termination.task.value
            if !stopped {
                NSLog("WhisperMax Qwen worker did not exit after SIGKILL")
            }
            if stopped, workerTermination?.id == termination.id {
                workerTermination = nil
            }
        }
    }

    private func failPendingRequests(with error: Error) {
        let requests = Array(pendingRequests.values)
        pendingRequests.removeAll()
        for request in requests {
            request.continuation.resume(throwing: error)
        }
    }
}
