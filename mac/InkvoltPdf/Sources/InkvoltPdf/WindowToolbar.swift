import AppKit
import PdfCore

/// The document window's toolbar (UX review, 2026-11-03): a short set by default, as Preview's (the sidebar, zoom,
/// Highlight, Markup, Fill & Sign, Share, Search; `ToolbarLayout.defaults`), the rest in View › Customize Toolbar….
/// The 26 markup tools moved off the always-shown strip into the markup toolbar, shown when asked for (the Markup
/// button, View › Show Markup Toolbar ⇧⌘A, or any markup tool picked from the Tools menu or its key).
extension DocumentWindowController: NSToolbarDelegate, NSSharingServicePickerToolbarItemDelegate {
    private static func id(_ raw: String) -> NSToolbarItem.Identifier { NSToolbarItem.Identifier(raw) }

    func makeToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "InkvoltPdfDocument")
        toolbar.delegate = self
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = !Report.isRunning
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        // The markup toolbar sits under the toolbar, in its material, as Preview's (UX review, round 2).
        if !window.titlebarAccessoryViewControllers.contains(toolStrip.accessory) {
            window.addTitlebarAccessoryViewController(toolStrip.accessory)
        }
        showMarkup(AppSettings.markupShown, remember: false)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarLayout.defaults.map(Self.id)
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ToolbarLayout.allowed.map(Self.id)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier.rawValue {
        case ToolbarLayout.sidebar:
            return button(identifier, "Sidebar", "sidebar.leading", "Show or hide the sidebar (⌃⌘S)",
                          #selector(NSSplitViewController.toggleSidebar(_:)), target: split)
        case ToolbarLayout.trackingSeparator:
            return NSTrackingSeparatorToolbarItem(identifier: identifier, splitView: split.splitView, dividerIndex: 0)
        case ToolbarLayout.zoom:
            let group = NSToolbarItemGroup(itemIdentifier: identifier, images: [
                symbol("minus.magnifyingglass", "Zoom Out"), symbol("plus.magnifyingglass", "Zoom In"),
            ], selectionMode: .momentary, labels: ["Zoom Out", "Zoom In"], target: self, action: #selector(zoomGroupClicked(_:)))
            group.label = "Zoom"
            group.toolTip = "Zoom out (⌘−) or in (⌘+)"
            return group
        case ToolbarLayout.pageNumber:
            return button(identifier, "Go to Page", "number", "Go to a page (⌥⌘G)", #selector(goToPage(_:)))
        case ToolbarLayout.highlight:
            return button(identifier, "Highlight", "highlighter", "Highlight the selected text, or pick the highlighter (Y)",
                          #selector(highlightClicked(_:)))
        case ToolbarLayout.markup:
            let item = button(identifier, "Markup", "pencil.tip.crop.circle", "Show or hide the markup tools (⇧⌘A)",
                              #selector(toggleMarkup(_:)))
            (item.view as? NSButton)?.setButtonType(.pushOnPushOff)
            (item.view as? NSButton)?.state = AppSettings.markupShown ? .on : .off
            return item
        case ToolbarLayout.fillSign:
            return button(identifier, "Fill & Sign", "signature", "Type on the form, add check marks and your signature (A)",
                          #selector(fillSignClicked(_:)))
        case ToolbarLayout.editContent:
            return button(identifier, "Edit", "pencil.line", "Edit text and images (J)", #selector(editContentClicked(_:)))
        case ToolbarLayout.redact:
            return button(identifier, "Redact", "rectangle.fill.badge.xmark", "Mark text or areas to remove for good (F)",
                          #selector(redactClicked(_:)))
        case ToolbarLayout.organize:
            return button(identifier, "Organize", "square.grid.2x2", "Organize pages (⌥⌘O)", #selector(toggleOrganizer(_:)))
        case ToolbarLayout.rotate:
            return button(identifier, "Rotate", "rotate.right", "Rotate the chosen pages right (⌘R)", #selector(rotatePagesRight(_:)))
        case ToolbarLayout.inspector:
            return button(identifier, "Inspector", "info.circle", "Show the selected comment's settings (⌘I)",
                          #selector(openInspector(_:)))
        case ToolbarLayout.print:
            return button(identifier, "Print", "printer", "Print (⌘P)", #selector(NSDocument.printDocument(_:)), target: nil)
        case ToolbarLayout.commands:
            return button(identifier, "Commands", "command", "Search every command (⇧⌘K)",
                          #selector(AppDelegate.showCommandPalette(_:)), target: nil)
        case ToolbarLayout.share:
            let item = NSSharingServicePickerToolbarItem(itemIdentifier: identifier)
            item.label = "Share"
            item.toolTip = "Send this PDF by Mail, Messages, AirDrop…"
            item.delegate = self
            return item
        case ToolbarLayout.search:
            return button(identifier, "Search", "magnifyingglass", "Find in this document (⌘F)", #selector(showFind(_:)))
        default:
            return nil
        }
    }

    private func symbol(_ name: String, _ label: String) -> NSImage {
        NSImage(systemSymbolName: name, accessibilityDescription: label) ?? NSImage()
    }

    private func button(_ identifier: NSToolbarItem.Identifier, _ label: String, _ symbolName: String, _ tip: String,
                        _ action: Selector, target: AnyObject? = nil) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.image = symbol(symbolName, label)
        item.isBordered = true
        item.target = target ?? self
        item.action = action
        if identifier.rawValue == ToolbarLayout.markup {
            // A toggle shows its state: a button view (a plain item can't stay pressed).
            let b = NSButton(image: symbol(symbolName, label), target: self, action: action)
            b.bezelStyle = .toolbar
            b.setAccessibleName(label)
            b.toolTip = tip
            item.view = b
        }
        return item
    }

    // MARK: The toolbar's actions

    @objc func zoomGroupClicked(_ sender: NSToolbarItemGroup) {
        if sender.selectedIndex == 0 { zoomOut(sender) } else { zoomIn(sender) }
    }

    /// Highlight: the selected text highlighted at once (as Preview's button); with nothing selected, the highlighter.
    @objc func highlightClicked(_ sender: Any?) { highlightText(sender) }

    @objc func fillSignClicked(_ sender: Any?) { pickTool(.fillText) }
    @objc func editContentClicked(_ sender: Any?) { pickTool(.editContent) }
    @objc func redactClicked(_ sender: Any?) { pickTool(.redact) }

    /// View › Show Markup Toolbar (⇧⌘A) and the toolbar's Markup button.
    @objc func toggleMarkup(_ sender: Any?) {
        let show = toolStrip.isHidden || !AppSettings.markupShown
        showMarkup(show)
        // Hiding the tools goes back to reading.
        if !show && !(pages.tool == .hand || pages.tool == .text) { pickTool(.text) }
    }

    /// Shows or hides the markup toolbar (never over Organize Pages' grid); remembered for new windows.
    func showMarkup(_ show: Bool, remember: Bool = true) {
        if remember { AppSettings.markupShown = show }
        toolStrip.isHidden = !show || organizerShown
        markupButton?.state = show ? .on : .off
    }

    /// A markup tool picked while its toolbar is hidden: shown, so the tool's color, width and choices are in sight.
    func revealMarkup(for tool: Tool) {
        guard tool != .hand && tool != .text && tool != .prepareForm, toolStrip.isHidden, !organizerShown else { return }
        showMarkup(true)
    }

    var markupButton: NSButton? {
        window?.toolbar?.items.first { $0.itemIdentifier.rawValue == ToolbarLayout.markup }?.view as? NSButton
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier.rawValue {
        case ToolbarLayout.highlight, ToolbarLayout.fillSign, ToolbarLayout.editContent, ToolbarLayout.redact, ToolbarLayout.markup:
            return pdf.session != nil && !organizerShown
        default:
            return engine.pageCount > 0
        }
    }

    // MARK: Share

    /// File › Share…: the same picker as the toolbar's Share, under the window's toolbar.
    @objc func shareDocument(_ sender: Any?) {
        guard let url = pdf.fileURL, let view = window?.contentView else { return NSSound.beep() }
        let picker = NSSharingServicePicker(items: [url])
        picker.show(relativeTo: NSRect(x: view.bounds.maxX - 60, y: view.bounds.maxY - 2, width: 1, height: 1), of: view, preferredEdge: .minY)
    }

    nonisolated func items(for pickerToolbarItem: NSSharingServicePickerToolbarItem) -> [Any] {
        let url: URL? = MainActor.assumeIsolated { pdf.fileURL }
        return url.map { [$0] } ?? []
    }
}
