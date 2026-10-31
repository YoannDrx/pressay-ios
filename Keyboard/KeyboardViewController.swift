import PressayShared
import UIKit

/// The Pressay keyboard: AZERTY or QWERTY typing without autocorrection (decision D10), and
/// the Pressay bar that follows a dictation and inserts its text.
///
/// UIKit rather than SwiftUI: one view per key and a single touch handler give multi-finger
/// rollover, taps between keys and the accents popup, without loading SwiftUI's runtime in
/// a process whose memory iOS caps (spike S4).
final class KeyboardViewController: UIInputViewController {
    private let bar = PressayBarView()
    private let grid = KeyGridView()
    private let link = DictationLink()
    private var typing = TypingSession()
    private var tracker = ContextTracker()
    private var language = KeyboardLanguage.french
    private var field = FieldKind.text
    private var lastKeyboardType: UIKeyboardType?
    private var documentID: UUID?
    /// What the keys showed last: some hosts call `textDidChange` dozens of times a keystroke.
    private var rendered: RenderState?
    private var gridHeight: NSLayoutConstraint?
    private let haptics = UIImpactFeedbackGenerator(style: .light)
    /// The app's Haptics setting, read once per appearance rather than at every key.
    private var hapticsEnabled = true
    private var assignedLanguage: String?

    override func loadView() {
        let input = KeyboardInputView(frame: .zero, inputViewStyle: .keyboard)
        // The bar grows with Dynamic Type: the keyboard takes the height its content needs.
        input.allowsSelfSizing = true
        view = input
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        link.host = self
        grid.delegate = self
        bar.onMicrophone = { [weak self] in
            self?.feedback()
            self?.link.toggleDictation()
        }
        bar.onUndo = { [weak self] in
            self?.feedback()
            self?.link.undoInsertion()
        }

        bar.translatesAutoresizingMaskIntoConstraints = false
        grid.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(bar)
        // After the bar: key previews of the top row draw over it.
        view.addSubview(grid)
        let gridHeight = grid.heightAnchor.constraint(equalToConstant: grid.metrics.height(rows: 4))
        self.gridHeight = gridHeight
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: view.topAnchor),
            bar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.topAnchor.constraint(equalTo: bar.bottomAnchor),
            grid.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            grid.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            grid.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            gridHeight,
        ])
        registerForTraitChanges([UITraitVerticalSizeClass.self]) { (controller: KeyboardViewController, _: UITraitCollection) in
            controller.updateMetrics()
        }
        updateMetrics()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        hapticsEnabled = hasFullAccess && KeyboardPreferences.shared.haptics
        configureForField(force: true)
        link.appear()
        updateBar()
        haptics.prepare()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        link.disappear()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        // `needsInputModeSwitchKey` is only reliable once the keyboard is on screen.
        render()
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        configureForField(force: false)
        typing.textDidChange(contextBefore: contextBefore)
        link.textChanged()
        render()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        // The cursor moved: what the keyboard wrote last is no longer what precedes it.
        tracker.reset()
        link.selectionMoved()
        typing.textDidChange(contextBefore: contextBefore)
        link.textChanged()
        render()
    }

    // MARK: Field

    /// Reads the field's traits. The layer only resets when the field changes, not on every
    /// keystroke.
    private func configureForField(force: Bool) {
        let proxy = textDocumentProxy
        let setting = hasFullAccess ? KeyboardPreferences.shared.layout : .automatic
        language = KeyboardLanguage.resolve(setting: setting, preferredLanguages: Locale.preferredLanguages)
        // Only on a change: each assignment goes to the host, which answers with another
        // `textDidChange`. Assigned every time, the two looped and pinned the host's main
        // thread (seen with the app's own practice field, at 98 % CPU).
        // Compared with what was assigned, not with the getter, which may return another form.
        if assignedLanguage != language.primaryLanguage {
            assignedLanguage = language.primaryLanguage
            primaryLanguage = language.primaryLanguage
        }

        // Another field, maybe in the same app: its text owes nothing to the previous one.
        if force || proxy.documentIdentifier != documentID {
            documentID = proxy.documentIdentifier
            tracker.reset()
            link.selectionMoved()
        }
        let keyboardType = proxy.keyboardType ?? .default
        if force || keyboardType != lastKeyboardType {
            lastKeyboardType = keyboardType
            field = Self.fieldKind(for: keyboardType)
            typing.layer = field == .number ? .numbers : .letters
        }
        typing.autocapitalization = Self.autocapitalization(proxy.autocapitalizationType ?? .sentences)
        typing.periodShortcutEnabled = field == .text && proxy.smartInsertDeleteType != .no
        typing.textDidChange(contextBefore: contextBefore)
        let style: UIUserInterfaceStyle = proxy.keyboardAppearance == .dark ? .dark : .unspecified
        if view.overrideUserInterfaceStyle != style {
            view.overrideUserInterfaceStyle = style
        }
    }

    private static func fieldKind(for type: UIKeyboardType) -> FieldKind {
        switch type {
        case .emailAddress: .email
        case .URL, .webSearch: .url
        case .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad, .numbersAndPunctuation: .number
        default: .text
        }
    }

    private static func autocapitalization(_ type: UITextAutocapitalizationType) -> AutocapitalizationMode {
        switch type {
        case .none: .none
        case .words: .words
        case .allCharacters: .allCharacters
        default: .sentences
        }
    }

    private func updateMetrics() {
        let metrics: KeyMetrics = traitCollection.verticalSizeClass == .compact ? .landscape : .portrait
        grid.metrics = metrics
        gridHeight?.constant = metrics.height(rows: 4)
    }

    // MARK: Rendering

    private func render() {
        let layout = KeyboardLayout.make(language: language, layer: typing.layer, field: field, showsGlobe: needsInputModeSwitchKey)
        let shift = typing.shift.state
        let returnTitle = ReturnKey.title(for: textDocumentProxy.returnKeyType ?? .default)
        // `hasText` lags like the context: trust what the keyboard wrote too.
        let returnEnabled = !(textDocumentProxy.enablesReturnKeyAutomatically ?? false)
            || textDocumentProxy.hasText || !(contextBefore ?? "").isEmpty
        let uppercase = typing.layer == .letters && typing.isUppercase
        let state = RenderState(
            layout: layout,
            shift: shift,
            uppercase: uppercase,
            returnTitle: returnTitle,
            returnEnabled: returnEnabled
        )
        guard state != rendered else { return }
        rendered = state
        grid.render(layout: layout, uppercase: uppercase) { spec in
            KeyFaces.face(for: spec, shift: shift, uppercase: uppercase, returnTitle: returnTitle, returnEnabled: returnEnabled)
        }
    }

    private func updateBar() {
        guard hasFullAccess else {
            bar.show(.fullAccessMissing)
            return
        }
        bar.show(.dictation(link.barState, canUndo: link.canUndo))
    }

    // MARK: Editing

    private func apply(_ edits: [TextEdit]) {
        let proxy = textDocumentProxy
        let before = contextBefore
        for edit in edits {
            switch edit {
            case let .insert(text):
                proxy.insertText(text)
            case let .deleteBackward(count):
                for _ in 0..<count {
                    proxy.deleteBackward()
                }
            }
        }
        tracker.didEdit(edits, from: before, now: Date())
        typing.textDidChange(contextBefore: contextBefore)
        link.userTyped()
        render()
    }

    private func feedback() {
        UIDevice.current.playInputClick()
        // Haptics need Full Access; without it the call does nothing.
        if hapticsEnabled {
            haptics.impactOccurred()
        }
    }
}

extension KeyboardViewController: KeyGridViewDelegate {
    func keyGridKeyDown(_ grid: KeyGridView) {
        feedback()
    }

    func keyGrid(_ grid: KeyGridView, type character: String) {
        apply(typing.type(character))
    }

    func keyGrid(_ grid: KeyGridView, deleteByWord: Bool) {
        apply(typing.delete(byWord: deleteByWord, contextBefore: contextBefore))
    }

    func keyGridShift(_ grid: KeyGridView) {
        typing.tapShift(at: Date())
        render()
    }

    func keyGridSpace(_ grid: KeyGridView) {
        apply(typing.space(contextBefore: contextBefore, now: Date()))
    }

    func keyGridReturn(_ grid: KeyGridView) {
        apply(typing.newline())
    }

    func keyGrid(_ grid: KeyGridView, switchTo layer: KeyboardLayer) {
        typing.layer = layer
        render()
    }

    func keyGrid(_ grid: KeyGridView, globe event: UIEvent?) {
        if let event {
            handleInputModeList(from: grid, with: event)
        } else {
            advanceToNextInputMode()
        }
    }
}

extension KeyboardViewController: DictationHost {
    var contextBefore: String? {
        tracker.context(actual: textDocumentProxy.documentContextBeforeInput, now: Date())
    }

    func recordEdits(_ edits: [TextEdit], from before: String?) {
        tracker.didEdit(edits, from: before, now: Date())
    }

    func dictationLinkDidChange(_ link: DictationLink) {
        updateBar()
    }

    func dictationLinkDidEditText(_ link: DictationLink) {
        typing.textDidChange(contextBefore: contextBefore)
        render()
        updateBar()
    }
}

private struct RenderState: Equatable {
    let layout: KeyboardLayout
    let shift: ShiftState
    let uppercase: Bool
    let returnTitle: String
    let returnEnabled: Bool
}

/// The input view, so the keys can play the system click (`playInputClick`). iOS honours
/// the user's "Keyboard Clicks" setting.
final class KeyboardInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }
}
