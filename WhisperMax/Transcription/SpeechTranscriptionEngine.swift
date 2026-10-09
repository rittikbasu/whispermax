import Foundation

enum SpeechTranscriptionInput: Sendable {
    case preparedSamples([Float])
    case originalAudio(URL)
}

struct SpeechTranscriptionOutput: Sendable {
    let text: String
    let inferenceDuration: TimeInterval?
}

protocol SpeechTranscriptionEngine: Actor {
    func prepare() async throws
    func transcribe(input: SpeechTranscriptionInput, prompt: String?) async throws -> SpeechTranscriptionOutput
    func shutdown() async
}
