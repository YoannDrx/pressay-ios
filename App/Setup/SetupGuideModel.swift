import AVFoundation
import Foundation
import Observation
import PressayCore
import PressayShared
import UIKit

/// A page of the setup guide.
enum SetupPage: Hashable {
    case welcome
    case step(SetupStep)
    case finished
}

/// The setup guide's state: what is done, which page shows, and where to resume. Each step
/// ticks itself from evidence (`SetupEvidence`) re-read when the app comes back to the front
/// and when the keyboard or an intent leaves a mark (`PressaySignal.setupChanged`).
@MainActor
@Observable
final class SetupGuideModel {
    static let shared = SetupGuideModel()

    private enum Key {
        static let completed = "setup.completed"
        static let savedPage = "setup.savedStep"
        static let welcomeSeen = "setup.welcomeSeen"
        static let triggerSkipped = "setup.triggerSkipped"
        static let actionButton = "setup.hasActionButton"
    }

    private(set) var evidence = SetupEvidence()
    var page: SetupPage = .welcome {
        didSet { save(page) }
    }
    var isPresented = false
    /// Whether this iPhone has an Action button; the user can correct the guess.
    var hasActionButton: Bool {
        didSet { defaults.set(hasActionButton, forKey: Key.actionButton) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var advanceTask: Task<Void, Never>?

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasActionButton = defaults.object(forKey: Key.actionButton) as? Bool
            ?? ActionButtonSupport.isAvailable(modelIdentifier: Self.modelIdentifier)
        evidence = currentEvidence()
        DarwinNotifier.observe(PressaySignal.setupChanged) {
            Task { @MainActor in SetupGuideModel.shared.refresh() }
        }
        if !isCompleted {
            page = resumePage()
            isPresented = true
        }
    }

    var isCompleted: Bool {
        defaults.bool(forKey: Key.completed)
    }

    // MARK: Navigation

    func begin() {
        defaults.set(true, forKey: Key.welcomeSeen)
        go(to: evidence.firstPending.map(SetupPage.step) ?? .finished)
    }

    func go(to page: SetupPage) {
        advanceTask?.cancel()
        self.page = page
    }

    /// The page after `step`: the next step still to do, or the end.
    func next(after step: SetupStep) -> SetupPage {
        let later = SetupStep.allCases.filter { $0.rawValue > step.rawValue && !evidence.isDone($0) }
        if let first = later.first { return .step(first) }
        return evidence.firstPending.map(SetupPage.step) ?? .finished
    }

    func previous(before step: SetupStep) -> SetupPage {
        SetupStep(rawValue: step.rawValue - 1).map(SetupPage.step) ?? .welcome
    }

    func skipTrigger() {
        defaults.set(true, forKey: Key.triggerSkipped)
        refresh()
        go(to: next(after: .trigger))
    }

    func finish() {
        defaults.set(true, forKey: Key.completed)
        isPresented = false
        PressayLog.shared.event("setup.finished", ["doneSteps": .int(evidence.doneCount)])
    }

    /// Closes the guide; it opens again at the same page at the next launch.
    func postpone() {
        isPresented = false
        PressayLog.shared.event("setup.postponed", ["doneSteps": .int(evidence.doneCount)])
    }

    /// From the settings or the home screen: opens where the user left, or from the start
    /// once the guide was finished.
    func open() {
        refresh()
        if isCompleted {
            defaults.set(false, forKey: Key.completed)
            defaults.set(false, forKey: Key.triggerSkipped)
            refresh()
            go(to: .welcome)
        } else {
            go(to: resumePage())
        }
        isPresented = true
    }

    private func resumePage() -> SetupPage {
        guard defaults.bool(forKey: Key.welcomeSeen) else { return .welcome }
        let saved = (defaults.object(forKey: Key.savedPage) as? Int).flatMap(SetupStep.init(rawValue:))
        return SetupResume.step(saved: saved, evidence: evidence).map(SetupPage.step) ?? .finished
    }

    private func save(_ page: SetupPage) {
        if case let .step(step) = page {
            defaults.set(step.rawValue, forKey: Key.savedPage)
        }
    }

    // MARK: Evidence

    /// Re-reads the evidence; when the step on screen just got done, moves on after a beat
    /// so the user sees it ticked.
    func refresh() {
        let before = evidence
        evidence = currentEvidence()
        guard case let .step(step) = page, !before.isDone(step), evidence.isDone(step) else { return }
        PressayLog.shared.event("setup.stepDone", ["step": .int(step.rawValue)])
        advanceTask?.cancel()
        advanceTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled, let self, self.page == .step(step) else { return }
            self.page = self.next(after: step)
        }
    }

    private func currentEvidence() -> SetupEvidence {
        let marks = SetupMarks.shared
        return SetupEvidence(
            microphoneGranted: AVAudioApplication.shared.recordPermission == .granted,
            keyboardAdded: Self.isKeyboardAdded,
            fullAccessSeen: marks?.keyboardFullAccessAt != nil,
            triggerUsed: marks?.intentUsedAt != nil,
            triggerSkipped: defaults.bool(forKey: Key.triggerSkipped),
            insertionSeen: marks?.lastInsertionAt != nil
        )
    }

    var microphoneDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    func requestMicrophone() async {
        let granted = await AVAudioApplication.requestRecordPermission()
        PressayLog.shared.event("setup.microphone", ["granted": .bool(granted)])
        refresh()
    }

    func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// The Pressay keyboard among the keyboards the user turned on. iOS has no public call
    /// for this; the input mode's identifier is the extension's bundle identifier.
    static var isKeyboardAdded: Bool {
        let keyboardID = (Bundle.main.bundleIdentifier ?? "fr.yodev.pressay") + ".keyboard"
        let selector = NSSelectorFromString("identifier")
        return UITextInputMode.activeInputModes.contains { mode in
            mode.responds(to: selector) && (mode.value(forKey: "identifier") as? String) == keyboardID
        }
    }

    /// The hardware model, such as "iPhone17,3"; the simulated one in the simulator.
    private static var modelIdentifier: String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { buffer in
            String(bytes: buffer.prefix { $0 != 0 }, encoding: .utf8) ?? ""
        }
    }
}
