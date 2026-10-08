import Foundation

enum SpeechTranscriptionInput: Sendable {
    case preparedSamples([Float])
    case originalAudio(URL)
}

struct SpeechTranscriptionOutput: Sendable {
    let text: String
    let whisperDiagnostics: TranscriptionResult?
    let inferenceDuration: TimeInterval?
}

protocol SpeechTranscriptionEngine: Actor {
    func prepare() async throws
    func transcribe(
        input: SpeechTranscriptionInput,
        prompt: String?,
        includeTokenDiagnostics: Bool,
        maxTokens: Int
    ) async throws -> SpeechTranscriptionOutput
    func shutdown() async
}

enum TranscriptionBackendSelection {
    case whisper
    case qwen(QwenMLXConfiguration)
    case invalid(String)

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> TranscriptionBackendSelection {
        guard let backend = environment["WHISPERMAX_ASR_BACKEND"] else {
            return .whisper
        }
        guard backend == "qwen-1.7b-8bit" else {
            return .invalid("Unknown experimental ASR backend.")
        }
        guard
            let pythonPath = environment["WHISPERMAX_QWEN_PYTHON"],
            let modelPath = environment["WHISPERMAX_QWEN_MODEL"],
            let workerURL = bundle.url(forResource: "qwen_mlx_worker", withExtension: "py")
        else {
            return .invalid("The Qwen prototype is missing its local runtime or model.")
        }

        let pythonURL = URL(fileURLWithPath: pythonPath).standardizedFileURL
        let modelURL = URL(fileURLWithPath: modelPath).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard
            FileManager.default.isExecutableFile(atPath: pythonURL.path),
            FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return .invalid("The Qwen prototype runtime or model path is unavailable.")
        }

        return .qwen(
            QwenMLXConfiguration(pythonURL: pythonURL, modelURL: modelURL, workerURL: workerURL)
        )
    }

    var usesQwen: Bool {
        if case .qwen = self { return true }
        return false
    }

    var setupError: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}
