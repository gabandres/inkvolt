import Foundation
import Testing
@testable import PdfCore

/// Ported from IndexTermsTests.cs: the index's words. Whatever Find, with case and accents ignored, treats as equal has to
/// file under the same term. Adapted: Windows asks its collation's sort keys what Find reads alike; the Mac's Find is
/// Foundation's comparison, so `Letters_Find_treats_as_the_same_have_one_term` asks that, letter by letter.
struct IndexTermsTests {
    private func terms(_ text: String) -> [String] {
        var out: [String] = []
        IndexTerms.read(text) { out.append($0) }
        return out
    }

    @Test(arguments: [("Hello, World", "hello|world"), ("CAFÉ Résumé", "cafe|resume"), ("café", "cafe"),
                      ("ﬁnal oﬃce", "final|office"), ("Straße", "strasse"), ("ｆｕｌｌ１２", "full12"),
                      ("soft\u{AD}hyphen", "softhyphen"), ("don't stop-now_please", "don|t|stop|now|please"), ("٣٤", "34")])
    func Words_are_folded(_ c: (text: String, expected: String)) {
        let expected: [String] = c.expected.split(separator: "|").map { String($0) }
        let found = terms(c.text)
        #expect(found == expected)
    }

    @Test func Text_without_spaces_is_filed_as_pairs() {
        #expect(terms("東京都") == ["東京", "京都"])
        #expect(terms("東") == ["東"])
        #expect(terms("東京 abc 京都") == ["東京", "abc", "京都"])
        #expect(terms("東京tower") == ["東京", "tower"])
    }

    @Test func A_long_run_is_cut_and_a_query_cut_the_same_way() {
        let found = terms(String(repeating: "a", count: 500) + " b")
        #expect(found[0] == String(repeating: "a", count: IndexTerms.maxChars))
        #expect(found[1] == "b")
        #expect(IndexTerms.of(String(repeating: "a", count: 60))[0] == String(repeating: "a", count: IndexTerms.maxChars))
    }

    @Test func Half_a_surrogate_pair_breaks_a_word_and_breaks_nothing_else() {
        let ab: [UInt16] = [0x61, 0x62], cd: [UInt16] = [0x63, 0x64]
        var found: [String] = []
        IndexTerms.read(ab + [0xD83D] + cd) { found.append($0) }
        #expect(found == ["ab", "cd"])
        found = []
        IndexTerms.read(ab + [0xDC00]) { found.append($0) }
        #expect(found == ["ab"])
        #expect(terms("𝐀") == ["a"]) // a mathematical capital A
    }

    @Test func A_query_of_only_punctuation_has_no_terms() {
        #expect(IndexTerms.of("+-*/ ... §").isEmpty)
    }

    /// The promise behind the index: a letter Find sees as the same as another (Foundation's comparison with case and
    /// accents ignored: its folded form, lower and upper case, its parts) files under the same term, so a search by index
    /// can't lose a page Find would find. Compared as whole words made of the letter, so ignorable and word-breaking
    /// characters show up too.
    @Test func Letters_Find_treats_as_the_same_have_one_term() {
        var lost: [String] = []
        for cp in UInt32(0x20)..<0xFFFF {
            if (0xD800...0xF8FF).contains(cp) || (0x3400...0x9FFF).contains(cp) || (0xAC00...0xD7A3).contains(cp) { continue }
            guard let scalar = Unicode.Scalar(cp) else { continue }
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .otherLetter, .decimalNumber, .letterNumber: break
            default: continue
            }
            let letter = String(Character(scalar))
            let mine = terms(letter)
            let alike = [letter.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil), letter.lowercased(),
                         letter.uppercased(), letter.decomposedStringWithCanonicalMapping]
            for other in Set(alike) where other != letter {
                // Only what Find itself reads as the same letter.
                guard letter.compare(other, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame else { continue }
                if terms(other) != mine {
                    lost.append("\(letter) U+\(String(cp, radix: 16, uppercase: true)) [\(mine.joined(separator: "|"))] vs \(other) [\(terms(other).joined(separator: "|"))]")
                }
            }
        }
        #expect(lost.isEmpty, "\(lost.count) letters Find reads alike file apart:\n\(lost.prefix(120).joined(separator: "\n"))")
    }

    @Test(arguments: [("Ærøskøbing", "aeroskobing"), ("Œuvre", "oeuvre"), ("Łódź", "lodz"), ("Đà Nẵng", "da nang"),
                      ("ΣΊΣΥΦΟΣ", "σίσυφος"), ("Ñandú", "nandu"), ("Ñ", "n")])
    func Find_agrees_and_so_does_the_index(_ c: (page: String, query: String)) {
        // Where Find, with case and accents ignored, finds it on the page (Foundation's comparison: "Ł", "ø" and "æ" are
        // letters of their own to it, unlike Windows')...
        let found = !PageText.findIn(c.page, c.query, matchCase: false, wholeWord: false, ignoreAccents: true).isEmpty
        let latinOnly = c.page.unicodeScalars.contains { "ÆØŒŁĐæøœłđ".unicodeScalars.contains($0) }
        #expect(found || latinOnly)
        // ...the index proposes the page, and for the letters only Windows' Find reads as Latin ones too.
        let pageTerms = terms(c.page)
        for term in IndexTerms.of(c.query) {
            #expect(pageTerms.contains { $0.contains(term) }, "\(term) not in \(pageTerms)")
        }
    }
}
