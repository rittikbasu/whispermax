import Foundation
import CoreML
import PhononCoreML

actor PhononCoreMLEngine {
    private enum EngineError: LocalizedError {
        case notPrepared

        var errorDescription: String? {
            switch self {
            case .notPrepared:
                return "Phonon is not ready to transcribe."
            }
        }
    }

    private let modelURL: URL
    private var transcriber: Transcriber?

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    func prepare() async throws {
        guard transcriber == nil else { return }
        try Task.checkCancellation()

        var options = Transcriber.Options()
        options.computeUnits = .cpuAndNeuralEngine
        options.functions = [10]
        options.eagerFunctions = [10]
        // Phonon's mel window adds 20 ms before selecting the encoder function.
        options.singleShotMaxSeconds = 9.98
        options.windowSeconds = 10

        let candidate = try Transcriber(bundle: modelURL, options: options)
        try Task.checkCancellation()
        _ = try candidate.transcribe(Self.warmUpSamples)
        try Task.checkCancellation()
        transcriber = candidate
    }

    private static let warmUpSamples: [Float] = {
        let sampleRate = 16_000.0
        let duration = 1.0
        let sampleCount = Int(sampleRate * duration)
        return (0..<sampleCount).map { index in
            let time = Double(index) / sampleRate
            let fundamental = sin(2 * .pi * 180 * time)
            let harmonic = sin(2 * .pi * 360 * time) * 0.35
            return Float((fundamental + harmonic) * 0.08)
        }
    }()

    func transcribe(url: URL) async throws -> (text: String, inferenceDuration: TimeInterval) {
        try Task.checkCancellation()
        guard let transcriber else { throw EngineError.notPrepared }

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let result = try transcriber.transcribe(url: url)
        try Task.checkCancellation()
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startedAt) / 1_000_000_000

        return (
            text: result.text,
            inferenceDuration: elapsed
        )
    }

    func shutdown() async {
        transcriber = nil
    }
}
