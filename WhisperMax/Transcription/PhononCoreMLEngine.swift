import Foundation
import CoreML
import PhononCoreML

struct PhononCoreMLConfiguration: Sendable {
    let modelURL: URL
}

actor PhononCoreMLEngine: SpeechTranscriptionEngine {
    private enum EngineError: LocalizedError {
        case notPrepared
        case originalAudioRequired

        var errorDescription: String? {
            switch self {
            case .notPrepared:
                return "Phonon is not ready to transcribe."
            case .originalAudioRequired:
                return "Phonon requires the original audio recording."
            }
        }
    }

    private let configuration: PhononCoreMLConfiguration
    private var transcriber: Transcriber?

    init(configuration: PhononCoreMLConfiguration) {
        self.configuration = configuration
    }

    func prepare() async throws {
        guard transcriber == nil else { return }
        try Task.checkCancellation()

        var options = Transcriber.Options()
        options.computeUnits = .cpuAndNeuralEngine
        options.functions = [10]
        options.eagerFunctions = [10]
        options.singleShotMaxSeconds = 10
        options.windowSeconds = 10

        let candidate = try Transcriber(bundle: configuration.modelURL, options: options)
        try Task.checkCancellation()
        _ = try candidate.transcribe([Float](repeating: 0, count: 10 * 16_000))
        try Task.checkCancellation()
        transcriber = candidate
    }

    func transcribe(
        input: SpeechTranscriptionInput,
        prompt _: String?,
        includeTokenDiagnostics _: Bool,
        maxTokens _: Int
    ) async throws -> SpeechTranscriptionOutput {
        try Task.checkCancellation()
        guard let transcriber else { throw EngineError.notPrepared }
        guard case .originalAudio(let url) = input else { throw EngineError.originalAudioRequired }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let result = try transcriber.transcribe(url: url)
        try Task.checkCancellation()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000

        return SpeechTranscriptionOutput(
            text: result.text,
            whisperDiagnostics: nil,
            inferenceDuration: elapsed
        )
    }

    func shutdown() async {
        transcriber = nil
    }
}
