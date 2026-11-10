import AppKit
import PdfCore
import PrintCore

/// Translate with AI (roadmap 3.1; the Windows `DocumentTab.Translate`): reads the pages' paragraphs, shows what goes
/// where, sends them through the user's endpoint with progress and Cancel, and opens a translated copy in a new window
/// with the original beside it, scrolling with it. The document stays as it was, and can be used meanwhile: the job works
/// on its bytes as they were when it started. Free, as on Windows. Logs nothing but counts: never the text.
extension DocumentWindowController {
    /// What the self-test answers instead of the dialogs: the language, its tag and the pages; whether to keep a part.
    struct TranslateTestAnswers {
        var language: String
        var tag: String?
        var pages: [Int]
        var keepPart = true
    }

    /// Tools › AI Assistant › Translate with AI…: into what and which pages, then the copy.
    @objc func aiTranslate(_ sender: Any?) {
        ai.job = Task { @MainActor in
            guard !ai.isTranslating, await aiReadyForTranslate(), let choice = await askTranslate() else { return }
            await translate(choice.language, tag: choice.tag, pages: choice.pages)
        }
    }

    private func aiReadyForTranslate() async -> Bool {
        let now = AiService.current(AppSettings.ai)
        if now.config != nil { return true }
        guard let window, await AiSettingsSheet.show(on: window, why: loc("{0} Set it up here, or Cancel.", now.problem ?? "")) else { return false }
        Self.refreshAllAiPanes()
        return AiService.current(AppSettings.ai).config != nil
    }

    /// Into what, and which pages; nil when cancelled.
    private func askTranslate() async -> (language: String, tag: String?, pages: [Int])? {
        if let test = ai.testTranslate { return (test.language, test.tag, test.pages) }
        guard let window else { return nil }
        let alert = NSAlert()
        alert.messageText = loc("Translate with AI")
        alert.informativeText = loc("Makes a translated copy that opens beside this document and scrolls with it. This document isn't changed.") + "\n\n"
            + loc("Next shows exactly what will be sent before anything is. A long document goes one paragraph at a time, and a local model can take a while: you can stop whenever you like and keep what's done.")
        let language = NSComboBox()
        language.addItems(withObjectValues: Translation.languages.map(\.name))
        language.completes = true
        language.stringValue = AppSettings.aiTranslateLanguage
        language.setAccessibilityLabel(loc("Translate into"))
        language.toolTip = loc("Pick a language, or type one the model knows")
        language.frame = NSRect(x: 0, y: 0, width: 240, height: 26)
        let pages = NSTextField(string: "All") // English: the word the scope's parser reads in every language, as on Windows
        let chosen = selectedPages
        if chosen.count > 1 { pages.stringValue = PageRange.format(chosen.sorted()) }
        pages.placeholderString = loc("All, or pages such as 1-3, 5")
        pages.setAccessibilityLabel(loc("Pages to translate"))
        pages.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        let grid = NSGridView(views: [[NSTextField(labelWithString: loc("Into")), language], [NSTextField(labelWithString: loc("Pages to translate")), pages]])
        grid.rowSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 380, height: 60)
        alert.accessoryView = grid
        alert.addButton(withTitle: loc("Next"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.layout()
        let response = await alert.beginSheetModal(for: window)
        guard response == .alertFirstButtonReturn else { return nil }
        let typed = AiText.trim(language.stringValue)
        if typed.isEmpty {
            notify(loc("Choose a language to translate into."))
            return nil
        }
        let parsed = AiJobs.scope(pages.stringValue, pageCount: engine.pageCount)
        guard let chosenPages = parsed.pages, parsed.error == nil else {
            notify(parsed.error ?? loc("Choose a language to translate into."))
            return nil
        }
        AppSettings.aiTranslateLanguage = typed
        let tag = Translation.languages.first { $0.name.caseInsensitiveCompare(typed) == .orderedSame }?.tag
        return (typed, tag, chosenPages)
    }

    /// A sheet of progress while `work` runs, Cancel firing `cancel`.
    private func withProgress<T>(_ title: String, _ text: String, _ cancel: CancelToken, _ work: (ProgressSheet) async throws -> T) async rethrows -> T {
        let sheet = ProgressSheet(title: title, text: text)
        let id = sheet.token.register { cancel.cancel() }
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.token.unregister(id)
            sheet.end()
            progressSheet = nil
        }
        return try await work(sheet)
    }

    /// Translates the pages into `language` (`tag` for the copy's /Lang; nil for a language typed in).
    func translate(_ language: String, tag: String?, pages: [Int]) async {
        guard window != nil, let session = pdf.session, var config = AiService.current(AppSettings.ai).config else { return }
        let run = CancelToken()
        ai.translating = run
        defer { ai.translating = nil }
        let data = session.data, password = session.password, name: String = pdf.displayName ?? ""
        do {
            // ── Read the pages, nothing sent ──
            let (plan, jobs, requests): (TranslationPlan, [TranslationJob], [[AiMessage]]) = try await withProgress(
                loc("Translate with AI"), loc("Reading the paragraphs…"), run) { sheet in
                if config.isOllama {
                    sheet.update(loc("Asking Ollama how much text the model reads at once…"), nil)
                    config = try await AiService.resolve(config, keys: AppSettings.aiKeys, cancel: run)
                }
                let tokens = Translation.pieceTokens(config.contextTokens)
                let total = pages.count
                return try await Task.detached(priority: .userInitiated) {
                    let plan = try Translation.makePlan(data, password, pages, progress: { done in
                        onMain {
                            sheet.update(loc("Reading the paragraphs… page {0} of {1}", CoreLanguage.number(min(done + 1, total)), CoreLanguage.number(total)),
                                         Double(done) / Double(max(1, total)))
                        }
                    }, cancel: run)
                    let jobs = Translation.jobs(plan, tokens)
                    return (plan, jobs, Translation.requests(jobs, language))
                }.value
            }
            if jobs.isEmpty {
                await say(loc("Nothing to translate"), Self.nothingToTranslate(plan, pages))
                return
            }

            // ── What is sent, where ──
            let encrypted = session.hasEncryption
            let restricted = await Task.detached(priority: .userInitiated) { AiCopyRestriction.isRestricted(data, password: password, hasEncryption: encrypted) }.value
            let repeats = plan.paragraphCount - jobs.count
            let n = CoreLanguage.number(plan.paragraphCount)
            let what = repeats > 0
                ? loc("The paragraphs of {0} ({1}, of which {3} repeat and go once), one by one, to be put into {2}", AiText.pagesText(pages), n, language, CoreLanguage.number(repeats))
                : loc("The paragraphs of {0} ({1}), one by one, to be put into {2}", AiText.pagesText(pages), n, language)
            let outgoing = AiOutgoing(requests, what: what, followUp: loc("any whose answer can't be used, once more"))
            guard await confirmSend(config, outgoing, restricted: restricted, title: loc("Send for translation?")) else { return }

            // ── Translate ──
            let client = AiService.client(config, keys: AppSettings.aiKeys)
            let host = config.endpoint.host
            let answers = await withProgress(loc("Translating into {0}", language), loc("Sending to {0}…", host), run) { sheet in
                let started = Date()
                return await Translation.translate(jobs, language, { m, t, c in try await client.chat(m, onText: t, cancel: c) }, progress: { p in
                    var left = ""
                    if p.done >= 3 && p.done < p.total {
                        let seconds = Date().timeIntervalSince(started) * Double(p.total - p.done) / Double(p.done)
                        let minutes = Int(exactly: min(max((seconds / 60).rounded(.up), 0), 100_000)) ?? 100_000
                        left = minutes <= 1 ? loc(" About a minute left.") : loc(" About {0} minutes left.", CoreLanguage.number(minutes))
                    }
                    let failed = p.failed > 0 ? loc(" {0} without a usable answer.", CoreLanguage.number(p.failed)) : ""
                    let text = loc("Paragraph {0} of {1}, on page {2}.", CoreLanguage.number(min(p.done + 1, p.total)), CoreLanguage.number(p.total),
                                   CoreLanguage.number(p.page + 1)) + left + failed
                    onMain { sheet.update(text, Double(p.done) / Double(max(1, p.total))) }
                }, cancel: run)
            }

            // ── What to do with a part ──
            if answers.done.isEmpty {
                if !answers.cancelled { await say(loc("Nothing was translated"), answers.stoppedBecause ?? Self.firstFailure(answers)) }
                return
            }
            if answers.cancelled || answers.stoppedBecause != nil {
                let done = CoreLanguage.number(answers.done.count), all = CoreLanguage.number(jobs.count)
                let body = answers.cancelled
                    ? loc("Stopped. {0} of {1} texts are translated. A copy can be made with those, and the rest left in the original language.", done, all)
                    : (answers.stoppedBecause ?? "") + "\n" + loc("{0} of {1} texts are translated. A copy can be made with those, and the rest left in the original language.", done, all)
                guard await keepPart(body) else { return }
            }

            // ── Write the copy, in a new window beside the original ──
            let stop = CancelToken()
            let (result, original): (TranslationResult, PdfEngine?) = try await withProgress(loc("Translate with AI"), loc("Writing the translated copy…"), stop) { sheet in
                let total = plan.pages.count
                return try await Task.detached(priority: .userInitiated) {
                    let result = try Translation.apply(plan, answers, tag, progress: { done in
                        onMain {
                            sheet.update(loc("Writing the translated copy… page {0} of {1}", CoreLanguage.number(min(done + 1, total)), CoreLanguage.number(total)),
                                         Double(done) / Double(max(1, total)))
                        }
                    }, cancel: stop)
                    return (result, result.data == nil ? nil : try? PdfEngine.open(data, password: password))
                }.value
            }
            let summary = Self.summary(result.report, language, plan)
            ai.lastTranslationSummary = summary
            guard let copy = result.data else {
                await say(loc("Nothing was translated"), summary)
                return
            }
            guard let document = NewDocuments.open(copy, name: Translation.copyName(name, language), password: plan.dropOpenPassword ? nil : (plan.openPassword ?? password)),
                  let controller = document.windowControllers.first as? DocumentWindowController else {
                original?.close()
                return
            }
            if let original { controller.showBeside(original, name: name) }
            ai.lastTranslationCopy = controller
            if result.report.notes > 0 { controller.showComments(nil) }
            await controller.say(loc("Translated copy ready"), summary)
            controller.notify(loc("The original is on the left, and they scroll together. Save the copy to keep it."))
            Report.note("Translate: \(requests.count) requests, \(result.report.translated) paragraphs written") // counts only, never the text
        } catch is CancellationError {
            // Stopped before anything was sent, or while the copy was being written.
        } catch {
            let message = (error as? AiError)?.message ?? (error as? ContentEditError)?.message
                ?? loc("This PDF's pages couldn't be read for translating. The document wasn't changed.")
            await say(loc("The translation couldn't be finished"), message)
        }
    }

    /// An alert sheet with one OK (the self-test reads it from the report instead).
    func say(_ title: String, _ body: String) async {
        Report.note("ALERT \(title)")
        guard !Report.isRunning, let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        _ = await alert.beginSheetModal(for: window)
    }

    private func keepPart(_ body: String) async -> Bool {
        if let test = ai.testTranslate { return test.keepPart }
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = loc("Keep what was translated?")
        alert.informativeText = body
        alert.addButton(withTitle: loc("Make the copy"))
        alert.addButton(withTitle: loc("Discard"))
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    private static func firstFailure(_ answers: TranslationAnswers) -> String {
        answers.failed.values.first.map { loc("No answer could be used: {0}.", $0) } ?? loc("The endpoint gave no answer.")
    }

    private static func capital(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).uppercased() + s.dropFirst() }

    static func nothingToTranslate(_ plan: TranslationPlan, _ pages: [Int]) -> String {
        if !plan.scanPages.isEmpty {
            let which = capital(AiText.pagesText(plan.scanPages))
            return plan.scanPages.count == 1 ? loc("{0} is a scan: its words are part of a picture, and a translated copy can't rewrite them.", which)
                : loc("{0} are scans: their words are part of a picture, and a translated copy can't rewrite them.", which)
        }
        if !plan.crowdedPages.isEmpty {
            let which = capital(AiText.pagesText(plan.crowdedPages))
            return plan.crowdedPages.count == 1 ? loc("{0} has too many pieces of text to work out paragraphs from. Nothing was sent.", which)
                : loc("{0} have too many pieces of text to work out paragraphs from. Nothing was sent.", which)
        }
        if let first = plan.blocked.first {
            return loc("The text of {0} can't be rewritten: {1}. Nothing was sent.", AiText.pagesText(plan.blocked.map(\.page)), first.why)
        }
        let which = capital(AiText.pagesText(pages))
        return pages.count == 1 ? loc("{0} has no words to translate. Nothing was sent.", which) : loc("{0} have no words to translate. Nothing was sent.", which)
    }

    /// What the copy holds, in words. The model's text never appears here, only counts and pages.
    static func summary(_ r: TranslationReport, _ language: String, _ plan: TranslationPlan) -> String {
        var lines: [String] = []
        let n = CoreLanguage.number(r.translated)
        if r.shrunk == 0 {
            lines.append(r.translated == 1 ? loc("1 paragraph in {0}.", language) : loc("{0} paragraphs in {1}.", n, language))
        } else if r.shrunk == 1 {
            lines.append(r.translated == 1 ? loc("1 paragraph in {0}, 1 in smaller type to stay in its box.", language)
                : loc("{0} paragraphs in {1}, 1 in smaller type to stay in its box.", n, language))
        } else {
            lines.append(loc("{0} paragraphs in {1}, {2} in smaller type to stay in their boxes.", n, language, CoreLanguage.number(r.shrunk)))
        }
        func pages(_ kind: TranslationFlagKind) -> [Int] { r.flags.filter { $0.kind == kind }.map(\.page) }
        if r.doNotFit > 0 {
            let which = AiText.pagesText(pages(.doesNotFit))
            lines.append(r.doNotFit == 1 ? loc("1 doesn't fit even at the smallest size ({0}).", which)
                : loc("{0} don't fit even at the smallest size ({1}).", CoreLanguage.number(r.doNotFit), which))
        }
        if r.notTranslated > 0 {
            let found = pages(.notTranslated)
            let which = AiText.pagesText(found.isEmpty ? [plan.pages.first?.page ?? 0] : found)
            lines.append(r.notTranslated == 1 ? loc("1 paragraph stays in the original language ({0}).", which)
                : loc("{0} paragraphs stay in the original language ({1}).", CoreLanguage.number(r.notTranslated), which))
        }
        if r.unchanged > 0 {
            lines.append(r.unchanged == 1 ? loc("The model gave 1 paragraph back unchanged (a name or a code, perhaps).")
                : loc("The model gave {0} paragraphs back unchanged (a name or a code, perhaps).", CoreLanguage.number(r.unchanged)))
        }
        if r.notes > 0 {
            lines.append(r.notes == 1 ? loc("1 comment in the copy marks what to look at (the Comments pane lists them).")
                : loc("{0} comments in the copy mark what to look at (the Comments pane lists them).", CoreLanguage.number(r.notes)))
        }
        if r.cancelled {
            lines.append(loc("The translation was stopped before the end."))
        } else if let why = r.stoppedBecause {
            lines.append(loc("The endpoint stopped the translation: {0}", why))
        }
        if !r.fonts.isEmpty { lines.append(loc("The page's fonts don't have all the letters, so some text is drawn in {0}.", r.fonts.joined(separator: ", "))) }
        if !r.scanPages.isEmpty { lines.append(loc("Not translated: {0}, scanned (the words are part of a picture).", AiText.pagesText(r.scanPages))) }
        if !r.turnedTextPages.isEmpty { lines.append(loc("Not translated: turned text on {0}.", AiText.pagesText(r.turnedTextPages))) }
        if !r.crowdedPages.isEmpty { lines.append(loc("Not translated: {0}, with too many pieces of text to work out.", AiText.pagesText(r.crowdedPages))) }
        if !r.failedPages.isEmpty { lines.append(loc("Not translated: {0}, which couldn't be read or rewritten.", AiText.pagesText(r.failedPages))) }
        return lines.joined(separator: "\n") + "\n\n"
            + loc("AI-generated: check it against the original. Comments, form fields, bookmarks and text inside pictures aren't translated.")
    }
}
