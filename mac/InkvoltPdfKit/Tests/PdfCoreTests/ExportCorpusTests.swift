import CryptoKit
import Foundation
import Testing
@testable import PdfCore

/// Not a port: pdf/tools/export-corpus on the Mac. The Windows tool exports public PDFs to Word and has Word count the
/// pages (baseline.json); the Mac has no Word, so this compares the Mac's exports with the Windows exports of the same
/// PDFs instead. Put the PDFs the Windows tool downloaded (its `.cache\<name>.pdf`) in /tmp/inkvolt-export-corpus and its
/// exports (`.cache\out\<name>.docx` and `.txt`) in /tmp/inkvolt-export-corpus/windows; skipped when the folder isn't
/// there. corpus.json and baseline.json are read in place (names, SHA-256, page counts). For each document: the PDF is
/// the one baselined (else "source changed", not compared), its page count is the baseline's, the Word file is a sound
/// package `textutil` reads, and the text export, and the Word file's paragraphs, tables and sections, are compared with
/// the Windows ones. PowerPoint and HTML too (E15), with the PDF as their source: the presentation a sound package with a
/// slide per page and no active content in the web page; with Windows' `.pptx` and `.html` beside its others, their slides,
/// text boxes, shapes, pictures, tables and text, and the page's blocks of text, are compared. The Mac's exports are left in
/// /tmp/inkvolt-export-corpus/mac to open, diff or run Windows' `ExportCorpus pptx` and `html` checks on. Prints one
/// "CORPUS <name> ..." line per document.
struct ExportCorpusTests {
    static let folder = "/tmp/inkvolt-export-corpus"
    static let tool = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../../pdf/tools/export-corpus")
        .standardizedFileURL

    /// The share of lines of `a` (with their counts) that `b` has too, over the larger of the two counts.
    private func sameLines(_ a: [String], _ b: [String]) -> Double {
        var bag: [String: Int] = [:]
        for l in b { bag[l, default: 0] += 1 }
        var common = 0
        for l in a where (bag[l] ?? 0) > 0 {
            bag[l]! -= 1
            common += 1
        }
        let n = max(a.count, b.count)
        return n == 0 ? 1 : Double(common) / Double(n)
    }

    /// What a Word file's body holds: its paragraphs' texts (in order), tables and sections.
    private func outline(_ docx: [UInt8]) throws -> (paragraphs: [String], tables: Int, sections: Int, rows: Int) {
        let doc = try WordDoc(docx)
        let tables = OpenXmlPackage.elements(doc.body, "w:tbl")
        return (OpenXmlPackage.elements(doc.body, "w:p").map(OpenXmlPackage.text), tables.count,
                OpenXmlPackage.elements(doc.document, "w:sectPr").count,
                tables.reduce(0) { $0 + OpenXmlPackage.children($1, "w:tr").count })
    }

    /// What a presentation holds: slides, text boxes, simple shapes, pictures, tables, and each text box's text in order.
    private func deck(_ pptx: [UInt8]) throws -> (slides: Int, textBoxes: Int, shapes: Int, pictures: Int, tables: Int, lines: [String]) {
        let d = try ExportPptxTests.Deck(pptx)
        let slides = d.slides
        let boxes = slides.flatMap(ExportPptxTests.textBoxes)
        let shapes = slides.reduce(0) { $0 + ExportPptxTests.shapes($1).count + OpenXmlPackage.elements($1, "p:cxnSp").count }
        return (slides.count, boxes.count, shapes, slides.reduce(0) { $0 + OpenXmlPackage.elements($1, "p:pic").count },
                slides.reduce(0) { $0 + OpenXmlPackage.elements($1, "a:tbl").count }, boxes.map(ExportPptxTests.text))
    }

    /// A web page's blocks of text in order: headings, paragraphs, list items and table cells.
    private func blocks(_ html: String) throws -> [String] {
        let names: Set<String> = ["h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "td", "th"]
        return ExportHtmlTests.descendants(try ExportHtmlTests.dom(html)).filter { names.contains($0.name ?? "") }.map(ExportHtmlTests.textOf)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: folder))) func corpusExportsAsOnWindows() throws {
        let corpus = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.tool.appendingPathComponent("corpus.json"))) as! [[String: Any]]
        let baseline = try JSONSerialization.jsonObject(with: Data(contentsOf: Self.tool.appendingPathComponent("baseline.json"))) as! [String: [String: Any]]
        var failures = 0
        for entry in corpus {
            let name = entry["name"] as! String
            let pdfPath = "\(Self.folder)/\(name).pdf"
            guard let pdf = FileManager.default.contents(atPath: pdfPath).map(Array.init) else {
                print("CORPUS \(name) SKIP (no PDF)")
                continue
            }
            let sha = SHA256.hash(data: pdf).map { String(format: "%02x", $0) }.joined()
            guard let base = baseline[name], base["sha256"] as? String == sha else {
                print("CORPUS \(name) source changed: not compared")
                continue
            }
            let engine = try PdfEngine.open(pdf)
            defer { engine.close() }
            let options = ExportOptions(title: name)
            let started = Date()
            let word = MemorySink()
            let report = try DocumentExport.export(engine, .word, to: word, options: options)
            let seconds = Date().timeIntervalSince(started)
            let text = MemorySink()
            _ = try DocumentExport.export(engine, .text, to: text, options: options)
            // The exports themselves, to open or diff, in mac/ beside windows/.
            let out = "\(Self.folder)/mac"
            try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
            try Data(word.bytes).write(to: URL(fileURLWithPath: "\(out)/\(name).docx"))
            try Data(text.bytes).write(to: URL(fileURLWithPath: "\(out)/\(name).txt"))
            let problems = try OpenXmlPackage(word.bytes).validate()
            let readable = try OpenXmlPackage.textutil(word.bytes) != nil
            var line = "CORPUS \(name) pages \(engine.pageCount)/\(base["pdfPages"] as? Int ?? -1) docx \(problems.isEmpty ? "valid" : "INVALID")"
                + " textutil \(readable ? "ok" : "FAIL") \(String(format: "%.1f", seconds)) s"
            var ok = report.saved && problems.isEmpty && readable && engine.pageCount == base["pdfPages"] as? Int

            let windowsText = FileManager.default.contents(atPath: "\(Self.folder)/windows/\(name).txt").map(Array.init)
            let windowsWord = FileManager.default.contents(atPath: "\(Self.folder)/windows/\(name).docx").map(Array.init)
            if let windowsText, let windowsWord {
                let mine = String(decoding: text.bytes, as: UTF8.self).components(separatedBy: "\r\n")
                let theirs = String(decoding: windowsText, as: UTF8.self).components(separatedBy: "\r\n")
                let a = try outline(word.bytes), b = try outline(windowsWord)
                let textSame = text.bytes == windowsText
                line += " | txt \(textSame ? "identical" : String(format: "%.3f of lines alike", sameLines(mine, theirs)))"
                line += " | docx paragraphs \(a.paragraphs.count)/\(b.paragraphs.count) (\(String(format: "%.3f", sameLines(a.paragraphs, b.paragraphs))) alike)"
                    + " tables \(a.tables)/\(b.tables) rows \(a.rows)/\(b.rows) sections \(a.sections)/\(b.sections)"
                ok = ok && a.sections == b.sections
            } else {
                line += " | no Windows export to compare"
            }

            // PowerPoint and HTML (E15), with the PDF as their source, as the Windows tool exports them.
            let withSource = ExportOptions(title: name, source: pdf)
            let pptx = MemorySink(), html = MemorySink()
            _ = try DocumentExport.export(engine, .powerPoint, to: pptx, options: withSource)
            _ = try DocumentExport.export(engine, .html, to: html, options: withSource)
            try Data(pptx.bytes).write(to: URL(fileURLWithPath: "\(out)/\(name).pptx"))
            try Data(html.bytes).write(to: URL(fileURLWithPath: "\(out)/\(name).html"))
            let deckProblems = try OpenXmlPackage(pptx.bytes).validate()
            let page = String(decoding: html.bytes, as: UTF8.self)
            let active = try NSRegularExpression(pattern: #"<(script|iframe|object|embed|link|base|form|svg|math|video|audio|source|a)|\son\w+\s*=|\s(href|srcset)\s*=|\ssrc="(?!data:image/(png|jpeg);base64,)"#,
                                                 options: .caseInsensitive).numberOfMatches(in: page, range: NSRange(page.startIndex..., in: page))
            let mineDeck = try deck(pptx.bytes), mineBlocks = try blocks(page)
            line += " | pptx \(deckProblems.isEmpty ? "valid" : "INVALID") slides \(mineDeck.slides) | html active \(active) blocks \(mineBlocks.count)"
            ok = ok && deckProblems.isEmpty && active == 0 && mineDeck.slides == engine.pageCount
            let windowsDeck = FileManager.default.contents(atPath: "\(Self.folder)/windows/\(name).pptx").map(Array.init)
            let windowsPage = FileManager.default.contents(atPath: "\(Self.folder)/windows/\(name).html").map { String(decoding: $0, as: UTF8.self) }
            if let windowsDeck, let windowsPage {
                let theirDeck = try deck(windowsDeck), theirBlocks = try blocks(windowsPage)
                line += " | vs Windows: slides \(mineDeck.slides)/\(theirDeck.slides) text boxes \(mineDeck.textBoxes)/\(theirDeck.textBoxes)"
                    + " shapes \(mineDeck.shapes)/\(theirDeck.shapes) pictures \(mineDeck.pictures)/\(theirDeck.pictures) tables \(mineDeck.tables)/\(theirDeck.tables)"
                    + " slide text \(String(format: "%.3f", sameLines(mineDeck.lines, theirDeck.lines))) alike"
                    + " | html blocks \(mineBlocks.count)/\(theirBlocks.count) (\(String(format: "%.3f", sameLines(mineBlocks, theirBlocks))) alike)"
                ok = ok && mineDeck.slides == theirDeck.slides
            }
            if !ok { failures += 1 }
            print(line + " \(ok ? "PASS" : "FAIL")")
        }
        #expect(failures == 0)
    }
}
