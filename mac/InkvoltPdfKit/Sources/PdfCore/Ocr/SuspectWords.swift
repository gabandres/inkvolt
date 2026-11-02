import Foundation

/// A spelling dictionary for one language (the Windows app's `ISpelling`; the Mac's is `NSSpellChecker`, in the app).
public protocol Spelling: Sendable {
    var language: String { get }

    /// Whether the dictionary knows the word (as written; a word it would only auto-correct isn't known).
    func isKnown(_ word: String) -> Bool

    /// Its suggestions for a word, best first; none when it has none.
    func suggest(_ word: String) -> [String]
}

/// Why a recognized word is a suspect word (several may apply). The raw values are Windows' `SuspectReasons`, written in
/// the text layer's `%w` lines, so a file reviewed on one platform reads the same on the other.
public struct SuspectReasons: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The spell checker for the recognized language doesn't know it.
    public static let notInDictionary = SuspectReasons(rawValue: 1)
    /// Letters and digits mixed inside it ("c0de", "1O5"), the way OCR confuses O and 0, l and 1, S and 5.
    public static let lettersAndDigits = SuspectReasons(rawValue: 2)
    /// A character text rarely has (|, ¦, a control or private-use character), or punctuation inside the word.
    public static let oddCharacters = SuspectReasons(rawValue: 4)
    /// Read differently from the page as scanned than from the cleaned page.
    public static let readDifferently = SuspectReasons(rawValue: 8)
}

/// Suspect words (the Windows app's `SuspectWords`): recognized words worth a second look. Vision gives a confidence per
/// line, not per word (and Windows' recognizer none at all), so this is a heuristic, never a score: a word is suspect when
/// the spell checker for the page's language doesn't know it, when letters and digits are mixed inside it, when it has
/// odd characters, or when the page as scanned and the cleaned page gave different words at its place. Short words,
/// numbers, words in capitals (an acronym) and the usual mixes (A4, 2nd, 10mm, MP3) are left alone.
public enum SuspectWords {
    private static let edges = Set(".,;:!?¿¡\"'“”‘’«»()[]{}…*")

    public static func check(_ text: String, _ spelling: (any Spelling)?) -> SuspectReasons {
        let core = core(text)
        if core.isEmpty { return text.contains(where: odd) ? .oddCharacters : [] }
        var reasons: SuspectReasons = []
        if text.contains(where: odd) || punctuationInside(core) { reasons.insert(.oddCharacters) }
        if mixedInside(core) { reasons.insert(.lettersAndDigits) }
        if let spelling, needsDictionary(core),
           core.split(separator: "-", omittingEmptySubsequences: true).contains(where: { !spelling.isKnown(String($0)) }) {
            reasons.insert(.notInDictionary)
        }
        return reasons
    }

    /// The word without the punctuation around it ("(river)," → "river").
    public static func core(_ text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.firstIndex(where: { !edges.contains($0) }) else { return "" }
        let last = t.lastIndex(where: { !edges.contains($0) })!
        return String(t[first...last])
    }

    /// For each word of `cleaned`, whether the page as scanned (`original`, in the same page space) read the same word
    /// differently: its word nearest the same place (centres within half a line) is spelled a little differently (at
    /// most a third of its letters) and is itself a real word (in `spelling`'s dictionary, when there is one). Then either
    /// reading may be the right one. A place where the scan gave no word, a garbled one or another word altogether
    /// doesn't count.
    public static func readDifferently(_ cleaned: [OcrWord], _ original: [OcrWord], _ spelling: (any Spelling)? = nil) -> [Bool] {
        cleaned.map { word in
            guard let other = alternative(word, original) else { return false }
            return spelling == nil || !needsDictionary(other) || spelling!.isKnown(other)
        }
    }

    /// The page as scanned's reading of a word, when it is the same word read a little differently (see
    /// `readDifferently`), without the punctuation around it; else nil.
    public static func alternative(_ cleaned: OcrWord, _ original: [OcrWord]) -> String? {
        let (cx, cy) = (cleaned.rect.centerX, cleaned.rect.centerY)
        let reach = cleaned.rect.height / 2
        let nearest = original.filter { abs($0.rect.centerY - cy) < reach && $0.rect.contains(cx, cy) }
            .min { abs($0.rect.centerX - cx) + abs($0.rect.centerY - cy) < abs($1.rect.centerX - cx) + abs($1.rect.centerY - cy) }
        guard let nearest else { return nil }
        let (mine, theirs) = (core(cleaned.text), core(nearest.text))
        if theirs.isEmpty || mine == theirs { return nil }
        return distance(Array(mine), Array(theirs)) <= max(1, max(mine.count, theirs.count) / 3) ? theirs : nil
    }

    /// Letters to change, add or remove to turn one word into the other (Levenshtein).
    private static func distance(_ a: [Character], _ b: [Character]) -> Int {
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        if a.isEmpty { return b.count }
        for i in 1...a.count {
            current[0] = i
            if !b.isEmpty {
                for j in 1...b.count {
                    current[j] = min(previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1), min(previous[j] + 1, current[j - 1] + 1))
                }
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    private static func isDigit(_ c: Character) -> Bool {
        c.unicodeScalars.count == 1 && c.unicodeScalars.first!.properties.generalCategory == .decimalNumber
    }

    /// A word to look up: two letters or more, all letters (apostrophes and hyphens inside), not an acronym.
    private static func needsDictionary(_ core: String) -> Bool {
        core.filter(\.isLetter).count >= 2
            && core.allSatisfy { $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }
            && !(core.allSatisfy { !$0.isLowercase } && core.count <= 6)
    }

    /// A digit between letters or a letter between digits; "A4", "MP3", "2nd", "10mm", "COVID-19" are fine.
    private static func mixedInside(_ core: String) -> Bool {
        let c = Array(core)
        if c.count >= 3 {
            for i in 1..<(c.count - 1) {
                let (before, here, after) = (c[i - 1], c[i], c[i + 1])
                if isDigit(here) && before.isLetter && after.isLetter { return true }
                if here.isLetter && isDigit(before) && isDigit(after) { return true }
            }
        }
        // A lone O, l or I among digits at the end or start ("100O", "l23") reads as a digit misread.
        return c.count >= 3 && c.filter(isDigit).count >= c.count - 1 && c.contains { $0 == "O" || $0 == "o" || $0 == "l" || $0 == "I" }
    }

    /// Punctuation a word doesn't have inside it ("wo;rd", "riv(er"); a comma between digits (1,234) is fine.
    private static func punctuationInside(_ core: String) -> Bool {
        let c = Array(core)
        for (i, ch) in c.enumerated() {
            if ";!?\"()[]{}¿¡".contains(ch) { return true }
            if ch == "," && !(i > 0 && i + 1 < c.count && isDigit(c[i - 1]) && isDigit(c[i + 1])) { return true }
        }
        return false
    }

    private static func odd(_ c: Character) -> Bool {
        if c == "|" || c == "¦" || c == "\u{FFFD}" { return true }
        return c.unicodeScalars.contains { s in
            switch s.properties.generalCategory {
            case .control, .privateUse, .surrogate, .unassigned: true
            default: false
            }
        }
    }
}
