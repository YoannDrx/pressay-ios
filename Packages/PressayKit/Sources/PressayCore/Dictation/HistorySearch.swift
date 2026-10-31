import Foundation

extension HistoryEntry {
    /// Case- and accent-insensitive, as people type a search on a phone: "ete" finds "été".
    public func matches(_ query: String) -> Bool {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return trimmed.split(whereSeparator: \.isWhitespace).allSatisfy { word in
            text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

extension Array where Element == HistoryEntry {
    public func matching(_ query: String) -> [HistoryEntry] {
        filter { $0.matches(query) }
    }
}
