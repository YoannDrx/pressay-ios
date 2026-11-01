import Foundation

/// A word of the personal dictionary, with the Mac's field names: it crosses encrypted sync as is.
public struct DictionaryEntry: Codable, Equatable, Sendable, Identifiable {
    public enum MatchKind: String, Codable, Sendable {
        case exact, fuzzy
    }

    public var id: String
    public var term: String
    public var variants: [String]
    public var replacement: String?
    public var matchKind: MatchKind
    public var language: String?
    public var enabled: Bool

    private enum CodingKeys: String, CodingKey {
        case id, term, variants, replacement, language, enabled
        case matchKind = "match_kind"
    }

    public init(
        id: String = UUID().uuidString.lowercased(),
        term: String,
        variants: [String] = [],
        replacement: String? = nil,
        matchKind: MatchKind = .exact,
        language: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.term = term
        self.variants = variants
        self.replacement = replacement
        self.matchKind = matchKind
        self.language = language
        self.enabled = enabled
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        term = try container.decode(String.self, forKey: .term)
        variants = try container.decodeIfPresent([String].self, forKey: .variants) ?? []
        replacement = try container.decodeIfPresent(String.self, forKey: .replacement)
        matchKind = try container.decodeIfPresent(MatchKind.self, forKey: .matchKind) ?? .exact
        language = try container.decodeIfPresent(String.self, forKey: .language)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(term, forKey: .term)
        try container.encode(variants, forKey: .variants)
        try container.encode(replacement, forKey: .replacement)
        try container.encode(matchKind, forKey: .matchKind)
        try container.encode(language, forKey: .language)
        try container.encode(enabled, forKey: .enabled)
    }

    /// The Mac's `validate_dictionary` rules, for one entry.
    public var isValid: Bool {
        Self.isValidID(id)
            && Self.isValidText(term, maximum: 200)
            && (replacement.map { Self.isValidText($0, maximum: 500) } ?? true)
            && variants.allSatisfy { Self.isValidText($0, maximum: 200) }
    }

    static func isValidID(_ value: String) -> Bool {
        (1...64).contains(value.count)
            && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }

    static func isValidText(_ value: String, maximum: Int) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.count <= maximum
    }
}
