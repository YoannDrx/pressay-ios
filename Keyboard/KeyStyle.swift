import PressayShared
import UIKit

/// One look for every key, light and dark: letters, shift, delete, space and return share
/// the same fill, corner and shadow (a request from the spike's testers).
enum KeyStyle {
    static let cornerRadius: CGFloat = 8.5
    static let horizontalSpacing: CGFloat = 6
    static let sideInset: CGFloat = 3

    /// Dark keys stay light enough for white labels at more than 6:1.
    static let fill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.38, alpha: 1) : .white
    }

    static let pressedFill = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0.26, alpha: 1) : UIColor(white: 0.80, alpha: 1)
    }

    static let shadow = UIColor { traits in
        traits.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.55) : UIColor(white: 0, alpha: 0.32)
    }

    static let label = UIColor.label
    static let disabledLabel = UIColor.tertiaryLabel
    static let selection = UIColor.systemBlue

    static func characterFont(compact: Bool) -> UIFont {
        .systemFont(ofSize: compact ? 21 : 25, weight: .regular)
    }

    static func functionFont(compact: Bool) -> UIFont {
        .systemFont(ofSize: compact ? 15 : 16, weight: .regular)
    }

    static func symbolConfiguration(compact: Bool) -> UIImage.SymbolConfiguration {
        UIImage.SymbolConfiguration(pointSize: compact ? 17 : 19, weight: .regular)
    }

    /// Paints `view` as a key, pressed or not.
    @MainActor
    static func apply(to view: UIView, pressed: Bool) {
        view.backgroundColor = pressed ? pressedFill : fill
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.layer.shadowColor = shadow.resolvedColor(with: view.traitCollection).cgColor
        view.layer.shadowOpacity = 1
        view.layer.shadowRadius = 0
        view.layer.shadowOffset = CGSize(width: 0, height: 1)
        view.layer.shadowPath = UIBezierPath(roundedRect: view.bounds, cornerRadius: cornerRadius).cgPath
    }
}

/// Grid metrics, portrait or landscape (compact height).
struct KeyMetrics: Equatable {
    let keyHeight: CGFloat
    let rowSpacing: CGFloat
    let topInset: CGFloat
    let bottomInset: CGFloat
    let compact: Bool

    static let portrait = KeyMetrics(keyHeight: 43, rowSpacing: 11, topInset: 6, bottomInset: 4, compact: false)
    static let landscape = KeyMetrics(keyHeight: 32, rowSpacing: 6, topInset: 4, bottomInset: 3, compact: true)

    func height(rows: Int) -> CGFloat {
        topInset + bottomInset + CGFloat(rows) * keyHeight + CGFloat(max(0, rows - 1)) * rowSpacing
    }
}
