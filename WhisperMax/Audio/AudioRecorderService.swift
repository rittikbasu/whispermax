import AVFoundation
import Foundation

@MainActor
final class AudioRecorderService: NSObject {
    enum RecorderError: LocalizedError {
        case couldNotStartRecording

        var errorDescription: String? {
            switch self {
            case .couldNotStartRecording:
                return "Could not start recording."
            }
        }
    }

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var shouldDiscardCurrentRecording = false

    var onMeter: ((Float, TimeInterval) -> Void)?
    var onFinish: ((URL) -> Void)?
    var onError: ((String) -> Void)?

    func start() throws {
        try ModelLocator.prepareDirectories()

        let url = ModelLocator.temporaryRecordingsDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        let recorder = try AVAudioRecorder(url: url, settings: settings)
        recorder.delegate = self
        recorder.isMeteringEnabled = true

        shouldDiscardCurrentRecording = false

        guard recorder.record() else {
            throw RecorderError.couldNotStartRecording
        }

        self.recorder = recorder
        startMetering()
    }

    func stop() {
        meterTimer?.invalidate()
        meterTimer = nil
        recorder?.stop()
    }

    func cancel() {
        shouldDiscardCurrentRecording = true
        stop()
    }

    private func startMetering() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(handleMeterTimer),
            userInfo: nil,
            repeats: true
        )
    }

    @objc
    private func handleMeterTimer() {
        guard let recorder else { return }

        recorder.updateMeters()

        let averagePower = recorder.averagePower(forChannel: 0)
        let peakPower = recorder.peakPower(forChannel: 0)
        let averageAmplitude = pow(10, averagePower / 20)
        let peakAmplitude = pow(10, peakPower / 20)
        let blendedAmplitude = min((averageAmplitude * 0.74) + (peakAmplitude * 0.26), 1.0)
        let gatedAmplitude = max(0, blendedAmplitude - 0.02) / 0.98
        let normalizedPower = min(pow(gatedAmplitude, 0.82), 1.0)
        onMeter?(Float(normalizedPower), recorder.currentTime)
    }
}

extension AudioRecorderService: AVAudioRecorderDelegate {
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        Task { @MainActor [weak self] in
            self?.onError?(error?.localizedDescription ?? "Recording failed.")
        }
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self else { return }

            defer {
                self.meterTimer?.invalidate()
                self.meterTimer = nil
                self.recorder = nil
            }

            guard flag else {
                self.onError?("Recording finished unsuccessfully.")
                return
            }

            if self.shouldDiscardCurrentRecording {
                try? FileManager.default.removeItem(at: recorder.url)
                self.shouldDiscardCurrentRecording = false
                return
            }

            self.onFinish?(recorder.url)
        }
    }
}
