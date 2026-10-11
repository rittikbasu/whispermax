import Foundation

enum ModelLocator {
    static let appSupportDirectory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WhisperMax", isDirectory: true)
    }()

    static let cacheDirectory: URL = {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("WhisperMax", isDirectory: true)
    }()

    static let historyFileURL = appSupportDirectory.appendingPathComponent("history.json")
    static let wordDictionaryFileURL = appSupportDirectory.appendingPathComponent("word-dictionary.json")
    static let audioInputPreferenceFileURL = appSupportDirectory.appendingPathComponent("audio-input-preference.json")
    static let insertionPolicyFileURL = appSupportDirectory.appendingPathComponent("insertion-policy.json")
    static let onboardingCompleteFileURL = appSupportDirectory.appendingPathComponent("onboarding-complete")
    static let debugRecordingsDirectory = appSupportDirectory.appendingPathComponent("DebugRecordings", isDirectory: true)
    static let modelsDirectory = appSupportDirectory.appendingPathComponent("Models", isDirectory: true)
    static let legacyTemporaryRecordingsDirectory = appSupportDirectory.appendingPathComponent("Recordings", isDirectory: true)
    static let temporaryRecordingsDirectory = cacheDirectory.appendingPathComponent("Recordings", isDirectory: true)
    static let phononModelURL = modelsDirectory.appendingPathComponent("Phonon-2-CoreML", isDirectory: true)
    static let phononPreviousModelURL = modelsDirectory.appendingPathComponent(".Phonon-2-CoreML.previous", isDirectory: true)
    static let phononStagingModelURL = modelsDirectory.appendingPathComponent(".Phonon-2-CoreML.partial", isDirectory: true)
    static let phononDownloadResumeDataURL = appSupportDirectory.appendingPathComponent("phonon-model-download.resumedata")
    static let phononDownloadResumeAssetURL = appSupportDirectory.appendingPathComponent("phonon-model-download.asset")

    static func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temporaryRecordingsDirectory, withIntermediateDirectories: true)

        if !FileManager.default.fileExists(atPath: phononModelURL.path),
           FileManager.default.fileExists(atPath: phononPreviousModelURL.path) {
            do {
                try FileManager.default.moveItem(at: phononPreviousModelURL, to: phononModelURL)
            } catch {
                NSLog("WhisperMax could not restore its previous Phonon model: %@", error.localizedDescription)
            }
        }
    }

    static func cleanTemporaryRecordings() {
        let fileManager = FileManager.default
        for directory in [temporaryRecordingsDirectory, legacyTemporaryRecordingsDirectory] {
            guard let files = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for file in files where file.pathExtension.lowercased() == "caf" {
                try? fileManager.removeItem(at: file)
            }
        }

        if let legacyFiles = try? fileManager.contentsOfDirectory(
            at: legacyTemporaryRecordingsDirectory,
            includingPropertiesForKeys: nil
        ), legacyFiles.isEmpty {
            try? fileManager.removeItem(at: legacyTemporaryRecordingsDirectory)
        }
    }

    static var hasInstalledPhononModel: Bool {
        PhononModelPackage.isInstalled(at: phononModelURL)
    }

    static func bundledVADModelURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: "ggml-silero-v6.2.0", withExtension: "bin")
    }
}
