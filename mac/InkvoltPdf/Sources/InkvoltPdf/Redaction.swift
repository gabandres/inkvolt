import AppKit
import PdfCore
import PrintCore

/// Redaction, the redaction check and Sanitize Document (the Windows app's `DocumentTab.Review` redaction part,
/// `RedactPatternActions`, `RedactionCheckActions` and `SanitizeActions`): areas are marked with the Redact tool, from the
/// selected text, from the search matches or by pattern, shown over the pages until applied; Apply blacks them out for
/// good (the pages become pictures, their remaining text recognized and laid back invisibly, one undo step) and then
/// checks the result in the background; Tools › Check Redaction… checks any PDF; Sanitize Document removes what the
/// document carries besides its pages, then says what went (What's in This PDF, which lists it first: Inventory.swift).
@MainActor
final class RedactionState {
    /// The sheets while they are open (the self-test drives them).
    var patternSheet: RedactPatternSheet?
    var reportSheet: RedactionReportSheet?
    var sanitizeSheet: SanitizeSheet?
    var inventorySheet: InventorySheet?
    /// The check after Apply, or a fix, while it runs (the self-test awaits it).
    var task: Task<Void, Never>?
    /// The last check's report and the last sanitize's result (the self-test reads them).
    var lastReport: RedactionCheckReport?
    var lastSanitize: SanitizeResult?
    /// The last What's in This PDF report (the self-test reads it).
    var lastInventory: InventoryReport?
    /// The self-test's recognizer for the text left on redacted pages (nil: Vision).
    var testRecognizer: Recognizer?
    /// The last choices of Redact by Pattern, offered again (until the app quits).
    static var lastPatterns = RedactionPatternOptions()
}

/// The bar over the pages while areas are marked or the Redact tool is on: how many areas on how many pages, and
/// Mark Search Matches, Clear, Apply Redactions… and Done.
@MainActor
final class RedactBar: NSView {
    let label = NSTextField(labelWithString: "")
    let matches = NSButton(title: loc("Mark Search Matches"), target: nil, action: nil)
    let clear = NSButton(title: loc("Clear Marks"), target: nil, action: nil)
    let apply = NSButton(title: loc("Apply Redactions…"), target: nil, action: nil)
    let done = NSButton(title: loc("Done"), target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        let icon = NSImageView(image: NSImage(systemSymbolName: "rectangle.fill", accessibilityDescription: loc("Redaction"))!)
        icon.contentTintColor = .labelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for b in [matches, clear, apply, done] {
            b.bezelStyle = .rounded
            b.controlSize = .small
        }
        apply.keyEquivalent = ""
        matches.toolTip = loc("Marks every match of the current search for redaction")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [icon, label, spacer, matches, clear, apply, done])
        stack.setVisibilityPriority(.detachOnlyIfNecessary, for: matches)
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(loc("Redaction"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.systemRed.withAlphaComponent(0.1).setFill()
        dirtyRect.fill()
    }
}

extension DocumentWindowController {
    /// "1 area", "12 areas" (a phrase the sentences below hold, as Windows' Redact_Areas_One/Many).
    static func areaPhrase(_ n: Int) -> String { n == 1 ? loc("{0} area", 1) : loc("{0} areas", CoreLanguage.number(n)) }
    static func pagePhrase(_ n: Int) -> String { n == 1 ? loc("{0} page", 1) : loc("{0} pages", CoreLanguage.number(n)) }

    /// Says something that needs reading in an alert over the window (in the bar during the self-test). `title` and
    /// `text` are shown as given: pass them through `loc`.
    func inform(_ title: String, _ text: String) {
        if Report.skipsDialogs {
            notify("\(title): \(text)")
            return
        }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.beginSheetModal(for: window)
    }

    func wireRedaction() {
        redactBar.isHidden = true
        redactBar.matches.target = self
        redactBar.matches.action = #selector(redactSearchMatches(_:))
        redactBar.clear.target = self
        redactBar.clear.action = #selector(clearRedactionMarks(_:))
        redactBar.apply.target = self
        redactBar.apply.action = #selector(applyRedactions(_:))
        redactBar.done.target = self
        redactBar.done.action = #selector(redactDone(_:))
    }

    // MARK: PagesHost

    func redactionsChanged() { updateRedactBar() }

    func updateRedactBar() {
        let marks = pages.redactions
        let shown = pages.tool == .redact || !marks.isEmpty
        redactBar.isHidden = !shown
        guard shown else { return }
        let pageCount = Set(marks.map(\.page)).count
        redactBar.label.stringValue = marks.isEmpty
            ? loc("Drag over the areas to black out. Nothing is removed until you apply the redactions.")
            : loc("{0} on {1} marked for redaction. Click a mark with the Redact tool to unmark it.", Self.areaPhrase(marks.count), Self.pagePhrase(pageCount))
        redactBar.apply.isEnabled = !marks.isEmpty
        redactBar.clear.isEnabled = !marks.isEmpty
        redactBar.matches.isHidden = found.isEmpty
    }

    // MARK: Marking

    @objc func redactDone(_ sender: Any?) {
        if pages.tool == .redact { pages.tool = .hand }
        updateRedactBar()
    }

    @objc func clearRedactionMarks(_ sender: Any?) { pages.clearRedactions() }

    /// Tools › Redact Selected Text (and the selection's context menu): its lines marked.
    @objc func redactSelectedText(_ sender: Any?) {
        let n = pages.redactSelection()
        if n == 0 { NSSound.beep() }
    }

    /// Tools › Redact Search Matches: every match of the current search marked.
    @objc func redactSearchMatches(_ sender: Any?) {
        var marks: [RedactMark] = []
        for f in found {
            guard let text = try? engine.text(f.page) else { continue }
            marks += text.rects(f.start, f.end).map { RedactMark(page: f.page, rect: $0.inflate(0.5)) }
        }
        guard !marks.isEmpty else { return NSSound.beep() }
        pages.addRedactions(marks)
        notify(found.count == 1 ? loc("Marked 1 match for redaction. Check the mark, then apply it.")
            : loc("Marked {0} matches for redaction. Check the marks, then apply them.", CoreLanguage.number(found.count)))
    }

    /// Tools › Redact by Pattern…: what to look for and where, in a sheet; the matches are then marked.
    @objc func redactByPattern(_ sender: Any?) {
        guard let window, redaction.patternSheet == nil else { return }
        let sheet = RedactPatternSheet(RedactionState.lastPatterns, pageCount: engine.pageCount, currentPage: pages.currentPage)
        redaction.patternSheet = sheet
        sheet.done = { [weak self] options in
            guard let self else { return }
            self.redaction.patternSheet = nil
            guard let options else { return }
            var remembered = options
            remembered.pages = nil
            RedactionState.lastPatterns = remembered
            self.startLongTask { await self.markPatternMatches(options) }
        }
        if let panel = sheet.window { window.beginSheet(panel) }
    }

    /// Finds the pattern matches with a progress sheet (Cancel stops it), marks them and turns the Redact tool on, so a
    /// mark can be clicked away before they are applied. The matches, nil when cancelled or stopped.
    @discardableResult
    func markPatternMatches(_ options: RedactionPatternOptions) async -> [RedactionMatch]? {
        let sheet = ProgressSheet(title: loc("Redact by Pattern"), text: loc("Searching the pages…"))
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let engine = engine
        let token = sheet.token
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            onMain { sheet.update(loc("Searching page {0} of {1}…", CoreLanguage.number(done), CoreLanguage.number(total)), Double(done) / Double(max(total, 1))) }
        }
        let result = await Task.detached { () -> Result<[RedactionMatch], Error> in
            Result { try RedactionPatterns.find(engine, options, progress: progress, cancel: token) }
        }.value
        guard engine === self.engine else { return nil }
        let matches: [RedactionMatch]
        switch result {
        case .success(let m): matches = m
        case .failure(let error as RedactionSearchTimeout):
            inform(loc("The search stopped"), error.message)
            return nil
        case .failure(is CancellationError):
            return nil
        case .failure(let error):
            pdf.showError(loc("The pages couldn't be searched."), error)
            return nil
        }
        if matches.isEmpty {
            notify(loc("Nothing matching was found on the pages searched."))
            return matches
        }
        pages.addRedactions(matches.flatMap { m in m.rects.map { RedactMark(page: m.page, rect: $0.inflate(0.5)) } })
        pages.tool = .redact
        go(matches[0].page)
        let summary = RedactionPatterns.summary(matches)
        notify(matches.count == 1
            ? loc("Marked 1 match for redaction ({0}). Check the mark, and click it if you want to keep it, then apply it.", summary)
            : loc("Marked {0} matches for redaction ({1}). Check the marks and click any you want to keep to unmark it, then apply them.",
                  CoreLanguage.number(matches.count), summary))
        return matches
    }

    // MARK: Applying

    private var looksSigned: Bool { pdf.session?.data.firstRange(of: Array("/ByteRange".utf8)) != nil }

    /// Apply Redactions…: asks first, then blacks the marks out for good and checks the result.
    @objc func applyRedactions(_ sender: Any?) {
        let marks = pages.redactions
        guard !marks.isEmpty, let window else { return }
        let pageList = Array(Set(marks.map(\.page))).sorted()
        let list = pageList.prefix(12).map { String($0 + 1) }.joined(separator: ", ") + (pageList.count > 12 ? "…" : "")
        if Report.isRunning { return startLongTask { await self.applyRedactionsNow() } }
        let alert = NSAlert()
        alert.messageText = marks.count == 1 ? loc("Apply 1 redaction?") : loc("Apply {0} redactions?", CoreLanguage.number(marks.count))
        var body = pageList.count == 1
            ? loc("The marked areas are blacked out and their content removed. Page {0} becomes a picture: its links, comments and form fields are flattened into it, and the text left on it is recognized again so it can still be searched.", list)
            : loc("The marked areas are blacked out and their content removed. Pages {0} become pictures: their links, comments and form fields are flattened into them, and the text left on them is recognized again so it can still be searched.", list)
        if looksSigned { body += "\n\n" + loc("This document is digitally signed: redaction rewrites the file, so its signatures will no longer verify.") }
        body += "\n\n" + loc("You can undo this until you save. Once saved, the removed content can't be recovered.")
        alert.informativeText = body
        alert.alertStyle = .warning
        alert.addButton(withTitle: loc("Apply Redactions"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self.startLongTask { await self.applyRedactionsNow() } } }
            }
        }
    }

    /// Blacks out every marked area (one undo step): the pages become pictures, then the text left on them is recognized
    /// and laid back as invisible text (Cancel skips only that part). `check`: the redaction check afterwards, in the
    /// background: its report when something of what was redacted is still in the file, a notice when nothing is.
    @discardableResult
    func applyRedactionsNow(check: Bool = true) async -> Bool {
        let marks = pages.redactions
        guard !marks.isEmpty, let session = pdf.session else { return false }
        var areas: [Int: [RectD]] = [:]
        for m in marks { areas[m.page, default: []].append(m.rect) }
        let areasNow = areas
        let pageList = Array(areas.keys).sorted()
        // What is about to be redacted, for the check afterwards: the text under the marks, the document as it is.
        let before = session.data
        let values = check ? ((try? RedactionCheck.valuesUnder(engine, areasNow)) ?? []) : []
        let sheet = ProgressSheet(title: loc("Applying redactions"), text: loc("Blacking out the marked areas…"))
        progressSheet = sheet
        sheet.begin(on: window)
        let recognizer = redaction.testRecognizer ?? PageOcr.recognizer(VisionRecognizer())
        let token = sheet.token
        let skipped = EditBox<Bool>(), recognized = EditBox<Int>()
        let label = marks.count == 1 ? loc("Redact 1 area") : loc("Redact {0} areas", CoreLanguage.number(marks.count))
        let ok = await editor.run(label, signaturesWarned: true) { d, pw in
            let redacted = try Redaction.apply(d, pw, areasNow)
            onMain { sheet.update(loc("Recognizing the text left on the redacted pages…"), nil) }
            do {
                var (words, _) = try PageOcr.recognizePages(redacted, pw, pageList, recognizer, exclude: areasNow, cancel: token) { done, total in
                    onMain { sheet.update(loc("Recognizing the text left on the redacted pages: page {0} of {1}…", CoreLanguage.number(min(done + 1, total)), CoreLanguage.number(total)),
                                          Double(done) / Double(max(total, 1))) }
                }
                // A word that reaches into a blacked-out area at all goes too (Windows drops only those mostly inside one):
                // its letters over the black would be text that doesn't show, and the recognizer may have guessed them.
                for (page, list) in words {
                    let black = (areasNow[page] ?? []).map { $0.inflate(1) }
                    words[page] = list.filter { w in !black.contains { !$0.intersect(w.rect).isEmpty } }
                }
                let n = words.values.reduce(0) { $0 + $1.count }
                recognized.value = n
                return n == 0 ? redacted : try TextLayer.addInvisibleText(redacted, pw, words)
            } catch is CancellationError {
                skipped.value = true
                return redacted
            }
        }
        sheet.end()
        progressSheet = nil
        guard ok else { return false }
        pages.clearRedactions()
        if pages.tool == .redact { pages.tool = .hand }
        if skipped.value == true {
            notify(loc("Redacted. Text recognition was cancelled, so the redacted pages can't be searched; use Recognize Text (OCR) to add it later."),
                   canUndo: true)
        } else {
            notify(loc("Redacted {0} on {1}. Save to keep it.", Self.areaPhrase(marks.count), Self.pagePhrase(pageList.count)), canUndo: true)
        }
        if check { checkAfterApply(RedactionCheckOptions(values: values, areas: areasNow, original: before)) }
        return true
    }

    /// The redaction check after Apply, in the background: the report when something of what was redacted is still in the
    /// file, a notice when nothing is. Nothing shows if the document changed meanwhile.
    func checkAfterApply(_ options: RedactionCheckOptions) {
        guard let session = pdf.session else { return }
        let data = session.data, password = session.password
        redaction.task = Task { @MainActor in
            let result = await Task.detached { try? RedactionCheck.run(data, password, options) }.value
            defer { self.redaction.task = nil }
            guard let report = result, self.pdf.session?.data == data else { return }
            self.redaction.lastReport = report
            if report.isClean {
                self.notify(loc("Redaction checked: nothing of what was redacted is left in the file."))
            } else {
                self.showCheckReport(report, options)
            }
        }
    }

    // MARK: Checking

    /// Tools › Check Redaction…: the check on any PDF (nothing known about what was redacted), then its report.
    @objc func checkRedaction(_ sender: Any?) {
        startLongTask {
            guard let report = await self.runCheck(RedactionCheckOptions()) else { return }
            if report.isClean {
                self.inform(loc("Redaction check"),
                            loc("Nothing recoverable was found: no text under boxes, highlights or redaction marks, no pictures under dark boxes, no text that doesn't show, and no earlier versions with text the pages no longer show.")
                                + report.notes.map { "\n\n" + $0 }.joined())
            } else {
                self.showCheckReport(report, RedactionCheckOptions())
            }
        }
    }

    /// The check with a progress sheet (Cancel stops it); nil when cancelled, failed or the document changed meanwhile.
    func runCheck(_ options: RedactionCheckOptions) async -> RedactionCheckReport? {
        guard let session = pdf.session else { return nil }
        let data = session.data, password = session.password
        let sheet = ProgressSheet(title: loc("Check Redaction"), text: loc("Looking at the pages…"))
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let token = sheet.token
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            onMain { sheet.update(loc("Checking: step {0} of {1}…", CoreLanguage.number(done), CoreLanguage.number(total)), Double(done) / Double(max(total, 1))) }
        }
        let result = await Task.detached { () -> Result<RedactionCheckReport, Error> in
            Result { try RedactionCheck.run(data, password, options, progress: progress, cancel: token) }
        }.value
        switch result {
        case .success(let report):
            guard pdf.session?.data == data else { return nil }
            redaction.lastReport = report
            return report
        case .failure(is CancellationError):
            return nil
        case .failure(let error):
            pdf.showError(loc("The redaction check couldn't run."), error)
            return nil
        }
    }

    /// The report in a sheet; Fix (when something can be fixed) fixes it and checks again.
    func showCheckReport(_ report: RedactionCheckReport, _ options: RedactionCheckOptions) {
        guard let window else { return }
        redaction.reportSheet?.close()
        let sheet = RedactionReportSheet(report, signed: looksSigned)
        redaction.reportSheet = sheet
        sheet.done = { [weak self] fix in
            guard let self else { return }
            self.redaction.reportSheet = nil
            guard fix else { return }
            let fixable = report.findings.filter { $0.fix != .none }
            self.redaction.task = Task { @MainActor in
                await self.fixLeftovers(fixable, options)
                self.redaction.task = nil
            }
        }
        if let panel = sheet.window { window.beginSheet(panel) }
    }

    /// Fixes what the check found: redacts the areas (marked, then applied as usual, with text recognition on the pages
    /// that become pictures), then sanitizes the kinds that hold leftovers in one rewrite, then checks again.
    func fixLeftovers(_ findings: [RedactionFinding], _ options: RedactionCheckOptions) async {
        let areas = RedactionCheck.redactAreas(findings)
        let items = RedactionCheck.sanitizeItems(findings)
        if !areas.isEmpty {
            pages.addRedactions(areas.flatMap { page, rects in rects.map { RedactMark(page: page, rect: $0) } })
            guard await applyRedactionsNow(check: false) else { return }
        }
        if !items.isEmpty || findings.contains(where: { $0.fix == .rewrite }) {
            let ok = await editor.run(loc("Remove redaction leftovers"), signaturesWarned: true) { d, pw in
                try SignedEdits.run({ try Sanitizer.sanitize(d, pw, items).data }, allowRewrite: true).0
            }
            guard ok || editor.lastOutcome == .noChange else { return }
        }
        // Checked again with what was redacted, not where (the fix redacted more, and earlier areas are pictures now).
        var again = options
        again.areas = nil
        again.original = nil
        guard let report = await runCheck(again) else { return }
        if report.isClean {
            notify(loc("Fixed: nothing of what was redacted is left in the file. Save to keep it."), canUndo: true)
        } else {
            showCheckReport(report, options)
        }
    }

    // MARK: Sanitize

    /// Tools › Sanitize Document…: what the document holds (counted in the background), the kinds to remove in a sheet,
    /// then the removal (one undo step, a full rewrite) and what went.
    @objc func sanitizeDocument(_ sender: Any?) {
        guard let session = pdf.session, redaction.sanitizeSheet == nil else { return }
        let data = session.data, password = session.password
        startLongTask {
            let result = await Task.detached { () -> Result<SanitizeReport, Error> in Result { try Sanitizer.scan(data, password) } }.value
            guard self.pdf.session?.data == data else { return }
            switch result {
            case .success(let found): self.askSanitize(found)
            case .failure(let error): self.pdf.showError(loc("This document can't be sanitized."), error)
            }
        }
    }

    private func askSanitize(_ found: SanitizeReport) {
        guard let window else { return }
        let sheet = SanitizeSheet(found)
        redaction.sanitizeSheet = sheet
        sheet.seeContents = { [weak self, weak sheet] in
            guard let self, let panel = sheet?.window else { return }
            self.startLongTask { await self.showInventory(on: panel, offerSanitize: false) }
        }
        sheet.done = { [weak self] items in
            guard let self else { return }
            self.redaction.sanitizeSheet = nil
            guard let items else { return }
            self.startLongTask { await self.sanitizeNow(items) }
        }
        if let panel = sheet.window { window.beginSheet(panel) }
    }

    /// Removes `items` (one undo step), then says what went; the result, nil when nothing was done.
    @discardableResult
    func sanitizeNow(_ items: Set<SanitizeItem>) async -> SanitizeResult? {
        let box = EditBox<SanitizeResult>()
        // The sheet said that a signed file's signatures stop verifying: no second question.
        let ok = await editor.run(loc("Sanitize document"), signaturesWarned: true) { d, pw in
            try SignedEdits.run({
                let r = try Sanitizer.sanitize(d, pw, items)
                box.value = r
                return r.data
            }, allowRewrite: true).0
        }
        guard ok, let result = box.value else { return nil }
        redaction.lastSanitize = result
        inform(loc("Document sanitized"), SanitizeSheet.describe(result))
        return result
    }
}

// MARK: Redact by Pattern

/// The Redact by Pattern sheet: the built-in kinds (in two columns, what each matches in its tooltip), the user's words
/// and phrases, the user's own regular expression (checked as it is typed), whole words and case, and the pages.
@MainActor
final class RedactPatternSheet: NSWindowController {
    private(set) var checks: [(pattern: RedactionPattern, box: NSButton)] = []
    let phrasesScroll = NSTextView.scrollableTextView()
    var phrases: NSTextView { phrasesScroll.documentView as! NSTextView }
    let expression = NSTextField()
    let expressionNote = NSTextField(wrappingLabelWithString: "")
    let wholeWord = NSButton(checkboxWithTitle: loc("Whole words only"), target: nil, action: nil)
    let matchCase = NSButton(checkboxWithTitle: loc("Match case"), target: nil, action: nil)
    let allPages = NSButton(radioButtonWithTitle: loc("All pages"), target: nil, action: nil)
    let somePages = NSButton(radioButtonWithTitle: loc("Pages:"), target: nil, action: nil)
    let range = NSTextField()
    let problem = NSTextField(wrappingLabelWithString: "")
    let more = NSButton()
    private var advanced: [NSView] = []
    private let pageCount: Int
    private static var hint: String { loc("For example CASE-\\d{4} finds CASE-0412. Line breaks read as spaces.") }
    var done: ((RedactionPatternOptions?) -> Void)?

    init(_ current: RedactionPatternOptions, pageCount: Int, currentPage: Int) {
        self.pageCount = pageCount
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 520), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: panel)
        let title = NSTextField(labelWithString: loc("Redact by Pattern"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let note = Self.wrapped(loc("Marks every match for redaction. Nothing is removed yet: you check the marks, then apply them."))

        let grid = NSGridView(numberOfColumns: 2, rows: 0)
        grid.rowSpacing = 6
        grid.columnSpacing = 16
        var row: [NSView] = []
        for pattern in RedactionPatterns.builtIn {
            let box = NSButton(checkboxWithTitle: RedactionPatterns.name(pattern), target: nil, action: nil)
            box.state = current.patterns.contains(pattern) ? .on : .off
            box.toolTip = RedactionPatterns.example(pattern)
            box.setAccessibilityHelp(RedactionPatterns.example(pattern))
            checks.append((pattern, box))
            row.append(box)
            if row.count == 2 {
                grid.addRow(with: row)
                row = []
            }
        }
        if !row.isEmpty { grid.addRow(with: row + [NSGridCell.emptyContentView]) }
        let kindsNote = Self.caption(
            loc("Point at a kind to see what it matches. Card numbers and IBANs count only when their check digits are right; ZIP codes match any five-digit number, so they are off unless you choose them."))

        phrases.string = current.phrases.joined(separator: "\n")
        phrases.isRichText = false
        phrases.font = .systemFont(ofSize: NSFont.systemFontSize)
        phrases.isAutomaticQuoteSubstitutionEnabled = false
        phrases.isAutomaticDashSubstitutionEnabled = false
        phrases.setAccessibilityLabel(loc("Your words and phrases, one per line"))
        phrasesScroll.borderType = .bezelBorder
        phrasesScroll.heightAnchor.constraint(equalToConstant: 56).isActive = true
        phrasesScroll.widthAnchor.constraint(equalToConstant: 500).isActive = true

        expression.stringValue = current.expression ?? ""
        expression.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        expression.placeholderString = #"CASE-\d{4}"# // English: a regular expression's example
        expression.setAccessibilityLabel(loc("Your own pattern, a regular expression"))
        expression.widthAnchor.constraint(equalToConstant: 500).isActive = true
        expressionNote.stringValue = Self.hint
        expressionNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        expressionNote.textColor = .secondaryLabelColor
        expressionNote.preferredMaxLayoutWidth = 500
        NotificationCenter.default.addObserver(self, selector: #selector(expressionChanged), name: NSControl.textDidChangeNotification, object: expression)

        wholeWord.state = current.wholeWord ? .on : .off
        matchCase.state = current.matchCase ? .on : .off
        matchCase.toolTip = loc("For your words and your pattern")
        let options = NSStackView(views: [wholeWord, matchCase])
        options.spacing = 24

        allPages.state = .on
        allPages.target = self
        allPages.action = #selector(pagesPicked(_:))
        somePages.target = self
        somePages.action = #selector(pagesPicked(_:))
        range.stringValue = PageRange.format(Array(0..<pageCount))
        range.placeholderString = loc("e.g. 1-3, 5, 8-")
        range.setAccessibilityLabel(loc("Pages to search"))
        range.widthAnchor.constraint(equalToConstant: 120).isActive = true
        NotificationCenter.default.addObserver(self, selector: #selector(rangeTyped), name: NSControl.textDidChangeNotification, object: range)
        let pagesRow = NSStackView(views: [allPages, somePages, range, Self.caption(loc("of {0}", CoreLanguage.number(pageCount)))])
        pagesRow.spacing = 8

        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 500
        problem.isHidden = true
        let find = NSButton(title: loc("Find and Mark"), target: self, action: #selector(findClicked))
        find.keyEquivalent = "\r"
        let cancel = NSButton(title: loc("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [spacer, cancel, find])

        // Your own pattern, whole words and case behind More Options (UX review, round 2: the sheet showed every choice).
        more.bezelStyle = .disclosure
        more.setButtonType(.pushOnPushOff)
        more.title = ""
        more.setAccessibilityLabel(loc("More Options"))
        more.target = self
        more.action = #selector(moreToggled)
        more.state = AppSettings.defaults.bool(forKey: "MoreOptions.RedactPattern") || !(current.expression ?? "").isEmpty
            || current.matchCase || !current.wholeWord ? .on : .off
        let moreLabel = NSTextField(labelWithString: loc("More Options"))
        moreLabel.textColor = .secondaryLabelColor
        let moreRow = NSStackView(views: [more, moreLabel])
        moreRow.spacing = 4
        advanced = [kindsNote, Self.heading(loc("Your own pattern (a regular expression)")), expression, expressionNote, options]

        var views: [NSView] = [title, note, Self.heading(loc("Look for")), grid, Self.heading(loc("Your words and phrases (one per line)"))]
        views += [phrasesScroll, Self.heading(loc("Pages")), pagesRow, moreRow]
        views += advanced
        views += [problem, buttons]
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: grid)
        stack.setCustomSpacing(14, after: phrasesScroll)
        stack.setCustomSpacing(14, after: pagesRow)
        stack.setCustomSpacing(14, after: options)
        stack.setCustomSpacing(16, after: problem)
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        for v in advanced { v.isHidden = more.state != .on }
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func wrapped(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.preferredMaxLayoutWidth = 500
        return f
    }

    static func caption(_ text: String) -> NSTextField {
        let f = wrapped(text)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        return f
    }

    static func heading(_ text: String) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        return f
    }

    @objc private func moreToggled() {
        AppSettings.defaults.set(more.state == .on, forKey: "MoreOptions.RedactPattern")
        for v in advanced { v.isHidden = more.state != .on }
        fit()
    }

    /// The sheet at the size of what it shows.
    func fit() {
        guard let window, let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        window.setContentSize(content.fittingSize)
    }

    @objc private func expressionChanged() {
        let error = RedactionPatterns.validateExpression(expression.stringValue)
        expressionNote.stringValue = error ?? Self.hint
        expressionNote.textColor = error == nil ? .secondaryLabelColor : .systemRed
        expression.setAccessibilityHelp(error ?? "")
    }

    @objc private func pagesPicked(_ sender: NSButton) {
        allPages.state = sender === allPages ? .on : .off
        somePages.state = sender === somePages ? .on : .off
    }

    @objc private func rangeTyped() { pagesPicked(somePages) }

    /// The choices as options (pages not included).
    func options() -> RedactionPatternOptions {
        let text = expression.stringValue
        return RedactionPatternOptions(
            patterns: Set(checks.filter { $0.box.state == .on }.map(\.pattern)),
            phrases: phrases.string.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            wholeWord: wholeWord.state == .on, matchCase: matchCase.state == .on,
            expression: text.trimmingCharacters(in: .whitespaces).isEmpty ? nil : text)
    }

    /// What is wrong with the choices, or nil (and the options with their pages).
    func validate() -> (error: String?, options: RedactionPatternOptions?) {
        if let error = RedactionPatterns.validateExpression(expression.stringValue) { return (error, nil) }
        var o = options()
        if o.isEmpty { return (loc("Choose something to look for: a kind of text, a word or phrase, or your own pattern."), nil) }
        if somePages.state == .on {
            let parsed = PageRange.tryParse(range.stringValue, pageCount)
            guard parsed.ok else { return (parsed.error ?? loc("That page range isn't valid."), nil) }
            o.pages = parsed.pages
        }
        return (nil, o)
    }

    @objc func findClicked() {
        let (error, o) = validate()
        if let error {
            problem.stringValue = error
            problem.isHidden = false
            return
        }
        finish(o)
    }

    @objc func cancelClicked() { finish(nil) }

    private func finish(_ options: RedactionPatternOptions?) {
        if let panel = window, let parent = panel.sheetParent { parent.endSheet(panel) }
        NotificationCenter.default.removeObserver(self)
        let done = done
        self.done = nil
        done?(options)
    }
}

// MARK: The redaction check's report

/// The redaction check's report: each thing found, where, and how it can be fixed; Fix redacts the areas, sanitizes the
/// kinds that hold leftovers and rewrites the file, then checks again. Copy Report puts the report on the clipboard.
@MainActor
final class RedactionReportSheet: NSWindowController {
    let report: RedactionCheckReport
    let fixable: [RedactionFinding]
    let fixButton: NSButton
    var done: ((Bool) -> Void)?

    init(_ report: RedactionCheckReport, signed: Bool) {
        self.report = report
        fixable = report.findings.filter { $0.fix != .none }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 560), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        fixButton = NSButton(title: loc("Fix"), target: nil, action: nil)
        super.init(window: panel)
        let title = NSTextField(labelWithString: loc("Redaction Check"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        let summary = RedactPatternSheet.wrapped(report.findings.count == 1
            ? loc("{0} It can be recovered from the file: copied, searched, or read with other tools.", report.summary)
            : loc("{0} Each can be recovered from the file: copied, searched, or read with other tools.", report.summary))
        summary.preferredMaxLayoutWidth = 620

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        for f in report.findings { list.addArrangedSubview(Self.row(f)) }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = document
        scroll.setAccessibilityLabel(loc("What was found"))
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -8),
            list.topAnchor.constraint(equalTo: document.topAnchor, constant: 8),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -8),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            scroll.widthAnchor.constraint(equalToConstant: 620),
            scroll.heightAnchor.constraint(equalToConstant: 300),
        ])

        var notes: [NSView] = []
        if !fixable.isEmpty {
            let areas = RedactionCheck.redactAreas(fixable)
            let items = RedactionCheck.sanitizeItems(fixable)
            var steps: [String] = []
            if !areas.isEmpty {
                let n = areas.values.reduce(0) { $0 + $1.count }
                let (a, p) = (DocumentWindowController.areaPhrase(n), DocumentWindowController.pagePhrase(areas.count))
                steps.append(areas.count == 1 ? loc("redacts {0} on {1} (it becomes a picture)", a, p) : loc("redacts {0} on {1} (they become pictures)", a, p))
            }
            if !items.isEmpty {
                let kinds = SanitizeSheet.kinds.filter { items.contains($0.item) }.map { SanitizeSheet.lower($0.label) }.joined(separator: "; ")
                steps.append(loc("removes {0}", kinds))
            }
            if !items.isEmpty || fixable.contains(where: { $0.fix == .rewrite }) {
                steps.append(loc("rewrites the file as one version (earlier versions and unused data go)"))
            }
            var fixNote = loc("Fix {0}, then checks again. You can undo it until you save.", steps.joined(separator: "; "))
            if signed { fixNote += " " + loc("This document is digitally signed: fixing rewrites it, so its signatures will no longer verify.") }
            notes.append(Self.note(fixNote))
        }
        if fixable.count < report.findings.count {
            notes.append(Self.note(
                loc("What has no fix here (tags, data the document still uses) can be removed by redacting the page it belongs to, or by printing the document to a new PDF.")))
        }
        if !report.notes.isEmpty { notes.append(Self.note(report.notes.joined(separator: "\n\n"))) }

        fixButton.title = fixable.isEmpty ? loc("Close") : fixable.count == 1 ? loc("Fix 1 Thing") : loc("Fix {0} Things", CoreLanguage.number(fixable.count))
        fixButton.target = self
        fixButton.action = #selector(fixClicked)
        fixButton.keyEquivalent = "\r"
        let close = NSButton(title: loc("Close"), target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\u{1b}"
        close.isHidden = fixable.isEmpty
        let copy = NSButton(title: loc("Copy Report"), target: self, action: #selector(copyClicked))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [copy, spacer, close, fixButton])

        let stack = NSStackView(views: [title, summary, RedactPatternSheet.heading(loc("What was found")), scroll] + notes + [buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    private static func note(_ text: String) -> NSTextField {
        let f = RedactPatternSheet.caption(text)
        f.preferredMaxLayoutWidth = 620
        return f
    }

    private static func row(_ f: RedactionFinding) -> NSView {
        let head = NSTextField(wrappingLabelWithString: "\(RedactionCheck.name(f.kind)) · \(f.place)")
        head.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let found = NSTextField(wrappingLabelWithString: f.text)
        found.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize + 1, weight: .regular)
        found.isSelectable = true
        let fix = RedactPatternSheet.caption(fixText(f))
        for t in [head, found, fix] { t.preferredMaxLayoutWidth = 580 }
        let row = NSStackView(views: [head, found, fix])
        row.orientation = .vertical
        row.alignment = .leading
        row.spacing = 2
        row.setAccessibilityElement(true)
        row.setAccessibilityRole(.group)
        row.setAccessibilityLabel("\(RedactionCheck.name(f.kind)), \(f.place): \(f.text). \(fixText(f))")
        return row
    }

    static func fixText(_ f: RedactionFinding) -> String {
        switch f.fix {
        case .redact where f.kind == .hiddenText: loc("Fix: the page is drawn again as a picture, without what doesn't show (nothing is blacked out).")
        case .redact: loc("Fix: redact this area.")
        case .sanitize:
            loc("Fix: Sanitize removes {0}.", SanitizeSheet.lower(SanitizeSheet.kinds.first { $0.item == f.sanitize }?.label ?? loc("it", context: "what Sanitize removes")))
        case .rewrite: loc("Fix: rewrite the file as one version.")
        case .none:
            f.kind == .structureTree ? loc("No fix here: tags stay through Sanitize. Redacting the page they describe drops its part of them.") : loc("No fix here.")
        }
    }

    /// The report as text (Copy Report), its title in the interface's language as Windows'.
    static func text(_ report: RedactionCheckReport) -> String {
        var s = loc("Redaction check") + "\n\(report.summary)\n\n"
        for f in report.findings { s += "- \(RedactionCheck.name(f.kind)) · \(f.place): \(f.text) (\(fixText(f)))\n" }
        for n in report.notes { s += "\n\(n)\n" }
        return s
    }

    @objc func fixClicked() { finish(!fixable.isEmpty) }
    @objc func closeClicked() { finish(false) }

    @objc func copyClicked() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.text(report), forType: .string)
    }

    private func finish(_ fix: Bool) {
        if let panel = window, let parent = panel.sheetParent { parent.endSheet(panel) }
        let done = done
        self.done = nil
        done?(fix)
    }
}

// MARK: Sanitize Document

/// The Sanitize Document sheet: one check box per kind found (with its count; kinds not found are shown, off and
/// dimmed), what the rewrite also drops, the signatures' warning; Sanitize removes the chosen kinds.
@MainActor
final class SanitizeSheet: NSWindowController {
    /// The kinds in order, with their labels and group headings in the interface's language (built at first use, after
    /// `AppLanguage.apply`).
    static let kinds: [(item: SanitizeItem, label: String, group: String?)] = [
        (.metadata, loc("Document properties, XMP metadata, comment authors and dates, other apps' private data"), loc("Document details")),
        (.hiddenLayers, loc("Hidden layers, with what they draw"), loc("Hidden data")),
        (.hiddenAnnotations, loc("Hidden comments and form fields"), nil),
        (.comments, loc("Comments, markup, stamps and drawings"), nil),
        (.formValues, loc("Form field values (the fields stay, empty)"), nil),
        (.bookmarks, loc("Bookmarks"), nil),
        (.thumbnails, loc("Embedded page thumbnails"), nil),
        (.activeContent, loc("JavaScript, actions that run programs or send data, multimedia"), loc("Active content")),
        (.externalLinks, loc("Links to web pages and other files"), nil),
        (.embeddedFiles, loc("Attached files"), loc("Attachments")),
        (.signatures, loc("Digital signatures (the signature fields stay, empty)"), loc("Signatures")),
    ]

    /// A kind in the one line of what the document doesn't hold.
    static func absentName(_ item: SanitizeItem) -> String {
        switch item {
        case .metadata: loc("document details")
        case .hiddenLayers: loc("hidden layers")
        case .hiddenAnnotations: loc("hidden comments or fields")
        case .comments: loc("comments or drawings")
        case .formValues: loc("form values")
        case .bookmarks: loc("bookmarks")
        case .thumbnails: loc("page thumbnails")
        case .activeContent: loc("scripts or actions")
        case .externalLinks: loc("links to other files or the web")
        case .embeddedFiles: loc("attachments")
        case .signatures: loc("digital signatures")
        }
    }

    /// The checkbox's words: the metadata line without "XMP" (plain words, UX review round 2).
    static func plainLabel(_ item: SanitizeItem, _ label: String) -> String {
        item == .metadata ? loc("Document details: title, author, comment authors and dates, other apps' private data") : label
    }

    static func lower(_ s: String) -> String { s.isEmpty ? s : s.prefix(1).lowercased() + s.dropFirst() }

    let found: SanitizeReport
    private(set) var checks: [(item: SanitizeItem, box: NSButton)] = []
    let problem = NSTextField(wrappingLabelWithString: "")
    var done: ((Set<SanitizeItem>?) -> Void)?
    /// See What's in It…: What's in This PDF over this sheet.
    var seeContents: (() -> Void)?
    let seeButton = NSButton(title: loc("See What's in It…"), target: nil, action: nil)

    init(_ found: SanitizeReport) {
        self.found = found
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 540, height: 520), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: panel)
        let title = NSTextField(labelWithString: loc("Sanitize Document"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        var views: [NSView] = [title, Self.note(
            loc("Removes what the file carries besides its pages: hidden information, scripts, attachments, authors and dates. You can undo this until you save."))]
        if found[.signatures] > 0 {
            views.append(Self.note(
                loc("This document is digitally signed. Sanitizing rewrites it, so its signatures will no longer verify. Removing them takes the signers' names and certificates out too; kept, they show as invalid. To keep the signed original, save the result as a copy (Save As).")))
        }
        // Only what this document holds gets a checkbox; the rest is one line (UX review, round 2: eleven greyed-out
        // "(none found)" boxes in five groups on a plain file).
        var absent: [String] = []
        var lastGroup: String?
        for (item, label, group) in Self.kinds {
            let n = found[item]
            if let group { lastGroup = group }
            let box = NSButton(checkboxWithTitle: "\(Self.plainLabel(item, label)) (\(CoreLanguage.number(n)))", target: nil, action: nil)
            box.state = n > 0 ? .on : .off
            box.isEnabled = n > 0
            box.setAccessibilityLabel(n > 0 ? loc("{0}: {1} found", label, CoreLanguage.number(n)) : loc("{0}: none found", label))
            checks.append((item, box))
            guard n > 0 else {
                if item != .signatures { absent.append(Self.absentName(item)) }
                continue
            }
            if let g = lastGroup {
                views.append(RedactPatternSheet.heading(g))
                lastGroup = nil
            }
            views.append(box)
        }
        if checks.allSatisfy({ found[$0.item] == 0 }) {
            views.append(RedactPatternSheet.heading(loc("Nothing hidden found")))
        }
        if !absent.isEmpty { views.append(Self.note(loc("Not in this document: {0}.", absent.joined(separator: ", ")))) }
        let earlier = found.earlierRevisions == 1 ? loc("{0} earlier version of the file", 1)
            : loc("{0} earlier versions of the file", CoreLanguage.number(found.earlierRevisions))
        switch (found.earlierRevisions > 0, found.unusedObjects > 0) {
        case (true, true): views.append(Self.note(loc("Saving it afresh also drops {0} and leftover pieces of earlier edits.", earlier)))
        case (true, false): views.append(Self.note(loc("Saving it afresh also drops {0}.", earlier)))
        case (false, true): views.append(Self.note(loc("Saving it afresh also drops leftover pieces of earlier edits.")))
        case (false, false): break
        }
        for n in found.notes { views.append(Self.note(n)) }
        views.append(Self.note(loc("Text drawn in white or outside the page stays: See What's in It… lists it, and redacting its area removes it.")))
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 500
        problem.isHidden = true
        views.append(problem)
        let sanitize = NSButton(title: loc("Sanitize"), target: self, action: #selector(sanitizeClicked))
        sanitize.keyEquivalent = "\r"
        let cancel = NSButton(title: loc("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        seeButton.target = self
        seeButton.action = #selector(seeClicked)
        let buttons = NSStackView(views: [seeButton, spacer, cancel, sanitize])
        views.append(buttons)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
        // As tall as what it lists (a fixed 520 points left a blank half on a plain file).
        stack.layoutSubtreeIfNeeded()
        panel.setContentSize(stack.fittingSize)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private static func note(_ text: String) -> NSTextField {
        let f = RedactPatternSheet.caption(text)
        f.preferredMaxLayoutWidth = 500
        return f
    }

    /// The kinds chosen.
    var chosen: Set<SanitizeItem> { Set(checks.filter { $0.box.state == .on }.map(\.item)) }

    @objc func sanitizeClicked() {
        guard !chosen.isEmpty || found.earlierRevisions > 0 || found.unusedObjects > 0 else {
            problem.stringValue = loc("Nothing to remove: this document holds none of these.")
            problem.isHidden = false
            return
        }
        finish(chosen)
    }

    @objc func cancelClicked() { finish(nil) }

    @objc func seeClicked() { seeContents?() }

    private func finish(_ items: Set<SanitizeItem>?) {
        if let panel = window, let parent = panel.sheetParent { parent.endSheet(panel) }
        let done = done
        self.done = nil
        done?(items)
    }

    /// What went (and anything that couldn't).
    static func describe(_ result: SanitizeResult) -> String {
        let removed = result.removed
        var lines = kinds.filter { removed[$0.item] > 0 }.map { "• " + short($0.item, removed[$0.item]) }
        if removed.earlierRevisions > 0 {
            lines.append("• " + (removed.earlierRevisions == 1 ? loc("{0} earlier version of the file", 1)
                : loc("{0} earlier versions of the file", CoreLanguage.number(removed.earlierRevisions))))
        }
        if removed.unusedObjects > 0 {
            lines.append("• " + (removed.unusedObjects == 1 ? loc("{0} unused object", 1) : loc("{0} unused objects", CoreLanguage.number(removed.unusedObjects))))
        }
        var s = lines.isEmpty ? loc("The file was rewritten as a single version; there was nothing else to remove.")
            : loc("Removed:") + "\n" + lines.joined(separator: "\n")
        if let left = result.remaining {
            let still = kinds.filter { removed[$0.item] > 0 && left[$0.item] > 0 }.map { short($0.item, left[$0.item]) }
            if !still.isEmpty { s += "\n\n" + loc("Still in the file: {0}.", still.joined(separator: "; ")) }
        }
        for n in removed.notes { s += "\n\n" + n }
        return s + "\n\n" + loc("Save to keep it (Save As keeps the original as it was).")
    }

    /// "3 comments": Windows' Sanitize_*_One/Many.
    private static func short(_ item: SanitizeItem, _ n: Int) -> String {
        let one = n == 1, count = CoreLanguage.number(n)
        switch item {
        case .metadata: return one ? loc("{0} metadata entry", 1) : loc("{0} metadata entries", count)
        case .hiddenLayers: return one ? loc("{0} hidden layer with its content", 1) : loc("{0} hidden layers with their content", count)
        case .hiddenAnnotations: return one ? loc("{0} hidden comment or field", 1) : loc("{0} hidden comments and fields", count)
        case .comments: return one ? loc("{0} comment", 1) : loc("{0} comments", count)
        case .formValues: return one ? loc("{0} field value", 1) : loc("{0} field values", count)
        case .bookmarks: return one ? loc("{0} bookmark", 1) : loc("{0} bookmarks", count)
        case .thumbnails: return one ? loc("{0} page thumbnail", 1) : loc("{0} page thumbnails", count)
        case .activeContent: return one ? loc("{0} script or active item", 1) : loc("{0} scripts and active items", count)
        case .externalLinks: return one ? loc("{0} external link", 1) : loc("{0} external links", count)
        case .embeddedFiles: return one ? loc("{0} attached file", 1) : loc("{0} attached files", count)
        case .signatures: return one ? loc("{0} digital signature", 1) : loc("{0} digital signatures", count)
        }
    }
}
