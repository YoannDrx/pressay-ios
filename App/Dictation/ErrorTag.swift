import Foundation
import PressayShared

/// A journal-safe name for an error: its type and enum case, never its payload or message,
/// which could carry a path or, one day, text.
enum ErrorTag {
    static func of(_ error: Error) -> LogValue {
        let type = String(describing: Swift.type(of: error))
        let mirror = Mirror(reflecting: error)
        guard mirror.displayStyle == .enum else {
            return .tag("\(type)#\((error as NSError).code)")
        }
        // A case with a payload shows as its label; a case without one describes itself.
        let name = mirror.children.first?.label ?? String(describing: error)
        return .tag("\(type).\(name)")
    }
}
