import Foundation
import Testing
@testable import PressayShared

@Suite struct ResultQueueTests {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ResultQueueTests-\(UUID().uuidString)")

    func result(_ text: String, createdAt: Date = Date()) -> DictationResult {
        DictationResult(text: text, engine: "fast", createdAt: createdAt, audioSeconds: 1, transcriptionSeconds: 0.1)
    }

    @Test func takesEachResultOnceInOrder() throws {
        let queue = ResultQueue(directory: directory)
        try queue.enqueue(result("un"))
        try queue.enqueue(result("deux"))

        #expect(try queue.takeNext()?.text == "un")
        #expect(try queue.takeNext()?.text == "deux")
        #expect(try queue.takeNext() == nil)
    }

    @Test func dropsResultsOlderThanMaxAge() throws {
        let queue = ResultQueue(directory: directory)
        let now = Date()
        try queue.enqueue(result("ancien", createdAt: now.addingTimeInterval(-700)))
        try queue.enqueue(result("récent", createdAt: now.addingTimeInterval(-10)))

        #expect(try queue.takeNext(now: now, maxAge: 600)?.text == "récent")
        #expect(try queue.pending().isEmpty)
    }

    @Test func keepsOnlyTheNewestResultsBeyondCapacity() throws {
        let queue = ResultQueue(directory: directory)
        for index in 0..<(ResultQueue.capacity + 5) {
            try queue.enqueue(result("\(index)"))
        }

        let pending = try queue.pending()
        #expect(pending.count == ResultQueue.capacity)
        #expect(pending.first?.text == "5")
    }

    /// Stands in for several keyboard instances racing on the same signal.
    @Test func concurrentTakersNeverShareAResult() async throws {
        let queue = ResultQueue(directory: directory)
        for index in 0..<ResultQueue.capacity {
            try queue.enqueue(result("\(index)"))
        }

        let taken = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var mine: [String] = []
                    while let next = try? queue.takeNext() {
                        mine.append(next.text)
                    }
                    return mine
                }
            }
            return await group.reduce(into: []) { $0 += $1 }
        }

        #expect(taken.count == ResultQueue.capacity)
        #expect(Set(taken).count == taken.count)
    }
}
