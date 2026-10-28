import AppKit
import PdfCore
import UniformTypeIdentifiers

/// New PDFs made in the app, each opened as a new, unsaved document (Save asks where, as for a new tab on Windows):
/// File › New PDF from Images…, New PDF from Clipboard, Combine Files… (and Scan…, in `ScanWindowController`).
@MainActor
enum NewDocuments {
    /// Opens `bytes` as an unsaved document named `name`; nil (and the error shown) when they aren't a readable PDF.
    @discardableResult
    static func open(_ bytes: [UInt8], name: String) -> PdfDocument? {
        do {
            let session = try DocumentSession.recover(bytes, originalPath: nil, name)
            let document = PdfDocument(recovered: session, page: 0, fileDate: nil)
            NSDocumentController.shared.addDocument(document)
            document.makeWindowControllers()
            document.showWindows()
            return document
        } catch {
            present("The new PDF couldn't be opened.", error)
            return nil
        }
    }

    static func present(_ message: String, _ error: Error?) {
        Report.note("ERROR shown: \(message)")
        guard !Report.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = message
        if let error { alert.informativeText = (error as? PdfEditError)?.message ?? error.localizedDescription }
        alert.runModal()
    }

    /// A name for a new document: "Pictures 2026-10-28 14.30.pdf".
    static func name(_ stem: String) -> String {
        let format = DateFormatter()
        format.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(stem) \(format.string(from: Date())).pdf"
    }

    // MARK: From images

    /// Asks for pictures, then makes them a PDF (a page each, the size of the picture).
    static func chooseImages(then done: (@MainActor (PdfDocument?) -> Void)? = nil) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose pictures: each becomes a page of a new PDF, in the order shown here."
        panel.prompt = "Create PDF"
        guard let urls = StartWindowController.pick(panel) else { return }
        let document = fromImages(urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending })
        done?(document)
    }

    @discardableResult
    static func fromImages(_ urls: [URL]) -> PdfDocument? {
        guard !urls.isEmpty else { return nil }
        do {
            let images = try urls.map { url in (bytes: [UInt8](try Data(contentsOf: url)), name: url.lastPathComponent) }
            let bytes = try ImageImport.imagesToPdf(images)
            return open(bytes, name: urls.count == 1 ? (urls[0].deletingPathExtension().lastPathComponent + ".pdf") : name("Pictures"))
        } catch {
            present("Those pictures couldn't be made into a PDF.", error)
            return nil
        }
    }

    /// File › New PDF from Clipboard: the picture on the clipboard as a one-page PDF.
    @discardableResult
    static func fromClipboard(_ pasteboard: NSPasteboard = .general) -> PdfDocument? {
        guard let png = clipboardPng(pasteboard) else {
            present("There's no picture on the clipboard.", PdfEditError("Copy a picture (or take a screenshot to the clipboard with ⌃⇧⌘4), then try again."))
            return nil
        }
        do {
            return open(try ImageImport.imagesToPdf([(bytes: png, name: "Clipboard.png")]), name: name("Clipboard"))
        } catch {
            present("The picture on the clipboard couldn't be made into a PDF.", error)
            return nil
        }
    }

    static func clipboardPng(_ pasteboard: NSPasteboard) -> [UInt8]? {
        if let data = pasteboard.data(forType: .png) { return [UInt8](data) }
        guard let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return [UInt8](png)
    }

    // MARK: Combine

    /// The files of a combine read as sources (a PDF's password asked when it needs one; pictures made into pages); nil
    /// when cancelled or unreadable (the error shown).
    static func sources(_ urls: [URL], passwords: [URL: String] = [:]) -> [PdfSource]? {
        var list: [PdfSource] = []
        do {
            for url in urls {
                let data = [UInt8](try Data(contentsOf: url))
                if url.pathExtension.lowercased() != "pdf" {
                    list.append(PdfSource(try ImageImport.imagesToPdf([(bytes: data, name: url.lastPathComponent)]), nil, url.lastPathComponent))
                    continue
                }
                var password = passwords[url]
                var wrong = password != nil
                while PdfSecurity.needsOpenPassword(data) && !PdfSecurity.isOpenPassword(data, password) && (try? PdfEngine.open(data, password: password)) == nil {
                    if Report.isRunning && wrong { return nil }
                    guard !Report.isRunning, let given = PasswordPrompt.ask(file: url.lastPathComponent, wrong: wrong) else { return nil }
                    password = given
                    wrong = true
                }
                list.append(PdfSource(data, password, url.lastPathComponent))
            }
        } catch {
            present("Those files couldn't be read.", error)
            return nil
        }
        return list
    }

    /// The files in their order as one new PDF (a bookmark per file when asked).
    @discardableResult
    static func combine(_ urls: [URL], bookmarks: Bool, passwords: [URL: String] = [:]) -> PdfDocument? {
        guard urls.count >= 1, let sources = sources(urls, passwords: passwords) else { return nil }
        do {
            return open(try PageEditor.merge(sources, bookmarks), name: name("Combined"))
        } catch {
            present("Those files couldn't be combined.", error)
            return nil
        }
    }
}

/// File › Combine Files…: the files listed in the order they will follow each other (Add, Move Up, Move Down, Remove, or
/// drag them), a bookmark per file if wanted, then Combine opens the new PDF.
@MainActor
final class CombineWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static var shared: CombineWindowController?

    private(set) var files: [URL] = []
    let table = NSTableView()
    let bookmarks = NSButton(checkboxWithTitle: "Add a bookmark for each file", target: nil, action: nil)
    let combineButton = NSButton(title: "Combine", target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private static let rowType = NSPasteboard.PasteboardType("com.bermudezsystems.InkvoltPdf.combine-row")
    /// The last document Combine opened (the self-test reads it).
    private(set) var lastCombined: PdfDocument?

    static func show(with urls: [URL] = []) -> CombineWindowController {
        let controller = shared ?? CombineWindowController()
        shared = controller
        controller.add(urls)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 380), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Combine Files"
        window.isRestorable = false
        window.minSize = NSSize(width: 420, height: 300)
        super.init(window: window)
        window.delegate = self

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("file"))
        column.title = "Files, in the order they will follow each other"
        table.addTableColumn(column)
        table.dataSource = self
        table.delegate = self
        table.allowsMultipleSelection = true
        table.registerForDraggedTypes([Self.rowType, .fileURL])
        table.setAccessibilityLabel("Files to combine")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder

        let add = NSButton(title: "Add Files…", target: self, action: #selector(addClicked))
        let up = NSButton(title: "Move Up", target: self, action: #selector(moveUpClicked))
        let down = NSButton(title: "Move Down", target: self, action: #selector(moveDownClicked))
        let remove = NSButton(title: "Remove", target: self, action: #selector(removeClicked))
        let side = NSStackView(views: [add, up, down, remove])
        side.orientation = .vertical
        side.alignment = .leading
        let middle = NSStackView(views: [scroll, side])
        middle.alignment = .top
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true
        scroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 300).isActive = true

        bookmarks.state = .on
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancelClicked))
        cancel.keyEquivalent = "\u{1b}"
        combineButton.target = self
        combineButton.action = #selector(combineClicked)
        combineButton.keyEquivalent = "\r"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [countLabel, spacer, cancel, combineButton])
        let stack = NSStackView(views: [middle, bookmarks, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        middle.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        window.contentView = stack
        window.center()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func add(_ urls: [URL]) {
        files += urls.filter { url in !files.contains(url) && (url.pathExtension.lowercased() == "pdf" || UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true) }
        refresh()
    }

    private func refresh() {
        table.reloadData()
        countLabel.stringValue = files.isEmpty ? "Add two or more files." : "\(files.count) file\(files.count == 1 ? "" : "s")"
        combineButton.isEnabled = files.count >= 2
    }

    func numberOfRows(in tableView: NSTableView) -> Int { files.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let url = files[row]
        let label = NSTextField(labelWithString: "\(row + 1). \(url.lastPathComponent)")
        label.lineBreakMode = .byTruncatingMiddle
        label.toolTip = url.path
        return label
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int,
                   proposedDropOperation dropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingSource as? NSTableView === tableView ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        let items = info.draggingPasteboard.pasteboardItems ?? []
        let rows = items.compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) }
        if !rows.isEmpty {
            move(IndexSet(rows), to: row)
            return true
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        add(urls)
        return !urls.isEmpty
    }

    /// Moves the rows `rows` to before row `to` (as a drop does).
    func move(_ rows: IndexSet, to: Int) {
        let moving = rows.map { files[$0] }
        let before = rows.filter { $0 < to }.count
        files = files.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        let at = min(max(to - before, 0), files.count)
        files.insert(contentsOf: moving, at: at)
        refresh()
        table.selectRowIndexes(IndexSet(at..<(at + moving.count)), byExtendingSelection: false)
    }

    @objc func addClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = "Choose PDFs or pictures to combine."
        guard let urls = StartWindowController.pick(panel) else { return }
        add(urls)
    }

    @objc func moveUpClicked() {
        let rows = table.selectedRowIndexes
        guard let first = rows.first, first > 0 else { return NSSound.beep() }
        move(rows, to: first - 1)
    }

    @objc func moveDownClicked() {
        let rows = table.selectedRowIndexes
        guard let last = rows.last, last < files.count - 1 else { return NSSound.beep() }
        move(rows, to: last + 2)
    }

    @objc func removeClicked() {
        let rows = table.selectedRowIndexes
        guard !rows.isEmpty else { return NSSound.beep() }
        files = files.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        refresh()
    }

    @objc func combineClicked() {
        guard files.count >= 2 else { return NSSound.beep() }
        guard let document = NewDocuments.combine(files, bookmarks: bookmarks.state == .on) else { return }
        lastCombined = document
        files = []
        refresh()
        window?.orderOut(nil)
    }

    @objc func cancelClicked() {
        files = []
        refresh()
        window?.orderOut(nil)
    }
}
