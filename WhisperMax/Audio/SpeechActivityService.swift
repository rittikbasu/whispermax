import Foundation
import whisper

struct SpeechActivityAnalysis {
    enum Confidence {
        case confident
        case borderline
    }

    let confidence: Confidence
    let maxProbability: Float
    let meanSpeechProbability: Float
    let probabilityStandardDeviation: Float
    let dynamicRangeDB: Float
    let strongFrameCount: Int
    let segmentCount: Int
    let voicedRatio: Float
    let vadAvailable: Bool
}

enum PreparedTranscriptionAudio {
    case noSpeech(SpeechActivityAnalysis)
    case ready(samples: [Float], analysis: SpeechActivityAnalysis)
}

final class SpeechActivityService {
    private enum Tuning {
        static let enterThreshold: Float = 0.58
        static let exitThreshold: Float = 0.42
        static let strongProbabilityThreshold: Float = 0.74
        static let confidentMaxProbabilityThreshold: Float = 0.70
        static let borderlineMaxProbabilityThreshold: Float = 0.63

        static let minSpeechFrames = 3
        static let minSilenceFrames = 9
        static let padFrames = 5

        static let confidentMinStrongFrames = 4
        static let confidentMinProbabilityStdDev: Float = 0.08
        static let confidentMinDynamicRangeDB: Float = 5.5

        static let borderlineMinStrongFrames = 2
        static let borderlineMinProbabilityStdDev: Float = 0.065
        static let borderlineMinDynamicRangeDB: Float = 4.5

        static let flatNoiseMaxProbability: Float = 0.62
        static let flatNoiseMaxProbabilityStdDev: Float = 0.05
        static let flatNoiseMaxDynamicRangeDB: Float = 4.0
        static let flatNoiseMaxVoicedRatio: Float = 0.96

        static let sustainedNoiseMinVoicedRatio: Float = 0.82
        static let sustainedNoiseMaxProbabilityStdDev: Float = 0.06
        static let sustainedNoiseMaxDynamicRangeDB: Float = 4.75

        static let dynamicRangeFrameSize = 320
        static let highPassAlpha: Float = 0.985
    }

    private struct Segment {
        let startSample: Int
        let endSample: Int
    }

    private enum DetectionResult {
        case unavailable
        case probabilities([Float])
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

    func prepareTranscriptionAudio(from originalSamples: [Float]) -> PreparedTranscriptionAudio {
        let emptyAnalysis = SpeechActivityAnalysis(
            confidence: .borderline,
            maxProbability: 0,
            meanSpeechProbability: 0,
            probabilityStandardDeviation: 0,
            dynamicRangeDB: 0,
            strongFrameCount: 0,
            segmentCount: 0,
            voicedRatio: 0,
            vadAvailable: false
        )

        guard !originalSamples.isEmpty else {
            return .noSpeech(emptyAnalysis)
        }

        let analysisSamples = preprocessForVAD(originalSamples)
        let dynamicRangeDB = clipDynamicRangeDB(for: analysisSamples)

        switch detectSpeechProbabilities(in: analysisSamples) {
        case .unavailable:
            let unavailableAnalysis = SpeechActivityAnalysis(
                confidence: .borderline,
                maxProbability: 0,
                meanSpeechProbability: 0,
                probabilityStandardDeviation: 0,
                dynamicRangeDB: dynamicRangeDB,
                strongFrameCount: 0,
                segmentCount: 0,
                voicedRatio: 0,
                vadAvailable: false
            )
            return .ready(samples: originalSamples, analysis: unavailableAnalysis)

        case .probabilities(let probabilities):
            guard !probabilities.isEmpty else {
                let silentAnalysis = SpeechActivityAnalysis(
                    confidence: .borderline,
                    maxProbability: 0,
                    meanSpeechProbability: 0,
                    probabilityStandardDeviation: 0,
                    dynamicRangeDB: dynamicRangeDB,
                    strongFrameCount: 0,
                    segmentCount: 0,
                    voicedRatio: 0,
                    vadAvailable: true
                )
                return .noSpeech(silentAnalysis)
            }

            let samplesPerFrame = max(1, Int(round(Double(originalSamples.count) / Double(probabilities.count))))
            let segments = segmentsFromProbabilities(
                probabilities,
                samplesPerFrame: samplesPerFrame,
                totalSamples: originalSamples.count
            )

            let strongFrameCount = probabilities.reduce(into: 0) { count, probability in
                if probability >= Tuning.strongProbabilityThreshold {
                    count += 1
                }
            }
            let voicedFrameCount = probabilities.reduce(into: 0) { count, probability in
                if probability >= Tuning.exitThreshold {
                    count += 1
                }
            }
            let activeProbabilities = probabilities.filter { $0 >= Tuning.exitThreshold }
            let maxProbability = probabilities.max() ?? 0
            let meanSpeechProbability = activeProbabilities.isEmpty
                ? 0
                : activeProbabilities.reduce(0, +) / Float(activeProbabilities.count)
            let probabilityStandardDeviation = standardDeviation(of: probabilities)
            let voicedRatio = Float(voicedFrameCount) / Float(max(probabilities.count, 1))

            guard
                !segments.isEmpty,
                maxProbability >= Tuning.borderlineMaxProbabilityThreshold
            else {
                let noSpeechAnalysis = SpeechActivityAnalysis(
                    confidence: .borderline,
                    maxProbability: maxProbability,
                    meanSpeechProbability: meanSpeechProbability,
                    probabilityStandardDeviation: probabilityStandardDeviation,
                    dynamicRangeDB: dynamicRangeDB,
                    strongFrameCount: strongFrameCount,
                    segmentCount: segments.count,
                    voicedRatio: voicedRatio,
                    vadAvailable: true
                )
                return .noSpeech(noSpeechAnalysis)
            }

            let analysis = SpeechActivityAnalysis(
                confidence: classifyConfidence(
                    maxProbability: maxProbability,
                    probabilityStandardDeviation: probabilityStandardDeviation,
                    dynamicRangeDB: dynamicRangeDB,
                    strongFrameCount: strongFrameCount
                ),
                maxProbability: maxProbability,
                meanSpeechProbability: meanSpeechProbability,
                probabilityStandardDeviation: probabilityStandardDeviation,
                dynamicRangeDB: dynamicRangeDB,
                strongFrameCount: strongFrameCount,
                segmentCount: segments.count,
                voicedRatio: voicedRatio,
                vadAvailable: true
            )

            if shouldRejectAsNoise(analysis: analysis) {
                return .noSpeech(analysis)
            }

            let startSample = segments[0].startSample
            let endSample = segments[segments.count - 1].endSample
            guard endSample > startSample else {
                return .noSpeech(analysis)
            }

            return .ready(samples: Array(originalSamples[startSample..<endSample]), analysis: analysis)
        }
    }

    private func classifyConfidence(
        maxProbability: Float,
        probabilityStandardDeviation: Float,
        dynamicRangeDB: Float,
        strongFrameCount: Int
    ) -> SpeechActivityAnalysis.Confidence {
        if
            maxProbability >= Tuning.confidentMaxProbabilityThreshold &&
            strongFrameCount >= Tuning.confidentMinStrongFrames &&
            probabilityStandardDeviation >= Tuning.confidentMinProbabilityStdDev &&
            dynamicRangeDB >= Tuning.confidentMinDynamicRangeDB
        {
            return .confident
        }

        return .borderline
    }

    private func shouldRejectAsNoise(analysis: SpeechActivityAnalysis) -> Bool {
        if
            analysis.maxProbability <= Tuning.flatNoiseMaxProbability &&
            analysis.probabilityStandardDeviation <= Tuning.flatNoiseMaxProbabilityStdDev &&
            analysis.dynamicRangeDB <= Tuning.flatNoiseMaxDynamicRangeDB &&
            analysis.voicedRatio <= Tuning.flatNoiseMaxVoicedRatio
        {
            return true
        }

        if
            analysis.confidence == .borderline &&
            analysis.strongFrameCount < Tuning.borderlineMinStrongFrames &&
            analysis.probabilityStandardDeviation < Tuning.borderlineMinProbabilityStdDev
        {
            return true
        }

        if
            analysis.voicedRatio >= Tuning.sustainedNoiseMinVoicedRatio &&
            analysis.probabilityStandardDeviation <= Tuning.sustainedNoiseMaxProbabilityStdDev &&
            analysis.dynamicRangeDB <= Tuning.sustainedNoiseMaxDynamicRangeDB
        {
            return true
        }

        return false
    }

    private func segmentsFromProbabilities(
        _ probabilities: [Float],
        samplesPerFrame: Int,
        totalSamples: Int
    ) -> [Segment] {
        var segments: [Segment] = []
        var inSpeech = false
        var candidateStartFrame = 0
        var speechRunFrames = 0
        var silenceRunFrames = 0
        var segmentStartFrame = 0

        for (index, probability) in probabilities.enumerated() {
            if !inSpeech {
                if probability >= Tuning.enterThreshold {
                    if speechRunFrames == 0 {
                        candidateStartFrame = index
                    }
                    speechRunFrames += 1

                    if speechRunFrames >= Tuning.minSpeechFrames {
                        inSpeech = true
                        segmentStartFrame = max(0, candidateStartFrame - Tuning.padFrames)
                        silenceRunFrames = 0
                    }
                } else {
                    speechRunFrames = 0
                }

                continue
            }

            if probability < Tuning.exitThreshold {
                silenceRunFrames += 1
                if silenceRunFrames >= Tuning.minSilenceFrames {
                    let endFrame = min(probabilities.count, index - silenceRunFrames + 1 + Tuning.padFrames)
                    appendSegment(
                        startFrame: segmentStartFrame,
                        endFrame: endFrame,
                        samplesPerFrame: samplesPerFrame,
                        totalSamples: totalSamples,
                        into: &segments
                    )

                    inSpeech = false
                    speechRunFrames = 0
                    silenceRunFrames = 0
                }
            } else {
                silenceRunFrames = 0
            }
        }

        if inSpeech {
            appendSegment(
                startFrame: segmentStartFrame,
                endFrame: probabilities.count,
                samplesPerFrame: samplesPerFrame,
                totalSamples: totalSamples,
                into: &segments
            )
        }

        return mergedSegments(segments)
    }

    private func appendSegment(
        startFrame: Int,
        endFrame: Int,
        samplesPerFrame: Int,
        totalSamples: Int,
        into segments: inout [Segment]
    ) {
        let startSample = min(totalSamples, max(0, startFrame * samplesPerFrame))
        let endSample = min(totalSamples, max(startSample, endFrame * samplesPerFrame))
        let minimumSpeechSamples = Tuning.minSpeechFrames * samplesPerFrame

        guard endSample - startSample >= minimumSpeechSamples else {
            return
        }

        segments.append(Segment(startSample: startSample, endSample: endSample))
    }

    private func mergedSegments(_ segments: [Segment]) -> [Segment] {
        guard !segments.isEmpty else {
            return []
        }

        var merged: [Segment] = [segments[0]]
        for segment in segments.dropFirst() {
            let last = merged.removeLast()
            if segment.startSample <= last.endSample {
                merged.append(
                    Segment(startSample: last.startSample, endSample: max(last.endSample, segment.endSample))
                )
            } else {
                merged.append(last)
                merged.append(segment)
            }
        }

        return merged
    }

    private func detectSpeechProbabilities(in samples: [Float]) -> DetectionResult {
        guard let vadContext = loadContextIfPossible() else {
            return .unavailable
        }

        _ = samples.withUnsafeBufferPointer { buffer in
            whisper_vad_detect_speech(vadContext, buffer.baseAddress, Int32(buffer.count))
        }

        let probabilityCount = whisper_vad_n_probs(vadContext)
        guard probabilityCount > 0, let pointer = whisper_vad_probs(vadContext) else {
            return .probabilities([])
        }

        return .probabilities(Array(UnsafeBufferPointer(start: pointer, count: Int(probabilityCount))))
    }

    private func preprocessForVAD(_ samples: [Float]) -> [Float] {
        guard !samples.isEmpty else {
            return samples
        }

        let mean = samples.reduce(0, +) / Float(samples.count)
        var result = Array(repeating: Float.zero, count: samples.count)
        var previousInput: Float = 0
        var previousOutput: Float = 0

        for index in samples.indices {
            let centered = samples[index] - mean
            let filtered = centered - previousInput + (Tuning.highPassAlpha * previousOutput)
            result[index] = filtered
            previousInput = centered
            previousOutput = filtered
        }

        return result
    }

    private func clipDynamicRangeDB(for samples: [Float]) -> Float {
        guard !samples.isEmpty else {
            return 0
        }

        var levels: [Float] = []
        var frameStart = 0

        while frameStart < samples.count {
            let frameEnd = min(frameStart + Tuning.dynamicRangeFrameSize, samples.count)
            let frame = samples[frameStart..<frameEnd]
            let frameCount = Float(frame.count)

            var sumSquares: Float = 0
            for sample in frame {
                sumSquares += sample * sample
            }

            let rms = sqrt(sumSquares / max(frameCount, 1))
            levels.append(20 * log10(max(rms, 0.000_001)))
            frameStart += Tuning.dynamicRangeFrameSize
        }

        let sortedLevels = levels.sorted()
        return percentile(in: sortedLevels, at: 0.9) - percentile(in: sortedLevels, at: 0.1)
    }

    private func standardDeviation(of values: [Float]) -> Float {
        guard values.count > 1 else {
            return 0
        }

        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(0) { partial, value in
            let delta = value - mean
            return partial + delta * delta
        } / Float(values.count)
        return sqrt(max(0, variance))
    }

    private func percentile(in sortedValues: [Float], at fraction: Float) -> Float {
        guard !sortedValues.isEmpty else {
            return 0
        }

        let clampedFraction = max(0, min(1, fraction))
        let index = Int(round(Float(sortedValues.count - 1) * clampedFraction))
        return sortedValues[index]
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

        var contextParams = whisper_vad_default_context_params()
        contextParams.n_threads = Int32(max(1, min(4, ProcessInfo.processInfo.processorCount - 1)))
        contextParams.use_gpu = false

        guard let vadContext = whisper_vad_init_from_file_with_params(modelURL.path, contextParams) else {
            return nil
        }

        self.vadContext = vadContext
        return vadContext
    }
}
