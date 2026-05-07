import Foundation

enum TranscriptionChunkPolicy {
    static func shouldRejectSinglePass(
        result: TranscriptionResult,
        text: String,
        selectedDuration: TimeInterval,
        mode: SpeechActivityDiagnostics.Mode
    ) -> Bool {
        guard mode == .shortFallback else {
            return false
        }

        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            return true
        }

        if !containsSpokenCharacters(normalized) {
            return true
        }

        if isLikelyNonSpeechArtifact(normalized) {
            return true
        }

        if result.segmentCount == 0 && result.maxNoSpeechProbability >= 0.98 {
            return true
        }

        if result.averageNoSpeechProbability >= 0.92,
           result.maxNoSpeechProbability >= 0.97,
           result.averageTokenProbability < 0.25 {
            return true
        }

        if selectedDuration <= 1.0,
           result.maxNoSpeechProbability >= 0.96,
           result.averageTokenProbability < 0.18 {
            return true
        }

        return false
    }

    static func shouldReject(
        result: TranscriptionResult,
        text: String,
        chunk: SpeechChunk
    ) -> Bool {
        if text.isEmpty {
            return true
        }

        let isVeryShortChunk = chunk.duration <= 0.45
        if isVeryShortChunk && result.maxNoSpeechProbability >= 0.92 {
            return true
        }

        if result.segmentCount == 0 && result.maxNoSpeechProbability >= 0.98 {
            return true
        }

        if result.maxNoSpeechProbability >= 0.995 && result.averageTokenProbability < 0.12 {
            return true
        }

        return false
    }

    private static func containsSpokenCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    private static func isLikelyNonSpeechArtifact(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return true
        }

        if isWrappedArtifact(trimmed, prefix: "*", suffix: "*") {
            return true
        }

        if isWrappedArtifact(trimmed, prefix: "[", suffix: "]") {
            return true
        }

        return false
    }

    private static func isWrappedArtifact(_ text: String, prefix: Character, suffix: Character) -> Bool {
        guard text.first == prefix, text.last == suffix else {
            return false
        }

        let inner = text
            .dropFirst()
            .dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !inner.isEmpty else {
            return true
        }

        let wordCount = inner.split(whereSeparator: \.isWhitespace).count
        return wordCount <= 4
    }
}
