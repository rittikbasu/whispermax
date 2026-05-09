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
            guard FileManager.default.fileExists(atPath: ModelLocator.historyFileURL.path) else {
                return []
            }

            let data = try Data(contentsOf: ModelLocator.historyFileURL)
            return try decoder.decode([TranscriptEntry].self, from: data)
        } catch {
            preserveCorruptHistoryFile(loadError: error)
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

    private func preserveCorruptHistoryFile(loadError: Error) {
        let fileManager = FileManager.default
        let sourceURL = ModelLocator.historyFileURL
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            return
        }

        let backupURL = Self.corruptBackupURL(fileManager: fileManager)

        do {
            try fileManager.moveItem(at: sourceURL, to: backupURL)
            NSLog("Preserved corrupt history at \(backupURL.path): \(loadError.localizedDescription)")
        } catch {
            do {
                try fileManager.copyItem(at: sourceURL, to: backupURL)
                try? fileManager.removeItem(at: sourceURL)
                NSLog("Copied corrupt history backup to \(backupURL.path): \(loadError.localizedDescription)")
            } catch {
                NSLog("Failed to preserve corrupt history: \(error.localizedDescription)")
            }
        }
    }

    private static func corruptBackupURL(fileManager: FileManager) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"

        let stamp = formatter.string(from: Date())
        var candidate = ModelLocator.appSupportDirectory
            .appendingPathComponent("history-corrupt-\(stamp).json")
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = ModelLocator.appSupportDirectory
                .appendingPathComponent("history-corrupt-\(stamp)-\(suffix).json")
            suffix += 1
        }

        return candidate
    }
}
