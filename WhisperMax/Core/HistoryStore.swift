import Foundation

final class HistoryStore {
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
}
