import Foundation

enum TranscriptFormatter {
    static func normalize(_ text: String) -> String {
        let collapsed = text.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )

        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
