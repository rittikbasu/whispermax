import CryptoKit
import Foundation

enum PhononModelPackage {
    struct Asset: Sendable {
        let path: String
        let byteCount: Int64
        let sha256: String

        var downloadURL: URL {
            URL(string: "https://huggingface.co/FermionResearch/Phonon-2-CoreML/resolve/\(revision)/\(path)?download=true")!
        }

        private var revision: String { PhononModelPackage.revision }
    }

    private struct Installation: Decodable, Encodable {
        let revision: String
    }

    static let revision = "1143812fd4236522232a8c33e3115f0577e3cd7d"
    static let totalByteCount: Int64 = assets.reduce(0) { $0 + $1.byteCount }

    static let assets: [Asset] = [
        Asset(
            path: "manifest.json",
            byteCount: 1_428,
            sha256: "ab3fb5dfd3fc07b1d8a24379d04418f458d0443ba6359d3a5ab2f098a7d64089"
        ),
        Asset(
            path: "decoder.bin",
            byteCount: 13_301_279,
            sha256: "36fa7202dda85c603af60d930ab88d7e9f0d2a619490aff46f5384db924cfa70"
        ),
        Asset(
            path: "Phonon-2.mlpackage/Manifest.json",
            byteCount: 617,
            sha256: "6ebc9309aea0e16bda9c7558521fef6307fac0afba9a5b4959fea45ed7cd0429"
        ),
        Asset(
            path: "Phonon-2.mlpackage/Data/com.apple.CoreML/model.mlmodel",
            byteCount: 2_500_482,
            sha256: "4f6790ec94fe4429b10397c013563d0a51119953ff6d3da466bbcb23a25dee2a"
        ),
        Asset(
            path: "Phonon-2.mlpackage/Data/com.apple.CoreML/weights/weight.bin",
            byteCount: 329_186_560,
            sha256: "93aa991318a00ed492fdbb724e7bca4e6a69c6cf671ab4f14a14ef6101e7648b"
        ),
        Asset(
            path: "LICENSE-CODE-Apache-2.0.txt",
            byteCount: 11_358,
            sha256: "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"
        ),
        Asset(
            path: "LICENSE-WEIGHTS-CC-BY-4.0.txt",
            byteCount: 18_657,
            sha256: "9ba9550ad48438d0836ddab3da480b3b69ffa0aac7b7878b5a0039e7ab429411"
        ),
        Asset(
            path: "NOTICE",
            byteCount: 3_084,
            sha256: "b468a23a1ce2c5181ea4050432bb68713a6468ce2e452927228d24f3d56226be"
        ),
    ]

    static func isInstalled(at bundleURL: URL) -> Bool {
        let markerURL = bundleURL.appendingPathComponent("whispermax-install.json")
        guard
            let data = try? Data(contentsOf: markerURL),
            let installation = try? JSONDecoder().decode(Installation.self, from: data),
            installation.revision == revision
        else {
            return false
        }

        return assets.allSatisfy { asset in
            fileSize(at: bundleURL.appendingPathComponent(asset.path)) == asset.byteCount
        }
    }

    static func isValid(_ asset: Asset, in directory: URL) -> Bool {
        let fileURL = directory.appendingPathComponent(asset.path)
        guard fileSize(at: fileURL) == asset.byteCount,
              let digest = sha256(at: fileURL)
        else {
            return false
        }
        return digest == asset.sha256
    }

    static func sha256(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        do {
            while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
                hasher.update(data: data)
            }
        } catch {
            return nil
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func writeInstallationMarker(in directory: URL) throws {
        let data = try JSONEncoder().encode(Installation(revision: revision))
        try data.write(to: directory.appendingPathComponent("whispermax-install.json"), options: .atomic)
    }

    private static func fileSize(at url: URL) -> Int64? {
        guard
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
            values.isRegularFile == true,
            let size = values.fileSize
        else {
            return nil
        }
        return Int64(size)
    }
}
