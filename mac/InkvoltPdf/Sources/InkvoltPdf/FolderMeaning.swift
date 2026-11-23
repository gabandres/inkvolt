import AppKit
import PdfCore
import PrintCore

/// Search by Meaning's settings (Search Folders' Meaning…, the Windows `FolderMeaning.ShowSettings`): on or off, and the
/// embedding model. Nothing is sent from here.
@MainActor
final class MeaningSettingsSheet: AiSheet {
    /// The sheet while it is open (the self-test fills it and presses its buttons).
    private(set) static var current: MeaningSettingsSheet?

    let turnOn = NSButton(checkboxWithTitle: loc("Turn on search by meaning"), target: nil, action: nil)
    let model = NSTextField()
    let problem = NSTextField(wrappingLabelWithString: "")
    let saveButton = NSButton(title: loc("Save"), target: nil, action: nil)

    init() {
        super.init(width: 520)
        window?.title = loc("Search by Meaning")
        let head = NSTextField(labelWithString: loc("Search by Meaning"))
        head.font = .boldSystemFont(ofSize: NSFont.systemFontSize + 1)
        stack.addArrangedSubview(head)
        addWide(Self.note(loc("Search by meaning finds pages by what they mean, not only the words they use. Your AI assistant's server turns each page's text into embeddings (lists of numbers) with an embedding model, and they're kept on this Mac beside each folder's index. Before any page goes, the send window shows every one. It stays off until you turn it on.")))
        turnOn.state = AppSettings.meaningEnabled ? .on : .off
        addWide(turnOn)
        let label = NSTextField(labelWithString: loc("Embedding model"))
        model.stringValue = AppSettings.meaningModel.isEmpty ? "nomic-embed-text" : AppSettings.meaningModel
        model.setAccessibilityLabel(loc("Embedding model"))
        model.toolTip = loc("A model that makes embeddings, not a chat model: nomic-embed-text, mxbai-embed-large or bge-m3 in Ollama (ollama pull nomic-embed-text), or text-embedding-3-small with OpenAI.")
        let row = NSStackView(views: [label, model])
        model.setContentHuggingPriority(.init(1), for: .horizontal)
        addWide(row)
        let now = AiService.current(AppSettings.ai)
        addWide(Self.note(now.config.map { loc("Embeddings come from the AI assistant's server. {0}", $0.endpoint.reachText) }
            ?? loc("Set up the AI assistant first (Tools › AI Assistant › AI Assistant Settings…): search by meaning uses its server.")))
        problem.textColor = .systemRed
        problem.isHidden = true
        addWide(problem)
        let cancel = NSButton(title: loc("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        addWide(NSStackView(views: [spacer, cancel, saveButton]))
    }

    private static func note(_ text: String) -> NSTextField {
        let f = NSTextField(wrappingLabelWithString: text)
        f.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        f.textColor = .secondaryLabelColor
        return f
    }

    @objc func cancelClicked() { finish(false) }

    @objc func saveClicked() {
        let name = AiText.trim(model.stringValue)
        if turnOn.state == .on && name.isEmpty {
            problem.stringValue = loc("Type the embedding model's name.")
            problem.isHidden = false
            fitWindow()
            return
        }
        AppSettings.meaningEnabled = turnOn.state == .on
        AppSettings.meaningModel = name
        finish(true)
    }

    /// Shows the settings on `window`; true when saved.
    static func show(on window: NSWindow) async -> Bool {
        let sheet = MeaningSettingsSheet()
        current = sheet
        defer { current = nil }
        return await sheet.run(on: window)
    }
}

/// Search by meaning (roadmap 4.21, Pro; the Windows `FolderMeaning`): off until the user turns it on and names an
/// embedding model. Before the pages of a folder are embedded the send window shows every one of them (always, whatever
/// was chosen for the endpoint: a folder's text is a lot to send), and a query's own words are shown before they go
/// unless the user chose not to be asked. PdfCore keeps the vectors (`MeaningIndex`, beside each folder index) and finds
/// the nearest pages; this asks, sends and reports. Logs nothing.
@MainActor
enum FolderMeaning {
    /// The model the embeddings come from while search by meaning is on; nil while it is off.
    static var model: String? {
        let m = AiText.trim(AppSettings.meaningModel)
        return AppSettings.meaningEnabled && !m.isEmpty ? m : nil
    }

    /// Ollama's own API for the Ollama preset, the OpenAI-compatible one otherwise.
    static func apiFor(_ config: AiConfig) -> EmbedApi { config.isOllama ? .ollama : .openAi }

    /// The settings, after the Pro check. True when saved.
    static func showSettings(on window: NSWindow) async -> Bool {
        guard Pro.allows(.meaningSearch) else {
            ProWindowController.show(feature: .meaningSearch)
            return false
        }
        return await MeaningSettingsSheet.show(on: window)
    }

    /// The assistant's configuration with the embedding model ready, asking for whatever is missing; nil when it stays off.
    static func ready(on window: NSWindow) async -> AiConfig? {
        guard Pro.allows(.meaningSearch) else {
            ProWindowController.show(feature: .meaningSearch)
            return nil
        }
        var now = AiService.current(AppSettings.ai)
        if now.config == nil {
            guard await AiSettingsSheet.show(on: window, why: loc("{0} Set it up here, or Cancel.", now.problem ?? "")) else { return nil }
            DocumentWindowController.refreshAllAiPanes()
            now = AiService.current(AppSettings.ai)
        }
        guard let config = now.config else { return nil }
        if model == nil {
            guard await MeaningSettingsSheet.show(on: window), model != nil else { return nil }
        }
        return config
    }

    /// One search by meaning at a time: the folders' meaning indexes are read and written by one.
    private static var busy = false

    struct Plan: @unchecked Sendable {
        let folder: String
        let index: MeaningIndex
        let pending: MeaningPending
    }

    /// Brings the folders' meaning indexes up to date (the send window first, listing every page), embeds `query` and
    /// returns the pages closest to it, best first (at most `count` in all); nil when not sent (said through `say`).
    /// - Throws: `CancellationError` (what was embedded so far is kept); `AiError`; `FolderIndexDamaged`; an I/O error.
    static func search(on window: NSWindow, _ config: AiConfig, _ folders: [FolderSearches.Folder], _ query: String, count: Int,
                       say: @escaping @MainActor @Sendable (String) -> Void, cancel: CancelToken) async throws -> [(folder: String, hit: MeaningHit)]? {
        guard !busy else {
            say(loc("Wait for the current answer, or Stop it first."))
            return nil
        }
        busy = true
        defer { busy = false }
        guard let model else { return nil }
        let api = apiFor(config)
        say(loc("Checking which pages are new…"))
        let key = config.endpoint.key
        var targets: [UncheckedBox<(folder: String, path: String, cached: MeaningIndex?, index: FolderIndex)>] = []
        for f in folders {
            guard let index = f.indexer?.currentIndex else { continue }
            let cached = f.meaning.flatMap { $0.model == model && $0.endpoint == key ? $0 : nil }
            targets.append(UncheckedBox((f.path, f.meaningPath, cached, index)))
        }
        // Each folder's meaning index read once (one made by another model or endpoint, of another version or damaged is
        // deleted and built again; one that can't be read just now is neither used nor deleted), then what it lacks.
        let plans: [Plan] = try await Task.detached(priority: .userInitiated) { () throws -> [Plan] in
            try targets.map { box -> Plan in
                let t = box.value
                var meaning = t.cached
                if meaning == nil {
                    let loaded = MeaningIndex.load(t.path, model, key)
                    if loaded.unreadable { throw MeaningUnreadable() }
                    if loaded.discarded != nil { unlink(t.path) }
                    meaning = loaded
                }
                let m = meaning ?? MeaningIndex.empty(model, key)
                return Plan(folder: t.folder, index: m, pending: try m.pending(t.index, cancel: cancel))
            }
        }.value
        for p in plans { folders.first { $0.path == p.folder }?.meaning = p.index }
        try cancel.check()
        let pieces = plans.reduce(0) { $0 + $1.pending.pieces.count }
        let leftOut = plans.reduce(0) { $0 + $1.pending.leftOut }
        let allPieces: [MeaningPiece] = plans.flatMap { $0.pending.pieces }
        var requests = stride(from: 0, to: pieces, by: AiEmbeddings.batchSize).map { start -> [AiMessage] in
            allPieces[start..<min(start + AiEmbeddings.batchSize, pieces)].map { AiMessage(role: "input", content: $0.text) }
        }
        requests.append([AiMessage(role: "input", content: query)])
        let what: String
        if pieces == 0 {
            what = loc("Your search words, to be turned into an embedding by {0}", model)
        } else {
            let pageCount = plans.reduce(0) { n, p in n + Set(p.pending.pieces.map { "\($0.page)\u{0}\($0.relativePath)" }).count }
            let fileCount = plans.reduce(0) { n, p in n + Set(p.pending.pieces.map { $0.relativePath }).count }
            let pagesText = pageCount == 1 ? loc("{0} page", CoreLanguage.number(1)) : loc("{0} pages", CoreLanguage.number(pageCount))
            let filesText = fileCount == 1 ? loc("{0} file", CoreLanguage.number(1)) : loc("{0} files", CoreLanguage.number(fileCount))
            what = loc("The text of {0} from {1}, to be turned into embeddings by {2}, then your search words", pagesText, filesText, model)
        }
        var listing = plans.flatMap { p in p.pending.listing.map { folders.count > 1 ? "\(p.folder): \($0)" : $0 } }
        if leftOut > 0 { listing.append(loc("Past the limit of {0} pieces, the rest isn't searched by meaning.", CoreLanguage.number(MeaningIndex.maxEntries))) }
        let outgoing = AiOutgoing(requests, what: what, listing: listing, onlyNote: pieces > 0 ? onlyNote : nil)
        let sendConfig = AiConfig(endpoint: config.endpoint, preset: config.preset, model: model, contextTokens: config.contextTokens, contextSource: config.contextSource)
        let consent = AiConsent(AppSettings.ai, config.endpoint, copyRestricted: false, force: pieces > 0)
        if consent.asks {
            guard await AiConfirmSheet.ask(on: window, sendConfig, outgoing, consent: consent, title: loc("Send for search by meaning?")) else {
                say(loc("Not sent."))
                return nil
            }
        }
        try cancel.check()
        let client = AiService.client(sendConfig, keys: AppSettings.aiKeys)
        var done = 0
        for p in plans where !p.pending.isEmpty {
            let path = MeaningIndex.pathFor(FolderIndex.basePathFor(FolderSearches.indexDirectory, p.folder))
            let before = done
            let plan = UncheckedBox(p)
            do {
                _ = try await Task.detached(priority: .userInitiated) {
                    try await plan.value.index.update(plan.value.pending, embed: { texts, c in try await client.embed(texts, api, cancel: c) }, path: path,
                                                      progress: { n in
                        DispatchQueue.main.async {
                            MainActor.assumeIsolated {
                                say(loc("Turning pages into embeddings: {0} of {1} pieces…", CoreLanguage.number(before + n), CoreLanguage.number(pieces)))
                            }
                        }
                    }, cancel: cancel)
                }.value
            } catch let e as AiError where e.message == MeaningIndex.lengthChangedMessage {
                // The model's vectors changed length: the index is made again next time.
                folders.first { $0.path == p.folder }?.forgetMeaning()
                throw e
            }
            done += p.pending.pieces.count
        }
        let vector = try await client.embed([query], api, cancel: cancel)[0]
        let boxes = plans.map { UncheckedBox($0) }
        return await Task.detached(priority: .userInitiated) {
            let all = boxes.flatMap { b in b.value.index.nearest(vector, count).filter { $0.score > 0 }.map { (folder: b.value.folder, hit: $0) } }
            return Array(all.sorted { $0.hit.score > $1.hit.score }.prefix(count))
        }.value
    }

    static var onlyNote: String {
        loc("Only this text and the model's name are sent: no file name, folder or other document. The embeddings stay on this Mac beside the folder's index, and next time only new or changed pages are sent.")
    }
}

/// A folder's meaning index couldn't be read just now (busy, locked): not wrong, so neither used nor deleted; said as a
/// file that couldn't be read.
struct MeaningUnreadable: Error {}

/// Hands a value that isn't Sendable to one task at a time (the meaning indexes, used by one search at a time).
struct UncheckedBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
