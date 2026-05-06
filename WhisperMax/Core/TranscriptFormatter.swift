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

    static func stitch(_ chunks: [String], preferredTerms: [String] = []) -> String {
        let parts = chunks
            .map { normalize($0, preferredTerms: preferredTerms) }
            .filter { !$0.isEmpty }

        guard var result = parts.first else {
            return ""
        }

        for chunk in parts.dropFirst() {
            result = merge(result, with: chunk)
        }

        return normalize(result, preferredTerms: preferredTerms)
    }

    private static func merge(_ left: String, with right: String) -> String {
        let leftTokens = left.split(whereSeparator: \.isWhitespace).map(String.init)
        let rightTokens = right.split(whereSeparator: \.isWhitespace).map(String.init)

        guard !leftTokens.isEmpty else {
            return right
        }

        guard !rightTokens.isEmpty else {
            return left
        }

        let maximumOverlap = min(18, leftTokens.count, rightTokens.count)
        var acceptedOverlap = 0

        for candidate in stride(from: maximumOverlap, through: 2, by: -1) {
            let leftSuffix = leftTokens.suffix(candidate)
            let rightPrefix = rightTokens.prefix(candidate)

            guard leftSuffix.count == rightPrefix.count else {
                continue
            }

            let matches = zip(leftSuffix, rightPrefix).allSatisfy { leftToken, rightToken in
                normalizedOverlapToken(leftToken) == normalizedOverlapToken(rightToken)
            }

            if matches {
                acceptedOverlap = candidate
                break
            }
        }

        let mergedTokens = leftTokens + rightTokens.dropFirst(acceptedOverlap)
        return mergedTokens.joined(separator: " ")
    }

    private static func normalizedOverlapToken(_ token: String) -> String {
        token
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
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
