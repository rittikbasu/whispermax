import Foundation

struct WordDictionaryEntry: Identifiable, Codable, Hashable {
    let id: UUID
    let text: String
    let createdAt: Date
}

final class WordDictionaryStore {
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

    func load() -> [WordDictionaryEntry] {
        do {
            try ModelLocator.prepareDirectories()
            let data = try Data(contentsOf: ModelLocator.wordDictionaryFileURL)
            return try decoder.decode([WordDictionaryEntry].self, from: data)
        } catch {
            return []
        }
    }

    func save(_ entries: [WordDictionaryEntry]) {
        do {
            try ModelLocator.prepareDirectories()
            let data = try encoder.encode(entries)
            try data.write(to: ModelLocator.wordDictionaryFileURL, options: .atomic)
        } catch {
            NSLog("Failed to save word dictionary: \(error.localizedDescription)")
        }
    }
}
