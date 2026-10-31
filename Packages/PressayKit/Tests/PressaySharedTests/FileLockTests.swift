import Foundation
import Testing
@testable import PressayShared

@Suite struct FileLockTests {
    /// Every `withLock` opens its own descriptor, and `flock` locks belong to the open file
    /// description, so threads here contend exactly as separate processes would.
    @Test func neverLetsTwoHoldersInAtOnce() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        let counter = Counter()

        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            try? FileLock(url: url).withLock {
                counter.enter()
                Thread.sleep(forTimeInterval: 0.002)
                counter.leave()
            }
        }

        #expect(counter.entries == 16)
        #expect(counter.maxInside == 1)
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var inside = 0
    private(set) var entries = 0
    private(set) var maxInside = 0

    func enter() {
        lock.withLock {
            inside += 1
            entries += 1
            maxInside = max(maxInside, inside)
        }
    }

    func leave() {
        lock.withLock { inside -= 1 }
    }
}
