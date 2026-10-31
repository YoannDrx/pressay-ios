import Foundation
import PressayShared

/// Captures written to disk while the user speaks, so a dictation survives the app being
/// killed: at the next launch, the files still present are orphans to transcribe.
///
/// The format is raw little-endian Float32, 16 kHz mono, without a header: whatever was
/// written before a crash is readable as is, with nothing to finalise.
public struct CaptureStore: Sendable {
    public static let fileExtension = "f32"

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// The store in the App Group, or nil when the container is unreachable.
    public static var shared: CaptureStore? {
        AppGroup.container.map { CaptureStore(directory: $0.appendingPathComponent("Captures", isDirectory: true)) }
    }

    public func url(for id: UUID) -> URL {
        directory.appendingPathComponent(id.uuidString).appendingPathExtension(Self.fileExtension)
    }

    public func makeWriter(id: UUID) throws -> CaptureWriter {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = url(for: id)
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
        // Dictation starts from the Lock Screen: the file must stay writable while locked.
        attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: attributes) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return try CaptureWriter(id: id, url: url)
    }

    /// Every capture on disk, oldest first.
    public func captures() -> [CaptureFile] {
        let keys: [URLResourceKey] = [.creationDateKey, .fileSizeKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url -> CaptureFile? in
            guard url.pathExtension == Self.fileExtension,
                  let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent)
            else { return nil }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return CaptureFile(
                id: id,
                url: url,
                createdAt: values?.creationDate ?? .distantPast,
                sampleCount: (values?.fileSize ?? 0) / MemoryLayout<Float>.size
            )
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    public func readSamples(id: UUID) throws -> [Float] {
        let data = try Data(contentsOf: url(for: id))
        let count = data.count / MemoryLayout<Float>.size
        var samples = [Float](repeating: 0, count: count)
        _ = samples.withUnsafeMutableBytes { data.copyBytes(to: $0, count: count * MemoryLayout<Float>.size) }
        return samples.map { Float(bitPattern: UInt32(littleEndian: $0.bitPattern)) }
    }

    public func remove(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }
}

public struct CaptureFile: Sendable, Equatable {
    public let id: UUID
    public let url: URL
    public let createdAt: Date
    public let sampleCount: Int

    public var seconds: Double { Double(sampleCount) / TranscriptionAudio.sampleRate }
}

/// Appends samples to a capture file. Called from the audio thread, so writes are serialised.
public final class CaptureWriter: @unchecked Sendable {
    public let id: UUID
    public let url: URL
    private let handle: FileHandle
    private let lock = NSLock()
    private var written = 0
    private var isClosed = false

    init(id: UUID, url: URL) throws {
        self.id = id
        self.url = url
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
    }

    deinit {
        if !isClosed {
            try? handle.close()
        }
    }

    public var sampleCount: Int {
        lock.withLock { written }
    }

    public func append(_ samples: UnsafeBufferPointer<Float>) throws {
        guard !samples.isEmpty else { return }
        let littleEndian = samples.map { $0.bitPattern.littleEndian }
        let data = littleEndian.withUnsafeBytes { Data($0) }
        try lock.withLock {
            guard !isClosed else { return }
            try handle.write(contentsOf: data)
            written += samples.count
        }
    }

    public func append(_ samples: [Float]) throws {
        try samples.withUnsafeBufferPointer { try append($0) }
    }

    public func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            try? handle.synchronize()
            try? handle.close()
        }
    }
}
