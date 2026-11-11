import AppKit
import PdfCore
import PrintCore

/// Redact by Pattern, start to end (the Windows app's `DocumentTab.RedactByPattern`): the search, scans through text
/// recognition; every hit listed to accept or skip, with the pages to look at by hand (`RedactReviewSheet`); the redaction
/// as one undo step; the result read back and searched again, then the redaction check (`PatternRedaction.verify`); the
/// removal report (`RemovalReportSheet`), and the check's own report when it found something the file came with.
extension DocumentWindowController {
    /// The recognizer redaction by pattern reads scans with (nil: the self-test's, when it set one).
    var patternReader: any TextRecognizer {
        redaction.testReader ?? VisionRecognizer(languages: SavedOcr.language.map { [$0] })
    }

    /// The whole command; true when anything was applied.
    @discardableResult
    func runPatternRedaction(_ options: RedactionPatternOptions) async -> Bool {
        guard let window, let session = pdf.session, let found = await searchPatterns(options) else { return false }
        let unsearched = SkippedPages.note(found.skipped).map { " " + $0 } ?? ""
        if found.hits.isEmpty && found.looks.isEmpty && found.skipped.isEmpty {
            notify(loc("Nothing matching was found on the pages searched."))
            return false
        }
        let earlierMarks = pages.redactions
        let sheet = RedactReviewSheet(found, earlier: earlierMarks.map { (page: $0.page, rect: $0.rect) }, engine: engine, unsearched: unsearched)
        redaction.reviewSheet = sheet
        let picked = await sheet.run(on: window)
        redaction.reviewSheet = nil
        guard let choice = picked, engine === self.engine, pdf.session === session else { return false }

        let name = session.displayName
        var run = PatternRedaction(file: name, patterns: options, found: found, accepted: choice.accepted, skipped: choice.skipped, mode: .reviewed,
                                   ocr: patternReader)
        run.marked = choice.lookAreas + choice.earlierApplied
        if run.areas.isEmpty {
            await showRemovalReport(RedactionReport([run.report()]), name)
            return false
        }
        let before = session.data
        pages.clearRedactions()
        pages.addRedactions(run.areas.flatMap { page, rects in rects.map { RedactMark(page: page, rect: $0) } })
        guard await applyRedactionsNow(check: false) else {
            pages.clearRedactions()
            pages.addRedactions(earlierMarks)
            return false
        }
        // What the person unticked stays a mark, not applied.
        if !choice.earlierKept.isEmpty { pages.addRedactions(choice.earlierKept.map { RedactMark(page: $0.page, rect: $0.rect) }) }
        var (report, outcome) = await readBackPatterns(run, before)
        report.markedAreas = choice.earlierApplied.count
        redaction.lastRemoval = report
        await showRemovalReport(RedactionReport([report]), name)
        // What is left outside the pages has a fix of its own, the check's.
        if let outcome, let check = outcome.check, !check.isClean {
            redaction.lastReport = check
            showCheckReport(check, outcome.checkOptions)
        }
        return true
    }

    /// Searches by pattern in the background with a progress sheet (Cancel stops it), scans through text recognition. Nil
    /// when cancelled or stopped: a search that stopped must never read as one that found nothing.
    func searchPatterns(_ options: RedactionPatternOptions) async -> RedactionSearchResult? {
        let sheet = ProgressSheet(title: loc("Redact by Pattern"), text: loc("Searching the pages…"))
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let engine = engine
        let token = sheet.token
        let reader = patternReader
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            onMain { sheet.update(loc("Searching page {0} of {1}…", CoreLanguage.number(done), CoreLanguage.number(total)), Double(done) / Double(max(total, 1))) }
        }
        let result = await Task.detached { () -> Result<RedactionSearchResult, Error> in
            Result { try RedactionSearch.find(engine, options, ocr: reader, progress: progress, cancel: token) }
        }.value
        guard engine === self.engine else { return nil }
        switch result {
        case .success(let found): return found
        case .failure(let error as RedactionSearchTimeout): inform(loc("The search stopped"), error.message)
        case .failure(let error as TooManyHits): inform(loc("The search stopped"), error.message)
        case .failure(is CancellationError): break
        case .failure(let error): pdf.showError(loc("The pages couldn't be searched."), error)
        }
        return nil
    }

    /// Reads the redacted document back, searches it again, then looks for what was removed everywhere else in the file
    /// (`PatternRedaction.verify`). A remaining hit, a leftover, or a read-back that didn't finish is the report's failure.
    /// Skipped hits don't count: the person kept them.
    func readBackPatterns(_ run: PatternRedaction, _ before: [UInt8]) async -> (RedactionFileReport, PatternRedactionOutcome?) {
        guard let session = pdf.session else { return (run.report().withoutResult(loc("The result couldn't be read back, so nothing says what was removed is gone.")), nil) }
        let data = session.data, password = session.password
        let sheet = ProgressSheet(title: loc("Redact by Pattern"), text: loc("Reading the result back…"))
        progressSheet = sheet
        sheet.begin(on: window)
        defer {
            sheet.end()
            progressSheet = nil
        }
        let token = sheet.token
        let progress: @Sendable (Int, Int) -> Void = { done, total in
            onMain { sheet.update(loc("Reading back page {0} of {1}…", CoreLanguage.number(done), CoreLanguage.number(total)), Double(done) / Double(max(total, 1))) }
        }
        let checking: @Sendable () -> Void = { onMain { sheet.update(loc("Looking through the rest of the file…"), 1) } }
        let result = await Task.detached { () -> Result<PatternRedactionOutcome, Error> in
            Result { try run.verify(data, password, before, readBack: progress, checking: checking, cancel: token) }
        }.value
        var report = run.report()
        var failure: String?
        var outcome: PatternRedactionOutcome?
        switch result {
        case .success(let o):
            outcome = o
            report = o.report
            // Only what was removed being left fails it; what else the check finds in the file opens its own report next.
            switch o.verdict {
            case .stillThere:
                let n = o.stillThere.count, on = RedactionReport.pages(o.stillThere.map(\.page))
                failure = n == 1 ? loc("Read back after redacting: {0} match is still there, on {1}. Run Redact by Pattern again, or undo.", CoreLanguage.number(n), on)
                    : loc("Read back after redacting: {0} matches are still there, on {1}. Run Redact by Pattern again, or undo.", CoreLanguage.number(n), on)
            case .leftInFile: failure = loc("Elsewhere in the file: {0}", o.check?.summary ?? "")
            case .incomplete: failure = (o.check?.notes ?? []).joined(separator: " ")
            case .passed: failure = nil
            }
        case .failure(is CancellationError):
            failure = loc("The result wasn't read back: you cancelled it, so nothing says what was removed is gone.")
        case .failure:
            failure = loc("The result couldn't be read back, so nothing says what was removed is gone.")
        }
        report.failure = failure
        return (report, outcome)
    }

    /// The removal report on a sheet, until it is closed.
    func showRemovalReport(_ report: RedactionReport, _ name: String) async {
        guard let window else { return }
        let sheet = RemovalReportSheet(report, suggestedName: (name as NSString).deletingPathExtension)
        redaction.removalSheet = sheet
        await sheet.run(on: window)
        redaction.removalSheet = nil
    }
}

/// Waits for a sheet's answer (a continuation resumed once).
@MainActor
final class SheetAnswer<T: Sendable> {
    private var continuation: CheckedContinuation<T, Never>?

    func wait(_ begin: () -> Void) async -> T {
        await withCheckedContinuation { c in
            continuation = c
            begin()
        }
    }

    func give(_ value: T) {
        let c = continuation
        continuation = nil
        c?.resume(returning: value)
    }
}

// MARK: The list of what was found

/// Every hit with its page and the words around it, accepted or skipped one by one or all, before anything is applied, with
/// the page beside the list to check it against (the Windows app's `RedactReviewDialog`; the rows are PdfCore's
/// `RedactionReviewList`). Pages only text recognition could read come first on their page: the list never lets a scan
/// pass as looked at, whatever was or wasn't found on it.
@MainActor
final class RedactReviewSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var list: RedactionReviewList
    let table = NSTableView()
    let redact = NSButton(title: "", target: nil, action: nil)
    let pageImage = NSImageView()
    let pageLabel = NSTextField(labelWithString: "")
    private let outline = OutlineView()
    private let engine: PdfEngine
    private var render: Task<Void, Never>?
    private let answer = SheetAnswer<RedactionReviewChoice?>()

    init(_ found: RedactionSearchResult, earlier: [(page: Int, rect: RectD)], engine: PdfEngine, unsearched: String) {
        list = RedactionReviewList(found, earlier: earlier)
        self.engine = engine
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init(window: panel)
        let title = NSTextField(labelWithString: loc("Check What Was Found"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        var notes: [NSView] = [title, Self.note(RedactionReviewList.heading(found) + unsearched, width: 940)]
        if let warn = RedactionReviewList.lookWarning(found) { notes.append(Self.note(warn, width: 940, caution: true)) }
        if let also = RedactionReviewList.earlierNote(earlier) { notes.append(Self.note(also, width: 940, caution: true)) }

        let column = NSTableColumn(identifier: .init("row"))
        column.width = 540
        table.addTableColumn(column)
        table.headerView = nil
        table.usesAutomaticRowHeights = true
        table.dataSource = self
        table.delegate = self
        table.allowsEmptySelection = false
        table.setAccessibilityLabel(loc("What was found"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        pageLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        pageImage.imageScaling = .scaleNone
        pageImage.imageAlignment = .alignTop
        pageImage.addSubview(outline)
        let pageScroll = NSScrollView()
        let holder = FlippedView()
        holder.addSubview(pageImage)
        pageScroll.documentView = holder
        pageScroll.hasVerticalScroller = true
        pageScroll.hasHorizontalScroller = true
        pageScroll.borderType = .bezelBorder
        let pane = NSStackView(views: [pageLabel, pageScroll])
        pane.orientation = .vertical
        pane.alignment = .leading
        let split = NSStackView(views: [scroll, pane])
        split.spacing = 12
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalToConstant: 540),
            scroll.heightAnchor.constraint(equalToConstant: 430),
            pageScroll.widthAnchor.constraint(equalToConstant: 388),
            pageScroll.heightAnchor.constraint(equalToConstant: 408),
        ])

        let accept = NSButton(title: loc("Accept All"), target: self, action: #selector(acceptAll))
        let skip = NSButton(title: loc("Skip All"), target: self, action: #selector(skipAll))
        let cancel = NSButton(title: loc("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        redact.target = self
        redact.action = #selector(redactClicked)
        redact.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [accept, skip, spacer, cancel, redact])
        let stack = NSStackView(views: notes + [split, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
        updateRedact()
        if !list.rows.isEmpty {
            table.selectRowIndexes([0], byExtendingSelection: false)
            showSelected()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    static func note(_ text: String, width: CGFloat, caution: Bool = false) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.preferredMaxLayoutWidth = width
        if caution { f.textColor = .systemOrange }
        return f
    }

    /// Shows the sheet; the person's choice, nil when cancelled.
    func run(on parent: NSWindow) async -> RedactionReviewChoice? {
        await answer.wait {
            if let panel = window { parent.beginSheet(panel) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { list.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let r = list.rows[row]
        let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(ticked(_:)))
        box.tag = row
        box.state = r.accepted ? .on : .off
        box.isHidden = !r.tickable
        box.setAccessibilityLabel(r.spoken)
        let head = NSTextField(labelWithString: "")
        head.attributedStringValue = NSAttributedString(string: r.place, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)])
        let kind = NSTextField(labelWithString: " · " + r.kind)
        let top = NSStackView(views: [head, kind])
        top.spacing = 0
        let words = NSMutableAttributedString(string: r.before, attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        words.append(NSAttributedString(string: r.value, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), .foregroundColor: NSColor.labelColor]))
        words.append(NSAttributedString(string: r.after, attributes: [.foregroundColor: NSColor.secondaryLabelColor]))
        let line = NSTextField(wrappingLabelWithString: "")
        line.attributedStringValue = words
        line.preferredMaxLayoutWidth = 480
        let text = NSStackView(views: [top, line])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let cell = NSStackView(views: [box, text])
        cell.alignment = .top
        cell.edgeInsets = NSEdgeInsets(top: 3, left: 2, bottom: 3, right: 4)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelected() }

    @objc private func ticked(_ sender: NSButton) {
        list.set(sender.tag, sender.state == .on)
        updateRedact()
    }

    /// Ticks or unticks a line (the self-test, and Space on the selected line).
    func toggle(_ row: Int) {
        guard list.rows.indices.contains(row) else { return }
        list.set(row, !list.rows[row].accepted)
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
        updateRedact()
    }

    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " ", table.selectedRow >= 0 { toggle(table.selectedRow) } else { super.keyDown(with: event) }
    }

    @objc func acceptAll() { setAll(true) }
    @objc func skipAll() { setAll(false) }

    private func setAll(_ accepted: Bool) {
        list.setAll(accepted)
        table.reloadData()
        updateRedact()
    }

    private func updateRedact() {
        redact.title = list.redactTitle
        redact.setAccessibilityLabel(list.redactTitle)
    }

    /// The selected line's page, with what the line is about outlined.
    private func showSelected() {
        let i = table.selectedRow
        guard list.rows.indices.contains(i) else { return }
        let row = list.rows[i]
        pageLabel.stringValue = row.place
        render?.cancel()
        let engine = engine
        let page = row.page
        let g = engine.page(page)
        let scale = min(1.2, 372 / max(1, g.width))
        let token = CancelToken()
        render = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            if Task.isCancelled { return token.cancel() }
            let image = await Task.detached { try? engine.render(page, scale: scale, cancel: token) }.value
            guard let self, !Task.isCancelled, let image, let picture = Self.picture(image) else { return }
            self.pageImage.image = picture
            self.pageImage.frame = NSRect(x: 0, y: 0, width: image.width, height: image.height)
            self.pageImage.superview?.frame = self.pageImage.frame
            self.pageImage.setAccessibilityLabel(loc("{0}, as it is now", row.place))
            self.outline.frame = self.pageImage.bounds
            self.outline.boxes = row.boxes.map { NSRect(x: $0.x * scale - 2, y: $0.y * scale - 2, width: max(2, $0.width * scale + 4), height: max(2, $0.height * scale + 4)) }
            self.outline.color = { if case .hit = row.item { return NSColor.systemRed } else { return NSColor.systemOrange } }()
            if let first = self.outline.boxes.first { self.pageImage.scrollToVisible(first.insetBy(dx: -40, dy: -120)) }
        }
    }

    private static func picture(_ image: RenderedImage) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: image.width, pixelsHigh: image.height, bitsPerSample: 8, samplesPerPixel: 3,
                                         hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: image.width * 3, bitsPerPixel: 24),
              let data = rep.bitmapData else { return nil }
        image.pixels.withUnsafeBufferPointer { data.update(from: $0.baseAddress!, count: min($0.count, image.width * image.height * 3)) }
        let picture = NSImage(size: NSSize(width: image.width, height: image.height))
        picture.addRepresentation(rep)
        return picture
    }

    @objc func redactClicked() { finish(list.choice) }
    @objc func cancelClicked() { finish(nil) }

    private func finish(_ choice: RedactionReviewChoice?) {
        render?.cancel()
        if let panel = window, let parent = panel.sheetParent { parent.endSheet(panel) }
        answer.give(choice)
    }

    /// Boxes outlined over the page picture (top-left origin).
    final class OutlineView: NSView {
        var boxes: [NSRect] = [] { didSet { needsDisplay = true } }
        var color = NSColor.systemRed
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) {
            color.setStroke()
            for b in boxes {
                let path = NSBezierPath(rect: b)
                path.lineWidth = 2
                path.stroke()
            }
        }
    }
}

// MARK: The removal report

/// The removal report as a page (the Windows app's `RedactionReportDialog`): what failed, or that the result was read back
/// and searched again; the pages to look at by hand; then, with Inkvolt Pro, each removal's page, pattern and masked value,
/// and Save CSV…. It only ever holds masked values.
@MainActor
final class RemovalReportSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    let report: RedactionReport
    let opening: NSTextField
    private let rows: [[String]]
    private let suggestedName: String
    private let answer = SheetAnswer<Void>()

    init(_ report: RedactionReport, suggestedName: String) {
        self.report = report
        self.suggestedName = suggestedName
        let many = report.files.count > 1
        var rows: [[String]] = []
        for f in report.files {
            for r in f.removals { rows.append([f.file, String(r.page + 1), r.patternName, r.masked, r.outcomeText]) }
            for l in f.looks { rows.append([f.file, String(l.page + 1), l.text, "", loc("Look by hand")]) }
        }
        self.rows = rows
        opening = RedactReviewSheet.note(report.opening, width: 620)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 660, height: 520), styleMask: [.titled, .resizable], backing: .buffered, defer: true)
        super.init(window: panel)
        let title = NSTextField(labelWithString: loc("Redaction Report"))
        title.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        if report.hasFailures { opening.textColor = .systemRed }
        var views: [NSView] = [title, opening]
        if let look = report.lookNote { views.append(RedactReviewSheet.note(look, width: 620, caution: true)) }
        if Pro.allows(.patternRedaction) {
            let table = NSTableView()
            let columns = (many ? [(loc("File"), 150.0)] : []) + [(loc("Page", context: "a column"), 44.0), (loc("What"), 200.0), (loc("Masked value"), 140.0), (loc("Result"), 120.0)]
            for (i, c) in columns.enumerated() {
                let column = NSTableColumn(identifier: .init("\(many ? i : i + 1)"))
                column.title = c.0
                column.width = c.1
                table.addTableColumn(column)
            }
            table.dataSource = self
            table.delegate = self
            table.setAccessibilityLabel(loc("Each removal (values masked)"))
            let scroll = NSScrollView()
            scroll.documentView = table
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.widthAnchor.constraint(equalToConstant: 620).isActive = true
            scroll.heightAnchor.constraint(equalToConstant: 260).isActive = true
            views += [RedactPatternSheet.heading(loc("Each removal (values masked)")), scroll,
                      RedactPatternSheet.caption(loc("A masked value keeps at most the last two digits of a long number. Your words and your own pattern are listed by kind, never as written."))]
        } else {
            views.append(RedactPatternSheet.caption(Pro.locked(.patternRedaction)))
        }
        let save = NSButton(title: loc("Save CSV…"), target: self, action: #selector(saveClicked))
        let close = NSButton(title: loc("Close"), target: self, action: #selector(closeClicked))
        close.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [save, spacer, close])
        views.append(buttons)
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func run(on parent: NSWindow) async {
        await answer.wait {
            if let panel = window { parent.beginSheet(panel) }
        }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let id = tableColumn.flatMap({ Int($0.identifier.rawValue) }), rows.indices.contains(row), id < rows[row].count else { return nil }
        let f = NSTextField(labelWithString: rows[row][id])
        f.lineBreakMode = .byTruncatingTail
        f.toolTip = rows[row][id]
        return f
    }

    @objc func saveClicked() {
        guard let window else { return }
        guard Pro.allows(.patternRedaction) else { return ProWindowController.show(feature: .patternRedaction) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = loc("{0} redaction report.csv", suggestedName)
        panel.message = loc("The report holds masked values only.")
        let csv = report.csv()
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                do {
                    try Data(csv).write(to: url)
                } catch {
                    let alert = NSAlert()
                    alert.messageText = loc("The report couldn't be saved")
                    alert.informativeText = error.localizedDescription
                    alert.beginSheetModal(for: window)
                }
            }
        }
    }

    @objc func closeClicked() {
        if let panel = window, let parent = panel.sheetParent { parent.endSheet(panel) }
        answer.give(())
    }
}
