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
        // The best of up to 3 (a busy runner only adds time): MuPDF still walks a table that long while it repairs, which
        // took 5.56 s once on GitHub's 3-core runner (2026-11-10), so the bound is 12 s there. The copy's size is the sharp
        // check: the old copy listed all 8 million numbers (168 MB) and loading it took far longer.
        let bound: Double = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] == nil ? 5 : 12
        var seconds = Double.infinity
        var normal = (data: [UInt8](), repaired: false)
        for _ in 0..<3 where seconds >= bound {
            let started = Date()
            let made = try within { PdfRepair.normalize(data, nil) }
            seconds = min(seconds, Date().timeIntervalSince(started))
            normal = (made.data, made.repaired)
        }
        #expect(normal.repaired)
        #expect(normal.data.count < 64 * 1024, "the repaired copy is \(normal.data.count) bytes")
        #expect(seconds < bound, "the repair took \(seconds) s at best")
        // The copy is sound and keeps the page and what the catalog names.
        let doc = try Core2Pdf.open(normal.data)
        #expect(doc.canAppend)
        #expect(try doc.pageCount() == 1)
        #expect(doc.catalog.dict("Extra")?.has("Kept") == true)
    }

    // MARK: A widget on many pages

    /// `pages` pages share one /Annots array of `fields` text fields; the last `lateOn` of them list another array, the same
    /// fields and one more, "late".
    private static func sharedAnnots(pages: Int, fields: Int, lateOn: Int) -> [UInt8] {
        let firstField = 6, late = firstField + fields, firstPage = late + 1
        let fieldRefs = (0..<fields).map { "\(firstField + $0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [\(fieldRefs) \(late) 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [\((0..<pages).map { "\(firstPage + $0) 0 R" }.joined(separator: " "))] /Count \(pages) >>",
            "[\(fieldRefs)]",
            helv,
            "[\(fieldRefs) \(late) 0 R]",
        ]
        for i in 0..<fields {
            let y = 20 + (i % 70) * 10
            objects.append("<< /Type /Annot /Subtype /Widget /F 4 /FT /Tx /T (f\(i)) /Rect [72 \(y) 300 \(y + 8)] /DA (/Helv 6 Tf 0 g) >>")
        }
        objects.append("<< /Type /Annot /Subtype /Widget /F 4 /FT /Tx /T (late) /Rect [320 20 500 28] /DA (/Helv 6 Tf 0 g) >>")
        for p in 0..<pages {
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots \(p >= pages - lateOn ? 5 : 3) 0 R >>")
        }
        return Core2Pdf.build(objects)
    }

    private func places(_ widgets: [FormWidget]) -> [String: Int] {
        widgets.reduce(into: [:]) { $0[$1.fieldName, default: 0] += 1 }
    }

    /// 3,000 pages share one /Annots array of 100 fields: 300,000 places a widget is shown. Reading the form made a
    /// FormWidget for each and grouped them page by page over all of them (quadratic). Now each field gets an equal share of
    /// `maxPlaces`, a field listed on few pages (even the last ones) keeps them all, and the places left out are counted.
    @Test func aWidgetListSharedByEveryPageIsReadInBoundedWork() throws {
        let data = Self.sharedAnnots(pages: 3000, fields: 100, lateOn: 2)
        let started = Date()
        let read = try within { try FormEditor.readForm(data, nil) }
        let seconds = Date().timeIntervalSince(started)
        #expect(seconds < 10, "reading the form took \(seconds) s")
        let byField = places(read.widgets)
        #expect(byField["late"] == 2)
        let share = (FormEditor.maxPlaces - 2) / 100
        #expect((0..<100).allSatisfy { byField["f\($0)"] == share }, "\(byField["f0"] ?? 0) places each")
        #expect(read.widgets.count <= FormEditor.maxPlaces)
        #expect(read.placesLeftOut == 300_000 + 2 - read.widgets.count)
        #expect(Set(read.widgets.filter { $0.pageIndex == 0 }.map(\.fieldName)).count == 100)
        #expect(read.widgets.map(\.tabOrder) == Array(0..<read.widgets.count))
        #expect(FormEditor.placesLeftOutMessage(read.placesLeftOut).contains("\(read.placesLeftOut)"))
    }

    /// A header field one /Annots array puts on all 12,000 pages (qpdf's shared annotations, which Acrobat shows on each)
    /// is on every page, and a field the last two pages add is on both: nothing left out.
    @Test func aHeaderFieldOnEveryPageOfALongFormIsOnEachOfThem() throws {
        let data = Self.sharedAnnots(pages: 12_000, fields: 1, lateOn: 2)
        let read = try within { try FormEditor.readForm(data, nil) }
        let byField = places(read.widgets)
        #expect(byField["f0"] == 12_000)
        #expect(byField["late"] == 2)
        #expect(Set(read.widgets.filter { $0.fieldName == "f0" }.map(\.pageIndex)).count == 12_000)
        #expect(read.placesLeftOut == 0)
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
    /// objects to its repair, and its repair reads no strings (`pdf_lex_no_string`: a parenthesis is a token alone), so
    /// "(junk 5 0 obj" is one too: a tail holding one is a repair the person is told of, never cut quietly.
    @Test(arguments: ["5 0 %note\nobj", "+5 +0 obj", "5\n%a\n0\n%b\nobj", "(junk 5 0 obj"])
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

    /// The word in a comment is no object to MuPDF's repair: such a tail is cut quietly, as one without the word.
    @Test(arguments: ["% exported obj", "%obj", "%%obj 5 0 obj"])
    func theWordObjInACommentIsNoObject(comment: String) throws {
        let sound = DamagedFile.sound()
        let data = sound + Array("x\n\(comment)\nstartxref\n\(sound.count - 30)\n%%EOF\n".utf8)
        let found = try #require(StaleTail.find(data))
        #expect(found.keep == sound.count)
        #expect(!found.hidesObjects)
        let normal = PdfRepair.normalize(data, nil)
        #expect(!normal.repaired)
        #expect(normal.data == sound)
    }

    // MARK: A face that can't be decoded

    /// A check box face whose bytes decode to nothing (a zlib stream cut after its header; a whole empty one followed by
    /// 70 KB) is unreadable, not empty: kept as it is, never replaced with a drawn tick.
    @Test(arguments: ["cut", "big"])
    func aCheckBoxFaceThatDecodesToNothingIsKept(kind: String) throws {
        let bytes: [UInt8] = kind == "cut" ? [0x78, 0x9C] : [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01] + [UInt8](repeating: 0xAB, count: 70_000)
        let face = "<< /Type /XObject /Subtype /Form /BBox [0 0 12 12] /Filter /FlateDecode /Length \(bytes.count) >>\nstream\n"
            + latin1String(bytes) + "\nendstream"
        let data = RedactionTestPdf.build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>",
            Self.helv,
            "<< /Type /Annot /Subtype /Widget /F 4 /P 3 0 R /FT /Btn /T (box) /V /Off /AS /Off /Rect [72 700 84 712] /MK << /CA (4) >> /AP << /N << /Yes 6 0 R /Off 7 0 R >> >> >>",
            face,
            "<< /Type /XObject /Subtype /Form /BBox [0 0 12 12] /Length 8 >>\nstream\n0 0 1 rg\nendstream",
        ])
        let filled = try FormEditor.fill(data, nil, ["box": "Yes"]).data
        let doc = try Core2Pdf.open(filled)
        let widget = try #require(Core2Pdf.field(doc, "box"))
        #expect(widget.name("AS") == "Yes")
        #expect(widget.dict("AP")?.dict("N")?["Yes"]?.rawStreamData == bytes)
    }

    // MARK: A sparse repair that is encrypted

    /// A damaged encrypted form with an object numbered in the millions that nothing refers to: its renumbered copy still
    /// decrypts with the same protection, and keeps that object (compaction alone keeps only what the trailer reaches).
    @Test func aSparseDamagedEncryptedFileIsRenumberedAndKeepsEveryObject() throws {
        let plain = Core2Pdf.form([
            "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /Rect [72 700 300 720] /DA (/Helv 12 Tf 0 g) /V (Alice) /F 4 /P 3 0 R >>",
        ])
        let encrypted = Encrypt.with(plain, "aes-128", user: "", owner: "own")
        let at = try #require(PdfBytes.last(Array("\nxref".utf8), in: encrypted, before: encrypted.count))
        // Moving the table damages the file (its startxref points before it now): MuPDF repairs it.
        let data = Array(encrypted[...at]) + Array("8388000 0 obj\n<< /Orphan true >>\nendobj\n".utf8) + Array(encrypted[(at + 1)...])
        #expect(try Core2Pdf.open(data).canAppend == false)

        let normal = try within { PdfRepair.normalize(data, nil) }
        #expect(normal.repaired)
        #expect(normal.data.count < 64 * 1024, "the repaired copy is \(normal.data.count) bytes")
        let copy = try Core2Pdf.open(normal.data)
        #expect(copy.canAppend)
        #expect(copy.objectCount < 100)
        #expect(copy.hasEncrypt)
        #expect(try PdfSecurity.readSecurity(normal.data, nil) == PdfSecurity.readSecurity(encrypted, nil))
        #expect(try FormEditor.read(normal.data, nil).first { $0.fieldName == "name" }?.value == "Alice")
        #expect((1..<copy.objectCount).contains { copy.object($0)["Orphan"]?.bool == true })
        #expect(!copy.trailer.has("InkvoltKeep"))
    }
}
