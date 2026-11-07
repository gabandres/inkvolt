import AppKit
import PdfCore
import PrintCore

/// The folders indexed in the app (Edit › Find › Search Folders…, the Windows app's `FolderSearches`): kept in the
/// settings, kept current while Inkvolt PDF is open and stopped when it quits. Each has its own index file in Application
/// Support's "Inkvolt PDF/FolderIndex"; nothing is written anywhere else, nothing leaves the Mac.
@MainActor
final class FolderSearches {
    static let shared = FolderSearches()
    static let settingsKey = "IndexedFolders"

    /// Where the index files go; the self-test points it at a folder of its own.
    static var indexDirectory: String = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Inkvolt PDF/FolderIndex").path
    }()

    /// One folder in the app: its setting and its indexer.
    @MainActor
    final class Folder {
        let path: String
        var paused: Bool
        fileprivate(set) var indexer: FolderIndexer?

        init(path: String, paused: Bool) {
            self.path = path
            self.paused = paused
        }

        var name: String { FileManager.default.displayName(atPath: path) }

        var statusText: String {
            if let indexer { return indexer.status.text }
            return Pro.allows(.folderSearch) ? loc("Stopped.") : Pro.locked(.folderSearch)
        }
    }

    private(set) var all: [Folder] = []
    /// The folders or a status changed (on the main thread, at most a few times a second).
    var changed: (() -> Void)?
    /// The self-test's folders aren't kept in the settings.
    var persists = true
    private var notePending = false

    /// The folders saved in the settings, each indexing unless it was left paused. Not in the self-test.
    func startSaved() {
        guard !Report.isRunning else { return }
        for entry in AppSettings.defaults.array(forKey: Self.settingsKey) as? [[String: Any]] ?? [] {
            guard let path = entry["folder"] as? String, !all.contains(where: { $0.path == path }) else { continue }
            let f = Folder(path: path, paused: entry["paused"] as? Bool ?? false)
            all.append(f)
            start(f)
        }
    }

    private func save() {
        if persists { AppSettings.defaults.set(all.map { ["folder": $0.path, "paused": $0.paused] }, forKey: Self.settingsKey) }
        noteChange()
    }

    /// What is wrong with indexing `path`, or nil.
    func problem(adding path: String) -> String? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return loc("There is no folder {0}.", path)
        }
        let full = Self.standard(path)
        for other in all {
            let known = Self.standard(other.path)
            if known == full { return loc("That folder is indexed already.") }
            if full.hasPrefix(known + "/") { return loc("That folder is inside {0}, which is indexed already.", other.path) }
            if known.hasPrefix(full + "/") { return loc("{0}, indexed already, is inside that folder. Remove it first, then add the larger one.", other.path) }
        }
        return nil
    }

    private static func standard(_ path: String) -> String {
        var p = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        return p
    }

    @discardableResult
    func add(_ path: String) -> Folder {
        let f = Folder(path: Self.standard(path), paused: false)
        all.append(f)
        start(f)
        save()
        return f
    }

    /// Stops indexing the folder and deletes its index file. Its PDFs aren't touched.
    func remove(_ f: Folder) {
        all.removeAll { $0 === f }
        let indexer = f.indexer ?? FolderIndexer(folder: f.path, basePath: FolderIndex.basePathFor(Self.indexDirectory, f.path))
        f.indexer = nil
        indexer.changed = nil
        save()
        // Off this thread: a reading may need a moment to stop.
        Thread.detachNewThread { indexer.stopAndDelete() }
    }

    func setPaused(_ f: Folder, _ paused: Bool) {
        f.paused = paused
        if paused { f.indexer?.pause() } else { f.indexer?.resume() }
        save()
    }

    /// Quitting: the readings stop and what was read is committed, briefly.
    func stopAll() {
        for f in all { f.indexer?.stop(wait: 2) }
    }

    /// Starts indexing, paused if it was left so. Locked: nothing runs, and the index file stays for when a key is back.
    func start(_ f: Folder) {
        guard f.indexer == nil, Pro.allows(.folderSearch) else { return }
        let indexer = FolderIndexer(folder: f.path, basePath: FolderIndex.basePathFor(Self.indexDirectory, f.path), startPaused: f.paused)
        indexer.changed = { DispatchQueue.main.async { MainActor.assumeIsolated { FolderSearches.shared.noteChange() } } }
        f.indexer = indexer
        indexer.start()
    }

    /// Calls `changed` soon, once for a burst of status changes.
    func noteChange() {
        guard !notePending else { return }
        notePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            MainActor.assumeIsolated {
                self.notePending = false
                self.changed?()
            }
        }
    }
}

/// Edit › Find › Search Folders… (the Windows app's `FolderSearchWindow`): a word across the indexed folders, answered from
/// the index, with the text around each hit; a result opens at the hit with the Find bar showing the words. Below it the
/// folders, each with what the index has of it, and Add Folder…, Pause, Skipped Files…, Rebuild… and Remove….
@MainActor
final class FolderSearchWindowController: NSWindowController, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    static var shared: FolderSearchWindowController?
    /// Pages to list at most.
    static let limit = 500

    struct Row {
        let folder: String
        let hit: FolderHit
    }

    let field = NSSearchField()
    let matchCase = NSButton(checkboxWithTitle: loc("Match case"), target: nil, action: nil)
    let wholeWords = NSButton(checkboxWithTitle: loc("Whole words"), target: nil, action: nil)
    let ignoreAccents = NSButton(checkboxWithTitle: loc("Ignore accents"), target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    let results = ReturnTableView()
    let folders = NSTableView()
    let pauseButton = NSButton(title: loc("Pause"), target: nil, action: nil)
    private let locked = NSStackView()
    private(set) var rows: [Row] = []
    /// The last search's words and options, for the Find bar a result opens with.
    private(set) var lastQuery = ""
    private(set) var lastOptions = FolderSearchOptions()
    private var cancel: CancelToken?
    private var generation = 0
    /// Calls once a search has said what it found (the self-test waits on it).
    var onSearched: (() -> Void)?

    static func show() {
        let c = shared ?? FolderSearchWindowController()
        shared = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.window?.makeFirstResponder(c.field)
        c.refreshFolders()
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = loc("Search Folders")
        window.isRestorable = false
        window.minSize = NSSize(width: 560, height: 480)
        super.init(window: window)
        window.delegate = self
        build()
        FolderSearches.shared.changed = { [weak self] in self?.refreshFolders() }
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let intro = NSTextField(wrappingLabelWithString: loc("Find a word in every PDF of a folder and its subfolders. The index stays on this Mac, kept up to date while Inkvolt PDF is open, and holds the text of those PDFs (never of files with a password). Scans are found once they have a text layer: Recognize Text adds one."))
        intro.textColor = .secondaryLabelColor

        let lockedTitle = NSTextField(labelWithString: Pro.locked(.folderSearch))
        lockedTitle.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let lockedText = NSTextField(wrappingLabelWithString: Pro.describe(.folderSearch))
        let about = NSButton(title: loc("About Inkvolt Pro…"), target: self, action: #selector(aboutPro))
        locked.setViews([lockedTitle, lockedText, about], in: .leading)
        locked.orientation = .vertical
        locked.alignment = .leading

        field.placeholderString = loc("A word or phrase")
        field.setAccessibilityLabel(loc("Search the indexed folders"))
        field.sendsWholeSearchString = false
        field.sendsSearchStringImmediately = false
        field.target = self
        field.action = #selector(search)
        field.delegate = self
        let searchButton = NSButton(title: loc("Search"), target: self, action: #selector(search))
        searchButton.keyEquivalent = "\r"
        let searchRow = NSStackView(views: [field, searchButton])
        ignoreAccents.state = .on
        ignoreAccents.toolTip = loc("Find é, è and ê when you type e")
        for box in [matchCase, wholeWords, ignoreAccents] {
            box.target = self
            box.action = #selector(search)
        }
        let options = NSStackView(views: [matchCase, wholeWords, ignoreAccents])

        for (id, title, width) in [("file", loc("File", context: "column"), 220.0), ("where", loc("Where"), 120.0), ("text", loc("Text"), 440.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            results.addTableColumn(column)
        }
        results.dataSource = self
        results.delegate = self
        results.usesAlternatingRowBackgroundColors = true
        results.setAccessibilityLabel(loc("Results"))
        results.target = self
        results.doubleAction = #selector(openSelected)
        results.onReturn = { [weak self] in self?.openSelected() }
        let resultScroll = scroll(results, minHeight: 220)

        let folderColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("folder"))
        folderColumn.title = loc("Folder")
        folderColumn.width = 260
        let stateColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        stateColumn.title = loc("Index")
        stateColumn.width = 520
        folders.addTableColumn(folderColumn)
        folders.addTableColumn(stateColumn)
        folders.dataSource = self
        folders.delegate = self
        folders.setAccessibilityLabel(loc("Indexed folders"))
        let folderScroll = scroll(folders, minHeight: 110)
        let heading = NSTextField(labelWithString: loc("Indexed folders"))
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        pauseButton.target = self
        pauseButton.action = #selector(pauseClicked)
        let buttons = NSStackView(views: [
            NSButton(title: loc("Add Folder…"), target: self, action: #selector(addFolder)), pauseButton,
            NSButton(title: loc("Skipped Files…"), target: self, action: #selector(showSkipped)),
            NSButton(title: loc("Rebuild…"), target: self, action: #selector(rebuildClicked)),
            NSButton(title: loc("Remove…"), target: self, action: #selector(removeClicked)),
        ])

        let stack = NSStackView(views: [intro, locked, searchRow, options, status, resultScroll, heading, folderScroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        window?.contentView = content
        var constraints = [
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ]
        for v in [intro, searchRow, status, resultScroll, folderScroll] as [NSView] {
            constraints.append(v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40))
        }
        NSLayoutConstraint.activate(constraints)
        resultScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        updateLocked()
    }

    private func scroll(_ table: NSTableView, minHeight: CGFloat) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = table
        s.hasVerticalScroller = true
        s.borderType = .bezelBorder
        s.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight).isActive = true
        return s
    }

    private func updateLocked() {
        let allowed = Pro.allows(.folderSearch)
        locked.isHidden = allowed
        field.isEnabled = allowed
    }

    @objc private func aboutPro() { ProWindowController.show(feature: .folderSearch) }

    func windowWillClose(_ notification: Notification) {
        cancel?.cancel()
        // What a search kept in memory, until the next one.
        for f in FolderSearches.shared.all { f.indexer?.currentIndex?.forgetCaches() }
        Self.shared = nil
        FolderSearches.shared.changed = nil
    }

    // MARK: Searching

    var options: FolderSearchOptions {
        FolderSearchOptions(matchCase: matchCase.state == .on, wholeWord: wholeWords.state == .on, ignoreAccents: ignoreAccents.state == .on,
                            maxPages: Self.limit)
    }

    @objc func search() {
        let query = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        cancel?.cancel()
        generation += 1
        rows = []
        results.reloadData()
        guard !query.isEmpty else {
            status.stringValue = ""
            onSearched?()
            return
        }
        let options = options
        lastQuery = query
        lastOptions = options
        let targets = FolderSearches.shared.all.map { (path: $0.path, indexer: $0.indexer) }
        if targets.isEmpty {
            status.stringValue = loc("No folder is indexed yet. Add Folder… chooses one.")
            onSearched?()
            return
        }
        status.stringValue = loc("Searching…")
        let token = CancelToken()
        cancel = token
        let generation = generation
        Thread.detachNewThread {
            let outcome = Self.run(query, options, targets, token)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard generation == self.generation else { return }
                    self.show(outcome, query)
                }
            }
        }
    }

    struct Outcome: Sendable {
        var rows: [(folder: String, hit: FolderHit)] = []
        var candidates = 0
        var hasWords = true
        var notOpen = false
        var stillIndexing = false
        var problems: [String] = []
        var cancelled = false
    }

    /// The search itself, off the main thread: each folder's index in turn, to the limit.
    nonisolated private static func run(_ query: String, _ options: FolderSearchOptions, _ targets: [(path: String, indexer: FolderIndexer?)],
                                        _ cancel: CancelToken) -> Outcome {
        var out = Outcome()
        for target in targets {
            guard let indexer = target.indexer, let index = indexer.currentIndex else {
                out.notOpen = true
                continue
            }
            if indexer.status.phase != .upToDate { out.stillIndexing = true }
            do {
                var left = options
                left.maxPages = max(0, options.maxPages - out.rows.count)
                if left.maxPages == 0 { break }
                let run = try index.search(query, options: left, cancel: cancel)
                defer { run.close() }
                out.hasWords = run.hasWords
                out.candidates += run.candidatePages
                while let hit = try run.next(cancel: cancel) { out.rows.append((target.path, hit)) }
            } catch is CancellationError {
                out.cancelled = true
                return out
            } catch is FolderIndexDamaged {
                indexer.rebuild()
                out.problems.append(loc("The index of {0} was damaged and is being built again.", target.path))
            } catch {
                out.problems.append(loc("The search stopped on an error: {0}", "\(error)"))
            }
        }
        return out
    }

    private func show(_ outcome: Outcome, _ query: String) {
        if outcome.cancelled { return }
        rows = outcome.rows.map { Row(folder: $0.folder, hit: $0.hit) }
        results.reloadData()
        var said: String
        if !outcome.hasWords {
            said = loc("Type a word with letters or digits: the index keeps those. To find punctuation, use Find in an open document.")
        } else if rows.isEmpty {
            said = loc("No matches for “{0}”.", query)
        } else if rows.count >= Self.limit {
            said = outcome.candidates > Self.limit
                ? loc("The first {0} pages are listed, of up to {1} with these words.", CoreLanguage.number(Self.limit), CoreLanguage.number(outcome.candidates))
                : loc("The first {0} pages are listed.", CoreLanguage.number(Self.limit))
        } else {
            let files = Set(rows.map { $0.folder + "/" + $0.hit.relativePath }).count
            let pages = rows.count == 1 ? loc("{0} page", CoreLanguage.number(1)) : loc("{0} pages", CoreLanguage.number(rows.count))
            let inFiles = files == 1 ? loc("{0} file", CoreLanguage.number(1)) : loc("{0} files", CoreLanguage.number(files))
            said = loc("{0} in {1}.", pages, inFiles)
        }
        if outcome.notOpen { said += " " + loc("The index isn't open yet. Try again in a moment.") }
        if outcome.stillIndexing && outcome.hasWords { said += " " + loc("Still indexing: more may turn up.") }
        for p in outcome.problems { said += " " + p }
        status.stringValue = said
        onSearched?()
    }

    // MARK: Opening a result

    @objc func openSelected() {
        let row = results.clickedRow >= 0 ? results.clickedRow : results.selectedRow
        guard row >= 0, row < rows.count else { return }
        open(rows[row])
    }

    /// Opens the result's PDF (or brings it forward) at the hit, the Find bar showing the words. Calls `opened` with its window.
    func open(_ row: Row, opened: ((DocumentWindowController?) -> Void)? = nil) {
        let url = URL(fileURLWithPath: row.folder).appendingPathComponent(row.hit.relativePath)
        let query = lastQuery, options = lastOptions, page = row.hit.page
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { document, _, _ in
            MainActor.assumeIsolated {
                let controller = (document as? PdfDocument)?.windowControllers.first as? DocumentWindowController
                controller?.showFolderHit(page: page, query: query, options: options)
                opened?(controller)
            }
        }
    }

    // MARK: Folders

    func refreshFolders() {
        updateLocked()
        let selected = folders.selectedRow
        folders.reloadData()
        if selected >= 0 && selected < FolderSearches.shared.all.count { folders.selectRowIndexes([selected], byExtendingSelection: false) }
        updatePause()
    }

    private var selectedFolder: FolderSearches.Folder? {
        let all = FolderSearches.shared.all
        let row = folders.selectedRow >= 0 ? folders.selectedRow : (all.count == 1 ? 0 : -1)
        return row >= 0 && row < all.count ? all[row] : nil
    }

    private func updatePause() {
        pauseButton.title = selectedFolder?.paused == true ? loc("Resume") : loc("Pause")
    }

    @objc func addFolder() {
        guard Pro.allows(.folderSearch) else { return aboutPro() }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = loc("Index")
        panel.message = loc("Index this folder and its subfolders")
        guard let window else { return }
        panel.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .OK, let url = panel.url else { return }
                self.add(url.path)
            }
        }
    }

    /// Adds `path`, or says why it can't be.
    func add(_ path: String) {
        if let problem = FolderSearches.shared.problem(adding: path) {
            let alert = NSAlert()
            alert.messageText = loc("Can't index this folder")
            alert.informativeText = problem
            if let window { alert.beginSheetModal(for: window) } else { alert.runModal() }
            return
        }
        FolderSearches.shared.add(path)
        refreshFolders()
    }

    @objc func pauseClicked() {
        guard let f = selectedFolder else { return }
        FolderSearches.shared.setPaused(f, !f.paused)
        refreshFolders()
    }

    @objc func showSkipped() {
        guard let f = selectedFolder, let window else { return }
        let skipped = f.indexer?.skipped() ?? []
        let alert = NSAlert()
        alert.messageText = loc("Skipped Files")
        alert.informativeText = skipped.count == 1
            ? loc("{0} file in {1} the index has no text, or not all the text, of. It is read again when it changes, or with Rebuild.", CoreLanguage.number(1), f.path)
            : loc("{0} files in {1} the index has no text, or not all the text, of. They are read again when they change, or with Rebuild.",
                  CoreLanguage.number(skipped.count), f.path)
        if !skipped.isEmpty {
            let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
            text.isEditable = false
            text.string = skipped.prefix(2000).map { "\($0.relativePath) — \($0.reason)" }.joined(separator: "\n")
            text.setAccessibilityLabel(loc("Skipped files"))
            let s = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 200))
            s.documentView = text
            s.hasVerticalScroller = true
            s.borderType = .bezelBorder
            alert.accessoryView = s
        }
        alert.beginSheetModal(for: window)
    }

    @objc func rebuildClicked() {
        guard let f = selectedFolder, let window else { return }
        let alert = NSAlert()
        alert.messageText = loc("Build this index again?")
        alert.informativeText = loc("Every PDF in {0} is read again, and files skipped earlier get another chance. Searches find what has been read so far.", f.path)
        alert.addButton(withTitle: loc("Rebuild"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                if response == .alertFirstButtonReturn { f.indexer?.rebuild() }
            }
        }
    }

    @objc func removeClicked() {
        guard let f = selectedFolder, let window else { return }
        let alert = NSAlert()
        alert.messageText = loc("Stop indexing this folder?")
        alert.informativeText = loc("Its index file is deleted. The PDFs in {0} aren't touched.", f.path)
        alert.addButton(withTitle: loc("Remove"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                FolderSearches.shared.remove(f)
                self.refreshFolders()
            }
        }
    }

    // MARK: Tables

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === results ? rows.count : FolderSearches.shared.all.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = tableColumn?.identifier.rawValue ?? ""
        let cell = NSTextField(labelWithString: "")
        cell.lineBreakMode = .byTruncatingTail
        if tableView === results {
            let r = rows[row]
            switch id {
            case "file":
                cell.stringValue = r.hit.relativePath
                cell.lineBreakMode = .byTruncatingHead
                cell.toolTip = (r.folder as NSString).appendingPathComponent(r.hit.relativePath)
            case "where":
                let page = CoreLanguage.number(r.hit.page + 1)
                cell.stringValue = r.hit.hits > 1 ? loc("page {0}, {1} times", page, CoreLanguage.number(r.hit.hits)) : loc("page {0}", page)
            default:
                cell.attributedStringValue = Self.excerpt(r.hit)
            }
        } else {
            let all = FolderSearches.shared.all
            guard row < all.count else { return cell }
            switch id {
            case "folder":
                cell.stringValue = all[row].name
                cell.toolTip = all[row].path
            default:
                cell.stringValue = all[row].statusText
                cell.toolTip = all[row].statusText
            }
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if (notification.object as? NSTableView) === folders { updatePause() }
    }

    /// The excerpt with the hit in bold.
    static func excerpt(_ hit: FolderHit) -> NSAttributedString {
        let text = NSMutableAttributedString(string: hit.excerpt, attributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)])
        let range = NSRange(location: hit.matchStart, length: hit.matchLength)
        if range.location >= 0 && NSMaxRange(range) <= text.length {
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: NSFont.systemFontSize), range: range)
        }
        return text
    }
}

/// A table that opens its selected row on Return, as a double click does.
@MainActor
final class ReturnTableView: NSTableView {
    var onReturn: (() -> Void)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, let onReturn { onReturn() } else { super.keyDown(with: event) }
    }
}
