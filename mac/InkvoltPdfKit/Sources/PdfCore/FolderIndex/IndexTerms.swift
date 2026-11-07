import Foundation

/// The words a `FolderIndex` files a page under, and the words of a query, read the same way (Windows' `IndexTerms`). A
/// term is a run of letters and digits folded so that everything Find treats as equal with case and accents ignored
/// (`PageText`'s search: Foundation's `.caseInsensitive` and `.diacriticInsensitive`) comes out the same: "É", "é", "e" and
/// "ｅ" are all "e", "ﬁ" is "fi", "ß" is "ss". It may fold more than Find does, never less: the index only proposes pages,
/// and Find's own comparison has the last word on the stored text. Scripts written without spaces (Chinese, Japanese,
/// Thai…) have no words to cut, so they are filed as overlapping pairs of characters. Changing what comes out here means
/// bumping `version`: indexes are then built again.
///
/// The Mac's folding asks Foundation (Windows asks its collation's sort keys): each letter of the Basic Multilingual Plane
/// folded with case, accents and width ignored, then taken apart by Unicode (NFKD) with its marks left out, plus the
/// letters Unicode doesn't take apart that Windows' Find reads as Latin ones (ø, æ, œ, ł, đ…). `stamp` hashes the whole
/// table, so an index built by an older macOS whose tables differ is built again.
enum IndexTerms {
    /// The folding's version, kept in the index file's header.
    static let version = 1

    /// A longer run (a base64 blob, hostile text) is filed under its start; a query's long word is cut the same way.
    static let maxChars = 48

    /// Calls `emit` with each term of `text`, in order, repeats included.
    static func read(_ text: String, _ emit: (String) -> Void) {
        read(Array(text.utf16), emit)
    }

    /// The same over UTF-16 units.
    static func read(_ text: [UInt16], _ emit: (String) -> Void) {
        let table = Table.shared
        var word = [UInt16]()
        word.reserveCapacity(maxChars)
        var full = false
        var previous: UInt32 = 0     // the last character of a run of spaceless script, when `inRun`
        var inRun = false
        var paired = false           // that run has given a pair already: a run of one is filed alone

        func endWord() {
            if !word.isEmpty { emit(String(decoding: word, as: UTF16.self)) }
            word.removeAll(keepingCapacity: true)
            full = false
        }
        func endRun() {
            if inRun && !paired { emit(string(previous)) }
            inRun = false
            paired = false
        }

        var i = 0
        let count = text.count
        while i < count {
            var cp = UInt32(text[i])
            if UTF16.isLeadSurrogate(text[i]) && i + 1 < count && UTF16.isTrailSurrogate(text[i + 1]) {
                cp = 0x10000 + ((cp - 0xD800) << 10) + (UInt32(text[i + 1]) - 0xDC00)
                i += 1
            } else if cp >= 0xD800 && cp <= 0xDFFF {
                cp = 0x20 // half a pair, as a damaged PDF can give: nothing to file
            }
            i += 1

            if cp < 0x80 {
                // Most text is here: letters and digits as they are, the rest breaks words.
                let isUpper = cp >= 0x41 && cp <= 0x5A
                if isUpper || (cp >= 0x61 && cp <= 0x7A) || (cp >= 0x30 && cp <= 0x39) {
                    if inRun { endRun() }
                    if word.count < maxChars { word.append(UInt16(isUpper ? cp + 32 : cp)) } else { full = true }
                } else if !word.isEmpty || inRun {
                    endWord()
                    if inRun { endRun() }
                }
                continue
            }

            for c in table.fold(cp) {
                if c == 0x20 {
                    endWord()
                    if inRun { endRun() }
                } else if isSpaceless(c) {
                    endWord()
                    if inRun {
                        emit(string(previous) + string(c))
                        paired = true
                    }
                    previous = c
                    inRun = true
                } else {
                    if inRun { endRun() }
                    let units = c > 0xFFFF ? 2 : 1
                    if !full && word.count + units <= maxChars {
                        if let scalar = Unicode.Scalar(c) { word.append(contentsOf: scalar.utf16) }
                    } else {
                        full = true
                    }
                }
            }
        }
        endWord()
        if inRun { endRun() }
    }

    /// The terms of a query, in order, repeats included.
    static func of(_ query: String) -> [String] {
        var terms: [String] = []
        read(query) { terms.append($0) }
        return terms
    }

    private static func string(_ cp: UInt32) -> String {
        guard let scalar = Unicode.Scalar(cp) else { return "" }
        return String(Character(scalar))
    }

    /// Written without spaces between words, so filed as pairs of characters.
    static func isSpaceless(_ c: UInt32) -> Bool {
        switch c {
        case 0x0E00...0x0EFF, 0x1000...0x109F, 0x1780...0x17FF: true   // Thai, Lao; Myanmar; Khmer
        case 0x3040...0x30FF: true                                     // Hiragana, Katakana
        case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: true   // CJK ideographs
        case 0x20000...0x3FFFF: true
        default: false
        }
    }

    /// Says which folding wrote an index: `version` and a hash of what this macOS folds each letter to.
    static var stamp: Int64 { (Int64(version) << 32) | Int64(Table.shared.stamp) }

    // ---- The folding ----

    private enum Kind { case ignored, letter, separator }

    private static func kind(_ scalar: Unicode.Scalar) -> Kind {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .format: .ignored
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter, .spacingMark,
             .decimalNumber, .letterNumber, .otherNumber: .letter
        default: .separator
        }
    }

    /// Letters Unicode doesn't take apart that Windows' Find (and a reader) takes for Latin ones: filed as those, so the
    /// index proposes the page and Find decides.
    private static let latin: [UInt32: String] = [
        0x00D8: "o", 0x00F8: "o", 0x00C6: "ae", 0x00E6: "ae", 0x0152: "oe", 0x0153: "oe", 0x0141: "l", 0x0142: "l",
        0x0110: "d", 0x0111: "d", 0x00D0: "d", 0x00F0: "d", 0x0126: "h", 0x0127: "h", 0x0131: "i", 0x0138: "k",
        0x013F: "l", 0x0140: "l", 0x014A: "n", 0x014B: "n", 0x0166: "t", 0x0167: "t", 0x00DE: "th", 0x00FE: "th",
        0x00DF: "ss", 0x1E9E: "ss", 0x0180: "b", 0x0197: "i", 0x0268: "i", 0x01B5: "z", 0x01B6: "z",
    ]

    /// What a character outside ASCII files as: its folded letters (as scalars), nothing when it is ignored, a space
    /// (0x20) when it breaks words.
    private static func compute(_ cp: UInt32) -> [UInt32] {
        guard let scalar = Unicode.Scalar(cp) else { return [0x20] }
        switch kind(scalar) {
        case .ignored: return []
        case .separator: return [0x20]
        case .letter: break
        }
        if (0xAC00...0xD7A3).contains(cp) || isSpaceless(cp) { return [cp] } // Korean syllables stay whole; pairs file ideographs
        if let same = latin[cp] { return same.unicodeScalars.map(\.value) }
        // A digit of any script files as its ASCII digit ("٣" as "3"), as Windows' Find reads them alike.
        if scalar.properties.generalCategory == .decimalNumber, let n = scalar.properties.numericValue, n >= 0, n <= 9 {
            return [0x30 + UInt32(n)]
        }
        // Through upper case first: letters that are only lower case variants ("ᲀ", a rounded "в"; "ſ") meet their
        // plain letter there, which Foundation's folding alone leaves apart while its comparison doesn't. Only when that
        // stays one letter: "ᾀ" in upper case is two ("ἈΙ"), and Find reads it as "α".
        let alone = String(Character(scalar))
        let roundTrip = alone.uppercased().lowercased()
        let cased = roundTrip.unicodeScalars.count == 1 ? roundTrip : alone
        let folded = cased.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        var out: [UInt32] = []
        for s in folded.decomposedStringWithCompatibilityMapping.unicodeScalars {
            if let same = latin[s.value] {
                out += same.unicodeScalars.map(\.value)
                continue
            }
            switch kind(s) {
            case .ignored: continue
            case .separator: out.append(0x20)
            case .letter:
                for lower in s.properties.lowercaseMapping.unicodeScalars { out.append(lower.value) }
            }
        }
        return out
    }

    /// The folding of every character of the Basic Multilingual Plane, made once (about 100 ms, the first time text
    /// outside ASCII comes along), read by any thread; characters beyond it are folded as they come.
    private final class Table: Sendable {
        static let shared = Table()
        private let bmp: [[UInt32]]
        let stamp: UInt32

        private init() {
            var bmp = [[UInt32]](repeating: [], count: 0x10000)
            var stamp: UInt32 = 2166136261 // FNV-1a: the same on every run
            for cp in UInt32(0x80)..<0x10000 {
                if (0xD800...0xDFFF).contains(cp) { continue }
                let f = IndexTerms.compute(cp)
                bmp[Int(cp)] = f
                if (0x3400...0x9FFF).contains(cp) || (0xAC00...0xD7A3).contains(cp) || (0xE000...0xF8FF).contains(cp) { continue }
                for v in f { stamp = (stamp ^ v) &* 16777619 }
                stamp = (stamp ^ cp) &* 16777619
            }
            self.bmp = bmp
            self.stamp = stamp
        }

        func fold(_ cp: UInt32) -> [UInt32] { cp < 0x10000 ? bmp[Int(cp)] : IndexTerms.compute(cp) }
    }
}
