import Foundation

enum DebugRecordingCaptureResult: String, Codable, Sendable {
    case inserted
    case clipboard
    case copied
    case noSpeech
    case error
}

#if DEBUG
struct DebugRecordingChunkPlan: Codable, Sendable {
    let startSample: Int
    let endSample: Int
    let overlapLeadSamples: Int
    let overlapTrailSamples: Int

    var duration: TimeInterval {
        Double(endSample - startSample) / AudioSampleDecoder.targetSampleRate
    }
}

struct DebugRecordingTranscriptionPass: Codable, Sendable {
    let index: Int
    let accepted: Bool
    let transcript: String
    let selectedDuration: TimeInterval?
    let averageNoSpeechProbability: Float
    let maxNoSpeechProbability: Float
    let averageTokenProbability: Float
    let segmentCount: Int
    let segmentDiagnostics: [TranscriptionSegmentDiagnostic]
}

struct DebugRecordingSpeechRegion: Codable, Sendable {
    let startSample: Int
    let endSample: Int
    let maxProbability: Float
    let meanProbability: Float
    let duration: TimeInterval
}

struct DebugRecordingDiagnostics: Codable, Sendable {
    let mode: String
    let originalDuration: TimeInterval
    let totalSpeechDuration: TimeInterval
    let selectedDuration: TimeInterval
    let speechRegions: [DebugRecordingSpeechRegion]
}

struct DebugRecordingMetadata: Codable, Sendable {
    let id: UUID
    let capturedAt: Date
    let appVersion: String
    let appBuild: String
    let bundleIdentifier: String
    let result: DebugRecordingCaptureResult
    let recordingDuration: TimeInterval?
    let transcript: String?
    let insertionMethod: String?
    let issueMessage: String?
    let errorMessage: String?
    let audioFilename: String
    let diagnostics: DebugRecordingDiagnostics?
    let chunks: [DebugRecordingChunkPlan]
    let transcriptionPasses: [DebugRecordingTranscriptionPass]
}

final class DebugRecordingStore {
    private enum TestingKey {
        static let enabled = "RetainDebugRecordings"
        static let limit = "RetainDebugRecordingsLimit"
    }

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private let fileManager = FileManager.default

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: TestingKey.enabled)
    }

    var retentionLimit: Int {
        let configured = UserDefaults.standard.integer(forKey: TestingKey.limit)
        if configured > 0 {
            return max(1, min(200, configured))
        }
        return 20
    }

    func capture(
        audioURL: URL,
        recordingDuration: TimeInterval?,
        result: DebugRecordingCaptureResult,
        transcript: String?,
        insertionMethod: InsertionMethod? = nil,
        issueMessage: String? = nil,
        errorMessage: String? = nil,
        diagnostics: SpeechActivityDiagnostics? = nil,
        chunks: [DebugRecordingChunkPlan] = [],
        transcriptionPasses: [DebugRecordingTranscriptionPass] = []
    ) {
        guard isEnabled else {
            return
        }

        do {
            try fileManager.createDirectory(
                at: ModelLocator.debugRecordingsDirectory,
                withIntermediateDirectories: true
            )

            let id = UUID()
            let stamp = Self.directoryStampFormatter.string(from: Date())
            let captureDirectory = ModelLocator.debugRecordingsDirectory
                .appendingPathComponent("\(stamp)-\(id.uuidString.prefix(8))", isDirectory: true)
            try fileManager.createDirectory(at: captureDirectory, withIntermediateDirectories: true)

            let audioFilename = "recording\(audioURL.pathExtension.isEmpty ? ".caf" : ".\(audioURL.pathExtension)")"
            let retainedAudioURL = captureDirectory.appendingPathComponent(audioFilename)
            try fileManager.copyItem(at: audioURL, to: retainedAudioURL)

            let metadata = DebugRecordingMetadata(
                id: id,
                capturedAt: Date(),
                appVersion: Self.bundleVersion,
                appBuild: Self.bundleBuild,
                bundleIdentifier: Bundle.main.bundleIdentifier ?? "unknown",
                result: result,
                recordingDuration: recordingDuration,
                transcript: transcript,
                insertionMethod: insertionMethod?.rawValue,
                issueMessage: issueMessage,
                errorMessage: errorMessage,
                audioFilename: audioFilename,
                diagnostics: diagnostics.map(Self.makeDiagnostics),
                chunks: chunks,
                transcriptionPasses: transcriptionPasses
            )

            let metadataURL = captureDirectory.appendingPathComponent("metadata.json")
            let metadataData = try encoder.encode(metadata)
            try metadataData.write(to: metadataURL, options: .atomic)

            if let transcript, !transcript.isEmpty {
                let transcriptURL = captureDirectory.appendingPathComponent("transcript.txt")
                try transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
            }

            pruneIfNeeded()
        } catch {
            NSLog("Failed to retain debug recording: \(error.localizedDescription)")
        }
    }

    private func pruneIfNeeded() {
        guard let captureDirectories = try? fileManager.contentsOfDirectory(
            at: ModelLocator.debugRecordingsDirectory,
            includingPropertiesForKeys: [.creationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let directories = captureDirectories.compactMap { url -> (URL, Date)? in
            guard
                let values = try? url.resourceValues(forKeys: [.creationDateKey, .isDirectoryKey]),
                values.isDirectory == true
            else {
                return nil
            }

            return (url, values.creationDate ?? .distantPast)
        }

        let overflow = directories.count - retentionLimit
        guard overflow > 0 else {
            return
        }

        for (url, _) in directories.sorted(by: { $0.1 < $1.1 }).prefix(overflow) {
            try? fileManager.removeItem(at: url)
        }
    }

    private static func makeDiagnostics(_ diagnostics: SpeechActivityDiagnostics) -> DebugRecordingDiagnostics {
        DebugRecordingDiagnostics(
            mode: diagnostics.mode.rawValue,
            originalDuration: diagnostics.originalDuration,
            totalSpeechDuration: diagnostics.totalSpeechDuration,
            selectedDuration: diagnostics.selectedDuration,
            speechRegions: diagnostics.speechRegions.map {
                DebugRecordingSpeechRegion(
                    startSample: $0.startSample,
                    endSample: $0.endSample,
                    maxProbability: $0.maxProbability,
                    meanProbability: $0.meanProbability,
                    duration: $0.duration
                )
            }
        )
    }

    private static let directoryStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()

    private static var bundleVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    }

    private static var bundleBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    }
}
#else
struct DebugRecordingChunkPlan: Sendable {
    let startSample: Int
    let endSample: Int
    let overlapLeadSamples: Int
    let overlapTrailSamples: Int
}

struct DebugRecordingTranscriptionPass: Sendable {
    let index: Int
    let accepted: Bool
    let transcript: String
    let selectedDuration: TimeInterval?
    let averageNoSpeechProbability: Float
    let maxNoSpeechProbability: Float
    let averageTokenProbability: Float
    let segmentCount: Int
    let segmentDiagnostics: [TranscriptionSegmentDiagnostic]
}

final class DebugRecordingStore {
    var isEnabled: Bool { false }
    var retentionLimit: Int { 0 }

    func capture(
        audioURL: URL,
        recordingDuration: TimeInterval?,
        result: DebugRecordingCaptureResult,
        transcript: String?,
        insertionMethod: InsertionMethod? = nil,
        issueMessage: String? = nil,
        errorMessage: String? = nil,
        diagnostics: SpeechActivityDiagnostics? = nil,
        chunks: [DebugRecordingChunkPlan] = [],
        transcriptionPasses: [DebugRecordingTranscriptionPass] = []
    ) {
    }
}
#endif
