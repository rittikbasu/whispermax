import Foundation

enum ModelLocator {
    static let appSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WhisperMax", isDirectory: true)
    }()

    static let historyFileURL = appSupportDirectory.appendingPathComponent("history.json")
    static let wordDictionaryFileURL = appSupportDirectory.appendingPathComponent("word-dictionary.json")
    static let audioInputPreferenceFileURL = appSupportDirectory.appendingPathComponent("audio-input-preference.json")
    static let insertionPolicyFileURL = appSupportDirectory.appendingPathComponent("insertion-policy.json")
    static let onboardingCompleteFileURL = appSupportDirectory.appendingPathComponent("onboarding-complete")
    static let downloadResumeDataURL = appSupportDirectory.appendingPathComponent("model-download.resumedata")
    static let modelsDirectory = appSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    static let temporaryRecordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    static let appLocalModelURL = modelsDirectory.appendingPathComponent("ggml-large-v3-turbo.bin")

    static let superwhisperModelURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("superwhisper", isDirectory: true)
            .appendingPathComponent("ggml-large-v3-turbo.bin")
    }()

    static func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryRecordingsDirectory, withIntermediateDirectories: true)
    }

    static func preferredModelURL() -> URL? {
        if FileManager.default.fileExists(atPath: appLocalModelURL.path) {
            return appLocalModelURL
        }

        if FileManager.default.fileExists(atPath: superwhisperModelURL.path) {
            return superwhisperModelURL
        }

        return nil
    }
}
