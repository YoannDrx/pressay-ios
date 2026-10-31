import Foundation

public struct ModelDownloadProgress: Sendable, Equatable {
    public let completedBytes: Int64
    public let totalBytes: Int64

    public init(completedBytes: Int64, totalBytes: Int64) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
    }

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(completedBytes) / Double(totalBytes)) : 0
    }
}

public enum ModelDownloadError: Error, Equatable, Sendable {
    case insufficientSpace(required: Int64, available: Int64)
    case httpStatus(Int)
    /// The server resumed at another offset than the one asked for.
    case unexpectedRange
    case sizeMismatch(path: String)
    case checksumMismatch(path: String)
}

/// Downloads a model file by file, resuming each one where it stopped, and keeps a file
/// only once its size and SHA-256 match the manifest. Same rules as the Mac's
/// `managers/model/download.rs`: HTTP Range to resume, an offset check on 206, a restart
/// from zero on 200, and a hash mismatch deletes the bytes so the next attempt starts clean.
public struct ModelDownloader: Sendable {
    /// Room left free on the device after the download, so the model never fills it up.
    public static let spareBytes: Int64 = 200 * 1024 * 1024

    private let store: ModelStore
    private let makeConfiguration: @Sendable () -> URLSessionConfiguration
    private let availableCapacity: @Sendable (URL) -> Int64?

    public init(
        store: ModelStore,
        makeConfiguration: @escaping @Sendable () -> URLSessionConfiguration = { .default },
        availableCapacity: @escaping @Sendable (URL) -> Int64? = ModelDownloader.availableCapacity(at:)
    ) {
        self.store = store
        self.makeConfiguration = makeConfiguration
        self.availableCapacity = availableCapacity
    }

    public func install(
        _ manifest: ModelManifest,
        progress: @escaping @Sendable (ModelDownloadProgress) -> Void = { _ in }
    ) async throws {
        let total = manifest.totalBytes
        if store.isInstalled(manifest) {
            progress(ModelDownloadProgress(completedBytes: total, totalBytes: total))
            return
        }
        try store.prepareDirectory(for: manifest)
        let required = total - store.bytesOnDisk(for: manifest)
        if let available = availableCapacity(store.root), available < required + Self.spareBytes {
            throw ModelDownloadError.insufficientSpace(required: required + Self.spareBytes, available: available)
        }

        var completed: Int64 = 0
        progress(ModelDownloadProgress(completedBytes: store.bytesOnDisk(for: manifest), totalBytes: total))
        for file in manifest.files {
            try Task.checkCancellation()
            let destination = store.fileURL(file, in: manifest)
            if ModelStore.size(of: destination) == file.size {
                completed += file.size
                continue
            }
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let partial = store.partialURL(file, in: manifest)
            let before = completed
            try await fetch(file, from: manifest.url(for: file), to: partial) { bytes in
                progress(ModelDownloadProgress(completedBytes: before + bytes, totalBytes: total))
            }
            try verify(file, at: partial)
            try FileManager.default.moveItem(at: partial, to: destination)
            completed += file.size
        }
        try store.markInstalled(manifest)
        progress(ModelDownloadProgress(completedBytes: total, totalBytes: total))
    }

    /// Checks size then SHA-256; on mismatch the bytes are deleted, so a retry starts over.
    func verify(_ file: ModelManifest.File, at url: URL) throws {
        guard ModelStore.size(of: url) == file.size else {
            try? FileManager.default.removeItem(at: url)
            throw ModelDownloadError.sizeMismatch(path: file.path)
        }
        guard try ModelStore.sha256(of: url) == file.sha256 else {
            try? FileManager.default.removeItem(at: url)
            throw ModelDownloadError.checksumMismatch(path: file.path)
        }
    }

    private func fetch(
        _ file: ModelManifest.File,
        from url: URL,
        to partial: URL,
        onBytes: @escaping @Sendable (Int64) -> Void
    ) async throws {
        var offset = ModelStore.size(of: partial) ?? 0
        if offset > file.size {
            try? FileManager.default.removeItem(at: partial)
            offset = 0
        }
        if offset == file.size {
            onBytes(offset)
            return
        }
        if offset == 0 {
            FileManager.default.createFile(atPath: partial.path, contents: nil)
        }
        var request = URLRequest(url: url)
        if offset > 0 {
            request.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        }
        let delegate = try StreamingDelegate(fileURL: partial, offset: offset, onBytes: onBytes)
        let session = URLSession(configuration: makeConfiguration(), delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.start(session.dataTask(with: request), continuation: continuation)
            }
        } onCancel: {
            delegate.cancel()
        }
    }

    public static func availableCapacity(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}

/// Appends the body of one response to a partial file, validating the resume offset first.
private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let requestedOffset: Int64
    private let onBytes: @Sendable (Int64) -> Void
    private var offset: Int64
    private var written: Int64 = 0
    private var lastReported: Int64 = 0
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?
    private var isCancelled = false

    init(fileURL: URL, offset: Int64, onBytes: @escaping @Sendable (Int64) -> Void) throws {
        handle = try FileHandle(forWritingTo: fileURL)
        requestedOffset = offset
        self.offset = offset
        self.onBytes = onBytes
    }

    func start(_ task: URLSessionDataTask, continuation: CheckedContinuation<Void, Error>) {
        let cancelled = lock.withLock {
            self.task = task
            self.continuation = continuation
            return isCancelled
        }
        if cancelled {
            task.cancel()
        } else {
            task.resume()
        }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void
    ) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        do {
            switch status {
            case 206:
                guard Self.rangeStart(of: response) == requestedOffset else {
                    throw ModelDownloadError.unexpectedRange
                }
                try handle.seek(toOffset: UInt64(requestedOffset))
            case 200:
                // The server ignored the Range header: start the file over.
                try handle.truncate(atOffset: 0)
                lock.withLock { offset = 0 }
            default:
                throw ModelDownloadError.httpStatus(status)
            }
            completionHandler(.allow)
        } catch {
            lock.withLock { failure = error }
            completionHandler(.cancel)
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            lock.withLock { failure = error }
            dataTask.cancel()
            return
        }
        let report: Int64? = lock.withLock {
            written += Int64(data.count)
            let position = offset + written
            guard position - lastReported >= 256 * 1024 else { return nil }
            lastReported = position
            return position
        }
        if let report { onBytes(report) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        try? handle.synchronize()
        try? handle.close()
        let (continuation, failure, cancelled, position) = lock.withLock {
            let pending = self.continuation
            self.continuation = nil
            return (pending, self.failure, isCancelled, offset + written)
        }
        onBytes(position)
        if let failure {
            continuation?.resume(throwing: failure)
        } else if cancelled {
            continuation?.resume(throwing: CancellationError())
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume()
        }
    }

    /// `Content-Range: bytes 100-199/200` → 100.
    static func rangeStart(of response: URLResponse) -> Int64? {
        guard let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"),
              let range = header.split(separator: " ").last,
              let start = range.split(separator: "-").first
        else { return nil }
        return Int64(start)
    }
}
