import Foundation

/// One line of the support journal, decoded for display. The journal holds only event
/// names, numbers and short tags (`LogValue`), never dictated text.
public struct JournalLine: Identifiable, Equatable, Sendable {
    public let id: Int
    public let event: String
    public let timestamp: String
    public let process: String
    /// "key=value" pairs, sorted by key.
    public let details: String

    /// Lines that are not a JSON object (a write cut short) are skipped. Newest first.
    public static func parse(_ journal: String, limit: Int = 500) -> [JournalLine] {
        let lines = journal.split(separator: "\n", omittingEmptySubsequences: true)
        var result: [JournalLine] = []
        for (index, line) in lines.enumerated().reversed() {
            guard result.count < limit,
                  let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let event = object["event"] as? String
            else { continue }
            let details = object
                .filter { !["event", "at", "process"].contains($0.key) }
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\(describe($0.value))" }
                .joined(separator: " ")
            result.append(JournalLine(
                id: index,
                event: event,
                timestamp: object["at"] as? String ?? "",
                process: shortProcess(object["process"] as? String ?? ""),
                details: details
            ))
        }
        return result
    }

    private static func describe(_ value: Any) -> String {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "true" : "false"
        }
        return "\(value)"
    }

    /// "fr.yodev.pressay.keyboard" → "keyboard"; the app itself → "app".
    private static func shortProcess(_ bundleID: String) -> String {
        let prefix = "fr.yodev.pressay"
        guard bundleID.hasPrefix(prefix) else { return bundleID }
        let rest = bundleID.dropFirst(prefix.count).drop { $0 == "." }
        return rest.isEmpty ? "app" : String(rest)
    }
}
