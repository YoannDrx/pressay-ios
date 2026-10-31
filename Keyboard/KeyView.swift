import PressayShared
import UIKit

/// What a key shows: text or a symbol, and what VoiceOver says.
struct KeyFace: Equatable {
    var title: String?
    var symbol: String?
    var accessibilityLabel: String
    var accessibilityValue: String?
    var isCharacter: Bool
    var isEnabled = true
}

/// One key. Its frame is the key's whole touch cell, so taps between keys still land;
/// the visible key is the inset `capView`.
final class KeyView: UIView {
    let spec: KeySpec
    private let capView = UIView()
    private let titleLabel = UILabel()
    private let imageView = UIImageView()
    private(set) var face: KeyFace
    var capFrame: CGRect = .zero {
        didSet { setNeedsLayout() }
    }
    var compact = false {
        didSet { if compact != oldValue { applyFace() } }
    }
    var isPressed = false {
        didSet { if isPressed != oldValue { KeyStyle.apply(to: capView, pressed: isPressed) } }
    }
    /// VoiceOver activation: one action, no repeat, no popup.
    var onAccessibilityActivate: (() -> Void)?
    /// VoiceOver's custom actions type the accents a long press would offer.
    var onAlternate: ((String) -> Void)?

    init(spec: KeySpec, face: KeyFace) {
        self.spec = spec
        self.face = face
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        capView.isUserInteractionEnabled = false
        addSubview(capView)
        titleLabel.textAlignment = .center
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.6
        imageView.contentMode = .center
        capView.addSubview(titleLabel)
        capView.addSubview(imageView)

        isAccessibilityElement = true
        accessibilityTraits = .keyboardKey
        applyFace()
        // The shadow is a CGColor: it does not follow light and dark by itself.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (key: KeyView, _: UITraitCollection) in
            KeyStyle.apply(to: key.capView, pressed: key.isPressed)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func update(face: KeyFace) {
        guard face != self.face else { return }
        self.face = face
        applyFace()
    }

    private func applyFace() {
        titleLabel.text = face.title
        titleLabel.font = face.isCharacter ? KeyStyle.characterFont(compact: compact) : KeyStyle.functionFont(compact: compact)
        titleLabel.textColor = face.isEnabled ? KeyStyle.label : KeyStyle.disabledLabel
        titleLabel.isHidden = face.title == nil
        imageView.image = face.symbol.flatMap {
            UIImage(systemName: $0, withConfiguration: KeyStyle.symbolConfiguration(compact: compact))
        }
        imageView.tintColor = face.isEnabled ? KeyStyle.label : KeyStyle.disabledLabel
        imageView.isHidden = face.symbol == nil
        accessibilityLabel = face.accessibilityLabel
        accessibilityValue = face.accessibilityValue
        accessibilityTraits = face.isEnabled ? .keyboardKey : [.keyboardKey, .notEnabled]
        accessibilityCustomActions = spec.alternates.isEmpty ? nil : spec.alternates.map { alternate in
            UIAccessibilityCustomAction(name: alternate) { [weak self] _ in
                self?.onAlternate?(alternate)
                return true
            }
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        capView.frame = capFrame
        titleLabel.frame = capView.bounds.insetBy(dx: 2, dy: 0)
        // Letters sit slightly high on the system keyboard; keep them optically centred.
        if face.isCharacter {
            titleLabel.frame.origin.y -= 1
        }
        imageView.frame = capView.bounds
        KeyStyle.apply(to: capView, pressed: isPressed)
    }

    override var accessibilityFrame: CGRect {
        get { UIAccessibility.convertToScreenCoordinates(capFrame, in: self) }
        set { super.accessibilityFrame = newValue }
    }

    override func accessibilityActivate() -> Bool {
        guard face.isEnabled else { return false }
        onAccessibilityActivate?()
        return true
    }

    /// The key's cap, in `view`'s coordinates: popups anchor to it.
    func capFrame(in view: UIView) -> CGRect {
        convert(capFrame, to: view)
    }
}
