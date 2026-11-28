import Foundation
import Testing
@testable import PdfCore

/// Roadmap 2.1: a font's own pair kerning (GPOS, kern) for text a paragraph edit lays out (ported from FontKerningTests.cs).
/// Mac difference: the installed Arial's tables come from Core Text (`PairKerning.read(CTFont)`), where Windows reads
/// arial.ttf's bytes.
struct FontKerningTests {
    // ---- A font's tables, read ----

    /// An sfnt of the tables given (head with 1000 units per em added).
    static func sfnt(_ tables: (String, [UInt8])...) -> [UInt8] {
        var head = [UInt8](repeating: 0, count: 54)
        head[18] = UInt8(1000 >> 8)
        head[19] = UInt8(1000 & 255)
        return PairKerning.sfnt(tables.map { (tag: $0.0, data: $0.1) } + [(tag: "head", data: head)])
    }

    static func words(_ values: Int...) -> [UInt8] { words(values) }

    static func words(_ values: [Int]) -> [UInt8] { values.flatMap { [UInt8($0 >> 8 & 255), UInt8($0 & 255)] } }

    /// A 'kern' table: version 0, one horizontal format 0 subtable with these pairs (sorted).
    static func kernTable(_ pairs: (Int, Int, Int)...) -> [UInt8] {
        let sorted = pairs.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
        var w = [0, 1, 0, 14 + 6 * sorted.count, 1, sorted.count, 0, 0, 0]
        for (l, r, v) in sorted { w += [l, r, v & 0xFFFF] }
        return words(w)
    }

    /// A GPOS table with one 'kern' feature of one lookup (type 2, or type 9 holding it), whose subtables are a format 1
    /// pair set (glyph 10 then 20: -50; 10 then 21: -30) and a format 2 class pair (glyphs 30-31 class 1 then 40 class 1: -70).
    static func gpos(_ extensionLookup: Bool) -> [UInt8] {
        // Subtable 1, PairPos format 1: coverage [10]; one pair set {20: -50, 21: -30}; value format 1 = XAdvance.
        let f1 = words(1, 12, 4, 0, 1, 18, /* coverage */ 1, 1, 10, /* pair set */ 2, 20, -50 & 0xFFFF, 21, -30 & 0xFFFF)
        // Subtable 2, PairPos format 2: coverage [30, 31]; class def 1: 30-31 → 1; class def 2: 40 → 1; 2 x 2 classes.
        let cov = words(1, 2, 30, 31)
        let cd1 = words(2, 1, 30, 31, 1)
        let cd2 = words(1, 40, 1, 1)
        let head2 = 16
        let records = words(0, 0, 0, -70 & 0xFFFF)
        let covAt = head2 + records.count
        let cd1At = covAt + cov.count
        let cd2At = cd1At + cd1.count
        let f2 = words(2, covAt, 4, 0, cd1At, cd2At, 2, 2) + records + cov + cd1 + cd2
        var lookup: [UInt8]
        if !extensionLookup {
            let at1 = 10
            lookup = words(2, 0, 2, at1, at1 + f1.count) + f1 + f2
        } else {
            // Two extension subtables (8 bytes each) pointing on to the pair subtables.
            let e1 = 10, e2 = e1 + 8
            let p1 = e2 + 8, p2 = p1 + f1.count
            func ext(_ from: Int, _ to: Int) -> [UInt8] { words(1, 2) + [0, 0, UInt8((to - from) >> 8 & 255), UInt8((to - from) & 255)] }
            lookup = words(9, 0, 2, e1, e2) + ext(e1, p1) + ext(e2, p2) + f1 + f2
        }
        let scripts = words(0)
        let feature = words(0, 1, 0)
        let features: [UInt8] = [0, 1] + Array("kern".utf8) + words(8) + feature
        let lookups = words(1, 4) + lookup
        let scriptAt = 10
        let featureAt = scriptAt + scripts.count
        let lookupAt = featureAt + features.count
        return words(1, 0, scriptAt, featureAt, lookupAt) + scripts + features + lookups
    }

    @Test func theKernTablesPairsAreRead() throws {
        let k = try #require(PairKerning.read(Self.sfnt(("kern", Self.kernTable((36, 57, -80), (55, 82, -60), (36, 55, -40))))))
        #expect(k.unitsPerEm == 1000)
        #expect(k.kern(36, 57) == -80)
        #expect(k.kern(55, 82) == -60)
        #expect(k.kern(36, 55) == -40)
        #expect(k.kern(57, 36) == 0)
        #expect(k.kern(1, 2) == 0)
    }

    @Test(arguments: [false, true])
    func gposPairAdjustmentsAreRead(_ extensionLookup: Bool) throws {
        let k = try #require(PairKerning.read(Self.sfnt(("GPOS", Self.gpos(extensionLookup)))))
        #expect(k.kern(10, 20) == -50)
        #expect(k.kern(10, 21) == -30)
        #expect(k.kern(10, 22) == 0)
        #expect(k.kern(30, 40) == -70)
        #expect(k.kern(31, 40) == -70)
        #expect(k.kern(30, 41) == 0) // class 0: the record's 0
        #expect(k.kern(20, 10) == 0)
    }

    @Test(arguments: [(true, -30), (false, -50)])
    func oneScriptsKernFeatureCountsLatinFirst(_ latinKerns: Bool, _ expected: Int) throws {
        // DFLT's kern feature has its lookup (10 then 20: -50), latn's another (-30). Latin's applies, once; a latn
        // language system without a kern feature leaves DFLT's.
        func pair(_ v: Int) -> [UInt8] { Self.words(1, 12, 4, 0, 1, 18, 1, 1, 10, 1, 20, v & 0xFFFF) }
        let lookup0 = Self.words(2, 0, 1, 8) + pair(-50)
        let lookup1 = Self.words(2, 0, 1, 8) + pair(-30)
        let lookups = Self.words(2, 6, 6 + lookup0.count) + lookup0 + lookup1
        func feature(_ index: Int) -> [UInt8] { Self.words(0, 1, index) }
        let features = Self.words(2) + Array("kern".utf8) + Self.words(14) + Array("kern".utf8) + Self.words(20) + feature(0) + feature(1)
        // Script list: DFLT (default language: feature 0), latn (default language: feature 1, or none).
        func langSys(_ feature: Int?) -> [UInt8] { feature.map { Self.words(0, 0xFFFF, 1, $0) } ?? Self.words(0, 0xFFFF, 0) }
        let scripts = Self.words(2) + Array("DFLT".utf8) + Self.words(14) + Array("latn".utf8) + Self.words(26)
            + Self.words(4, 0) + langSys(0) + Self.words(4, 0) + langSys(latinKerns ? 1 : nil)
        let scriptAt = 10
        let featureAt = scriptAt + scripts.count
        let lookupAt = featureAt + features.count
        let gpos = Self.words(1, 0, scriptAt, featureAt, lookupAt) + scripts + features + lookups
        let k = try #require(PairKerning.read(Self.sfnt(("GPOS", gpos))))
        #expect(k.kern(10, 20) == expected)
    }

    @Test func aFontWithoutKerningHasNone() {
        #expect(PairKerning.read(Self.sfnt()) == nil)
        #expect(PairKerning.read([]) == nil)
        #expect(PairKerning.read([UInt8](repeating: 0, count: 11)) == nil)
    }

    @Test func aCutOrScrambledFontNeverThrows() {
        var seed: UInt64 = 7
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(n))
        }
        for font in [Self.sfnt(("GPOS", Self.gpos(true))), Self.sfnt(("kern", Self.kernTable((36, 57, -80))))] {
            for cut in stride(from: 0, to: font.count, by: 3) {
                let k = PairKerning.read(Array(font[..<cut]))
                _ = k?.kern(10, 20)
                _ = k?.kern(36, 57)
            }
            for _ in 0..<300 {
                var bad = font
                for _ in 0..<4 { bad[12 + 16 * 2 + next(bad.count - (12 + 16 * 2))] = UInt8(next(256)) }
                let k = PairKerning.read(bad)
                _ = k?.kern(10, 20)
                _ = k?.kern(30, 40)
                _ = k?.kern(36, 57)
            }
        }
    }

    /// The installed Arial, as Core Text has it.
    static var arial: TrueTypeFont { StandInFonts.face("Arial", false, false)!.font }

    @Test func arialsOwnKerningIsRead() throws {
        let arial = Self.arial
        let k = try #require(PairKerning.read(arial.font))
        func g(_ c: Character) -> Int { arial.glyphOf(c.unicodeScalars.first!.value) }
        #expect(k.kern(g("A"), g("V")) < 0)
        #expect(k.kern(g("T"), g("o")) < 0)
        #expect(k.kern(g("H"), g("H")) == 0)
    }

    // ---- In a paragraph edit ----

    static let chars = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 .,;:!?'-"

    /// Arial's own adjustment for a pair, as a TJ number (thousandths of an em, positive: closer).
    static func arialPair(_ a: Character, _ b: Character) -> Double {
        let arial = Self.arial
        let k = PairKerning.read(arial.font)!
        let v = -Double(k.kern(arial.glyphOf(a.unicodeScalars.first!.value), arial.glyphOf(b.unicodeScalars.first!.value))) * 1000 / k.unitsPerEm
        return (v * 10).rounded() / 10
    }

    static func n(_ v: Double) -> String { PdfNum.f(v) }

    @Test func newPairsInAKernedParagraphGetTheFontsOwnKerning() throws {
        // The generator kerned "fo" by -40 (a TJ adjustment inside a word): the paragraph is kerned text, so "AV" and
        // "To" typed into it get Arial's own adjustments (the embedded subset kept no table: the installed Arial's, whose
        // widths are the subset's), while "fo" keeps the generator's.
        let pdf = ContentEditPdf.make("BT /FA 11 Tf 14 TL 72 700 Td [(The f) -40 (ox jumps over the lazy dog and keeps going on)] TJ T* "
            + "[(while the f) -40 (ox runs along the river bank at night)] TJ ET", fontText: Self.chars)
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first { $0.text.hasPrefix("The fox") })
        #expect(p.blocked == nil)
        let text = "To AVOW the fox " + p.text
        let content = ContentEditPdf.content(try ContentEditor.replaceParagraph(pdf, nil, p, text))
        let to = Self.arialPair("T", "o")
        let av = Self.arialPair("A", "V")
        #expect(to > 0 && av > 0)
        #expect(content.contains("(T) \(Self.n(to)) (o"), "\(content.prefix(400))")
        #expect(content.contains("A) \(Self.n(av)) (V"))
        #expect(content.components(separatedBy: "f) -40 (o").count - 1 == 3)
    }

    @Test func aParagraphSetWithoutKerningGetsNone() throws {
        // No adjustment anywhere in the original: new pairs get none either, so the edited lines look like the rest.
        let pdf = ContentEditPdf.make("BT /FA 11 Tf 14 TL 72 700 Td (The fox jumps over the lazy dog and keeps going on) Tj T* "
            + "(while the fox runs along the river bank at night) Tj ET", fontText: Self.chars)
        let p = try #require(try ContentEditor.read(pdf, nil, 0).paragraphs.first { $0.text.hasPrefix("The fox") })
        let content = ContentEditPdf.content(try ContentEditor.replaceParagraph(pdf, nil, p, "To AVOW " + p.text))
        #expect(!content.contains("(T) \(Self.n(Self.arialPair("T", "o")))"))
        #expect(content.contains("(To AVOW"))
    }

    @Test func theOneRunEditorKernsNewPairsFromTheFontToo() throws {
        let pdf = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td [(Hel) -30 (lo World)] TJ ET", fontText: Self.chars)
        let run = try #require(try ContentEditor.read(pdf, nil, 0).runs.first { $0.text == "Hello World" })
        let content = ContentEditPdf.content(try ContentEditor.replaceText(pdf, nil, run, "Hello To World"))
        #expect(content.contains("T) \(Self.n(Self.arialPair("T", "o"))) (o"), "\(content)")
        #expect(content.contains("(Hel) -30 (lo"))
    }

    @Test func aFontWhoseInstalledNamesakeHasOtherWidthsIsntKernedFromIt() throws {
        // /FA's widths made 10% wider: the installed Arial isn't its design, so its table isn't used.
        let pdf = ContentEditPdf.make("BT /FA 11 Tf 72 700 Td (a) Tj ET", fontText: Self.chars)
        let doc = try PdfEdit.openToRead(pdf, nil)
        let fa = try #require(doc.page(0).dict("Resources")?.dict("Font")?.dict("FA"))
        #expect(FontKerning.of(TextFont(fa)) != nil)
        let widths = try #require(fa.array("Widths"))
        let wider = doc.array(widths.elements.map { doc.real(($0.number ?? 0) * 1.1) })
        let copy = doc.dict(fa.keys.compactMap { k in k == "Widths" ? (k, wider) : fa[k].map { (k, $0) } })
        #expect(FontKerning.of(TextFont(copy)) == nil)
    }
}
