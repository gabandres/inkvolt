import AppKit
import PdfCore
import PrintCore

/// What the window keeps for its AI assistant: the pane (made on first use), the request running, the conversation, the
/// pages' text already read.
@MainActor
final class AiState {
    var pane: AiPane?
    var panelItem: NSSplitViewItem?
    var cancel: CancelToken?
    var copyRestricted = false
    var turns: [AiTurn] = []
    let pageTexts = AiPageCache()
    /// The job started from a menu or the pane (the self-test awaits it).
    var job: Task<Void, Never>?

    /// True while a request of this document's AI assistant runs.
    var isBusy: Bool { cancel != nil }
}

/// The AI assistant (bring your own; off by default; the Windows `DocumentTab.Ai`): its pane at the right of the document,
/// and Summarize, Ask about this document and Explain selection. Only the text the user asks about is read, shown before
/// it is sent, and sent to the endpoint in Settings › AI assistant. One request at a time per document, with Stop. Free, as
/// on Windows. Logs nothing: never the text, the key or the endpoint's messages.
extension DocumentWindowController {
    var isAiPaneOpen: Bool { ai.panelItem?.isCollapsed == false }

    // MARK: Menu commands

    /// Tools › AI Assistant › Summarize with AI…: which pages, then the summary.
    @objc func aiSummarize(_ sender: Any?) {
        ai.job = Task { @MainActor in
            guard await aiReady(), let pages = await askSummaryPages() else { return }
            await summarize(pages)
        }
    }

    /// Tools › AI Assistant › Ask AI about This Document: the pane, with the caret in the question box.
    @objc func aiAsk(_ sender: Any?) {
        ai.job = Task { @MainActor in
            if await aiReady() { showAiPane() }
        }
    }

    /// Tools › AI Assistant › Explain Selection with AI (and the selection's context menu).
    @objc func aiExplain(_ sender: Any?) {
        ai.job = Task { @MainActor in await explainSelection() }
    }

    /// Tools › AI Assistant › AI Assistant Settings….
    @objc func aiSettings(_ sender: Any?) {
        ai.job = Task { @MainActor in
            guard let window, await AiSettingsSheet.show(on: window) else { return }
            Self.refreshAllAiPanes()
            notify(AiService.describe(AppSettings.ai))
        }
    }

    /// True when the AI assistant is set up; else offers its settings (saying why) and tells whether it is now.
    private func aiReady() async -> Bool {
        let now = AiService.current(AppSettings.ai)
        if now.config != nil { return true }
        guard let window, await AiSettingsSheet.show(on: window, why: loc("{0} Set it up here, or Cancel.", now.problem ?? "")) else { return false }
        Self.refreshAllAiPanes()
        return AiService.current(AppSettings.ai).config != nil
    }

    /// Which pages to summarize; nil when cancelled. The pages chosen in the sidebar, if several.
    private func askSummaryPages() async -> [Int]? {
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = loc("Summarize with AI")
        alert.informativeText = loc("Next shows exactly what will be sent before anything is.")
        let field = NSTextField(string: "All") // English: the word the scope's parser reads in every language, as on Windows
        field.setAccessibilityLabel(loc("Pages to summarize"))
        field.placeholderString = loc("All, or pages such as 1-3, 5")
        let chosen = selectedPages
        if chosen.count > 1 { field.stringValue = PageRange.format(chosen.sorted()) }
        field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        let label = NSTextField(labelWithString: loc("Pages to summarize:"))
        let row = NSStackView(views: [label, field])
        row.frame = NSRect(x: 0, y: 0, width: 360, height: 26)
        alert.accessoryView = row
        alert.addButton(withTitle: loc("Next"))
        alert.addButton(withTitle: loc("Cancel"))
        aiSummaryAlert = (alert, field)
        defer { aiSummaryAlert = nil }
        alert.layout()
        let response = await alert.beginSheetModal(for: window)
        guard response == .alertFirstButtonReturn else { return nil }
        let parsed = AiJobs.scope(field.stringValue, pageCount: engine.pageCount)
        if let wrong = parsed.error {
            notify(wrong)
            return nil
        }
        return parsed.pages
    }

    // MARK: The pane

    /// Opens the pane (made on first use) and puts the caret in the question box.
    func showAiPane(focusQuestion: Bool = true) {
        let pane = ai.pane ?? makeAiPane()
        ai.panelItem?.animator().isCollapsed = false
        refreshAiPane()
        if focusQuestion {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { pane.focusQuestion() }
            }
        }
    }

    private func makeAiPane() -> AiPane {
        let pane = AiPane()
        _ = pane.view
        let item = NSSplitViewItem(inspectorWithViewController: pane)
        item.minimumThickness = 260
        item.maximumThickness = 900
        item.preferredThicknessFraction = 0.3
        item.isCollapsed = true
        addSidePanel(item)
        pane.onClose = { [weak self] in self?.closeAiPane() }
        pane.onStop = { [weak self] in self?.ai.cancel?.cancel() }
        pane.onClear = { [weak self] in
            guard let self, let pane = self.ai.pane else { return }
            self.ai.cancel?.cancel()
            self.ai.turns = []
            pane.clear()
            pane.showStatus(loc("Conversation cleared"))
        }
        pane.onAsk = { [weak self] question in
            self?.ai.job = Task { @MainActor [weak self] in await self?.ask(question) }
        }
        pane.onSummarize = { [weak self] in self?.aiSummarize(nil) }
        pane.onSettings = { [weak self] in self?.aiSettings(nil) }
        pane.onPage = { [weak self] page in
            guard let self, page >= 0, page < self.engine.pageCount else { return }
            self.go(page)
        }
        ai.pane = pane
        ai.panelItem = item
        return pane
    }

    func closeAiPane() {
        ai.panelItem?.animator().isCollapsed = true
        window?.makeFirstResponder(pages)
    }

    /// Shows the current endpoint in the pane (after Settings changed it).
    func refreshAiPane() {
        let now = AiService.current(AppSettings.ai)
        ai.pane?.showDestination(now.config, problem: now.problem)
    }

    /// After Settings changed: every open document's pane.
    static func refreshAllAiPanes() {
        for document in NSDocumentController.shared.documents {
            for case let controller as DocumentWindowController in document.windowControllers { controller.refreshAiPane() }
        }
    }

    // MARK: Uses

    /// Summarizes the pages (map-reduce when they don't fit the model's context).
    func summarize(_ chosen: [Int]) async {
        guard let config = await prepare(), let texts = await readPages(chosen), let pane = ai.pane else { return }
        let plan = AiJobs.summary(chosen, texts, config, settings: AppSettings.ai)
        guard let job = plan.job else {
            pane.showStatus(plan.notSent)
            return
        }
        _ = await run(config, label: job.label, job.outgoing) { client, onFinal, onStep, cancel in
            let force = config.endpoint.reach == .internet
            let confirm: @Sendable ([[AiMessage]], CancelToken?) async throws -> Bool
            if job.showCombine {
                confirm = { round, _ in await self.confirmCombine(config, round, pages: job.pages, force: force) }
            } else {
                confirm = { _, _ in true }
            }
            return try await AiJobs.run(job, client: client, config: config, onFinal: onFinal, onStep: onStep, confirmCombine: confirm, cancel: cancel)
        }
    }

    private func confirmCombine(_ config: AiConfig, _ round: [[AiMessage]], pages chosen: [Int], force: Bool) async -> Bool {
        await confirmSend(config, AiJobs.combineOutgoing(round, pages: chosen), restricted: ai.copyRestricted, force: force, title: AiJobs.combineTitle)
    }

    /// A question about the pages in the pane's Pages box, with the conversation so far.
    func ask(_ question: String) async {
        if AiText.trim(question).isEmpty { return }
        guard let config = await prepare(), let pane = ai.pane else { return }
        let scope = AiJobs.scope(pane.scopeField.stringValue, pageCount: engine.pageCount)
        guard let chosen = scope.pages else {
            pane.showStatus(scope.error)
            window?.makeFirstResponder(pane.scopeField)
            return
        }
        guard let texts = await readPages(chosen) else { return }
        let plan = AiJobs.question(question, turns: ai.turns, pages: chosen, texts, config)
        guard let job = plan.job else {
            pane.showStatus(plan.notSent)
            return
        }
        let messages = job.request.messages
        let answered = await run(config, label: question, job.outgoing) { client, onFinal, onStep, cancel in
            onStep(AiStep(1, 1, true, loc("Asking")))
            return try await client.chat(messages, onText: onFinal, cancel: cancel)
        }
        if answered { pane.clearQuestion() }
    }

    /// Explains the selected text.
    func explainSelection() async {
        guard let first = pages.selectedSpans.first?.page else { return }
        guard let config = await prepare(), let pane = ai.pane else { return }
        guard let selection = pages.selectedText else {
            pane.showStatus(loc("Not sent: the document changed meanwhile. Select the text again."))
            return
        }
        let plan = AiJobs.explanation(selection, page: first, config)
        guard let job = plan.job else {
            pane.showStatus(plan.notSent)
            return
        }
        let messages = job.messages
        _ = await run(config, label: job.label, job.outgoing, historyQuestion: job.historyQuestion) { client, onFinal, onStep, cancel in
            onStep(AiStep(1, 1, true, loc("Explaining")))
            return try await client.chat(messages, onText: onFinal, cancel: cancel)
        }
    }

    // MARK: Plumbing

    /// The configuration to use, with the pane open; nil (after asking for setup) when the assistant is off or busy.
    private func prepare() async -> AiConfig? {
        guard await aiReady(), var config = AiService.current(AppSettings.ai).config else { return nil }
        showAiPane(focusQuestion: false)
        guard let pane = ai.pane else { return nil }
        if ai.isBusy {
            pane.showStatus(loc("Wait for the current answer, or Stop it first."))
            return nil
        }
        guard config.isOllama else { return config }
        // Ollama cuts a prompt longer than its context without a word: ask it how much this model gets.
        let token = CancelToken()
        ai.cancel = token
        pane.setBusy(true)
        pane.showStatus(loc("Asking Ollama how much text the model reads at once…"))
        defer {
            ai.cancel = nil
            pane.setBusy(false)
        }
        do {
            config = try await AiService.resolve(config, keys: AppSettings.aiKeys, cancel: token)
        } catch {
            pane.showStatus(loc("Stopped. Nothing was sent."))
            return nil
        }
        pane.showStatus(loc("{0} reads {1} tokens at once ({2}).", config.model, AiText.n0(config.contextTokens), config.contextSource ?? ""))
        return config
    }

    /// The pages' text, read in the background; nil when cancelled or the document changed meanwhile.
    private func readPages(_ chosen: [Int]) async -> [AiPageText]? {
        guard let pane = ai.pane else { return nil }
        let current = engine
        let missing = ai.pageTexts.missing(chosen, engine: current)
        let token = CancelToken()
        if !missing.isEmpty {
            ai.cancel = token
            pane.setBusy(true)
            pane.showStatus(loc("Reading the text of {0}…", AiText.pagesText(missing)))
        }
        defer {
            if !missing.isEmpty {
                ai.cancel = nil
                pane.setBusy(false)
            }
        }
        do {
            let total = missing.count
            let skipped = SkippedPages()
            let read = try await ai.pageTexts.read(chosen, engine: current, cancel: token, skipped: skipped, progress: { [weak pane] done in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { pane?.showStatus(loc("Reading the text… {0} of {1} pages", AiText.n0(done), AiText.n0(total))) }
                }
            })
            if engine !== current {
                pane.showStatus(loc("Not sent: the document changed while its text was read. Try again."))
                return nil
            }
            // Pages the engine refused go as empty: said, after the progress already queued.
            if let note = skipped.note {
                DispatchQueue.main.async { [weak pane] in MainActor.assumeIsolated { pane?.showStatus(note) } }
            }
            return read
        } catch {
            pane.showStatus(loc("Stopped. Nothing was sent."))
            return nil
        }
    }

    /// Asks before sending (skipped where the user chose not to be asked). True to send.
    func confirmSend(_ config: AiConfig, _ outgoing: AiOutgoing, restricted: Bool, force: Bool = false, title: String? = nil) async -> Bool {
        let consent = AiConsent(AppSettings.ai, config.endpoint, copyRestricted: restricted, force: force)
        guard consent.asks else { return true }
        guard let window else { return false }
        return await AiConfirmSheet.ask(on: window, config, outgoing, consent: consent, title: title)
    }

    /// Confirms the send (unless the user chose not to be asked for this endpoint), then runs the job, streaming the final
    /// answer into a new card. True when an answer came back.
    private func run(_ config: AiConfig, label: String, _ outgoing: AiOutgoing, historyQuestion: String? = nil,
                     job: @escaping @Sendable (AiClient, @escaping @Sendable (String) -> Void, @escaping @Sendable (AiStep) -> Void, CancelToken) async throws -> AiReply) async -> Bool {
        guard let pane = ai.pane, let session = pdf.session else { return false }
        let data = session.data, password = session.password, encrypted = session.hasEncryption
        let restricted = await Task.detached(priority: .userInitiated) {
            AiCopyRestriction.isRestricted(data, password: password, hasEncryption: encrypted)
        }.value
        ai.copyRestricted = restricted
        guard await confirmSend(config, outgoing, restricted: restricted) else {
            pane.showStatus(loc("Not sent."))
            return false
        }

        pane.addQuestion(label)
        let card = pane.addAnswer(model: config.model, pageCount: engine.pageCount)
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
            let reply = try await job(client, { piece in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { card.append(piece) }
                }
            }, { step in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard !card.finished else { return }
                        let text = AiJobs.stepText(step)
                        pane.showStatus(text)
                        card.progress(text)
                    }
                }
            }, token)
            let answer = AiText.trim(AiText.withoutThinking(reply.text).text)
            card.finish(answer, note: AiJobs.finishNote(reply, answer: answer))
            if !answer.isEmpty { ai.turns.append(AiTurn(historyQuestion ?? label, answer)) }
            pane.showStatus(loc("Answer ready. AI-generated: check it against the pages."))
            return true
        } catch is CancellationError {
            card.finish(nil, note: loc("Stopped."))
            pane.showStatus(loc("Stopped."))
        } catch let e as AiError {
            card.finish(nil, note: e.message, error: true)
            pane.showStatus(e.message)
        } catch {
            // Anything unexpected still ends the card: an error, never a lasting "…".
            let message = loc("Something went wrong with the answer from {0}. Nothing more was sent.", config.endpoint.host)
            card.finish(nil, note: message, error: true)
            pane.showStatus(message)
        }
        return false
    }

    /// Asks the user's own AI model for a picture's alternate text, after the usual "what is sent, where" window (for the
    /// Reading Order pane; the Windows `SuggestAltAsync`). `onAsking` runs once the user has approved it. Nil when the user
    /// declined, or there is no suggestion; an error is shown as a sheet.
    func suggestAltText(png: [UInt8], nearby: String, language: String?, page: Int, number: Int, cancel: CancelToken, onAsking: () -> Void) async -> String? {
        var now = AiService.current(AppSettings.ai)
        if now.config == nil {
            guard let window, await AiSettingsSheet.show(on: window, why: "\(now.problem.map { $0 + " " } ?? "")\(AiJobs.altTextSetup)") else { return nil }
            Self.refreshAllAiPanes()
            now = AiService.current(AppSettings.ai)
        }
        guard var config = now.config, let session = pdf.session else { return nil }
        let request = AiJobs.altText(png: png, nearby: nearby, language: language, page: page, number: number)
        let restricted = AiCopyRestriction.isRestricted(session.data, password: session.password, hasEncryption: session.hasEncryption)
        guard await confirmSend(config, request.outgoing, restricted: restricted, title: AiJobs.altTextTitle) else { return nil }
        onAsking()
        do {
            config = try await AiService.resolve(config, keys: AppSettings.aiKeys, cancel: cancel)
            let reply = try await AiService.client(config, keys: AppSettings.aiKeys).chat(request.messages, cancel: cancel)
            let alt = AiPrompts.cleanAltText(AiText.withoutThinking(reply.text).text)
            if alt.isEmpty { notify(loc("The model sent no text. Type the alternate text, or try another model.")) }
            return alt.isEmpty ? nil : alt
        } catch is CancellationError {
            return nil
        } catch {
            pdf.showError(loc("No suggestion"), (error as? AiError).map { PdfEditError($0.message) })

            return nil
        }
    }
}
