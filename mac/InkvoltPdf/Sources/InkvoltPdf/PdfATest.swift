import AppKit
import PdfCore

/// The self-test's scenario for E7 (`--edit`, on the synthetic text document before `MeasureTest`; `--only-pdfa` runs it
/// alone): File › Save as PDF/A-2b… found in the menu bar and enabled, then the command's own path (settling the edits,
/// the conversion with its progress sheet, the save, the result sheet's text) with the copy written to a temporary
/// folder instead of the save panel's choice; the copy checked by `PdfA.validate` and read back; the open document left
/// as it was; the copy refused over the open file; a CMYK document refused with its reasons; a restricted document asking
/// for its permissions password. The sheets aren't shown while the self-test runs: their titles and text are read from
/// `PdfAState`. Only counts and short texts are written.
@MainActor
struct PdfATest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private static func item(_ action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        for i in menu?.items ?? [] {
            if i.action == action { return i }
            if let hit = item(action, in: i.submenu) { return hit }
        }
        return nil
    }

    mutating func run() async {
        lines.append("== \(name): Save as PDF/A-2b")
        let menuItem = Self.item(#selector(DocumentWindowController.saveAsPdfA(_:)), in: NSApp.mainMenu)
        check(menuItem?.title == "Save as PDF/A-2b…" && menuItem?.menu?.title == "File" && menuItem.map { controller.validateMenuItem($0) } == true,
              "File › Save as PDF/A-2b… is in the menu bar and enabled")
        guard let session = controller.pdf.session else {
            check(false, "the document is open")
            return finish()
        }
        let before = session.data, dirty = session.isDirty
        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-pdfa-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: folder) }
        let target = URL(fileURLWithPath: (folder as NSString).appendingPathComponent(PdfA.copyName(session.displayName)))

        PdfAState.testTarget = target
        let saved = await controller.saveAsPdfA()
        check(saved && PdfAState.lastTitle == "Saved as PDF/A-2b" && PdfAState.lastMessage.hasPrefix(target.lastPathComponent)
              && PdfAState.lastMessage.contains("• sRGB output intent and PDF/A metadata added"),
              "the command saves the copy and says what changed (\(PdfAState.lastMessage.components(separatedBy: "\n• ").count - 1) changes)")
        let copy = (try? Data(contentsOf: target)).map { [UInt8]($0) } ?? []
        let problems = PdfA.validate(copy)
        check(!copy.isEmpty && problems.isEmpty, "the copy passes PdfA.validate (\(problems.count) problems)")
        if let engine = try? PdfEngine.open(copy), let original = try? PdfEngine.open(before) {
            let samePages = engine.pageCount == original.pageCount
            let sameText = (try? engine.text(0).text) == (try? original.text(0).text)
            engine.close()
            original.close()
            check(samePages && sameText, "the copy has the document's pages and text")
        } else {
            check(false, "the copy opens")
        }
        check(controller.pdf.session?.data == before && controller.pdf.session?.isDirty == dirty, "the open document didn't change")

        if let own = session.filePath {
            let onDisk = try? Data(contentsOf: URL(fileURLWithPath: own))
            PdfAState.testTarget = URL(fileURLWithPath: own)
            let over = await controller.saveAsPdfA()
            check(!over && PdfAState.lastTitle == "Choose another name" && (try? Data(contentsOf: URL(fileURLWithPath: own))) == onDisk,
                  "the copy isn't saved over the open document")
        }
        PdfAState.testTarget = nil

        let cmyk = Self.cmykPdf()
        let refused = await controller.makePdfACopy(cmyk, nil, name: "CMYK.pdf")
        check(refused == nil && PdfAState.lastTitle == "Can't save as PDF/A-2b" && PdfAState.lastMessage.hasPrefix("Nothing was saved.")
              && PdfAState.lastMessage.contains("CMYK"), "a CMYK document is refused, saying why")

        if let locked = try? PdfSecurity.protect(before, session.password, userPassword: "open", ownerPassword: "owner") {
            PdfAState.testOwnerPasswords = ["wrong", "owner"]
            let questions = PdfAState.ownerPasswordQuestions.count
            let result = await controller.makePdfACopy(locked, "open", name: "Locked.pdf")
            let asked = Array(PdfAState.ownerPasswordQuestions.dropFirst(questions))
            PdfAState.testOwnerPasswords = []
            check(result.map { PdfA.validate($0.data).isEmpty && $0.changes.contains { $0.contains("password protection removed") } } == true
                  && asked == ["Permissions password required", "That password is incorrect. Try again."],
                  "a restricted document asks for its permissions password until it is right (\(asked.count) questions)")
        } else {
            check(false, "a protected copy is made")
        }
        finish()
    }

    /// A one-page PDF filled with a CMYK color (what a PDF/A-2b copy with an sRGB output intent can't keep).
    private static func cmykPdf() -> [UInt8] {
        let content = "0 0 0 1 k 72 72 100 100 re f"
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R >>",
                       "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"]
        var pdf = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(pdf.utf8.count)
            pdf += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n" + offsets.map { String(format: "%010d 00000 n \n", $0) }.joined()
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(pdf.utf8)
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
