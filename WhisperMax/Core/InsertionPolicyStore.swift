import Foundation

enum LearnedInsertionStrategy: String, Codable {
    case accessibilityFirst
    case pasteFirst
}

final class InsertionPolicyStore {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    func load() -> [String: LearnedInsertionStrategy] {
        do {
            try ModelLocator.prepareDirectories()
            let data = try Data(contentsOf: ModelLocator.insertionPolicyFileURL)
            return try decoder.decode([String: LearnedInsertionStrategy].self, from: data)
        } catch {
            return [:]
        }
    }

    func save(_ strategies: [String: LearnedInsertionStrategy]) {
        do {
            try ModelLocator.prepareDirectories()
            let data = try encoder.encode(strategies)
            try data.write(to: ModelLocator.insertionPolicyFileURL, options: .atomic)
        } catch {
            NSLog("Failed to save insertion policy: \(error.localizedDescription)")
        }
    }
}
