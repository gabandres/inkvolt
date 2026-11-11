import AppKit
import PdfCore
import PrintCore

/// Long-term validation in the window (roadmap 3.4; the Windows app's `MainWindow.Signing` and `LtvDialogs`): Fill & Sign ›
/// Add Verification Information… stores what it takes to check the signatures years from now (Pro), Check Signatures
/// Online… asks whether their certificates were revoked without changing the file (free). Before anything goes online a
/// window lists every address that would be asked, what it gets, and what won't be asked and why; what was done is told
/// at the top of the Signatures pane afterwards. Going online happens only through `LtvClient`.
extension DocumentWindowController {
    /// The client long-term validation goes online through: it refuses this Mac and the local network, whatever a file names.
    nonisolated static func newLtvClient() -> LtvClient { LtvClient() }

    @objc func addVerificationInformation(_ sender: Any?) { addVerificationInformation(scripted: nil) }

    /// Add Verification Information: shows what would be contacted, asks, stores the answers as an update after the
    /// signatures, then saves the copy ("name-ltv.pdf"), as signing does. Whatever fails, nothing is written.
    /// `scripted`: the self-test's answer to the window (the timestamp server, or "" for none) and where the copy goes.
    func addVerificationInformation(scripted: (timestampUrl: String, saveTo: URL)?) {
        guard !signing.signing, let session = pdf.session else { return NSSound.beep() }
        guard Pro.allows(.longTermValidation) else {
            ProWindowController.show(feature: .longTermValidation)
            return
        }
        if session.hasEncryption {
            info(loc("Protected PDFs can't take long-term data"),
                 loc("An update can't be appended to an encrypted PDF without breaking its signatures, so nothing can be added to this file."))
            return
        }
        signing.signing = true
        let data = session.data, password = session.password, repaired = session.repairedLength
        startLongTask {
            defer { self.signing.signing = false }
            let client = Self.newLtvClient()
            let plan = await Task.detached { Ltv.plan(data, password, client: client, repairedLength: repaired) }.value
            guard let url = scripted?.timestampUrl ?? LtvDialogs.confirmAdd(plan, client, window: self.window) else { return }
            self.notify(loc("Getting the long-term data…"))
            let result: LtvResult
            do {
                let stamp = url.isEmpty ? nil : client.timestampSender(url)
                result = try await Task.detached { try await Ltv.addVerification(data, password, client, documentTimestamp: stamp, repairedLength: repaired) }.value
            } catch let e as SigningError {
                self.info(loc("Long-term data wasn't added"), e.message)
                return
            } catch {
                self.pdf.showError(loc("Long-term data wasn't added"), error)
                return
            }
            // Committed as one edit, on the bytes it was made from.
            let done = await self.editor.run(loc("Add Verification Information"), contentOnly: true) { d, _ in
                guard d == data else { throw PdfEditError(loc("The document changed while the long-term data was being added. Add it again.")) }
                return result.pdf
            }
            guard done else { return }
            if !result.changed {
                // Same bytes back: nothing to keep in the undo list or to save.
                if self.pdf.session?.undoLabel == loc("Add Verification Information") { self.pdf.undo() }
                self.showLongTermOutcome(loc("The file already holds everything that could be added. It wasn't changed."),
                                         LtvDialogs.describe(result.certificates, result.contacts))
                return
            }
            // The data must be the file's last change for the signatures to read as they do: save the bytes as they are.
            let base = (session.displayName as NSString).deletingPathExtension
            guard await self.saveCopy(base.lowercased().hasSuffix("-ltv") ? base + ".pdf" : base + "-ltv.pdf", to: scripted?.saveTo,
                                      message: loc("Save the document with its long-term data. It is saved as it is: any change after this would come after the data.")) else {
                if self.pdf.session?.undoLabel == loc("Add Verification Information") { self.pdf.undo() }
                self.notify(loc("Not added: the copy wasn't saved"))
                return
            }
            let gaps = result.certificates.filter { !$0.covered }.count
            self.showLongTermOutcome(gaps == 0 ? loc("Long-term data added.")
                : gaps == 1 ? loc("Long-term data added, but {0} certificate has none: see what was asked.", CoreLanguage.number(1))
                : loc("Long-term data added, but {0} certificates have none: see what was asked.", CoreLanguage.number(gaps)),
                LtvDialogs.describe(result.certificates, result.contacts))
        }
    }

    @objc func checkSignaturesOnline(_ sender: Any?) { checkSignaturesOnline(scripted: false) }

    /// Check Signatures Online: shows what would be contacted, asks, and shows the signatures in that light. The file
    /// stays as it is; the answer counts for this window's view only (`SigningState.online`).
    func checkSignaturesOnline(scripted: Bool) {
        guard !signing.signing, let session = pdf.session else { return NSSound.beep() }
        signing.signing = true
        let data = session.data, password = session.password, repaired = session.repairedLength
        startLongTask {
            defer { self.signing.signing = false }
            let client = Self.newLtvClient()
            let plan = await Task.detached { Ltv.plan(data, password, client: client, onlyMissing: false, repairedLength: repaired) }.value
            guard scripted || LtvDialogs.confirmOnline(plan, window: self.window) else { return }
            self.notify(loc("Checking the signatures online…"))
            do {
                let result = try await Task.detached { try await Ltv.checkOnline(data, password, client, repairedLength: repaired) }.value
                self.signing.online = result.snapshot
                self.showLongTermOutcome(result.problem.map { loc("Checked online, but not everything could be asked. {0} The file wasn't changed.", $0) }
                    ?? loc("Checked online. The file wasn't changed."), LtvDialogs.describe(result.certificates, result.contacts))
                self.verifySignatures(onOpen: false)
            } catch let e as SigningError {
                self.info(loc("The check didn't work"), e.message)
            } catch let e as LtvFetchError {
                self.info(loc("The check didn't work"), e.message)
            } catch {
                self.info(loc("The check didn't work"), "\(error)")
            }
        }
    }

    /// Puts what long-term validation did at the top of the Signatures pane, and shows the pane.
    func showLongTermOutcome(_ text: String, _ details: String) {
        sidebar.signatures.showOutcome(text, details)
        showSignatures(nil)
        notify(text)
    }

    /// Saves the document as a new file (`suggested`; `scripted` for the self-test); false when not saved.
    func saveCopy(_ suggested: String, to scripted: URL?, message: String) async -> Bool {
        var url = scripted
        if url == nil && !Report.isRunning, let window {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.pdf]
            panel.nameFieldStringValue = suggested
            panel.message = message
            if let dir = pdf.fileURL?.deletingLastPathComponent() { panel.directoryURL = dir }
            let response = await panel.beginSheetModal(for: window)
            url = response == .OK ? panel.url : nil
        }
        guard let url else { return false }
        let error = await withCheckedContinuation { (done: CheckedContinuation<Error?, Never>) in
            pdf.save(to: url, ofType: "com.adobe.pdf", for: .saveAsOperation) { done.resume(returning: $0) }
        }
        if let error {
            pdf.showError(loc("The copy couldn't be saved."), error)
            return false
        }
        verifySignatures(onOpen: true)
        return true
    }
}

/// Long-term validation's "what is sent, where" windows: before anything goes online the person sees every address that
/// would be asked, what it gets, and what won't be asked and why.
@MainActor
enum LtvDialogs {
    private static var nothingElse: String {
        loc("Nothing else leaves this Mac, and the document itself is never sent. Addresses on this Mac or a local network are never contacted, however a file names them.")
    }

    /// The timestamp server the person entered; the address that came filled in before there was a choice doesn't count.
    static var chosenTimestampUrl: String {
        let saved = AppSettings.defaults.string(forKey: "TimestampUrl") ?? ""
        return saved.isEmpty || saved == "http://timestamp.digicert.com" ? LtvPlan.suggestedTimestampServer : saved
    }

    /// Add Verification Information: the addresses, and the choice of a document timestamp. The timestamp server's address,
    /// or "" for none; nil when cancelled.
    static func confirmAdd(_ plan: LtvPlan, _ client: LtvClient, window: NSWindow?) -> String? {
        if Report.skipsDialogs { return "" }
        let alert = NSAlert()
        alert.messageText = loc("Add Verification Information")
        alert.informativeText = loc("Stores in the file what it takes to check its signatures years from now, as an update after the signatures: they stay as they are. The file is saved as a new copy afterwards.")
        let form = SheetForm("AddVerification", width: 560)
        addAddresses(form, plan)
        let timestamp = NSButton(checkboxWithTitle: loc("Also add a document timestamp (PAdES B-LTA)"), target: nil, action: nil)
        let url = NSTextField(string: chosenTimestampUrl)
        url.widthAnchor.constraint(equalToConstant: 320).isActive = true
        url.setAccessibilityLabel(loc("Timestamp server"))
        url.isEnabled = false
        let sync = ControlAction(timestamp) { url.isEnabled = timestamp.state == .on }
        form.row(nil, timestamp)
        form.row(loc("Timestamp server"), url)
        form.note(loc("Sectigo's free server is suggested; you can enter another that starts with https://. It {0}. A signature with no timestamp of its own takes two.",
                      LtvPlan.whatIsSent(.timestamp)))
        form.note(nothingElse)
        form.install(in: alert)
        alert.addButton(withTitle: loc("Contact and add"))
        alert.addButton(withTitle: loc("Cancel"))
        while true {
            guard alert.runModal() == .alertFirstButtonReturn else { return nil }
            _ = sync
            guard timestamp.state == .on else { return "" }
            let typed = url.stringValue.trimmingCharacters(in: .whitespaces)
            if typed.isEmpty {
                problem(loc("Enter the timestamp server's address, or untick the document timestamp."))
                continue
            }
            if let why = client.why(typed, .timestamp) {
                problem(loc("That timestamp server can't be used: {0}.", why))
                continue
            }
            AppSettings.defaults.set(typed, forKey: "TimestampUrl")
            return typed
        }
    }

    /// Signing for the long term: the addresses, once the digital ID and the timestamp server are chosen.
    static func confirmSign(_ plan: LtvPlan, _ level: LongTermLevel, window: NSWindow?) -> Bool {
        if Report.skipsDialogs { return true }
        return confirm(level == .lta ? loc("Sign with long-term validation (PAdES B-LTA)") : loc("Sign with long-term validation (PAdES B-LT)"),
                       loc("To store the proof that your certificate is good when you sign, these will be asked:"), plan, loc("Contact and sign"))
    }

    /// Batch's long-term action: the addresses every signed file in the list would ask, before the batch runs.
    static func confirmBatch(_ plan: LtvPlan, signedFiles: Int) -> Bool {
        if Report.skipsDialogs { return true }
        let title = signedFiles == 1 ? loc("Add long-term validation data to {0} signed file", CoreLanguage.number(1))
            : loc("Add long-term validation data to {0} signed files", CoreLanguage.number(signedFiles))
        return confirm(title, loc("Before the batch runs, these will be asked, one file at a time. An answer is used again for the next file, and a server that doesn't answer isn't asked again. Each result is saved as a new copy; the originals stay as they are."),
                       plan, loc("Contact and run"))
    }

    /// Check Signatures Online: the addresses. Leaves the file alone.
    static func confirmOnline(_ plan: LtvPlan, window: NSWindow?) -> Bool {
        if Report.skipsDialogs { return true }
        return confirm(loc("Check signatures online"),
                       loc("Opening a file never goes online. To check now whether the certificates of its signatures have been revoked, these will be asked. The file stays as it is, and the answer is for this window only."),
                       plan, loc("Contact and check"))
    }

    private static func confirm(_ title: String, _ text: String, _ plan: LtvPlan, _ button: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        let form = SheetForm("LongTermAddresses", width: 560)
        addAddresses(form, plan)
        form.note(nothingElse)
        form.install(in: alert)
        alert.addButton(withTitle: button)
        alert.addButton(withTitle: loc("Cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// The addresses that will be asked and those that won't, each a line a screen reader reads, and the plan's notes.
    private static func addAddresses(_ form: SheetForm, _ plan: LtvPlan) {
        let asked = plan.addresses.filter { $0.refusedBecause == nil }
        let refused = plan.addresses.filter { $0.refusedBecause != nil }
        if !asked.isEmpty {
            form.row(loc("What will be contacted"), list(asked.map { loc("{0}, about {1}: {2}", host($0.url), $0.forWhom, $0.url) }, loc("What will be contacted")))
            var kinds: [LtvAddressKind] = []
            for a in asked where !kinds.contains(a.kind) { kinds.append(a.kind) }
            for kind in kinds {
                let sent = LtvPlan.whatIsSent(kind)
                let line = switch kind {
                case .ocsp: loc("An OCSP responder {0}.", sent)
                case .crl: loc("A CRL address {0}.", sent)
                case .issuer: loc("An issuer's address {0}.", sent)
                case .timestamp: loc("The timestamp server {0}.", sent)
                }
                form.note(line)
            }
        } else if refused.isEmpty {
            form.note(plan.complete ? loc("Nothing needs asking: the file already holds the data, or its certificates need none.")
                : loc("The certificates name nothing to ask about them."))
        }
        if !refused.isEmpty {
            form.row(loc("What won't be contacted"), list(refused.map { "\($0.refusedBecause ?? ""): \($0.url)" }, loc("What won't be contacted")))
        }
        for note in plan.notes { form.note(note) }
    }

    /// The host of an address as a certificate names it (shortened: a hostile certificate's address can be long).
    private static func host(_ url: String) -> String {
        guard let start = url.range(of: "://")?.upperBound else { return String(url.prefix(80)) }
        let rest = url[start...]
        return String(rest[..<(rest.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? rest.endIndex)].prefix(80))
    }

    /// A list to read with the keyboard: each address a line, selectable, in a box of bounded height.
    private static func list(_ lines: [String], _ name: String) -> NSView {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 10))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        text.string = lines.map { String($0.prefix(300)) }.joined(separator: "\n")
        text.setAccessibilityLabel(name)
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.widthAnchor.constraint(equalToConstant: 400).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: min(130, CGFloat(max(1, lines.count)) * 17 + 8)).isActive = true
        return scroll
    }

    private static func problem(_ text: String) {
        let a = NSAlert()
        a.messageText = text
        a.runModal()
    }

    /// The details behind what the Signatures pane says was done: each certificate, and everything that was asked.
    nonisolated static func describe(_ certificates: [LtvCertificateResult], _ contacts: [LtvContact]) -> String {
        var parts: [String] = []
        if !certificates.isEmpty { parts.append(([loc("Certificates:")] + certificates.map { "\($0.name): \($0.outcome)" }).joined(separator: "\n")) }
        if !contacts.isEmpty { parts.append(([loc("Asked:")] + contacts.map { "\($0.url): \($0.outcome)" }).joined(separator: "\n")) }
        if contacts.isEmpty { parts.append(loc("Nothing was asked online.")) }
        return parts.joined(separator: "\n\n")
    }
}
