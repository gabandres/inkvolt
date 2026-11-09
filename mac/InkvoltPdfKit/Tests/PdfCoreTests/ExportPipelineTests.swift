import Foundation
import Testing
@testable import PdfCore

/// Ported from ExportPipelineTests.cs, every test: the export module through its interface (`DocumentExport.export`,
/// `exportToFile`): which pages are read, recognition of pages without text, and when nothing is saved. Adapted: the
/// blank PDFs are written by hand (`ExportTestPdf.blank`), output goes to a `MemorySink` where Windows uses a
/// MemoryStream, and the recognizer's error is a Swift error with that message.
struct ExportPipelineTests {
    private struct NoOcr: LocalizedError {
        var errorDescription: String? { "no OCR today" }
    }

    /// A fresh temporary folder, removed after `body`.
    private func inFolder(_ body: (String) throws -> Void) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-export-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try body(dir)
    }

    private func files(_ dir: String) throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: dir).sorted() }

    @Test(arguments: ExportFormat.allCases) func exportsToAFileWithNothingLeftBehind(_ format: ExportFormat) throws {
        try inFolder { dir in
            let engine = try PdfEngine.open(ExportTestPdf.make())
            defer { engine.close() }
            let name = "out" + DocumentExport.fileExtension(format)
            let path = dir + "/" + name
            let report = try DocumentExport.exportToFile(engine, format, path, options: ExportOptions(title: "Sample"))
            #expect(report.saved)
            #expect(report.pages == engine.pageCount)
            #expect(report.tables == (format == .excel ? 1 : 0))
            #expect(try files(dir) == [name]) // the temporary file is gone
            if format == .text {
                let bytes = Array(try Data(contentsOf: URL(fileURLWithPath: path)))
                #expect(Array(bytes.prefix(3)) == [0xEF, 0xBB, 0xBF])
                #expect(String(decoding: bytes.dropFirst(3), as: UTF8.self).hasPrefix("Quarterly Report"))
            }
        }
    }

    @Test func aReservedFileIsReplacedOnlyWhileItIsStillEmpty() throws {
        // A one-click conversion reserves report.docx empty (ExportTarget), then exports for as long as it takes; whatever
        // another app put there meanwhile (its own file, a link, a folder) is never written over.
        try inFolder { dir in
            let engine = try PdfEngine.open(ExportTestPdf.make())
            defer { engine.close() }
            let fm = FileManager.default
            let path = dir + "/report.docx"

            #expect(ExportTarget.tryCreate(path) == .created)
            #expect(try DocumentExport.exportToFile(engine, .word, path, overReservedOnly: true).saved)
            #expect(((try fm.attributesOfItem(atPath: path))[.size] as? NSNumber)?.intValue ?? 0 > 0)

            try Data("someone else's".utf8).write(to: URL(fileURLWithPath: path))
            let error = try #require(throws: PdfEditError.self) { _ = try DocumentExport.exportToFile(engine, .word, path, overReservedOnly: true) }
            #expect(error.message.contains("report.docx was changed by something else"))
            #expect(try String(contentsOfFile: path, encoding: .utf8) == "someone else's")

            let link = dir + "/linked.docx", elsewhere = dir + "/elsewhere.txt"
            fm.createFile(atPath: elsewhere, contents: nil)
            try fm.createSymbolicLink(atPath: link, withDestinationPath: elsewhere) // a link to an empty file isn't the reserved file
            #expect(throws: PdfEditError.self) { _ = try DocumentExport.exportToFile(engine, .word, link, overReservedOnly: true) }
            #expect(try fm.destinationOfSymbolicLink(atPath: link) == elsewhere)
            #expect(((try fm.attributesOfItem(atPath: elsewhere))[.size] as? NSNumber)?.intValue == 0)

            // Removed meanwhile: written anew. And nothing of the export's own is left behind.
            #expect(try DocumentExport.exportToFile(engine, .word, dir + "/gone.docx", overReservedOnly: true).saved)
            #expect(try files(dir) == ["elsewhere.txt", "gone.docx", "linked.docx", "report.docx"])
        }
    }

    @Test(arguments: ExportFormat.allCases) func nothingExtractedSavesNothing(_ format: ExportFormat) throws {
        try inFolder { dir in
            let engine = try PdfEngine.open(ExportTestPdf.blank(2))
            defer { engine.close() }
            let report = try DocumentExport.exportToFile(engine, format, dir + "/out" + DocumentExport.fileExtension(format))
            #expect(!report.saved)
            #expect(report.noText == 2)
            #expect(report.noTextWithPictures == 0)
            #expect(try files(dir).isEmpty)

            // Text but no tables: Excel saves nothing either.
            let text = try PdfEngine.open(TestPdf.make(1))
            defer { text.close() }
            #expect(try DocumentExport.export(text, format, to: MemorySink()).saved == (format != .excel))
        }
    }

    @Test func pagesWithoutTextAreRecognizedWhenARecognizerIsGiven() throws {
        let engine = try PdfEngine.open(ExportTestPdf.blank(3))
        defer { engine.close() }
        let asked = Collected<Int>()
        var options = ExportOptions(pages: [2, 0])
        options.recognize = { _, page, _ in
            asked.add(page)
            if page == 0 { throw NoOcr() }
            return [OcrWord("Recognized", RectD(72, 72, 120, 14)), OcrWord("words", RectD(200, 72, 60, 14))]
        }
        let sink = MemorySink()
        let report = try DocumentExport.export(engine, .text, to: sink, options: options)

        #expect(asked.all == [2, 0])
        #expect(report.saved)
        #expect(report.pages == 2)
        #expect(report.recognized == 1)
        #expect(report.noText == 1)
        #expect(report.recognitionFailed == [ExportProblem(0, "no OCR today")])
        #expect(String(decoding: sink.bytes, as: UTF8.self).contains("Recognized words"))

        // Without a recognizer the same pages have no text: nothing to save.
        options.recognize = nil
        #expect(try !DocumentExport.export(engine, .text, to: MemorySink(), options: options).saved)
    }

    @Test func theRecognizersSuspectWordsAreCounted() throws {
        let engine = try PdfEngine.open(ExportTestPdf.blank(2))
        defer { engine.close() }
        var options = ExportOptions()
        options.recognize = { _, page, _ in
            page == 0
                ? [OcrWord("Recognized", RectD(72, 72, 120, 14)), OcrWord("w0rds", RectD(200, 72, 60, 14), suspect: .lettersAndDigits)]
                : [OcrWord("Fine", RectD(72, 72, 60, 14)), OcrWord("ok", RectD(140, 72, 30, 14))]
        }
        let report = try DocumentExport.export(engine, .text, to: MemorySink(), options: options)
        #expect(report.recognized == 2)
        #expect(report.suspectWords == 1)
        // A page with text of its own isn't recognized: nothing suspect.
        let text = try PdfEngine.open(TestPdf.make(1))
        defer { text.close() }
        #expect(try DocumentExport.export(text, .text, to: MemorySink(), options: options).suspectWords == 0)
    }

    @Test func reportsProgressPageByPageThenWriting() throws {
        let engine = try PdfEngine.open(TestPdf.make(3))
        defer { engine.close() }
        let seen = Collected<ExportProgress>()
        _ = try DocumentExport.export(engine, .text, to: MemorySink(), options: ExportOptions(pages: [1, 2], progress: { seen.add($0) }))
        #expect(seen.all == [ExportProgress(.reading, 1, 0, 2), ExportProgress(.reading, 2, 1, 2), ExportProgress(.writing, -1, 2, 2)])
        #expect(seen.all[1].fraction == 0.5)
    }

    @Test func aCancelledExportLeavesNothing() throws {
        try inFolder { dir in
            let engine = try PdfEngine.open(TestPdf.make(2))
            defer { engine.close() }
            let cancel = CancelToken()
            let options = ExportOptions(progress: { if $0.index == 1 { cancel.cancel() } })
            #expect(throws: CancellationError.self) {
                _ = try DocumentExport.exportToFile(engine, .word, dir + "/out.docx", options: options, cancel: cancel)
            }
            #expect(try files(dir).isEmpty)
        }
    }
}
