import Foundation

/// What `DocumentExport` makes: a Word document, an Excel workbook of the tables found, or plain text.
public enum ExportFormat: Sendable, CaseIterable { case word, excel, text }

public enum ExportStage: Sendable { case reading, recognizing, writing }

/// Where an export is (`ExportOptions.progress`): the page being read or recognized (0-based; -1 while writing), how
/// many pages were read before it, of how many.
public struct ExportProgress: Equatable, Sendable {
    public var stage: ExportStage
    public var page: Int
    public var index: Int
    public var count: Int

    public init(_ stage: ExportStage, _ page: Int, _ index: Int, _ count: Int) {
        self.stage = stage
        self.page = page
        self.index = index
        self.count = count
    }

    public var fraction: Double { count == 0 ? 1 : Double(index) / Double(count) }
}

/// How to export (see `DocumentExport.export`).
public struct ExportOptions: Sendable {
    /// The pages to export (0-based, in this order); nil exports every page.
    public var pages: [Int]?
    /// The document's title in the Word and Excel file.
    public var title: String?
    /// Text recognition for pages without text (scans); nil reads only the text the pages have. The app passes
    /// `PageOcr.recognizer(VisionRecognizer())`.
    public var recognize: Recognizer?
    /// Called as each page is read or recognized, and once before the file is written (on the exporting thread).
    public var progress: (@Sendable (ExportProgress) -> Void)?

    public init(pages: [Int]? = nil, title: String? = nil, recognize: Recognizer? = nil, progress: (@Sendable (ExportProgress) -> Void)? = nil) {
        self.pages = pages
        self.title = title
        self.recognize = recognize
        self.progress = progress
    }
}

/// A page an export couldn't read, or couldn't recognize (0-based), and why.
public struct ExportProblem: Equatable, Sendable {
    public var page: Int
    public var message: String

    public init(_ page: Int, _ message: String) {
        self.page = page
        self.message = message
    }
}

/// What an export did. `saved`: false when nothing was extracted, so there is nothing to save: no text at all (and,
/// for Word, no pictures either), or, for Excel, no tables. `recognized`: pages whose text came from the recognizer;
/// `noText`: pages without text (after recognition), `noTextWithPictures` those with pictures (Word keeps them);
/// `tables`: Excel's tables (one sheet each); `unreadable`: damaged pages, exported empty; `recognitionFailed`: pages
/// exported without text because recognition failed.
public struct ExportReport: Equatable, Sendable {
    public var saved: Bool
    public var pages: Int
    public var recognized: Int
    public var noText: Int
    public var noTextWithPictures: Int
    public var tables: Int
    public var unreadable: [ExportProblem]
    public var recognitionFailed: [ExportProblem]
}

/// Export to Word, Excel and plain text (pdf/GLOSSARY.md "Document export"). `export` (to a sink) and `exportToFile`
/// read the pages (a damaged page exports empty; a page without text is recognized when the caller gives a recognizer),
/// lay out the document and write the format, or report that there was nothing to save. Pages come in one at a time;
/// each format lays the whole document out once all pages are in (body size and heading levels are document-wide).
public enum DocumentExport {
    /// The file extension of `format` (".docx", ".xlsx", ".txt").
    public static func fileExtension(_ format: ExportFormat) -> String {
        switch format {
        case .word: ".docx"
        case .excel: ".xlsx"
        case .text: ".txt"
        }
    }

    /// Exports the pages of `engine` to `output`. When the report says nothing was saved, discard the output: Excel and
    /// text wrote nothing, Word may have written part of a file. `exportToFile` handles that.
    /// - Throws: `CancellationError` when `cancel` fires; a write error of `output`.
    public static func export(_ engine: PdfEngine, _ format: ExportFormat, to output: ByteSink, options: ExportOptions = ExportOptions(),
                              cancel: CancelToken? = nil) throws -> ExportReport {
        let pages = options.pages ?? Array(0..<engine.pageCount)
        let run = Run(engine, pages, images: format == .word, options, cancel)
        var tables = 0
        let saved: Bool
        switch format {
        case .word:
            try writeDocx(output, { try run.next()?.page }, options.title)
            saved = run.noText < pages.count || run.noTextWithPictures > 0
        case .excel:
            let found = try self.tables(run.all())
            tables = found.count
            saved = !found.isEmpty
            if saved { try XlsxWriter.write(output, found, options.title) }
        case .text:
            let text = plainText(try run.all().map(\.page))
            saved = run.noText < pages.count
            if saved { try output.write([0xEF, 0xBB, 0xBF] + Array(text.utf8)) }
        }
        return ExportReport(saved: saved, pages: pages.count, recognized: run.recognized, noText: run.noText,
                            noTextWithPictures: run.noTextWithPictures, tables: tables, unreadable: run.unreadable,
                            recognitionFailed: run.recognitionFailed)
    }

    /// `export` to `path`, through a temporary file in the same folder that is swapped in at the end: a failed or
    /// cancelled export, or one with nothing to save, leaves the folder as it was.
    /// - Throws: `CancellationError` when `cancel` fires; a file error when the file can't be written.
    public static func exportToFile(_ engine: PdfEngine, _ format: ExportFormat, _ path: String, options: ExportOptions = ExportOptions(),
                                    cancel: CancelToken? = nil) throws -> ExportReport {
        let full = URL(fileURLWithPath: path).standardizedFileURL
        let tmp = full.deletingLastPathComponent().appendingPathComponent("~inkvoltpdf-\(UUID().uuidString.replacingOccurrences(of: "-", with: "")).tmp")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil, attributes: nil) else {
            throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: tmp.path])
        }
        do {
            let handle = try FileHandle(forWritingTo: tmp)
            let report: ExportReport
            do {
                report = try export(engine, format, to: FileSink(handle), options: options, cancel: cancel)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try cancel.check()
            if report.saved {
                if FileManager.default.fileExists(atPath: full.path) {
                    _ = try FileManager.default.replaceItemAt(full, withItemAt: tmp)
                } else {
                    try FileManager.default.moveItem(at: tmp, to: full)
                }
            } else {
                try FileManager.default.removeItem(at: tmp)
            }
            return report
        } catch {
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }

    /// Reads the pages one at a time (Word stores each page's pictures as it arrives), counting as it goes.
    private final class Run {
        let engine: PdfEngine
        let pages: [Int]
        let images: Bool
        let options: ExportOptions
        let cancel: CancelToken?
        var recognized = 0, noText = 0, noTextWithPictures = 0
        var unreadable: [ExportProblem] = [], recognitionFailed: [ExportProblem] = []
        private var i = 0

        init(_ engine: PdfEngine, _ pages: [Int], images: Bool, _ options: ExportOptions, _ cancel: CancelToken?) {
            self.engine = engine
            self.pages = pages
            self.images = images
            self.options = options
            self.cancel = cancel
        }

        /// The next page (its number 1-based), or nil after the last (and the writing stage reported).
        func next() throws -> (number: Int, page: ExportPage)? {
            guard i < pages.count else {
                if i == pages.count {
                    i += 1
                    options.progress?(ExportProgress(.writing, -1, pages.count, pages.count))
                }
                return nil
            }
            try cancel.check()
            let p = pages[i]
            options.progress?(ExportProgress(.reading, p, i, pages.count))
            var page: ExportPage
            var readable = true
            do {
                page = try engine.exportPage(p, images: images, cancel: cancel)
            } catch let error as PdfEngineError {
                // A damaged page: export the rest (it stays empty, and the report says so).
                unreadable.append(ExportProblem(p, error.message))
                readable = false
                let g = engine.page(p)
                page = ExportPage(g.width, g.height, [], [], [])
            }
            if readable && !page.hasText, let recognize = options.recognize {
                options.progress?(ExportProgress(.recognizing, p, i, pages.count))
                do {
                    let words = try recognize(engine, p, cancel)
                    if !words.isEmpty {
                        page.lines = ExportPage.linesFromOcr(words)
                        page.fromOcr = true
                        recognized += 1
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // Rendering or the recognizer failed on this page: go on without its text.
                    recognitionFailed.append(ExportProblem(p, Self.message(error)))
                }
            }
            if !page.hasText {
                noText += 1
                if !page.images.isEmpty { noTextWithPictures += 1 }
            }
            i += 1
            return (p + 1, page)
        }

        func all() throws -> [(number: Int, page: ExportPage)] {
            var list: [(number: Int, page: ExportPage)] = []
            while let x = try next() { list.append(x) }
            return list
        }

        /// An error's words (.NET's `Exception.Message`).
        static func message(_ error: Error) -> String {
            if let e = error as? PdfEngineError { return e.message }
            if let e = error as? LocalizedError, let d = e.errorDescription { return d }
            return String(describing: error)
        }
    }

    /// Writes a .docx. Pictures are stored as each page arrives; only the text is kept until the end.
    static func writeDocx(_ output: ByteSink, _ next: () throws -> ExportPage?, _ title: String?) throws {
        let writer = DocxWriter(output)
        var kept: [ExportPage] = []
        while var page = try next() {
            if !page.images.isEmpty {
                let p = page
                page.images = try p.images.filter { DocLayout.keeps(p, $0) }.map { i in
                    ExportImage([], i.ext, i.pixelWidth, i.pixelHeight, i.box, ref: try writer.addImage(i.data, i.ext))
                }
            }
            kept.append(page)
        }
        try writer.finish(DocLayout.analyzeDocument(kept), title)
    }

    /// Writes a .docx of pages already read (the tests' and the corpus check's way in).
    static func writeDocx(_ output: ByteSink, _ pages: [ExportPage], _ title: String?) throws {
        var it = pages.makeIterator()
        try writeDocx(output, { it.next() }, title)
    }

    /// The tables found on the pages, named after their page ("Page 3", "Page 3 (2)"); page numbers are 1-based.
    static func tables(_ pages: [(number: Int, page: ExportPage)]) -> [(name: String, table: DocTable)] {
        let list = pages.map { ($0.number, $0.page.withoutImages()) }
        let laid = DocLayout.analyze(list.map(\.1))
        var tables: [(name: String, table: DocTable)] = []
        for (i, page) in laid.enumerated() {
            for (k, t) in page.tables.enumerated() {
                tables.append((k == 0 ? "Page \(list[i].0)" : "Page \(list[i].0) (\(k + 1))", t))
            }
        }
        return tables
    }

    /// Plain text in reading order: one paragraph per line with a blank line between paragraphs, table rows as
    /// tab-separated cells, list items with a bullet ("• ").
    static func plainText(_ pages: [ExportPage]) -> String {
        let laid = DocLayout.analyze(pages.map { $0.withoutImages() })
        var sb = ""
        func oneLine(_ s: String) -> String {
            s.replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        }
        for page in laid {
            for block in page.blocks {
                switch block {
                case .paragraph(let p):
                    if p.list == .bullet { sb += "\u{2022} " }
                    sb += oneLine(p.text) + "\r\n\r\n"
                case .table(let t):
                    for row in t.rows {
                        var cells: [String] = []
                        for cell in row {
                            cells.append(oneLine(cell.text))
                            for _ in stride(from: 1, to: cell.colSpan, by: 1) { cells.append("") }
                        }
                        sb += cells.joined(separator: "\t").trimmingEnd { $0 == "\t" } + "\r\n"
                    }
                    sb += "\r\n"
                case .picture:
                    break
                }
            }
        }
        return sb.trimmedEndWS + "\r\n"
    }
}
