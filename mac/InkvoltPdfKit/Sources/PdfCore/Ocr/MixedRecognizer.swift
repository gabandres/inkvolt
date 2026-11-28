import Foundation

/// Pages in two languages (roadmap 2.2; the Windows app's `MixedRecognizer`), read by two recognizers that each read one
/// language (Vision with one language each): each reads the whole page, and for each line the reading that looks more like
/// real words is kept. Lines are matched by place (a line of one reading and a line of the other that share their height
/// and overlap across are the same line, with whatever lines those overlap); a line only one of them read is kept as read.
/// A reading's words count by their letters, each as much as it is plausible: known to its language's spell checker, else
/// the engine's confidence when it gives one, else half. Ties go to the first language.
///
/// Its `language` is both languages' tags joined by "+" ("en-US+es-MX", Windows' `PageRecognizer.Language`), which the
/// text layer keeps for the review of its words.
public struct MixedRecognizer: TextRecognizer {
    public let first: any TextRecognizer
    public let second: any TextRecognizer
    private let firstSpelling: (any Spelling)?
    private let secondSpelling: (any Spelling)?

    public init(_ first: any TextRecognizer, _ firstSpelling: (any Spelling)?, _ second: any TextRecognizer, _ secondSpelling: (any Spelling)?) {
        self.first = first
        self.firstSpelling = firstSpelling
        self.second = second
        self.secondSpelling = secondSpelling
    }

    public var language: String? {
        var tags: [String] = []
        for t in MixedRecognizer.languagesOf(first) + MixedRecognizer.languagesOf(second)
        where !tags.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { tags.append(t) }
        return tags.isEmpty ? nil : tags.joined(separator: "+")
    }

    /// The languages a recognizer reads (BCP-47 tags, first one first; Windows' `ScanText.LanguagesOf`): two for a page in two.
    public static func languagesOf(_ recognizer: any TextRecognizer) -> [String] {
        (recognizer.language ?? "").split(separator: "+").map(String.init).filter { !$0.isEmpty }
    }

    /// The first recognizer's (both are Vision on the Mac).
    public var unsureBelow: Double { first.unsureBelow }

    public func recognize(_ image: RenderedImage, cancel: CancelToken?) throws -> [OcrWord] {
        try read(image, cancel: cancel).map(\.word)
    }

    public func read(_ image: RenderedImage, cancel: CancelToken?) throws -> [RecognizedWord] {
        let a = try first.read(image, cancel: cancel)
        try cancel.check()
        let b = try second.read(image, cancel: cancel)
        return Self.choose(a, firstSpelling, b, secondSpelling)
    }

    /// For each line, the reading of `a` or `b` that is more plausible; in `a`'s reading order.
    public static func choose(_ a: [RecognizedWord], _ spellA: (any Spelling)?, _ b: [RecognizedWord], _ spellB: (any Spelling)?) -> [RecognizedWord] {
        let linesA = lines(a), linesB = lines(b)
        // Union-find over A's lines (0..) and B's lines (linesA.count..).
        var parent = Array(0..<(linesA.count + linesB.count))
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i {
                parent[i] = parent[parent[i]]
                i = parent[i]
            }
            return i
        }
        for i in linesA.indices {
            for j in linesB.indices where same(linesA[i].box, linesB[j].box) { parent[find(i)] = find(linesA.count + j) }
        }

        var scoreA: [Int: Double] = [:], scoreB: [Int: Double] = [:]
        for i in linesA.indices { scoreA[find(i), default: 0] += linesA[i].words.reduce(0) { $0 + plausibility($1, spellA) } }
        for j in linesB.indices { scoreB[find(linesA.count + j), default: 0] += linesB[j].words.reduce(0) { $0 + plausibility($1, spellB) } }
        func takesB(_ group: Int) -> Bool { (scoreB[group] ?? 0) > (scoreA[group] ?? 0) || scoreA[group] == nil }

        // Groups in A's order; a group only B read goes after the group B read just before it.
        var order: [Int] = []
        var seen = Set<Int>()
        for g in linesA.indices.map(find) where seen.insert(g).inserted { order.append(g) }
        var previous = -1
        for g in linesB.indices.map({ find(linesA.count + $0) }) {
            if seen.insert(g).inserted { order.insert(g, at: previous < 0 ? 0 : (order.firstIndex(of: previous) ?? -1) + 1) }
            previous = g
        }

        var result: [RecognizedWord] = []
        var line = 0
        for g in order {
            let (chosen, offset) = takesB(g) ? (linesB, linesA.count) : (linesA, 0)
            for k in chosen.indices where find(offset + k) == g {
                result += chosen[k].words.map { w in
                    var w = w
                    w.line = line
                    return w
                }
                line += 1
            }
        }
        return result
    }

    /// How much a word counts for its reading: its letters, each as plausible as the word is (0-1). A word its spell
    /// checker knows: 1; one it doesn't (a name): a quarter, up to a half with the engine's confidence; without a spell
    /// checker: the engine's confidence, else a half. Letters mixed with digits or punctuation ("rn,1l", "negr0") read as
    /// garbage: a tenth at most, so they never outweigh a name.
    static func plausibility(_ word: RecognizedWord, _ spelling: (any Spelling)?) -> Double {
        let core = SuspectWords.core(word.text)
        // Counted by UTF-16 unit, as .NET counts chars (a letter outside the BMP counts twice there too).
        let letters = core.unicodeScalars.filter { isLetter($0) }.reduce(0) { $0 + $1.utf16.count }
        if letters == 0 { return 0 }
        let sure = word.confidence.map { min(max($0, 0), 100) / 100 }
        let wordLike = core.unicodeScalars.allSatisfy { s in
            isLetter(s) || s.properties.generalCategory == .nonspacingMark || s.properties.generalCategory == .spacingMark || s == "'" || s == "’" || s == "-"
        }
        let p: Double
        if !wordLike {
            p = 0.1 * (sure ?? 1)
        } else if let spelling {
            p = core.split(separator: "-", omittingEmptySubsequences: true).allSatisfy({ spelling.isKnown(String($0)) }) ? 1 : 0.25 + 0.25 * (sure ?? 0)
        } else {
            p = sure ?? 0.5
        }
        return Double(letters) * p
    }

    /// .NET's `char.IsLetter`: the letter categories.
    private static func isLetter(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    private struct Box {
        var x0: Double, y0: Double, x1: Double, y1: Double
    }

    private static func lines(_ words: [RecognizedWord]) -> [(words: [RecognizedWord], box: Box)] {
        var result: [(words: [RecognizedWord], box: Box)] = []
        var index: [Int: Int] = [:]
        for w in words {
            let i: Int
            if let known = index[w.line] {
                i = known
            } else {
                i = result.count
                index[w.line] = i
                result.append(([], Box(x0: w.rect.x, y0: w.rect.y, x1: w.rect.right, y1: w.rect.bottom)))
            }
            result[i].words.append(w)
            let b = result[i].box
            result[i].box = Box(x0: min(b.x0, w.rect.x), y0: min(b.y0, w.rect.y), x1: max(b.x1, w.rect.right), y1: max(b.y1, w.rect.bottom))
        }
        return result
    }

    /// The same line: they overlap across, and over at least half the shorter one's height.
    private static func same(_ a: Box, _ b: Box) -> Bool {
        let across = min(a.x1, b.x1) - max(a.x0, b.x0)
        let down = min(a.y1, b.y1) - max(a.y0, b.y0)
        return across > 0 && down >= 0.5 * min(a.y1 - a.y0, b.y1 - b.y0)
    }
}

/// Two languages' spell checkers as one (suspect words on a page read in two languages; Windows' `EitherSpelling`): a word
/// either knows is known; suggestions from the first, then the second.
public struct EitherSpelling: Spelling {
    public let first: any Spelling
    public let second: any Spelling

    public init(_ first: any Spelling, _ second: any Spelling) {
        self.first = first
        self.second = second
    }

    public var language: String { first.language }

    public func isKnown(_ word: String) -> Bool { first.isKnown(word) || second.isKnown(word) }

    public func suggest(_ word: String) -> [String] {
        var all: [String] = []
        for s in first.suggest(word) + second.suggest(word) where !all.contains(s) { all.append(s) }
        return Array(all.prefix(8))
    }

    /// Both when there are two, else whichever there is.
    public static func of(_ first: (any Spelling)?, _ second: (any Spelling)?) -> (any Spelling)? {
        guard let first else { return second }
        guard let second else { return first }
        return EitherSpelling(first, second)
    }
}
