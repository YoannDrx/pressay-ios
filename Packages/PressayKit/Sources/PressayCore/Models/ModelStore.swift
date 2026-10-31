import CryptoKit
import Foundation

/// Where downloaded models live: Application Support, excluded from backups (they can be
/// downloaded again), one directory per model and revision.
public struct ModelStore: Sendable {
    public let root: URL

    public init(root: URL) {
        self.root = root
    }

    /// `Application Support/Models` of the current process.
    public static var applicationSupport: ModelStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ModelStore(root: base.appendingPathComponent("Models", isDirectory: true))
    }

    public func directory(for manifest: ModelManifest) -> URL {
        root.appendingPathComponent(manifest.id, isDirectory: true)
            .appendingPathComponent(manifest.revision, isDirectory: true)
    }

    func fileURL(_ file: ModelManifest.File, in manifest: ModelManifest) -> URL {
        file.path.split(separator: "/").reduce(directory(for: manifest)) { $0.appendingPathComponent(String($1)) }
    }

    func partialURL(_ file: ModelManifest.File, in manifest: ModelManifest) -> URL {
        let url = fileURL(file, in: manifest)
        return url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".partial")
    }

    private func markerURL(for manifest: ModelManifest) -> URL {
        directory(for: manifest).appendingPathComponent(".installed")
    }

    /// True once every file was downloaded and verified. Checks sizes, not hashes: hashing
    /// 480 MB at each launch would cost seconds, and each file was hashed before it was kept.
    public func isInstalled(_ manifest: ModelManifest) -> Bool {
        guard FileManager.default.fileExists(atPath: markerURL(for: manifest).path) else { return false }
        return manifest.files.allSatisfy { file in
            Self.size(of: fileURL(file, in: manifest)) == file.size
        }
    }

    func markInstalled(_ manifest: ModelManifest) throws {
        try Data(manifest.revision.utf8).write(to: markerURL(for: manifest), options: .atomic)
    }

    /// Bytes already on disk for `manifest`, verified or partial: what a resumed download skips.
    public func bytesOnDisk(for manifest: ModelManifest) -> Int64 {
        manifest.files.reduce(0) { total, file in
            let complete = Self.size(of: fileURL(file, in: manifest))
            if complete == file.size { return total + file.size }
            return total + min(Self.size(of: partialURL(file, in: manifest)) ?? 0, file.size)
        }
    }

    /// Removes every revision of the model.
    public func remove(_ manifest: ModelManifest) throws {
        let url = root.appendingPathComponent(manifest.id, isDirectory: true)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// Creates the model directory, excluded from iCloud and device backups.
    func prepareDirectory(for manifest: ModelManifest) throws {
        try FileManager.default.createDirectory(at: directory(for: manifest), withIntermediateDirectories: true)
        var rootURL = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? rootURL.setResourceValues(values)
    }

    static func size(of url: URL) -> Int64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        return (attributes[.size] as? NSNumber)?.int64Value
    }

    /// Lowercase hexadecimal SHA-256 of a file, read in 1 MB chunks.
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
