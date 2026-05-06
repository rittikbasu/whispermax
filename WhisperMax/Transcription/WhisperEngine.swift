import Foundation
import whisper

struct TranscriptionTokenDiagnostic: Codable, Sendable {
    let text: String
    let probability: Float
}

struct TranscriptionSegmentDiagnostic: Codable, Sendable {
    let text: String
    let noSpeechProbability: Float
    let includedInTranscript: Bool
    let averageTokenProbability: Float
    let tokens: [TranscriptionTokenDiagnostic]
}

struct TranscriptionResult: Sendable {
    let text: String
    let averageNoSpeechProbability: Float
    let maxNoSpeechProbability: Float
    let averageTokenProbability: Float
    let segmentCount: Int
    let segmentDiagnostics: [TranscriptionSegmentDiagnostic]?
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

    private static let noSpeechSegmentThreshold: Float = 0.80

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

    func transcribe(
        samples: [Float],
        prompt: String? = nil,
        includeTokenDiagnostics: Bool = false
    ) throws -> TranscriptionResult {
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

        let segmentCount = Int(whisper_full_n_segments(context))
        var transcript = ""
        var noSpeechProbabilities: [Float] = []
        var tokenProbabilitySum: Float = 0
        var evaluatedTokenCount = 0
        var segmentDiagnostics: [TranscriptionSegmentDiagnostic] = []
        if includeTokenDiagnostics {
            segmentDiagnostics.reserveCapacity(segmentCount)
        }

        for index in 0..<segmentCount {
            let noSpeechProbability = whisper_full_get_segment_no_speech_prob(context, Int32(index))
            noSpeechProbabilities.append(noSpeechProbability)
            let segmentText = String(cString: whisper_full_get_segment_text(context, Int32(index)))
            let includedInTranscript = noSpeechProbability < Self.noSpeechSegmentThreshold

            if includedInTranscript {
                transcript += segmentText
            }

            let tokenCount = Int(whisper_full_n_tokens(context, Int32(index)))
            var segmentTokens: [TranscriptionTokenDiagnostic] = []
            var segmentProbabilitySum: Float = 0
            var segmentEvaluatedTokenCount = 0
            if includeTokenDiagnostics {
                segmentTokens.reserveCapacity(tokenCount)
            }

            guard tokenCount > 0 else {
                if includeTokenDiagnostics {
                    segmentDiagnostics.append(
                        TranscriptionSegmentDiagnostic(
                            text: segmentText,
                            noSpeechProbability: noSpeechProbability,
                            includedInTranscript: includedInTranscript,
                            averageTokenProbability: 0,
                            tokens: []
                        )
                    )
                }
                continue
            }

            for tokenIndex in 0..<tokenCount {
                let tokenText = String(cString: whisper_full_get_token_text(context, Int32(index), Int32(tokenIndex)))
                let trimmedTokenText = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmedTokenText.isEmpty else {
                    continue
                }

                let tokenProbability = whisper_full_get_token_p(context, Int32(index), Int32(tokenIndex))
                tokenProbabilitySum += tokenProbability
                evaluatedTokenCount += 1
                segmentProbabilitySum += tokenProbability
                segmentEvaluatedTokenCount += 1

                if includeTokenDiagnostics {
                    segmentTokens.append(
                        TranscriptionTokenDiagnostic(
                            text: trimmedTokenText,
                            probability: tokenProbability
                        )
                    )
                }
            }

            if includeTokenDiagnostics {
                let averageSegmentTokenProbability = segmentEvaluatedTokenCount == 0
                    ? 0
                    : segmentProbabilitySum / Float(segmentEvaluatedTokenCount)

                segmentDiagnostics.append(
                    TranscriptionSegmentDiagnostic(
                        text: segmentText,
                        noSpeechProbability: noSpeechProbability,
                        includedInTranscript: includedInTranscript,
                        averageTokenProbability: averageSegmentTokenProbability,
                        tokens: segmentTokens
                    )
                )
            }
        }

        let averageNoSpeechProbability = noSpeechProbabilities.isEmpty
            ? 0
            : noSpeechProbabilities.reduce(0, +) / Float(noSpeechProbabilities.count)
        let maxNoSpeechProbability = noSpeechProbabilities.max() ?? 0
        let averageTokenProbability = evaluatedTokenCount == 0
            ? 0
            : tokenProbabilitySum / Float(evaluatedTokenCount)

        return TranscriptionResult(
            text: transcript,
            averageNoSpeechProbability: averageNoSpeechProbability,
            maxNoSpeechProbability: maxNoSpeechProbability,
            averageTokenProbability: averageTokenProbability,
            segmentCount: segmentCount,
            segmentDiagnostics: includeTokenDiagnostics ? segmentDiagnostics : nil
        )
    }
}
