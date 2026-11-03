import AppKit
import PdfCore

/// The self-test's scenario for E9 (`--edit`, on the synthetic text document; `--only-attachments-layers` runs it alone):
/// the Attachments pane through View › Show Attachments and its own buttons (a text file and a PDF attached as edits, the
/// PDF opened as a new document, the text file saved with the download mark, one removed, undo and redo, the saved bytes
/// read back), then a layered document made here, opened as a new document: the Layers pane through View › Show Layers,
/// a layer's check box clicked (the pages drawn from a copy with the file and its undo history untouched; printing uses
/// the same copy), a locked layer that can't be changed, Reset, Save as Default as one edit, undo. Only counts are written.
@MainActor
struct AttachmentsLayersTest {
    /// True while the scenario's own documents open (they get only its checks).
    private(set) static var isActive = false

    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0
    private let folder: URL

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-e9-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func menuItem(_ title: String) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == title { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    /// Runs a View menu item's command on a window, as choosing it does.
    private func choose(_ title: String, on target: DocumentWindowController) -> Bool {
        guard let item = menuItem(title), let action = item.action, target.validateMenuItem(item) else { return false }
        return NSApp.sendAction(action, to: target, from: item)
    }

    private func wait(_ seconds: Double = 15, _ done: () -> Bool) async -> Bool {
        for _ in 0..<Int(seconds * 20) {
            if done() { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return done()
    }

    mutating func run() async {
        lines.append("== \(name): attachments and layers")
        Self.isActive = true
        defer { Self.isActive = false }
        await attachments()
        await layers()
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: Attachments

    private mutating func attachments() async {
        let pane = controller.sidebar.attachments
        let shown = choose("Show Attachments", on: controller)
        check(shown && controller.sidebar.shownPane == .attachments && !pane.isHidden && pane.items.isEmpty && !pane.saveButton.isEnabled,
              "View › Show Attachments (⌥⌘5) shows the empty pane, Save and Remove off")

        let notes = folder.appendingPathComponent("notes.txt")
        let text = Data("Synthetic notes for the attachment pane.\n".utf8)
        try? text.write(to: notes)
        let inner = folder.appendingPathComponent("inner.pdf")
        try? Data(SyntheticPdf.make()).write(to: inner)
        let before = controller.pdf.session?.data
        let addedNotes = await controller.attach(notes, description: "Meeting notes")
        let addedPdf = await controller.attach(inner)
        check(addedNotes && addedPdf && pane.items.map(\.info.fileName).sorted() == ["inner.pdf", "notes.txt"]
              && pane.items.first { $0.info.fileName == "notes.txt" }?.info.description == "Meeting notes"
              && controller.pdf.session?.data != before,
              "two files attached as edits, listed with their description (\(pane.items.count) rows)")

        // Open: the attached PDF as a new unsaved document.
        if let pdfRow = pane.items.first(where: { $0.info.fileName == "inner.pdf" }) {
            pane.select(pdfRow.info.key)
            let others = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
            let enabled = pane.openButton.isEnabled
            pane.openButton.performClick(nil)
            let opened = await wait { NSDocumentController.shared.documents.contains { !others.contains(ObjectIdentifier($0)) } }
            let doc = NSDocumentController.shared.documents.first { !others.contains(ObjectIdentifier($0)) } as? PdfDocument
            check(enabled && opened && doc?.fileURL == nil && doc?.engine?.pageCount == PdfEngineCount.of(inner),
                  "Open makes the attached PDF a new unsaved document (\(doc?.engine?.pageCount ?? 0) pages)")
            doc?.close()
        } else {
            check(false, "the attached PDF is listed")
        }

        // An attached PDF with its own open password: asked for it (a wrong one asked again), then opened; Cancel opens none.
        let locked = folder.appendingPathComponent("locked.pdf")
        try? Data((try? PdfSecurity.protect(SyntheticPdf.make(), nil, userPassword: "selftest-inner", ownerPassword: nil)) ?? []).write(to: locked)
        if await controller.attach(locked), let row = pane.items.first(where: { $0.info.fileName == "locked.pdf" }) {
            DocumentWindowController.testAttachmentPasswords = ["selftest-wrong", "selftest-inner"]
            let asked = DocumentWindowController.attachmentPasswordAsked
            var others = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
            controller.openAttachment(row.info)
            let opened = await wait { NSDocumentController.shared.documents.contains { !others.contains(ObjectIdentifier($0)) } }
            let doc = NSDocumentController.shared.documents.first { !others.contains(ObjectIdentifier($0)) } as? PdfDocument
            let twice = DocumentWindowController.attachmentPasswordAsked - asked == 2
            let pages = doc?.engine?.pageCount ?? 0
            doc?.close()
            others = Set(NSDocumentController.shared.documents.map(ObjectIdentifier.init))
            DocumentWindowController.testAttachmentPasswords = []
            let before = DocumentWindowController.attachmentPasswordAsked
            controller.openAttachment(row.info)
            _ = await wait(2) { DocumentWindowController.attachmentPasswordAsked > before }
            let none = !NSDocumentController.shared.documents.contains { !others.contains(ObjectIdentifier($0)) }
            check(opened && twice && pages == PdfEngineCount.of(inner) && none,
                  "an attached PDF with its own password: asked, a wrong one asked again, then opened (\(pages) pages); cancelled: none opened")
            controller.pdf.undo()
            _ = await wait { pane.items.count == 2 }
        } else {
            check(false, "the protected PDF is attached and listed")
        }

        // Save…: the text file written out, marked as downloaded.
        if let noteRow = pane.items.first(where: { $0.info.fileName == "notes.txt" }) {
            pane.select(noteRow.info.key)
            let target = folder.appendingPathComponent("saved notes.txt")
            controller.saveAttachment(noteRow.info, to: target)
            let saved = await wait { controller.lastSavedAttachment == target }
            let quarantined = (try? target.resourceValues(forKeys: [.quarantinePropertiesKey]))?.quarantineProperties != nil
            check(saved && (try? Data(contentsOf: target)) == text && quarantined && !pane.openButton.isEnabled,
                  "Save writes the attachment's bytes, marked as downloaded (quarantine); Open is off for a text file")

            // Remove (the button), undo, redo.
            let edits = controller.editor.finishedEdits
            pane.removeButton.performClick(nil)
            let removed = await wait { controller.editor.finishedEdits > edits }
            check(removed && pane.items.map(\.info.fileName) == ["inner.pdf"], "Remove takes it out as one edit")
            controller.pdf.undo()
            let back = await wait { pane.items.count == 2 }
            controller.pdf.redo()
            let again = await wait { pane.items.count == 1 }
            check(back && again, "undo brings it back, redo removes it again")
        } else {
            check(false, "the text file is listed")
        }

        // The saved bytes read back.
        if let data = controller.pdf.session?.data {
            let file = folder.appendingPathComponent("saved.pdf")
            try? Data(data).write(to: file)
            let read = (try? Attachments.list([UInt8](Data(contentsOf: file)), controller.pdf.session?.password)) ?? []
            check(read.map(\.fileName) == ["inner.pdf"] && read.first?.mimeType == "application/pdf",
                  "the document's bytes, saved and read back, hold the attachment left")
        }

        // A name from the file can't climb out of the folder it's saved in.
        check(DocumentWindowController.safeFileName("../../evil/..") == "attachment" && DocumentWindowController.safeFileName(#"C:\a\b:c.txt"#) == "b_c.txt",
              "names from the file are made safe for saving (no folders, no colons, never empty)")
    }

    // MARK: Layers

    /// Blue (on) in a labeled group, Red (off), Green (on, locked): squares at x 100, 250 and 400.
    static func layeredPdf() -> [UInt8] {
        let content = "/OC /L1 BDC 0 0 1 rg 100 600 100 100 re f EMC /OC /L2 BDC 1 0 0 rg 250 600 100 100 re f EMC /OC /L3 BDC 0 0.6 0 rg 400 600 100 100 re f EMC"
        let objects = [
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R 7 0 R] /D << /ON [5 0 R 7 0 R] /OFF [6 0 R] /Locked [7 0 R] /Order [[(Group) 5 0 R] 6 0 R 7 0 R] >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Properties << /L1 5 0 R /L2 6 0 R /L3 7 0 R >> >> >>",
            "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream",
            "<< /Type /OCG /Name (Blue) >>",
            "<< /Type /OCG /Name (Red) >>",
            "<< /Type /OCG /Name (Green) >>",
        ]
        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.count)
            out += Array("\(i + 1) 0 obj\n\(o)\nendobj\n".utf8)
        }
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        let xref = out.count
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }

    /// The fraction of dark pixels in a square of page 1 (page space, origin at the bottom left), as `engine` draws it.
    private static func ink(_ engine: PdfEngine?, x: Double) -> Double {
        guard let engine, let img = try? engine.render(0, scale: 1, region: RectD(x, 92, 100, 100)) else { return -1 }
        var dark = 0
        var i = 0
        while i + 2 < img.pixels.count {
            if Int(img.pixels[i]) + Int(img.pixels[i + 1]) + Int(img.pixels[i + 2]) < 600 { dark += 1 }
            i += 3
        }
        return Double(dark) / Double(max(1, img.width * img.height))
    }

    private mutating func layers() async {
        check(!controller.sidebar.showsLayers && menuItem("Show Layers") != nil, "a document without layers: the Layers segment is off")
        guard let doc = NewDocuments.open(Self.layeredPdf(), name: "Layered"),
              let window = doc.windowControllers.first as? DocumentWindowController else {
            return check(false, "the layered document opens")
        }
        defer { doc.close() }
        let pane = window.sidebar.layers
        let shown = choose("Show Layers", on: window)
        let rows = pane.roots
        check(shown && window.sidebar.showsLayers && window.sidebar.shownPane == .layers && rows.count == 3 && rows[0].label == "Group"
              && rows[0].children.first?.layer?.name == "Blue" && !pane.resetButton.isEnabled,
              "View › Show Layers (⌥⌘6) shows the author's order: the Group with Blue, then Red and Green")
        let green = pane.checkBox("Green")
        check(green != nil && green?.isEnabled == false && green?.state == .on, "the locked layer (Green) can't be changed")

        let original = window.pdf.session?.data
        let blueBefore = Self.ink(window.engine, x: 100), redBefore = Self.ink(window.engine, x: 250)
        let applied = window.layersApplied
        pane.checkBox("Blue")?.performClick(nil)
        pane.checkBox("Red")?.performClick(nil)
        let drawn = await wait { window.layersApplied > applied && window.layerEngine != nil }
        let blue = Self.ink(window.layerEngine, x: 100), red = Self.ink(window.layerEngine, x: 250), greenInk = Self.ink(window.layerEngine, x: 400)
        check(drawn && blueBefore > 0.9 && redBefore < 0.01 && blue < 0.01 && red > 0.9 && greenInk > 0.9,
              String(format: "Blue hidden and Red shown: drawn from a copy (blue %.2f → %.2f, red %.2f → %.2f, green %.2f)", blueBefore, blue, redBefore, red, greenInk))
        check(window.pdf.session?.data == original && window.pdf.session?.canUndo == false && pane.resetButton.isEnabled && pane.saveButton.isEnabled,
              "the file and its undo history are untouched; Reset and Save as Default turn on")
        let printed = (window.printOperation(NSPrintInfo()).view as? PrintSheetView)?.engine
        check(printed != nil && printed === window.layerEngine, "printing uses the layers shown")

        pane.resetButton.performClick(nil)
        let reset = await wait { window.layerEngine == nil }
        check(reset && pane.checkBox("Blue")?.state == .on && pane.checkBox("Red")?.state == .off && !pane.resetButton.isEnabled,
              "Reset shows the document's own layers again")

        pane.checkBox("Red")?.performClick(nil)
        let edits = window.editor.finishedEdits
        pane.saveButton.performClick(nil)
        let saved = await wait { window.editor.finishedEdits > edits }
        let defaults = (try? Layers.list(window.pdf.session?.data ?? [], nil)) ?? []
        check(saved && defaults.first { $0.name == "Red" }?.defaultVisible == true && window.layerChoice.isEmpty && window.pdf.session?.canUndo == true,
              "Save as Default makes Red visible in the file, as one edit")
        window.pdf.undo()
        let undone = await wait { ((try? Layers.list(window.pdf.session?.data ?? [], nil)) ?? []).first { $0.name == "Red" }?.defaultVisible == false }
        check(undone && pane.checkBox("Red")?.state == .off, "undo restores the saved default")
    }
}
