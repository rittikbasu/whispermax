import Foundation
import whisper

actor WhisperEngine {
    enum EngineError: LocalizedError {
        case initializationFailed
        case transcriptionFailed

        var errorDescription: String? {
            switch self {
            case .initializationFailed:
                return "Whisper could not initialize the local model."
            case .transcriptionFailed:
                return "Whisper failed to process the recording."
            }
        }
    }

    private let modelURL: URL
    private var context: OpaquePointer?

    init(modelURL: URL) {
        self.modelURL = modelURL
    }

    func prepare() throws {
        guard context == nil else {
            return
        }

        var parameters = whisper_context_default_params()
        parameters.flash_attn = true

        guard let context = whisper_init_from_file_with_params(modelURL.path, parameters) else {
            throw EngineError.initializationFailed
        }

        self.context = context
    }

    func transcribe(audioURL: URL) throws -> String {
        try prepare()

        guard let context else {
            throw EngineError.initializationFailed
        }

        let samples = try decodePCM16WaveFile(audioURL)
        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))

        var fullParams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let status: Int32 = "en".withCString { language in
            fullParams.print_realtime = false
            fullParams.print_progress = false
            fullParams.print_timestamps = false
            fullParams.print_special = false
            fullParams.translate = false
            fullParams.language = language
            fullParams.n_threads = Int32(maxThreads)
            fullParams.offset_ms = 0
            fullParams.no_context = true
            fullParams.single_segment = false
            fullParams.no_timestamps = true

            whisper_reset_timings(context)

            return samples.withUnsafeBufferPointer { buffer in
                whisper_full(context, fullParams, buffer.baseAddress, Int32(buffer.count))
            }
        }

        guard status == 0 else {
            throw EngineError.transcriptionFailed
        }

        let segmentCount = whisper_full_n_segments(context)
        var transcript = ""

        for index in 0..<segmentCount {
            transcript += String(cString: whisper_full_get_segment_text(context, index))
        }

        return transcript
    }
}

private func decodePCM16WaveFile(_ url: URL) throws -> [Float] {
    let data = try Data(contentsOf: url)
    guard data.count > 44 else {
        return []
    }

    return stride(from: 44, to: data.count, by: 2).map { index in
        data[index..<(index + 2)].withUnsafeBytes { rawBuffer in
            let value = Int16(littleEndian: rawBuffer.load(as: Int16.self))
            return max(-1.0, min(Float(value) / 32767.0, 1.0))
        }
    }
}
