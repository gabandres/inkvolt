import AppKit
import PdfCore
import PrintCore
import UniformTypeIdentifiers

/// File › Batch… (the Windows app's `BatchWindow`): one list of actions run on many files (PDFs, and images made into
/// PDFs), the results saved in a folder with names from a template. Files come from Add Files, Add Folder (with or
/// without subfolders) or a drop; each action has a sheet with the same settings as its own command; a row shows its
/// progress and result as the batch runs (`BatchRunner`), a file that fails or is skipped says why, Stop ends it. A file
/// with a password asks for it when its turn comes. Presets (the Pro seam) keep the actions and choices under a name in
/// Application Support, or anywhere as a JSON file (Export, Import, also for the command line).
@MainActor
final class BatchWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static var shared: BatchWindowController?

    private(set) var files: [BatchFile] = []
    private var status: [String] = []
    private(set) var steps: [BatchStep] = []
    let fileTable = NSTableView()
    let actionTable = NSTableView()
    let folderField = NSTextField(string: "")
    let namesField = NSTextField(string: BatchNames.defaultTemplate)
    let neverOverwrite = NSButton(checkboxWithTitle: loc("Never replace a file (a taken name gets a number)"), target: nil, action: nil)
    let keepSubfolders = NSButton(checkboxWithTitle: loc("Keep subfolders below the results folder"), target: nil, action: nil)
    let signedFiles = NSPopUpButton(frame: .zero, pullsDown: false)
    let passwords = NSPopUpButton(frame: .zero, pullsDown: false)
    let imagePages = NSPopUpButton(frame: .zero, pullsDown: false)
    let presetPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let runButton = NSButton(title: loc("Run"), target: nil, action: nil)
    let stopButton = NSButton(title: loc("Stop"), target: nil, action: nil)
    /// The last run's removal report, when the plan had Redact Patterns.
    let reportButton = NSButton(title: loc("Redaction Report…"), target: nil, action: nil)
    private var reportSheet: RemovalReportSheet?
    let summary = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    /// What an empty list says to do (UX review, round 2: two blank tables and a disabled Run, nothing said why).
    private let noFiles = BatchWindowController.emptyNote(loc("No files yet. Drop PDFs or folders here, or choose Add Files…"))
    private let noActions = BatchWindowController.emptyNote(loc("No actions yet. Choose Add Action to pick what happens to each file."))
    private let more = NSButton()
    private var advancedRows: [NSGridRow] = []
    private var task: Task<Void, Never>?
    private var cancel: CancelToken?
    /// The last run's summary (the self-test reads it).
    private(set) var lastSummary: BatchSummary?
    private static let rowType = NSPasteboard.PasteboardType("com.bermudezsystems.InkvoltPdf.batch-row")

    static func show(with paths: [String] = []) {
        let controller = shared ?? BatchWindowController()
        shared = controller
        controller.add(paths)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// Where saved presets live.
    static var presetsFolder: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("Inkvolt PDF/presets").path
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 860, height: 700), styleMask: [.titled, .closable, .resizable, .miniaturizable],
                              backing: .buffered, defer: false)
        window.title = loc("Batch")
        window.isRestorable = false
        window.minSize = NSSize(width: 720, height: 600)
        super.init(window: window)
        window.delegate = self

        for (id, title, width) in [("file", loc("File", context: "column"), 240.0), ("result", loc("Result"), 300.0), ("folder", loc("Folder"), 220.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            fileTable.addTableColumn(column)
        }
        fileTable.dataSource = self
        fileTable.delegate = self
        fileTable.allowsMultipleSelection = true
        fileTable.registerForDraggedTypes([.fileURL])
        fileTable.setAccessibilityLabel(loc("Files"))
        fileTable.doubleAction = #selector(openResult)
        fileTable.target = self
        let fileScroll = NSScrollView()
        fileScroll.documentView = fileTable
        fileScroll.hasVerticalScroller = true
        fileScroll.borderType = .bezelBorder
        fileScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        let addFiles = NSButton(title: loc("Add Files…"), target: self, action: #selector(addFilesClicked))
        let addFolder = NSButton(title: loc("Add Folder…"), target: self, action: #selector(addFolderClicked))
        let removeFiles = NSButton(title: loc("Remove"), target: self, action: #selector(removeFilesClicked))
        let clearFiles = NSButton(title: loc("Clear"), target: self, action: #selector(clearFilesClicked))
        let fileButtons = NSStackView(views: [addFiles, addFolder, removeFiles, clearFiles])
        fileButtons.orientation = .vertical
        fileButtons.alignment = .leading
        let filesRow = NSStackView(views: [Self.overlay(fileScroll, noFiles), fileButtons])
        filesRow.alignment = .top

        let actionColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionColumn.title = loc("Actions, in order")
        actionTable.addTableColumn(actionColumn)
        actionTable.dataSource = self
        actionTable.delegate = self
        actionTable.registerForDraggedTypes([Self.rowType])
        actionTable.setAccessibilityLabel(loc("Actions"))
        actionTable.doubleAction = #selector(editActionClicked)
        actionTable.target = self
        let actionScroll = NSScrollView()
        actionScroll.documentView = actionTable
        actionScroll.hasVerticalScroller = true
        actionScroll.borderType = .bezelBorder
        actionScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
        let addAction = NSPopUpButton(frame: .zero, pullsDown: true)
        addAction.addItem(withTitle: loc("Add Action"))
        let offered = Self.offered
        for (i, step) in offered.enumerated() {
            // Groups: the actions on the PDF, the exports of its pages, the comments and form data.
            if i > 0, (offered[i - 1].exportFormat == nil) != (step.exportFormat == nil) || offered[i - 1].isReviewExport != step.isReviewExport {
                addAction.menu?.addItem(.separator())
            }
            let item = NSMenuItem(title: step.title, action: #selector(addActionPicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            addAction.menu?.addItem(item)
        }
        let editAction = NSButton(title: loc("Edit…"), target: self, action: #selector(editActionClicked))
        let upAction = NSButton(title: loc("Move Up"), target: self, action: #selector(moveActionUp))
        let downAction = NSButton(title: loc("Move Down"), target: self, action: #selector(moveActionDown))
        let removeAction = NSButton(title: loc("Remove"), target: self, action: #selector(removeActionClicked))
        let actionButtons = NSStackView(views: [addAction, editAction, upAction, downAction, removeAction])
        actionButtons.orientation = .vertical
        actionButtons.alignment = .leading
        let actionsRow = NSStackView(views: [Self.overlay(actionScroll, noActions), actionButtons])
        actionsRow.alignment = .top

        folderField.placeholderString = loc("Where the results go")
        folderField.setAccessibilityLabel(loc("Results folder"))
        let chooseFolder = NSButton(title: loc("Choose…"), target: self, action: #selector(chooseFolderClicked))
        namesField.setAccessibilityLabel(loc("Result names"))
        namesField.toolTip = loc("<<name>> the file's name, <<n>> or <<n:3>> its number, <<date>>, <<folder>>")
        neverOverwrite.state = .on
        keepSubfolders.state = .on
        signedFiles.addItems(withTitles: [loc("Leave signed files as they are (exports still read them)"),
                                          loc("Change signed files too (their signatures may stop verifying)")])
        passwords.addItems(withTitles: [loc("Ask for passwords as files need them"), loc("Skip files that need a password")])
        imagePages.addItems(withTitles: [loc("Images on pages their own size"), loc("Images on Letter pages"), loc("Images on A4 pages")])
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: loc("Results folder:")), stackOf(folderField, chooseFolder)],
            [NSTextField(labelWithString: loc("Names:")), namesField],
            [NSTextField(labelWithString: ""), neverOverwrite],
            [NSTextField(labelWithString: ""), keepSubfolders],
            [NSTextField(labelWithString: loc("Signed files:")), signedFiles],
            [NSTextField(labelWithString: loc("Passwords:")), passwords],
            [NSTextField(labelWithString: loc("Images:")), imagePages],
        ])
        grid.rowSpacing = 4
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        // The folder and names in sight; replacing, subfolders, signed files, passwords and images behind More Options.
        more.bezelStyle = .disclosure
        more.setButtonType(.pushOnPushOff)
        more.title = ""
        more.setAccessibilityLabel(loc("More Options"))
        more.target = self
        more.action = #selector(moreToggled)
        more.state = AppSettings.defaults.bool(forKey: "MoreOptions.Batch") ? .on : .off
        let moreLabel = NSTextField(labelWithString: loc("More Options"))
        moreLabel.textColor = .secondaryLabelColor
        grid.insertRow(at: 2, with: [NSGridCell.emptyContentView, stackOf(more, moreLabel)])
        advancedRows = (3..<grid.numberOfRows).map { grid.row(at: $0) }
        for row in advancedRows { row.isHidden = more.state != .on }
        folderField.widthAnchor.constraint(greaterThanOrEqualToConstant: 360).isActive = true
        namesField.widthAnchor.constraint(equalToConstant: 300).isActive = true

        presetPopup.setAccessibilityLabel(loc("Preset"))
        presetPopup.target = self
        presetPopup.action = #selector(presetPicked)
        let savePreset = NSButton(title: loc("Save Preset…"), target: self, action: #selector(savePresetClicked))
        let exportPreset = NSButton(title: loc("Export…"), target: self, action: #selector(exportPresetClicked))
        let importPreset = NSButton(title: loc("Import…"), target: self, action: #selector(importPresetClicked))
        let watched = NSButton(title: loc("Watched Folders…"), target: self, action: #selector(watchedFoldersClicked))
        let presetsRow = NSStackView(views: [NSTextField(labelWithString: loc("Preset:")), presetPopup, savePreset, exportPreset, importPreset, NSView(), watched])
        presetPopup.widthAnchor.constraint(greaterThanOrEqualToConstant: 200).isActive = true

        runButton.target = self
        runButton.action = #selector(runClicked)
        runButton.keyEquivalent = "\r"
        stopButton.target = self
        stopButton.action = #selector(stopClicked)
        stopButton.isEnabled = false
        reportButton.target = self
        reportButton.action = #selector(reportClicked)
        reportButton.isHidden = true
        progress.style = .bar
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false
        progress.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let bottom = NSStackView(views: [summary, spacer, reportButton, progress, stopButton, runButton])

        // Spare height goes below the options, not between their rows.
        let filler = NSView()
        filler.setContentHuggingPriority(.init(1), for: .vertical)
        grid.setContentHuggingPriority(.required, for: .vertical)
        let stack = NSStackView(views: [filesRow, actionsRow, grid, filler, presetsRow, bottom])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for v in [filesRow, actionsRow, presetsRow, bottom] { v.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true }
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        window.contentView = stack
        window.center()
        folderField.stringValue = AppSettings.defaults.string(forKey: "BatchFolder") ?? ""
        reloadPresets()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The actions as the Add Action menu offers them, with their default settings (the watermark's and the footer's
    /// default text in the interface's language: words the person edits first, as Windows'), built at first use, after
    /// `AppLanguage.apply`.
    static let offered: [BatchStep] = {
        var steps: [BatchStep] = [.optimize(OptimizeOptions()), .protect(ProtectStep("", nil, .all)), .unprotect]
        steps += [.sanitize(Set(SanitizeItem.allCases.filter { $0 != .signatures })), .redactPatterns(RedactionPatternOptions())]
        steps += [.checkRedaction, .checkAccessibility, .reportContents, .watermark(WatermarkOptions(text: loc("DRAFT")))]
        steps += [.headerFooter(BatchWindowController.defaultHeaderFooter, continueBates: false), .rotate(90), .flatten(FlattenOptions())]
        steps += [.ocr, .makeAccessible(language: nil), .saveAsPdfA, .saveAsPdfA2a]
        steps += [.export(.word, dpi: 150), .export(.excel, dpi: 150), .export(.powerPoint, dpi: 150), .export(.html, dpi: 150), .export(.text, dpi: 150)]
        steps += [.export(.png, dpi: 150), .export(.jpeg, dpi: 150)]
        steps += [.export(.commentsXfdf, dpi: 150), .export(.commentsFdf, dpi: 150), .export(.commentsCsv, dpi: 150), .export(.commentSummary, dpi: 150)]
        steps += [.export(.formDataXfdf, dpi: 150), .export(.formDataFdf, dpi: 150), .export(.formDataCsv, dpi: 150), .export(.formDataJson, dpi: 150)]
        return steps
    }()

    private static var defaultHeaderFooter: HeaderFooterOptions {
        var o = HeaderFooterOptions()
        o.footerCenter = loc("Page <<page>> of <<pages>>")
        return o
    }

    private func stackOf(_ views: NSView...) -> NSStackView {
        let s = NSStackView(views: views)
        s.spacing = 6
        return s
    }

    // MARK: Files

    func add(_ paths: [String]) {
        guard !paths.isEmpty else { return }
        let found = BatchFiles.expand(paths, recursive: false, excludeFolder: folderField.stringValue)
        let known = Set(files.map { $0.path.lowercased() })
        for f in found where !known.contains(f.path.lowercased()) {
            files.append(f)
            status.append("")
        }
        if folderField.stringValue.isEmpty, let first = found.first {
            folderField.stringValue = ((first.path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(loc("Inkvolt PDF results"))
        }
        refresh()
    }

    func addFolder(_ path: String, recursive: Bool) {
        let found = BatchFiles.expand([path], recursive: recursive, excludeFolder: folderField.stringValue)
        let known = Set(files.map { $0.path.lowercased() })
        for f in found where !known.contains(f.path.lowercased()) {
            files.append(f)
            status.append("")
        }
        if folderField.stringValue.isEmpty { folderField.stringValue = (path as NSString).appendingPathComponent(loc("Inkvolt PDF results")) }
        refresh()
    }

    private func refresh() {
        fileTable.reloadData()
        actionTable.reloadData()
        let running = task != nil
        runButton.isEnabled = !running && !files.isEmpty && !steps.isEmpty
        stopButton.isEnabled = running
        noFiles.isHidden = !files.isEmpty
        noActions.isHidden = !steps.isEmpty
        progress.isHidden = !running && lastSummary == nil
        reportButton.isHidden = running || lastSummary?.redactionReport == nil
        if !running {
            summary.stringValue = lastSummary?.text ?? (files.isEmpty ? loc("Add files and actions.") : Self.counts(files.count, steps.count))
        }
    }

    /// "3 files, 2 actions": each count's own word, whole for Spanish (archivo/archivos, acción/acciones).
    private static func counts(_ files: Int, _ actions: Int) -> String {
        let f = files == 1 ? loc("1 file") : loc("{0} files", CoreLanguage.number(files))
        let a = actions == 1 ? loc("1 action") : loc("{0} actions", CoreLanguage.number(actions))
        return "\(f), \(a)"
    }

    func numberOfRows(in tableView: NSTableView) -> Int { tableView === fileTable ? files.count : steps.count }

    static func emptyNote(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.textColor = .secondaryLabelColor
        label.alignment = .center
        label.preferredMaxLayoutWidth = 320
        return label
    }

    /// The list with its empty-state note centred over it.
    static func overlay(_ scroll: NSScrollView, _ label: NSView) -> NSView {
        let box = NSView()
        for v in [scroll, label] {
            v.translatesAutoresizingMaskIntoConstraints = false
            box.addSubview(v)
        }
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: box.leadingAnchor), scroll.trailingAnchor.constraint(equalTo: box.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: box.topAnchor), scroll.bottomAnchor.constraint(equalTo: box.bottomAnchor),
            label.centerXAnchor.constraint(equalTo: box.centerXAnchor), label.centerYAnchor.constraint(equalTo: box.centerYAnchor, constant: 12),
        ])
        return box
    }

    @objc private func moreToggled() {
        AppSettings.defaults.set(more.state == .on, forKey: "MoreOptions.Batch")
        for row in advancedRows { row.isHidden = more.state != .on }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let text: String
        if tableView === fileTable {
            let f = files[row]
            switch tableColumn?.identifier.rawValue {
            case "file": text = (f.path as NSString).lastPathComponent
            case "result": text = status[row]
            default: text = (f.path as NSString).deletingLastPathComponent
            }
        } else {
            text = "\(row + 1). \(Self.describe(steps[row]))"
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    /// An action with its main setting, for the list.
    static func describe(_ step: BatchStep) -> String {
        switch step {
        case .watermark(let o): "\(step.title): \(o.text ?? loc("a picture"))"
        case .headerFooter(let o, let c): "\(step.title): \(headerFooterTexts(o, continues: c))"
        case .rotate(let d): step.title + ": \(d)°"
        case .export(let f, let dpi): f == .png || f == .jpeg ? loc("{0} at {1} dpi", step.title, CoreLanguage.number(dpi)) : step.title
        case .protect(let p): "\(step.title): \(passwordsNamed(p))"
        case .sanitize(let items): "\(step.title): \(items.count == 1 ? loc("1 kind") : loc("{0} kinds", CoreLanguage.number(items.count)))"
        case .redactPatterns(let r): step.title + ": " + (r.setName.map { loc("Saved set \"{0}\"", $0) } ?? (r.patterns.map { RedactionPatterns.name($0) } + r.phrases).joined(separator: ", "))
        default: step.title
        }
    }

    private static func headerFooterTexts(_ o: HeaderFooterOptions, continues: Bool) -> String {
        let texts = HeaderFooterSlot.allCases.map { o.text($0) }.filter { !$0.isEmpty }.joined(separator: " · ")
        return continues ? texts + " " + loc("(numbers continue)") : texts
    }

    /// Which passwords a Protect action sets, in words.
    private static func passwordsNamed(_ p: ProtectStep) -> String {
        switch (p.userPassword != nil, p.ownerPassword != nil) {
        case (true, true): loc("open password and permissions password")
        case (true, false): loc("open password")
        case (false, true): loc("permissions password")
        case (false, false): ""
        }
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> (any NSPasteboardWriting)? {
        guard tableView === actionTable else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(row), forType: Self.rowType)
        return item
    }

    func tableView(_ tableView: NSTableView, validateDrop info: any NSDraggingInfo, proposedRow row: Int, proposedDropOperation: NSTableView.DropOperation) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return tableView === actionTable ? .move : .copy
    }

    func tableView(_ tableView: NSTableView, acceptDrop info: any NSDraggingInfo, row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        if tableView === actionTable {
            let rows = (info.draggingPasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: Self.rowType).flatMap(Int.init) }
            guard let from = rows.first else { return false }
            let step = steps.remove(at: from)
            steps.insert(step, at: min(from < row ? row - 1 : row, steps.count))
            refresh()
            return true
        }
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        for url in urls {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { addFolder(url.path, recursive: true) } else { add([url.path]) }
        }
        return !urls.isEmpty
    }

    @objc private func addFilesClicked() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, .image]
        panel.allowsMultipleSelection = true
        panel.message = loc("Choose PDFs or pictures for the batch.")
        guard let urls = StartWindowController.pick(panel) else { return }
        add(urls.map(\.path))
    }

    @objc private func addFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = loc("Choose a folder: its PDFs and pictures are added.")
        let recursive = NSButton(checkboxWithTitle: loc("Subfolders too"), target: nil, action: nil)
        panel.accessoryView = recursive
        panel.isAccessoryViewDisclosed = true
        guard let url = StartWindowController.pick(panel)?.first else { return }
        addFolder(url.path, recursive: recursive.state == .on)
    }

    @objc private func removeFilesClicked() {
        let rows = fileTable.selectedRowIndexes
        guard !rows.isEmpty else { return NSSound.beep() }
        files = files.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        status = status.enumerated().filter { !rows.contains($0.offset) }.map(\.element)
        refresh()
    }

    @objc private func clearFilesClicked() {
        files = []
        status = []
        lastSummary = nil
        refresh()
    }

    @objc private func openResult() {
        let row = fileTable.clickedRow
        guard row >= 0, let result = lastSummary?.items.first(where: { $0.file.path == files[row].path }), let first = result.outputs.first else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: first))
    }

    @objc private func chooseFolderClicked() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = loc("Where the results go.")
        guard let url = StartWindowController.pick(panel)?.first else { return }
        folderField.stringValue = url.path
    }

    // MARK: Actions

    @objc private func addActionPicked(_ sender: NSMenuItem) {
        let step = Self.offered[sender.tag]
        ActionSheet.edit(step, on: window) { [weak self] edited in
            guard let self, let edited else { return }
            self.steps.append(edited)
            self.refresh()
        }
    }

    @objc private func editActionClicked() {
        let row = actionTable.selectedRow >= 0 ? actionTable.selectedRow : actionTable.clickedRow
        guard row >= 0 else { return NSSound.beep() }
        ActionSheet.edit(steps[row], on: window) { [weak self] edited in
            guard let self, let edited else { return }
            self.steps[row] = edited
            self.refresh()
        }
    }

    @objc private func moveActionUp() {
        let row = actionTable.selectedRow
        guard row > 0 else { return NSSound.beep() }
        steps.swapAt(row, row - 1)
        refresh()
        actionTable.selectRowIndexes(IndexSet(integer: row - 1), byExtendingSelection: false)
    }

    @objc private func moveActionDown() {
        let row = actionTable.selectedRow
        guard row >= 0, row < steps.count - 1 else { return NSSound.beep() }
        steps.swapAt(row, row + 1)
        refresh()
        actionTable.selectRowIndexes(IndexSet(integer: row + 1), byExtendingSelection: false)
    }

    @objc private func removeActionClicked() {
        let row = actionTable.selectedRow
        guard row >= 0 else { return NSSound.beep() }
        steps.remove(at: row)
        refresh()
    }

    // MARK: The plan and the run

    /// The window's choices as a plan (the output folder as typed).
    var plan: BatchPlan {
        var plan = BatchPlan(steps: steps, outputFolder: (folderField.stringValue as NSString).expandingTildeInPath)
        plan.nameTemplate = namesField.stringValue
        plan.neverOverwrite = neverOverwrite.state == .on
        plan.keepSubfolders = keepSubfolders.state == .on
        plan.signedFiles = signedFiles.indexOfSelectedItem == 1 ? .edit : .skip
        plan.passwords = passwords.indexOfSelectedItem == 1 ? .skip : .ask
        plan.imagePageSize = [.fitImage, .letter, .a4][max(imagePages.indexOfSelectedItem, 0)]
        return plan
    }

    func apply(_ preset: BatchPreset) {
        steps = preset.steps
        if let folder = preset.outputFolder { folderField.stringValue = folder }
        namesField.stringValue = preset.nameTemplate
        neverOverwrite.state = preset.neverOverwrite ? .on : .off
        keepSubfolders.state = preset.keepSubfolders ? .on : .off
        signedFiles.selectItem(at: preset.signedFiles == .edit ? 1 : 0)
        passwords.selectItem(at: preset.passwords == .skip ? 1 : 0)
        imagePages.selectItem(at: preset.imagePageSize == .letter ? 1 : preset.imagePageSize == .a4 ? 2 : 0)
        refresh()
    }

    @objc private func runClicked() {
        guard task == nil else { return }
        let plan = plan
        if let error = plan.validate(ocrAvailable: true) { return show(error) }
        for case .protect(let p) in plan.steps where p.needsPasswords {
            return show(loc("Protect with a password needs its passwords: choose it and Edit… to type them."))
        }
        AppSettings.defaults.set(plan.outputFolder, forKey: "BatchFolder")
        // Ends in "…" in every language: a row's text ending so is still under way (`progressed`).
        status = Array(repeating: loc("Waiting…"), count: files.count)
        lastSummary = nil
        let token = CancelToken()
        cancel = token
        progress.doubleValue = 0
        summary.stringValue = loc("Running…")
        let files = files
        let host = SavedOcr.batchHost(askPassword: { [weak self] request, _ in await self?.askPassword(request) })
        let onProgress: @Sendable (BatchProgress) -> Void = { [weak self] p in
            onMain { self?.progressed(p) }
        }
        task = Task { @MainActor in
            do {
                let result = try await BatchRunner.run(files, plan, host, progress: onProgress, cancel: token)
                lastSummary = result
                Report.note("batch: \(result.text)")
            } catch {
                show(loc("The batch couldn't run: {0}", NSAlert.plainText(error)))
            }
            task = nil
            cancel = nil
            progress.doubleValue = 1
            refresh()
        }
        refresh()
    }

    private func progressed(_ p: BatchProgress) {
        guard p.index < status.count else { return }
        if let r = p.result {
            var text = r.message
            if !r.notes.isEmpty { text += " (\(r.notes.joined(separator: "; ")))" }
            status[p.index] = text
            let finished = status.filter { !$0.isEmpty && !$0.hasSuffix("…") }.count
            progress.doubleValue = Double(finished) / Double(max(1, files.count))
        } else {
            status[p.index] = p.message
        }
        fileTable.reloadData(forRowIndexes: IndexSet(integer: p.index), columnIndexes: IndexSet(integer: 1))
    }

    /// The last run's removal report as a page.
    @objc func reportClicked() {
        guard let report = lastSummary?.redactionReport, let window, reportSheet == nil else { return }
        let sheet = RemovalReportSheet(report, suggestedName: loc("Batch"))
        reportSheet = sheet
        Task { @MainActor in
            await sheet.run(on: window)
            reportSheet = nil
        }
    }

    @objc private func stopClicked() {
        cancel?.cancel()
        summary.stringValue = loc("Stopping after the current actions…")
        stopButton.isEnabled = false
    }

    /// A password for a file, asked as a sheet (nil skips the file; the self-test skips).
    private func askPassword(_ request: BatchPasswordRequest) async -> String? {
        guard let window, !Report.isRunning else { return nil }
        return await withCheckedContinuation { cont in
            let alert = NSAlert()
            let name = (request.file.path as NSString).lastPathComponent
            switch request.kind {
            case .open: alert.messageText = request.wrong ? loc("That isn't the password of {0}.", name) : loc("{0} needs a password to open.", name)
            case .permissions:
                alert.messageText = request.wrong ? loc("That isn't the permissions password of {0}.", name) : loc("Changing {0} needs its permissions password.", name)
            }
            alert.informativeText = loc("Type it, or Skip to leave this file out.")
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.setAccessibleName(loc("Password"))
            alert.accessoryView = field
            alert.addButton(withTitle: loc("Continue"))
            alert.addButton(withTitle: loc("Skip"))
            alert.window.initialFirstResponder = field
            alert.beginSheetModal(for: window) { response in
                cont.resume(returning: response == .alertFirstButtonReturn ? field.stringValue : nil)
            }
        }
    }

    /// An alert over the window: `message` is shown as given (pass it through `loc`).
    private func show(_ message: String) {
        Report.note("ERROR batch: \(message)")
        guard let window, !Report.isRunning else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.beginSheetModal(for: window)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if task != nil {
            show(loc("The batch is running: Stop it first."))
            return false
        }
        return true
    }

    // MARK: Presets

    private var presetPaths: [String] = []

    private func reloadPresets() {
        presetPopup.removeAllItems()
        presetPopup.addItem(withTitle: loc("Choose a preset…"))
        presetPaths = ((try? FileManager.default.contentsOfDirectory(atPath: Self.presetsFolder)) ?? [])
            .filter { $0.lowercased().hasSuffix(".json") }.sorted { $0.lowercased() < $1.lowercased() }
            .map { (Self.presetsFolder as NSString).appendingPathComponent($0) }
        for path in presetPaths { presetPopup.addItem(withTitle: ((path as NSString).lastPathComponent as NSString).deletingPathExtension) }
    }

    private func proAllows(_ feature: ProFeature) -> Bool {
        if Pro.allows(feature) { return true }
        ProWindowController.show(feature: feature)
        return false
    }

    @objc private func presetPicked() {
        let i = presetPopup.indexOfSelectedItem - 1
        guard i >= 0, i < presetPaths.count else { return }
        guard proAllows(.batchPresets) else { return presetPopup.selectItem(at: 0) }
        load(presetPaths[i])
    }

    func load(_ path: String) {
        do {
            apply(try BatchPresets.load(path))
        } catch let e as BatchPresetError {
            show(e.message)
        } catch {
            show("\(error)")
        }
    }

    @objc private func savePresetClicked() {
        guard proAllows(.batchPresets), let window else { return }
        guard !steps.isEmpty else { return show(loc("Add at least one action to save as a preset.")) }
        let alert = NSAlert()
        alert.messageText = loc("Save Preset")
        alert.informativeText = loc("The actions with their settings, the names and the choices, under a name. Passwords are never kept.")
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        name.placeholderString = loc("Preset name")
        let keepFolder = NSButton(checkboxWithTitle: loc("Keep the results folder in the preset"), target: nil, action: nil)
        keepFolder.state = .on
        let stack = NSStackView(views: [name, keepFolder])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame = NSRect(x: 0, y: 0, width: 300, height: 56)
        alert.accessoryView = stack
        alert.addButton(withTitle: loc("Save"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.window.initialFirstResponder = name
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                let title = name.stringValue.trimmingCharacters(in: .whitespaces)
                guard !title.isEmpty else { return self.show(loc("Type a name for the preset.")) }
                self.savePreset(title, keepFolder: keepFolder.state == .on)
            }
        }
    }

    func savePreset(_ title: String, keepFolder: Bool) {
        let preset = BatchPreset.from(title, plan, keepFolder: keepFolder)
        let path = (Self.presetsFolder as NSString).appendingPathComponent(BatchPresets.fileName(title))
        do {
            try BatchPresets.save(preset, path)
            reloadPresets()
            if let i = presetPaths.firstIndex(of: path) { presetPopup.selectItem(at: i + 1) }
        } catch {
            show(loc("The preset couldn't be saved: {0}", error.localizedDescription))
        }
    }

    @objc private func exportPresetClicked() {
        guard proAllows(.batchPresets), !steps.isEmpty else { return NSSound.beep() }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        let selected = presetPopup.indexOfSelectedItem - 1
        let fallback = loc("Batch preset")
        let name = selected >= 0 && selected < presetPaths.count ? presetPopup.titleOfSelectedItem ?? fallback : fallback
        panel.nameFieldStringValue = BatchPresets.fileName(name)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BatchPresets.save(BatchPreset.from(name, plan, keepFolder: true), url.path)
        } catch {
            show(loc("The preset couldn't be saved: {0}", error.localizedDescription))
        }
    }

    @objc private func importPresetClicked() {
        guard proAllows(.batchPresets) else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = loc("Choose a batch preset (JSON).")
        guard let url = StartWindowController.pick(panel)?.first else { return }
        do {
            let preset = try BatchPresets.load(url.path)
            apply(preset)
            let path = (Self.presetsFolder as NSString).appendingPathComponent(BatchPresets.fileName(preset.name))
            try BatchPresets.save(preset, path)
            reloadPresets()
            if let i = presetPaths.firstIndex(of: path) { presetPopup.selectItem(at: i + 1) }
        } catch let e as BatchPresetError {
            show(e.message)
        } catch {
            show("\(error)")
        }
    }

    @objc private func watchedFoldersClicked() {
        guard proAllows(.watchedFolders) else { return }
        WatchedFoldersWindowController.show()
    }
}

/// The sheet with an action's settings (the same as its own command's).
@MainActor
enum ActionSheet {
    static func edit(_ step: BatchStep, on window: NSWindow?, _ done: @escaping @MainActor (BatchStep?) -> Void) {
        guard let window else { return done(nil) }
        let alert = NSAlert()
        alert.messageText = step.title
        let read: () -> BatchStep?
        switch step {
        case .unprotect, .checkRedaction, .checkAccessibility, .reportContents, .ocr, .makeAccessible, .saveAsPdfA, .saveAsPdfA2a:
            return done(step)
        case .optimize(let o):
            alert.informativeText = loc("Pictures shown larger than the chosen resolution are downsampled and stored as JPEG; identical streams merged, uncompressed ones compressed.")
            let qualities = [loc("High quality (200 dpi)"), loc("Medium (150 dpi)"), loc("Low (96 dpi)"), loc("Keep pictures as they are")]
            let quality = popup(qualities, o.maxImageDpi == 200 ? 0 : o.maxImageDpi == 96 ? 2 : o.maxImageDpi == nil ? 3 : 1)
            let thumbs = check(loc("Remove embedded page thumbnails"), o.removeThumbnails)
            let piece = check(loc("Remove other apps' private data"), o.removePieceInfo)
            let meta = check(loc("Remove XMP metadata (the title and author stay)"), o.removeMetadata)
            alert.accessoryView = column([quality, thumbs, piece, meta], width: 360)
            read = {
                var n = o
                n.maxImageDpi = [200.0, 150, 96, nil][max(quality.indexOfSelectedItem, 0)]
                n.removeThumbnails = thumbs.state == .on
                n.removePieceInfo = piece.state == .on
                n.removeMetadata = meta.state == .on
                return .optimize(n)
            }
        case .protect(let p):
            alert.informativeText = loc("AES-256 (AES-128 for old readers). Passwords are asked here and never kept in a preset.")
            let open = NSSecureTextField(string: p.userPassword ?? "")
            open.placeholderString = loc("Password to open (optional)")
            let owner = NSSecureTextField(string: p.ownerPassword ?? "")
            owner.placeholderString = loc("Permissions password (optional)")
            let printings = [loc("Printing allowed"), loc("Low-resolution printing only"), loc("No printing")]
            let print = popup(printings, p.permissions.print == .highResolution ? 0 : p.permissions.print == .lowResolution ? 1 : 2)
            let copy = check(loc("Allow copying text and pictures"), p.permissions.copy)
            let modify = check(loc("Allow changing the pages"), p.permissions.modify)
            let annotate = check(loc("Allow comments"), p.permissions.annotate)
            let fill = check(loc("Allow filling forms"), p.permissions.fillForms)
            let assemble = check(loc("Allow rearranging pages"), p.permissions.assemble)
            let method = popup(["AES-256", loc("AES-128 (old readers)")], p.method == .aes128 ? 1 : 0)
            for f in [open, owner] { f.widthAnchor.constraint(equalToConstant: 300).isActive = true }
            alert.accessoryView = column([open, owner, print, copy, modify, annotate, fill, assemble, method], width: 360)
            read = {
                let user = open.stringValue.isEmpty ? nil : open.stringValue
                let ownerPassword = owner.stringValue.isEmpty ? nil : owner.stringValue
                let perms = PdfPermissions(print: [.highResolution, .lowResolution, .none][max(print.indexOfSelectedItem, 0)], copy: copy.state == .on,
                                           modify: modify.state == .on, annotate: annotate.state == .on, fillForms: fill.state == .on, assemble: assemble.state == .on)
                return .protect(ProtectStep(user, ownerPassword, ownerPassword == nil ? .all : perms, method.indexOfSelectedItem == 1 ? .aes128 : .aes256))
            }
        case .sanitize(let items):
            alert.informativeText = loc("What to remove from each file.")
            let boxes = SanitizeItem.allCases.map { check(sanitizeLabel($0), items.contains($0)) }
            alert.accessoryView = column(boxes, width: 420)
            read = { .sanitize(Set(zip(SanitizeItem.allCases, boxes).filter { $0.1.state == .on }.map(\.0))) }
        case .redactPatterns(let r):
            alert.informativeText = loc("Found on every page and blacked out at once; the pages with matches become pictures with their text recognized again.")
            let boxes = RedactionPatterns.builtIn.map { check(RedactionPatterns.name($0), r.patterns.contains($0)) }
            let phrases = NSTextField(string: r.phrases.joined(separator: ", "))
            phrases.placeholderString = loc("Words or phrases, comma-separated")
            let expression = NSTextField(string: r.expression ?? "")
            expression.placeholderString = loc("Your own pattern (ICU regular expression)")
            let whole = check(loc("Whole words only"), r.wholeWord)
            let caseBox = check(loc("Match case"), r.matchCase)
            for f in [phrases, expression] { f.widthAnchor.constraint(equalToConstant: 380).isActive = true }
            // A saved set fills the choices in (Pro); changed after, the step is the person's own again.
            let (sets, _) = RedactionPatternSets.list(RedactionPatternSets.defaultFolder)
            let setPopup = popup([loc("No saved set")] + sets.map(\.name), max(0, (sets.firstIndex { $0.name == r.setName } ?? -1) + 1))
            setPopup.setAccessibilityLabel(loc("Saved set"))
            let fill = SetFiller {
                let i = setPopup.indexOfSelectedItem - 1
                guard sets.indices.contains(i) else { return }
                guard Pro.allows(.patternRedaction) else {
                    setPopup.selectItem(at: 0)
                    ProWindowController.show(feature: .patternRedaction)
                    return
                }
                let o = sets[i].options
                for (kind, box) in zip(RedactionPatterns.builtIn, boxes) { box.state = o.patterns.contains(kind) ? .on : .off }
                phrases.stringValue = o.phrases.joined(separator: ", ")
                expression.stringValue = o.expression ?? ""
                whole.state = o.wholeWord ? .on : .off
                caseBox.state = o.matchCase ? .on : .off
            }
            setPopup.target = fill
            setPopup.action = #selector(SetFiller.picked)
            alert.accessoryView = column([setPopup] + boxes + [phrases, expression, whole, caseBox], width: 420)
            read = {
                _ = fill // kept alive while the alert is open
                var n = r
                n.patterns = Set(zip(RedactionPatterns.builtIn, boxes).filter { $0.1.state == .on }.map(\.0))
                n.phrases = phrases.stringValue.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                n.expression = expression.stringValue.isEmpty ? nil : expression.stringValue
                n.wholeWord = whole.state == .on
                n.matchCase = caseBox.state == .on
                let i = setPopup.indexOfSelectedItem - 1
                n.setName = sets.indices.contains(i) && sets[i].options.patterns == n.patterns && sets[i].options.phrases == n.phrases
                    && sets[i].options.expression == n.expression && sets[i].options.wholeWord == n.wholeWord && sets[i].options.matchCase == n.matchCase
                    ? sets[i].name : nil
                return .redactPatterns(n)
            }
        case .watermark(let o):
            alert.informativeText = loc("A text turned and see-through (a preset's picture stays as it is).")
            let text = NSTextField(string: o.text ?? "")
            text.placeholderString = loc("DRAFT, CONFIDENTIAL, …")
            let size = NSTextField(string: PdfNum.f2(o.fontSize))
            let opacity = NSTextField(string: String(Int(o.opacity * 100)))
            let rotation = NSTextField(string: PdfNum.f2(o.rotation))
            let layout = popup([loc("Once, in the middle"), loc("Tiled across the page")], o.layout == .tiled ? 1 : 0)
            let behind = check(loc("Behind the page's content"), o.behind)
            text.widthAnchor.constraint(equalToConstant: 300).isActive = true
            var rows: [[Any]] = [[loc("Text:"), text], [loc("Font size:"), size], [loc("Opacity (%):"), opacity]]
            rows += [[loc("Angle:"), rotation], [loc("Layout:"), layout], ["", behind]]
            alert.accessoryView = grid(rows, width: 420)
            read = {
                var n = o
                let typed = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if n.image == nil || !typed.isEmpty {
                    n.text = typed
                    n.image = nil
                }
                n.fontSize = number(size) ?? 72
                n.opacity = (number(opacity) ?? 30) / 100
                n.rotation = number(rotation) ?? 45
                n.layout = layout.indexOfSelectedItem == 1 ? .tiled : .center
                n.behind = behind.state == .on
                return .watermark(n)
            }
        case .headerFooter(let o, let continues):
            alert.informativeText = loc("Tokens: <<page>>, <<pages>>, <<date>>, <<time>>, <<file>>, <<bates>>.")
            let slots = HeaderFooterSlot.allCases.map { s -> NSTextField in
                let f = NSTextField(string: o.text(s))
                f.widthAnchor.constraint(equalToConstant: 130).isActive = true
                return f
            }
            let size = NSTextField(string: PdfNum.f2(o.fontSize))
            let batesOn = check(loc("Bates numbers (<<bates>>)"), o.bates != nil)
            let prefix = NSTextField(string: o.bates?.prefix ?? "")
            prefix.placeholderString = loc("Prefix")
            let start = NSTextField(string: String(o.bates?.start ?? 1))
            let digits = NSTextField(string: String(o.bates?.digits ?? 6))
            let suffix = NSTextField(string: o.bates?.suffix ?? "")
            suffix.placeholderString = loc("Suffix")
            let cont = check(loc("Numbers continue from one file to the next"), continues)
            for f in [size, start, digits] { f.widthAnchor.constraint(equalToConstant: 60).isActive = true }
            for f in [prefix, suffix] { f.widthAnchor.constraint(equalToConstant: 90).isActive = true }
            let columns = [NSTextField(labelWithString: loc("Left")), NSTextField(labelWithString: loc("Center")), NSTextField(labelWithString: loc("Right"))]
            let g = NSGridView(views: [
                [NSTextField(labelWithString: "")] + columns,
                [NSTextField(labelWithString: loc("Header:")), slots[0], slots[1], slots[2]],
                [NSTextField(labelWithString: loc("Footer:")), slots[3], slots[4], slots[5]],
                [NSTextField(labelWithString: loc("Font size:")), size, batesOn, NSGridCell.emptyContentView],
                [NSTextField(labelWithString: loc("Bates:")), prefix, start, digits],
                [NSTextField(labelWithString: ""), suffix, cont, NSGridCell.emptyContentView],
            ])
            g.rowSpacing = 6
            g.columnSpacing = 8
            g.frame = NSRect(x: 0, y: 0, width: 520, height: 190)
            alert.accessoryView = g
            read = {
                var n = o
                (n.headerLeft, n.headerCenter, n.headerRight) = (slots[0].stringValue, slots[1].stringValue, slots[2].stringValue)
                (n.footerLeft, n.footerCenter, n.footerRight) = (slots[3].stringValue, slots[4].stringValue, slots[5].stringValue)
                n.fontSize = number(size) ?? 10
                n.bates = batesOn.state == .on
                    ? BatesFormat(prefix.stringValue, Int64(start.stringValue.trimmingCharacters(in: .whitespaces)) ?? 1, Int(digits.stringValue.trimmingCharacters(in: .whitespaces)) ?? 6, suffix.stringValue)
                    : nil
                return .headerFooter(n, continueBates: cont.state == .on)
            }
        case .rotate(let d):
            let turn = popup([loc("Right (90°)"), loc("Upside down (180°)"), loc("Left (−90°)")], d == 180 ? 1 : d < 0 || d == 270 ? 2 : 0)
            alert.accessoryView = column([turn], width: 300)
            read = { .rotate([90, 180, -90][max(turn.indexOfSelectedItem, 0)]) }
        case .flatten(let f):
            let annotations = check(loc("Comments and drawings"), f.annotations)
            let fields = check(loc("Form fields (the form is removed)"), f.formFields)
            let links = check(loc("Links (removed)"), f.links)
            let printable = check(loc("Only what prints"), f.printableOnly)
            alert.accessoryView = column([annotations, fields, links, printable], width: 360)
            read = { .flatten(FlattenOptions(annotations: annotations.state == .on, formFields: fields.state == .on, links: links.state == .on, printableOnly: printable.state == .on)) }
        case .export(let format, let dpi):
            if format == .png || format == .jpeg {
                let resolution = popup([72, 150, 300, 600].map { loc("{0} dpi", CoreLanguage.number($0)) }, dpi == 72 ? 0 : dpi == 300 ? 2 : dpi == 600 ? 3 : 1)
                alert.accessoryView = column([resolution], width: 300)
                read = { .export(format, dpi: [72, 150, 300, 600][max(resolution.indexOfSelectedItem, 0)]) }
            } else {
                return done(step)
            }
        }
        alert.addButton(withTitle: loc("OK"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated { done(response == .alertFirstButtonReturn ? read() : nil) }
        }
    }

    static func sanitizeLabel(_ item: SanitizeItem) -> String {
        switch item {
        case .metadata: loc("Document properties and metadata")
        case .hiddenLayers: loc("Hidden layers")
        case .hiddenAnnotations: loc("Hidden comments and fields")
        case .comments: loc("Comments, markup, stamps and drawings")
        case .formValues: loc("Form values")
        case .bookmarks: loc("Bookmarks")
        case .thumbnails: loc("Page thumbnails")
        case .activeContent: loc("Scripts and active content")
        case .externalLinks: loc("Links to the web and other files")
        case .embeddedFiles: loc("Attached files")
        case .signatures: loc("Digital signatures")
        }
    }

    private static func number(_ field: NSTextField) -> Double? {
        TypedNumber.parse(field.stringValue)
    }

    private static func check(_ title: String, _ on: Bool) -> NSButton {
        let b = NSButton(checkboxWithTitle: title, target: nil, action: nil)
        b.state = on ? .on : .off
        return b
    }

    private static func popup(_ titles: [String], _ selected: Int) -> NSPopUpButton {
        let p = NSPopUpButton(frame: .zero, pullsDown: false)
        p.addItems(withTitles: titles)
        p.selectItem(at: selected)
        return p
    }

    private static func column(_ views: [NSView], width: CGFloat) -> NSView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(views.count) * 28)
        return stack
    }

    private static func grid(_ rows: [[Any]], width: CGFloat) -> NSView {
        let g = NSGridView(views: rows.map { row in row.map { $0 as? NSView ?? NSTextField(labelWithString: $0 as? String ?? "") } })
        g.rowSpacing = 6
        g.columnSpacing = 8
        g.frame = NSRect(x: 0, y: 0, width: width, height: CGFloat(rows.count) * 30)
        return g
    }
}

/// The folders Inkvolt PDF watches while it is open (the Windows app's `FolderWatches`): each with its preset, saved in
/// the settings and started again with the app; a watch runs `WatchedFolder.run` until stopped.
@MainActor
final class FolderWatches {
    static let shared = FolderWatches()
    static let settingsKey = "WatchedFolders"

    @MainActor
    final class Watch {
        let folder: String
        let preset: String
        var enabled: Bool
        var task: Task<Void, Never>?
        var cancel: CancelToken?
        var status = loc("Stopped")
        init(folder: String, preset: String, enabled: Bool) {
            self.folder = folder
            self.preset = preset
            self.enabled = enabled
        }
    }

    private(set) var all: [Watch] = []
    var changed: (() -> Void)?

    /// The watches saved in the settings; started unless the user stopped them.
    func startSaved() {
        guard !Report.isRunning else { return }
        for entry in AppSettings.defaults.array(forKey: Self.settingsKey) as? [[String: Any]] ?? [] {
            guard let folder = entry["folder"] as? String, let preset = entry["preset"] as? String else { continue }
            let w = Watch(folder: folder, preset: preset, enabled: entry["enabled"] as? Bool ?? true)
            all.append(w)
            if w.enabled { start(w) }
        }
    }

    func save() {
        AppSettings.defaults.set(all.map { ["folder": $0.folder, "preset": $0.preset, "enabled": $0.enabled] }, forKey: Self.settingsKey)
        changed?()
    }

    func add(folder: String, preset: String) {
        let w = Watch(folder: folder, preset: preset, enabled: true)
        all.append(w)
        start(w)
        save()
    }

    func remove(_ w: Watch) {
        stop(w)
        all.removeAll { $0 === w }
        save()
    }

    func start(_ w: Watch) {
        guard w.task == nil else { return }
        guard Pro.allows(.watchedFolders) else {
            w.status = Pro.locked(.watchedFolders)
            w.enabled = false
            return
        }
        let preset: BatchPreset
        do {
            preset = try BatchPresets.load(w.preset)
        } catch {
            w.status = loc("The preset can't be read: {0}", (error as? BatchPresetError)?.message ?? "\(error)")
            w.enabled = false
            changed?()
            return
        }
        let outFolder = preset.outputFolder ?? WatchedFolder.defaultOutput(w.folder)
        let plan = preset.toPlan(outFolder)
        let token = CancelToken()
        w.cancel = token
        w.enabled = true
        w.status = loc("Watching")
        let folder = w.folder
        let host = SavedOcr.batchHost()
        w.task = Task { @MainActor in
            do {
                let onProgress: @Sendable (WatchProgress) -> Void = { p in
                    onMain {
                        if let e = p.finished {
                            w.status = "\(Self.stateText(e.state)): \(e.fileName)"
                        } else if p.working > 0 {
                            w.status = p.working == 1 ? loc("Working on 1 file") : loc("Working on {0} files", CoreLanguage.number(p.working))
                        }
                        self.changed?()
                    }
                }
                let summary = try await WatchedFolder.run(folder, plan, host, WatchOptions(), progress: onProgress, cancel: token)
                w.status = loc("Stopped ({0} done, {1} failed)", CoreLanguage.number(summary.done), CoreLanguage.number(summary.failed))
            } catch {
                w.status = loc("Stopped: {0}", NSAlert.plainText(error))
                w.enabled = false
            }
            w.task = nil
            w.cancel = nil
            self.changed?()
        }
        changed?()
    }

    func stop(_ w: Watch) {
        w.cancel?.cancel()
        w.enabled = false
        w.status = loc("Stopping…")
        changed?()
    }

    /// A file's state as the Status column shows it (the raw value stays the log's).
    nonisolated static func stateText(_ state: BatchItemState) -> String {
        switch state {
        case .waiting: loc("waiting", context: "batch state")
        case .running: loc("working", context: "batch state")
        case .done: loc("done", context: "batch state")
        case .skipped: loc("skipped", context: "batch state")
        case .failed: loc("failed", context: "batch state")
        case .cancelled: loc("cancelled", context: "batch state")
        }
    }
}

/// Batch › Watched Folders… (and File › Watched Folders…): the folders watched while the app is open, with their preset
/// and what they are doing; Add… picks a folder and a preset, Start/Stop and Remove act on the chosen one.
@MainActor
final class WatchedFoldersWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static var shared: WatchedFoldersWindowController?
    let table = NSTableView()

    static func show() {
        let controller = shared ?? WatchedFoldersWindowController()
        shared = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 360), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = loc("Watched Folders")
        window.isRestorable = false
        super.init(window: window)
        for (id, title, width) in [("folder", loc("Folder"), 260.0), ("preset", loc("Preset"), 180.0), ("status", loc("Status"), 220.0)] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(loc("Watched folders"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let note = NSTextField(wrappingLabelWithString: loc("Each PDF or picture put in a watched folder runs through its preset once it has stopped growing; the original moves to \"done\" or \"failed\" below the folder, and inkvolt-watch.log there gets a line per file. Folders are watched while Inkvolt PDF is open. For one watched without the app, see the command line (--help)."))
        note.preferredMaxLayoutWidth = 680
        let add = NSButton(title: loc("Add…"), target: self, action: #selector(addClicked))
        let startStop = NSButton(title: loc("Start / Stop"), target: self, action: #selector(startStopClicked))
        let remove = NSButton(title: loc("Remove"), target: self, action: #selector(removeClicked))
        let buttons = NSStackView(views: [add, startStop, remove])
        let stack = NSStackView(views: [note, scroll, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        window.contentView = stack
        window.center()
        FolderWatches.shared.changed = { [weak self] in self?.table.reloadData() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func numberOfRows(in tableView: NSTableView) -> Int { FolderWatches.shared.all.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let w = FolderWatches.shared.all[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "folder": text = w.folder
        case "preset": text = ((w.preset as NSString).lastPathComponent as NSString).deletingPathExtension
        default: text = w.status
        }
        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    @objc private func addClicked() {
        let folderPanel = NSOpenPanel()
        folderPanel.canChooseDirectories = true
        folderPanel.canChooseFiles = false
        folderPanel.message = loc("Choose the folder to watch.")
        guard let folder = StartWindowController.pick(folderPanel)?.first else { return }
        let presetPanel = NSOpenPanel()
        presetPanel.allowedContentTypes = [.json]
        presetPanel.directoryURL = URL(fileURLWithPath: BatchWindowController.presetsFolder)
        presetPanel.message = loc("Choose the preset to run on each file (a batch preset, JSON).")
        guard let preset = StartWindowController.pick(presetPanel)?.first else { return }
        FolderWatches.shared.add(folder: folder.path, preset: preset.path)
    }

    @objc private func startStopClicked() {
        let row = table.selectedRow
        guard row >= 0 else { return NSSound.beep() }
        let w = FolderWatches.shared.all[row]
        if w.task != nil { FolderWatches.shared.stop(w) } else { FolderWatches.shared.start(w) }
        FolderWatches.shared.save()
    }

    @objc private func removeClicked() {
        let row = table.selectedRow
        guard row >= 0 else { return NSSound.beep() }
        FolderWatches.shared.remove(FolderWatches.shared.all[row])
    }
}

/// Runs a closure when a saved set is picked in Redact Patterns' editor.
@MainActor
final class SetFiller: NSObject {
    private let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func picked() { action() }
}
