import PressayShared
import UIKit

@MainActor
protocol KeyGridViewDelegate: AnyObject {
    /// A key went down: sound and haptic.
    func keyGridKeyDown(_ grid: KeyGridView)
    func keyGrid(_ grid: KeyGridView, type character: String)
    func keyGrid(_ grid: KeyGridView, deleteByWord: Bool)
    func keyGridShift(_ grid: KeyGridView)
    func keyGridSpace(_ grid: KeyGridView)
    func keyGridReturn(_ grid: KeyGridView)
    func keyGrid(_ grid: KeyGridView, switchTo layer: KeyboardLayer)
    /// Every touch event of the globe key, for `handleInputModeList(from:with:)`;
    /// nil from VoiceOver, which only activates.
    func keyGrid(_ grid: KeyGridView, globe event: UIEvent?)
}

/// The keys, laid out from a `KeyboardLayout`, with one touch handler for all of them:
/// typing with several fingers commits the previous key as the next one goes down, a long
/// press opens the accents, and the delete key repeats (character, then word).
final class KeyGridView: UIView {
    weak var delegate: KeyGridViewDelegate?
    var metrics = KeyMetrics.portrait {
        didSet { if metrics != oldValue { keyViews.joined().forEach { $0.compact = metrics.compact }; setNeedsLayout() } }
    }

    private var layout = KeyboardLayout(rows: [])
    private var keyViews: [[KeyView]] = []
    private var faces: (KeySpec) -> KeyFace = { _ in KeyFace(accessibilityLabel: "", isCharacter: false) }
    private var uppercase = false

    @MainActor
    private final class Tracking {
        var key: KeyView
        var popup: KeyPopupView?
        var longPress: Timer?
        var showsAlternates: Bool { popup?.isChoice ?? false }

        init(key: KeyView) {
            self.key = key
        }
    }

    private var tracked: [ObjectIdentifier: Tracking] = [:]
    private var deleteTimer: Timer?
    private var deleteRepeats = 0

    static let longPressDelay: TimeInterval = 0.4

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        clipsToBounds = false
        // The keys are the accessibility elements, not the grid.
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Content

    /// Rebuilds the keys when the layout changes, otherwise only refreshes their faces.
    func render(layout: KeyboardLayout, uppercase: Bool, faces: @escaping (KeySpec) -> KeyFace) {
        self.faces = faces
        self.uppercase = uppercase
        if layout != self.layout {
            cancelAllTouches()
            self.layout = layout
            keyViews.joined().forEach { $0.removeFromSuperview() }
            keyViews = layout.rows.map { row in
                row.map { spec in
                    let key = KeyView(spec: spec, face: faces(spec))
                    key.compact = metrics.compact
                    key.onAccessibilityActivate = { [weak self, weak key] in
                        guard let self, let key else { return }
                        self.delegate?.keyGridKeyDown(self)
                        self.perform(key.spec.action, text: nil, fromAccessibility: true)
                    }
                    key.onAlternate = { [weak self] alternate in
                        guard let self else { return }
                        self.delegate?.keyGrid(self, type: alternate)
                    }
                    addSubview(key)
                    return key
                }
            }
            setNeedsLayout()
        } else {
            keyViews.joined().forEach { $0.update(face: faces($0.spec)) }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let unit = (bounds.width - 2 * KeyStyle.sideInset) / KeyboardLayout.rowUnits
        let pitch = metrics.keyHeight + metrics.rowSpacing
        for (rowIndex, row) in keyViews.enumerated() {
            let capTop = metrics.topInset + CGFloat(rowIndex) * pitch
            let cellTop = rowIndex == 0 ? 0 : capTop - metrics.rowSpacing / 2
            let cellBottom = rowIndex == keyViews.count - 1 ? bounds.height : capTop + metrics.keyHeight + metrics.rowSpacing / 2
            var units = 0.0
            for (keyIndex, key) in row.enumerated() {
                let start = KeyStyle.sideInset + CGFloat(units) * unit
                let end = KeyStyle.sideInset + CGFloat(units + key.spec.width) * unit
                let cellLeft = keyIndex == 0 ? 0 : start
                let cellRight = keyIndex == row.count - 1 ? bounds.width : end
                key.frame = CGRect(x: cellLeft, y: cellTop, width: cellRight - cellLeft, height: cellBottom - cellTop)
                let capLeft = start + CGFloat(key.spec.leadingGap) * unit + KeyStyle.horizontalSpacing / 2
                let capRight = end - CGFloat(key.spec.trailingGap) * unit - KeyStyle.horizontalSpacing / 2
                key.capFrame = CGRect(
                    x: capLeft - cellLeft,
                    y: capTop - cellTop,
                    width: max(0, capRight - capLeft),
                    height: metrics.keyHeight
                )
                units += key.spec.width
            }
        }
    }

    // MARK: Touches

    private func key(at point: CGPoint) -> KeyView? {
        let clamped = CGPoint(
            x: min(max(point.x, 0), bounds.width - 0.5),
            y: min(max(point.y, 0), bounds.height - 0.5)
        )
        return keyViews.joined().first { $0.frame.contains(clamped) }
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let key = key(at: touch.location(in: self)) else { continue }
            commitRolledOverKeys()
            let tracking = Tracking(key: key)
            tracked[ObjectIdentifier(touch)] = tracking
            key.isPressed = true
            delegate?.keyGridKeyDown(self)
            switch key.spec.action {
            case .character:
                showPreview(for: tracking)
                scheduleLongPress(for: tracking)
            case .delete:
                beginDeleting()
            case .shift:
                delegate?.keyGridShift(self)
            case .globe:
                if let event {
                    delegate?.keyGrid(self, globe: event)
                }
            case .space, .returnKey, .layer:
                break
            }
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let tracking = tracked[ObjectIdentifier(touch)] else { continue }
            let point = touch.location(in: self)
            if let popup = tracking.popup, popup.isChoice {
                popup.select(atX: point.x)
                continue
            }
            switch tracking.key.spec.action {
            case .character:
                // Sliding to another letter types that letter instead, like the system keyboard.
                guard let other = key(at: point), other !== tracking.key, case .character = other.spec.action else { continue }
                tracking.key.isPressed = false
                tracking.longPress?.invalidate()
                tracking.popup?.removeFromSuperview()
                tracking.key = other
                other.isPressed = true
                showPreview(for: tracking)
                scheduleLongPress(for: tracking)
            case .globe:
                if let event {
                    delegate?.keyGrid(self, globe: event)
                }
            default:
                break
            }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let tracking = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            finish(tracking, commit: true, event: event)
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        for touch in touches {
            guard let tracking = tracked.removeValue(forKey: ObjectIdentifier(touch)) else { continue }
            finish(tracking, commit: false, event: event)
        }
    }

    private func finish(_ tracking: Tracking, commit: Bool, event: UIEvent?) {
        tracking.longPress?.invalidate()
        tracking.key.isPressed = false
        let alternate = tracking.showsAlternates ? tracking.popup?.selectedOption : nil
        tracking.popup?.removeFromSuperview()
        if tracking.key.spec.action == .delete {
            endDeleting()
        }
        if tracking.key.spec.action == .globe {
            // Without an event, the call would switch keyboards on a cancelled touch.
            if let event {
                delegate?.keyGrid(self, globe: event)
            }
            return
        }
        guard commit else { return }
        perform(tracking.key.spec.action, text: alternate, fromAccessibility: false)
    }

    /// Fast typists press the next key before releasing the previous one.
    private func commitRolledOverKeys() {
        for (identifier, tracking) in tracked {
            guard case .character = tracking.key.spec.action, !tracking.showsAlternates else { continue }
            tracked.removeValue(forKey: identifier)
            finish(tracking, commit: true, event: nil)
        }
    }

    private func cancelAllTouches() {
        for tracking in tracked.values {
            tracking.longPress?.invalidate()
            tracking.popup?.removeFromSuperview()
        }
        tracked.removeAll()
        endDeleting()
    }

    private func perform(_ action: KeyAction, text: String?, fromAccessibility: Bool) {
        guard let delegate else { return }
        switch action {
        case let .character(value):
            delegate.keyGrid(self, type: text ?? value)
        case .space:
            delegate.keyGridSpace(self)
        case .returnKey:
            guard keyViews.joined().first(where: { $0.spec.action == .returnKey })?.face.isEnabled ?? true else { return }
            delegate.keyGridReturn(self)
        case let .layer(layer):
            delegate.keyGrid(self, switchTo: layer)
        case .delete where fromAccessibility:
            delegate.keyGrid(self, deleteByWord: false)
        case .shift where fromAccessibility:
            delegate.keyGridShift(self)
        case .globe where fromAccessibility:
            delegate.keyGrid(self, globe: nil)
        case .delete, .shift, .globe:
            // Already handled when the finger went down.
            break
        }
    }
}

extension KeyGridView {
    // MARK: Popups

    private func showPreview(for tracking: Tracking) {
        guard case let .character(value) = tracking.key.spec.action else { return }
        // In landscape the bubble would cover the row above for nothing.
        guard !metrics.compact else { return }
        let cap = tracking.key.capFrame(in: self)
        let popup = KeyPopupView(
            options: [value],
            isChoice: false,
            optionWidth: cap.width + 12,
            compact: metrics.compact,
            uppercase: uppercase
        )
        addSubview(popup)
        popup.place(above: cap, within: bounds, height: metrics.keyHeight + 10)
        tracking.popup = popup
    }

    private func scheduleLongPress(for tracking: Tracking) {
        guard !tracking.key.spec.alternates.isEmpty else { return }
        tracking.longPress = Timer.scheduledTimer(withTimeInterval: Self.longPressDelay, repeats: false) { [weak self, weak tracking] _ in
            MainActor.assumeIsolated {
                guard let self, let tracking else { return }
                self.showAlternates(for: tracking)
            }
        }
    }

    private func showAlternates(for tracking: Tracking) {
        guard !tracking.key.spec.alternates.isEmpty else { return }
        tracking.popup?.removeFromSuperview()
        let cap = tracking.key.capFrame(in: self)
        // The most frequent accent sits above the finger, selected: releasing types it.
        let popup = KeyPopupView(
            options: tracking.key.spec.alternates,
            isChoice: true,
            optionWidth: max(cap.width, 30),
            compact: metrics.compact,
            uppercase: uppercase
        )
        addSubview(popup)
        popup.place(above: cap, within: bounds, height: metrics.keyHeight + 6)
        tracking.popup = popup
        delegate?.keyGridKeyDown(self)
    }

}

// MARK: Delete

extension KeyGridView {
    private func beginDeleting() {
        endDeleting()
        delegate?.keyGrid(self, deleteByWord: false)
        deleteRepeats = 0
        deleteTimer = Timer.scheduledTimer(withTimeInterval: DeleteRepeat.initialDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.startRepeating()
            }
        }
    }

    private func startRepeating() {
        deleteTimer = Timer.scheduledTimer(withTimeInterval: DeleteRepeat.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.deleteRepeats += 1
                self.delegate?.keyGridKeyDown(self)
                self.delegate?.keyGrid(self, deleteByWord: DeleteRepeat.deletesWord(afterRepeats: self.deleteRepeats))
            }
        }
    }

    private func endDeleting() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }
}
