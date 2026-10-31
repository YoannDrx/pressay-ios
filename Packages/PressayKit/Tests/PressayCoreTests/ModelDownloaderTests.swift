import CryptoKit
import Foundation
import Testing
@testable import PressayCore

/// Serves in-memory files and honours `Range`, like the model host.
final class StubModelServer: URLProtocol, @unchecked Sendable {
    struct Behaviour {
        var files: [String: Data] = [:]
        var ignoresRange = false
        var wrongRangeStart = false
        var status: Int?
        var requests: [(path: String, range: String?)] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var behaviour = Behaviour()

    static func reset(_ newValue: Behaviour) {
        lock.withLock { behaviour = newValue }
    }

    static var requests: [(path: String, range: String?)] {
        lock.withLock { behaviour.requests }
    }

    static func configuration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubModelServer.self]
        return configuration
    }

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url, let client else { return }
        let range = request.value(forHTTPHeaderField: "Range")
        let current = Self.lock.withLock {
            Self.behaviour.requests.append((url.lastPathComponent, range))
            return Self.behaviour
        }
        let key = url.path.components(separatedBy: "/resolve/rev/").last ?? ""
        guard let body = current.files[key] else {
            respond(client, url: url, status: 404, headers: [:], body: Data())
            return
        }
        if let status = current.status {
            respond(client, url: url, status: status, headers: [:], body: Data())
        } else if let range, !current.ignoresRange,
                  let start = Int(range.dropFirst("bytes=".count).dropLast()) {
            let served = current.wrongRangeStart ? 0 : start
            let headers = ["Content-Range": "bytes \(served)-\(body.count - 1)/\(body.count)"]
            respond(client, url: url, status: 206, headers: headers, body: body.subdata(in: start..<body.count))
        } else {
            respond(client, url: url, status: 200, headers: [:], body: body)
        }
    }

    private func respond(_ client: URLProtocolClient, url: URL, status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client.urlProtocol(self, didLoad: body)
        client.urlProtocolDidFinishLoading(self)
    }
}

@Suite(.serialized) struct ModelDownloaderTests {
    let store = ModelStore(
        root: FileManager.default.temporaryDirectory.appendingPathComponent("ModelDownloaderTests-\(UUID().uuidString)")
    )
    let weights = Data((0..<300_000).map { UInt8($0 % 251) })
    let vocabulary = Data("{\"0\":\"a\"}".utf8)

    var manifest: ModelManifest {
        ModelManifest(
            id: "test-model",
            revision: "rev",
            baseURL: URL(string: "https://models.example/test/resolve/rev")!,
            files: [
                .init(path: "Model.mlmodelc/weights/weight.bin", size: Int64(weights.count), sha256: Self.hash(weights)),
                .init(path: "vocab.json", size: Int64(vocabulary.count), sha256: Self.hash(vocabulary)),
            ]
        )
    }

    var served: StubModelServer.Behaviour {
        StubModelServer.Behaviour(files: ["Model.mlmodelc/weights/weight.bin": weights, "vocab.json": vocabulary])
    }

    static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func downloader(capacity: Int64? = nil) -> ModelDownloader {
        ModelDownloader(store: store, makeConfiguration: StubModelServer.configuration) { _ in capacity }
    }

    @Test func installsAndVerifiesEveryFile() async throws {
        StubModelServer.reset(served)
        let reports = ProgressRecorder()
        try await downloader().install(manifest) { reports.append($0) }

        #expect(store.isInstalled(manifest))
        let installed = store.directory(for: manifest).appendingPathComponent("Model.mlmodelc/weights/weight.bin")
        #expect(try Data(contentsOf: installed) == weights)
        #expect(reports.last == ModelDownloadProgress(completedBytes: manifest.totalBytes, totalBytes: manifest.totalBytes))
    }

    @Test func resumesAPartialFileWithARangeRequest() async throws {
        StubModelServer.reset(served)
        let file = manifest.files[0]
        let partial = store.partialURL(file, in: manifest)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try weights.prefix(100_000).write(to: partial)

        try await downloader().install(manifest)

        #expect(StubModelServer.requests.first?.range == "bytes=100000-")
        #expect(store.isInstalled(manifest))
        #expect(try Data(contentsOf: store.fileURL(file, in: manifest)) == weights)
    }

    @Test func restartsWhenTheServerIgnoresTheRange() async throws {
        var behaviour = served
        behaviour.ignoresRange = true
        StubModelServer.reset(behaviour)
        let file = manifest.files[0]
        let partial = store.partialURL(file, in: manifest)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try weights.prefix(100_000).write(to: partial)

        try await downloader().install(manifest)

        #expect(try Data(contentsOf: store.fileURL(file, in: manifest)) == weights)
    }

    @Test func rejectsAResumeAtTheWrongOffset() async throws {
        var behaviour = served
        behaviour.wrongRangeStart = true
        StubModelServer.reset(behaviour)
        let partial = store.partialURL(manifest.files[0], in: manifest)
        try FileManager.default.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        try weights.prefix(100_000).write(to: partial)

        await #expect(throws: ModelDownloadError.unexpectedRange) {
            try await downloader().install(manifest)
        }
        #expect(!store.isInstalled(manifest))
    }

    @Test func deletesAFileWhoseHashDoesNotMatch() async throws {
        var behaviour = served
        var tampered = weights
        tampered[42] ^= 0xFF
        behaviour.files["Model.mlmodelc/weights/weight.bin"] = tampered
        StubModelServer.reset(behaviour)

        await #expect(throws: ModelDownloadError.checksumMismatch(path: "Model.mlmodelc/weights/weight.bin")) {
            try await downloader().install(manifest)
        }
        #expect(!store.isInstalled(manifest))
        #expect(store.bytesOnDisk(for: manifest) == 0)
    }

    @Test func reportsAServerError() async throws {
        var behaviour = served
        behaviour.status = 503
        StubModelServer.reset(behaviour)
        await #expect(throws: ModelDownloadError.httpStatus(503)) {
            try await downloader().install(manifest)
        }
    }

    @Test func refusesToFillTheDevice() async throws {
        StubModelServer.reset(served)
        await #expect(throws: ModelDownloadError.insufficientSpace(
            required: manifest.totalBytes + ModelDownloader.spareBytes, available: 1000
        )) {
            try await downloader(capacity: 1000).install(manifest)
        }
        #expect(StubModelServer.requests.isEmpty)
    }

    @Test func aMissingFileUninstallsTheModel() async throws {
        StubModelServer.reset(served)
        try await downloader().install(manifest)
        try FileManager.default.removeItem(at: store.fileURL(manifest.files[1], in: manifest))
        #expect(!store.isInstalled(manifest))

        try await downloader().install(manifest)
        #expect(store.isInstalled(manifest))
        #expect(StubModelServer.requests.map(\.path) == ["weight.bin", "vocab.json", "vocab.json"])
    }

    @Test func removesTheModel() async throws {
        StubModelServer.reset(served)
        try await downloader().install(manifest)
        try store.remove(manifest)
        #expect(!store.isInstalled(manifest))
    }
}

final class ProgressRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ModelDownloadProgress] = []

    func append(_ value: ModelDownloadProgress) {
        lock.withLock { values.append(value) }
    }

    var last: ModelDownloadProgress? {
        lock.withLock { values.last }
    }
}

@Suite struct ModelManifestTests {
    @Test func parakeetManifestIsWellFormed() {
        let manifest = ModelManifest.parakeetTDTv3
        #expect(Set(manifest.files.map(\.path)).count == manifest.files.count)
        #expect(manifest.files.allSatisfy { $0.sha256.count == 64 && $0.sha256 == $0.sha256.lowercased() })
        #expect(manifest.files.allSatisfy { $0.size > 0 })
        #expect(manifest.totalBytes == 483_105_645)
        // FluidAudio loads these four Core ML bundles and the vocabulary for Parakeet v3.
        let roots = Set(manifest.files.map { String($0.path.split(separator: "/")[0]) })
        #expect(roots == [
            "Preprocessor.mlmodelc", "Encoder.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc",
            "parakeet_vocab.json",
        ])
    }

    @Test func urlsArePinnedToTheRevision() {
        let manifest = ModelManifest.parakeetTDTv3
        let url = manifest.url(for: manifest.files[0]).absoluteString
        #expect(url.hasPrefix("https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v3-coreml/resolve/\(manifest.revision)/"))
        #expect(url.hasSuffix("/Preprocessor.mlmodelc/analytics/coremldata.bin"))
    }

    @Test func hashesAFile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(UUID().uuidString)")
        try Data("pressay".utf8).write(to: url)
        #expect(try ModelStore.sha256(of: url) == ModelDownloaderTests.hash(Data("pressay".utf8)))
    }
}
