import PressayShared
import UIKit

/// What `DictationLink` needs from its keyboard.
@MainActor
protocol DictationHost: AnyObject {
    var textDocumentProxy: any UITextDocumentProxy { get }
    var hasFullAccess: Bool { get }
    /// The text before the cursor, accounting for edits the host has not reflected yet.
    var contextBefore: String? { get }
    func recordEdits(_ edits: [TextEdit], from before: String?)
    /// The bar state or the undo availability changed.
    func dictationLinkDidChange(_ link: DictationLink)
    /// Text was inserted or removed: automatic capitals must follow.
    func dictationLinkDidEditText(_ link: DictationLink)
}

/// The keyboard's side of a dictation: follows the session the app publishes in the App
/// Group, asks the app to start or stop, and inserts results.
///
/// iOS keeps earlier keyboard instances alive in the same process, so there is a single
/// Darwin observer per process (`DarwinNotifier` and `observeOnce`) and only the visible
/// instance acts on a signal (spike S3). The keyboard never opens the app (App Review 4.4.1)
/// and never touches the network.
@MainActor
final class DictationLink {
    static let visible = VisibleInstance<DictationLink>()
    private static var isObserving = false
    /// Results inserted by any instance of this process.
    private static var insertedIDs = Set<UUID>()
    static let memoryInterval: Duration = .seconds(15)

    weak var host: DictationHost?
    private(set) var barState: KeyboardBarState = .ready
    private var undo: InsertionUndo?
    private var lastInsertionAt: Date?
    private var toggleRequestedAt: Date?
    private var refreshTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    private var peakMemoryMB = 0.0

    var canUndo: Bool {
        guard let undo, let host else { return false }
        return undo.isAvailable(contextBefore: host.contextBefore)
    }

    // MARK: Lifecycle

    func appear() {
        Self.visible.appeared(self)
        let fullAccess = host?.hasFullAccess ?? false
        let memory = MemoryFootprint.currentMB
        peakMemoryMB = max(peakMemoryMB, memory)
        PressayLog.shared.event("keyboard.appeared", [
            "fullAccess": .bool(fullAccess),
            "memoryMB": .double(memory.rounded(toPlaces: 1)),
        ])
        guard fullAccess else { return }
        Self.observeOnce()
        refresh()
        // A result dictated while the keyboard was hidden, if it is recent enough.
        insertPendingResults(trigger: "appear")
        startMemorySampling()
    }

    func disappear() {
        Self.visible.disappeared(self)
        refreshTask?.cancel()
        memoryTask?.cancel()
        PressayLog.shared.event("keyboard.hidden", ["peakMemoryMB": .double(peakMemoryMB.rounded(toPlaces: 1))])
    }

    private static func observeOnce() {
        guard !isObserving else { return }
        isObserving = true
        DarwinNotifier.observe(PressaySignal.phaseChanged) {
            Task { @MainActor in visible.current?.phaseChanged() }
        }
        DarwinNotifier.observe(PressaySignal.resultReady) {
            Task { @MainActor in visible.current?.insertPendingResults(trigger: "signal") }
        }
    }

    private func phaseChanged() {
        refresh()
        // The result signal may have been missed while iOS was busy: delivery is a second chance.
        if SessionStore.shared?.phase == .delivered {
            insertPendingResults(trigger: "phase")
        }
    }

    // MARK: State

    func refresh() {
        let session = SessionStore.shared
        let now = Date()
        barState = KeyboardBarState.resolve(
            phase: session?.phase ?? .idle,
            phaseChangedAt: session?.phaseChangedAt,
            lastInsertionAt: lastInsertionAt,
            toggleRequestedAt: toggleRequestedAt,
            now: now
        )
        if undo != nil, !canUndo {
            undo = nil
        }
        host?.dictationLinkDidChange(self)
        scheduleRefresh(phaseChangedAt: session?.phaseChangedAt, now: now)
    }

    private func scheduleRefresh(phaseChangedAt: Date?, now: Date) {
        refreshTask?.cancel()
        guard let next = KeyboardBarState.nextChange(
            phaseChangedAt: phaseChangedAt,
            lastInsertionAt: lastInsertionAt,
            toggleRequestedAt: toggleRequestedAt,
            now: now
        ) else { return }
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(next.timeIntervalSince(now) + 0.05))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    // MARK: Insertion

    func insertPendingResults(trigger: StaticString) {
        guard Self.visible.isVisible(self), let host, host.hasFullAccess else {
            PressayLog.shared.event("keyboard.insert.skipped", ["trigger": .tag(trigger.description), "visible": .bool(false)])
            return
        }
        guard let queue = ResultQueue.shared else { return }
        let delivery = ResultDelivery(queue: queue)
        var inserted = 0
        while inserted < ResultQueue.capacity {
            let result: DictationResult?
            do {
                result = try delivery.next(alreadyInserted: Self.insertedIDs)
            } catch {
                PressayLog.shared.event("keyboard.insert.failed", ["trigger": .tag(trigger.description)])
                break
            }
            guard let result else { break }
            insert(result, trigger: trigger)
            inserted += 1
        }
        if inserted > 0 {
            host.dictationLinkDidEditText(self)
            refresh()
        }
    }

    private func insert(_ result: DictationResult, trigger: StaticString) {
        guard let host else { return }
        Self.insertedIDs.insert(result.id)
        let before = host.contextBefore
        let text = InsertionText.prepare(result.text, contextBefore: before)
        host.textDocumentProxy.insertText(text)
        host.recordEdits([.insert(text)], from: before)
        undo = InsertionUndo(text: text)
        lastInsertionAt = Date()
        PressayLog.shared.event("keyboard.inserted", [
            "trigger": .tag(trigger.description),
            "ageMs": .int(Int(Date().timeIntervalSince(result.createdAt) * 1000)),
            "characters": .int(text.count),
        ])
    }

    /// "Undo insertion": deletes the dictated text while the cursor still follows it.
    func undoInsertion() {
        guard let undo, let host, canUndo else {
            self.undo = nil
            refresh()
            return
        }
        let before = host.contextBefore
        for _ in 0..<undo.deletionCount {
            host.textDocumentProxy.deleteBackward()
        }
        host.recordEdits([.deleteBackward(count: undo.deletionCount)], from: before)
        self.undo = nil
        lastInsertionAt = nil
        PressayLog.shared.event("keyboard.insertion.undone", ["characters": .int(undo.deletionCount)])
        host.dictationLinkDidEditText(self)
        refresh()
    }

    /// The user typed: the inserted text is no longer the last thing written.
    func userTyped() {
        guard undo != nil else { return }
        undo = nil
        host?.dictationLinkDidChange(self)
    }

    /// The cursor moved or the field changed: deleting characters before the cursor could
    /// now remove something else than the dictation.
    func selectionMoved() {
        guard undo != nil else { return }
        undo = nil
        host?.dictationLinkDidChange(self)
    }

    /// The text or the cursor moved outside the keyboard.
    func textChanged() {
        guard undo != nil, !canUndo else { return }
        undo = nil
        host?.dictationLinkDidChange(self)
    }

    // MARK: Microphone

    /// Asks the app to start or stop. The keyboard cannot record (no microphone for keyboard
    /// extensions) nor open the app: when the app is not running, nothing answers, and the
    /// bar suggests the Action button after `KeyboardBarState.toggleAnswerTimeout`.
    func toggleDictation() {
        guard let session = SessionStore.shared else { return }
        let now = Date()
        toggleRequestedAt = now
        session.requestToggle(at: now)
        PressayLog.shared.event("keyboard.toggle.requested", ["phase": .tag(session.phase.rawValue)])
        refresh()
    }

    // MARK: Memory

    private func startMemorySampling() {
        memoryTask?.cancel()
        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.memoryInterval)
                guard !Task.isCancelled, let self else { return }
                let memory = MemoryFootprint.currentMB
                self.peakMemoryMB = max(self.peakMemoryMB, memory)
                PressayLog.shared.event("keyboard.memory", [
                    "memoryMB": .double(memory.rounded(toPlaces: 1)),
                    "peakMemoryMB": .double(self.peakMemoryMB.rounded(toPlaces: 1)),
                ])
            }
        }
    }
}

/// Same metric as the jetsam limit: the physical footprint of this process.
enum MemoryFootprint {
    static var currentMB: Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10, Double(places))
        return (self * factor).rounded() / factor
    }
}
