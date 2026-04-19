import CoreAudio
import Foundation

enum AudioInputPreference: Codable, Equatable {
    case systemDefault
    case pinned(PinnedAudioInputPreference)
}

struct PinnedAudioInputPreference: Codable, Equatable {
    private let uid: String?
    private let legacyAudioObjectID: UInt32?
    let name: String

    init(uid: String, name: String) {
        self.uid = uid
        self.legacyAudioObjectID = nil
        self.name = name
    }

    init(device: AudioInputDevice) {
        self.uid = device.uid
        self.legacyAudioObjectID = nil
        self.name = device.name
    }

    private enum CodingKeys: String, CodingKey {
        case uid
        case audioObjectID
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        uid = try container.decodeIfPresent(String.self, forKey: .uid)
        legacyAudioObjectID = try container.decodeIfPresent(UInt32.self, forKey: .audioObjectID)
        name = try container.decode(String.self, forKey: .name)

        if uid == nil, legacyAudioObjectID == nil {
            throw DecodingError.dataCorruptedError(
                forKey: .uid,
                in: container,
                debugDescription: "Pinned microphone preference is missing both uid and audioObjectID."
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(uid, forKey: .uid)
    }

    func matches(_ device: AudioInputDevice) -> Bool {
        if let uid {
            return device.uid == uid
        }

        if let legacyAudioObjectID {
            return device.audioObjectID == legacyAudioObjectID
        }

        return false
    }

    func resolvedDevice(in devices: [AudioInputDevice]) -> AudioInputDevice? {
        devices.first(where: matches)
    }

    var needsUIDMigration: Bool {
        uid == nil && legacyAudioObjectID != nil
    }

    func migrated(using device: AudioInputDevice) -> PinnedAudioInputPreference {
        PinnedAudioInputPreference(device: device)
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
