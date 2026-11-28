import Foundation
import Testing
@testable import PdfCore

/// Roadmap 3.1, pdf.js's half of "the copy reads as written" (Windows' `TranslationPdfJsTests`): a translated copy opens in
/// pdf.js (Mozilla's viewer, the one in Firefox and most browser viewers) with each paragraph's new words in order. Opt-in
/// with INKVOLTPDF_PDFJS (needs Node and npm, `pdf/tools/pdfjs-check`); with INKVOLTPDF_CORPUS, the export corpus's first
/// pages too. No model: each text comes back with words of its own around it, its markup kept.
struct TranslationPdfJsTests {
    static let letters = "The quick brown fox jumps over a lazy dog, until the 0123456789 and THE QUICK BROWN FOX JUMPS OVER A LAZY DOG.!"

    static func solid(_ s: String) -> String { String(String.UnicodeScalarView(s.unicodeScalars.filter { !$0.properties.isWhitespace })) }

    static func words(_ s: String) -> String { ParagraphEditTests.words(s) }

    /// The answer's words as a reader should find them: its tags taken out (a reply's tags never reach a page, ours or not).
    static func shown(_ answer: String) -> String { words(TranslationMarkup.plain(answer)) }

    /// Right-to-left copies pdf.js should read with the spaces between their right-to-left words: no stretch in two fonts.
    static let spaced: Set<String> = ["arabic plain", "arabic red", "arabic version", "hebrew plain"]

    /// Right-to-left text as pdf.js reads a line written in stretches (`GlyphOrder.stretches`): without the spaces between
    /// a right-to-left letter and a Latin letter, a figure, or a "-", "+" or "%" MuPDF reads left to right (written on its
    /// own).
    static func glued(_ s: String) -> String {
        let u = Array(s.unicodeScalars)
        func isAny(_ c: Unicode.Scalar, _ classes: [Bidi.Cls]) -> Bool { classes.contains(Bidi.classify(c.value)) }
        let rtl: [Bidi.Cls] = [.R, .AL], ltr: [Bidi.Cls] = [.L, .EN, .ES, .ET]
        var out = String.UnicodeScalarView()
        for i in u.indices {
            if u[i] == " " && i > 0 && i + 1 < u.count {
                let a = u[i - 1], b = u[i + 1]
                if (isAny(a, rtl) && isAny(b, ltr)) || (isAny(a, ltr) && isAny(b, rtl)) { continue }
            }
            out.append(u[i])
        }
        return String(out)
    }

    @Test func translatedCopiesReadTheSameInPdfjs() throws {
        guard let flag = ProcessInfo.processInfo.environment["INKVOLTPDF_PDFJS"], !flag.isEmpty else { return }
        guard let node = ParagraphEditTests.onPath("node"), let npm = ParagraphEditTests.onPath("npm") else {
            print("Skipped: node or npm isn't on the PATH.")
            return
        }
        let tool = ParagraphEditTests.pdfJsTool
        #expect(FileManager.default.fileExists(atPath: tool.appendingPathComponent("index.mjs").path), "\(tool.path)")
        if !FileManager.default.fileExists(atPath: tool.appendingPathComponent("node_modules").path) {
            _ = try ParagraphEditTests.runTool(npm, ["ci", "--no-audit", "--no-fund"], tool)
        }
        let spanish: (String) -> String = { "ñandú \($0) y más" }
        var cases: [(name: String, pdf: [UInt8], page: Int, language: String, answer: (String) -> String)] = [
            ("report", TranslationPdf.report(1), 0, "es", spanish),
            // Bold, a subscript, a red word and an underline, kept as looks.
            ("looks", ContentEditPdf.make(
                "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj /FB 12 Tf (brown) Tj /FA 12 Tf ( fox jumps over d) Tj /FA 8 Tf -2 Ts (model) Tj 0 Ts /FA 12 Tf ( and the ) Tj "
                    + "1 0 0 rg (red) Tj 0 g ( lazy dog.) Tj ET 0 0 0 rg 72 697 60 0.8 re f", fontText: Self.letters, faces: true), 0, "es",
             { _ in "El <b>zorro</b> marrón salta sobre d<sub>model</sub> y el perro <span>rojo</span> perezoso." }),
            ("arabic", ContentEditPdf.make(
                "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj /FB 12 Tf (brown) Tj /FA 12 Tf ( fox is ) Tj 1 0 0 rg (red) Tj 0 g ( and jumps over the lazy dog.) Tj ET",
                fontText: Self.letters, faces: true), 0, "ar", { _ in "الثعلب <b>البني</b> السريع <span>أحمر</span> ويقفز فوق الكلب الكسول." }),
            ("arabic plain", ContentEditPdf.make("BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog and the 2024 dog.) Tj ET",
                                                 fontText: Self.letters), 0, "ar",
             { _ in "الثعلب البني السريع يقفز فوق الكلب الكسول في عام 2024 والكلب (الكسول)." }),
            // A red word is a color, not a font: its line is still written in stretches.
            ("arabic red", ContentEditPdf.make(
                "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox is ) Tj 1 0 0 rg (red) Tj 0 g ( and jumps over the lazy dog.) Tj ET",
                fontText: Self.letters, faces: true), 0, "ar", { _ in "قال ابن-سينا إن الثعلب <span>أحمر</span> ويقفز فوق fox الكلب." }),
            // A version kept whole left to right ("2.0-beta"), two hyphens MuPDF reads left to right, one by one.
            ("arabic version", ContentEditPdf.make("BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog and the 2024 dog.) Tj ET",
                                                   fontText: Self.letters), 0, "ar", { _ in "صدر الإصدار 2.0-beta أمس -- قبل الموعد." }),
            ("hebrew", TranslationPdf.report(1), 0, "he", { _ in "השועל החום המהיר <b>קופץ</b> מעל הכלב העצלן." }),
            ("hebrew plain", TranslationPdf.report(1), 0, "he", { _ in "השועל החום המהיר קופץ מעל הכלב [העצלן] בשנת 2025." }),
            ("japanese", TranslationPdf.report(1), 0, "ja", { "素早い茶色の狐が怠惰な犬を飛び越えた。" + "\(TranslationMarkup.plain($0).utf16.count)" }),
        ]
        var corpus = Set<String>()
        if let dir = ProcessInfo.processInfo.environment["INKVOLTPDF_CORPUS"], !dir.isEmpty,
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for name in names.filter({ $0.lowercased().hasSuffix(".pdf") }).sorted() {
                let pdf = [UInt8](try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name)))
                guard let engine = try? PdfEngine.open(pdf) else { continue }
                let pages = engine.pageCount
                engine.close()
                for page in 0..<min(2, pages) {
                    cases.append(("\(name) p\(page + 1)", pdf, page, "es", spanish))
                    corpus.insert("\(name) p\(page + 1)")
                }
            }
        }

        var failures: [String] = []
        for (name, pdf, page, language, answer) in cases {
            let plan = try Translation.makePlan(pdf, nil, [page])
            var answers = TranslationAnswers()
            for (text, _) in plan.texts { answers.done[text] = answer(text) }
            let result = try Translation.apply(plan, answers, language)
            guard let copy = result.data else {
                print("\(name): nothing written")
                continue
            }
            let got = Self.words(try ParagraphEditTests.pdfJsText(node, copy, page))
            let solid = Self.solid(got)
            let before = Self.words(try ParagraphEditTests.pdfJsText(node, pdf, page))
            var read = 0, missed = 0, own = 0
            for (sent, _) in plan.texts {
                // A paragraph pdf.js doesn't read in order on the original page either (a form's fields beside its label on
                // one line, a drop capital, a word cut by a line-end hyphen) is the page's own order, not the copy's.
                let source = Self.words(plan.marked.contains(sent) ? TranslationMarkup.plain(sent) : sent)
                if ParagraphEditTests.firstMiss(source, before) != nil && !Self.solid(before).contains(Self.solid(source)) {
                    own += 1
                    continue
                }
                let want = Self.shown(answers.done[sent]!)
                // Word by word in order; where only the spaces differ, letter by letter (Japanese has no spaces to read by).
                // Right-to-left text word by word, each stretch's words with their spaces; pdf.js reads a stretch and the
                // number or Latin word beside it together (GlyphOrder.stretches). A line with a stretch in two fonts (a bold
                // word) is written in reading order: its letters in order, without the spaces.
                let rtl = want.utf16.contains { (0x0590...0x08FF).contains($0) }
                let miss: String?
                if rtl && Self.spaced.contains(name) {
                    miss = ParagraphEditTests.firstMiss(Self.glued(want), Self.glued(got)) // a line may end where pdf.js glues
                } else if solid.contains(Self.solid(want)) {
                    miss = nil
                } else {
                    miss = want.contains(" ") && !rtl ? ParagraphEditTests.firstMiss(want, got) : "“\(want)” not read whole"
                }
                if let miss {
                    missed += 1
                    print("  \(name): “\(want.prefix(80))”: \(miss)")
                } else {
                    read += 1
                }
            }
            print("\(name): \(plan.texts.count) texts, \(result.report.translated) written; pdf.js reads \(read) in order"
                + (missed > 0 ? ", \(missed) not" : "") + (own > 0 ? ", \(own) not in the original either" : ""))
            // The test's own pages read whole; a real page may have a paragraph or so whose new lines land among a form row's
            // other fields, read in its content's order.
            if missed > (corpus.contains(name) ? max(1, (read + missed) / 50) : 0) {
                failures.append("\(name): pdf.js doesn't read \(missed) of \(read + missed) texts in order")
            }
        }
        for f in failures { print("FAIL " + f) }
        #expect(failures.isEmpty)
    }
}
