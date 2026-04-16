import CoreAudio
import Foundation

enum AudioInputPreference: Codable, Equatable {
    case systemDefault
    case pinned(PinnedAudioInputPreference)
}

struct PinnedAudioInputPreference: Codable, Equatable {
    let audioObjectID: UInt32
    let name: String

    init(audioObjectID: AudioObjectID, name: String) {
        self.audioObjectID = audioObjectID
        self.name = name
    }

    var resolvedAudioObjectID: AudioObjectID {
        audioObjectID
    }
}

final class AudioInputPreferenceStore {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    func load() -> AudioInputPreference {
        do {
            try ModelLocator.prepareDirectories()
            let data = try Data(contentsOf: ModelLocator.audioInputPreferenceFileURL)
            return try decoder.decode(AudioInputPreference.self, from: data)
        } catch {
            return .systemDefault
        }
    }

    func save(_ preference: AudioInputPreference) {
        do {
            try ModelLocator.prepareDirectories()
            let data = try encoder.encode(preference)
            try data.write(to: ModelLocator.audioInputPreferenceFileURL, options: .atomic)
        } catch {
            NSLog("Failed to save input preference: \(error.localizedDescription)")
        }
    }
}
