import AppKit
import PdfCore

/// The self-test's scenario for E2 (`--edit`, after `RedactTest`, on the synthetic text document): a box dragged for a
/// new visible signature through the page view's own mouse handling, then Sign Digitally through the window's own flow
/// with a personal ID made in memory (a Keychain identity would ask for its password, which nobody can answer over SSH),
/// the signed copy saved into a temporary folder and verified there; the Signatures pane and the notice bar; a comment
/// after signing (the signature stays intact) and a page deletion (it would break the signature: the question is
/// answered no). Only counts and statuses are written.
@MainActor
struct SignTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0
    private let folder: String

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
        folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-sign-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
    }

    private var pages: PagesView { controller.pages }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func event(_ type: NSEvent.EventType, _ p: NSPoint) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: pages.convert(p, to: nil), modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                           windowNumber: controller.window?.windowNumber ?? 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func settle() async {
        await controller.longTask?.value
        await pages.pendingEdit?.value
        await controller.signaturesVerified()
        try? await Task.sleep(for: .milliseconds(60))
        await controller.signaturesVerified()
    }

    mutating func run() async {
        guard let session = controller.pdf.session else {
            Report.write("== \(name): digital signatures\nRESULT: FAIL (no session)")
            return
        }
        lines.append("== \(name): digital signatures (\(controller.engine.pageCount) pages)")
        controller.closePopovers()
        controller.setZoom(1)
        controller.go(0)
        await settle()
        check(controller.signing.signatures.isEmpty && !session.signedOnOpen, "an unsigned document lists no signatures")

        // The box picker, through the page view's mouse handling.
        var picked: (page: Int, rect: RectD)?
        pages.boxPicker = { page, rect in picked = rect.map { (page, $0) } }
        let r = pages.pageRects[0]
        let from = pages.viewPoint(PointD(300, 600), r), to = pages.viewPoint(PointD(520, 660), r)
        pages.mouseDown(with: event(.leftMouseDown, from))
        pages.mouseDragged(with: event(.leftMouseDragged, to))
        pages.mouseUp(with: event(.leftMouseUp, to))
        let box = picked
        check(box.map { $0.page == 0 && abs($0.rect.width - 220) < 1 && abs($0.rect.height - 60) < 1 } == true && pages.boxPicker == nil,
              "a box dragged on page 1 for the signature (220 x 60)")

        let id: DigitalId
        do {
            id = try DigitalIds.createPersonal(name: "Inkvolt Self Test", email: nil, organization: nil, years: 1, inKeychain: false)
        } catch {
            check(false, "a personal ID made in memory: \(error)")
            return finish()
        }
        var look = SignatureLook()
        look.showDistinguishedName = true
        let choice = SignChoice(id: id, reason: "I have reviewed this document", location: nil, visible: true, look: look, timestamp: false,
                                timestampUrl: SignDialog.defaultTimestampUrl, certify: .none)
        let url = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("signed.pdf"))
        let before = session.data.count
        controller.signDigitally(field: nil, scripted: choice, box: box ?? (0, RectD(300, 600, 220, 60)), saveTo: url)
        await settle()
        let saved = (try? Data(contentsOf: url)).map { Array($0) } ?? []
        let onDisk = Signatures.verify(saved)
        check(onDisk.count == 1 && onDisk[0].status == .valid && onDisk[0].signerName == "Inkvolt Self Test" && onDisk[0].pageIndex == 0,
              "Sign Digitally: the signed copy saved and verified (\(onDisk.map { "\($0.status)" }.joined(separator: ", ")))")
        check(saved.count > before && controller.pdf.session?.data == saved, "the signature appended to the document, the window shows the signed copy")
        check(onDisk.first.map { abs($0.rect.width - 220) < 1 && abs($0.rect.height - 60) < 1 } == true, "the visible signature in the box dragged")
        let cards = controller.sidebar.signatures.shown
        check(cards.count == 1 && controller.sidebar.showsSignatures && controller.pdf.session?.signedOnOpen == true,
              "the Signatures pane lists it, and edits now ask before breaking it")
        check(!controller.noticeBar.isHidden, "the notice bar sums up the signature")
        controller.showSignatures(nil)
        check(controller.sidebar.shownSegment == 3, "View › Show Signatures shows the pane")

        // A comment is appended: the signature stays intact.
        let noted = await controller.editor.run("Add note") { d, pw in try Annotations.addNote(d, pw, 0, 72, 72, "Checked", author: "Self Test") }
        await settle()
        let afterNote = controller.signing.signatures.first
        check(noted && afterNote?.status == .modifiedAfterSigning, "a comment after signing keeps the signature intact (\(afterNote.map { "\($0.status)" } ?? "none"))")

        // Deleting a page would break it: the question is answered no in the self-test, nothing changes.
        if controller.engine.pageCount > 1, let current = controller.pdf.session?.data {
            let deleted = await controller.editor.run("Delete pages") { d, pw in try PageEditor.delete(d, pw, [1]) }
            check(!deleted && controller.editor.lastOutcome == .declined && controller.pdf.session?.data == current,
                  "deleting a signed page asks first (declined: nothing changed)")
        }
        finish()
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
