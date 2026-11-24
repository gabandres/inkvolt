import AppKit
import PrintCore

/// The password a scan preset puts on its PDF (roadmap 4.18), asked the first time it saves: typed twice
/// (`PdfEncryption.checkNew`), and kept in the keychain for the preset when the person ticks the box. Windows'
/// PasswordDialog in its new-password form.
@MainActor
enum PresetPasswordPrompt {
    /// The password and whether to keep it; nil when the person cancelled.
    static func ask(presetName: String) -> (password: String, remember: Bool)? {
        let first = NSSecureTextField(frame: NSRect(x: 0, y: 58, width: 300, height: 24))
        first.placeholderString = String(localized: "Password")
        // Named for VoiceOver: a placeholder is gone once something is typed (the accessibility audit).
        first.setAccessibilityLabel(String(localized: "Password"))
        first.cell?.setAccessibilityLabel(String(localized: "Password"))
        let again = NSSecureTextField(frame: NSRect(x: 0, y: 28, width: 300, height: 24))
        again.placeholderString = String(localized: "Type it again")
        again.setAccessibilityLabel(String(localized: "Type it again"))
        again.cell?.setAccessibilityLabel(String(localized: "Type it again"))
        let remember = NSButton(checkboxWithTitle: String(localized: "Use it for this preset from now on (kept in your keychain)"), target: nil, action: nil)
        remember.frame = NSRect(x: 0, y: 0, width: 300, height: 20)
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 84))
        for view in [first, again, remember] { fields.addSubview(view) }

        let alert = NSAlert()
        alert.messageText = String(localized: "A password for \(presetName)'s PDFs")
        let prompt = String(localized: "Whoever opens the PDF will need it. Nobody can open the file without it, Inkvolt Print included: keep it somewhere safe.")
        alert.informativeText = prompt
        alert.accessoryView = fields
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.window.initialFirstResponder = first
        var warned: String?
        while alert.runModal() == .alertFirstButtonReturn {
            switch PdfEncryption.checkNew(first.stringValue, again.stringValue) {
            case nil:
                // Preview (PDFKit) takes only an ASCII password for AES-256; Inkvolt PDF (MuPDF) and Acrobat take any. Said
                // once; Save again keeps it.
                if !first.stringValue.allSatisfy(\.isASCII) && warned != first.stringValue {
                    warned = first.stringValue
                    alert.informativeText = String(localized: "Preview can't open a PDF whose password has letters like ñ or é (Inkvolt PDF and Acrobat can). Save again to keep it, or type another.")
                        + "\n\n" + prompt
                    continue
                }
                return (first.stringValue, remember.state == .on)
            case .mismatch:
                alert.informativeText = String(localized: "The two passwords don't match.") + "\n\n" + prompt
            case .empty:
                alert.informativeText = prompt
            }
            again.stringValue = ""
        }
        return nil
    }
}
