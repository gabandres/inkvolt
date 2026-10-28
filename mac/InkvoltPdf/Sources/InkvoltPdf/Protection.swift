import AppKit
import PdfCore

/// Passwords (the Windows app's `SecurityActions`): File › Protect with Password… (Change Password Protection… on a
/// protected file) encrypts the document with an open password, a permissions password and what it restricts (AES-256,
/// or AES-128 for old readers); File › Remove Password Protection… takes the encryption off. Both are one edit that
/// commits the passwords the result opens with, so undo brings the old protection back; the file on disk changes on Save.
extension DocumentWindowController {
    /// How the document is protected now (nil when it can't be read).
    var currentSecurity: SecurityInfo? {
        guard let s = pdf.session else { return nil }
        return try? PdfSecurity.readSecurity(s.data, s.openPassword ?? s.password)
    }

    @objc func protectDocument(_ sender: Any?) {
        guard let window, protectSheet == nil else { return }
        let current = currentSecurity
        let sheet = ProtectSheet(current: current)
        protectSheet = sheet
        sheet.done = { [weak self] choice in
            guard let self else { return }
            self.protectSheet = nil
            if let choice { Task { await self.protect(choice) } }
        }
        if let panel = sheet.window { window.beginSheet(panel) }
    }

    @objc func removeProtection(_ sender: Any?) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Remove password protection?"
        alert.informativeText = "The saved file opens without a password, and anyone can print, copy and change it."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Remove Protection")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                Task { await self.removeProtectionNow() }
            }
        }
    }

    /// Encrypts with `choice` (one undo step); the session then opens the document with the new passwords.
    @discardableResult
    func protect(_ choice: ProtectionChoice) async -> Bool {
        let encrypted = currentSecurity?.isEncrypted == true
        let (user, owner, permissions, method) = (choice.userPassword, choice.ownerPassword, choice.permissions, choice.method)
        let ok = await editor.run(encrypted ? "Change password protection" : "Protect with password",
                                  newPasswords: (owner ?? user, user)) { d, pw in
            try PdfSecurity.protect(d, pw, userPassword: user, ownerPassword: owner, permissions: permissions, method: method)
        }
        if ok {
            notify(user != nil ? "Protected: the saved file needs its password to open. Save to keep it." : "Restrictions set. Save to keep them.",
                   canUndo: true)
        }
        return ok
    }

    @discardableResult
    func removeProtectionNow() async -> Bool {
        let ok = await editor.run("Remove password protection", newPasswords: (nil, nil)) { d, pw in try PdfSecurity.unprotect(d, pw) }
        if ok { notify("Protection removed. Save to keep the change.", canUndo: true) }
        return ok
    }
}

/// Passwords and permissions chosen in the Protect sheet (nil passwords: not set). Never printed.
struct ProtectionChoice: Sendable, CustomStringConvertible {
    var userPassword: String?
    var ownerPassword: String?
    var permissions: PdfPermissions
    var method: EncryptionMethod
    var description: String { "Protection" }
}

/// The Protect with Password sheet: an open password (typed twice, its strength shown), restrictions with their
/// permissions password, and the encryption. Protect checks the answers and says what is wrong in the sheet.
@MainActor
final class ProtectSheet: NSWindowController {
    let needOpen = NSButton(checkboxWithTitle: "Require a password to open the document", target: nil, action: nil)
    let openField = NSSecureTextField()
    let openConfirm = NSSecureTextField()
    private let strength = NSTextField(labelWithString: "")
    let restrict = NSButton(checkboxWithTitle: "Restrict printing, copying and editing", target: nil, action: nil)
    let ownerField = NSSecureTextField()
    let ownerConfirm = NSSecureTextField()
    let printing = NSPopUpButton(frame: .zero, pullsDown: false)
    let copy = NSButton(checkboxWithTitle: "Copy text and images", target: nil, action: nil)
    let modify = NSButton(checkboxWithTitle: "Change the document", target: nil, action: nil)
    let annotate = NSButton(checkboxWithTitle: "Add comments", target: nil, action: nil)
    let fill = NSButton(checkboxWithTitle: "Fill in form fields and sign", target: nil, action: nil)
    let assemble = NSButton(checkboxWithTitle: "Insert, delete and rotate pages", target: nil, action: nil)
    let method = NSPopUpButton(frame: .zero, pullsDown: false)
    let problem = NSTextField(labelWithString: "")
    private var openRows: [NSView] = []
    private var restrictRows: [NSView] = []
    var done: ((ProtectionChoice?) -> Void)?

    init(current: SecurityInfo?) {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 420), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: panel)
        let encrypted = current?.isEncrypted == true
        let perms = encrypted ? current?.permissions ?? .all : .all
        let title = NSTextField(labelWithString: encrypted ? "Change Password Protection" : "Protect with Password")
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let note = NSTextField(wrappingLabelWithString: encrypted
            ? "Set new passwords and permissions. The old passwords stop working once you save."
            : "Encrypts the document. Keep the passwords somewhere safe: a forgotten open password can't be recovered.")
        note.preferredMaxLayoutWidth = 440
        needOpen.state = current?.requiresOpenPassword == true ? .on : .off
        restrict.state = perms.isUnrestricted ? .off : .on
        for f in [openField, openConfirm, ownerField, ownerConfirm] { f.widthAnchor.constraint(equalToConstant: 220).isActive = true }
        openField.setAccessibilityLabel("Open password")
        openConfirm.setAccessibilityLabel("Confirm open password")
        ownerField.setAccessibilityLabel("Permissions password")
        ownerConfirm.setAccessibilityLabel("Confirm permissions password")
        openField.target = self
        openField.action = #selector(rate)
        NotificationCenter.default.addObserver(self, selector: #selector(rate), name: NSControl.textDidChangeNotification, object: openField)
        strength.textColor = .secondaryLabelColor
        strength.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        printing.addItems(withTitles: ["High resolution", "Low resolution (150 dpi)", "Not allowed"])
        printing.selectItem(at: perms.print == .highResolution ? 0 : perms.print == .lowResolution ? 1 : 2)
        printing.setAccessibilityLabel("Printing")
        copy.state = perms.copy ? .on : .off
        modify.state = perms.modify ? .on : .off
        annotate.state = perms.annotate ? .on : .off
        fill.state = perms.fillForms ? .on : .off
        assemble.state = perms.assemble ? .on : .off
        method.addItems(withTitles: ["AES-256 (Acrobat X and later, recommended)", "AES-128 (for Acrobat 7-9 and older readers)"])
        method.selectItem(at: current?.method == .aes128 ? 1 : 0)
        method.setAccessibilityLabel("Encryption")
        problem.textColor = .systemRed
        problem.lineBreakMode = .byWordWrapping
        problem.preferredMaxLayoutWidth = 440
        for b in [needOpen, restrict] {
            b.target = self
            b.action = #selector(sync)
        }

        func row(_ label: String, _ control: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: label)
            l.alignment = .right
            l.widthAnchor.constraint(equalToConstant: 160).isActive = true
            return NSStackView(views: [l, control])
        }
        let openRow = row("Open password:", openField), openConfirmRow = row("Confirm:", openConfirm)
        let ownerRow = row("Permissions password:", ownerField), ownerConfirmRow = row("Confirm:", ownerConfirm)
        let printRow = row("Printing:", printing)
        let allow = NSStackView(views: [copy, modify, annotate, fill, assemble])
        allow.orientation = .vertical
        allow.alignment = .leading
        allow.edgeInsets = NSEdgeInsets(top: 0, left: 168, bottom: 0, right: 0)
        let strengthRow = NSStackView(views: [strength])
        strengthRow.edgeInsets = NSEdgeInsets(top: 0, left: 168, bottom: 0, right: 0)
        openRows = [openRow, openConfirmRow, strengthRow]
        restrictRows = [ownerRow, ownerConfirmRow, printRow, allow]
        let protect = NSButton(title: "Protect", target: self, action: #selector(protectClicked))
        protect.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, protect])
        let stack = NSStackView(views: [title, note, needOpen] + openRows + [restrict] + restrictRows + [row("Encryption:", method), problem, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
        panel.initialFirstResponder = needOpen
        sync()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    @objc private func sync() {
        for v in openRows { v.isHidden = needOpen.state != .on }
        for v in restrictRows { v.isHidden = restrict.state != .on }
        window?.layoutIfNeeded()
        if let window, let content = window.contentView { window.setContentSize(content.fittingSize) }
    }

    @objc private func rate() {
        let r = PasswordStrength.rate(openField.stringValue)
        strength.stringValue = r.label.isEmpty ? "" : "Strength: \(r.label)"
    }

    /// What is wrong with the answers (nil when Protect can go ahead).
    func validate() -> String? {
        let wantOpen = needOpen.state == .on, wantRestrict = restrict.state == .on
        if !wantOpen && !wantRestrict { return "Choose an open password, restrictions, or both." }
        if wantOpen {
            if openField.stringValue.isEmpty { return "Enter the open password." }
            if openField.stringValue != openConfirm.stringValue { return "The open passwords don't match." }
        }
        if wantRestrict {
            if ownerField.stringValue.isEmpty { return "Enter a permissions password: it is needed to lift the restrictions later." }
            if ownerField.stringValue != ownerConfirm.stringValue { return "The permissions passwords don't match." }
            if wantOpen && ownerField.stringValue == openField.stringValue {
                return "Use a permissions password different from the open password, or anyone who can open the document could lift the restrictions."
            }
        }
        // MuPDF's write options are separated by commas.
        if (wantOpen && openField.stringValue.contains(",")) || (wantRestrict && ownerField.stringValue.contains(",")) {
            return "Inkvolt PDF for Mac can't use a comma in a password. Choose one without a comma."
        }
        return nil
    }

    /// The answers as a choice (call after `validate`).
    func choice() -> ProtectionChoice {
        let restricted = restrict.state == .on
        let permissions = restricted
            ? PdfPermissions(print: [PrintPermission.highResolution, .lowResolution, .none][max(printing.indexOfSelectedItem, 0)],
                             copy: copy.state == .on, modify: modify.state == .on, annotate: annotate.state == .on,
                             fillForms: fill.state == .on, assemble: assemble.state == .on)
            : PdfPermissions.all
        return ProtectionChoice(userPassword: needOpen.state == .on ? openField.stringValue : nil,
                                ownerPassword: restricted ? ownerField.stringValue : nil,
                                permissions: permissions, method: method.indexOfSelectedItem == 1 ? .aes128 : .aes256)
    }

    @objc func protectClicked() {
        if let wrong = validate() {
            problem.stringValue = wrong
            NSAccessibility.post(element: problem, notification: .announcementRequested, userInfo: [.announcement: wrong])
            sync()
            return
        }
        finish(choice())
    }

    @objc func cancelClicked() { finish(nil) }

    private func finish(_ choice: ProtectionChoice?) {
        NotificationCenter.default.removeObserver(self)
        if let panel = window { panel.sheetParent?.endSheet(panel) }
        done?(choice)
    }
}
