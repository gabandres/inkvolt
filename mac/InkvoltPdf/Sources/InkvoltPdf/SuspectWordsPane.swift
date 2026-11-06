import AppKit
import PdfCore
import PrintCore

/// The Mac's spelling dictionary for suspect words (the Windows app's spell checker through `ISpelling`):
/// `NSSpellChecker` in the language the words were recognized in, its closest available dictionary. Asked from the
/// recognition's worker thread, so each question goes to the main thread, as AppKit wants.
struct MacSpelling: Spelling {
    let language: String
    private let checkerLanguage: String

    /// Nil when the Mac has no dictionary for the language.
    init?(language: String?) {
        let wanted = language ?? Locale.preferredLanguages.first ?? "en"
        let available = Self.onMain { NSSpellChecker.shared.availableLanguages }
        let underscored = wanted.replacingOccurrences(of: "-", with: "_")
        let base = String(wanted.prefix { $0 != "-" && $0 != "_" })
        guard let match = available.first(where: { $0.caseInsensitiveCompare(underscored) == .orderedSame })
            ?? available.first(where: { $0.caseInsensitiveCompare(base) == .orderedSame })
            ?? available.first(where: { $0.lowercased().hasPrefix(base.lowercased() + "_") }) else { return nil }
        self.language = wanted
        checkerLanguage = match
    }

    func isKnown(_ word: String) -> Bool {
        let language = checkerLanguage
        return Self.onMain {
            let range = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                                           inSpellDocumentWithTag: 0, wordCount: nil)
            return range.location == NSNotFound
        }
    }

    func suggest(_ word: String) -> [String] {
        let language = checkerLanguage
        return Self.onMain {
            NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word,
                                          language: language, inSpellDocumentWithTag: 0) ?? []
        }
    }

    private static func onMain<T: Sendable>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}

/// A suspect word in the pane: where it is, what was read, why it is suspect, and its picture.
struct SuspectWordItem {
    let page: Int
    /// The word's index in its page's text layer.
    let index: Int
    let word: OcrWord
    let language: String?
    var image: NSImage?

    var why: String {
        var why: [String] = []
        if word.suspect.contains(.notInDictionary) { why.append(loc("not in the dictionary")) }
        if word.suspect.contains(.lettersAndDigits) { why.append(loc("letters and digits mixed")) }
        if word.suspect.contains(.oddCharacters) { why.append(loc("odd characters")) }
        if word.suspect.contains(.readDifferently) { why.append(loc("read differently before cleaning")) }
        return why.joined(separator: ", ")
    }

    var caption: String { loc("Page {0} · {1}", CoreLanguage.number(page + 1), why) }
}

/// The Suspect Words pane (the Windows app's): the words Recognize Text marked as suspect (`SuspectWords`), each beside
/// its picture cut from the page. Choosing one shows it on the page; it is corrected in place (the text layer is written
/// again, so search finds the correction) or kept as read. Each is one undo step. Return corrects.
final class SuspectWordsPane: NSView, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    private let summary = NSTextField(wrappingLabelWithString: "")
    private let table = NSTableView()
    private let scroll = NSScrollView()
    let field = NSTextField(string: "")
    let correctButton = NSButton(title: loc("Correct"), target: nil, action: nil)
    let keepButton = NSButton(title: loc("Keep as Read"), target: nil, action: nil)
    private let suggestions = NSStackView()
    private let editor = NSStackView()
    private(set) var items: [SuspectWordItem] = []

    var onSelect: ((SuspectWordItem) -> Void)?
    var onCorrect: ((SuspectWordItem, String) -> Void)?
    var onKeep: ((SuspectWordItem) -> Void)?
    var suggest: ((SuspectWordItem) -> [String])?

    override init(frame: NSRect) {
        super.init(frame: frame)
        summary.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summary.textColor = .secondaryLabelColor
        let column = NSTableColumn(identifier: .init("word"))
        table.addTableColumn(column)
        table.headerView = nil
        table.rowHeight = 58
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(loc("Suspect words"))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        field.placeholderString = loc("The word as it should read")
        field.setAccessibilityLabel(loc("Correction"))
        field.delegate = self
        for (button, action) in [(correctButton, #selector(correctClicked)), (keepButton, #selector(keepClicked))] {
            button.target = self
            button.action = action
            button.controlSize = .small
            button.bezelStyle = .push
        }
        correctButton.toolTip = loc("Replace the recognized word with what is typed (search finds the correction)")
        keepButton.toolTip = loc("The word is right as recognized: take it off the list")
        suggestions.orientation = .horizontal
        suggestions.spacing = 4
        let buttons = NSStackView(views: [correctButton, keepButton])
        buttons.spacing = 4
        editor.orientation = .vertical
        editor.alignment = .leading
        editor.spacing = 4
        editor.setViews([field, suggestions, buttons], in: .top)
        editor.isHidden = true
        let stack = NSStackView(views: [summary, scroll, editor])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            summary.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
            field.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16),
        ])
        setAccessibilityLabel(loc("Suspect words"))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The list, keeping the chosen row where it can; `hasLayers`: the document has recognized text at all.
    func show(_ items: [SuspectWordItem], hasLayers: Bool) {
        let keep = table.selectedRow
        self.items = items
        let pages = Set(items.map(\.page)).count
        let count = items.count
        if count == 0 {
            summary.stringValue = hasLayers ? loc("No suspect words left: every recognized word has been checked or looked right.")
                : loc("No recognized text to check here. Use Recognize Text (OCR) on scanned pages first.")
        } else if pages > 1 {
            summary.stringValue = loc("{0} suspect words on {1} pages. Correct a word or keep it as read.", CoreLanguage.number(count), CoreLanguage.number(pages))
        } else {
            summary.stringValue = count == 1 ? loc("{0} suspect word on 1 page. Correct a word or keep it as read.", CoreLanguage.number(count))
                : loc("{0} suspect words on 1 page. Correct a word or keep it as read.", CoreLanguage.number(count))
        }
        table.reloadData()
        if !items.isEmpty {
            table.selectRowIndexes([min(max(keep, 0), items.count - 1)], byExtendingSelection: false)
        }
        showSelected()
    }

    /// A word's picture, once cut from its page.
    func setImage(_ image: NSImage?, at row: Int) {
        guard row < items.count else { return }
        items[row].image = image
        table.reloadData(forRowIndexes: [row], columnIndexes: [0])
    }

    var summaryText: String { summary.stringValue }
    var selected: SuspectWordItem? { table.selectedRow >= 0 && table.selectedRow < items.count ? items[table.selectedRow] : nil }
    var suggestionTitles: [String] { suggestions.arrangedSubviews.compactMap { ($0 as? NSButton)?.title } }

    func choose(_ row: Int) { table.selectRowIndexes([row], byExtendingSelection: false) }

    func press(suggestion index: Int) { (suggestions.arrangedSubviews[index] as? NSButton)?.performClick(nil) }

    // MARK: Table

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let item = items[row]
        let picture = NSImageView()
        picture.image = item.image
        picture.imageScaling = .scaleProportionallyDown
        picture.widthAnchor.constraint(equalToConstant: 72).isActive = true
        picture.heightAnchor.constraint(equalToConstant: 30).isActive = true
        picture.setAccessibilityElement(false)
        let word = NSTextField(labelWithString: item.word.text)
        word.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        let caption = NSTextField(labelWithString: item.caption)
        caption.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        caption.textColor = .secondaryLabelColor
        caption.lineBreakMode = .byTruncatingTail
        let text = NSStackView(views: [word, caption])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        let row = NSStackView(views: [picture, text])
        row.spacing = 6
        row.setAccessibilityElement(true)
        row.setAccessibilityLabel(loc("{0}. Page {1}. {2}", item.word.text, CoreLanguage.number(item.page + 1), item.why))
        return row
    }

    func tableViewSelectionDidChange(_ notification: Notification) { showSelected() }

    private func showSelected() {
        guard let item = selected else {
            editor.isHidden = true
            return
        }
        editor.isHidden = false
        field.stringValue = item.word.text
        for v in suggestions.arrangedSubviews { v.removeFromSuperview() }
        let core = SuspectWords.core(item.word.text)
        for s in (suggest?(item) ?? []).prefix(4) {
            // Keep what was around the word ("rlver," → "river,").
            let whole = item.word.text.range(of: core).map { item.word.text.replacingCharacters(in: $0, with: s) } ?? s
            let b = NSButton(title: whole, target: self, action: #selector(suggestionClicked(_:)))
            b.controlSize = .small
            b.bezelStyle = .push
            b.toolTip = loc("Correct to “{0}”", whole)
            suggestions.addArrangedSubview(b)
        }
        suggestions.isHidden = suggestions.arrangedSubviews.isEmpty
        onSelect?(item)
    }

    // MARK: Actions

    @objc private func suggestionClicked(_ sender: NSButton) {
        guard let item = selected else { return }
        onCorrect?(item, sender.title)
    }

    @objc private func correctClicked() {
        guard let item = selected else { return }
        onCorrect?(item, field.stringValue)
    }

    @objc private func keepClicked() {
        guard let item = selected else { return }
        onKeep?(item)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.insertNewline(_:)) {
            correctClicked()
            return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            window?.makeFirstResponder(table)
            return true
        }
        return false
    }
}

// MARK: The window's commands

extension DocumentWindowController {
    func wireSuspectWords() {
        let pane = sidebar.suspectWords
        pane.onSelect = { [weak self] item in
            guard let self else { return }
            let box = Self.turnedBounds(item.word)
            self.go(item.page, targetY: box.y)
            self.pages.flash(item.page, box)
        }
        pane.onCorrect = { [weak self] item, text in self?.correctSuspect(item, text) }
        pane.onKeep = { [weak self] item in self?.keepSuspect(item) }
        pane.suggest = { item in
            guard item.word.suspect.contains(.notInDictionary), let spelling = MacSpelling(language: item.language) else { return [] }
            return spelling.suggest(SuspectWords.core(item.word.text))
        }
        refreshSuspectWords()
    }

    /// Reads the document's suspect words again (at opening and after every change): a file recognized by Recognize
    /// Text, Batch or a scan lists those left. A file whose bytes can't hold a text layer isn't parsed for one.
    func refreshSuspectWords() {
        guard let session = pdf.session else { return }
        let layers = TextLayer.mayHaveLayer(session.data) ? ((try? TextLayer.words(session.data, session.password)) ?? [:]) : [:]
        let items = layers.sorted { $0.key < $1.key }.flatMap { page, layer in
            layer.words.enumerated().filter { !$0.element.suspect.isEmpty }
                .map { SuspectWordItem(page: page, index: $0.offset, word: $0.element, language: layer.language) }
        }
        sidebar.showsSuspectWords = !items.isEmpty || sidebar.shownPane == .suspectWords
        sidebar.suspectWords.show(items, hasLayers: !layers.isEmpty)
        loadSuspectPictures(items)
    }

    /// Cuts each word's picture from its page, with a little room around it.
    private func loadSuspectPictures(_ items: [SuspectWordItem]) {
        guard let engine = pdf.engine else { return }
        for (row, item) in items.enumerated() {
            guard item.page < engine.pageCount else { continue }
            let g = engine.page(item.page)
            let box = Self.turnedBounds(item.word)
            let (padX, padY) = (max(3, item.word.rect.height * 0.4), max(1, item.word.rect.height * 0.12))
            let x0 = max(0, box.x - padX), y0 = max(0, box.y - padY)
            let region = RectD(x0, y0, min(g.width, box.right + padX) - x0, min(g.height, box.bottom + padY) - y0)
            guard !region.isEmpty else { continue }
            let scale = min(max(44 / max(1, item.word.rect.height), 1), 4)
            guard let img = try? engine.render(item.page, scale: scale, region: region) else { continue }
            sidebar.suspectWords.setImage(Self.nsImage(img), at: row)
        }
    }

    private static func nsImage(_ img: RenderedImage) -> NSImage? {
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: img.width, pixelsHigh: img.height, bitsPerSample: 8,
                                         samplesPerPixel: 3, hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: img.stride, bitsPerPixel: 24), let base = rep.bitmapData else { return nil }
        img.pixels.withUnsafeBufferPointer { src in base.update(from: src.baseAddress!, count: min(src.count, img.stride * img.height)) }
        let image = NSImage(size: NSSize(width: img.width, height: img.height))
        image.addRepresentation(rep)
        return image
    }

    /// The upright box around a word's turned box.
    static func turnedBounds(_ w: OcrWord) -> RectD {
        if w.angle == 0 { return w.rect }
        let (s, c) = (sin(w.angle * .pi / 180), cos(w.angle * .pi / 180))
        let (hw, hh) = (w.rect.width / 2, w.rect.height / 2)
        let ex = abs(hw * c) + abs(hh * s), ey = abs(hw * s) + abs(hh * c)
        return RectD(w.rect.centerX - ex, w.rect.centerY - ey, 2 * ex, 2 * ey)
    }

    /// Tools › Review Suspect Words: the pane on the document's suspect words.
    @objc func reviewSuspectWords(_ sender: Any?) {
        if let item = split.splitViewItems.first, item.isCollapsed { item.animator().isCollapsed = false }
        sidebar.showsSuspectWords = true
        sidebar.show(.suspectWords)
        refreshSuspectWords()
        window?.makeFirstResponder(sidebar.suspectWords)
    }

    func correctSuspect(_ item: SuspectWordItem, _ typed: String) {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return notify(loc("A word can't be empty: type the correction, or choose Keep as Read.")) }
        if text.contains(where: \.isWhitespace) { return notify(loc("Type one word: a correction replaces one recognized word.")) }
        let (page, index) = (item.page, item.index)
        Task { @MainActor in
            if await self.editor.run(loc("Correct recognized word"), { d, pw in try TextLayer.correct(d, pw, page, index, text) }) {
                self.notify(loc("“{0}” is now “{1}” on page {2}; search finds it.", item.word.text, text, CoreLanguage.number(page + 1)), canUndo: true)
            }
        }
    }

    func keepSuspect(_ item: SuspectWordItem) {
        let (page, index) = (item.page, item.index)
        Task { @MainActor in
            _ = await self.editor.run(loc("Keep recognized word")) { d, pw in try TextLayer.keep(d, pw, page, index) }

        }
    }
}
