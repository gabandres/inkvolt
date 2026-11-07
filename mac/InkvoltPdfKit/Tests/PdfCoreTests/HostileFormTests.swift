import Foundation
import Testing
@testable import PdfCore

/// The 1.9.0 hostile-input review of the forms and repair work (no Windows twin): files built to make a form read, a fill or
/// a repair take unbounded time or memory, or to hide objects from the stale-tail check, must be handled in bounded work.
/// A hang fails the test instead of blocking the run.
struct HostileFormTests {
    struct TimedOut: Error {}

    private final class Outcome<T>: @unchecked Sendable { var result: Result<T, Error>? }

    /// Runs `work` on another thread and waits at most `seconds` for it.
    private func within<T: Sendable>(_ seconds: Double = 20, _ work: @escaping @Sendable () throws -> T) throws -> T {
        let box = Outcome<T>()
        let done = DispatchSemaphore(value: 0)
        Thread {
            box.result = Result { try work() }
            done.signal()
        }.start()
        if done.wait(timeout: .now() + seconds) == .timedOut { throw TimedOut() }
        return try box.result!.get()
    }

    private static let helv = "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"

    // MARK: The repaired copy

    /// 300 bytes whose last object is numbered near MuPDF's largest: the repaired copy MuPDF wrote listed every number up
    /// to it (8 million rows of its cross-reference table, 168 MB), and loading each first took seconds.
    @Test func aTinyDamagedFileWithAHugeObjectNumberIsRepairedSmall() throws {
        let data = Array("""
        %PDF-1.7
        1 0 obj
        << /Type /Catalog /Pages 2 0 R /Extra 8388000 0 R >>
        endobj
        2 0 obj
        << /Type /Pages /Kids [3 0 R] /Count 1 >>
        endobj
        3 0 obj
        << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>
        endobj
        8388000 0 obj
        << /Kept true >>
        endobj
        trailer
        << /Root 1 0 R >>
        %%EOF

        """.utf8)
        let started = Date()
        let normal = try within { PdfRepair.normalize(data, nil) }
        let seconds = Date().timeIntervalSince(started)
        #expect(normal.repaired)
        #expect(normal.data.count < 64 * 1024, "the repaired copy is \(normal.data.count) bytes")
        #expect(seconds < 5, "the repair took \(seconds) s")
        // The copy is sound and keeps the page and what the catalog names.
        let doc = try Core2Pdf.open(normal.data)
        #expect(doc.canAppend)
        #expect(try doc.pageCount() == 1)
        #expect(doc.catalog.dict("Extra")?.has("Kept") == true)
    }

    // MARK: A widget on many pages

    /// 3,000 pages share one /Annots array of 100 fields: 300,000 places a widget is shown. Reading the form made a
    /// FormWidget for each and grouped them page by page over all of them (quadratic).
    @Test func aWidgetListSharedByEveryPageIsReadInBoundedWork() throws {
        let pages = 3000, fields = 100
        let firstField = 5, firstPage = firstField + fields
        let fieldRefs = (0..<fields).map { "\(firstField + $0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [\(fieldRefs)] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [\((0..<pages).map { "\(firstPage + $0) 0 R" }.joined(separator: " "))] /Count \(pages) >>",
            "[\(fieldRefs)]",
            Self.helv,
        ]
        for i in 0..<fields {
            let y = 20 + (i % 70) * 10
            objects.append("<< /Type /Annot /Subtype /Widget /F 4 /FT /Tx /T (f\(i)) /Rect [72 \(y) 300 \(y + 8)] /DA (/Helv 6 Tf 0 g) >>")
        }
        for _ in 0..<pages { objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots 3 0 R >>") }
        let data = Core2Pdf.build(objects)

        let started = Date()
        let widgets = try within { try FormEditor.read(data, nil) }
        let seconds = Date().timeIntervalSince(started)
        #expect(seconds < 10, "reading the form took \(seconds) s")
        // Each widget on its first page, and places on further pages up to a bound.
        #expect(widgets.count == fields + FormEditor.maxExtraPlaces, "\(widgets.count) widgets")
        #expect(Set(widgets.filter { $0.pageIndex == 0 }.map(\.fieldName)).count == fields)
        #expect(widgets.map(\.tabOrder) == Array(0..<widgets.count))
    }

    // MARK: A check box face that inflates

    /// A check box face of a few hundred bytes that inflates (twice over) to 80 MB of spaces, shared by 12 widgets of a
    /// form that asks for its appearances: every fill decoded it whole, several times for each widget.
    @Test func aCheckBoxFaceThatInflatesHugelyIsntDecodedWhole() throws {
        let widgets = 12
        let bomb = HandDeflate.zlib(RunBytes(head: [], byte: 32, count: 80 << 20), times: 2).bytes
        let face = "<< /Type /XObject /Subtype /Form /BBox [0 0 10 10] /Filter [/FlateDecode /FlateDecode] /Length \(bomb.count) >>\nstream\n"
            + latin1String(bomb) + "\nendstream"
        let firstWidget = 7
        let kids = (0..<widgets).map { "\(firstWidget + $0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [6 0 R 5 0 R] /NeedAppearances true /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [6 0 R \(kids)] >>",
            Self.helv,
            "<< /FT /Btn /T (boxes) /V /Off /Kids [\(kids)] >>",
            "<< /Type /Annot /Subtype /Widget /F 4 /P 3 0 R /FT /Tx /T (name) /Rect [72 740 300 760] /DA (/Helv 12 Tf 0 g) >>",
        ]
        let faceObject = firstWidget + widgets
        for i in 0..<widgets {
            objects.append("<< /Type /Annot /Subtype /Widget /F 4 /P 3 0 R /Parent 5 0 R /Rect [\(72 + i * 20) 700 \(84 + i * 20) 712] /AS /Off /AP << /N << /Yes \(faceObject) 0 R /Off \(faceObject) 0 R >> >> >>")
        }
        objects.append(face)
        let data = RedactionTestPdf.build(objects) // Latin-1: the stream's bytes as they are
        #expect(data.count < 64 * 1024)

        let started = Date()
        let filled = try within { try FormEditor.fill(data, nil, ["name": "Ana"]).data }
        let seconds = Date().timeIntervalSince(started)
        #expect(seconds < 10, "the fill took \(seconds) s")
        #expect(try FormEditor.read(filled, nil).first { $0.fieldName == "name" }?.value == "Ana")
    }

    // MARK: Objects the stale-tail check didn't see

    /// MuPDF's lexer reads a comment as white space and a signed number as a number, so "5 0 %…\nobj" and "+5 +0 obj" are
    /// objects to its repair: a tail holding one is a repair the person is told of, never cut quietly.
    @Test(arguments: ["5 0 %note\nobj", "+5 +0 obj", "5\n%a\n0\n%b\nobj"])
    func anObjectHeaderWithCommentsOrSignsIsSeenInATail(header: String) throws {
        let sound = DamagedFile.sound()
        let tail = "x\n\(header)\n<< /Type /Annot /Subtype /Widget /F 4 /FT /Tx /T (name) /Rect [72 700 300 720] /V (Older) >>\nendobj\nstartxref\n\(sound.count - 30)\n%%EOF\n"
        let data = sound + Array(tail.utf8)
        // MuPDF's repair takes such a header for an object (a file of objects alone, no cross-reference).
        var loose = "%PDF-1.7\n"
        for (i, o) in DamagedFile.objects.enumerated() {
            let older = "<< /Type /Annot /Subtype /Widget /F 4 /FT /Tx /T (name) /Rect [72 700 300 720] /V (Older) >>"
            loose += i + 1 == 5 ? "\(header)\n\(older)\nendobj\n" : "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        loose += "trailer\n<< /Root 1 0 R >>\n%%EOF\n"
        #expect(try Core2Pdf.open(Array(loose.utf8)).object(5).text("V") == "Older")

        let found = try #require(StaleTail.find(data))
        #expect(found.keep == sound.count)
        #expect(found.hidesObjects)
        #expect(PdfRepair.normalize(data, nil).repaired)
    }
}
