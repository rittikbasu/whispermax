import Foundation

enum TranscriptFormatter {
    static func normalize(_ text: String, preferredTerms: [String] = []) -> String {
        let collapsed = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !preferredTerms.isEmpty else {
            return trimmed
        }

        return applyPreferredTerms(preferredTerms, to: trimmed)
    }

    private static func applyPreferredTerms(_ preferredTerms: [String], to text: String) -> String {
        var result = text

        for term in preferredTerms
            .map(normalizePreferredTerm)
            .filter({ !$0.isEmpty })
            .sorted(by: { $0.count > $1.count })
        {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            let pattern = "(?<![\\p{L}\\p{N}])\(escaped)(?![\\p{L}\\p{N}])"

            guard let expression = try? NSRegularExpression(
                pattern: pattern,
                options: [.caseInsensitive]
            ) else {
                continue
            }

            let fullRange = NSRange(result.startIndex..<result.endIndex, in: result)
            result = expression.stringByReplacingMatches(
                in: result,
                options: [],
                range: fullRange,
                withTemplate: term
            )
        }

        return result
    }

    private static func normalizePreferredTerm(_ term: String) -> String {
        term.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
