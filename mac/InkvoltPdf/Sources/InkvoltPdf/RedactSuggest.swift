import AppKit
import PdfCore
import PrintCore

/// What Suggest Redactions was asked for: the kinds the AI assistant looks for, the user's description, the list, the pages.
struct RedactSuggestPlan {
    var kinds: SuggestKinds
    var description: String?
    var useTerms: Bool
    var pages: [Int]

    var asksAi: Bool { !kinds.isEmpty || !RedactionSuggestions.cleanDescription(description).isEmpty }
}

/// Suggest Redactions (roadmap 4.10, Pro; the Windows `RedactSuggestActions` and `DocumentTab.RedactSuggest`): the user's
/// own AI endpoint proposes what to redact by meaning, and the user's names and terms list adds its own; the proposals go
/// into Redact by Pattern's review list, then apply, read-back, check and report as for patterns (`reviewAndRedact`).
/// PdfCore decides what a proposal is and whether the text holds it (`RedactionSuggestions`); this only asks, shows and
/// passes on. Nothing is sent unless the assistant is on and the user chose a kind, and the send window always shows what
/// goes and where.
extension DocumentWindowController {
    /// The last choices, offered again next time (until the app quits). Nothing is chosen for the assistant at first.
    private static var lastSuggest = RedactSuggestPlan(kinds: [], description: nil, useTerms: true, pages: [])

    /// Where the names and terms list is kept on this Mac (the self-test points it at a file of its own).
    static var termsUrl: URL = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Inkvolt PDF/redaction-terms.txt")
    }()

    /// Tools › Redact › Suggest Redactions…: what to look for, the list, the pages; then the suggestions.
    @objc func suggestRedactions(_ sender: Any?) {
        guard Pro.allows(.redactionSuggestions) else { return ProWindowController.show(feature: .redactionSuggestions) }
        guard let window, pdf.session != nil, redaction.patternSheet == nil else { return }
        Task { @MainActor in
            guard let plan = await askSuggestPlan(on: window, Self.lastSuggest) else { return }
            var remembered = plan
            remembered.pages = []
            Self.lastSuggest = remembered
            startLongTask { await self.runSuggestRedactions(plan) }
        }
    }

    /// The sheet; nil when cancelled. While the assistant is off, only the list is offered and nothing is sent.
    private func askSuggestPlan(on window: NSWindow, _ current: RedactSuggestPlan) async -> RedactSuggestPlan? {
        let config = AiService.current(AppSettings.ai).config
        let alert = NSAlert()
        alert.messageText = loc("Suggest Redactions")
        alert.informativeText = config.map { loc("Your AI assistant ({0} · {1}) reads the pages' text and suggests what to redact. You see exactly what is sent, and where, before it goes.", $0.model, $0.endpoint.reachText) }
            ?? loc("The AI assistant is off, so nothing is sent anywhere: only your names and terms list is searched. To get suggestions by meaning, set up your own assistant in Settings › AI assistant.")
        let titles: [(SuggestKinds, String)] = [
            (SuggestKinds.names, loc("Names of people")), (SuggestKinds.organizations, loc("Companies and organizations")),
            (SuggestKinds.addresses, loc("Postal addresses")), (SuggestKinds.accountNumbers, loc("Account and ID numbers")),
        ]
        let kinds: [(SuggestKinds, NSButton)] = titles.map { kind, title in
            let box = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            box.state = config != nil && current.kinds.contains(kind) ? .on : .off
            box.isEnabled = config != nil
            return (kind, box)
        }
        let described = NSTextField(string: current.description ?? "")
        described.placeholderString = loc("Describe it in your words, for example: diagnoses and medicines, or salaries")
        described.toolTip = described.placeholderString
        described.setAccessibilityLabel(loc("Also anything that is (optional)"))
        described.isEnabled = config != nil
        described.widthAnchor.constraint(equalToConstant: 300).isActive = true
        let file = RedactionTerms.read(Self.termsUrl)
        let useTerms = NSButton(checkboxWithTitle: Self.listTitle(file.terms.count), target: nil, action: nil)
        useTerms.state = current.useTerms ? .on : .off
        let listNote = NSTextField(wrappingLabelWithString: Self.listProblem(file) ?? "")
        listNote.textColor = .systemOrange
        listNote.preferredMaxLayoutWidth = 420
        listNote.isHidden = listNote.stringValue.isEmpty
        let edit = NSButton(title: loc("Edit List…"), target: nil, action: nil)
        let pagesField = NSTextField(string: "All") // English: the word the scope's parser reads in every language, as on Windows
        pagesField.placeholderString = loc("All, or pages such as 1-3, 5")
        pagesField.setAccessibilityLabel(loc("Pages"))
        pagesField.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let form = SheetForm("SuggestRedactions")
        form.row(loc("Ask the assistant for"), kinds[0].1, kinds[1].1)
        form.row(nil, kinds[2].1, kinds[3].1)
        form.row(loc("Also anything that is (optional)"), described)
        form.row(nil, useTerms, edit)
        form.row(nil, listNote)
        form.row(loc("Pages"), pagesField)
        form.note(loc("Nothing is removed yet: every place found is listed for you to accept or skip, and the result is read back and checked."))
        form.install(in: alert)
        alert.addButton(withTitle: loc("Find"))
        alert.addButton(withTitle: loc("Cancel"))
        let target = SuggestEditTarget { [weak self] in
            guard let self, let saved = await self.editTerms(on: alert.window) else { return }
            useTerms.title = Self.listTitle(saved.terms.count)
            listNote.stringValue = Self.listProblem(saved) ?? ""
            listNote.isHidden = listNote.stringValue.isEmpty
            if !saved.terms.isEmpty { useTerms.state = .on }
        }
        edit.target = target
        edit.action = #selector(SuggestEditTarget.clicked)
        redaction.suggestAlert = alert
        defer { redaction.suggestAlert = nil }
        while true {
            let response = await alert.beginSheetModal(for: window)
            guard response == .alertFirstButtonReturn else { return nil }
            let scope = AiJobs.scope(pagesField.stringValue, pageCount: engine.pageCount)
            var problem = scope.error
            let chosen = kinds.filter { $0.1.state == .on }.reduce(into: SuggestKinds()) { $0.insert($1.0) }
            let asksAi = !chosen.isEmpty || !RedactionSuggestions.cleanDescription(described.stringValue).isEmpty
            if problem == nil && !asksAi && !(useTerms.state == .on && !RedactionTerms.load(Self.termsUrl).isEmpty) {
                problem = config == nil ? loc("Your names and terms list is empty. Add names with Edit List, or set up the AI assistant.")
                    : loc("Choose something to ask the assistant for, or use your list.")
            }
            if let problem, !Report.isRunning {
                let say = NSAlert()
                say.messageText = loc("Suggest Redactions")
                say.informativeText = problem
                await say.beginSheetModal(for: window)
                continue
            }
            guard let pages = scope.pages, problem == nil else { return nil }
            _ = target // kept alive while the sheet is up
            return RedactSuggestPlan(kinds: config == nil ? [] : chosen, description: config == nil ? nil : described.stringValue,
                                     useTerms: useTerms.state == .on, pages: pages)
        }
    }

    private static func listTitle(_ count: Int) -> String {
        count == 1 ? loc("Also my names and terms list ({0} entry)", CoreLanguage.number(count))
            : loc("Also my names and terms list ({0} entries)", CoreLanguage.number(count))
    }

    /// What a list read short is missing, in words; nil when it was read whole.
    static func listProblem(_ file: RedactionTermsFile) -> String? {
        if file.tooLarge {
            return loc("Your saved names and terms list is larger than {0} MB, so none of it is used. Edit it to shorten it.",
                       CoreLanguage.number(RedactionTerms.maxBytes / (1 << 20)))
        }
        if file.leftOut == 0 { return nil }
        return file.leftOut == 1
            ? loc("{0} entry in your saved list is too long, or past what a list can hold, and isn't searched. Edit the list to fix it.", CoreLanguage.number(1))
            : loc("{0} entries in your saved list are too long, or past what a list can hold, and aren't searched. Edit the list to fix it.",
                  CoreLanguage.number(file.leftOut))
    }

    /// The names and terms list, one per line, edited and kept on this Mac as written; the saved list, or nil when
    /// cancelled. A list that can't be kept whole (a line too long, too many) isn't saved: the sheet says why and stays.
    func editTerms(on parent: NSWindow) async -> RedactionTermsFile? {
        let file = RedactionTerms.read(Self.termsUrl)
        var text = file.text
        var problem = Self.listProblem(file)
        while true {
            let alert = NSAlert()
            alert.messageText = loc("Names and terms to redact")
            alert.informativeText = loc("One per line: names, companies, case numbers, words. Kept on this Mac only. Lines starting with # are skipped.")
                + (problem.map { "\n\n" + $0 } ?? "")
            let scroll = NSTextView.scrollableTextView()
            scroll.frame = NSRect(x: 0, y: 0, width: 420, height: 240)
            scroll.borderType = .bezelBorder
            let box = scroll.documentView as! NSTextView
            box.string = text
            box.isRichText = false
            box.font = .systemFont(ofSize: NSFont.systemFontSize)
            box.isAutomaticQuoteSubstitutionEnabled = false
            box.isAutomaticDashSubstitutionEnabled = false
            box.setAccessibilityLabel(loc("Names and terms"))
            alert.accessoryView = scroll
            alert.addButton(withTitle: loc("Save"))
            alert.addButton(withTitle: loc("Cancel"))
            redaction.termsAlert = (alert, box)
            defer { redaction.termsAlert = nil }
            alert.layout()
            alert.window.initialFirstResponder = box
            guard await alert.beginSheetModal(for: parent) == .alertFirstButtonReturn else { return nil }
            text = box.string
            if let refused = RedactionTerms.check(text) {
                problem = refused
                continue
            }
            do {
                try RedactionTerms.saveText(Self.termsUrl, text)
            } catch {
                let say = NSAlert()
                say.messageText = loc("Names and terms to redact")
                say.informativeText = loc("The list couldn't be saved. Check that the app's data folder can be written to, then try again.")
                await say.beginSheetModal(for: parent)
                return nil
            }
            return RedactionTerms.read(Self.termsUrl)
        }
    }

    /// The whole command; true when anything was applied.
    @discardableResult
    func runSuggestRedactions(_ plan: RedactSuggestPlan) async -> Bool {
        guard pdf.session != nil else { return false }
        var proposals: [RedactionProposal] = []
        var notes: [String] = []
        redaction.lastSuggestion = nil
        if plan.asksAi && AiService.current(AppSettings.ai).config != nil {
            if let result = await askForSuggestions(plan, &notes) {
                redaction.lastSuggestion = result
                proposals += result.kept
                if result.dropped > 0 {
                    notes.append(result.dropped == 1
                        ? loc("{0} suggestion wasn't in the text as written, or couldn't be read, and was left out.", CoreLanguage.number(1))
                        : loc("{0} suggestions weren't in the text as written, or couldn't be read, and were left out.", CoreLanguage.number(result.dropped)))
                }
                if result.unreadable > 0 {
                    notes.append(result.unreadable == 1
                        ? loc("{0} answer from the assistant wasn't a list and was skipped.", CoreLanguage.number(1))
                        : loc("{0} answers from the assistant weren't a list and were skipped.", CoreLanguage.number(result.unreadable)))
                }
            } else if !plan.useTerms || pdf.session == nil {
                return false // not sent, stopped or failed: said where it happened
            } else {
                // The list is still searched, and the list says the assistant's part is missing.
                notes.append(loc("The assistant's suggestions aren't included (nothing came back from it): only your names and terms list was searched."))
            }
        }
        if plan.useTerms {
            let file = RedactionTerms.read(Self.termsUrl)
            proposals += RedactionTerms.asProposals(file.terms)
            if let problem = Self.listProblem(file) { notes.append(problem) } // a list read short is said above the list
        }
        let note = notes.isEmpty ? nil : notes.joined(separator: " ")
        if proposals.isEmpty {
            notify(note.map { loc("Nothing to redact was suggested.") + " " + $0 } ?? loc("Nothing to redact was suggested."))
            return false
        }
        let options: RedactionPatternOptions
        do {
            options = try RedactionSuggestions.searchOptions(proposals, plan.pages)
        } catch let error as TooManySuggestions {
            inform(loc("Suggest Redactions"), error.message)
            return false
        } catch {
            return false
        }
        guard var found = await searchPatterns(options) else { return false }
        found = RedactionSuggestions.label(found, proposals)
        if found.hits.isEmpty && found.looks.isEmpty {
            notify(loc("Nothing matching was found on the pages searched."))
            return false
        }
        return await reviewAndRedact(options, found, note: note)
    }

    /// The pages' text to the user's model, shown first in the send window (always, whatever was chosen for this endpoint:
    /// this is the text the user wants kept private), then its proposals read and checked against that text. Nil when not
    /// sent, stopped or failed (said in the assistant's pane or a message).
    private func askForSuggestions(_ plan: RedactSuggestPlan, _ notes: inout [String]) async -> RedactionSuggestResult? {
        guard let config = await prepare(), let texts = await readPages(plan.pages), let pane = ai.pane, let session = pdf.session else { return nil }
        let requests = RedactionSuggestions.requests(texts, plan.kinds, plan.description, config.inputTokens)
        // Pages without text (scans, pages that couldn't be read) go to the model as nothing: always said, by page.
        let blank = RedactionSuggestions.pagesWithoutText(texts)
        if !requests.isEmpty && !blank.isEmpty {
            notes.append(blank.count == 1
                ? loc("The assistant didn't read {0}: it has no text. Scanned pages need Recognize Text (OCR) first; the search below still reads them for your list and shows them to look at.", AiText.pagesText(blank))
                : loc("The assistant didn't read {0}: they have no text. Scanned pages need Recognize Text (OCR) first; the search below still reads them for your list and shows them to look at.", AiText.pagesText(blank)))
        }
        if requests.isEmpty {
            // Scans without text: nothing to send; the search after reads them through recognition, and the list says so.
            notes.append(plan.pages.count == 1
                ? loc("Nothing was sent: {0} has no text. Scanned pages need Recognize Text (OCR) first.", AiText.pagesText(plan.pages))
                : loc("Nothing was sent: {0} have no text. Scanned pages need Recognize Text (OCR) first.", AiText.pagesText(plan.pages)))
            return RedactionSuggestResult(kept: [], dropped: 0, unreadable: 0)
        }
        let data = session.data, password = session.password, encrypted = session.hasEncryption
        let restricted = await Task.detached(priority: .userInitiated) {
            AiCopyRestriction.isRestricted(data, password: password, hasEncryption: encrypted)
        }.value
        let outgoing = AiOutgoing(requests.map(\.messages), what: loc("The text of {0}, to find what to redact", AiText.pagesText(plan.pages)))
        guard await confirmSend(config, outgoing, restricted: restricted, force: true, title: loc("Send for redaction suggestions?")) else {
            pane.showStatus(loc("Not sent."))
            return nil
        }

        let token = CancelToken()
        ai.cancel = token
        pane.setBusy(true)
        pane.showStatus(loc("Sending to {0}…", config.endpoint.host))
        defer {
            ai.cancel = nil
            pane.setBusy(false)
        }
        do {
            let client = AiService.client(config, keys: AppSettings.aiKeys)
            let result = try await RedactionSuggestions.suggest(requests, ask: { messages, step, cancel in
                let text = AiJobs.stepText(step)
                DispatchQueue.main.async { MainActor.assumeIsolated { pane.showStatus(text) } }
                return try await client.chat(messages, cancel: cancel).text
            }, cancel: token)
            pane.showStatus(result.kept.count == 1 ? loc("{0} suggestion found in the text.", CoreLanguage.number(1))
                : loc("{0} suggestions found in the text.", CoreLanguage.number(result.kept.count)))
            return result
        } catch is CancellationError {
            pane.showStatus(loc("Stopped."))
        } catch let e as AiError {
            pane.showStatus(e.message)
            pdf.showError(loc("No suggestions"), PdfEditError(e.message))
        } catch {
            let message = loc("Something went wrong with the answer from {0}. Nothing more was sent.", config.endpoint.host)
            pane.showStatus(message)
            pdf.showError(loc("No suggestions"), PdfEditError(message))
        }
        return nil
    }
}

/// The Edit List… button's target while the sheet is up (an NSAlert's accessory has no controller of its own).
@MainActor
final class SuggestEditTarget: NSObject {
    private let action: @MainActor () async -> Void
    init(_ action: @escaping @MainActor () async -> Void) { self.action = action }
    @objc func clicked() { Task { @MainActor in await action() } }
}
