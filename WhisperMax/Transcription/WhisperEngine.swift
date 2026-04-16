import AVFoundation
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

    func transcribe(audioURL: URL, prompt: String? = nil) throws -> String {
        try prepare()

        guard let context else {
            throw EngineError.initializationFailed
        }

        let samples = try decodeAudioFile(audioURL)
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

        for index in 0..<segmentCount {
            transcript += String(cString: whisper_full_get_segment_text(context, index))
        }

        return transcript
    }
}

private func decodeAudioFile(_ url: URL) throws -> [Float] {
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
            sampleRate: 16_000,
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

    var hasProvidedInput = false
    var conversionError: NSError?
    converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
        if hasProvidedInput {
            outStatus.pointee = .endOfStream
            return nil
        }

        hasProvidedInput = true
        outStatus.pointee = .haveData
        return sourceBuffer
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
