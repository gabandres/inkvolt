import Foundation

/// A spelling dictionary people can add words to (the Windows app's `ISpellingDictionary`): `NSSpellChecker` in the app
/// (its Learn Spelling list, which every Mac app using the system's spelling shares), a word list in tests.
public protocol SpellingDictionary: Spelling {
    /// Adds a word to the user's dictionary; false when it couldn't be added.
    func add(_ word: String) -> Bool
}

/// A word of typed text the dictionary doesn't know, and where it starts in that text (UTF-16 units, as `NSRange`).
public struct Misspelling: Equatable, Sendable {
    public var start: Int
    public var word: String

    public init(_ start: Int, _ word: String) {
        self.start = start
        self.word = word
    }

    public var end: Int { start + word.utf16.count }
}

/// Spell check where people type (roadmap 4.1; the Windows app's `SpellChecker`): what in a text is a word to look up,
/// which of those the dictionary doesn't know, and what a person can do about one (a suggestion, Ignore for the rest of
/// the session, Add to dictionary). A word is a run of letters, with an apostrophe inside it ("don't"); a hyphen joins two
/// words that are each looked up. Left alone: anything with a digit ("A4", "2nd"), single letters, words in capitals (an
/// acronym), and addresses (a web or e-mail address, a domain, a file path). The app draws its underlines from `check`
/// in every editor people type into.
public final class SpellChecker: @unchecked Sendable {
    /// Words looked up in one text at most: a pasted book doesn't hold up typing.
    public static let maxWords = 2_000

    /// A "word" longer than this is no word (a hash, a run of letters a crafted file holds): not looked up.
    public static let maxWordLength = 48

    /// Suggestions offered for a word at most.
    public static let maxSuggestions = 5

    /// Answers kept; more and they are forgotten (a long session's typing doesn't grow without end).
    private static let maxKnown = 20_000

    public let dictionary: any SpellingDictionary
    private let skipAllCaps: Bool
    private var known: [String: Bool] = [:]
    private var ignored: Set<String> = []
    private let gate = NSLock()

    public init(_ dictionary: any SpellingDictionary, skipAllCaps: Bool = true) {
        self.dictionary = dictionary
        self.skipAllCaps = skipAllCaps
    }

    /// The dictionary's language ("en-US").
    public var language: String { dictionary.language }

    /// The words of `text` the dictionary doesn't know (and that weren't ignored or added), in order.
    public func check(_ text: String) -> [Misspelling] {
        let u = Array(text.utf16)
        return Self.words(u, skipAllCaps: skipAllCaps).compactMap { w in
            let word = String(decoding: u[w.start..<(w.start + w.length)], as: UTF16.self)
            return knows(word) ? nil : Misspelling(w.start, word)
        }
    }

    /// The misspelling at `index` of the text (the caret just after a word counts), or nil.
    public static func at(_ found: [Misspelling], _ index: Int) -> Misspelling? {
        found.first { index >= $0.start && index <= $0.end }
    }

    /// The dictionary's suggestions for a word, best first, the word itself left out.
    public func suggestions(_ word: String) -> [String] {
        let n = word.utf16.count
        if n == 0 || n > Self.maxWordLength { return [] }
        // The dictionary is asked without the lock held: the Mac's answers on the main thread, which may be waiting on it.
        var seen = Set<String>()
        return Array(dictionary.suggest(word).filter { !$0.isEmpty && $0 != word && seen.insert($0).inserted }.prefix(Self.maxSuggestions))
    }

    /// Ignore: the word isn't underlined again anywhere for as long as this checker lives (the app's session).
    public func ignore(_ word: String) {
        gate.lock()
        defer { gate.unlock() }
        ignored.insert(word)
    }

    /// The word was ignored (`ignore`).
    public func isIgnored(_ word: String) -> Bool {
        gate.lock()
        defer { gate.unlock() }
        return ignored.contains(word)
    }

    /// Add to dictionary: the user's dictionary takes the word (then it is known everywhere); false when it couldn't.
    public func add(_ word: String) -> Bool {
        let n = word.utf16.count
        if n == 0 || n > Self.maxWordLength { return false }
        if !dictionary.add(word) { return false } // without the lock held (see `suggestions`)
        gate.withLock { known[word] = true }
        return true
    }

    /// The text with `m` replaced by `replacement`; nil when the text no longer has that word there (it was typed over
    /// since it was checked).
    public static func correct(_ text: String, _ m: Misspelling, _ replacement: String) -> String? {
        let u = Array(text.utf16), w = Array(m.word.utf16)
        guard m.start >= 0, m.end <= u.count, Array(u[m.start..<m.end]) == w else { return nil }
        return String(decoding: u[..<m.start], as: UTF16.self) + replacement + String(decoding: u[m.end...], as: UTF16.self)
    }

    private func knows(_ word: String) -> Bool {
        let answered: Bool? = gate.withLock { ignored.contains(word) ? true : known[word] }
        if let answered { return answered }
        let k = dictionary.isKnown(word) // without the lock held (see `suggestions`)
        gate.withLock {
            if known.count >= Self.maxKnown { known.removeAll() }
            known[word] = k
        }
        return k
    }

    // ---- What is looked up ----

    /// The words of `text` to look up (start, length in UTF-16 units), at most `maxWords`: see the class's summary for
    /// what is left alone. `skipAllCaps`: words in capitals aren't looked up.
    public static func words(_ text: String, skipAllCaps: Bool = true) -> [(start: Int, length: Int)] {
        words(Array(text.utf16), skipAllCaps: skipAllCaps)
    }

    static func words(_ text: [UInt16], skipAllCaps: Bool) -> [(start: Int, length: Int)] {
        var result: [(start: Int, length: Int)] = []
        var i = 0
        while i < text.count && result.count < maxWords {
            // A chunk: the characters between white space.
            while i < text.count && isWhiteSpace(text[i]) { i += 1 }
            let start = i
            while i < text.count && !isWhiteSpace(text[i]) { i += 1 }
            if i == start { break }
            let chunk = Array(text[start..<i])
            if isAddress(chunk) { continue }
            for (s, l) in wordsIn(chunk) where checked(chunk[s..<(s + l)], skipAllCaps) {
                result.append((start + s, l))
                if result.count >= maxWords { break }
            }
        }
        return result
    }

    /// The runs of letters (and digits, judged later) in a chunk, an apostrophe between two letters kept inside.
    private static func wordsIn(_ chunk: [UInt16]) -> [(start: Int, length: Int)] {
        var result: [(start: Int, length: Int)] = []
        var i = 0
        while i < chunk.count {
            if !isWordChar(chunk[i]) {
                i += 1
                continue
            }
            let start = i
            while i < chunk.count && (isWordChar(chunk[i]) || (isApostrophe(chunk[i]) && i + 1 < chunk.count && isLetter(chunk[i + 1]) && i > start)) {
                i += 1
            }
            result.append((start, i - start))
        }
        return result
    }

    /// The UTF-16 unit as a scalar; nil for half of a surrogate pair (.NET's char tests say no to those).
    private static func scalar(_ c: UInt16) -> Unicode.Scalar? { Unicode.Scalar(c) }

    private static func isWhiteSpace(_ c: UInt16) -> Bool { scalar(c)?.properties.isWhitespace ?? false }

    private static func isLetter(_ c: UInt16) -> Bool {
        switch scalar(c)?.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    private static func isDigit(_ c: UInt16) -> Bool { scalar(c)?.properties.generalCategory == .decimalNumber }

    private static func isWordChar(_ c: UInt16) -> Bool {
        if isLetter(c) || isDigit(c) { return true }
        let category = scalar(c)?.properties.generalCategory
        return category == .nonspacingMark || category == .spacingMark
    }

    private static func isApostrophe(_ c: UInt16) -> Bool { c == 0x27 || c == 0x2019 }

    /// A word worth looking up: two letters or more, no digit, not too long, not in capitals when those are skipped.
    private static func checked(_ word: ArraySlice<UInt16>, _ skipAllCaps: Bool) -> Bool {
        if word.count < 2 || word.count > maxWordLength { return false }
        var letters = 0, upper = 0
        for c in word {
            if isDigit(c) { return false }
            if !isLetter(c) { continue }
            letters += 1
            if scalar(c)?.properties.generalCategory == .uppercaseLetter { upper += 1 }
        }
        if letters < 2 { return false }
        return !(skipAllCaps && upper == letters)
    }

    /// A web or e-mail address, a domain ("example.com") or a file path: never a word to look up.
    private static func isAddress(_ chunk: [UInt16]) -> Bool {
        let s = String(decoding: chunk, as: UTF16.self)
        if s.contains("://") || s.lowercased().hasPrefix("www.") { return true }
        if chunk.contains(0x5C) || chunk.contains(0x2F) { return true } // \ or /
        if let at = chunk.firstIndex(of: 0x40), at > 0 && at < chunk.count - 1 { return true }
        return domain.firstMatch(in: s, range: NSRange(location: 0, length: chunk.count)) != nil
    }

    private static let domain = try! NSRegularExpression(
        pattern: #"^[(\[\"'“‘]*[\p{L}\p{N}-]+(\.[\p{L}\p{N}-]+)*\.(com|org|net|edu|gov|io|info|biz|co|uk|us|es|mx|de|fr|it|pt|br|ar|cl|ca|eu|app|dev)[)\]\"'”’.,;:!?]*$"#,
        options: [.caseInsensitive])

    // ---- Which language ----

    /// The languages to try, in order, for text typed into a document: the document's own (its /Lang, when it names one),
    /// the interface's (in the Mac's region when the Mac speaks the same language: "es-MX", not "es"), the Mac's language,
    /// then US English. The first one the Mac has a dictionary for is used; none, and nothing is checked.
    public static func languages(_ document: String?, _ interfaceLanguage: String, _ system: String) -> [String] {
        var result: [String] = []
        func add(_ tag: String?) {
            if let t = Self.tag(tag), !result.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) { result.append(t) }
        }
        add(document)
        let ui = Self.tag(interfaceLanguage).map { String($0.split(separator: "-")[0]) }
        if let ui, let w = Self.tag(system), w.split(separator: "-")[0] == ui {
            add(w)
        } else {
            add(ui == "en" ? "en-US" : ui == "es" ? "es-ES" : ui == "pt" ? "pt-BR" : ui)
        }
        add(system)
        add("en-US")
        return result
    }

    /// A language tag as BCP 47 writes it ("es-MX"), or nil when `tag` isn't one.
    static func tag(_ tag: String?) -> String? {
        guard let t = tag?.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "_", with: "-"), !t.isEmpty, t.utf16.count <= 35,
              languageTag.firstMatch(in: t, range: NSRange(location: 0, length: t.utf16.count)) != nil else { return nil }
        return t.split(separator: "-", omittingEmptySubsequences: false).enumerated().map { i, part in
            if i == 0 { return part.lowercased() }
            switch part.count {
            case 2: return part.uppercased()
            case 4: return part.prefix(1).uppercased() + part.dropFirst().lowercased()
            default: return part.lowercased()
            }
        }.joined(separator: "-")
    }

    private static let languageTag = try! NSRegularExpression(pattern: #"^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$"#)

    /// The language a document says its text is in (its catalog's /Lang), or nil when it says none or can't be read.
    public static func documentLanguage(_ data: [UInt8], _ password: String?) -> String? {
        guard let doc = try? PdfEdit.openToRead(data, password) else { return nil } // a damaged or refused file: the interface's language instead
        return tag(doc.catalog.text("Lang"))
    }
}
