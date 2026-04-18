import AVFoundation
import Foundation

final class AudioRecorderService {
    enum RecorderError: LocalizedError {
        case couldNotStartRecording

        var errorDescription: String? {
            switch self {
            case .couldNotStartRecording:
                return "Could not start recording."
            }
        }
    }

    private let stateLock = NSLock()

    private var engine: AVAudioEngine?
    private var recordingFile: AVAudioFile?
    private var recordingURL: URL?
    private var shouldDiscardCurrentRecording = false
    private var isRecording = false
    private var recordedDuration: TimeInterval = 0
    private var lastMeterEmissionTime: TimeInterval = 0
    private var ambientFloorDB: Float = -52
    private var displayedLevel: Float = 0
    private var recentRMSDB: [Float] = []

    var onMeter: (@MainActor @Sendable (Float, TimeInterval) -> Void)?
    var onFinish: (@MainActor @Sendable (URL) -> Void)?
    var onError: (@MainActor @Sendable (String) -> Void)?

    func start() throws {
        try ModelLocator.prepareDirectories()

        let url = ModelLocator.temporaryRecordingsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("caf")

        let engine = AVAudioEngine()
        let inputNode = engine.inputNode
        let hardwareFormat = inputNode.outputFormat(forBus: 0)

        guard
            hardwareFormat.channelCount > 0,
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: hardwareFormat.sampleRate,
                channels: hardwareFormat.channelCount,
                interleaved: false
            )
        else {
            throw RecorderError.couldNotStartRecording
        }

        let recordingFile = try AVAudioFile(
            forWriting: url,
            settings: inputFormat.settings,
            commonFormat: inputFormat.commonFormat,
            interleaved: inputFormat.isInterleaved
        )

        stateLock.lock()
        shouldDiscardCurrentRecording = false
        isRecording = true
        recordedDuration = 0
        lastMeterEmissionTime = 0
        ambientFloorDB = -52
        displayedLevel = 0
        recentRMSDB.removeAll(keepingCapacity: true)
        self.engine = engine
        self.recordingFile = recordingFile
        self.recordingURL = url
        stateLock.unlock()

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(
            onBus: 0,
            bufferSize: 1_024,
            format: inputFormat
        ) { [weak self] buffer, _ in
            self?.handleInputBuffer(buffer)
        }

        do {
            engine.prepare()
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            stateLock.lock()
            self.engine = nil
            self.recordingFile = nil
            self.recordingURL = nil
            self.isRecording = false
            stateLock.unlock()
            throw RecorderError.couldNotStartRecording
        }
    }

    func stop() {
        finishRecording(discard: false)
    }

    func cancel() {
        finishRecording(discard: true)
    }

    private func finishRecording(discard: Bool) {
        let engine: AVAudioEngine?

        stateLock.lock()
        guard isRecording else {
            stateLock.unlock()
            return
        }

        shouldDiscardCurrentRecording = discard
        engine = self.engine
        stateLock.unlock()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()

        let url: URL?
        let shouldDiscard: Bool

        stateLock.lock()
        url = recordingURL
        shouldDiscard = shouldDiscardCurrentRecording
        self.engine = nil
        self.recordingFile = nil
        self.recordingURL = nil
        self.shouldDiscardCurrentRecording = false
        self.isRecording = false
        self.recordedDuration = 0
        self.lastMeterEmissionTime = 0
        self.ambientFloorDB = -52
        self.displayedLevel = 0
        self.recentRMSDB.removeAll(keepingCapacity: true)
        stateLock.unlock()

        guard let url else {
            return
        }

        if shouldDiscard {
            try? FileManager.default.removeItem(at: url)
            return
        }

        Task { @MainActor [onFinish] in
            onFinish?(url)
        }
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        let metrics = Self.signalMetrics(from: buffer)
        let duration: TimeInterval
        let shouldEmitMeter: Bool
        let emittedLevel: Float

        stateLock.lock()
        guard let recordingFile else {
            stateLock.unlock()
            return
        }

        do {
            try recordingFile.write(from: buffer)
        } catch {
            stateLock.unlock()
            failRecording(message: "Recording failed.")
            return
        }

        recordedDuration += Double(buffer.frameLength) / buffer.format.sampleRate
        duration = recordedDuration
        emittedLevel = updateDisplayLevel(with: metrics)

        let now = ProcessInfo.processInfo.systemUptime
        if now - lastMeterEmissionTime >= (1.0 / 36.0) {
            lastMeterEmissionTime = now
            shouldEmitMeter = true
        } else {
            shouldEmitMeter = false
        }
        stateLock.unlock()

        guard shouldEmitMeter else {
            return
        }

        let onMeter = self.onMeter
        Task { @MainActor in
            onMeter?(emittedLevel, duration)
        }
    }

    private func failRecording(message: String) {
        let engine: AVAudioEngine?
        let recordingURL: URL?
        let onError = self.onError

        stateLock.lock()
        guard isRecording else {
            stateLock.unlock()
            Task { @MainActor in
                onError?(message)
            }
            return
        }

        engine = self.engine
        recordingURL = self.recordingURL
        self.engine = nil
        self.recordingFile = nil
        self.recordingURL = nil
        self.shouldDiscardCurrentRecording = false
        self.isRecording = false
        self.recordedDuration = 0
        self.lastMeterEmissionTime = 0
        self.ambientFloorDB = -52
        self.displayedLevel = 0
        self.recentRMSDB.removeAll(keepingCapacity: true)
        stateLock.unlock()

        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()

        if let recordingURL {
            try? FileManager.default.removeItem(at: recordingURL)
        }

        Task { @MainActor in
            onError?(message)
        }
    }

    private struct SignalMetrics {
        let rmsDB: Float
        let peakDB: Float
    }

    private func updateDisplayLevel(with metrics: SignalMetrics) -> Float {
        recentRMSDB.append(metrics.rmsDB)
        if recentRMSDB.count > 54 {
            recentRMSDB.removeFirst(recentRMSDB.count - 54)
        }

        let sortedFloorSamples = recentRMSDB.sorted()
        let percentileIndex = max(0, min(sortedFloorSamples.count - 1, Int(Double(sortedFloorSamples.count - 1) * 0.32)))
        let floorCandidate = min(max(sortedFloorSamples[percentileIndex], -66), -24)
        let floorResponsiveness: Float = floorCandidate > ambientFloorDB ? 0.30 : 0.10
        ambientFloorDB += (floorCandidate - ambientFloorDB) * floorResponsiveness

        let speechMargin: Float = 7.5
        let rmsRange: Float = 17.0
        let peakRange: Float = 22.0

        let relativeRMS = max(0, metrics.rmsDB - (ambientFloorDB + speechMargin))
        let relativePeak = max(0, metrics.peakDB - (ambientFloorDB + speechMargin + 1.5))

        let rmsComponent = pow(min(relativeRMS / rmsRange, 1), 1.22)
        let peakComponent = pow(min(relativePeak / peakRange, 1), 1.55) * 0.28
        let targetLevel = max(rmsComponent, peakComponent)

        let responsiveness: Float = targetLevel > displayedLevel ? 0.26 : 0.18
        displayedLevel += (targetLevel - displayedLevel) * responsiveness

        if displayedLevel < 0.012 {
            displayedLevel = 0
        }

        return min(displayedLevel, 1)
    }

    private static func signalMetrics(from buffer: AVAudioPCMBuffer) -> SignalMetrics {
        guard
            let channelData = buffer.floatChannelData,
            buffer.frameLength > 0
        else {
            return SignalMetrics(rmsDB: -80, peakDB: -80)
        }

        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)
        var sumSquares: Float = 0
        var peak: Float = 0

        for frame in 0..<frameCount {
            var monoSample: Float = 0

            for channel in 0..<channelCount {
                monoSample += channelData[channel][frame]
            }

            monoSample /= Float(channelCount)

            let magnitude = abs(monoSample)
            sumSquares += monoSample * monoSample
            peak = max(peak, magnitude)
        }

        let rms = sqrt(sumSquares / Float(frameCount))
        let rmsDB = 20 * log10(max(rms, 0.000_000_1))
        let peakDB = 20 * log10(max(peak, 0.000_000_1))
        return SignalMetrics(rmsDB: rmsDB, peakDB: peakDB)
    }
}
