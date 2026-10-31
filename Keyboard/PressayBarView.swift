import PressayShared
import UIKit

/// The Pressay bar above the keys: where the dictation stands, the microphone, and
/// "Undo insertion". Without Full Access it explains how to turn dictation on instead.
final class PressayBarView: UIView {
    enum Content: Equatable {
        case dictation(KeyboardBarState, canUndo: Bool)
        case fullAccessMissing
    }

    var onMicrophone: (() -> Void)?
    var onUndo: (() -> Void)?

    private let iconView = UIImageView()
    private let statusLabel = UILabel()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let undoButton = UIButton(type: .system)
    private let microphoneButton = UIButton(type: .system)
    private var content: Content?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Dynamic Type, up to a size that still leaves room for the keys.
        maximumContentSizeCategory = .accessibilityMedium

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .secondaryLabel
        iconView.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .subheadline)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.isAccessibilityElement = false

        statusLabel.font = .preferredFont(forTextStyle: .subheadline)
        statusLabel.adjustsFontForContentSizeCategory = true
        statusLabel.textColor = .label
        statusLabel.numberOfLines = 2
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.accessibilityTraits = [.staticText, .updatesFrequently]

        spinner.hidesWhenStopped = true

        configureButtons()

        let stack = UIStackView(arrangedSubviews: [iconView, statusLabel, spinner, undoButton, microphoneButton])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            microphoneButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
            microphoneButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 52),
            undoButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 36),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureButtons() {
        var undo = UIButton.Configuration.plain()
        undo.image = UIImage(systemName: "arrow.uturn.backward")
        undo.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(textStyle: .subheadline)
        undo.title = String(localized: "keyboard.undo")
        undo.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = UIFont.preferredFont(forTextStyle: .subheadline)
            return attributes
        }
        undo.imagePadding = 4
        undo.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 8, bottom: 6, trailing: 8)
        undoButton.configuration = undo
        undoButton.addAction(UIAction { [weak self] _ in self?.onUndo?() }, for: .primaryActionTriggered)
        undoButton.setContentHuggingPriority(.required, for: .horizontal)
        undoButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        var microphone = UIButton.Configuration.filled()
        microphone.cornerStyle = .capsule
        microphone.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        microphone.contentInsets = NSDirectionalEdgeInsets(top: 8, leading: 14, bottom: 8, trailing: 14)
        microphoneButton.configuration = microphone
        microphoneButton.addAction(UIAction { [weak self] _ in self?.onMicrophone?() }, for: .primaryActionTriggered)
        microphoneButton.setContentHuggingPriority(.required, for: .horizontal)
        microphoneButton.setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    func show(_ content: Content) {
        guard content != self.content else { return }
        let previous = self.content
        self.content = content
        switch content {
        case .fullAccessMissing:
            iconView.image = UIImage(systemName: "lock")
            statusLabel.text = String(localized: "keyboard.bar.fullAccess")
            statusLabel.numberOfLines = 3
            spinner.stopAnimating()
            undoButton.isHidden = true
            microphoneButton.isHidden = true
        case let .dictation(state, canUndo):
            statusLabel.numberOfLines = 2
            iconView.image = UIImage(systemName: Self.icon(for: state))
            iconView.tintColor = state == .failed ? .systemOrange : .secondaryLabel
            statusLabel.text = Self.text(for: state)
            if state == .transcribing { spinner.startAnimating() } else { spinner.stopAnimating() }
            undoButton.isHidden = !canUndo
            microphoneButton.isHidden = false
            configureMicrophone(for: state)
        }
        // VoiceOver hears the new state without moving its cursor.
        if case let .dictation(old, _) = previous, case let .dictation(new, _) = content, old != new {
            UIAccessibility.post(notification: .announcement, argument: statusLabel.text)
        }
    }

    private func configureMicrophone(for state: KeyboardBarState) {
        guard var configuration = microphoneButton.configuration else { return }
        let stops = state == .listening
        configuration.image = UIImage(systemName: stops ? "stop.fill" : "mic.fill")
        configuration.baseBackgroundColor = stops ? .systemRed : .tintColor
        configuration.baseForegroundColor = .white
        microphoneButton.configuration = configuration
        microphoneButton.isEnabled = state != .transcribing
        microphoneButton.accessibilityLabel = String(localized: stops ? "keyboard.microphone.stop" : "keyboard.microphone.start")
    }

    private static func icon(for state: KeyboardBarState) -> String {
        switch state {
        case .ready: "waveform"
        case .listening: "waveform.circle.fill"
        case .transcribing: "text.bubble"
        case .inserted: "checkmark.circle"
        case .failed: "exclamationmark.triangle"
        case .actionButtonHint: "button.horizontal.top.press"
        }
    }

    private static func text(for state: KeyboardBarState) -> String {
        switch state {
        case .ready: String(localized: "keyboard.bar.ready")
        case .listening: String(localized: "keyboard.bar.listening")
        case .transcribing: String(localized: "keyboard.bar.transcribing")
        case .inserted: String(localized: "keyboard.bar.inserted")
        case .failed: String(localized: "keyboard.bar.failed")
        case .actionButtonHint: String(localized: "keyboard.bar.actionButtonHint")
        }
    }
}
