import AppKit
import PdfCore
import PrintCore

/// The command bar in the window's toolbar (PdfCore's `CommandBar`; docs/design/command-bar.md, the Windows design the
/// owner approved 2026-11-08): each group an `NSMenuToolbarItem` with its icon and label, whose body runs the group's
/// main job in one click and whose arrow opens its menu (each item with a line under it, `NSMenuItem.subtitle`); the
/// pointer tools an icon-only segmented group. The toolbar's » overflow takes the groups the window has no room for,
/// Scan & OCR first, and keeps Edit, Convert, Comment and Fill & Sign longest (`CommandBar.visibilityPriority`).
/// Option-click on a body asks first, as the menus do (Windows' Shift+click).
extension DocumentWindowController {
    // MARK: Building

    /// The toolbar item of the command bar group `id`.
    func barItem(_ id: String, identifier: NSToolbarItem.Identifier) -> NSToolbarItem? {
        guard let group = BarTable.group(id) else { return nil }
        if !group.hasMainJob { return pointerItem(group, identifier) }
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.title = group.label // shown beside the icon: the label always stays
        item.label = group.label
        item.paletteLabel = group.label
        item.image = NSImage(systemSymbolName: group.symbol, accessibilityDescription: group.label)
        item.showsIndicator = true
        item.target = self
        item.action = #selector(barGroupClicked(_:))
        item.toolTip = loc("{0}: {1}. Option-click to choose options first.", group.main.title, group.main.note)
        item.menu = barMenu(group)
        item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: CommandBar.visibilityPriority(group))
        return item
    }

    /// Hand, Select Text and Snapshot by their icons; the one in use is selected.
    private func pointerItem(_ group: CommandBar.Group, _ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let images = group.items.map { NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.title) ?? NSImage() }
        let item = NSToolbarItemGroup(itemIdentifier: identifier, images: images, selectionMode: .selectOne,
                                      labels: group.items.map(\.title), target: self, action: #selector(pointerClicked(_:)))
        item.label = group.label
        item.paletteLabel = group.label
        item.toolTip = group.items.map { "\($0.title): \($0.note)" }.joined(separator: "\n") // English: punctuation only
        for (sub, entry) in zip(item.subitems, group.items) { sub.toolTip = "\(entry.title): \(entry.note)" } // English: punctuation only
        item.visibilityPriority = NSToolbarItem.VisibilityPriority(rawValue: CommandBar.visibilityPriority(group))
        item.selectedIndex = pointerIndex
        return item
    }

    /// The group's menu: its commands, the main job first, each with the line that says what it does; Comment ends with
    /// the Draw submenu. Its accessibility label names the arrow for VoiceOver ("Convert: more commands").
    func barMenu(_ group: CommandBar.Group) -> NSMenu {
        let menu = NSMenu(title: group.label)
        menu.setAccessibilityLabel(loc("{0}: more commands", group.label))
        for (i, entry) in group.items.enumerated() {
            if entry.startsSection { menu.addItem(.separator()) }
            let item = NSMenuItem(title: entry.title, action: #selector(barItemClicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id
            item.subtitle = entry.note
            item.image = Self.barImage(entry)
            if i == 0 && group.hasMainJob {
                // The main job, as the body runs it.
                item.attributedTitle = NSAttributedString(string: entry.title, attributes: [.font: NSFont.menuFont(ofSize: 0).withWeight(.semibold)])
            }
            menu.addItem(item)
        }
        if group.id == CommandBar.drawsIn {
            menu.addItem(.separator())
            let draw = NSMenuItem(title: loc("Draw"), action: nil, keyEquivalent: "")
            draw.image = NSImage(systemSymbolName: "scribble", accessibilityDescription: nil)
            let sub = NSMenu(title: loc("Draw"))
            for item in MainMenu.toolItems(.draw) { sub.addItem(item) }
            draw.submenu = sub
            menu.addItem(draw)
        }
        return menu
    }

    /// A menu item's symbol: in its file type's colour (Word, Excel, PowerPoint, PDF/A) or red (Apply Redactions), drawn
    /// in the label colour under Increase Contrast; the others monochrome.
    static func barImage(_ entry: CommandBar.Item) -> NSImage? {
        guard let image = NSImage(systemSymbolName: entry.symbol, accessibilityDescription: nil) else { return nil }
        guard let tint = entry.tint else { return image }
        let color = NSColor(name: nil) { appearance in Self.barColor(tint, appearance) }
        return image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color])) ?? image
    }

    /// `tint` in `appearance`: BarColors' light or dark shade, or the label colour under Increase Contrast.
    static func barColor(_ tint: CommandBar.Tint, _ appearance: NSAppearance) -> NSColor {
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            || appearance.bestMatch(from: [.accessibilityHighContrastAqua, .accessibilityHighContrastDarkAqua]) != nil
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua, .accessibilityHighContrastDarkAqua]) != .aqua
        guard let hex = BarColors.color(tint, dark: dark, increaseContrast: contrast), let (r, g, b) = BarColors.rgb(hex) else {
            return .labelColor
        }
        return NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }

    /// The pointer group's selection for the tool in use (none when another tool is).
    var pointerIndex: Int {
        switch activePages.tool {
        case .hand: 0
        case .text: 1
        case .snapshot: 2
        default: -1
        }
    }

    /// Shows the tool in use on the pointer group.
    func updatePointerGroup() {
        let group = window?.toolbar?.items.first { $0.itemIdentifier.rawValue == ToolbarLayout.group(CommandBar.pointer) } as? NSToolbarItemGroup
        if let group, group.selectedIndex != pointerIndex { group.selectedIndex = pointerIndex }
    }

    // MARK: Running

    @objc func pointerClicked(_ sender: NSToolbarItemGroup) {
        // Organize Pages' grid has no page tools: the pointer group is disabled there (`validateBarItem`), and a click
        // that gets through anyway changes nothing.
        guard pdf.session != nil, !organizerShown else {
            updatePointerGroup()
            return NSSound.beep()
        }
        switch sender.selectedIndex {
        case 0: choose(.hand)
        case 1: choose(.text)
        case 2: chooseSnapshot(sender)
        default: break
        }
        updatePointerGroup()
    }

    /// A group's body: its main job, at once (Option: asking first).
    @objc func barGroupClicked(_ sender: Any?) {
        guard let raw = (sender as? NSToolbarItem)?.itemIdentifier.rawValue, let id = ToolbarLayout.groupId(raw),
              let group = BarTable.group(id) else { return }
        runBar(group.main, option: NSEvent.modifierFlags.contains(.option))
    }

    /// A command picked from a group's menu (or its » overflow).
    @objc func barItemClicked(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let entry = Self.barEntry(id) else { return }
        runBar(entry, option: NSEvent.modifierFlags.contains(.option))
    }

    static func barEntry(_ id: String) -> CommandBar.Item? { BarTable.item(id) }

    /// Runs `entry`: its at-once form unless Option is held, else what its menu bar command or tool does.
    func runBar(_ entry: CommandBar.Item, option: Bool) {
        guard barEnabled(entry) else { return NSSound.beep() }
        Report.progress("bar: \(entry.id)\(option ? " (option)" : "")")
        if CommandBar.runsAtOnce(entry, option: option) {
            switch entry.id {
            case "ExportWord": return convertAtOnce(.word)
            case "ExportExcel": return convertAtOnce(.excel)
            case "ExportPowerPoint": return convertAtOnce(.powerPoint)
            case "ExportText": return convertAtOnce(.text)
            case "ExportHtml": return convertAtOnce(.html)
            case "Highlight": return highlightText(nil)
            case "AddSignature": return signAtOnce()
            case "ProtectPassword": return protectAtOnce()
            case "Redact": return redactAtOnce()
            case "RecognizeText": return recognizeAtOnce()
            default: break
            }
        }
        if let tool = entry.tool {
            choose(Self.tool(tool))
        } else if let action = entry.action {
            // The window's own commands come here; the app's (Combine Files…, Scan…) go along the responder chain to the
            // app delegate, as the menu bar sends them.
            let selector = NSSelectorFromString(action)
            NSApp.sendAction(selector, to: barTarget(selector), from: self)
        }
    }

    /// Who runs `selector`: this window when it implements it, else nil (the responder chain, ending at the app delegate).
    func barTarget(_ selector: Selector) -> AnyObject? { responds(to: selector) ? self : nil }

    /// The page tool a bar item picks (a stable key; every case mapped, so a renamed tool fails to build).
    static func tool(_ tool: CommandBar.BarTool) -> Tool {
        switch tool {
        case .hand: .hand
        case .selectText: .text
        case .editContent: .editContent
        case .image: .image
        case .link: .link
        case .note: .note
        case .stamp: .stamp
        case .signature: .signature
        case .addText: .fillText
        case .checkMark: .fillCheck
        case .cross: .fillCross
        case .redact: .redact
        }
    }

    /// Whether `entry` can run now: a menu bar command's own rule (`DocumentCommands`), a tool's as the Tools menu's.
    func barEnabled(_ entry: CommandBar.Item) -> Bool {
        if let action = entry.action, let command = DocumentCommands.command(action: action) {
            return command.isEnabled(in: commandState(for: command))
        }
        return pdf.session != nil && !organizerShown
    }

    /// The body of a group: enabled when its main job can run.
    func validateBarItem(_ identifier: String) -> Bool? {
        guard let id = ToolbarLayout.groupId(identifier), let group = BarTable.group(id) else { return nil }
        return group.hasMainJob ? barEnabled(group.main) : pdf.session != nil && !organizerShown
    }

    // MARK: One-click jobs

    /// Fill & Sign's body: your saved signature, placed with the next click; none yet: the pad to make one. A saved
    /// signature whose picture can't be read says so plainly (`armSignature`).
    func signAtOnce() {
        if let saved = SignatureLibrary.shared.first(initials: false) {
            armSignature(saved)
        } else {
            drawSignature(nil)
        }
    }

    /// Protect's body: only the password (AES-256, nothing restricted). A protected document gets the full sheet, which
    /// shows what it has.
    func protectAtOnce() {
        guard let window, protectSheet == nil, pdf.session != nil else { return }
        if pdf.session?.hasEncryption == true { return protectDocument(nil) }
        let alert = NSAlert()
        alert.messageText = loc("Protect with a password")
        alert.informativeText = loc("Anyone opening the saved file must type it. Option-click Protect for restrictions and other options.")
        let field = NSSecureTextField(), confirm = NSSecureTextField()
        field.placeholderString = loc("Password")
        confirm.placeholderString = loc("Type it again")
        field.setAccessibilityLabel(loc("Password"))
        confirm.setAccessibilityLabel(loc("Type it again"))
        let stack = NSStackView(views: [field, confirm])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: 54)
        for f in [field, confirm] { f.widthAnchor.constraint(equalToConstant: 260).isActive = true }
        alert.accessoryView = stack
        alert.addButton(withTitle: loc("Protect"))
        alert.addButton(withTitle: loc("Cancel"))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                guard response == .alertFirstButtonReturn else { return }
                let password = field.stringValue
                let problem = password.isEmpty ? loc("Enter the open password.")
                    : password != confirm.stringValue ? loc("The open passwords don't match.")
                    : password.contains(",") ? loc("Inkvolt PDF for Mac can't use a comma in a password. Choose one without a comma.")
                    : nil
                if let problem { return self.problemAlert(loc("Not protected"), problem) }
                let choice = ProtectionChoice(userPassword: password, ownerPassword: nil, permissions: .all, method: .aes256)
                Task { await self.protect(choice) }
            }
        }
    }

    /// Protect › Redact: the selected text marked at once; with none, the marking tool.
    func redactAtOnce() {
        if pages.selectedText != nil {
            redactSelectedText(nil)
        } else {
            choose(.redact)
        }
    }

    /// Scan & OCR's body: every page recognized with the last Recognize Text settings (pages with text are skipped).
    func recognizeAtOnce() {
        let all = Array(0..<engine.pageCount)
        guard !all.isEmpty else { return }
        startLongTask { await self.runRecognize(pages: all) }
    }

    /// Convert › Word (Excel, PowerPoint, text, HTML) in one click: name.docx next to the PDF, never over a file
    /// ("name (2).docx", reserved by an exclusive create), or in Documents when the PDF isn't saved or its folder refuses
    /// it; all pages, scans read with the saved recognition settings; the file opened, and a notice to find it or redo it
    /// with options. The document is busy (`isBusy`, the window's long task) from before the reservation on, so no edit
    /// starts meanwhile and a second click (a double-click) converts nothing more: `startLongTask` sets the task before
    /// it returns, and nothing between the check and it lets another click in (the password question is app-modal).
    func convertAtOnce(_ format: ExportFormat) {
        guard let session = pdf.session, !isBusy else { return }
        if session.openPassword != nil && !confirmUnprotected() { return }
        startLongTask {
            let name = (session.displayName as NSString).deletingPathExtension + DocumentExport.fileExtension(format)
            let pdfPath = self.pdf.fileURL?.path
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.path
            let outcome = await Task.detached { ExportTarget.reservation(pdfPath: pdfPath, fileName: name, documents: documents) }.value
            let target: ExportTarget.Reserved?
            if case .reserved(let r) = outcome { target = r } else { target = nil }
            // Closed meanwhile: the empty reserved file goes.
            guard self.window != nil, self.pdf.session != nil else {
                if let target { ExportTarget.deleteIfEmpty(target.path) }
                return
            }
            guard let target else {
                // Why nothing was reserved, then the export's own options and save panel, never offering a device name.
                let why: String
                switch outcome {
                case .deviceName: why = loc("“{0}” can't be a file name on Windows, so it isn't used. Choose where to save it, and under what name.", name)
                case .refused(documentsTried: true): why = loc("Neither the PDF's folder nor Documents accepts new files. Choose where to save it.")
                default: why = loc("The PDF's folder doesn't accept new files and there is no Documents folder to use instead. Choose where to save it.")
                }
                self.problemAlert(loc("Can't save the export"), why)
                let suggested = ExportTarget.allowedName(name)
                DispatchQueue.main.async { MainActor.assumeIsolated { self.askExport(format, fileName: suggested) } }
                return
            }
            let url = URL(fileURLWithPath: target.path)
            let report = await self.runExport(format, to: url, pages: Array(0..<self.engine.pageCount),
                                              recognize: UserDefaults.standard.object(forKey: "ExportOcr") as? Bool != false,
                                              recognizer: Self.atOnceRecognizer, atOnce: target.inDocuments)
            guard report?.saved == true else {
                ExportTarget.deleteIfEmpty(target.path)
                return
            }
            if Report.isRunning {
                Report.progress("convert at once: would open \(url.lastPathComponent)") // never Word in a self-test
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// The links of a one-click conversion's notice: Show in Finder, and Change options…, which opens the export's
    /// options (unless the document closed, or is busy with another job, which it then says).
    func atOnceLinks(_ format: ExportFormat, _ url: URL) -> [(String, () -> Void)] {
        [
            (loc("Show in Finder"), { NSWorkspace.shared.activateFileViewerSelecting([url]) }),
            (loc("Change options…"), { [weak self] in
                guard let self, self.window != nil, let session = self.pdf.session else { return }
                if self.isBusy { return self.notify(loc("Wait a moment: {0} is still busy.", session.displayName)) }
                self.askExport(format)
            }),
        ]
    }
}

/// The command bar's table, built once: the interface's language is chosen at launch and stays for the run (Settings ›
/// Language applies from the next launch), so menu validation and clicks look items up here instead of rebuilding every
/// group's sentences each time. PdfCore's `CommandBar.groups` stays computed, so its tests can switch languages per task.
@MainActor
enum BarTable {
    static let groups = CommandBar.groups
    private static let byGroup = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
    private static let byItem = Dictionary(uniqueKeysWithValues: groups.flatMap(\.items).map { ($0.id, $0) })

    static func group(_ id: String) -> CommandBar.Group? { byGroup[id] }
    static func item(_ id: String) -> CommandBar.Item? { byItem[id] }
}

private extension NSFont {
    func withWeight(_ weight: NSFont.Weight) -> NSFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: weight]])
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
