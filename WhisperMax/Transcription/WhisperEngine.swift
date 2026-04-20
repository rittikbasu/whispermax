import Foundation
import whisper

struct TranscriptionResult {
    let text: String
    let averageNoSpeechProbability: Float
    let maxNoSpeechProbability: Float
    let segmentCount: Int
    let averageTokenProbability: Float
    let evaluatedTokenCount: Int
}

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

    func transcribe(audioURL: URL, prompt: String? = nil) throws -> String {
        let samples = try AudioSampleDecoder.decodeWhisperSamples(from: audioURL)
        return try transcribe(samples: samples, prompt: prompt)
    }

    func transcribe(samples: [Float], prompt: String? = nil) throws -> String {
        try transcribeResult(samples: samples, prompt: prompt).text
    }

    func transcribeResult(samples: [Float], prompt: String? = nil) throws -> TranscriptionResult {
        try prepare()

        guard let context else {
            throw EngineError.initializationFailed
        }

        let maxThreads = max(1, min(8, ProcessInfo.processInfo.processorCount - 2))
        let transcriptionPrompt = prompt?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var fullParams = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)

        let status: Int32 = (transcriptionPrompt ?? "").withCString { promptCString in
            "en".withCString { language in
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
                fullParams.initial_prompt = transcriptionPrompt?.isEmpty == false ? promptCString : nil
                fullParams.carry_initial_prompt = transcriptionPrompt?.isEmpty == false

                whisper_reset_timings(context)

                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, fullParams, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }

        guard status == 0 else {
            throw EngineError.transcriptionFailed
        }

        let segmentCount = whisper_full_n_segments(context)
        var transcript = ""
        var noSpeechProbabilities: [Float] = []
        var tokenProbabilitySum: Float = 0
        var evaluatedTokenCount = 0

        for index in 0..<segmentCount {
            transcript += String(cString: whisper_full_get_segment_text(context, index))
            noSpeechProbabilities.append(
                whisper_full_get_segment_no_speech_prob(context, index)
            )

            let tokenCount = whisper_full_n_tokens(context, index)
            guard tokenCount > 0 else {
                continue
            }

            for tokenIndex in 0..<tokenCount {
                let tokenText = String(cString: whisper_full_get_token_text(context, index, tokenIndex))
                guard !tokenText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                tokenProbabilitySum += whisper_full_get_token_p(context, index, tokenIndex)
                evaluatedTokenCount += 1
            }
        }

        let averageNoSpeechProbability = noSpeechProbabilities.isEmpty
            ? 0
            : noSpeechProbabilities.reduce(0, +) / Float(noSpeechProbabilities.count)
        let averageTokenProbability = evaluatedTokenCount == 0
            ? 0
            : tokenProbabilitySum / Float(evaluatedTokenCount)

        return TranscriptionResult(
            text: transcript,
            averageNoSpeechProbability: averageNoSpeechProbability,
            maxNoSpeechProbability: noSpeechProbabilities.max() ?? 0,
            segmentCount: Int(segmentCount),
            averageTokenProbability: averageTokenProbability,
            evaluatedTokenCount: evaluatedTokenCount
        )
    }
}
