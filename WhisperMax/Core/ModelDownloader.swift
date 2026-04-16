import Foundation

final class ModelDownloader: NSObject {
    static let remoteURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"
    )!

    var onProgress: ((Double) -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((String) -> Void)?

    private var downloadTask: URLSessionDownloadTask?
    private var session: URLSession?

    func start() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 7200 // 2 hours
        config.timeoutIntervalForRequest = 60

        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        downloadTask = session?.downloadTask(with: Self.remoteURL)
        downloadTask?.resume()
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async { self.onProgress?(progress) }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let dest = ModelLocator.appLocalModelURL
        do {
            try FileManager.default.createDirectory(
                at: ModelLocator.modelsDirectory,
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: dest.path) {
                try FileManager.default.removeItem(at: dest)
            }
            try FileManager.default.moveItem(at: location, to: dest)
            DispatchQueue.main.async { self.onComplete?() }
        } catch {
            DispatchQueue.main.async {
                self.onError?("Failed to save model: \(error.localizedDescription)")
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        // Ignore cancellation
        let nsError = error as NSError
        guard nsError.code != NSURLErrorCancelled else { return }
        DispatchQueue.main.async {
            self.onError?(error.localizedDescription)
        }
    }
}
