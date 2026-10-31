import Foundation
import os

/// A value the journal accepts. There is deliberately no free-form string case:
/// dictated text must never reach the journal, only lengths, timings and identifiers.
public enum LogValue: Sendable, Equatable {
    case int(Int)
    case double(Double)
    case bool(Bool)
    /// A short identifier such as an engine name or an error code, never user content.
    case tag(String)

    var jsonValue: Any {
        switch self {
        case let .int(value): value
        case let .double(value): value
        case let .bool(value): value
        case let .tag(value): value
        }
    }
}

extension LogValue: ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

/// Append-only JSON Lines journal in the App Group, readable from the app so a tester
/// can share it. Writes are synchronous: intents and extensions can be suspended
/// right after they return. The app, the keyboard and the widgets append to the same
/// file, so each line is written under a file lock: in the spike, unlocked writes from
/// two processes corrupted 1 line in 1,488.
public struct PressayLog: Sendable {
    private static let queue = DispatchQueue(label: "fr.yodev.pressay.log")

    public let fileURL: URL?
    private let process: String
    private let logger: Logger

    public init(fileURL: URL?, process: String = Bundle.main.bundleIdentifier ?? "unknown") {
        self.fileURL = fileURL
        self.process = process
        self.logger = Logger(subsystem: "fr.yodev.pressay", category: "journal")
    }

    public static let shared = PressayLog(fileURL: AppGroup.container?.appendingPathComponent("journal.jsonl"))

    /// `name` is a `StaticString` so an event name can never be built from user content.
    public func event(_ name: StaticString, _ fields: [String: LogValue] = [:], at date: Date = Date()) {
        let eventName = name.description
        var entry = fields.mapValues(\.jsonValue)
        entry["event"] = eventName
        entry["at"] = date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        entry["process"] = process
        logger.info("\(eventName, privacy: .public)")
        guard let url = fileURL,
              let data = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys])
        else { return }
        var line = data
        line.append(0x0A)
        Self.queue.sync {
            try? lock(for: url).withLock {
                if let handle = try? FileHandle(forWritingTo: url) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: line)
                } else {
                    try? line.write(to: url)
                }
            }
        }
    }

    public func readAll() -> String {
        guard let url = fileURL else { return "" }
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    public func clear() {
        guard let url = fileURL else { return }
        Self.queue.sync {
            _ = try? lock(for: url).withLock { try? FileManager.default.removeItem(at: url) }
        }
    }

    private func lock(for url: URL) -> FileLock {
        FileLock(url: url.appendingPathExtension("lock"))
    }
}
