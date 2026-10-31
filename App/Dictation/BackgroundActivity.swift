import UIKit

/// Asks iOS for time to finish work after the app leaves the screen.
@MainActor
final class BackgroundActivity {
    private let name: String
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        self.name = name
    }

    func begin() {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }

    static var applicationStateTag: String {
        switch UIApplication.shared.applicationState {
        case .active: "active"
        case .inactive: "inactive"
        case .background: "background"
        @unknown default: "unknown"
        }
    }
}
