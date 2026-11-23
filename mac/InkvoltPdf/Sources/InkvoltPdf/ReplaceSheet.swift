import AppKit
import PdfCore
import PrintCore

/// Find and Replace (roadmap 4.2; Windows' `ReplaceDialog` and `DocumentTab.Replace`): what to find and what to put instead,
/// Match case and Whole words only, and every match listed with its page and the words around it as it is typed (searched
/// off the main thread). Replace changes the selected match at once and finds again, going on to the next; Replace All the
/// ones left ticked, as one edit (one undo step; a signed file gets it appended). What couldn't be replaced as asked is
/// listed afterwards, never dropped. Edit › Find › Find and Replace….
extension DocumentWindowController {
    @objc func showReplace(_ sender: Any?) {
        guard let window, pdf.session != nil, replaceSheet == nil else { return NSSound.beep() }
        if organizerShown { showOrganizer(false) }
        // The selected words (a phrase on one line) are what people usually mean to replace.
        if let selected = pages.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines), !selected.isEmpty, selected.count <= 200,
           !selected.contains("\n") {
            ReplaceSheet.lastQuery.find = selected
        }
        let sheet = ReplaceSheet(controller: self)
        replaceSheet = sheet
        if let panel = sheet.window { window.beginSheet(panel) }
        sheet.search()
    }

    /// Replaces `matches` with `with` as one edit, then says how it went: a notice when every one was made as asked, else
    /// the list of what was done instead. False when nothing was committed.
    @discardableResult
    func replaceMatches(_ matches: [ReplaceMatch], with: String, all: Bool) async -> Bool {
        guard !matches.isEmpty, let window else { return false }
        // Thousands of paragraphs take a while: shown page by page, with Cancel (nothing is changed then). Replace from the
        // open sheet shows none (one paragraph).
        let sheet = ProgressSheet(title: loc("Replacing"), text: loc("Starting…"))
        if all && window.attachedSheet == nil { sheet.begin(on: window) }
        let token = sheet.token
        let box = ReplaceOutcome()
        let made = await editor.run(all ? loc("Replace All") : loc("Replace")) { d, pw in
            let r = try TextReplace.replace(d, pw, matches, with: with, cancel: token, progress: { done, total in
                Task { @MainActor in
                    sheet.update(loc("Page {0} of {1}", CoreLanguage.number(done + 1), CoreLanguage.number(total)), Double(done) / Double(max(total, 1)))
                }
            })
            box.result = r
            return r.data
        }
        sheet.end()
        lastReplace = box.result
        guard let result = box.result, made || editor.lastOutcome == .noChange else { return false }
        if !result.notes.isEmpty {
            showReplaceNotes(result)
        } else {
            notify(result.replaced == 1 ? loc("Replaced 1 match.") : loc("Replaced {0} matches.", CoreLanguage.number(result.replaced)), canUndo: made)
        }
        return made
    }

    /// Each replacement not made as asked, and what was done instead.
    private func showReplaceNotes(_ result: ReplaceResult) {
        let intro = loc("Replaced: {0}. Left as they were: {1}. Undo (⌘Z) puts back every replacement made.",
                        CoreLanguage.number(result.replaced), CoreLanguage.number(result.left))
        let lines = result.notes.map(Self.noteLine)
        if Report.skipsDialogs { return notify(intro + " " + lines.joined(separator: " ")) }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = loc("Replacements to check")
        alert.informativeText = intro
        let scroll = NSTextView.scrollableTextView()
        scroll.frame = NSRect(x: 0, y: 0, width: 520, height: min(300, CGFloat(lines.count) * 44 + 20))
        scroll.borderType = .bezelBorder
        if let text = scroll.documentView as? NSTextView {
            text.string = lines.joined(separator: "\n\n")
            text.isEditable = false
            text.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            text.setAccessibilityLabel(loc("Replacements to check"))
        }
        alert.accessoryView = scroll
        alert.beginSheetModal(for: window)
    }

    /// "Page 2 · “…the invoice total…”: what happened."
    static func noteLine(_ n: ReplaceNote) -> String {
        func chars(_ list: [String]) -> String {
            list.prefix(10).map { $0 == " " ? loc("a space") : "“\($0)”" }.joined(separator: ", ")
        }
        var what: String
        switch n.kind {
        case .standIn:
            what = loc("replaced; {0} drawn in {1}, the closest font on this Mac (the paragraph's font lacks them).", chars(n.chars), n.fonts.joined(separator: ", "))
        case .wider:
            what = loc("replaced; text on one line doesn't wrap, and this line is {0} pt wider: check it doesn't run into what's beside it.",
                       CoreLanguage.number(Int(exactly: min(max(n.wider, 0), 1e6).rounded()) ?? 0))
        case .missing:
            what = loc("left as it was: no font on this Mac has {0}.", chars(n.chars))
        case .wouldOverlap:
            what = loc("left as it was: the longer paragraph would run into the text or picture below it. Change it in Edit Text & Images to decide.")
        case .cantEdit:
            what = loc("left as it was: {0}", n.why ?? "")
        case .changed:
            what = loc("left as it was: the paragraph changed since it was found. Search again.")
        }
        if n.count > 1 { what += loc(" ({0} matches in this paragraph)", CoreLanguage.number(n.count)) }
        let m = n.match
        return loc("Page {0} · “{1}”: {2}", CoreLanguage.number(m.pageIndex + 1), ReplaceSheet.shorten(m.before + m.found + m.after), what)
    }
}

/// What the edit's worker made, handed back to the window.
private final class ReplaceOutcome: @unchecked Sendable {
    var result: ReplaceResult?
}

/// The Find and Replace sheet: the fields, the list of matches (each ticked unless its paragraph can't be changed), Replace,
/// Replace All and Close.
@MainActor
final class ReplaceSheet: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    /// The last search's text and options, offered again next time (Windows keeps them per tab).
    static var lastQuery = ReplaceQuery("")
    static var lastWith = ""

    private weak var controller: DocumentWindowController?
    let findField = NSTextField(string: "")
    let withField = NSTextField(string: "")
    let matchCase = NSButton(checkboxWithTitle: loc("Match case"), target: nil, action: nil)
    let wholeWords = NSButton(checkboxWithTitle: loc("Whole words only"), target: nil, action: nil)
    private let status = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    let replaceButton = NSButton(title: loc("Replace"), target: nil, action: nil)
    let replaceAllButton = NSButton(title: loc("Replace All"), target: nil, action: nil)
    private let closeButton = NSButton(title: loc("Close"), target: nil, action: nil)

    /// The matches listed, and which are unticked (by where they are, kept from one search to the next).
    private(set) var matches: [ReplaceMatch] = []
    private var unticked = Set<ReplaceKey>()
    private var generation = 0
    private var searching: CancelToken?
    private var pendingSearch: DispatchWorkItem?
    /// The match to select once the next search is in (after Replace).
    private var selectNext: ((([ReplaceMatch]) -> Int?))?
    /// A search or a replacement is under way (the self-test waits on it).
    private(set) var busy = false

    init(controller: DocumentWindowController) {
        self.controller = controller
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        panel.title = loc("Find and Replace")
        panel.minSize = NSSize(width: 520, height: 360)
        super.init(window: panel)
        build(panel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build(_ panel: NSPanel) {
        findField.stringValue = Self.lastQuery.find
        withField.stringValue = Self.lastWith
        matchCase.state = Self.lastQuery.matchCase ? .on : .off
        wholeWords.state = Self.lastQuery.wholeWord ? .on : .off
        findField.setAccessibilityLabel(loc("Find"))
        withField.setAccessibilityLabel(loc("Replace with"))
        findField.placeholderString = loc("Text to find")
        withField.placeholderString = loc("Text to put instead")
        for f in [findField, withField] {
            f.delegate = self
            f.widthAnchor.constraint(equalToConstant: 420).isActive = true
        }
        for b in [matchCase, wholeWords] {
            b.target = self
            b.action = #selector(optionsChanged)
        }
        status.textColor = .secondaryLabelColor
        status.preferredMaxLayoutWidth = 560

        let tick = NSTableColumn(identifier: .init("tick"))
        tick.title = ""
        tick.width = 24
        let match = NSTableColumn(identifier: .init("match"))
        match.title = loc("Matches")
        match.resizingMask = .autoresizingMask
        table.addTableColumn(tick)
        table.addTableColumn(match)
        table.headerView = nil
        table.usesAutomaticRowHeights = true
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(loc("Matches"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true

        replaceButton.target = self
        replaceButton.action = #selector(replaceClicked)
        replaceButton.toolTip = loc("Replaces the selected match now and goes on to the next")
        replaceAllButton.target = self
        replaceAllButton.action = #selector(replaceAllClicked)
        replaceAllButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(closeClicked)
        closeButton.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)

        let grid = NSGridView(views: [
            [NSTextField(labelWithString: loc("Find:")), findField],
            [NSTextField(labelWithString: loc("Replace with:")), withField],
            [NSGridCell.emptyContentView, NSStackView(views: [matchCase, wholeWords])],
        ])
        grid.column(at: 0).xPlacement = .trailing
        grid.rowSpacing = 8
        let buttons = NSStackView(views: [closeButton, spacer, replaceButton, replaceAllButton])
        let stack = NSStackView(views: [grid, status, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 20, bottom: 16, right: 20)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        panel.contentView = stack
        panel.initialFirstResponder = findField
        update()
    }

    var query: ReplaceQuery { ReplaceQuery(findField.stringValue, matchCase: matchCase.state == .on, wholeWord: wholeWords.state == .on) }

    /// The matches ticked to be replaced.
    var ticked: [ReplaceMatch] { matches.filter { $0.blocked == nil && !unticked.contains(ReplaceKey.of($0)) } }

    func controlTextDidChange(_ obj: Notification) {
        guard (obj.object as? NSTextField) === findField else { return update() }
        // Searched once typing rests a moment; a newer key wins.
        pendingSearch?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.search() } }
        pendingSearch = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    @objc private func optionsChanged() { search() }

    /// Finds the query in the document as it is now, off the main thread; the list follows.
    func search() {
        pendingSearch?.cancel()
        generation += 1
        let generation = generation
        searching?.cancel()
        let q = query
        guard let session = controller?.pdf.session, !q.find.isEmpty else {
            matches = []
            table.reloadData()
            update(loc("Type what to find. Matches are listed here with their page and the words around them."))
            return
        }
        let cancel = CancelToken()
        searching = cancel
        busy = true
        let (data, password) = (session.data, session.password)
        let pageCount = controller?.engine.pageCount ?? 0
        update(loc("Searching…"))
        Task { @MainActor [weak self] in
            let found = await Task.detached { () -> Result<ReplaceFound, any Error> in
                Result {
                    try TextReplace.find(data, password, q, progress: { page in
                        Task { @MainActor [weak self] in
                            guard let self, self.generation == generation else { return }
                            self.status.stringValue = loc("Searching… page {0} of {1}", CoreLanguage.number(page), CoreLanguage.number(pageCount))
                        }
                    }, cancel: cancel)
                }
            }.value
            guard let self, self.generation == generation else { return }
            busy = false
            switch found {
            case .success(let f):
                show(f)
            case .failure(let error):
                if error is CancellationError { return }
                matches = []
                table.reloadData()
                update(loc("The document's text couldn't be searched. Try again, or reopen the file."))
            }
        }
    }

    private func show(_ found: ReplaceFound) {
        matches = found.matches
        table.reloadData()
        var text: String
        if matches.isEmpty {
            text = loc("No matches in the document's text.")
        } else {
            let pages = found.pages == 1 ? loc("1 page") : loc("{0} pages", CoreLanguage.number(found.pages))
            text = matches.count == 1 ? loc("1 match. Untick it to keep it as it is.")
                : loc("{0} matches on {1}. Untick any to keep as they are.", CoreLanguage.number(matches.count), pages)
            if found.cutShort { text += " " + loc("Only the first {0} are listed: make the search longer to see the rest.", CoreLanguage.number(TextReplace.maxMatches)) }
            if matches.contains(where: { $0.blocked != nil }) { text += " " + loc("Some are in text that can't be changed (said under them).") }
        }
        if let pick = selectNext?(matches) {
            table.selectRowIndexes([pick], byExtendingSelection: false)
            table.scrollRowToVisible(pick)
        }
        selectNext = nil
        update(text)
    }

    private func update(_ text: String? = nil) {
        if let text { status.stringValue = text }
        let n = ticked.count
        replaceAllButton.title = n > 0 ? loc("Replace All ({0})", CoreLanguage.number(n)) : loc("Replace All")
        replaceAllButton.isEnabled = n > 0 && !busy
        replaceButton.isEnabled = !ticked.isEmpty && !busy
    }

    // MARK: The list

    func numberOfRows(in tableView: NSTableView) -> Int { matches.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let m = matches[row]
        let key = ReplaceKey.of(m)
        if tableColumn?.identifier.rawValue == "tick" {
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(tickToggled(_:)))
            box.tag = row
            box.state = m.blocked == nil && !unticked.contains(key) ? .on : .off
            box.isEnabled = m.blocked == nil
            box.setAccessibilityLabel(loc("{0}: {1}", loc("Page {0}", CoreLanguage.number(m.pageIndex + 1)), m.before + m.found + m.after))
            return box
        }
        let line = NSMutableAttributedString(string: loc("Page {0}", CoreLanguage.number(m.pageIndex + 1)) + "  ",
                                             attributes: [.foregroundColor: NSColor.secondaryLabelColor])
        line.append(NSAttributedString(string: m.before))
        line.append(NSAttributedString(string: m.found, attributes: [.font: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize)]))
        line.append(NSAttributedString(string: m.after))
        if let why = m.blocked {
            line.append(NSAttributedString(string: "\n" + loc("This paragraph can't be edited: {0}.", why),
                                           attributes: [.foregroundColor: NSColor.secondaryLabelColor, .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]))
        }
        let label = NSTextField(labelWithAttributedString: line)
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    @objc private func tickToggled(_ sender: NSButton) {
        guard sender.tag < matches.count else { return }
        let key = ReplaceKey.of(matches[sender.tag])
        if sender.state == .on { unticked.remove(key) } else { unticked.insert(key) }
        update()
    }

    /// Unticks the match at `row` (the self-test).
    func untick(_ row: Int) {
        guard row < matches.count else { return }
        unticked.insert(ReplaceKey.of(matches[row]))
        table.reloadData()
        update()
    }

    // MARK: Buttons

    /// Replaces the selected match (else the first ticked) now, finds again and selects the next one after it.
    @objc func replaceClicked() {
        let selected = table.selectedRow >= 0 && table.selectedRow < matches.count ? matches[table.selectedRow] : nil
        guard let m = selected.flatMap({ s in ticked.contains(s) ? s : nil }) ?? ticked.first, let controller else { return NSSound.beep() }
        let with = withField.stringValue
        remember()
        busy = true
        update()
        Task { @MainActor [weak self] in
            await controller.replaceMatches([m], with: with, all: false)
            guard let self else { return }
            busy = false
            // The ticks of the matches after it, where they are now.
            let inserted = with.utf16.count
            unticked = Set(unticked.compactMap { $0.after(m, inserted: inserted) })
            selectNext = { TextReplace.nextAfter($0, m, inserted: inserted) }
            search()
        }
    }

    /// Replace All: the ticked matches, after the sheet closes.
    @objc func replaceAllClicked() {
        let chosen = ticked
        guard !chosen.isEmpty, let controller else {
            update(loc("Tick at least one match to replace, or close."))
            return
        }
        let with = withField.stringValue
        remember()
        close(sheet: true)
        Task { @MainActor in await controller.replaceMatches(chosen, with: with, all: true) }
    }

    @objc func closeClicked() {
        remember()
        close(sheet: true)
    }

    private func remember() {
        Self.lastQuery = query
        Self.lastWith = withField.stringValue
    }

    private func close(sheet: Bool) {
        searching?.cancel()
        pendingSearch?.cancel()
        if let panel = window, let parent = panel.sheetParent { parent.endSheet(panel) }
        window?.orderOut(nil)
        controller?.replaceSheet = nil
    }

    /// Text from the page, shortened to fit a line.
    static func shorten(_ s: String) -> String { s.count <= 90 ? s : String(s.prefix(89)) + "…" }
}
