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

        if
            sourceFormat.sampleRate == targetFormat.sampleRate,
            sourceFormat.channelCount == targetFormat.channelCount,
            sourceFormat.commonFormat == targetFormat.commonFormat,
            sourceFormat.isInterleaved == targetFormat.isInterleaved,
            let channelData = sourceBuffer.floatChannelData
        {
            return Array(
                UnsafeBufferPointer(
                    start: channelData[0],
                    count: Int(sourceBuffer.frameLength)
                )
            )
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            return []
        }

        let outputFrameCapacity = AVAudioFrameCount(
            ceil(Double(sourceBuffer.frameLength) * targetFormat.sampleRate / sourceFormat.sampleRate)
        ) + 4_096

        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity
        ) else {
            return []
        }

        let converterInput = ConverterInput(buffer: sourceBuffer)
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
