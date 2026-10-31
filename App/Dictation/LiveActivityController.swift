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
        let stale = Activity<DictationActivityAttributes>.activities.map(SendableActivity.init)
        if !stale.isEmpty {
            Task {
                for item in stale {
                    await item.end(nil, dismissalPolicy: .immediate)
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
        let item = SendableActivity(activity: activity)
        let content = ActivityContent(state: state(phase), staleDate: nil)
        Task { await item.update(content) }
    }

    func end(_ phase: DictationPhase) {
        guard let activity else { return }
        let item = SendableActivity(activity: activity)
        let content = ActivityContent(state: state(phase), staleDate: nil)
        Task { await item.end(content, dismissalPolicy: .after(Date().addingTimeInterval(4))) }
        self.activity = nil
    }

    private func state(_ phase: DictationPhase) -> DictationActivityAttributes.ContentState {
        .init(phase: phase, startedAt: startedAt)
    }
}

/// Some SDKs (iOS 26.5) do not mark `Activity` as `Sendable`, though ActivityKit documents
/// its methods as safe to call from any task; this hands one to a task without a warning.
private struct SendableActivity: @unchecked Sendable {
    let activity: Activity<DictationActivityAttributes>

    func update(_ content: ActivityContent<DictationActivityAttributes.ContentState>) async {
        await activity.update(content)
    }

    func end(
        _ content: ActivityContent<DictationActivityAttributes.ContentState>?,
        dismissalPolicy: ActivityUIDismissalPolicy
    ) async {
        await activity.end(content, dismissalPolicy: dismissalPolicy)
    }
}
