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
    case phononCoreML(PhononCoreMLConfiguration)
    case invalid(String)

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        bundle: Bundle = .main
    ) -> TranscriptionBackendSelection {
        guard let backend = environment["WHISPERMAX_ASR_BACKEND"] else {
            return .whisper
        }
        switch backend {
        case "qwen-1.7b-8bit":
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
        case "phonon-coreml-10s":
            guard let modelPath = environment["WHISPERMAX_PHONON_MODEL"] else {
                return .invalid("The Phonon prototype is missing its local model path.")
            }

            let modelURL = URL(fileURLWithPath: modelPath).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard
                FileManager.default.fileExists(atPath: modelURL.path, isDirectory: &isDirectory),
                isDirectory.boolValue,
                FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("manifest.json").path),
                FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("decoder.bin").path),
                FileManager.default.fileExists(atPath: modelURL.appendingPathComponent("Phonon-2.mlpackage", isDirectory: true).path)
            else {
                return .invalid("The Phonon prototype model folder is unavailable or incomplete.")
            }

            return .phononCoreML(PhononCoreMLConfiguration(modelURL: modelURL))
        default:
            return .invalid("Unknown experimental ASR backend.")
        }
    }

    var usesOriginalAudio: Bool {
        switch self {
        case .qwen, .phononCoreML:
            return true
        case .whisper, .invalid:
            return false
        }
    }

    var requiresSpeechGate: Bool {
        usesOriginalAudio
    }

    var setupError: String? {
        if case .invalid(let message) = self { return message }
        return nil
    }
}
