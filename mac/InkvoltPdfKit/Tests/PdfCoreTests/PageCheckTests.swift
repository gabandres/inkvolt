import Compression
import Foundation
import PrintCore
import Testing
@testable import PdfCore

/// Ported from PageCheckTests.cs: MuPDF's own inflating, bounded by time, and its pictures by size. Windows draws a page
/// first in a check process and refuses it past the limit; the Mac bounds MuPDF in process, through each call's cookie
/// (`PdfEngine.pageBudget`, `PdfEngine.maxPictureSamples`): the page's reading stops at the budget and the page is refused,
/// the rest of the document draws, reads and searches as before. Serialized and timed. Adapted: no check process, so
/// the tests of its starting, crashing, sharing and memory (BothCheckProcessesOpenOneCopyOfTheDocument, ACheckProcessThat…,
/// AProcessThatFails…, the viewer's waits) have no counterpart; AnEditsEngine… is the Mac's as it is (an edit opens a new
/// engine, whose verdicts start empty). Mac additions: Cancel and closing stop a bomb's page at once; every call that
/// reads a page's content is bounded.
@Suite(.serialized)
struct PageCheckTests {
    /// Short, so the bombs give up quickly here; the app's is `PdfEngine.defaultPageBudget`.
    static let limit = 1.0

    /// What a refusal may take past the limit on a loaded runner.
    static let slack = 3.0

    /// A zlib stream (RFC 1950) of `head` then `zeros` zero bytes, deflated as it goes (4 GB is never held).
    static func zlib(_ head: [UInt8], zeros: Int) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x9C]
        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }
        guard compression_stream_init(stream, COMPRESSION_STREAM_ENCODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return [] }
        defer { compression_stream_destroy(stream) }
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        let none = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
        defer { none.deallocate() }
        func pump(_ data: UnsafeBufferPointer<UInt8>, final: Bool) {
            stream.pointee.src_ptr = data.baseAddress ?? UnsafePointer(none)
            stream.pointee.src_size = data.count
            while true {
                let status = buffer.withUnsafeMutableBufferPointer { b in
                    stream.pointee.dst_ptr = b.baseAddress!
                    stream.pointee.dst_size = b.count
                    return compression_stream_process(stream, final ? Int32(COMPRESSION_STREAM_FINALIZE.rawValue) : 0)
                }
                out += buffer.prefix(buffer.count - stream.pointee.dst_size)
                if status != COMPRESSION_STATUS_OK || (stream.pointee.src_size == 0 && (!final || stream.pointee.dst_size > 0)) { break }
            }
        }
        head.withUnsafeBufferPointer { pump($0, final: false) }
        let chunk = [UInt8](repeating: 0, count: 1 << 20)
        var left = zeros
        while left > 0 {
            let n = min(left, chunk.count)
            chunk.withUnsafeBufferPointer { pump(UnsafeBufferPointer(rebasing: $0.prefix(n)), final: false) }
            left -= n
        }
        [UInt8]().withUnsafeBufferPointer { pump($0, final: true) }
        // Adler-32 of the head, then of the zeros (a stays, b grows by a for each).
        var a: UInt64 = 1, b: UInt64 = 0
        for byte in head {
            a = (a + UInt64(byte)) % 65521
            b = (b + a) % 65521
        }
        b = (b + a * (UInt64(zeros) % 65521)) % 65521
        let sum = UInt32(b << 16 | a)
        return out + [UInt8(sum >> 24), UInt8((sum >> 16) & 255), UInt8((sum >> 8) & 255), UInt8(sum & 255)]
    }

    static let drawn = Array("BT /F1 12 Tf 72 600 Td (Hidden) Tj ET ".utf8)

    /// About 4 KB that inflate twice to 4 GB: MuPDF took 52 to 116 s of one core to draw its page on Windows.
    static let twiceTo4Gb = zlib(zlib(drawn, zeros: 4 << 30), zeros: 0)

    /// About 1 MB that inflates once to 1 GB: 13 s a draw on Windows.
    static let onceTo1Gb = zlib(drawn, zeros: 1 << 30)

    /// A PDF of numbered objects given as bytes (a stream's data may be anything).
    static func build(_ objects: [[UInt8]]) -> [UInt8] {
        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.count)
            out += Array("\(i + 1) 0 obj\n".utf8) + o + Array("\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }

    static func obj(_ text: String) -> [UInt8] { Array(text.utf8) }

    static func stream(_ data: [UInt8], _ dict: String = "") -> [UInt8] {
        Array("<< \(dict) /Length \(data.count) >>\nstream\n".utf8) + data + Array("\nendstream".utf8)
    }

    static func stream(_ content: String, _ dict: String = "") -> [UInt8] { stream(Array(content.utf8), dict) }

    /// Three pages that each draw "Visit notes"; the second has `packed` as a second content stream with `dict`.
    static func threePages(_ packed: [UInt8], _ dict: String) -> [UInt8] {
        build([
            obj("<< /Type /Catalog /Pages 2 0 R >>"),
            obj("<< /Type /Pages /Kids [3 0 R 4 0 R 5 0 R] /Count 3 >>"),
            obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>"),
            obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents [6 0 R 8 0 R] /Resources << /Font << /F1 7 0 R >> >> >>"),
            obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>"),
            stream("BT /F1 18 Tf 72 700 Td (Visit notes) Tj ET"),
            obj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
            stream(packed, dict),
        ])
    }

    /// A page drawing `picture` (its dictionary `dict`) over most of it.
    static func picture(_ picture: [UInt8], _ dict: String) -> [UInt8] {
        build([
            obj("<< /Type /Catalog /Pages 2 0 R >>"),
            obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /XObject << /Im 5 0 R >> >> >>"),
            stream("q 500 0 0 500 50 150 cm /Im Do Q"),
            stream(picture, dict),
        ])
    }

    static let bombs = ["7 KB, Flate twice to 4 GB", "1 MB, Flate once to 1 GB"]

    static func bomb(_ name: String) -> [UInt8] {
        name.hasPrefix("7 KB") ? threePages(twiceTo4Gb, "/Filter [/FlateDecode /FlateDecode]") : threePages(onceTo1Gb, "/Filter /FlateDecode")
    }

    static func open(_ file: [UInt8], budget: Double = limit) throws -> PdfEngine {
        let engine = try PdfEngine.open(file)
        engine.pageBudget = budget
        return engine
    }

    /// Seconds `work` took.
    static func time(_ work: () throws -> Void) rethrows -> Double {
        let start = ContinuousClock.now
        try work()
        let d = ContinuousClock.now - start
        return Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Runs `work`, expecting it refused; what it threw.
    static func refused(_ work: () throws -> Void) -> PageRefused? {
        do {
            try work()
            Issue.record("not refused")
        } catch let e as PageRefused {
            return e
        } catch {
            Issue.record("threw \(error) instead of refusing")
        }
        return nil
    }

    @Test(arguments: bombs)
    func AFlateBombsPageIsRefusedWithinTheLimitAndTheRestOfTheDocumentWorks(_ name: String) throws {
        let file = Self.bomb(name)
        #expect(file.count < (name.hasPrefix("7 KB") ? 8 << 10 : (1 << 20) + (64 << 10)), "\(file.count) bytes")
        let engine = try Self.open(file)
        defer { engine.close() }

        var refusal: PageRefused?
        let took = Self.time { refusal = Self.refused { _ = try engine.render(1, scale: 0.5) } }
        #expect(took < Self.limit + Self.slack, "\(name): refused after \(took) s")
        #expect(refusal?.tooSlow == true)
        #expect(refusal?.page == 1)
        #expect(refusal?.message.contains("2") == true) // the page number, as the user counts
        #expect(engine.verdictOf(1) == .tooSlow)

        // Refused at once from then on, for its text too.
        let again = Self.time {
            _ = Self.refused { _ = try engine.render(1, scale: 2) }
            _ = Self.refused { _ = try engine.text(1) }
            _ = Self.refused { _ = try engine.exportRead(1, images: true, jpegAbovePixels: 1 << 20, cancel: nil) }
        }
        #expect(again < 1, "\(again) s")

        // The other pages draw and read.
        for page in [0, 2] {
            #expect(try engine.render(page, scale: 0.5).pixels.contains { $0 < 128 }, "page \(page + 1) drew nothing")
            #expect(try engine.text(page).text.contains("Visit notes"))
            #expect(engine.verdictOf(page) == .fine)
        }
    }

    @Test func EveryCallThatReadsAPagesContentIsBounded() throws {
        // A new engine for each, so none is refused from what another found: thumbnails and the view (render), the
        // export of pictures (saveImage), Find and copy (text), Recognize Text and redaction (textLines, exportRead), a
        // snapshot or a stamp's picture (renderRegionRgba).
        let file = Self.bomb("7 KB")
        let folder = NSTemporaryDirectory() + "inkvolt-check-\(NewIds.hex().prefix(8))"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let calls: [(String, (PdfEngine) throws -> Void)] = [
            ("render without comments", { _ = try $0.render(1, scale: 0.5, annotations: false) }),
            ("saveImage", { try $0.saveImage(1, dpi: 36, path: folder + "/page.png", jpeg: false) }),
            ("text", { _ = try $0.text(1) }),
            ("textLines", { _ = try $0.textLines(1, annotations: true) }),
            ("exportRead", { _ = try $0.exportRead(1, images: false, jpegAbovePixels: 0, cancel: nil) }),
            ("renderRegionRgba", { _ = try $0.renderRegionRgba(1, RectD(0, 0, 100, 100), scale: 1, cancel: nil) }),
        ]
        for (name, call) in calls {
            let engine = try Self.open(file)
            defer { engine.close() }
            var refusal: PageRefused?
            let took = Self.time { refusal = Self.refused { try call(engine) } }
            #expect(took < Self.limit + Self.slack, "\(name): \(took) s")
            #expect(refusal?.tooSlow == true, "\(name)")
        }
        #expect(!FileManager.default.fileExists(atPath: folder + "/page.png"))
    }

    @Test func CancelStopsABombsPageAtOnceAndRefusesNothing() throws {
        let engine = try Self.open(Self.bomb("7 KB"), budget: 120)
        defer { engine.close() }
        let cancel = CancelToken()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { cancel.cancel() }
        let took = Self.time {
            #expect(throws: CancellationError.self) { _ = try engine.render(1, scale: 0.5, cancel: cancel) }
        }
        #expect(took < 0.3 + Self.slack, "\(took) s")
        #expect(engine.verdictOf(1) == .unknown)
        // Nothing of the stopped reading is kept: the page draws again (and is refused, here, at a short limit).
        engine.pageBudget = Self.limit
        #expect(Self.refused { _ = try engine.render(1, scale: 0.5) }?.tooSlow == true)
    }

    @Test func ClosingTheDocumentStopsABombsPageAtOnce() throws {
        let engine = try Self.open(Self.bomb("7 KB"), budget: 120)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var outcome: Error?
        DispatchQueue.global().async {
            do { _ = try engine.render(1, scale: 0.5) } catch { outcome = error }
            done.signal()
        }
        Thread.sleep(forTimeInterval: 0.3)
        let took = Self.time {
            engine.close()
            #expect(done.wait(timeout: .now() + Self.slack) == .success)
        }
        #expect(took < Self.slack, "\(took) s")
        #expect(outcome is PdfEngineClosed || outcome is CancellationError, "\(String(describing: outcome))")
    }

    @Test func FindOverADocumentWithABombFinishes() throws {
        let engine = try Self.open(Self.bomb("7 KB"))
        defer { engine.close() }
        var pages: [PdfEngine.PageMatches] = []
        let took = try Self.time { pages = try engine.findAll("Visit notes", matchCase: false, wholeWord: false) }
        #expect(took < Self.limit + Self.slack, "\(took) s")
        #expect(pages.map(\.page) == [0, 1, 2])
        #expect(pages[0].hits.count == 1)
        #expect(pages[1].refused?.tooSlow == true)
        #expect(pages[1].error != nil)
        #expect(pages[2].hits.count == 1)

        // Searched again: the refused page isn't read twice.
        var second: [PdfEngine.PageMatches] = []
        let again = try Self.time { second = try engine.findAll("notes", matchCase: false, wholeWord: false) }
        #expect(second.reduce(0) { $0 + $1.hits.count } == 2)
        #expect(again < 1, "\(again) s")
    }

    @Test func APictureThatInflatesForSecondsIsRefusedAndOneMuPdfStopsAtItsSizeDraws() throws {
        // 20,000 x 20,000 RGB is 1.2 GB of samples: MuPDF inflates all of them for every draw, whatever the zoom (9 s a
        // draw on Windows), and doesn't look at the render's cookie while it does. Refused for its size before MuPDF
        // reads a sample of it. 1.2 MB of file.
        let samples = 20_000 * 20_000 * 3
        let bomb = Self.picture(Self.zlib([], zeros: samples), "/Type /XObject /Subtype /Image /Width 20000 /Height 20000 /BitsPerComponent 8 /ColorSpace /DeviceRGB /Filter /FlateDecode")
        #expect(bomb.count < 2 << 20, "\(bomb.count) bytes")
        do {
            let engine = try Self.open(bomb, budget: 120)
            defer { engine.close() }
            let took = Self.time { #expect(Self.refused { _ = try engine.render(0, scale: 0.25) }?.tooSlow == false) }
            #expect(took < Self.slack, "\(took) s")
            #expect(engine.verdictOf(0) == .failed)
        }

        // A picture of 10 x 10 whose data inflates to 1 GB: MuPDF reads no more than its size says (milliseconds).
        let small = Self.picture(Self.onceTo1Gb, "/Type /XObject /Subtype /Image /Width 10 /Height 10 /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /FlateDecode")
        let engine = try Self.open(small)
        defer { engine.close() }
        _ = try engine.render(0, scale: 0.25)
        #expect(engine.verdictOf(0) == .fine)
    }

    @Test(arguments: ["a small picture's soft mask", "a pattern's picture"])
    func APictureMuPdfDrawsOnlyThroughAnotherIsCheckedAtItsFullSizeToo(_ place: String) throws {
        // 50,000 x 50,000 gray (2.5 G samples) with a few bytes of data, drawn only through a small picture's soft mask
        // or a pattern's cell: refused for its size as a picture drawn on the page is.
        let huge = Self.stream(Self.zlib([], zeros: 0), "/Type /XObject /Subtype /Image /Width 50000 /Height 50000 /BitsPerComponent 8 /ColorSpace /DeviceGray /Filter /FlateDecode")
        let file = place.contains("mask")
            ? Self.build([
                Self.obj("<< /Type /Catalog /Pages 2 0 R >>"),
                Self.obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
                Self.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /XObject << /Im 5 0 R >> >> >>"),
                Self.stream("q 500 0 0 500 50 150 cm /Im Do Q"),
                Self.stream([UInt8](repeating: 0x80, count: 100 * 100), "/Type /XObject /Subtype /Image /Width 100 /Height 100 /BitsPerComponent 8 /ColorSpace /DeviceGray /SMask 6 0 R"),
                huge,
            ])
            : Self.build([
                Self.obj("<< /Type /Catalog /Pages 2 0 R >>"),
                Self.obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
                Self.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Pattern << /P1 5 0 R >> >> >>"),
                Self.stream("/Pattern cs /P1 scn 0 0 612 792 re f"),
                Self.stream("q 100 0 0 100 0 0 cm /Im Do Q", "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 100 100] /XStep 100 /YStep 100 /Resources << /XObject << /Im 6 0 R >> >>"),
                huge,
            ])
        let engine = try Self.open(file)
        defer { engine.close() }
        let took = Self.time { _ = Self.refused { _ = try engine.render(0, scale: 0.25) } }
        #expect(engine.verdictOf(0) == .failed) // too large, not too slow
        #expect(took < Self.limit + Self.slack, "\(took) s")
    }

    @Test func ARealDrawingSheetStillDrawsInFull() throws {
        // A sheet like the bench's drawing set: 72,000 paths on ARCH D, Flate content, a title; drawn at the app's budget
        // as without one.
        var content = "0.5 w 0 0 0 RG\n"
        var rng = SplitMix(seed: 3)
        for _ in 0..<72_000 {
            let x = rng.next(2560), y = rng.next(1700)
            content += "\(x) \(y) m \(x + rng.next(30)) \(y + rng.next(30)) l S\n" // hatching's short strokes
        }
        content += "BT /F2 24 Tf 2200 60 Td (A-103 FLOOR PLAN) Tj ET"
        let file = Self.build([
            Self.obj("<< /Type /Catalog /Pages 2 0 R >>"),
            Self.obj("<< /Type /Pages /Kids [3 0 R] /Count 1 >>"),
            Self.obj("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 2592 1728] /Contents 4 0 R /Resources << /Font << /F2 5 0 R >> >> >>"),
            Self.stream(Self.zlib(Array(content.utf8), zeros: 0), "/Filter /FlateDecode"),
            Self.obj("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>"),
        ])
        let budgeted = try PdfEngine.open(file)
        defer { budgeted.close() }
        #expect(budgeted.pageBudget == PdfEngine.defaultPageBudget)
        let plain = try Self.open(file, budget: 0) // no limit
        defer { plain.close() }
        let scale = 1200 / 2592.0
        let unlimited = try plain.render(0, scale: scale).pixels
        let bounded = try budgeted.render(0, scale: scale).pixels
        #expect(unlimited == bounded)
        #expect(budgeted.verdictOf(0) == .fine)
        #expect(try budgeted.text(0).text.contains("A-103"))
    }

    @Test func BatchsPageImagesLeaveOutARefusedPageAndSayWhich() async throws {
        let dir = NSTemporaryDirectory() + "inkvolt-check-batch-\(NewIds.hex().prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/visit.pdf"
        try Data(Self.bomb("7 KB")).write(to: URL(fileURLWithPath: file))
        let output = dir + "/out"
        let summary = try await PdfEngine.$budgetForTests.withValue(Self.limit) {
            try await BatchRunner.run([BatchFile(file)], BatchPlan(steps: [.export(.png, dpi: 36)], outputFolder: output), BatchHost())
        }
        #expect(summary.done == 1)
        #expect(FileManager.default.fileExists(atPath: output + "/visit - page 1.png"))
        #expect(!FileManager.default.fileExists(atPath: output + "/visit - page 2.png"))
        #expect(FileManager.default.fileExists(atPath: output + "/visit - page 3.png"))
        #expect(summary.items.first?.notes == [loc("Page {0} couldn't be read", CoreLanguage.number(2))])
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: output)) ?? []).allSatisfy { !$0.hasSuffix(".tmp") })
    }
}
