@preconcurrency import AVFoundation
import Foundation

enum AudioSampleDecoder {
    static let targetSampleRate: Double = 16_000

    private final class ConverterInput: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        private var hasProvidedInput = false

        init(buffer: AVAudioPCMBuffer) {
            self.buffer = buffer
        }

        func nextBuffer(_ outStatus: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
            if hasProvidedInput {
                outStatus.pointee = .endOfStream
                return nil
            }

            hasProvidedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
    }

    static func decodeWhisperSamples(from url: URL) throws -> [Float] {
        let audioFile = try AVAudioFile(forReading: url)
        let sourceFormat = audioFile.processingFormat
        let sourceFrameCount = AVAudioFrameCount(audioFile.length)

        guard
            sourceFrameCount > 0,
            let sourceBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: sourceFrameCount)
        else {
            return []
        }

        try audioFile.read(into: sourceBuffer)

        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            return []
        }

        var conversionInput = sourceBuffer
        var conversionInputFormat = sourceFormat
        // Downmix before resampling; AVAudioConverter can emit silence for VPIO's multichannel format.
        if sourceFormat.channelCount > 1,
           (sourceBuffer.floatChannelData != nil || sourceBuffer.int16ChannelData != nil),
           let monoFormat = AVAudioFormat(
               commonFormat: .pcmFormatFloat32,
               sampleRate: sourceFormat.sampleRate,
               channels: 1,
               interleaved: false
           ),
           let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: sourceBuffer.frameLength),
           let monoData = monoBuffer.floatChannelData?.pointee
        {
            let channelCount = Int(sourceFormat.channelCount)
            let frameCount = Int(sourceBuffer.frameLength)
            let scale = 1 / Float(channelCount)

            if let channels = sourceBuffer.floatChannelData {
                for frame in 0..<frameCount {
                    var sample: Float = 0
                    for channel in 0..<channelCount {
                        sample += channels[channel][frame]
                    }
                    monoData[frame] = sample * scale
                }
            } else if let channels = sourceBuffer.int16ChannelData {
                for frame in 0..<frameCount {
                    var sample: Float = 0
                    for channel in 0..<channelCount {
                        sample += Float(channels[channel][frame])
                    }
                    monoData[frame] = sample * (scale / 32_768)
                }
            } else {
                return []
            }

            monoBuffer.frameLength = sourceBuffer.frameLength
            conversionInput = monoBuffer
            conversionInputFormat = monoFormat
        }

        if
            conversionInputFormat.sampleRate == targetFormat.sampleRate,
            conversionInputFormat.channelCount == targetFormat.channelCount,
            conversionInputFormat.commonFormat == targetFormat.commonFormat,
            conversionInputFormat.isInterleaved == targetFormat.isInterleaved,
            let channelData = conversionInput.floatChannelData
        {
            return Array(
                UnsafeBufferPointer(
                    start: channelData[0],
                    count: Int(conversionInput.frameLength)
                )
            )
        }

        guard let converter = AVAudioConverter(from: conversionInputFormat, to: targetFormat) else {
            return []
        }

        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(conversionInput.frameLength) * targetFormat.sampleRate / conversionInputFormat.sampleRate)
        ) + 4_096

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return []
        }

        let converterInput = ConverterInput(buffer: conversionInput)
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            converterInput.nextBuffer(outStatus)
        }

        if conversionError != nil {
            return []
        }

        guard let channelData = outputBuffer.floatChannelData else {
            return []
        }

        return Array(
            UnsafeBufferPointer(
                start: channelData[0],
                count: Int(outputBuffer.frameLength)
            )
        )
    }
}
