import Foundation

/// Pending dictations, stored as one JSON file in the App Group.
///
/// Every read-modify-write runs under an exclusive `flock`, so when several processes
/// race (the app, the visible keyboard, a stale keyboard instance iOS kept alive),
/// each result is taken exactly once. The lock is held for a few milliseconds only:
/// iOS kills a suspended process that still holds a file lock in a shared container.
public struct ResultQueue: Sendable {
    public static let capacity = 20

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The queue in the App Group, or nil when the container is unreachable.
    public static var shared: ResultQueue? {
        AppGroup.container.map(ResultQueue.init(directory:))
    }

    private var fileURL: URL { directory.appendingPathComponent("pending-results.json") }
    private var lockURL: URL { directory.appendingPathComponent("pending-results.lock") }

    public func enqueue(_ result: DictationResult) throws {
        try withLock {
            var items = try read()
            items.append(result)
            if items.count > Self.capacity {
                items.removeFirst(items.count - Self.capacity)
            }
            try write(items)
        }
    }

    /// Removes and returns the oldest result younger than `maxAge`; older ones are dropped,
    /// so a dictation nobody inserted never lands in an unrelated field much later.
    public func takeNext(now: Date = Date(), maxAge: TimeInterval = 600) throws -> DictationResult? {
        try withLock {
            var items = try read().filter { now.timeIntervalSince($0.createdAt) <= maxAge }
            let next = items.isEmpty ? nil : items.removeFirst()
            try write(items)
            return next
        }
    }

    public func pending() throws -> [DictationResult] {
        try withLock { try read() }
    }

    public func removeAll() throws {
        try withLock { try write([]) }
    }

    private func read() throws -> [DictationResult] {
        guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { return [] }
        return try JSONDecoder.pressay.decode([DictationResult].self, from: data)
    }

    private func write(_ items: [DictationResult]) throws {
        let data = try JSONEncoder.pressay.encode(items)
        try data.write(to: fileURL, options: .atomic)
    }

    private func withLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

extension JSONEncoder {
    static var pressay: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

extension JSONDecoder {
    static var pressay: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
