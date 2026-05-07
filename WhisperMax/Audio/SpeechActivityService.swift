import Foundation
import whisper

struct SpeechChunk: Sendable {
    let samples: [Float]
    let startSample: Int
    let endSample: Int
    let overlapLeadSamples: Int
    let overlapTrailSamples: Int

    var duration: TimeInterval {
        Double(endSample - startSample) / AudioSampleDecoder.targetSampleRate
    }
}

struct SpeechRegion: Sendable {
    let startSample: Int
    let endSample: Int
    let maxProbability: Float
    let meanProbability: Float

    var duration: TimeInterval {
        Double(endSample - startSample) / AudioSampleDecoder.targetSampleRate
    }
}

struct SpeechActivityDiagnostics: Sendable {
    enum Mode: String, Sendable {
        case bypass
        case noSpeech
        case shortFallback
        case singlePass
        case chunked
    }

    let mode: Mode
    let originalDuration: TimeInterval
    let speechRegions: [SpeechRegion]
    let totalSpeechDuration: TimeInterval
    let selectedDuration: TimeInterval
}

enum PreparedTranscriptionAudio {
    case noSpeech(SpeechActivityDiagnostics)
    case singlePass(samples: [Float], diagnostics: SpeechActivityDiagnostics)
    case chunked(chunks: [SpeechChunk], diagnostics: SpeechActivityDiagnostics)
}

extension PreparedTranscriptionAudio {
    var diagnostics: SpeechActivityDiagnostics {
        switch self {
        case .noSpeech(let diagnostics),
                .singlePass(_, let diagnostics),
                .chunked(_, let diagnostics):
            return diagnostics
        }
    }

    var debugChunkPlans: [DebugRecordingChunkPlan] {
        switch self {
        case .chunked(let chunks, _):
            return chunks.map {
                DebugRecordingChunkPlan(
                    startSample: $0.startSample,
                    endSample: $0.endSample,
                    overlapLeadSamples: $0.overlapLeadSamples,
                    overlapTrailSamples: $0.overlapTrailSamples
                )
            }
        case .noSpeech, .singlePass:
            return []
        }
    }
}

/// Post-stop speech activity analysis.
///
/// Design goals:
/// - VAD remains post-stop only; start/stop is still explicit.
/// - Short clips stay simple: trim once, transcribe once.
/// - Longer clips prioritize reliability over trimming: if VAD found credible speech
///   anywhere in the recording, prefer a full-buffer Whisper pass so later/softer
///   words are not lost at VAD boundaries.
/// - Chunked transcription is an extreme long-form fallback only.
/// - If VAD is unavailable, fall back to a single-pass whisper decode instead of blocking.
final class SpeechActivityService {
    private enum Tuning {
        static let minSpeechDurationMS = 90.0
        static let minSilenceDurationMS = 500.0
        static let internalSpeechPadMS = 100.0
        static let mergeGapMS = 320.0
        static let segmentThreshold: Float = 0.20
        static let maxSpeechDurationS: Float = 3_600.0

        static let trimmedSinglePassMaxDurationS = 12.0
        static let shortUtteranceFallbackMaxDurationS = 4.0
        static let shortFormLeadingPadS = 0.75
        static let shortFormTrailingPadS = 0.95
        static let minSinglePassSecondsForSpeech = 0.15

        static let fullClipSinglePassMaxDurationS = 180.0

        static let maxIntraChunkGapS = 3.50
        static let targetChunkDurationS = 24.0
        static let maxChunkDurationS = 32.0
        static let minChunkDurationS = 6.0
        static let chunkOverlapS = 1.20
        static let firstChunkLeadingPadS = 0.60
        static let lastChunkTrailingPadS = 0.90
        static let longRegionSplitStrideS = targetChunkDurationS - chunkOverlapS
    }

    private struct ChunkWindow {
        let baseStartSample: Int
        let baseEndSample: Int
    }

    private let modelURL: URL?
    private var vadContext: OpaquePointer?
    private var hasAttemptedContextLoad = false

    init(modelURL: URL? = ModelLocator.bundledVADModelURL()) {
        self.modelURL = modelURL
    }

    deinit {
        if let vadContext {
            whisper_vad_free(vadContext)
        }
    }

    func prepareTranscriptionAudio(from audioURL: URL) throws -> PreparedTranscriptionAudio {
        let samples = try AudioSampleDecoder.decodeWhisperSamples(from: audioURL)
        return prepareTranscriptionAudio(from: samples)
    }

    func prepareTranscriptionAudio(from samples: [Float]) -> PreparedTranscriptionAudio {
        guard !samples.isEmpty else {
            return .noSpeech(diagnostics(
                mode: .noSpeech,
                originalSampleCount: 0,
                regions: [],
                selectedSampleCount: 0
            ))
        }

        guard let vadContext = loadContextIfPossible() else {
            return .singlePass(
                samples: samples,
                diagnostics: diagnostics(
                    mode: .bypass,
                    originalSampleCount: samples.count,
                    regions: [],
                    selectedSampleCount: samples.count
                )
            )
        }

        let probabilities = detectSpeechProbabilities(context: vadContext, samples: samples)

        guard let rawRegions = buildSpeechRegions(
            context: vadContext,
            samples: samples,
            probabilities: probabilities
        ) else {
            return .singlePass(
                samples: samples,
                diagnostics: diagnostics(
                    mode: .bypass,
                    originalSampleCount: samples.count,
                    regions: [],
                    selectedSampleCount: samples.count
                )
            )
        }

        let mergedRegions = mergeAdjacentRegions(rawRegions)

        guard !mergedRegions.isEmpty else {
            if shouldUseShortUtteranceFallback(for: samples.count) {
                return .singlePass(
                    samples: samples,
                    diagnostics: diagnostics(
                        mode: .shortFallback,
                        originalSampleCount: samples.count,
                        regions: [],
                        selectedSampleCount: samples.count
                    )
                )
            }

            return .noSpeech(diagnostics(
                mode: .noSpeech,
                originalSampleCount: samples.count,
                regions: [],
                selectedSampleCount: 0
            ))
        }

        if shouldUseTrimmedSinglePass(for: samples.count) {
            let window = singlePassWindow(for: mergedRegions, sampleCount: samples.count)
            let trimmedDuration = Double(window.endSample - window.startSample) / AudioSampleDecoder.targetSampleRate
            guard trimmedDuration >= Tuning.minSinglePassSecondsForSpeech else {
                return .noSpeech(diagnostics(
                    mode: .noSpeech,
                    originalSampleCount: samples.count,
                    regions: mergedRegions,
                    selectedSampleCount: 0
                ))
            }

            return .singlePass(
                samples: Array(samples[window.startSample..<window.endSample]),
                diagnostics: diagnostics(
                    mode: .singlePass,
                    originalSampleCount: samples.count,
                    regions: mergedRegions,
                    selectedSampleCount: window.endSample - window.startSample
                )
            )
        }

        if shouldUseFullClipSinglePass(for: samples.count) {
            return .singlePass(
                samples: samples,
                diagnostics: diagnostics(
                    mode: .singlePass,
                    originalSampleCount: samples.count,
                    regions: mergedRegions,
                    selectedSampleCount: samples.count
                )
            )
        }

        let chunks = buildChunks(from: mergedRegions, sampleCount: samples.count, samples: samples)
        guard !chunks.isEmpty else {
            return .noSpeech(diagnostics(
                mode: .noSpeech,
                originalSampleCount: samples.count,
                regions: mergedRegions,
                selectedSampleCount: 0
            ))
        }

        let selectedSampleCount = chunks.reduce(0) { $0 + ($1.endSample - $1.startSample) }
        return .chunked(
            chunks: chunks,
            diagnostics: diagnostics(
                mode: .chunked,
                originalSampleCount: samples.count,
                regions: mergedRegions,
                selectedSampleCount: selectedSampleCount
            )
        )
    }

    private func detectSpeechProbabilities(context: OpaquePointer, samples: [Float]) -> [Float]? {
        let status = samples.withUnsafeBufferPointer { buffer in
            whisper_vad_detect_speech(context, buffer.baseAddress, Int32(buffer.count))
        }

        guard status else {
            return nil
        }

        let count = Int(whisper_vad_n_probs(context))
        guard count > 0, let pointer = whisper_vad_probs(context) else {
            return nil
        }

        return Array(UnsafeBufferPointer(start: pointer, count: count))
    }

    private func buildSpeechRegions(
        context: OpaquePointer,
        samples: [Float],
        probabilities: [Float]?
    ) -> [SpeechRegion]? {
        guard !samples.isEmpty else {
            return []
        }

        var params = whisper_vad_default_params()
        params.threshold = Tuning.segmentThreshold
        params.min_speech_duration_ms = Int32(Tuning.minSpeechDurationMS)
        params.min_silence_duration_ms = Int32(Tuning.minSilenceDurationMS)
        params.max_speech_duration_s = Tuning.maxSpeechDurationS
        params.speech_pad_ms = Int32(Tuning.internalSpeechPadMS)
        params.samples_overlap = 0

        guard let segments = samples.withUnsafeBufferPointer({ buffer in
            whisper_vad_segments_from_samples(context, params, buffer.baseAddress, Int32(buffer.count))
        }) else {
            return nil
        }
        defer {
            whisper_vad_free_segments(segments)
        }

        let count = whisper_vad_segments_n_segments(segments)
        guard count > 0 else {
            return []
        }

        let samplesPerProbabilityFrame: Double? = {
            guard let probabilities, !probabilities.isEmpty else {
                return nil
            }
            return Double(samples.count) / Double(probabilities.count)
        }()

        var regions: [SpeechRegion] = []
        regions.reserveCapacity(Int(count))

        for index in 0..<count {
            let startTimeSeconds = Double(whisper_vad_segments_get_segment_t0(segments, index)) / 100.0
            let endTimeSeconds = Double(whisper_vad_segments_get_segment_t1(segments, index)) / 100.0
            let startSample = max(0, min(samples.count, Int((startTimeSeconds * AudioSampleDecoder.targetSampleRate).rounded(.down))))
            let endSample = max(startSample, min(samples.count, Int((endTimeSeconds * AudioSampleDecoder.targetSampleRate).rounded(.up))))
            guard endSample > startSample else {
                continue
            }

            let probabilityWindow: ArraySlice<Float> = {
                guard
                    let probabilities,
                    let samplesPerProbabilityFrame,
                    samplesPerProbabilityFrame > 0
                else {
                    return []
                }

                let frameStart = max(0, min(probabilities.count - 1, Int(floor(Double(startSample) / samplesPerProbabilityFrame))))
                let frameEnd = max(frameStart + 1, min(probabilities.count, Int(ceil(Double(endSample) / samplesPerProbabilityFrame))))
                return probabilities[frameStart..<frameEnd]
            }()

            let meanProbability = probabilityWindow.isEmpty
                ? 0
                : probabilityWindow.reduce(0, +) / Float(probabilityWindow.count)
            let maxProbability = probabilityWindow.max() ?? 0

            regions.append(
                SpeechRegion(
                    startSample: startSample,
                    endSample: endSample,
                    maxProbability: maxProbability,
                    meanProbability: meanProbability
                )
            )
        }

        return regions
    }

    private func mergeAdjacentRegions(_ regions: [SpeechRegion]) -> [SpeechRegion] {
        guard !regions.isEmpty else {
            return []
        }

        let mergeGapSamples = Int(Tuning.mergeGapMS / 1000 * AudioSampleDecoder.targetSampleRate)
        var merged: [SpeechRegion] = []

        for region in regions {
            guard let previous = merged.last else {
                merged.append(region)
                continue
            }

            if region.startSample - previous.endSample <= mergeGapSamples {
                let newDuration = Double(max(region.endSample - previous.startSample, 1))
                let previousDuration = Double(previous.endSample - previous.startSample)
                let currentDuration = Double(region.endSample - region.startSample)
                let weightedMean = Float(
                    ((Double(previous.meanProbability) * previousDuration)
                        + (Double(region.meanProbability) * currentDuration)) / newDuration
                )

                merged[merged.count - 1] = SpeechRegion(
                    startSample: previous.startSample,
                    endSample: max(previous.endSample, region.endSample),
                    maxProbability: max(previous.maxProbability, region.maxProbability),
                    meanProbability: weightedMean
                )
            } else {
                merged.append(region)
            }
        }

        return merged
    }

    private func shouldUseTrimmedSinglePass(for sampleCount: Int) -> Bool {
        let originalDuration = Double(sampleCount) / AudioSampleDecoder.targetSampleRate
        return originalDuration <= Tuning.trimmedSinglePassMaxDurationS
    }

    private func shouldUseShortUtteranceFallback(for sampleCount: Int) -> Bool {
        let originalDuration = Double(sampleCount) / AudioSampleDecoder.targetSampleRate
        return originalDuration <= Tuning.shortUtteranceFallbackMaxDurationS
    }

    private func shouldUseFullClipSinglePass(for sampleCount: Int) -> Bool {
        let originalDuration = Double(sampleCount) / AudioSampleDecoder.targetSampleRate
        return originalDuration <= Tuning.fullClipSinglePassMaxDurationS
    }

    private func singlePassWindow(for regions: [SpeechRegion], sampleCount: Int) -> (startSample: Int, endSample: Int) {
        guard let first = regions.first, let last = regions.last else {
            return (0, sampleCount)
        }

        let leadingPadSamples = Int(Tuning.shortFormLeadingPadS * AudioSampleDecoder.targetSampleRate)
        let trailingPadSamples = Int(Tuning.shortFormTrailingPadS * AudioSampleDecoder.targetSampleRate)

        let startSample = max(0, first.startSample - leadingPadSamples)
        let endSample = min(sampleCount, last.endSample + trailingPadSamples)
        return (startSample, max(startSample, endSample))
    }

    private func buildChunks(from regions: [SpeechRegion], sampleCount: Int, samples: [Float]) -> [SpeechChunk] {
        let targetChunkSamples = Int(Tuning.targetChunkDurationS * AudioSampleDecoder.targetSampleRate)
        let maxChunkSamples = Int(Tuning.maxChunkDurationS * AudioSampleDecoder.targetSampleRate)
        let minChunkSamples = Int(Tuning.minChunkDurationS * AudioSampleDecoder.targetSampleRate)
        let maxIntraChunkGapSamples = Int(Tuning.maxIntraChunkGapS * AudioSampleDecoder.targetSampleRate)
        let overlapSamples = Int(Tuning.chunkOverlapS * AudioSampleDecoder.targetSampleRate)
        let firstChunkLeadingPadSamples = Int(Tuning.firstChunkLeadingPadS * AudioSampleDecoder.targetSampleRate)
        let lastChunkTrailingPadSamples = Int(Tuning.lastChunkTrailingPadS * AudioSampleDecoder.targetSampleRate)
        let longRegionSplitStrideSamples = max(1, Int(Tuning.longRegionSplitStrideS * AudioSampleDecoder.targetSampleRate))

        var windows: [ChunkWindow] = []
        var index = 0

        while index < regions.count {
            let region = regions[index]
            let regionDurationSamples = region.endSample - region.startSample

            if regionDurationSamples > maxChunkSamples {
                var chunkStart = region.startSample
                while chunkStart < region.endSample {
                    let chunkEnd = min(region.endSample, chunkStart + targetChunkSamples)
                    windows.append(ChunkWindow(baseStartSample: chunkStart, baseEndSample: chunkEnd))
                    if chunkEnd >= region.endSample {
                        break
                    }
                    chunkStart = max(chunkStart + longRegionSplitStrideSamples, chunkStart + 1)
                }
                index += 1
                continue
            }

            let chunkStart = region.startSample
            var chunkEnd = region.endSample
            var nextIndex = index + 1

            while nextIndex < regions.count {
                let nextRegion = regions[nextIndex]
                let gapSamples = nextRegion.startSample - chunkEnd
                let proposedSpan = nextRegion.endSample - chunkStart

                if gapSamples > maxIntraChunkGapSamples {
                    break
                }

                if proposedSpan <= targetChunkSamples {
                    chunkEnd = nextRegion.endSample
                    nextIndex += 1
                    continue
                }

                if proposedSpan <= maxChunkSamples && (chunkEnd - chunkStart) < minChunkSamples {
                    chunkEnd = nextRegion.endSample
                    nextIndex += 1
                    continue
                }

                break
            }

            windows.append(ChunkWindow(baseStartSample: chunkStart, baseEndSample: chunkEnd))
            index = nextIndex
        }

        guard !windows.isEmpty else {
            return []
        }

        return windows.enumerated().compactMap { offset, window in
            let isFirst = offset == 0
            let isLast = offset == windows.count - 1

            let startSample = isFirst
                ? max(0, window.baseStartSample - firstChunkLeadingPadSamples)
                : max(0, window.baseStartSample - overlapSamples)
            let endSample = isLast
                ? min(sampleCount, window.baseEndSample + lastChunkTrailingPadSamples)
                : min(sampleCount, window.baseEndSample + overlapSamples)

            guard endSample > startSample else {
                return nil
            }

            let overlapLeadSamples = window.baseStartSample - startSample
            let overlapTrailSamples = endSample - window.baseEndSample

            return SpeechChunk(
                samples: Array(samples[startSample..<endSample]),
                startSample: startSample,
                endSample: endSample,
                overlapLeadSamples: overlapLeadSamples,
                overlapTrailSamples: overlapTrailSamples
            )
        }
    }

    private func diagnostics(
        mode: SpeechActivityDiagnostics.Mode,
        originalSampleCount: Int,
        regions: [SpeechRegion],
        selectedSampleCount: Int
    ) -> SpeechActivityDiagnostics {
        SpeechActivityDiagnostics(
            mode: mode,
            originalDuration: Double(originalSampleCount) / AudioSampleDecoder.targetSampleRate,
            speechRegions: regions,
            totalSpeechDuration: regions.reduce(0) { $0 + $1.duration },
            selectedDuration: Double(selectedSampleCount) / AudioSampleDecoder.targetSampleRate
        )
    }

    private func loadContextIfPossible() -> OpaquePointer? {
        if let vadContext {
            return vadContext
        }

        guard !hasAttemptedContextLoad else {
            return nil
        }

        hasAttemptedContextLoad = true

        guard let modelURL else {
            return nil
        }

        var params = whisper_vad_default_context_params()
        params.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.processorCount - 1)))
        params.use_gpu = false
        params.gpu_device = 0

        vadContext = whisper_vad_init_from_file_with_params(modelURL.path, params)
        return vadContext
    }
}
