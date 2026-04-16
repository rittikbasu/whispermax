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

        // Resume from where we left off if interrupted previously
        if let resumeData = try? Data(contentsOf: ModelLocator.downloadResumeDataURL) {
            downloadTask = session?.downloadTask(withResumeData: resumeData)
        } else {
            downloadTask = session?.downloadTask(with: Self.remoteURL)
        }

        downloadTask?.resume()
    }

    // Call on app termination — blocks until resume data is written so next launch can pick up mid-download
    func pause() {
        guard let task = downloadTask else { return }
        downloadTask = nil

        let semaphore = DispatchSemaphore(value: 0)
        task.cancel(byProducingResumeData: { resumeData in
            if let resumeData {
                try? resumeData.write(to: ModelLocator.downloadResumeDataURL)
            }
            semaphore.signal()
        })
        // Wait up to 2 seconds for the resume data to be written before the process exits
        _ = semaphore.wait(timeout: .now() + 2)
    }

    func cancel() {
        downloadTask?.cancel()
        downloadTask = nil
        try? FileManager.default.removeItem(at: ModelLocator.downloadResumeDataURL)
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
            // Clean up resume data — download is complete
            try? FileManager.default.removeItem(at: ModelLocator.downloadResumeDataURL)
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
        let nsError = error as NSError
        // Cancellation is intentional — don't report as error
        guard nsError.code != NSURLErrorCancelled else { return }

        // If the session has resume data (e.g. network drop), save it for next launch
        if let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
            try? resumeData.write(to: ModelLocator.downloadResumeDataURL)
        }

        DispatchQueue.main.async {
            self.onError?(error.localizedDescription)
        }
    }
}
