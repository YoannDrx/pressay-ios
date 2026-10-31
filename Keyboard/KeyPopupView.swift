import UIKit

/// The bubble above a pressed key: the character in large, or after a long press the
/// accents to slide to.
final class KeyPopupView: UIView {
    private var labels: [UILabel] = []
    private(set) var options: [String] = []
    private(set) var selectedIndex = 0
    private let optionWidth: CGFloat
    /// A row of accents to slide to, rather than the preview of the pressed key.
    let isChoice: Bool

    init(options: [String], isChoice: Bool, optionWidth: CGFloat, compact: Bool, uppercase: Bool) {
        self.optionWidth = optionWidth
        self.isChoice = isChoice
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = KeyStyle.fill
        layer.cornerRadius = KeyStyle.cornerRadius + 2
        layer.cornerCurve = .continuous
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 4
        layer.shadowOffset = CGSize(width: 0, height: 2)
        self.options = options
        labels = options.map { option in
            let label = UILabel()
            label.text = uppercase ? option.uppercased() : option
            label.textAlignment = .center
            label.textColor = KeyStyle.label
            label.font = .systemFont(ofSize: compact ? 24 : 30)
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.layer.cornerRadius = KeyStyle.cornerRadius
            label.layer.cornerCurve = .continuous
            label.clipsToBounds = true
            addSubview(label)
            return label
        }
        select(0)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Places the bubble above `cap`, kept inside `container` horizontally.
    func place(above cap: CGRect, within container: CGRect, height: CGFloat) {
        let width = optionWidth * CGFloat(options.count) + 8
        var originX = isChoice ? cap.minX - 4 : cap.midX - width / 2
        originX = min(max(container.minX + 2, originX), container.maxX - width - 2)
        frame = CGRect(x: originX, y: cap.minY - height - 6, width: width, height: height)
        for (index, label) in labels.enumerated() {
            label.frame = CGRect(x: 4 + CGFloat(index) * optionWidth, y: 4, width: optionWidth, height: height - 8)
        }
        layer.shadowPath = UIBezierPath(roundedRect: CGRect(origin: .zero, size: frame.size), cornerRadius: layer.cornerRadius).cgPath
    }

    /// Selects the option under `position`, in the popup's superview coordinates.
    func select(atX position: CGFloat) {
        let local = position - frame.minX - 4
        select(Int((local / optionWidth).rounded(.down)))
    }

    private func select(_ index: Int) {
        selectedIndex = min(max(0, index), options.count - 1)
        guard isChoice else { return }
        for (offset, label) in labels.enumerated() {
            let selected = offset == selectedIndex
            label.backgroundColor = selected ? KeyStyle.selection : .clear
            label.textColor = selected ? .white : KeyStyle.label
        }
    }

    var selectedOption: String? {
        options.indices.contains(selectedIndex) ? options[selectedIndex] : nil
    }
}
