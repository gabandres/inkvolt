import Foundation
import Testing
@testable import PdfCore

/// File › Export Pages as Images (Windows' `FileActions.ExportImages`, app code without tests there): the names, the
/// resolution kept under `PageImages.maxPixels`, the images written, a cancel and a refused page. Mac additions.
struct PageImageExportTests {
    private func folder() throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-images-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url.path
    }

    @Test func eachPageIsNamedAsWindowsNamesIt() {
        #expect(PageImageExport.fileName("Report", page: 2, jpeg: false) == "Report - page 3.png")
        #expect(PageImageExport.fileName("Report", page: 0, jpeg: true) == "Report - page 1.jpg")
        #expect(PageImageExport.resolutions == [72, 96, 150, 200, 300, 600])
        #expect(PageImageExport.resolutions[PageImageExport.defaultResolution] == 150)
    }

    @Test func aTakenNameGetsANumberAndNothingIsReplaced() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: dir + "/Doc - page 1.png", contents: Data([1]))
        let engine = try PdfEngine.open(TestPdf.make(2))
        defer { engine.close() }
        let plan = try PageImageExport.plan(engine, pages: [0, 1], folder: dir, name: "Doc", dpi: 72, jpeg: false)
        #expect(plan.targets.map { ($0.path as NSString).lastPathComponent } == ["Doc - page 1 (2).png", "Doc - page 2.png"])
        #expect(plan.clamped.isEmpty)
    }

    @Test func aVeryLargePageIsExportedAtALowerResolution() throws {
        // A0 (2384 × 3370 pt) at 600 dpi would be ~560 megapixels.
        let a0 = Core1TestPdf.build([
            1: "<< /Type /Catalog /Pages 2 0 R >>",
            2: "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2384 3370] >>",
            4: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ])
        let engine = try PdfEngine.open(a0)
        defer { engine.close() }
        let plan = try PageImageExport.plan(engine, pages: [0, 1], folder: NSTemporaryDirectory(), name: "Plan", dpi: 600, jpeg: false)
        #expect(plan.clamped == [0])
        #expect(plan.lowest! < 600 && plan.dpi[1] == 600)
        let g = engine.page(0)
        #expect(g.width / 72 * plan.dpi[0]! * (g.height / 72 * plan.dpi[0]!) <= PageImages.maxPixels)
    }

    @Test func thePagesAreWrittenAsPngOrJpeg() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let engine = try PdfEngine.open(TestPdf.make(3))
        defer { engine.close() }
        for jpeg in [false, true] {
            let plan = try PageImageExport.plan(engine, pages: [0, 2], folder: dir, name: "Doc", dpi: 72, jpeg: jpeg)
            var seen: [Int] = []
            let outcome = PageImageExport.run(engine, plan, jpeg: jpeg) { page, _, _ in seen.append(page) }
            #expect(outcome.done == 2 && outcome.refused.isEmpty && !outcome.cancelled && outcome.failure == nil)
            #expect(seen == [0, 2])
            for t in plan.targets {
                let bytes = [UInt8](try Data(contentsOf: URL(fileURLWithPath: t.path)).prefix(3))
                #expect(bytes == (jpeg ? [0xFF, 0xD8, 0xFF] : [0x89, 0x50, 0x4E]))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
                == ["Doc - page 1.jpg", "Doc - page 1.png", "Doc - page 3.jpg", "Doc - page 3.png"])
    }

    @Test func aCancelKeepsTheImagesBeforeItAndLeavesNoHalfImage() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let engine = try PdfEngine.open(TestPdf.make(3))
        defer { engine.close() }
        let plan = try PageImageExport.plan(engine, pages: [0, 1, 2], folder: dir, name: "Doc", dpi: 72, jpeg: false)
        let cancel = CancelToken()
        let outcome = PageImageExport.run(engine, plan, jpeg: false, cancel: cancel) { _, index, _ in if index == 1 { cancel.cancel() } }
        #expect(outcome.cancelled && outcome.done == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir) == ["Doc - page 1.png"])
    }

    @Test func aPageThatCantBeReadIsLeftOutAndTheRestAreSaved() throws {
        let dir = try folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let engine = try PdfEngine.open(TestPdf.make(3))
        defer { engine.close() }
        let plan = try PageImageExport.plan(engine, pages: [0, 1, 2], folder: dir, name: "Doc", dpi: 72, jpeg: false)
        let outcome = PageImageExport.run(engine, plan, jpeg: false, save: { e, page, dpi, path, jpeg, cancel in
            if page == 1 { throw PageRefused(page: 1, tooSlow: true) }
            try e.saveImage(page, dpi: dpi, path: path, jpeg: jpeg, cancel: cancel)
        }) { _, _, _ in }
        #expect(outcome.done == 2 && outcome.refused == [1] && !outcome.cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir).sorted() == ["Doc - page 1.png", "Doc - page 3.png"])
    }
}
