import Foundation
import Testing
@testable import PdfCore

/// Roadmap 2.1's test, the pdf.js half (ported from ParagraphEditTests.PdfJs.cs): an edited page opens in pdf.js with
/// the same text. Opt-in with INKVOLTPDF_PDFJS set; needs Node and npm on the PATH (else it skips itself) and the
/// repository's `pdf/tools/pdfjs-check` (its README), found up from this file. With INKVOLTPDF_CORPUS set, the export
/// corpus's files are checked too.
extension ParagraphEditTests {
    /// pdf/tools/pdfjs-check, up from this source file (mac/InkvoltPdfKit/Tests/PdfCoreTests).
    static var pdfJsTool: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("pdf/tools/pdfjs-check")
    }

    /// A program on the PATH ("node", "npm"), or nil.
    static func onPath(_ name: String) -> String? {
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    static func runTool(_ exe: String, _ args: [String], _ workDir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = workDir
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw ContentEditError("\(exe) \(args.joined(separator: " ")): exit \(p.terminationStatus)\n\(String(decoding: errors, as: UTF8.self))")
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The text pdf.js reads from one page of a PDF (0-based), items in the order it reads them.
    static func pdfJsText(_ node: String, _ pdf: [UInt8], _ page: Int) throws -> String {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-pdfjs-\(UUID().uuidString).pdf")
        try Data(pdf).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let json = try runTool(node, ["index.mjs", file.path, "\(page + 1)", "\(page + 1)"], pdfJsTool)
        let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let pages = root?["pages"] as? [[String: Any]]
        return pages?.first?["text"] as? String ?? ""
    }

    /// Nil when every word of `expected` appears in `got`, in order (pdf.js may space the rest differently); else the
    /// first word missing and what pdf.js read after the last one found.
    static func firstMiss(_ expected: String, _ got: String) -> String? {
        let words = got.split(separator: " ").map(String.init)
        var at = 0
        for w in expected.split(separator: " ").map(String.init) {
            let from = at
            while at < words.count && words[at] != w { at += 1 }
            if at == words.count { return "“\(w)” missing; pdf.js reads on: \(words.dropFirst(from).prefix(12).joined(separator: " "))" }
            at += 1
        }
        return nil
    }

    @Test func editedParagraphsReadTheSameInPdfJs() throws {
        guard let flag = ProcessInfo.processInfo.environment["INKVOLTPDF_PDFJS"], !flag.isEmpty else { return }
        guard let node = Self.onPath("node"), let npm = Self.onPath("npm") else {
            print("Skipped: node or npm isn't on the PATH.")
            return
        }
        #expect(FileManager.default.fileExists(atPath: Self.pdfJsTool.appendingPathComponent("index.mjs").path), "\(Self.pdfJsTool.path)")
        if !FileManager.default.fileExists(atPath: Self.pdfJsTool.appendingPathComponent("node_modules").path) {
            _ = try Self.runTool(npm, ["ci", "--no-audit", "--no-fund"], Self.pdfJsTool)
        }

        // The test's own pages: each alignment, a paragraph inside a form XObject, turned text, stand-in characters, and a
        // one-run edit.
        var cases: [(name: String, pdf: [UInt8], page: Int, added: String)] = []
        for align in [ParagraphAlign.left, .right, .center, .justified] { cases.append(("sample \(align)", Self.page(align, gap: 120).pdf, 0, Self.twenty)) }
        cases.append(("sample form", ContentEditPdf.make("q /Fm1 Do Q", form: Self.formBody(), fontText: Self.chars), 0, Self.twenty))
        cases.append(("sample turned 90°", Self.turnedPdf(90, 150, 250), 0, Self.twenty))
        cases.append(("sample turned 30°", Self.turnedPdf(30, 150, 300), 0, Self.twenty))
        cases.append(("sample stand-ins", Self.page(.left, gap: 120).pdf, 0, "mail me @ home #1 for 5 " + Self.twenty))
        cases.append(("sample looks", Self.page(.left, gap: 120).pdf, 0, "")) // with Looks(), below
        if let dir = ProcessInfo.processInfo.environment["INKVOLTPDF_CORPUS"], !dir.isEmpty,
           let names = try? FileManager.default.contentsOfDirectory(atPath: dir) {
            for name in names.filter({ $0.lowercased().hasSuffix(".pdf") }).sorted() {
                let pdf = [UInt8](try Data(contentsOf: URL(fileURLWithPath: dir).appendingPathComponent(name)))
                guard let engine = try? PdfEngine.open(pdf) else { continue }
                let pages = engine.pageCount
                engine.close()
                for page in 0..<min(3, pages) { cases.append(("\(name) p\(page + 1)", pdf, page, "")) }
            }
        }

        var failures: [String] = []
        for (name, pdf, page, addedWords) in cases {
            guard let content = try? ContentEditor.read(pdf, nil, page) else {
                print("\(name): unreadable")
                continue
            }
            guard let p = content.paragraphs.filter({ $0.blocked == nil && $0.lines.count > 1 }).max(by: { $0.lines.count < $1.lines.count }) else {
                print("\(name): no editable paragraph of several lines")
                continue
            }
            let words = p.text.split(separator: " ").map(String.init)
            let looks = name == "sample looks"
            // As many of the 20 words as fit without running into what follows (a line that lands beside the next block, on
            // its baseline, would read into it in any viewer; the overlap warning is the corpus test's job).
            var added = !addedWords.isEmpty ? addedWords : (0..<20).map { words[$0 % words.count] }.joined(separator: " ")
            var text = p.text + " " + added
            let spans = looks ? Self.looks(text) : nil
            var check = p.check(text, spans: spans)
            for count in [10, 5, 2, 1] {
                if check.overlaps == nil || !addedWords.isEmpty || looks { break }
                added = (0..<count).map { words[$0 % words.count] }.joined(separator: " ")
                text = p.text + " " + added
                check = p.check(text)
            }
            if !check.missing.isEmpty {
                print("\(name): refused, no font has \(check.missing.prefix(5).joined(separator: " "))")
                continue
            }
            if check.overlaps != nil {
                print("\(name): no room under the paragraph for even one more word")
                continue
            }
            let edited: [UInt8]
            do {
                edited = try ContentEditor.replaceParagraph(pdf, nil, p, text, spans: spans)
            } catch {
                failures.append("\(name): \(error)")
                continue
            }
            let got = Self.words(try Self.pdfJsText(node, edited, page))
            let miss = Self.firstMiss(Self.words(text), got) ?? (got.contains(Self.words(added)) ? nil : "the added words aren't read together")
            let standIns = check.borrowed.isEmpty ? "" : "stand-ins \(check.standIns.joined(separator: " "))"
            print("\(name): \(p.lines.count) lines \(p.align) → \(check.lineCount); pdf.js \(miss.map { "DIFFERS: " + $0 } ?? "reads it in order"); \(standIns)")
            if let miss { failures.append("\(name): pdf.js doesn't read the edited paragraph in order (\(miss))") }
        }
        // The one-run editor with a stand-in character.
        let one = ContentEditPdf.make("BT /FA 20 Tf 72 692 Td (Hello World) Tj ET BT /FA 9 Tf 72 600 Td (draft) Tj ET")
        let r = try Self.run(try ContentEditor.read(one, nil, 0), "Hello World")
        let edited = try ContentEditor.replaceText(one, nil, r, "Hello Zebra")
        let got = Self.words(try Self.pdfJsText(node, edited, 0))
        print("one run with stand-ins: pdf.js reads \"\(got)\"")
        if !got.contains("Hello Zebra") { failures.append("one run with stand-ins: pdf.js doesn't read \"Hello Zebra\"") }
        for f in failures { print("FAIL " + f) }
        #expect(failures.isEmpty)
    }
}
