import CoreGraphics
import Foundation
import PDFKit
import PrintCore
import Testing
@testable import PrintMac

/// PrintCore's text layer (`PdfWriter`, `OcrFont`) read back by PDFKit, the engine Preview searches with (the Windows tests
/// of the same names read it with MuPDF and pdf.js): every planted word in Greek, Cyrillic, Arabic, Hebrew, Japanese,
/// Chinese, Korean, Devanagari, Thai and beyond the first plane is found, phrases across words too, and the layer draws
/// nothing. The words are Windows' list, as is the page: a 40 × 56 px JPEG at 4 dpi (720 × 1008 pt).
struct OcrLayerSearchTests {
    static let dpi = 4

    /// Each planted word with what to search for it (what a person would type): Windows' `OcrLayerSearchTests.Planted`.
    static let planted: [(script: String, word: String, search: String)] = [
        ("Greek", "Καλημέρα", "Καλημέρα"),
        ("Greek polytonic", "Ἀθῆναι", "Ἀθῆναι"),
        ("Cyrillic", "Привет", "Привет"),
        ("Cyrillic, decomposed by the recognizer", "Чайка", "Чайка"),
        ("Serbian", "Љубљана", "Љубљана"),
        ("Arabic", "مرحبا", "مرحبا"),
        ("Arabic with harakat", "السَّلام", "السَّلام"),
        ("Arabic with a number", "عام2026", "عام"),
        ("Arabic in brackets", "(كلمة)", "كلمة"),
        ("Hebrew", "שלום", "שלום"),
        ("Hebrew with points", "שָׁלוֹם", "שָׁלוֹם"),
        ("Japanese", "東京都庁", "東京都庁"),
        ("Japanese kana", "カタカナとひらがな", "カタカナ"),
        ("Chinese", "中华人民共和国", "人民"),
        ("Korean", "안녕하세요", "안녕"),
        ("A character beyond the first plane", "𠮷野家", "𠮷野家"),
        ("Devanagari", "नमस्ते", "नमस्ते"),
        ("Thai", "สวัสดี", "สวัสดี"),
        ("Latin", "Résumé", "Résumé"),
    ]

    static func word(_ text: String, _ x: Double, _ line: Double, width: Double = 16) -> PdfWriter.Word {
        PdfWriter.Word(text, x: x, y: 1 + line * 1.5, width: width, height: 1)
    }

    /// The test page: white, 40 × 56 px.
    static let jpeg: [UInt8] = {
        guard let context = CGContext(data: nil, width: 40, height: 56, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return [] }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 56))
        return context.makeImage().flatMap { try? ScanImaging.jpeg($0) } ?? []
    }()

    static func pdf(_ words: [PdfWriter.Word]) throws -> PDFDocument {
        let bytes = try PdfWriter.write([PdfWriter.Page(jpeg, dpi: dpi, words: words)])
        return try #require(PDFDocument(data: Data(bytes)))
    }

    static func plantedPdf() throws -> PDFDocument {
        try pdf(planted.enumerated().map { i, p in word(p.word, 4, Double(i)) })
    }

    /// Found as Preview's Find looks: PDFKit's `findString`, in the words as typed (composed).
    static func finds(_ document: PDFDocument, _ text: String) -> Bool {
        !document.findString(text.precomposedStringWithCanonicalMapping, withOptions: []).isEmpty
    }

    @Test func pdfKitFindsEveryPlantedWord() throws {
        let document = try Self.plantedPdf()
        let missing = Self.planted.filter { !Self.finds(document, $0.search) }.map { "\($0.script): \($0.search)" }
        #expect(missing.isEmpty, "Not found: \(missing.joined(separator: "; "))\nPDFKit read:\n\(document.string ?? "")")
    }

    @Test func pdfKitFindsPhrasesAcrossWords() throws {
        let document = try Self.pdf([
            Self.word("first", 2, 0, width: 6), Self.word("second", 9, 0, width: 6), Self.word("third", 16, 0, width: 6),
            Self.word("один", 2, 1, width: 6), Self.word("два", 9, 1, width: 6), Self.word("три", 16, 1, width: 6),
            // A right-to-left line: the first word in reading order lies furthest right.
            Self.word("שלום", 16, 2, width: 6), Self.word("עולם", 9, 2, width: 6),
            Self.word("مرحبا", 16, 3, width: 6), Self.word("بالعالم", 9, 3, width: 6),
            // Japanese in pieces with small gaps: found as one run.
            Self.word("東京", 2, 4, width: 4), Self.word("都庁", 6.3, 4, width: 4), Self.word("です", 10.6, 4, width: 4),
        ])
        // As Windows' pdf.js test: PDFKit finds each word of a right-to-left line but not a phrase across two (it reads the
        // line in visual order, "עולםשלום", the space dropped; a known limit, print/ROADMAP.md 2.3). Left-to-right phrases
        // and CJK runs are found whole.
        let phrases = ["first second third", "один два три", "東京都庁です", "שלום", "עולם", "مرحبا", "بالعالم"]
        let missing = phrases.filter { !Self.finds(document, $0) }
        #expect(missing.isEmpty, "Not found: \(missing.joined(separator: "; "))\nPDFKit read:\n\(document.string ?? "")")
    }

    @Test func theLayerDrawsNothing() throws {
        let with = try #require(Self.plantedPdf().page(at: 0)), without = try #require(Self.pdf([]).page(at: 0))
        #expect(Self.pixels(with) == Self.pixels(without))
    }

    @Test func aWordIsSelectedOverItsOwnBox() throws {
        let document = try Self.pdf([PdfWriter.Word("Привет", x: 10, y: 20, width: 12, height: 1)])
        let hits = document.findString("Привет", withOptions: [])
        try #require(hits.count == 1, "PDFKit read: \(document.string ?? "")")
        let page = try #require(document.page(at: 0))
        let box = hits[0].bounds(for: page)
        // 18 pt a pixel at 4 dpi: from x 180 to 396.
        #expect(abs(box.minX - 180) < 2 && abs(box.maxX - 396) < 4, "\(box)")
    }

    /// The page drawn at a quarter of its size, as bytes.
    static func pixels(_ page: PDFPage) -> [UInt8] {
        let box = page.bounds(for: .mediaBox)
        let (w, h) = (Int(box.width / 4), Int(box.height / 4))
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return }
            context.scaleBy(x: 0.25, y: 0.25)
            page.draw(with: .mediaBox, to: context)
        }
        return bytes
    }
}
