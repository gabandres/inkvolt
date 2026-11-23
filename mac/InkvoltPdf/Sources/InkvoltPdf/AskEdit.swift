import AppKit
import PdfCore
import PrintCore

@MainActor
private func askNote(_ text: String, color: NSColor = .secondaryLabelColor) -> NSTextField {
    let f = NSTextField(wrappingLabelWithString: text)
    f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    f.textColor = color
    return f
}

/// Edit by Asking's first sheet: what to do, in the person's words.
@MainActor
final class AskEditRequestSheet: AiSheet {
    /// The sheet while it is open (the self-test types in it and presses Next).
    private(set) static var current: AskEditRequestSheet?

    let field = NSTextField()
    let problem = askNote("", color: .systemRed)
    private(set) var request = ""

    init() {
        super.init(width: 520)
        window?.title = loc("Edit by Asking")
        let head = NSTextField(labelWithString: loc("Edit by Asking"))
        head.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        stack.addArrangedSubview(head)
        addWide(askNote(loc("Say what to do to this document in your own words, such as \"turn pages 3 to 5 the right way up and bookmark page 6 as Appendix\". Your AI assistant proposes the steps; you see each one and choose before anything runs.")))
        field.placeholderString = loc("Rotate the last page and highlight every \"deadline\"")
        field.setAccessibilityLabel(loc("What to do"))
        addWide(field)
        addWide(askNote(loc("Only your words, the number of pages and the page you're on are sent, with the list of commands it may use: none of the document's text.")))
        problem.isHidden = true
        addWide(problem)
        let cancel = NSButton(title: loc("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let next = NSButton(title: loc("Next"), target: self, action: #selector(nextClicked))
        next.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addWide(NSStackView(views: [spacer, cancel, next]))
        window?.initialFirstResponder = field
    }

    @objc func cancelClicked() { finish(false) }

    @objc func nextClicked() {
        let typed = AiText.trim(field.stringValue)
        if typed.isEmpty {
            problem.stringValue = loc("Type what to do.")
            problem.isHidden = false
            fitWindow()
            return
        }
        request = typed
        finish(true)
    }

    /// The request typed on `window`; nil when cancelled.
    static func ask(on window: NSWindow) async -> String? {
        let sheet = AskEditRequestSheet()
        current = sheet
        defer { current = nil }
        return await sheet.run(on: window) ? sheet.request : nil
    }
}

/// Edit by Asking's steps: each proposed step ticked, for the person to keep or untick; what was left out said.
@MainActor
final class AskEditStepsSheet: AiSheet {
    /// The sheet while it is open (the self-test reads it and presses Run).
    private(set) static var current: AskEditStepsSheet?

    private(set) var boxes: [NSButton] = []
    let problem = askNote("", color: .systemRed)
    let runButton = NSButton(title: loc("Run"), target: nil, action: nil)
    private let plan: AskEditPlan

    init(_ plan: AskEditPlan) {
        self.plan = plan
        super.init(width: 560)
        window?.title = loc("Steps Proposed")
        let head = NSTextField(labelWithString: loc("Steps Proposed"))
        head.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        stack.addArrangedSubview(head)
        addWide(askNote(loc("Your AI assistant proposes these steps, in this order. Untick any you don't want: nothing runs until you press Run, and Undo takes each edit back.")))
        for (i, step) in plan.steps.enumerated() {
            let box = NSButton(checkboxWithTitle: loc("{0}. {1}", CoreLanguage.number(i + 1), step.describe()), target: nil, action: nil)
            box.state = .on
            boxes.append(box)
            addWide(box)
        }
        for why in plan.refused { addWide(askNote(why, color: .systemOrange)) }
        if let said = plan.said { addWide(askNote(loc("The model said: \"{0}\"", said))) }
        problem.isHidden = true
        addWide(problem)
        let cancel = NSButton(title: loc("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        runButton.target = self
        runButton.action = #selector(runClicked)
        runButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addWide(NSStackView(views: [spacer, cancel, runButton]))
    }

    var chosen: [AskEditStep] { zip(plan.steps, boxes).filter { $0.1.state == .on }.map(\.0) }

    @objc func cancelClicked() { finish(false) }

    @objc func runClicked() {
        if chosen.isEmpty {
            problem.stringValue = loc("Tick at least one step, or Cancel.")
            problem.isHidden = false
            fitWindow()
            return
        }
        finish(true)
    }

    /// The steps kept on `window`; nil when cancelled.
    static func choose(on window: NSWindow, _ plan: AskEditPlan) async -> [AskEditStep]? {
        let sheet = AskEditStepsSheet(plan)
        current = sheet
        defer { current = nil }
        return await sheet.run(on: window) ? sheet.chosen : nil
    }
}

/// Edit by Asking (roadmap 4.23, free; the Windows `DocumentTab.AskEdit`): a request in the person's words goes to their
/// own AI endpoint with a few of the command palette's commands as tools (`AskEdit`: only the request, the page count and
/// the page in view go, shown first in the send window). The steps it proposes are listed, ticked, for the person to
/// untick; nothing runs until they press Run, and each edit is one undo step. Page numbers follow the pages a step before
/// deleted. Logs nothing.
extension DocumentWindowController {
    /// Tools › AI Assistant › Edit by Asking….
    @objc func aiAskEdit(_ sender: Any?) {
        ai.job = Task { @MainActor in await self.askEdit() }
    }

    /// Asks for the request (unless given), sends it, shows the steps and runs those the person keeps.
    func askEdit(_ given: String? = nil) async {
        guard engine.pageCount > 0, let window else { return }
        var request = given
        if request == nil { request = await AskEditRequestSheet.ask(on: window) }
        guard let request else { return }
        guard let config = await prepare(), let pane = ai.pane else { return }
        let pageCount = engine.pageCount
        let messages = AskEdit.messages(request, pageCount: pageCount, currentPage: pages.currentPage)
        var outgoing = AiOutgoing([messages], what: loc("Your request, the page count and the page you're on, with the commands it may propose"),
                                  onlyNote: loc("Only this and the model's name are sent: no text of the document, its name or its folder. The model only proposes steps; nothing runs before you choose."))
        outgoing.previewExtra = "\n── tools ──\n" + AiText.trim(AskEdit.toolsJson) + "\n"
        guard await confirmSend(config, outgoing, restricted: false, title: loc("Send your request to the AI assistant?")) else {
            pane.showStatus(loc("Not sent."))
            return
        }
        let token = CancelToken()
        ai.cancel = token
        pane.setBusy(true)
        pane.showStatus(loc("Sending to {0}…", config.endpoint.host))
        let plan: AskEditPlan
        do {
            defer {
                ai.cancel = nil
                pane.setBusy(false)
            }
            plan = try await AiService.client(config, keys: AppSettings.aiKeys).askEdit(messages, pageCount: pageCount, cancel: token)
        } catch is CancellationError {
            pane.showStatus(loc("Stopped."))
            return
        } catch {
            let message = (error as? AiError)?.message ?? loc("Something went wrong with the answer from {0}. Nothing more was sent.", config.endpoint.host)
            pane.showStatus(message)
            ai.lastAskEdit = "failed: \(message)"
            let alert = NSAlert()
            alert.messageText = loc("Edit by Asking")
            alert.informativeText = message
            if Report.skipsDialogs { return }
            await alert.beginSheetModal(for: window)
            return
        }
        pane.showStatus(nil)
        ai.lastAskEdit = "proposed [\(plan.steps.map { $0.describe() }.joined(separator: " | "))] refused [\(plan.refused.joined(separator: " | "))] said '\(plan.said ?? "")'"
        if pageCount != engine.pageCount {
            // The document changed meanwhile: the steps' pages no longer hold.
            ai.lastAskEdit += "; not run: the document changed"
            notify(loc("The document changed while the AI assistant was answering, so its steps no longer fit. Nothing was done: ask again."))
            return
        }
        if plan.steps.isEmpty {
            var why = [loc("The AI assistant didn't propose any step it can take with the commands offered.")] + plan.refused
            if let said = plan.said { why.append(loc("The model said: \"{0}\"", said)) }
            let alert = NSAlert()
            alert.messageText = loc("Edit by Asking")
            alert.informativeText = why.joined(separator: "\n\n")
            if Report.skipsDialogs { return }
            await alert.beginSheetModal(for: window)
            return
        }
        guard let chosen = await AskEditStepsSheet.choose(on: window, plan), !chosen.isEmpty else { return }
        await runAskEditSteps(chosen)
    }

    /// Runs the steps in order, each edit its own undo step, the pages of later steps following pages deleted before them.
    private func runAskEditSteps(_ steps: [AskEditStep]) async {
        var deleted: [Int] = [] // pages of the document as it was asked about
        var done = 0
        var notes: [String] = []
        for original in steps {
            guard let step = AskEdit.afterDelete(original, deleted) else {
                notes.append(loc("Left out, as a step before it deleted its pages: {0}.", original.describe()))
                continue
            }
            var ok = true
            switch step.kind {
            case .goToPage:
                go(min(max(step.pages[0], 0), max(0, engine.pageCount - 1)))
            case .rotatePages:
                let chosen = step.pages.filter { $0 < engine.pageCount }
                ok = !chosen.isEmpty ? await rotatePages(chosen, degrees: step.degrees == 270 ? -90 : step.degrees) : false
            case .deletePages:
                let chosen = step.pages.filter { $0 < engine.pageCount }
                if chosen.isEmpty || chosen.count >= engine.pageCount {
                    notes.append(loc("Left out, as it would delete every page: {0}.", step.describe()))
                    continue
                }
                ok = await removePages(chosen)
                if ok { deleted += original.pages.filter { !deleted.contains($0) } }
            case .addBookmark:
                ok = await addBookmark(title: step.text, page: step.pages[0], top: nil, after: nil)
            case .highlightText:
                ok = await highlightEvery(step.text, &notes)
            case .findForRedaction:
                // Redact by Pattern's own marks: nothing is removed until the person applies them.
                ok = await runPatternRedaction(RedactionPatternOptions(patterns: step.patterns, phrases: step.text.isEmpty ? [] : [step.text]))
            }
            if ok { done += 1 } else { notes.append(loc("Not done: {0}.", step.describe())) }
        }
        ai.lastAskEdit += "; ran \(done) of \(steps.count)" + (notes.isEmpty ? "" : ": \(notes.joined(separator: " "))")
        let ran = done == 1 ? loc("Ran {0} step. Undo takes each edit back.", CoreLanguage.number(1)) : loc("Ran {0} steps. Undo takes each edit back.", CoreLanguage.number(done))
        notify(([ran] + notes).joined(separator: " "), canUndo: done > 0)
    }

    /// Every place `text` is (Find's way: any case), highlighted as comments in one undo step.
    private func highlightEvery(_ text: String, _ notes: inout [String]) async -> Bool {
        let engine = engine
        let hits: [HitToMark]
        do {
            hits = try await Task.detached(priority: .userInitiated) {
                try engine.findAll(text, matchCase: false, wholeWord: false).flatMap { m -> [HitToMark] in
                    guard let pageText = m.text else { return [] }
                    return m.hits.map { HitToMark(m.page, pageText.rects($0.start, $0.end)) }
                }
            }.value
        } catch {
            return false
        }
        if hits.isEmpty {
            notes.append(loc("\"{0}\" isn't in the document.", text))
            return true // nothing to do is done
        }
        let author = editor.author
        let label = hits.count == 1 ? loc("Highlight 1 match") : loc("Highlight {0} matches", CoreLanguage.number(hits.count))
        let made = await editor.run(label, contentOnly: true) { d, pw in try SearchMarks.apply(d, pw, hits, .highlight, author: author, color: SearchMarks.colorOf(.highlight)).data }
        return made || editor.lastOutcome == .noChange
    }
}
