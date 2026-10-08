import Foundation

final class PhononModelDownloader: NSObject, @unchecked Sendable {
    var onProgress: ((Double) -> Void)?
    var onComplete: (() -> Void)?
    var onError: ((String) -> Void)?

    private let destinationURL: URL
    private let stagingURL: URL
    private let resumeDataURL: URL
    private let resumeAssetURL: URL
    private let fileManager = FileManager.default
    private let stateLock = NSLock()
    private let delegateQueue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.whispermax.phonon-model-downloader"
        queue.maxConcurrentOperationCount = 1
        return queue
    }()

    private var session: URLSession?
    private var downloadTask: URLSessionDownloadTask?
    private var retryTask: DispatchWorkItem?
    private var currentAsset: PhononModelPackage.Asset?
    private var completedByteCount: Int64 = 0
    private var retryCount = 0
    private var isPausing = false
    private let maximumRetryCount = 3

    init(destinationURL: URL = ModelLocator.phononModelURL) {
        self.destinationURL = destinationURL
        stagingURL = ModelLocator.phononStagingModelURL
        resumeDataURL = ModelLocator.phononDownloadResumeDataURL
        resumeAssetURL = ModelLocator.phononDownloadResumeAssetURL
    }

    func start() {
        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        } catch {
            reportError("Could not prepare the Phonon model folder: \(error.localizedDescription)")
            return
        }

        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForResource = 7_200
        configuration.timeoutIntervalForRequest = 30
        configuration.waitsForConnectivity = true
        configuration.allowsExpensiveNetworkAccess = true
        configuration.allowsConstrainedNetworkAccess = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: delegateQueue)
        delegateQueue.addOperation { [weak self] in
            self?.startNextAsset()
        }
    }

    func pause() {
        retryTask?.cancel()
        retryTask = nil

        stateLock.lock()
        isPausing = true
        let task = downloadTask
        let asset = currentAsset
        downloadTask = nil
        stateLock.unlock()

        guard let task, let asset else { return }
        let semaphore = DispatchSemaphore(value: 0)
        task.cancel(byProducingResumeData: { [resumeDataURL, resumeAssetURL] data in
            if let data {
                try? data.write(to: resumeDataURL, options: .atomic)
                try? asset.path.write(to: resumeAssetURL, atomically: true, encoding: .utf8)
            }
            semaphore.signal()
        })
        _ = semaphore.wait(timeout: .now() + 2)
        session?.invalidateAndCancel()
        session = nil
    }

    private func startNextAsset() {
        completedByteCount = 0
        var pendingAsset: PhononModelPackage.Asset?
        for asset in PhononModelPackage.assets {
            guard PhononModelPackage.isValid(asset, in: stagingURL) else {
                pendingAsset = asset
                break
            }
            completedByteCount += asset.byteCount
        }

        guard let asset = pendingAsset else {
            do {
                try installStagedModel()
                clearResumeData()
                session?.finishTasksAndInvalidate()
                session = nil
                reportComplete()
            } catch {
                fail("Could not install the Phonon model: \(error.localizedDescription)")
            }
            return
        }

        stateLock.lock()
        currentAsset = asset
        isPausing = false
        stateLock.unlock()
        retryCount = 0
        startCurrentAsset()
    }

    private func startCurrentAsset() {
        guard let asset = currentAsset, let session else { return }

        let resumeData: Data?
        if (try? String(contentsOf: resumeAssetURL, encoding: .utf8)) == asset.path {
            resumeData = try? Data(contentsOf: resumeDataURL)
        } else {
            resumeData = nil
            clearResumeData()
        }

        let task: URLSessionDownloadTask
        if let resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            var request = URLRequest(url: asset.downloadURL)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            task = session.downloadTask(with: request)
        }

        stateLock.lock()
        downloadTask = task
        stateLock.unlock()
        task.resume()
    }

    private func install(_ asset: PhononModelPackage.Asset, from location: URL) throws {
        guard let response = downloadTask?.response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else {
            throw DownloadError.invalidResponse
        }

        guard
            let size = try? location.resourceValues(forKeys: [.fileSizeKey]).fileSize,
            Int64(size) == asset.byteCount,
            PhononModelPackage.sha256(at: location) == asset.sha256
        else {
            throw DownloadError.integrityCheckFailed(asset.path)
        }

        let targetURL = stagingURL.appendingPathComponent(asset.path)
        try fileManager.createDirectory(
            at: targetURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: targetURL.path) {
            try fileManager.removeItem(at: targetURL)
        }
        try fileManager.moveItem(at: location, to: targetURL)
        clearResumeData()
        completedByteCount += asset.byteCount
    }

    private func installStagedModel() throws {
        try PhononModelPackage.writeInstallationMarker(in: stagingURL)

        let previousURL = ModelLocator.phononPreviousModelURL

        let hadPreviousModel = fileManager.fileExists(atPath: destinationURL.path)
        if hadPreviousModel {
            if fileManager.fileExists(atPath: previousURL.path) {
                try fileManager.removeItem(at: previousURL)
            }
            try fileManager.moveItem(at: destinationURL, to: previousURL)
        }

        do {
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            if hadPreviousModel {
                try? fileManager.removeItem(at: previousURL)
            }
        } catch {
            if hadPreviousModel, !fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.moveItem(at: previousURL, to: destinationURL)
            } else if !hadPreviousModel,
                      !fileManager.fileExists(atPath: destinationURL.path),
                      fileManager.fileExists(atPath: previousURL.path) {
                try? fileManager.moveItem(at: previousURL, to: destinationURL)
            }
            throw error
        }
    }

    private func persistResumeData(_ data: Data?, for asset: PhononModelPackage.Asset) {
        guard let data else {
            clearResumeData()
            return
        }
        try? data.write(to: resumeDataURL, options: .atomic)
        try? asset.path.write(to: resumeAssetURL, atomically: true, encoding: .utf8)
    }

    private func clearResumeData() {
        try? fileManager.removeItem(at: resumeDataURL)
        try? fileManager.removeItem(at: resumeAssetURL)
    }

    private func retryAfterTransientFailure(_ error: Error, for asset: PhononModelPackage.Asset) {
        guard retryCount < maximumRetryCount else {
            fail("Could not download the Phonon model: \(error.localizedDescription)")
            return
        }

        retryCount += 1
        let delay = min(pow(2.0, Double(retryCount - 1)), 4.0)
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.delegateQueue.addOperation {
                guard self.currentAsset?.path == asset.path else { return }
                self.startCurrentAsset()
            }
        }
        retryTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: task)
    }

    private func fail(_ message: String) {
        session?.finishTasksAndInvalidate()
        session = nil
        stateLock.lock()
        downloadTask = nil
        stateLock.unlock()
        reportError(message)
    }

    private func reportProgress(_ progress: Double) {
        DispatchQueue.main.async { [onProgress] in
            onProgress?(progress)
        }
    }

    private func reportComplete() {
        DispatchQueue.main.async { [onComplete] in
            onComplete?()
        }
    }

    private func reportError(_ message: String) {
        DispatchQueue.main.async { [onError] in
            onError?(message)
        }
    }

    private enum DownloadError: LocalizedError {
        case invalidResponse
        case integrityCheckFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The model server returned an invalid response."
            case .integrityCheckFailed(let path):
                return "The downloaded file failed verification (\(path)). Please retry."
            }
        }
    }
}

extension PhononModelDownloader: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let asset = currentAsset else { return }
        let assetProgress = min(1, Double(totalBytesWritten) / Double(asset.byteCount))
        let overall = Double(completedByteCount) / Double(PhononModelPackage.totalByteCount)
            + assetProgress * Double(asset.byteCount) / Double(PhononModelPackage.totalByteCount)
        reportProgress(min(1, overall))
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let asset = currentAsset else { return }
        do {
            try install(asset, from: location)
            retryCount = 0
            stateLock.lock()
            self.downloadTask = nil
            stateLock.unlock()
            delegateQueue.addOperation { [weak self] in
                self?.startNextAsset()
            }
        } catch {
            try? fileManager.removeItem(at: location)
            clearResumeData()
            fail("Could not verify the Phonon model: \(error.localizedDescription)")
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else { return }
        let nsError = error as NSError
        stateLock.lock()
        let shouldIgnoreCancellation = isPausing && nsError.code == NSURLErrorCancelled
        let asset = currentAsset
        stateLock.unlock()
        guard !shouldIgnoreCancellation, let asset else { return }

        let resumeData = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        persistResumeData(resumeData, for: asset)
        stateLock.lock()
        downloadTask = nil
        stateLock.unlock()
        retryAfterTransientFailure(error, for: asset)
    }
}
