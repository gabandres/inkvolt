import Foundation

/// How Inkvolt Print's command palette (⌘K; the Windows apps' Ctrl+K) matches what is typed (the Windows apps'
/// `PaletteSearch`): every word must appear in the entry's category or name; a name starting with a word ranks first, then a
/// word starting a word, then a word inside one. Entries that aren't commands (recent files) rank a little lower than
/// commands on a tie.
public enum PaletteSearch {
    /// 0 when a word is missing; otherwise higher is better.
    public static func score(_ name: String, _ category: String, _ words: [String], isCommand: Bool = true) -> Int {
        let hay = "\(category) \(name)"
        var score = 0
        for w in words {
            guard let at = hay.range(of: w, options: .caseInsensitive, locale: .current) else { return 0 }
            let startsName = name.range(of: w, options: [.caseInsensitive, .anchored], locale: .current) != nil
            let startsWord = at.lowerBound == hay.startIndex || hay[hay.index(before: at.lowerBound)] == " "
            score += startsName ? 30 : startsWord ? 20 : 10
        }
        return score + (isCommand ? 5 : 0)
    }

    /// The entries matching `query`, best first (the list's order on a tie), at most `max`; with nothing typed, the first
    /// `max` for which `showWhenEmpty` holds.
    public static func filter<T>(_ items: [T], _ query: String, name: (T) -> String, category: (T) -> String,
                                 isCommand: ((T) -> Bool)? = nil, showWhenEmpty: ((T) -> Bool)? = nil, max: Int = 60) -> [T] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty { return Array(items.filter { showWhenEmpty?($0) ?? true }.prefix(max)) }
        let words: [String] = q.split(separator: " ").map(String.init)
        var scored: [(offset: Int, item: T, score: Int)] = []
        for (offset, item) in items.enumerated() {
            let command: Bool = isCommand?(item) ?? true
            let s: Int = score(name(item), category(item), words, isCommand: command)
            if s > 0 { scored.append((offset, item, s)) }
        }
        scored.sort { a, b in a.score != b.score ? a.score > b.score : a.offset < b.offset }
        return scored.prefix(max).map { $0.item }
    }
}
