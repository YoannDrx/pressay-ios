import Foundation
import Observation
import PressayCore
import PressayShared

/// The Fast model on this iPhone: downloaded on demand, resumed after a cut, verified
/// file by file against the manifest compiled into the app.
@MainActor
@Observable
final class ModelLibrary {
    enum Failure: Equatable {
        case insufficientSpace(required: Int64)
        case network
        case integrity
    }

    enum State: Equatable {
        case notInstalled
        case downloading(Double)
        case installed
        case failed(Failure)
    }

    let manifest = ModelManifest.parakeetTDTv3
    private(set) var state: State
    /// Called after the model is deleted, so the engine frees its memory.
    @ObservationIgnored var onRemoved: (() -> Void)?

    @ObservationIgnored private let store: ModelStore
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let background = BackgroundActivity(name: "model-download")

    init(store: ModelStore) {
        self.store = store
        state = store.isInstalled(.parakeetTDTv3) ? .installed : .notInstalled
    }

    /// Bytes already downloaded, kept for a resume.
    var downloadedBytes: Int64 {
        store.bytesOnDisk(for: manifest)
    }

    func download() {
        guard task == nil, state != .installed else { return }
        let manifest = manifest
        let downloader = ModelDownloader(store: store)
        state = .downloading(Double(downloadedBytes) / Double(manifest.totalBytes))
        background.begin()
        PressayLog.shared.event("model.downloadStarted", ["resumedBytes": .int(Int(downloadedBytes))])
        task = Task {
            let start = Date()
            do {
                try await downloader.install(manifest) { progress in
                    Task { @MainActor [weak self] in self?.report(progress) }
                }
                state = .installed
                PressayLog.shared.event("model.installed", ["seconds": .double(Date().timeIntervalSince(start))])
            } catch is CancellationError {
                state = .notInstalled
            } catch let error as ModelDownloadError {
                state = .failed(Self.failure(for: error))
                PressayLog.shared.event("model.downloadFailed", ["reason": .tag(Self.tag(for: error))])
            } catch {
                state = .failed(.network)
                PressayLog.shared.event("model.downloadFailed", [
                    "reason": .tag("network"), "error": ErrorTag.of(error),
                ])
            }
            task = nil
            background.end()
        }
    }

    func cancel() {
        task?.cancel()
    }

    func remove() {
        cancel()
        try? store.remove(manifest)
        state = .notInstalled
        onRemoved?()
        PressayLog.shared.event("model.removed")
    }

    private func report(_ progress: ModelDownloadProgress) {
        guard case .downloading = state else { return }
        state = .downloading(progress.fraction)
    }

    private static func failure(for error: ModelDownloadError) -> Failure {
        switch error {
        case let .insufficientSpace(required, _): .insufficientSpace(required: required)
        case .checksumMismatch, .sizeMismatch: .integrity
        case .httpStatus, .unexpectedRange: .network
        }
    }

    private static func tag(for error: ModelDownloadError) -> String {
        switch error {
        case .insufficientSpace: "insufficientSpace"
        case .checksumMismatch: "checksumMismatch"
        case .sizeMismatch: "sizeMismatch"
        case let .httpStatus(status): "http\(status)"
        case .unexpectedRange: "unexpectedRange"
        }
    }
}
