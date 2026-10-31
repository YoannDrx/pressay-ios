import ActivityKit
import Foundation
import PressayShared

/// The Live Activity and Dynamic Island of a dictation: elapsed time and a Stop button
/// while recording, then the outcome for a few seconds.
@MainActor
final class LiveActivityController {
    private var activity: Activity<DictationActivityAttributes>?
    private var startedAt = Date()

    @discardableResult
    func start(startedAt: Date) -> Bool {
        self.startedAt = startedAt
        let stale = Activity<DictationActivityAttributes>.activities
        if !stale.isEmpty {
            Task {
                for activity in stale {
                    await activity.end(nil, dismissalPolicy: .immediate)
                }
            }
        }
        do {
            activity = try Activity.request(
                attributes: DictationActivityAttributes(),
                content: .init(state: state(.recording), staleDate: nil)
            )
            return true
        } catch {
            PressayLog.shared.event("liveActivity.failed", [
                "error": ErrorTag.of(error),
                "enabled": .bool(ActivityAuthorizationInfo().areActivitiesEnabled),
            ])
            return false
        }
    }

    func update(_ phase: DictationPhase) {
        guard let activity else { return }
        let content = ActivityContent(state: state(phase), staleDate: nil)
        Task { await activity.update(content) }
    }

    func end(_ phase: DictationPhase) {
        guard let activity else { return }
        let content = ActivityContent(state: state(phase), staleDate: nil)
        Task { await activity.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4))) }
        self.activity = nil
    }

    private func state(_ phase: DictationPhase) -> DictationActivityAttributes.ContentState {
        .init(phase: phase, startedAt: startedAt)
    }
}
