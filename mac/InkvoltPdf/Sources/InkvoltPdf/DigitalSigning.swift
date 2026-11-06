import AppKit
import PdfCore
import PrintCore
import UniformTypeIdentifiers

/// Digital signatures in the window (the Windows app's `DocumentTab.Signing`, `MainWindow.Signing`, `SignDialog` and the
/// Signatures pane): each document's signatures verified when it opens and after every change, shown in the sidebar's
/// Signatures pane and summed up in the notice bar; Tools › Sign Digitally… (also a click on an empty signature field):
/// the digital ID (a Keychain identity, a .p12 file imported into the keychain, or a new personal ID), reason, location,
/// the visible signature's look, a timestamp, certification; a box dragged on the page for a new visible signature;
/// the signature appended as one edit, then the signed copy saved ("name-signed.pdf"), as Windows does.
@MainActor
final class SigningState {
    /// The signatures as last verified, and as they were when the document was opened (or reloaded).
    var signatures: [SignatureInfo] = []
    var onOpen: [String: SignatureInfo] = [:]
    /// The verification running (a newer one replaces it).
    var generation = 0
    var verifying: Task<Void, Never>?
    /// A signing in progress (one at a time).
    var signing = false
    /// The summary already shown in the notice bar after the last verification.
    var shownSummary: String?
}

/// What the Sign Digitally dialog chose.
struct SignChoice {
    var id: DigitalId
    var reason: String?
    var location: String?
    var visible: Bool
    var look: SignatureLook
    var timestamp: Bool
    var timestampUrl: String
    var certify: CertificationLevel
}

extension DocumentWindowController {
    // MARK: Verifying

    var isSigned: Bool { signing.signatures.contains { $0.status != .unsigned } }

    /// Verifies the document's signatures off the main thread, then shows them; `onOpen` keeps them as the opened
    /// document's (the edit transaction then asks before an edit breaks one).
    func verifySignatures(onOpen: Bool) {
        guard let session = pdf.session else { return }
        let data = session.data, password = session.password
        signing.generation += 1
        let generation = signing.generation
        signing.verifying = Task { @MainActor in
            let found = await Task.detached { SignatureProbe.mayHaveSignatures(data) ? Signatures.verify(data, password) : [] }.value
            guard generation == self.signing.generation, !Task.isCancelled else { return }
            self.showSignatures(found, onOpen: onOpen)
            self.signing.verifying = nil
        }
    }

    /// Waits for the verification running (the self-test).
    func signaturesVerified() async { await signing.verifying?.value }

    /// Valid (or intact) when opened, broken now: the expected effect of this window's edits, not tampering.
    func brokenByEdits(_ s: SignatureInfo) -> Bool {
        guard s.status == .invalid || s.status == .disallowedChanges, let before = signing.onOpen[s.fieldName] else { return false }
        return before.status == .valid || before.status == .modifiedAfterSigning
    }

    private func appendedByEdits(_ s: SignatureInfo) -> Bool {
        s.status == .modifiedAfterSigning && signing.onOpen[s.fieldName]?.status == .valid
    }

    private func showSignatures(_ found: [SignatureInfo], onOpen: Bool) {
        // A signature our edits broke may no longer parse: keep naming its signer and certificate as they were.
        let sigs = found.map { s -> SignatureInfo in
            guard !onOpen, brokenByEdits(s), let o = signing.onOpen[s.fieldName] else { return s }
            var shown = s
            shown.signerName = s.signerName ?? o.signerName
            shown.signingTime = s.signingTime ?? o.signingTime
            if s.certificate == nil {
                shown.certificate = o.certificate
                shown.certificateTrusted = o.certificateTrusted
                shown.certificateStatus = o.certificateStatus
            }
            return shown
        }
        signing.signatures = sigs
        if onOpen {
            pdf.session?.signedOnOpen = isSigned
            signing.onOpen = Dictionary(sigs.map { ($0.fieldName, $0) }, uniquingKeysWith: { a, _ in a })
        }
        sidebar.signatures.show(sigs.map { SignatureCard(info: $0, page: $0.pageIndex >= 0 ? $0.pageIndex : nil, brokenByEdits: brokenByEdits($0)) })
        sidebar.showsSignatures = !sigs.isEmpty

        let signed = sigs.filter { $0.status != .unsigned }
        guard !signed.isEmpty else {
            signing.shownSummary = nil
            return
        }
        let text: String
        if signed.count == 1 {
            text = loc("Signed by {0} — {1}.", signed[0].signerName ?? signed[0].fieldName, shortStatus(signed[0]))
        } else if signed.allSatisfy(brokenByEdits) {
            text = loc("{0} signatures were valid when opened; your edits invalidated them.", CoreLanguage.number(signed.count))
        } else {
            let problems = signed.filter { Self.severity($0, brokenByEdits($0)) != .ok }
            let listed = problems.prefix(3).map { "\($0.signerName ?? $0.fieldName) — \(shortStatus($0))" }.joined(separator: "; ")
            let total = CoreLanguage.number(signed.count)
            text = problems.isEmpty ? loc("{0} signatures, all valid.", total)
                : problems.count == 1 ? loc("{1} signatures; {0} has a problem: {2}.", 1, total, listed)
                : loc("{1} signatures; {0} have problems: {2}.", CoreLanguage.number(problems.count), total, listed)
        }
        sidebar.signatures.summary = text
        if text != signing.shownSummary {
            signing.shownSummary = text
            notify(text + " " + loc("Details: View › Show Signatures."))
        }
    }

    private func shortStatus(_ s: SignatureInfo) -> String {
        if brokenByEdits(s) { return loc("valid when opened, invalidated by your edits") }
        switch s.status {
        case .modifiedAfterSigning where appendedByEdits(s): return loc("intact; your changes were added after signing")
        case .invalid: return loc("invalid")
        case .disallowedChanges: return loc("invalid: changed in ways the signature doesn't allow")
        case .unsupported: return loc("can't be checked")
        case .modifiedAfterSigning: return loc("modified after signing")
        default: return s.certificateTrusted ? loc("valid") : loc("certificate not trusted")
        }
    }

    enum Severity { case ok, warn, bad, none }

    static func severity(_ s: SignatureInfo, _ brokenByEdits: Bool) -> Severity {
        if brokenByEdits { return .warn }
        switch s.status {
        case .unsigned: return .none
        case .invalid, .disallowedChanges: return .bad
        case .valid where s.certificateTrusted: return .ok
        default: return .warn
        }
    }

    static func summary(_ s: SignatureInfo, _ brokenByEdits: Bool) -> String {
        if brokenByEdits {
            return loc("Valid when opened. Your edits changed the signed document, so this signature no longer verifies. Undo them, or keep the signed original by saving your changes as a copy.")
        }
        switch s.status {
        case .unsigned: return loc("Empty signature field.")
        case .invalid: return loc("Invalid: the signed content was altered, or the signature is damaged.")
        case .disallowedChanges:
            return loc("Invalid: the signed bytes are intact, but the document was later changed in ways this signature doesn't allow, so what you see may not be what was signed.")
        case .unsupported: return loc("Not checked: Inkvolt PDF can't verify this kind of signature.")
        case .modifiedAfterSigning:
            return s.certificateTrusted ? loc("The signature is valid, but the document was modified after signing.")
                : loc("The signature is intact, but the document was modified after signing and the certificate isn't trusted on this Mac.")
        case .valid:
            return s.certificateTrusted ? loc("Valid: the document hasn't changed since it was signed.")
                : loc("The signature is intact, but the certificate isn't trusted on this Mac ({0}).", s.certificateStatus)
        }
    }

    /// Goes to a signature's box on its page.
    func goToSignature(_ info: SignatureInfo) {
        guard info.pageIndex >= 0 else { return }
        go(info.pageIndex, targetY: info.rect.y)
    }

    /// A click on a signature field: an empty one is signed, a signed one shows its details.
    func signatureFieldClicked(_ name: String) {
        if let s = signing.signatures.first(where: { $0.fieldName == name }), s.status != .unsigned {
            showSignatures(nil)
            sidebar.signatures.highlight(name)
            return
        }
        signDigitally(field: name)
    }

    // MARK: Signing

    @objc func signDigitally(_ sender: Any?) { signDigitally(field: nil) }

    /// Signs: the dialog, a box dragged for a new visible signature, the signature appended, then the signed copy saved.
    func signDigitally(field: String?, scripted: SignChoice? = nil, box: (page: Int, rect: RectD)? = nil, saveTo: URL? = nil) {
        guard !signing.signing, let session = pdf.session else { return NSSound.beep() }
        if session.hasEncryption {
            info(loc("Protected PDFs can't be signed"),
                 loc("Remove the protection first (File › Remove Password Protection…), then sign: the signed copy is saved as a new file."))
            return
        }
        let widget = field.flatMap { name in form.widgets.first { $0.fieldName == name } }
        let fieldVisible = widget.map { !$0.rect.isEmpty } ?? true
        guard let choice = scripted ?? SignDialog.run(field: field, fieldVisible: fieldVisible, alreadySigned: isSigned, window: window) else { return }
        signing.signing = true
        startLongTask {
            defer { self.signing.signing = false }
            var place = box
            if field == nil && choice.visible && place == nil {
                place = await self.pickSignatureBox()
                if place == nil {
                    self.notify(loc("Signing cancelled."))
                    return
                }
            }
            var request = SignRequest(id: choice.id)
            request.fieldName = field
            request.pageIndex = place?.page ?? 0
            request.rect = choice.visible ? place?.rect : nil
            request.reason = choice.reason
            request.location = choice.location
            request.look = choice.look
            request.certify = choice.certify
            if choice.timestamp, let url = URL(string: choice.timestampUrl) { request.timestamp = Self.timestampClient(url) }
            self.notify(choice.timestamp ? loc("Signing and getting a timestamp…") : loc("Signing…"))
            guard await self.applySignature(request) else { return }
            await self.saveSigned(to: saveTo)
        }
    }

    /// Signs the document's current bytes (off the main thread: the keychain may ask for the key's password or a smart
    /// card's PIN), then commits the result as one edit.
    @discardableResult
    func applySignature(_ request: SignRequest) async -> Bool {
        guard let session = pdf.session else { return false }
        let source = session.data, password = session.password
        let signed: [UInt8]
        do {
            signed = try await Task.detached { try await Signing.sign(source, password, request) }.value
        } catch is CancellationError {
            notify(loc("Signing cancelled."))
            return false
        } catch let e as SigningError {
            info(loc("This document can't be signed"), e.message)
            return false
        } catch {
            pdf.showError(loc("The document couldn't be signed."), error)
            return false
        }
        return await editor.run(loc("Sign"), contentOnly: true) { d, _ in
            guard d == source else { throw PdfEditError(loc("The document changed while it was being signed. Sign it again.")) }
            return signed
        }
    }

    /// The signature must be the file's last change: the signed bytes are saved as they are, as a new file. Not saved:
    /// the signature is undone.
    private func saveSigned(to scripted: URL?) async {
        guard let session = pdf.session else { return }
        let base = ((session.displayName as NSString).deletingPathExtension)
        let name = base.lowercased().hasSuffix("-signed") ? base + ".pdf" : base + "-signed.pdf"
        var url = scripted
        if url == nil && !Report.isRunning, let window {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = name
            panel.message = loc("Save the signed document. It is saved as it was signed: any change after this would come after the signature.")
            if let dir = pdf.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
            let response = await panel.beginSheetModal(for: window)
            url = response == .OK ? panel.url : nil
        }
        guard let url else {
            if pdf.session?.undoLabel == loc("Sign") { pdf.undo() }
            notify(loc("Not signed: the signed copy wasn't saved."))
            return
        }
        let error = await withCheckedContinuation { (done: CheckedContinuation<Error?, Never>) in
            pdf.save(to: url, ofType: "com.adobe.pdf", for: .saveAsOperation) { done.resume(returning: $0) }
        }
        if let error {
            pdf.showError(loc("The signed copy couldn't be saved."), error)
            return
        }
        // The signed copy is the document now: edits ask before they break its signature.
        verifySignatures(onOpen: true)
    }

    /// Waits for a box dragged on a page (a click puts down one of the usual size); nil when Esc cancels.
    func pickSignatureBox() async -> (page: Int, rect: RectD)? {
        notify(loc("Drag a box on the page where the signature goes (Esc cancels)."))
        window?.makeFirstResponder(pages)
        return await withCheckedContinuation { (done: CheckedContinuation<(page: Int, rect: RectD)?, Never>) in
            pages.boxPicker = { page, rect in done.resume(returning: rect.map { (page, $0) }) }
        }
    }

    /// The RFC 3161 exchange with a timestamp server: posts the request (a hash of the signature only), returns the reply.
    nonisolated static func timestampClient(_ url: URL) -> @Sendable ([UInt8]) async throws -> [UInt8] {
        { request in
            var post = URLRequest(url: url, timeoutInterval: 30)
            post.httpMethod = "POST"
            post.setValue("application/timestamp-query", forHTTPHeaderField: "Content-Type")
            post.httpBody = Data(request)
            let (data, response) = try await URLSession.shared.data(for: post)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw SigningError(loc("the server answered {0}", http.statusCode))
            }
            return Array(data)
        }
    }

    private func info(_ title: String, _ text: String) {
        if Report.skipsDialogs {
            notify("\(title): \(text)")
            return
        }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }
}

/// A file without "/Sig" (no signature field, no /SigFlags) has no signatures to list: it isn't opened again to look.
enum SignatureProbe {
    static func mayHaveSignatures(_ data: [UInt8]) -> Bool { data.firstRange(of: Array("/Sig".utf8)) != nil }
}

/// One signature in the Signatures pane.
struct SignatureCard {
    var info: SignatureInfo
    var page: Int?
    var brokenByEdits: Bool

    var title: String { info.status == .unsigned ? loc("{0} (not signed)", info.fieldName) : info.signerName ?? info.fieldName }

    var details: String {
        var lines = [page.map { loc("Field: {0}, page {1}", info.fieldName, $0 + 1) } ?? loc("Field: {0} (invisible)", info.fieldName)]
        let full = DateFormatter()
        full.dateStyle = .full
        full.timeStyle = .medium
        if let t = info.signingTime {
            let when = full.string(from: t)
            lines.append(info.hasTimestamp ? loc("Signed: {0} (timestamped)", when) : loc("Signed: {0} (the signer's clock)", when))
        }
        if let p = info.certificationLevel {
            lines.append(p == 1 ? loc("Certified: no changes allowed") : p == 2 ? loc("Certified: filling in forms and signing allowed")
                : loc("Certified: filling in forms, signing and comments allowed"))
        }
        if let r = info.reason, !r.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(loc("Reason: {0}", r)) }
        if let l = info.location, !l.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(loc("Location: {0}", l)) }
        if let f = info.subFilter { lines.append(loc("Format: {0}", f)) }
        if info.status != .unsigned {
            lines.append(info.coversWholeDocument ? loc("Covers the whole document") : loc("Doesn't cover the whole document (changed after signing)"))
        }
        if let c = info.certificate {
            let short = DateFormatter()
            short.dateStyle = .short
            let (from, to) = (short.string(from: c.notBefore), short.string(from: c.notAfter))
            lines.append(loc("Certificate: {0}", c.subject))
            lines.append(loc("Issued by: {0}", c.issuerCommonName ?? ""))
            lines.append(info.certificateValidAtSigningTime == false ? loc("Valid: {0} to {1} (not valid at signing time)", from, to)
                : loc("Valid: {0} to {1}", from, to))
            lines.append(loc("Trust: {0}", info.certificateTrusted ? loc("trusted by this Mac") : info.certificateStatus))
            lines.append(loc("SHA-1 fingerprint: {0}", c.fingerprint))
        }
        if let d = info.detail, !d.isEmpty { lines.append(d) }
        return lines.joined(separator: "\n")
    }
}

/// The sidebar's Signatures pane: a summary, Sign Digitally…, then a card per signature field.
@MainActor
final class SignaturesPane: NSView {
    private let stack = NSStackView()
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private var cards: [(name: String, box: NSBox)] = []
    var onGo: ((SignatureInfo) -> Void)?
    var onSign: ((String?) -> Void)?

    var summary: String {
        get { summaryLabel.stringValue }
        set { summaryLabel.stringValue = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 10, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        scroll.documentView = flipped
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor), scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor), scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor), stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.topAnchor.constraint(equalTo: flipped.topAnchor), stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])
        setAccessibilityLabel(loc("Signatures"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The cards shown (the self-test reads them).
    private(set) var shown: [SignatureCard] = []

    func show(_ list: [SignatureCard]) {
        shown = list
        for v in stack.arrangedSubviews { v.removeFromSuperview() }
        cards = []
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        stack.addArrangedSubview(summaryLabel)
        summaryLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        let sign = NSButton(title: loc("Sign Digitally…"), target: self, action: #selector(signClicked))
        stack.addArrangedSubview(sign)
        for card in list { add(card) }
    }

    private func add(_ card: SignatureCard) {
        let box = NSBox()
        box.boxType = .custom
        box.cornerRadius = 6
        box.borderColor = .separatorColor
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = NSSize(width: 8, height: 8)
        let severity = DocumentWindowController.severity(card.info, card.brokenByEdits)
        let (symbol, color): (String, NSColor) = switch severity {
        case .ok: ("checkmark.seal.fill", .systemGreen)
        case .bad: ("xmark.seal.fill", .systemRed)
        case .none: ("signature", .secondaryLabelColor)
        case .warn: ("exclamationmark.triangle.fill", .systemOrange)
        }
        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = color
        let title = NSTextField(wrappingLabelWithString: card.title)
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let status = NSTextField(wrappingLabelWithString: DocumentWindowController.summary(card.info, card.brokenByEdits))
        status.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let details = NSTextField(wrappingLabelWithString: card.details)
        details.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        details.textColor = .secondaryLabelColor
        details.isSelectable = true
        details.setAccessibilityLabel(loc("Signature details"))
        var views: [NSView] = [title, status, details]
        if card.page != nil {
            let go = NSButton(title: loc("Go to Signature"), target: self, action: #selector(goClicked(_:)))
            go.identifier = NSUserInterfaceItemIdentifier(card.info.fieldName)
            go.bezelStyle = .inline
            views.append(go)
        }
        if card.info.status == .unsigned {
            let sign = NSButton(title: loc("Sign This Field…"), target: self, action: #selector(signFieldClicked(_:)))
            sign.identifier = NSUserInterfaceItemIdentifier(card.info.fieldName)
            sign.bezelStyle = .inline
            views.append(sign)
        }
        let text = NSStackView(views: views)
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        let row = NSStackView(views: [icon, text])
        row.alignment = .top
        row.spacing = 8
        box.contentView = row
        stack.addArrangedSubview(box)
        box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -20).isActive = true
        box.setAccessibilityLabel("\(card.title): \(DocumentWindowController.summary(card.info, card.brokenByEdits))")
        cards.append((card.info.fieldName, box))
    }

    /// Draws attention to one field's card.
    func highlight(_ name: String) {
        for c in cards { c.box.borderColor = c.name == name ? .controlAccentColor : .separatorColor }
        if let box = cards.first(where: { $0.name == name })?.box { box.scrollToVisible(box.bounds) }
    }

    @objc private func signClicked() { onSign?(nil) }

    @objc private func signFieldClicked(_ sender: NSButton) { onSign?(sender.identifier?.rawValue) }

    @objc private func goClicked(_ sender: NSButton) {
        guard let s = shown.first(where: { $0.info.fieldName == sender.identifier?.rawValue }) else { return }
        onGo?(s.info)
    }
}

/// The Sign Digitally dialog (the Windows app's `SignDialog`): the choices are kept in the settings for next time.
@MainActor
enum SignDialog {
    /// The reasons offered, written into the signature as the signer's words, in the interface's language as Windows'.
    static var reasons: [String] {
        [loc("I am the author of this document"), loc("I approve this document"), loc("I have reviewed this document"),
         loc("I agree to the terms defined by this document")]
    }
    static let defaultTimestampUrl = "http://timestamp.digicert.com"

    @MainActor
    private final class IdPicker: NSObject {
        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        var ids: [DigitalId] = []
        weak var window: NSWindow?

        func reload(select: Certificate? = nil) {
            ids = DigitalIds.keychain()
            popup.removeAllItems()
            if ids.isEmpty { popup.addItem(withTitle: loc("No digital ID in the keychain")) }
            for id in ids { popup.addItem(withTitle: DigitalIds.describe(id.certificate)) }
            popup.menu?.addItem(.separator())
            popup.addItem(withTitle: loc("Create a Personal Digital ID…"))
            popup.addItem(withTitle: loc("Import a Digital ID File (.p12)…"))
            if let select, let i = ids.firstIndex(where: { $0.certificate == select }) { popup.selectItem(at: i) } else { popup.selectItem(at: 0) }
            popup.target = self
            popup.action = #selector(picked)
        }

        var chosen: DigitalId? { ids.indices.contains(popup.indexOfSelectedItem) ? ids[popup.indexOfSelectedItem] : nil }

        /// Create… and Import… are the last two items (by position: their titles are in the interface's language).
        @objc private func picked() {
            let i = popup.indexOfSelectedItem, n = popup.numberOfItems
            if i == n - 2 {
                reload(select: SignDialog.createPersonalId()?.certificate)
            } else if i == n - 1 {
                reload(select: SignDialog.importId()?.certificate)
            }
        }
    }

    static func run(field: String?, fieldVisible: Bool, alreadySigned: Bool, window: NSWindow?) -> SignChoice? {
        let d = AppSettings.defaults
        let alert = NSAlert()
        alert.messageText = field.map { loc("Sign “{0}” Digitally", $0) } ?? loc("Sign Digitally")
        alert.informativeText = loc("Signs with a digital ID from your keychain, then saves the signed copy.")
        let picker = IdPicker()
        picker.reload()
        picker.popup.setAccessibilityLabel(loc("Digital ID"))
        let reason = NSComboBox()
        reason.addItems(withObjectValues: reasons)
        reason.stringValue = d.string(forKey: "SignReason") ?? ""
        reason.setAccessibilityLabel(loc("Reason"))
        let location = NSTextField(string: d.string(forKey: "SignLocation") ?? "")
        location.setAccessibilityLabel(loc("Location"))
        func check(_ title: String, _ key: String, _ fallback: Bool) -> NSButton {
            let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            b.state = (d.object(forKey: key) as? Bool ?? fallback) ? .on : .off
            return b
        }
        let visible = check(loc("Show the signature on the page"), "SignVisible", true)
        if field != nil {
            visible.state = fieldVisible ? .on : .off
            visible.isEnabled = false
        }
        let showDate = check(loc("Show the date"), "SignShowDate", true)
        let showReason = check(loc("Show the reason"), "SignShowReason", true)
        let showDn = check(loc("Show the signer's full certificate name"), "SignShowDn", false)
        let image = NSPopUpButton(frame: .zero, pullsDown: false)
        image.addItem(withTitle: loc("No image"))
        let handwritten = SignatureLibrary.shared.saved.filter { !$0.initials }
        for s in handwritten { image.addItem(withTitle: loc("Handwritten: {0}", s.name)) }
        image.selectItem(at: (handwritten.firstIndex { $0.path == d.string(forKey: "SignImagePath") } ?? -1) + 1)
        image.setAccessibilityLabel(loc("Image beside the text"))
        let timestamp = check(loc("Add a trusted timestamp"), "SignTimestamp", false)
        let tsaUrl = NSTextField(string: d.string(forKey: "TimestampUrl") ?? defaultTimestampUrl)
        tsaUrl.setAccessibilityLabel(loc("Timestamp server"))
        let certify = NSPopUpButton(frame: .zero, pullsDown: false)
        certify.addItems(withTitles: [loc("Don't certify (approval signature)"), loc("Certify: no changes allowed"), loc("Certify: form filling allowed"),
                                      loc("Certify: form filling and comments allowed")])
        if alreadySigned || field != nil {
            certify.isEnabled = false
            certify.toolTip = loc("Only the first signature can certify a document.")
        }
        certify.setAccessibilityLabel(loc("Certify"))

        for v in [picker.popup, reason, location, tsaUrl] as [NSView] { v.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        // What most signatures need in sight; the look, the timestamp and certifying behind More Options (UX review,
        // round 2: twelve rows at once).
        let form = SheetForm("SignDigitally", width: 440)
        form.row(loc("Digital ID"), picker.popup)
        if picker.ids.isEmpty { form.note(loc("Your keychain has no digital ID yet: choose Create a Personal Digital ID or Import from this menu.")) }
        form.row(loc("Reason"), reason)
        form.row(loc("Location"), location)
        form.row(nil, visible)
        form.row(loc("On the page"), showDate, advanced: true)
        form.row(nil, showReason, advanced: true)
        form.row(nil, showDn, advanced: true)
        form.row(loc("Image"), image, advanced: true)
        form.row(loc("Timestamp"), timestamp, advanced: true)
        form.row(loc("Server"), tsaUrl, advanced: true)
        form.note(loc("The server receives only a code made from the signature, never the document."), advanced: true)
        form.row(loc("Certify"), certify, advanced: true)
        form.install(in: alert)
        alert.addButton(withTitle: loc("Sign"))
        alert.addButton(withTitle: loc("Cancel"))
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            guard let id = picker.chosen else {
                problem(loc("Choose a digital ID."), loc("Create a personal digital ID, or import one from a .p12 file, if your keychain has none."))
                continue
            }
            let url = tsaUrl.stringValue.trimmingCharacters(in: .whitespaces)
            if timestamp.state == .on, URL(string: url).map({ $0.scheme == "http" || $0.scheme == "https" }) != true {
                problem(loc("Enter the timestamp server's address."), loc("It starts with http:// or https://."))
                continue
            }
            d.set(reason.stringValue, forKey: "SignReason")
            d.set(location.stringValue, forKey: "SignLocation")
            if field == nil { d.set(visible.state == .on, forKey: "SignVisible") }
            d.set(showDate.state == .on, forKey: "SignShowDate")
            d.set(showReason.state == .on, forKey: "SignShowReason")
            d.set(showDn.state == .on, forKey: "SignShowDn")
            let chosenImage = image.indexOfSelectedItem > 0 ? handwritten[image.indexOfSelectedItem - 1] : nil
            d.set(chosenImage?.path, forKey: "SignImagePath")
            d.set(timestamp.state == .on, forKey: "SignTimestamp")
            d.set(url, forKey: "TimestampUrl")
            var look = SignatureLook()
            look.showDate = showDate.state == .on
            look.showReason = showReason.state == .on
            look.showDistinguishedName = showDn.state == .on
            look.image = chosenImage.flatMap { SignatureLibrary.shared.image($0) }
            func empty(_ s: String) -> String? { s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s }
            return SignChoice(id: id, reason: empty(reason.stringValue), location: empty(location.stringValue), visible: visible.state == .on,
                              look: look, timestamp: timestamp.state == .on, timestampUrl: url,
                              certify: CertificationLevel(rawValue: max(certify.indexOfSelectedItem, 0)) ?? .none)
        }
    }

    private static func problem(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }

    /// A new self-signed personal ID (RSA 3072, five years), made in the login keychain.
    static func createPersonalId() -> DigitalId? {
        let alert = NSAlert()
        alert.messageText = loc("Create a Personal Digital ID")
        alert.informativeText = loc("A self-signed ID, kept in your login keychain (Keychain Access can export it as a backup). Others see your signatures as intact, but not trusted until they trust your ID.")
        let name = NSTextField(string: AppSettings.author)
        name.placeholderString = loc("Name")
        let email = NSTextField(string: "")
        email.placeholderString = loc("Email (optional)")
        let org = NSTextField(string: "")
        org.placeholderString = loc("Organization (optional)")
        let stack = NSStackView(views: [name, email, org])
        stack.orientation = .vertical
        for f in [name, email, org] { f.widthAnchor.constraint(equalToConstant: 300).isActive = true }
        stack.frame = NSRect(origin: .zero, size: stack.fittingSize)
        alert.accessoryView = stack
        alert.addButton(withTitle: loc("Create"))
        alert.addButton(withTitle: loc("Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            return try DigitalIds.createPersonal(name: name.stringValue, email: email.stringValue, organization: org.stringValue, inKeychain: true)
        } catch {
            problem(loc("The digital ID couldn't be made."), "\(error)")
            return nil
        }
    }

    /// A .p12 or .pfx file's ID, imported into the login keychain.
    static func importId() -> DigitalId? {
        let open = NSOpenPanel()
        open.allowedContentTypes = [UTType(filenameExtension: "p12"), UTType(filenameExtension: "pfx")].compactMap { $0 }
        open.message = loc("Choose a digital ID file (.p12 or .pfx).")
        guard open.runModal() == .OK, let url = open.url, let data = try? Data(contentsOf: url) else { return nil }
        let alert = NSAlert()
        alert.messageText = loc("The digital ID file's password")
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.setAccessibleName(loc("Password"))
        alert.accessoryView = field
        alert.addButton(withTitle: loc("Import"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        do {
            return try DigitalIds.importP12(Array(data), password: field.stringValue)
        } catch {
            problem(loc("The digital ID couldn't be imported."), "\(error)")
            return nil
        }
    }
}
