@preconcurrency import AVFoundation
import Foundation

private enum HarnessError: Error, LocalizedError {
    case missingModels
    case invalidPath(String)

    var errorDescription: String? {
        switch self {
        case .missingModels:
            return "usage: vad_fixture_harness <whisper-model.bin> <vad-model.bin> [fixture path ...]"
        case .invalidPath(let path):
            return "Invalid fixture path: \(path)"
        }
    }
}

private struct HarnessResult {
    let transcript: String?
    let diagnostics: SpeechActivityDiagnostics
    let chunks: [SpeechChunk]
}

private struct FixtureComparison {
    let expected: String
    let actual: String
    let removed: [String]
    let inserted: [String]
}

@main
private struct VADFixtureHarness {
    static func main() async throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        guard arguments.count >= 2 else {
            throw HarnessError.missingModels
        }

        let whisperModelURL = URL(fileURLWithPath: arguments[0])
        let vadModelURL = URL(fileURLWithPath: arguments[1])
        let fixtureArguments = Array(arguments.dropFirst(2))
        let fixturePaths = try resolveFixturePaths(from: fixtureArguments)

        let whisperEngine = WhisperEngine(modelURL: whisperModelURL)
        try await whisperEngine.prepare()
        let speechActivityService = SpeechActivityService(modelURL: vadModelURL)

        for fixtureURL in fixturePaths {
            do {
                let result = try await runFixture(
                    at: fixtureURL,
                    speechActivityService: speechActivityService,
                    whisperEngine: whisperEngine
                )
                print(renderFixtureOutput(for: fixtureURL, result: result))
            } catch {
                print("[\(fixtureURL.lastPathComponent)] ERROR: \(error.localizedDescription)")
            }
        }
    }

    private static func resolveFixturePaths(from arguments: [String]) throws -> [URL] {
        let fileManager = FileManager.default
        let explicitPaths = arguments.isEmpty
            ? [".vad-fixtures", "\(NSHomeDirectory())/Library/Application Support/WhisperMax/Recordings"]
            : arguments

        var results: [URL] = []
        let allowedExtensions = Set(["wav", "aiff", "aif", "caf", "m4a"])

        for path in explicitPaths {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw HarnessError.invalidPath(path)
            }

            if isDirectory.boolValue {
                let children = try fileManager.contentsOfDirectory(
                    at: url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
                let audioFiles = children
                    .filter { allowedExtensions.contains($0.pathExtension.lowercased()) }
                    .sorted { $0.lastPathComponent < $1.lastPathComponent }
                results.append(contentsOf: audioFiles)
            } else if allowedExtensions.contains(url.pathExtension.lowercased()) {
                results.append(url)
            }
        }

        return results
    }

    private static func runFixture(
        at url: URL,
        speechActivityService: SpeechActivityService,
        whisperEngine: WhisperEngine
    ) async throws -> HarnessResult {
        let samples = try AudioSampleDecoder.decodeWhisperSamples(from: url)
        let prepared = speechActivityService.prepareTranscriptionAudio(from: samples)

        switch prepared {
        case .noSpeech(let diagnostics):
            return HarnessResult(
                transcript: nil,
                diagnostics: diagnostics,
                chunks: []
            )
        case .singlePass(let trimmedSamples, let diagnostics):
            let transcription = try await whisperEngine.transcribe(samples: trimmedSamples, prompt: nil)
            let cleaned = TranscriptFormatter.normalize(transcription.text)
            return HarnessResult(
                transcript: cleaned.isEmpty ? nil : cleaned,
                diagnostics: diagnostics,
                chunks: []
            )
        case .chunked(let chunks, let diagnostics):
            var chunkTexts: [String] = []
            chunkTexts.reserveCapacity(chunks.count)
            var rollingContext = ""

            for chunk in chunks {
                let transcription = try await whisperEngine.transcribe(
                    samples: chunk.samples,
                    prompt: composeChunkPrompt(rollingContext: rollingContext)
                )
                let cleaned = TranscriptFormatter.normalize(transcription.text)
                guard !cleaned.isEmpty else {
                    continue
                }
                if TranscriptionChunkPolicy.shouldReject(result: transcription, text: cleaned, chunk: chunk) {
                    continue
                }
                chunkTexts.append(cleaned)
                rollingContext = updatedChunkContext(from: chunkTexts)
            }

            let stitched = TranscriptFormatter.stitch(chunkTexts)
            return HarnessResult(
                transcript: stitched.isEmpty ? nil : stitched,
                diagnostics: diagnostics,
                chunks: chunks
            )
        }
    }

    private static func renderFixtureOutput(for url: URL, result: HarnessResult) -> String {
        var lines: [String] = []
        let duration = result.diagnostics.originalDuration
        lines.append("[\(url.lastPathComponent)] \(String(format: "%.2fs", duration)) mode=\(result.diagnostics.mode.rawValue)")
        lines.append("  speech regions: \(formatRegions(result.diagnostics.speechRegions))")
        if !result.chunks.isEmpty {
            lines.append("  chunks: \(formatChunks(result.chunks))")
        }
        lines.append("  selected duration: \(String(format: "%.2fs", result.diagnostics.selectedDuration))")

        if let transcript = result.transcript {
            lines.append("  transcript: \(transcript)")
        } else {
            lines.append("  transcript: <no speech>")
        }

        if let comparison = loadExpectedTranscriptComparison(for: url, actual: result.transcript ?? "") {
            lines.append("  expected: \(comparison.expected)")
            if !comparison.removed.isEmpty {
                lines.append("  missing tokens: \(comparison.removed.joined(separator: " "))")
            }
            if !comparison.inserted.isEmpty {
                lines.append("  extra tokens: \(comparison.inserted.joined(separator: " "))")
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func formatRegions(_ regions: [SpeechRegion]) -> String {
        guard !regions.isEmpty else {
            return "<none>"
        }

        return regions.map { region in
            let start = Double(region.startSample) / AudioSampleDecoder.targetSampleRate
            let end = Double(region.endSample) / AudioSampleDecoder.targetSampleRate
            return "\(String(format: "%.2f", start))-\(String(format: "%.2f", end))"
        }
        .joined(separator: ", ")
    }

    private static func formatChunks(_ chunks: [SpeechChunk]) -> String {
        chunks.enumerated().map { offset, chunk in
            let start = Double(chunk.startSample) / AudioSampleDecoder.targetSampleRate
            let end = Double(chunk.endSample) / AudioSampleDecoder.targetSampleRate
            let lead = Double(chunk.overlapLeadSamples) / AudioSampleDecoder.targetSampleRate
            let trail = Double(chunk.overlapTrailSamples) / AudioSampleDecoder.targetSampleRate
            return "#\(offset + 1) \(String(format: "%.2f", start))-\(String(format: "%.2f", end)) (lead \(String(format: "%.2f", lead))s trail \(String(format: "%.2f", trail))s)"
        }
        .joined(separator: "; ")
    }

    private static func loadExpectedTranscriptComparison(for audioURL: URL, actual: String) -> FixtureComparison? {
        let base = audioURL.deletingPathExtension()
        let candidates = [
            base.appendingPathExtension("txt"),
            URL(fileURLWithPath: base.path + ".expected.txt")
        ]

        guard
            let expectedURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
            let expected = try? String(contentsOf: expectedURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            return nil
        }

        let expectedTokens = tokenize(expected)
        let actualTokens = tokenize(actual)
        let difference = actualTokens.difference(from: expectedTokens)

        let removed = difference.removals.compactMap { change -> String? in
            if case .remove(_, let element, _) = change {
                return element
            }
            return nil
        }
        let inserted = difference.insertions.compactMap { change -> String? in
            if case .insert(_, let element, _) = change {
                return element
            }
            return nil
        }

        return FixtureComparison(
            expected: expected,
            actual: actual,
            removed: removed,
            inserted: inserted
        )
    }

    private static func tokenize(_ text: String) -> [String] {
        text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    private static func composeChunkPrompt(rollingContext: String) -> String? {
        let context = rollingContext.trimmingCharacters(in: .whitespacesAndNewlines)
        return context.isEmpty ? nil : "Recent transcript context:\n\(context)"
    }

    private static func updatedChunkContext(from chunkTexts: [String]) -> String {
        guard let last = chunkTexts.last else {
            return ""
        }

        let tokens = last.split(whereSeparator: \.isWhitespace)
        return tokens.suffix(36).joined(separator: " ")
    }
}
