import Foundation

/// Applies dictionary entries after every engine, as `apply_dictionary_entries` does on the Mac:
/// never through a whitespace or punctuation boundary; exact entries handle phrases and variants;
/// fuzzy entries (created on the Mac) use the same conservative edit distance and Soundex policy.
public enum DictionaryApplier {
    /// The Mac's default `word_correction_threshold`.
    public static let threshold = 0.18

    private struct FuzzyMatch {
        let count: Int
        let output: String
        let score: Double
    }

    private struct Rule {
        let entryIndex: Int
        let output: String
        let aliasKey: String
        let tokenCount: Int
    }

    public static func apply(_ entries: [DictionaryEntry], to text: String, threshold: Double = threshold) -> String {
        let rules = rules(for: entries)
        guard !rules.isEmpty else { return text }
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var result: [String] = []
        var index = 0
        while index < words.count {
            let remaining = Array(words[index...])
            if let (count, output) = replacement(remaining, entries: entries, rules: rules, threshold: threshold) {
                let prefix = punctuation(of: words[index]).prefix
                let suffix = punctuation(of: words[index + count - 1]).suffix
                result.append(prefix + output + suffix)
                index += count
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return result.joined(separator: " ")
    }

    private static func rules(for entries: [DictionaryEntry]) -> [Rule] {
        entries.enumerated().flatMap { index, entry -> [Rule] in
            guard entry.enabled else { return [] }
            let replacement = entry.replacement?.trimmingCharacters(in: .whitespacesAndNewlines)
            let output = (replacement?.isEmpty == false ? entry.replacement : nil) ?? entry.term
            return ([entry.term] + entry.variants)
                .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                .map { alias in
                    Rule(
                        entryIndex: index,
                        output: output,
                        aliasKey: matchKey(alias),
                        tokenCount: max(1, alias.split(whereSeparator: \.isWhitespace).count)
                    )
                }
        }
    }

    private static func replacement(
        _ words: [String], entries: [DictionaryEntry], rules: [Rule], threshold: Double
    ) -> (Int, String)? {
        let exact = rules.filter { entries[$0.entryIndex].matchKind == .exact }
        let maximumTokens = min(exact.map(\.tokenCount).max() ?? 0, words.count)
        // Exact rules win over fuzzy rules; the longest phrase wins, then dictionary order.
        if maximumTokens > 0 {
            for count in stride(from: maximumTokens, through: 1, by: -1) {
                guard !crossesPunctuation(words, count: count) else { continue }
                let candidate = ngram(words, count: count)
                if let rule = exact.first(where: { $0.tokenCount == count && $0.aliasKey == candidate }) {
                    return (count, rule.output)
                }
            }
        }

        var best: FuzzyMatch?
        let fuzzy = rules.filter { entries[$0.entryIndex].matchKind == .fuzzy && isASCIIKey($0.aliasKey) }
        for count in stride(from: min(3, words.count), through: 1, by: -1) {
            guard !crossesPunctuation(words, count: count) else { continue }
            let candidate = ngram(words, count: count)
            guard isASCIIKey(candidate), candidate.count <= 50 else { continue }
            for rule in fuzzy {
                let longest = Double(max(candidate.count, rule.aliasKey.count))
                let difference = Double(abs(candidate.count - rule.aliasKey.count))
                guard difference <= max(longest * 0.25, 2) else { continue }
                let edit = Double(levenshtein(candidate, rule.aliasKey)) / longest
                let phonetic = isLetters(candidate) && isLetters(rule.aliasKey) && soundex(candidate) == soundex(rule.aliasKey)
                let score = phonetic ? edit * 0.3 : edit
                if score < threshold, score < (best?.score ?? .infinity) {
                    best = FuzzyMatch(count: count, output: rule.output, score: score)
                }
            }
        }
        return best.map { ($0.count, $0.output) }
    }

    private static func crossesPunctuation(_ words: [String], count: Int) -> Bool {
        words.prefix(count - 1).contains { !punctuation(of: $0).suffix.isEmpty }
    }

    private static func ngram(_ words: [String], count: Int) -> String {
        words.prefix(count).map(matchKey).joined()
    }

    static func matchKey(_ word: String) -> String {
        String(word.filter { $0.isLetter || $0.isNumber }).lowercased()
    }

    private static func punctuation(of word: String) -> (prefix: String, suffix: String) {
        let isWordCharacter: (Character) -> Bool = { $0.isLetter || $0.isNumber }
        guard let first = word.firstIndex(where: isWordCharacter), let last = word.lastIndex(where: isWordCharacter) else {
            return (word, "")
        }
        return (String(word[..<first]), String(word[word.index(after: last)...]))
    }

    private static func isASCIIKey(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    private static func isLetters(_ key: String) -> Bool {
        !key.isEmpty && key.allSatisfy { $0.isASCII && $0.isLetter }
    }

    static func levenshtein(_ left: String, _ right: String) -> Int {
        let left = Array(left)
        let right = Array(right)
        guard !left.isEmpty else { return right.count }
        guard !right.isEmpty else { return left.count }
        var previous = Array(0...right.count)
        for (row, leftCharacter) in left.enumerated() {
            var current = [row + 1]
            for (column, rightCharacter) in right.enumerated() {
                let substitution = previous[column] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(previous[column + 1] + 1, current[column] + 1, substitution))
            }
            previous = current
        }
        return previous[right.count]
    }

    /// Classic Soundex, as the Mac's `natural` crate computes it on lowercased keys.
    static func soundex(_ word: String) -> String {
        guard let first = word.first else { return "" }
        let digits = word.dropFirst().map(soundexDigit)
        var kept: [Character] = [first]
        for digit in digits where digit != "9" && kept.last != digit {
            kept.append(digit)
        }
        let code = kept.enumerated().filter { $0.offset == 0 || $0.element != "0" }.map(\.element)
        return String((code + ["0", "0", "0"]).prefix(4))
    }

    private static func soundexDigit(_ character: Character) -> Character {
        switch character {
        case "b", "f", "p", "v": "1"
        case "c", "g", "j", "k", "q", "s", "x", "z": "2"
        case "d", "t": "3"
        case "l": "4"
        case "m", "n": "5"
        case "r": "6"
        case "h", "w": "9"
        default: "0"
        }
    }
}
