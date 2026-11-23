import AppKit
import PdfCore
import PrintCore

/// The answers' list, top down.
private final class FolderAskList: NSStackView {
    override var isFlipped: Bool { true }
}

/// Edit › Find › Ask Across Folders… (roadmap 4.11, Pro; the Windows `FolderAskWindow`): a question over the indexed
/// folders or a set of PDFs, answered by the user's own AI endpoint. PdfCore picks the pages and passages and reads the
/// answer's citations back (`FolderAsk`, `FolderIndex.rank`); this asks, shows the send window with every page and file,
/// streams the answer and opens a cited file at its page. A window of its own, as Search Folders. Logs nothing: never the
/// question, the text or the endpoint's messages.
@MainActor
final class FolderAskWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    static var shared: FolderAskWindowController?

    let inFolders = NSButton(radioButtonWithTitle: loc("In the indexed folders"), target: nil, action: nil)
    let inFiles = NSButton(radioButtonWithTitle: loc("In these PDFs:"), target: nil, action: nil)
    let chooseButton = NSButton(title: loc("Choose PDFs…"), target: nil, action: nil)
    /// Search by meaning (roadmap 4.21): pages close in meaning join those sharing the question's words.
    let alsoMeaning = NSButton(checkboxWithTitle: loc("Also find pages by meaning"), target: nil, action: nil)
    let filesText = NSTextField(wrappingLabelWithString: "")
    let whereText = NSTextField(wrappingLabelWithString: "")
    let question = NSTextField()
    let askButton = NSButton(title: loc("Ask"), target: nil, action: nil)
    let stopButton = NSButton(title: loc("Stop"), target: nil, action: nil)
    let status = NSTextField(wrappingLabelWithString: "")
    private let list = FolderAskList()
    private let scroll = NSScrollView()
    private(set) var files: [String] = []
    private var cancel: CancelToken?
    /// The question running (the self-test awaits it).
    private(set) var job: Task<Void, Never>?
    /// The last request sent (the self-test reads it).
    private(set) var lastRequest: FolderAskRequest?
    /// The last answer's card (the self-test reads it).
    private(set) var lastCard: AiAnswerCard?
    /// The self-test's PDFs for Choose PDFs…, in place of the open panel.
    var testFiles: [String]?

    static func show() {
        guard Pro.allows(.folderAsk) else { return ProWindowController.show(feature: .folderAsk) }
        let c = shared ?? FolderAskWindowController()
        shared = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
        c.window?.makeFirstResponder(c.question)
        c.showWhere()
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 680), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = loc("Ask Across Folders")
        window.isRestorable = false
        window.minSize = NSSize(width: 480, height: 420)
        super.init(window: window)
        window.delegate = self
        build()
        showWhere()
        showFiles()
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func build() {
        let intro = NSTextField(wrappingLabelWithString: loc("Ask a question about the PDFs in your indexed folders, or about PDFs you choose. The folder index picks the pages most related to it, and your own AI assistant answers from them, citing the file and page. Nothing is sent before you see exactly what goes."))
        intro.textColor = .secondaryLabelColor
        for b in [inFolders, inFiles] {
            b.target = self
            b.action = #selector(scopeChanged)
        }
        inFolders.state = .on
        chooseButton.target = self
        chooseButton.action = #selector(chooseClicked)
        let scope = NSStackView(views: [inFolders, inFiles, chooseButton])
        alsoMeaning.toolTip = loc("Pages close in meaning to the question join those that share its words (search by meaning, through your own AI assistant's embedding model).")
        alsoMeaning.state = FolderMeaning.model != nil ? .on : .off
        alsoMeaning.target = self
        alsoMeaning.action = #selector(alsoMeaningClicked)
        scope.spacing = 12
        scope.setAccessibilityLabel(loc("Ask in"))
        for t in [filesText, whereText, status] {
            t.textColor = .secondaryLabelColor
            t.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        }
        status.setAccessibilityLabel(loc("Status"))

        question.placeholderString = loc("Ask a question about these documents")
        question.setAccessibilityLabel(loc("Question"))
        question.delegate = self
        question.target = self
        question.action = #selector(askClicked)
        askButton.bezelStyle = .rounded
        askButton.keyEquivalent = "\r"
        askButton.target = self
        askButton.action = #selector(askClicked)
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.isHidden = true
        let row = NSStackView(views: [question, askButton, stopButton])
        row.spacing = 8
        question.setContentHuggingPriority(.init(1), for: .horizontal)

        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 10
        list.edgeInsets = NSEdgeInsets(top: 4, left: 0, bottom: 8, right: 0)
        list.translatesAutoresizingMaskIntoConstraints = false
        list.setAccessibilityLabel(loc("Questions and answers"))
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        list.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
        scroll.setContentHuggingPriority(.init(1), for: .vertical)

        let stack = NSStackView(views: [intro, scope, alsoMeaning, filesText, whereText, row, status, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 16, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        for v in [intro, filesText, whereText, row, status, scroll] as [NSView] {
            v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40).isActive = true
        }
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor), stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window?.contentView = content
    }

    func windowWillClose(_ notification: Notification) {
        cancel?.cancel()
        if Self.shared === self { Self.shared = nil }
    }

    // MARK: What it shows

    func showWhere() {
        let now = AiService.current(AppSettings.ai)
        if let config = now.config {
            whereText.stringValue = "\(config.model) · \(config.endpoint.reachText)" // only names and values
        } else {
            whereText.stringValue = now.problem ?? loc("Not set up")
        }
    }

    private func showFiles() {
        if files.isEmpty {
            filesText.stringValue = loc("No PDFs chosen yet.")
        } else {
            let names = files.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") + (files.count > 5 ? ", …" : "")
            filesText.stringValue = files.count == 1 ? loc("{0} PDF: {1}", CoreLanguage.number(1), names) : loc("{0} PDFs: {1}", CoreLanguage.number(files.count), names)
        }
        filesText.isHidden = inFiles.state != .on && files.isEmpty
    }

    private func say(_ text: String) {
        status.stringValue = text
        NSAccessibility.post(element: status, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    private func setBusy(_ busy: Bool) {
        stopButton.isHidden = !busy
        askButton.isEnabled = !busy
    }

    // MARK: Actions

    @objc func scopeChanged(_ sender: NSButton) {
        inFolders.state = sender === inFiles ? .off : .on
        inFiles.state = sender === inFiles ? .on : .off
        if sender === inFiles && files.isEmpty { chooseClicked() }
        showFiles()
    }

    @objc func alsoMeaningClicked() {
        guard alsoMeaning.state == .on, FolderMeaning.model == nil, let window else { return }
        Task { @MainActor in
            if !(await FolderMeaning.showSettings(on: window)) || FolderMeaning.model == nil { alsoMeaning.state = .off }
        }
    }

    @objc func chooseClicked() {
        if let testFiles {
            setFiles(testFiles)
            return
        }
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.title = loc("Choose PDFs…")
        panel.allowedContentTypes = [.pdf]
        panel.allowsMultipleSelection = true
        panel.beginSheetModal(for: window) { [weak self] response in
            MainActor.assumeIsolated {
                guard let self else { return }
                if response == .OK { self.setFiles(panel.urls.map(\.path)) } else if self.files.isEmpty { self.setFiles([]) }
            }
        }
    }

    func setFiles(_ paths: [String]) {
        files = paths
        inFiles.state = paths.isEmpty ? .off : .on
        inFolders.state = paths.isEmpty ? .on : .off
        showFiles()
    }

    /// In the indexed folders (true) or the chosen PDFs (false).
    func setScope(folders: Bool) {
        inFolders.state = folders ? .on : .off
        inFiles.state = folders ? .off : .on
        showFiles()
    }

    @objc func askClicked() {
        let q = AiText.trim(question.stringValue)
        guard !q.isEmpty, cancel == nil else { return }
        job = Task { @MainActor [weak self] in await self?.ask(q) }
    }

    @objc func stopClicked() { cancel?.cancel() }

    override func cancelOperation(_ sender: Any?) {
        if let cancel { cancel.cancel() } else { window?.performClose(nil) }
    }

    // MARK: Asking

    private func ask(_ typed: String) async {
        guard Pro.allows(.folderAsk) else { return ProWindowController.show(feature: .folderAsk) }
        guard let window else { return }
        var now = AiService.current(AppSettings.ai)
        if now.config == nil {
            guard await AiSettingsSheet.show(on: window, why: loc("{0} Set it up here, or Cancel.", now.problem ?? "")) else { return }
            DocumentWindowController.refreshAllAiPanes()
            now = AiService.current(AppSettings.ai)
            showWhere()
        }
        guard var config = now.config else { return }
        let asksFiles = inFiles.state == .on
        if asksFiles && files.isEmpty { return say(loc("Choose the PDFs to ask about first.")) }
        let folders = FolderSearches.shared.all.compactMap { f -> (path: String, indexer: FolderIndexer)? in
            guard let indexer = f.indexer, indexer.currentIndex != nil else { return nil }
            return (f.path, indexer)
        }
        if !asksFiles && folders.isEmpty {
            return say(FolderSearches.shared.all.isEmpty ? loc("No folder is indexed yet. Add Folder… chooses one.") : loc("The index isn't open yet. Try again in a moment."))
        }
        let token = CancelToken()
        cancel = token
        setBusy(true)
        defer {
            cancel = nil
            setBusy(false)
        }
        do {
            if config.isOllama {
                say(loc("Asking Ollama how much text the model reads at once…"))
                config = try await AiService.resolve(config, keys: AppSettings.aiKeys, cancel: token)
            }
            say(asksFiles ? loc("Reading the PDFs…") : loc("Finding the pages most related to the question…"))
            let chosen = files
            var found = try await Task.detached(priority: .userInitiated) {
                asksFiles ? try Self.fromFiles(chosen, token) : try Self.fromFolders(folders, typed, token)
            }.value
            if alsoMeaning.state == .on && asksFiles {
                found.notes.append(loc("Search by meaning works on indexed folders only."))
            } else if alsoMeaning.state == .on {
                // The pages closest in meaning join those sharing the question's words (their embeddings shown before they go).
                let open = FolderSearches.shared.all.filter { $0.indexer?.currentIndex != nil }
                guard await FolderMeaning.ready(on: window) != nil,
                      let hits = try await FolderMeaning.search(on: window, config, open, typed, count: Self.meaningPages, say: { [weak self] in self?.say($0) }, cancel: token) else {
                    return say(loc("Not sent."))
                }
                let byWords = found.pages
                found.pages = try await Task.detached(priority: .userInitiated) { try Self.withMeaning(byWords, hits, folders, token) }.value
            }
            let notes = found.notes
            guard let request = FolderAsk.build(typed, found.pages, inputTokens: config.inputTokens) else {
                // In the folders, no page ranked means none shares a word (Windows says "no text" there too).
                let why = found.pages.isEmpty && asksFiles ? loc("None of the pages has text to send. Scans need Recognize Text first.")
                    : loc("No page shares a word with the question. Try other words.")
                return say(([why] + notes).joined(separator: " "))
            }
            lastRequest = request
            say(loc("Checking the files' permissions…"))
            let sources = request.sources
            let restricted = await Task.detached(priority: .userInitiated) {
                sources.filter { Self.restricted($0.path) }.map(\.name)
            }.value
            try token.check()
            var listing = FolderAsk.sentList(request)
            if !restricted.isEmpty { listing.append(loc("These PDFs don't allow copying their text: {0}", restricted.joined(separator: ", "))) }
            let pageCount = request.pages.count, fileCount = request.sources.count
            let pagesText = pageCount == 1 ? loc("{0} page", CoreLanguage.number(1)) : loc("{0} pages", CoreLanguage.number(pageCount))
            let filesText = fileCount == 1 ? loc("{0} file", CoreLanguage.number(1)) : loc("{0} files", CoreLanguage.number(fileCount))
            let what = request.trimmed ? loc("Your question and the parts most related to it, from {0} of {1}", pagesText, filesText)
                : loc("Your question and the text of {0} from {1}", pagesText, filesText)
            let outgoing = AiOutgoing([request.messages], what: what, listing: listing, onlyNote: Self.onlyNote)
            let consent = AiConsent(AppSettings.ai, config.endpoint, copyRestricted: !restricted.isEmpty, force: false)
            if consent.asks {
                guard await AiConfirmSheet.ask(on: window, config, outgoing, consent: consent, title: nil) else { return say(loc("Not sent.")) }
            }
            try token.check()
            addQuestion(typed)
            let card = addAnswer(config.model, request)
            say(loc("Sending to {0}…", config.endpoint.host))
            do {
                let client = AiService.client(config, keys: AppSettings.aiKeys)
                let reply = try await client.chat(request.messages, onText: { piece in
                    DispatchQueue.main.async { MainActor.assumeIsolated { card.append(piece) } }
                }, cancel: token)
                let answer = AiText.trim(AiText.withoutThinking(reply.text).text)
                let note = ([AiJobs.finishNote(reply, answer: answer)].compactMap { $0 } + notes).joined(separator: " ")
                card.finish(answer, note: note.isEmpty ? nil : note)
                say(loc("Answer ready. AI-generated: check it against the pages."))
            } catch let e as AiError {
                card.finish(nil, note: e.message, error: true)
                say(e.message)
            } catch is CancellationError {
                card.finish(nil, note: loc("Stopped."))
                throw CancellationError()
            }
        } catch is CancellationError {
            say(loc("Stopped."))
        } catch let e as AiError {
            say(e.message)
        } catch {
            // A folder removed or its index rebuilt while this ran, or a file that can't be read: said, never a silent stop.
            say(loc("A folder's index or a file couldn't be read. Check that the folder is still there and the files aren't open in another app, then try again."))
        }
    }

    static var onlyNote: String {
        loc("Only this text, the instructions shown below and the model's name are sent, with each file's name within its folder as listed: not where the files are on this Mac, their properties or any other page.")
    }

    private func addQuestion(_ text: String) {
        let bubble = AiBubble(text)
        bubble.setWidth(max(scroll.contentView.bounds.width, 300))
        add(bubble)
    }

    private func addAnswer(_ model: String, _ sent: FolderAskRequest) -> AiAnswerCard {
        let card = AiAnswerCard(model: model, pageCount: 0, goTo: { _ in }, scrolled: { [weak self] in self?.scrollToEnd() }, links: { text in
            FolderAsk.citations(text, sent).map { c in
                AiAnswerCard.Link(start: c.start, length: c.length, tip: loc("Open {0} at page {1}", c.source.name, CoreLanguage.number(c.page + 1)),
                                  open: { Self.open(c.source.path, page: c.page) })
            }
        })
        card.noteLabel.preferredMaxLayoutWidth = max(scroll.contentView.bounds.width - 24, 280)
        add(card)
        lastCard = card
        return card
    }

    private func add(_ view: NSView) {
        list.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        scrollToEnd()
    }

    private func scrollToEnd() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.list.layoutSubtreeIfNeeded()
                let height = self.list.frame.height - self.scroll.contentView.bounds.height
                self.scroll.contentView.scroll(to: NSPoint(x: 0, y: max(height, 0)))
                self.scroll.reflectScrolledClipView(self.scroll.contentView)
            }
        }
    }

    /// Opens `path` at `page` (a cited page), in its window if it is open already.
    static func open(_ path: String, page: Int, opened: ((DocumentWindowController?) -> Void)? = nil) {
        NSDocumentController.shared.openDocument(withContentsOf: URL(fileURLWithPath: path), display: true) { document, _, _ in
            MainActor.assumeIsolated {
                let controller = (document as? PdfDocument)?.windowControllers.first as? DocumentWindowController
                Task { @MainActor in
                    if let controller {
                        for _ in 0..<250 where controller.pages.pageRects.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
                        controller.go(page)
                    }
                    opened?(controller)
                }
            }
        }
    }

    // MARK: Reading (off the main thread)

    struct Found: Sendable {
        var pages: [FolderAskPage] = []
        var notes: [String] = []
    }

    /// The pages the folders' indexes propose for the question, best first, with their text.
    nonisolated static func fromFolders(_ folders: [(path: String, indexer: FolderIndexer)], _ question: String, _ cancel: CancelToken) throws -> Found {
        var out = Found()
        let words = FolderAsk.words(question)
        var ranked: [(folder: Int, page: RankedPage)] = []
        for (i, f) in folders.enumerated() {
            guard let index = f.indexer.currentIndex else { continue }
            do {
                ranked += try index.rank(words, FolderAsk.maxCandidatePages, cancel: cancel).map { (i, $0) }
            } catch is FolderIndexDamaged {
                f.indexer.rebuild()
                out.notes.append(loc("The index of {0} was damaged and is being built again.", f.path))
            } catch is FolderIndexIOError {
                continue // closed meanwhile
            }
        }
        // The best of all folders (stable: a folder's own order kept among equals).
        let best = ranked.enumerated().sorted { a, b in
            a.element.page.words != b.element.page.words ? a.element.page.words > b.element.page.words : a.offset < b.offset
        }.prefix(FolderAsk.maxCandidatePages).map(\.element)
        var order: [Int] = []
        var byFolder: [Int: [RankedPage]] = [:]
        for r in best {
            if byFolder[r.folder] == nil { order.append(r.folder) }
            byFolder[r.folder, default: []].append(r.page)
        }
        for i in order {
            let f = folders[i]
            guard let index = f.indexer.currentIndex, let chosen = byFolder[i] else { continue }
            do {
                let texts = try index.pageTexts(chosen.map { ($0.relativePath, $0.page) }, cancel: cancel)
                for (c, text) in zip(chosen, texts) {
                    out.pages.append(FolderAskPage((f.path as NSString).appendingPathComponent(c.relativePath), c.relativePath, c.page, text))
                }
            } catch is FolderIndexDamaged {
                f.indexer.rebuild()
                out.notes.append(loc("The index of {0} was damaged and is being built again.", f.path))
            } catch is FolderIndexIOError {
                continue
            }
        }
        if folders.contains(where: { $0.indexer.status.phase != .upToDate }) { out.notes.append(loc("Still indexing: more may turn up.")) }
        return out
    }

    /// Pages closest in meaning brought to a question by search by meaning.
    static let meaningPages = 30

    /// The pages closest in meaning, read from their folders' indexes, joined to those sharing the question's words
    /// (`FolderAsk.withMeaning`).
    nonisolated static func withMeaning(_ pages: [FolderAskPage], _ hits: [(folder: String, hit: MeaningHit)],
                                        _ folders: [(path: String, indexer: FolderIndexer)], _ cancel: CancelToken) throws -> [FolderAskPage] {
        var close: [FolderAskPage] = []
        for f in folders {
            let mine = hits.filter { $0.folder == f.path }.map(\.hit)
            guard !mine.isEmpty, let index = f.indexer.currentIndex else { continue }
            let texts = try index.pageTexts(mine.map { ($0.relativePath, $0.page) }, cancel: cancel)
            for (h, text) in zip(mine, texts) {
                close.append(FolderAskPage((f.path as NSString).appendingPathComponent(h.relativePath), h.relativePath, h.page, text, meaning: h.score))
            }
        }
        return FolderAsk.withMeaning(pages, close)
    }

    nonisolated static func fromFiles(_ files: [String], _ cancel: CancelToken) throws -> Found {
        let read = try FolderAsk.readFiles(files, maxPages: FolderAsk.maxFilePages, cancel: cancel)
        func names(_ paths: [String]) -> String { paths.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ") }
        var out = Found(pages: read.pages)
        if !read.needPassword.isEmpty { out.notes.append(loc("Not read (they need a password): {0}.", names(read.needPassword))) }
        if !read.unreadable.isEmpty { out.notes.append(loc("Couldn't be read: {0}.", names(read.unreadable))) }
        if !read.notAllRead.isEmpty {
            out.notes.append(loc("Only the first {0} pages of the PDFs were read; not all of: {1}.", CoreLanguage.number(FolderAsk.maxFilePages), names(read.notAllRead)))
        }
        return out
    }

    /// The PDF forbids copying its text, or its permissions can't be read (then asked about as if it did).
    nonisolated static func restricted(_ path: String) -> Bool {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int, size <= 512 << 20,
              let data = FileManager.default.contents(atPath: path) else { return true }
        return FolderAsk.copyRestricted([UInt8](data))
    }

    // MARK: The self-test

    /// Asks `text` as typed, and waits for it to end.
    func testAsk(_ text: String) async {
        question.stringValue = text
        askClicked()
        await job?.value
    }

    /// What the window shows, for the self-test (the Windows `DevState`).
    func stateReport() -> String {
        let sent = lastRequest.map { FolderAsk.sentList($0).joined(separator: " | ") } ?? ""
        let answer = lastCard.map { "\($0.text.prefix(60)) links=\($0.links.count)" } ?? "none"
        return "folderask: status '\(status.stringValue)'; sent [\(sent)]; answer \(answer)"
    }
}
