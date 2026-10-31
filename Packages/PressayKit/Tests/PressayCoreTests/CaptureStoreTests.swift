import Foundation
import Testing
@testable import PressayCore

@Suite struct CaptureStoreTests {
    let store = CaptureStore(
        directory: FileManager.default.temporaryDirectory.appendingPathComponent("CaptureStoreTests-\(UUID().uuidString)")
    )

    @Test func readsBackWhatWasWritten() throws {
        let id = UUID()
        let writer = try store.makeWriter(id: id)
        try writer.append([0.25, -0.5])
        try writer.append([1, 0, -1])
        #expect(writer.sampleCount == 5)
        writer.close()

        #expect(try store.readSamples(id: id) == [0.25, -0.5, 1, 0, -1])
    }

    /// A process killed mid-dictation never closes its writer: the file must still be readable.
    @Test func anUnclosedCaptureIsAnOrphanWithItsSamples() throws {
        let id = UUID()
        let writer = try store.makeWriter(id: id)
        try writer.append([Float](repeating: 0.1, count: 16000))

        let orphans = store.captures()
        #expect(orphans.map(\.id) == [id])
        #expect(orphans.first?.sampleCount == 16000)
        #expect(orphans.first?.seconds == 1)
        #expect(try store.readSamples(id: id).count == 16000)
    }

    @Test func removesACapture() throws {
        let id = UUID()
        try store.makeWriter(id: id).close()
        store.remove(id: id)
        #expect(store.captures().isEmpty)
    }

    @Test func ignoresUnrelatedFiles() throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: store.directory.appendingPathComponent("notes.txt"))
        #expect(store.captures().isEmpty)
    }

    @Test func writesAfterCloseAreDropped() throws {
        let writer = try store.makeWriter(id: UUID())
        writer.close()
        try writer.append([1, 2])
        #expect(writer.sampleCount == 0)
    }
}
