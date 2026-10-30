import Foundation
import Testing
@testable import PdfCore

/// Ported from AutoTagTests.cs and AutoTagBatchTests (same names): PDF/A-2a, Make Accessible in Batch and presets. Serialized
/// with the other Pro tests (`ProGated`): Batch asks the Pro check for Make Accessible and PDF/A-2a. Adapted: where the Windows
/// tests ask `AccessibilityCheck` (roadmap 1.3, not on this branch), the tags are looked at.
extension ProGated {
@Suite final class AutoTagOutputTests {
    private let root: String

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-autotag-\(NewIds.hex().prefix(8))")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        Pro.store = MemoryProStore()
        Pro.enforced = false
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @Test func Save_as_pdfa_2a_keeps_the_tags_and_says_conformance_a_and_pdfua() throws {
        let pdf = ExportTestPdf.make()
        #expect(throws: PdfAError.self) { try PdfA.convert(pdf, nil, conformance: .a) } // not tagged
        let tagged = try AutoTag.write(pdf, nil, TagTest.withAlt(TagTest.plan(pdf)), AccessibleOptions(title: "Report", language: "en"))
        let result = try PdfA.convert(tagged, nil, conformance: .a)
        #expect(PdfA.validate(result.data, conformance: .a) == [])
        let doc = try PdfEdit.openToRead(result.data, nil)
        let xmp = String(decoding: doc.catalog.dict("Metadata")?.streamData ?? [], as: UTF8.self)
        #expect(xmp.contains("<pdfaid:conformance>A</pdfaid:conformance>"))
        #expect(xmp.contains("<pdfuaid:part>1</pdfuaid:part>"))
        #expect(xmp.contains("pdfaSchema:prefix>pdfuaid<")) // the extension schema PDF/A asks for
        #expect(doc.catalog.has("StructTreeRoot"))
        try TagTest.tagsHold(result.data)
    }

    @Test func Batch_tags_each_file_saves_pdfa_2a_and_says_what_needs_alt_text() async throws {
        let input = (root as NSString).appendingPathComponent("report.pdf")
        try Data(ExportTestPdf.make()).write(to: URL(fileURLWithPath: input))
        let out = (root as NSString).appendingPathComponent("out")
        let plan = BatchPlan(steps: [.makeAccessible(language: nil), .saveAsPdfA2a], outputFolder: out)
        #expect(plan.validate(ocrAvailable: false) == nil)

        let summary = try await BatchRunner.run([BatchFile(input)], plan, BatchHost())

        #expect(summary.items.count == 1)
        let item = try #require(summary.items.first)
        #expect(item.state == .done, "\(item.message)")
        #expect(item.notes.contains { $0.hasPrefix("Tagged:") && $0.contains("title \"Quarterly Report\"") && $0.contains("language en") })
        #expect(item.notes.contains { $0.hasPrefix("1 picture needs alternate text") })
        #expect(item.notes.contains { $0.hasPrefix("PDF/A-2a") })
        let result = [UInt8](try Data(contentsOf: URL(fileURLWithPath: (out as NSString).appendingPathComponent("report.pdf"))))
        #expect(PdfA.validate(result, conformance: .a) == [])
        let doc = try PdfEdit.openToRead(result, nil)
        #expect(TagTest.tree(doc).first { $0.type == "Figure" }.map { !$0.elem.has("Alt") } == true) // only the alternate text is left
    }

    @Test func Presets_keep_make_accessible_and_the_pdfa_level() throws {
        let json = BatchPresets.write(BatchPreset(name: "Accessible archive", steps: [.makeAccessible(language: "es-PR"), .saveAsPdfA2a]))
        #expect(json.contains("\"makeAccessible\""))
        let steps = try BatchPresets.read(json).steps
        #expect(steps == [.makeAccessible(language: "es-PR"), .saveAsPdfA2a])
        #expect(try BatchPresets.read(BatchPresets.write(BatchPreset(name: "B", steps: [.saveAsPdfA]))).steps == [.saveAsPdfA])
    }

    @Test func Batch_asks_the_pro_check_for_make_accessible_and_pdfa_2a() {
        let out = (root as NSString).appendingPathComponent("out")
        Pro.enforced = true
        defer { Pro.enforced = false }
        #expect(BatchPlan(steps: [.makeAccessible(language: nil)], outputFolder: out).validate(ocrAvailable: false) == Pro.locked(.autoTagging))
        #expect(BatchPlan(steps: [.saveAsPdfA2a], outputFolder: out).validate(ocrAvailable: false) == Pro.locked(.accessibleOutput))
        #expect(BatchPlan(steps: [.saveAsPdfA], outputFolder: out).validate(ocrAvailable: false) == nil) // PDF/A-2b stays free
    }

    /// The files veraPDF validates on Windows (`INKVOLTPDF_TAG_INPUTS`, `INKVOLTPDF_TAG_OUT`; off without them; veraPDF stays
    /// off the Mac): each one tagged as `tools/a11y-corpus`'s `tag --all` does, figures given a stand-in alternate text, into
    /// `tagged/`, then Save as PDF/A-2a into `pdfa/`; `log.txt` says what became of each.
    @Test func Corpus_files_are_tagged_for_verapdf_when_asked() throws {
        let env = ProcessInfo.processInfo.environment
        guard let inputs = env["INKVOLTPDF_TAG_INPUTS"], let out = env["INKVOLTPDF_TAG_OUT"], !inputs.isEmpty, !out.isEmpty else { return }
        let taggedFolder = (out as NSString).appendingPathComponent("tagged"), pdfaFolder = (out as NSString).appendingPathComponent("pdfa")
        for f in [taggedFolder, pdfaFolder] { try FileManager.default.createDirectory(atPath: f, withIntermediateDirectories: true) }
        var log: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: inputs).sorted() where name.lowercased().hasSuffix(".pdf") {
            let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: (inputs as NSString).appendingPathComponent(name))))
            let started = Date()
            do {
                let engine = try PdfEngine.open(data)
                defer { engine.close() }
                var plan = try AutoTag.plan(engine, data, nil)
                var figures = 0
                for i in plan.blocks.indices where plan.blocks[i].kind == .figure {
                    figures += 1
                    plan.blocks[i].alt = "Figure \(figures) on page \(plan.blocks[i].page + 1)"
                }
                let title = plan.title ?? (name as NSString).deletingPathExtension
                let tagged = try AutoTag.write(data, nil, plan, AccessibleOptions(title: title, language: plan.language ?? "en"))
                try Data(tagged).write(to: URL(fileURLWithPath: (taggedFolder as NSString).appendingPathComponent(name)))
                let seconds = String(format: "%.1f", Date().timeIntervalSince(started))
                log.append("\(name) tagged: \(plan.blocks.count) blocks, \(figures) figures, \(seconds) s")
                do {
                    let copy = try PdfA.convert(tagged, nil, conformance: .a)
                    try Data(copy.data).write(to: URL(fileURLWithPath: (pdfaFolder as NSString).appendingPathComponent(name)))
                    log.append("\(name) saved as 2a; \(copy.changes.joined(separator: "; "))")
                } catch let e as PdfAError {
                    log.append("\(name) refused: \(e.blockers.joined(separator: " "))")
                }
            } catch {
                log.append("\(name) ERROR \(error)")
            }
        }
        try Data(log.joined(separator: "\n").utf8).write(to: URL(fileURLWithPath: (out as NSString).appendingPathComponent("log.txt")))
    }
}
}
