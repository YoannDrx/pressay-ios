import Foundation

/// The App Group shared by the app, the keyboard and the widgets.
/// The keyboard can only reach it once the user grants Full Access.
public enum AppGroup {
    public static let identifier = "group.fr.yodev.pressay"

    /// Nil when the process has no App Group entitlement, or when the keyboard
    /// runs without Full Access.
    public static var container: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    public static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }
}
