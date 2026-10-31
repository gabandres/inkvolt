import AppKit
import PdfCore

/// Tools › Make Accessible (Tag)… (the Windows app's `AccessibleActions`): reads the pages into a tag plan (`AutoTag.plan`,
/// off the main thread with a progress sheet and Cancel), asks for the title and language (proposed: the document's, its
/// first heading, a language read from the text), writes the tags as one undo step (`AutoTag.write`; a signed file's edit is
/// appended), then opens the Reading Order pane to check the order and give pictures alternate text.
extension DocumentWindowController {
    @objc func makeAccessible(_ sender: Any?) {
        startLongTask { await self.makeAccessible() }
    }

    /// The Pro check of a feature: true when it may run, else the Inkvolt Pro window says what it does and where to get it.
    func proAllows(_ feature: ProFeature) -> Bool {
        if Pro.allows(feature) { return true }
        Report.progress("Pro: \(Pro.title(feature)) asked for a licence")
        ProWindowController.show(feature: feature)
        return false
    }

    /// The whole command; true when the tags were written.
    @discardableResult
    func makeAccessible() async -> Bool {
        guard pdf.session != nil, proAllows(.autoTagging), await settleForTags() else { return false }
        guard let plan = await readTagPlan() else { return false }
        return await writeTags(plan, ask: true)
    }

    /// Everything being typed or edited goes into the document first.
    func settleForTags() async -> Bool {
        form.commitEditor()
        await form.settle()
        await content.settle()
        return pdf.session != nil
    }

    /// The plan for the document as it is now, read with a progress sheet (nil: cancelled, unreadable, or the document
    /// changed meanwhile).
    func readTagPlan() async -> TagPlan? {
        guard let session = pdf.session else { return nil }
        let data = session.data, password = session.password
        let sheet = ProgressSheet(title: "Make Accessible", text: "Reading the pages…")
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let token = sheet.token
        let outcome = await Task.detached { () -> Result<TagPlan, Error> in
            Result {
                // Its own engine: the viewer's keeps rendering meanwhile.
                let engine = try PdfEngine.open(data, password: password)
                defer { engine.close() }
                return try AutoTag.plan(engine, data, password, progress: { done, total in
                    Task { @MainActor in sheet.update("Reading page \(done + 1) of \(total)…", Double(done) / Double(max(1, total))) }
                }, cancel: token)
            }
        }.value
        switch outcome {
        case .success(let plan):
            guard pdf.session?.data == data else { return nil }
            return plan
        case .failure(let error):
            if !(error is CancellationError) { pdf.showError("This document can't be tagged", error) }
            return nil
        }
    }

    /// Writes the plan's tags as one undo step (asking for the title and language first with `ask`), then shows the pane.
    @discardableResult
    func writeTags(_ plan: TagPlan, ask: Bool) async -> Bool {
        var plan = plan
        if ask {
            guard let confirmed = await askTitleAndLanguage(plan) else { return false }
            plan = confirmed
        }
        guard await settleForTags() else { return false }
        let options = AccessibleOptions(title: plan.title, language: plan.language)
        let written = plan
        let ok = await editor.run("Make accessible") { d, pw in try AutoTag.write(d, pw, written, options) }
        guard ok else { return false }
        Report.progress("Make Accessible: \(plan.blocks.count) pieces, \(plan.figuresWithoutAlt) pictures without alternate text")
        readingOrder.showWritten(plan)
        notify(ReadingOrder.written(plan), canUndo: true)
        return true
    }

    /// The title and language sheet; the plan with what the person confirmed, or nil when cancelled.
    private func askTitleAndLanguage(_ plan: TagPlan) async -> TagPlan? {
        if Report.isRunning {
            var plan = plan
            plan.title = AccessibleState.testTitle ?? plan.title
            plan.language = AccessibleState.testLanguage ?? plan.language
            AccessibleState.lastProblem = ReadingOrder.problem(title: plan.title ?? "", language: plan.language ?? "")
            guard AccessibleState.lastProblem == nil else { return nil }
            plan.languageGuessed = false
            plan.titleFrom = .metadata
            return plan
        }
        guard let window else { return nil }
        let title = NSTextField(string: plan.title ?? "")
        title.setAccessibilityLabel("Title")
        title.widthAnchor.constraint(equalToConstant: 420).isActive = true
        let language = NSComboBox()
        language.addItems(withObjectValues: ReadingOrder.languages)
        language.stringValue = plan.language ?? ""
        language.completes = true
        language.setAccessibilityLabel("Language code")
        language.widthAnchor.constraint(equalToConstant: 200).isActive = true
        func note(_ text: String, error: Bool = false) -> NSTextField {
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = error ? .systemRed : .secondaryLabelColor
            label.preferredMaxLayoutWidth = 420
            return label
        }
        func heading(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            return label
        }
        let problem = note("", error: true)
        problem.isHidden = true
        var views: [NSView] = [note(ReadingOrder.introduction)]
        if plan.wasTagged { views.append(note(ReadingOrder.replaces)) }
        views += [heading("Title"), title, note(ReadingOrder.titleNote(plan)), heading("Language"), language, note(ReadingOrder.languageNote(plan)),
                  note(ReadingOrder.found(plan)), problem]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        while true {
            let alert = NSAlert()
            alert.messageText = "Tag the Document"
            alert.addButton(withTitle: "Make Accessible")
            alert.addButton(withTitle: "Cancel")
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            alert.window.initialFirstResponder = title
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return nil }
            if let wrong = ReadingOrder.problem(title: title.stringValue, language: language.stringValue) {
                // Asked again, saying what's missing.
                problem.stringValue = wrong
                problem.isHidden = false
                continue
            }
            var result = plan
            result.title = title.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            result.language = language.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            result.languageGuessed = false
            result.titleFrom = .metadata
            return result
        }
    }
}

/// What the self-test answers in Make Accessible's sheet (it isn't shown while the self-test runs), and what it said.
@MainActor
enum AccessibleState {
    static var testTitle: String?
    static var testLanguage: String?
    static var lastProblem: String?
    /// The self-test's answer to "Tag the document first?" for Save as PDF/A-2a.
    static var testTagFirst = true
    private(set) static var tagFirstAsked = 0

    static func askTagFirst(_ window: NSWindow?) async -> Bool {
        if Report.isRunning {
            tagFirstAsked += 1
            return testTagFirst
        }
        let alert = NSAlert()
        alert.messageText = "Tag the document first?"
        alert.informativeText = "PDF/A-2a keeps a document's structure (its tags), and this one has none. Make Accessible tags it from its layout (headings, paragraphs, lists, tables, pictures); you can check the reading order and add alternate text, then save the PDF/A-2a copy again."
        alert.addButton(withTitle: "Make Accessible")
        alert.addButton(withTitle: "Cancel")
        guard let window else { return alert.runModal() == .alertFirstButtonReturn }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }
}
