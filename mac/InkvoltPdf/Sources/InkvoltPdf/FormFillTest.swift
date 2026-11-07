import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for filling real forms' traits (`--edit`, once; `--only-form-fill` runs it alone), on forms made
/// here: masked fields (AFSpecial SSN, phone and ZIP+4 with a MaxLen of just their digits) typed in the page view's own
/// editor, one character at a time through the keystroke script, Tab moving on after each fill and keeping the order; and a
/// form encrypted as USCIS's are (no open password, an owner password, filling allowed), filled and saved without the owner
/// password, the protection unchanged. Only values it made are written.
@MainActor
struct FormFillTest {
    /// Running: the forms it opens get no self-test of their own.
    private(set) static var isActive = false
    private var lines: [String] = []
    private var failures = 0

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[form-fill] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    /// Objects 1-4 (catalog, pages, page, Helvetica), then the fields as text fields from 5.
    private static func form(_ fields: [(name: String, extra: String, y: Int)]) -> [UInt8] {
        let refs = fields.indices.map { "\(5 + $0) 0 R" }.joined(separator: " ")
        var objects = [
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [\(refs)] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.28 841.89] /Annots [\(refs)] /Resources << >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]
        for f in fields {
            objects.append("<< /Type /Annot /Subtype /Widget /FT /Tx /T (\(f.name)) /Rect [72 \(f.y) 300 \(f.y + 20)] /DA (/Helv 12 Tf 0 g) /F 4 /P 3 0 R \(f.extra) >>")
        }
        var out = "%PDF-1.7\n"
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.utf8.count)
            out += "\(i + 1) 0 obj\n\(o)\nendobj\n"
        }
        let xref = out.utf8.count
        out += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { out += String(format: "%010d 00000 n \n", o) }
        out += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return Array(out.utf8)
    }

    private static func special(_ psf: Int, _ maxLength: Int) -> String {
        "/MaxLen \(maxLength) /AA << /K << /S /JavaScript /JS (AFSpecial_Keystroke\\(\(psf)\\);) >> /F << /S /JavaScript /JS (AFSpecial_Format\\(\(psf)\\);) >> >>"
    }

    /// The form opened and ready for typing: its page placed, and the window having given the page view the keyboard (it
    /// does so just after showing, which would close an editor opened sooner).
    private func open(_ bytes: [UInt8], _ name: String) async -> (document: PdfDocument, controller: DocumentWindowController)? {
        guard let document = NewDocuments.open(bytes, name: name),
              let controller = document.windowControllers.first as? DocumentWindowController else { return nil }
        controller.form.reload()
        for _ in 0..<250 where controller.pages.pageRects.isEmpty || controller.window?.firstResponder !== controller.pages {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return (document, controller)
    }

    private func settle(_ c: DocumentWindowController) async {
        for _ in 0..<3 {
            await c.pages.pendingEdit?.value
            await c.form.settle()
            await c.content.settle()
        }
    }

    /// Types `text` into the open editor one character at a time, as the keyboard would.
    private func type(_ form: FormFiller, _ text: String) {
        guard let field = form.editorView else { return }
        for ch in text {
            field.stringValue += String(ch)
            form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        }
    }

    mutating func run() async {
        Self.isActive = true
        defer { Self.isActive = false }
        lines.append("== Filling forms: masked fields, an encrypted form that allows filling")
        await masked()
        await encrypted()
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }

    private mutating func masked() async {
        let cases: [(name: String, psf: Int, length: Int, y: Int, typed: String, shown: String)] = [
            ("SSN", 3, 9, 760, "123456789", "123-45-6789"),
            ("Phone", 2, 10, 720, "7875551234", "(787) 555-1234"),
            ("ZipPlus4", 1, 9, 680, "009011234", "00901-1234"),
            ("Zip", 0, 5, 640, "00901", "00901"),
        ]
        let bytes = Self.form(cases.map { ($0.name, Self.special($0.psf, $0.length), $0.y) })
        guard let (document, c) = await open(bytes, "masked.pdf") else { return check(false, "masked form: opened") }
        defer { document.close() }
        guard let form = c.form else { return check(false, "masked form: filler") }
        let order = form.fillable.map(\.fieldName)
        check(order == cases.map(\.name), "masked form: Tab order \(order.joined(separator: ", "))")
        for (i, f) in cases.enumerated() {
            guard let w = form.widgets.first(where: { $0.fieldName == f.name }) else {
                check(false, "\(f.name): no widget")
                continue
            }
            form.focus(w, open: true)
            await form.keystrokesReady()
            type(form, f.typed)
            let held = form.editorView?.stringValue ?? "-"
            form.focusNext(1) // commits, moves on
            await settle(c)
            let after = form.widgets.first { $0.fieldName == f.name }
            check(held == f.typed, "\(f.name): typing \(f.typed) holds \(held) within MaxLen \(f.length)")
            check(after?.value == f.typed && after?.displayValue == f.shown, "\(f.name): stored \(after?.value ?? "-"), shows \(after?.displayValue ?? "-")")
            let next = order[(i + 1) % order.count]
            check(form.focused?.fieldName == next, "Tab after the fill goes to \(next): \(form.focused?.fieldName ?? "-")")
        }
        form.cancelEditor()
        check(form.fillable.map(\.fieldName) == order, "the Tab order is the same after the fills")
        check(form.lastResult?.rejected.isEmpty != false, "no value refused")
    }

    private mutating func encrypted() async {
        let plain = Self.form([("Nombre", "/V (Viejo)", 760), ("SSN", Self.special(3, 9), 720)])
        let allowed = PdfPermissions(print: .highResolution, copy: true, modify: false, annotate: false, fillForms: true, assemble: false)
        guard let protected = try? PdfSecurity.protect(plain, nil, userPassword: "", ownerPassword: "form-test-owner", permissions: allowed),
              let before = try? PdfSecurity.readSecurity(protected, nil),
              let (document, c) = await open(protected, "encrypted.pdf"), let form = c.form else {
            return check(false, "encrypted form: opened")
        }
        defer { document.close() }
        check(before.isEncrypted && !before.requiresOpenPassword && before.permissions.fillForms && !before.permissions.modify,
              "encrypted form: \(before.summary)")
        guard let name = form.widgets.first(where: { $0.fieldName == "Nombre" }) else { return check(false, "encrypted form: no widget") }
        form.focus(name, open: true)
        form.editorView?.stringValue = ""
        form.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: form.editorView))
        type(form, "Ada Lovelace")
        form.focusNext(1)
        await form.keystrokesReady()
        type(form, "123456789")
        form.focusNext(1)
        await settle(c)
        form.cancelEditor()
        check(c.editor.lastOutcome == .done, "filled without the owner password: \(String(describing: c.editor.lastOutcome))")
        check(form.value("Nombre") == "Ada Lovelace" && form.value("SSN") == "123456789", "the values are in the fields")

        let folder = (NSTemporaryDirectory() as NSString).appendingPathComponent("InkvoltPdfFormFill-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: folder) }
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: (folder as NSString).appendingPathComponent("saved.pdf"))
        let error = await withCheckedContinuation { (done: CheckedContinuation<String?, Never>) in
            document.save(to: url, ofType: "com.adobe.pdf", for: .saveAsOperation) { error in
                done.resume(returning: error.map { "\($0.localizedDescription)" })
            }
        }
        check(error == nil, "saved: \(error ?? "no error")")
        guard let saved = (try? Data(contentsOf: url)).map({ [UInt8]($0) }) else { return check(false, "saved file read back") }
        let widgets = (try? FormEditor.read(saved, nil)) ?? []
        check(widgets.first { $0.fieldName == "Nombre" }?.value == "Ada Lovelace" && widgets.first { $0.fieldName == "SSN" }?.displayValue == "123-45-6789",
              "read back from the saved file")
        check(saved.starts(with: protected), "the saved file is the original bytes and an update")
        check((try? PdfSecurity.readSecurity(saved, nil)) == before, "the same protection: \((try? PdfSecurity.readSecurity(saved, nil))?.summary ?? "-")")
        check(saved.firstRange(of: Array("Ada Lovelace".utf8)) == nil, "the value isn't in the file in the clear")
    }
}
