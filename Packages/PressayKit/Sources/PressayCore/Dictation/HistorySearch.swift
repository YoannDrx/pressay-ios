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
    /// What the history shows: everything with Pro, the last `freeDays` days without it. Older
    /// entries stay sealed on the iPhone, so they come back with Pro.
    public func visibleEntries(isPro: Bool, freeDays: Int, now: Date = Date()) -> [HistoryEntry] {
        guard !isPro else { return self }
        let limit = now.addingTimeInterval(-TimeInterval(freeDays) * 86_400)
        return filter { $0.createdAt >= limit }
    }

    public func matching(_ query: String) -> [HistoryEntry] {
        filter { $0.matches(query) }
    }
}
