import Foundation

enum HistoryRetentionLimit: Int, CaseIterable, Identifiable {
    case oneHundred = 100
    case fiveHundred = 500
    case oneThousand = 1000

    var id: Int { rawValue }

    var title: String {
        "\(rawValue)"
    }

    static let defaultLimit: HistoryRetentionLimit = .oneThousand
}

final class HistoryStore {
    private enum DefaultsKey {
        static let retentionLimit = "HistoryRetentionLimit"
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    func load() -> [TranscriptEntry] {
        do {
            try ModelLocator.prepareDirectories()
            let data = try Data(contentsOf: ModelLocator.historyFileURL)
            return try decoder.decode([TranscriptEntry].self, from: data)
        } catch {
            return []
        }
    }

    func save(_ entries: [TranscriptEntry]) {
        do {
            try ModelLocator.prepareDirectories()
            let data = try encoder.encode(entries)
            try data.write(to: ModelLocator.historyFileURL, options: .atomic)
        } catch {
            NSLog("Failed to save history: \(error.localizedDescription)")
        }
    }

    func loadRetentionLimit() -> HistoryRetentionLimit {
        let rawValue = UserDefaults.standard.integer(forKey: DefaultsKey.retentionLimit)
        return HistoryRetentionLimit(rawValue: rawValue) ?? .defaultLimit
    }

    func saveRetentionLimit(_ limit: HistoryRetentionLimit) {
        UserDefaults.standard.set(limit.rawValue, forKey: DefaultsKey.retentionLimit)
    }

    func pruned(_ entries: [TranscriptEntry], limit: HistoryRetentionLimit) -> [TranscriptEntry] {
        Array(
            entries
                .sorted { $0.createdAt > $1.createdAt }
                .prefix(limit.rawValue)
        )
    }
}
