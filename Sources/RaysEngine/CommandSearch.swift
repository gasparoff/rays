import Foundation

/// Ranks command titles for the command palette (⌘K). Pure and deterministic.
///
/// A query matches when every typed word is found in the title, ignoring case and accents.
/// Matches at the start of the title rank first, then at the start of a word, then anywhere;
/// ties keep the original order, so the caller's order (scenes before settings) is the tiebreak.
public enum CommandSearch {
    public static func rank<Item>(_ items: [Item], query: String, title: (Item) -> String) -> [Item] {
        let words = normalize(query).split(separator: " ").map(String.init)
        guard !words.isEmpty else { return items }
        let scored = items.enumerated().compactMap { index, item -> (score: Int, index: Int, item: Item)? in
            guard let score = score(normalize(title(item)), words: words) else { return nil }
            return (score, index, item)
        }
        return scored.sorted { ($0.score, $0.index) < ($1.score, $1.index) }.map(\.item)
    }

    /// Lower is better; nil when some word is missing.
    static func score(_ title: String, words: [String]) -> Int? {
        var total = 0
        for word in words {
            var best: Int?
            var from = title.startIndex
            while let range = title.range(of: word, range: from..<title.endIndex) {
                let here = range.lowerBound == title.startIndex ? 0 : (isWordStart(title, range.lowerBound) ? 1 : 2)
                best = min(best ?? here, here)
                if here == 0 { break }
                from = title.index(after: range.lowerBound)
            }
            guard let best else { return nil }
            total += best
        }
        return total
    }

    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isWordStart(_ s: String, _ i: String.Index) -> Bool {
        let before = s[s.index(before: i)]
        return !(before.isLetter || before.isNumber)
    }
}
