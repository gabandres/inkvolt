import AppKit
import PrintCore

/// Tools › Command Palette… (⇧⌘K; the Windows app's Ctrl+K, which on the Mac is Link Selected Text, and its Ctrl+Shift+P,
/// which is Page Setup): every menu command that can run now, searched as you type (every word, in any order, in the
/// command or its menu), run with Return or a double-click. The commands are the menu bar's own items (built from the
/// document command table, `DocumentCommands`, with what AppKit adds: Close All, Start Dictation…, Emoji & Symbols, the
/// titles it changes such as Hide Sidebar), each checked and sent along the responder chain of the window that was in
/// front (its first responder, the window, its controller and document, then the app and its delegate), so the palette
/// offers and does what the menus would for that window; a document window checks them by the table's rules.
@MainActor
final class CommandPalette: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static var shared: CommandPalette?

    /// A command: its title, the menus it's in, its shortcut, the menu item, and what handles it. `english` is its title
    /// and menus in English when the interface is in another language (empty in English), so a search in English words
    /// still finds it.
    struct Entry {
        let title: String
        let path: String
        let shortcut: String
        let item: NSMenuItem
        let handler: AnyObject
        var english = ""
    }

    let field = NSSearchField()
    let table = NSTableView()
    private(set) var all: [Entry] = []
    private(set) var shown: [Entry] = []
    /// The window the commands go to (the one in front when the palette opened).
    private weak var target: NSWindow?
    /// The last command run (the self-test reads it).
    private(set) var lastRun: String?

    static func show(over window: NSWindow? = nil) {
        let palette = shared ?? CommandPalette()
        shared = palette
        palette.target = window ?? NSApp.keyWindow ?? NSApp.mainWindow
        palette.all = collect(for: palette.target)
        palette.field.stringValue = ""
        palette.filter("")
        if let front = palette.target, let panel = palette.window {
            let f = front.frame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.maxY - panel.frame.height - 80))
        } else {
            palette.window?.center()
        }
        palette.showWindow(nil)
        palette.window?.makeKeyAndOrderFront(nil)
        palette.window?.makeFirstResponder(palette.field)
    }

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 380), styleMask: [.titled, .closable, .fullSizeContentView],
                            backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isRestorable = false
        panel.hidesOnDeactivate = true
        panel.title = loc("Command Palette")
        super.init(window: panel)
        panel.delegate = self
        field.placeholderString = loc("Search all commands")
        field.delegate = self
        field.font = .systemFont(ofSize: 16)
        field.setAccessibleName(loc("Search all commands"))
        // No close, minimize or zoom buttons: Escape closes it, as Spotlight.
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] { panel.standardWindowButton(kind)?.isHidden = true }
        // The title column takes what the shortcuts leave (they were cut off at the right edge).
        let title = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        title.width = 380
        title.resizingMask = .autoresizingMask
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        key.width = 84
        key.minWidth = 84
        table.columnAutoresizingStyle = .firstColumnOnlyAutoresizingStyle
        table.addTableColumn(title)
        table.addTableColumn(key)
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        table.setAccessibilityLabel(loc("Commands"))
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let stack = NSStackView(views: [field, scroll])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 28, left: 14, bottom: 14, right: 14)
        panel.contentView = stack
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// Menu commands the palette leaves out: hiding and quitting the app and clearing the recent list are no search's goal.
    private static let skipped: Set<Selector> = [#selector(NSApplication.hide(_:)), #selector(NSApplication.hideOtherApplications(_:)),
                                                 #selector(NSApplication.unhideAllApplications(_:)), #selector(NSApplication.terminate(_:)),
                                                 #selector(NSDocumentController.clearRecentDocuments(_:))]

    /// Every menu item that can run now for `window`, in menu order.
    static func collect(for window: NSWindow?) -> [Entry] {
        var entries: [Entry] = []
        let chain = responders(window)
        let english = englishTitles()
        func walk(_ menu: NSMenu, _ path: [String]) {
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let sub = item.submenu {
                    if sub === NSApp.servicesMenu { continue }
                    walk(sub, path + [item.title])
                } else if let action = item.action, action != #selector(NSWindow.makeKeyAndOrderFront(_:)), !skipped.contains(action),
                          action != #selector(AppDelegate.showCommandPalette(_:)), let handler = handler(item, action, chain) {
                    var entry = Entry(title: item.title, path: path.joined(separator: " › "), shortcut: shortcut(item), item: item, handler: handler)
                    if !english.isEmpty {
                        entry.english = ([item.title] + path).compactMap { english[$0] }.joined(separator: " ")
                    }
                    entries.append(entry)
                }
            }
        }
        guard let main = NSApp.mainMenu else { return [] }
        // The document's menus first, the app menu last (its About and Check for Updates opened the list).
        for top in Array(main.items.dropFirst()) + Array(main.items.prefix(1)) {
            guard let menu = top.submenu else { continue }
            walk(menu, [top.title])
        }
        return entries
    }

    /// Shown text → its English, from the interface's table (empty in English): the menus' titles come from `loc`, so a
    /// title in the table's language finds the English it was asked for by. A key's " [context]" is left out.
    static func englishTitles() -> [String: String] {
        guard let table = CoreLanguage.table else { return [:] }
        var english: [String: String] = [:]
        for (key, shown) in table.sentences where !shown.isEmpty && shown != key {
            var plain = key
            if key.hasSuffix("]"), let open = key.range(of: " [", options: .backwards) { plain = String(key[..<open.lowerBound]) }
            english[shown] = english[shown].map { $0 + " " + plain } ?? plain
        }
        return english
    }

    /// The responder chain as AppKit walks it for a menu command aimed at `window`.
    static func responders(_ window: NSWindow?) -> [AnyObject] {
        var chain: [AnyObject] = []
        var responder: NSResponder? = window?.firstResponder
        while let r = responder {
            chain.append(r)
            responder = r.nextResponder
        }
        if let window {
            if !chain.contains(where: { $0 === window }) { chain.append(window) }
            if let delegate = window.delegate { chain.append(delegate) }
            if let controller = window.windowController {
                chain.append(controller)
                if let document = controller.document { chain.append(document as AnyObject) }
            }
        }
        chain.append(NSApp)
        if let delegate = NSApp.delegate { chain.append(delegate) }
        chain.append(NSDocumentController.shared)
        return chain
    }

    /// What would handle `item` (its own target, else the first in the chain that responds), if it says the command can
    /// run now.
    static func handler(_ item: NSMenuItem, _ action: Selector, _ chain: [AnyObject]) -> AnyObject? {
        let candidates: [AnyObject] = item.target.map { [$0] } ?? chain
        guard let found = candidates.first(where: { $0.responds(to: action) }) else { return nil }
        if let v = found as? NSMenuItemValidation { return v.validateMenuItem(item) ? found : nil }
        if let v = found as? NSUserInterfaceValidations { return v.validateUserInterfaceItem(item) ? found : nil }
        return found
    }

    /// "⇧⌘K", "⌥⌘↓", or a single key ("T") for the tools.
    static func shortcut(_ item: NSMenuItem) -> String {
        let key = item.keyEquivalent
        guard !key.isEmpty else { return "" }
        let m = item.keyEquivalentModifierMask
        var text = ""
        if m.contains(.control) { text += "⌃" }
        if m.contains(.option) { text += "⌥" }
        if m.contains(.shift) || (key.uppercased() == key && key.lowercased() != key) { text += "⇧" }
        if m.contains(.command) { text += "⌘" }
        let names: [Int: String] = [NSUpArrowFunctionKey: "↑", NSDownArrowFunctionKey: "↓", NSLeftArrowFunctionKey: "←", NSRightArrowFunctionKey: "→",
                                    NSHomeFunctionKey: "↖", NSEndFunctionKey: "↘", NSBackspaceCharacter: "⌫", NSDeleteCharacter: "⌫"]
        if let scalar = key.unicodeScalars.first, let name = names[Int(scalar.value)] { return text + name }
        return text + key.uppercased()
    }

    /// The commands whose title or menus hold every word of `query`, each at the start of one of their words, in the
    /// interface's language or in English (titles starting with it first): "zoom in" finds Zoom In, not Zoom to Page
    /// through the "in" inside "página".
    func filter(_ query: String) {
        let words = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let matching = all.filter { e in
            let shown = e.title + " " + e.path
            let text = e.english.isEmpty ? shown : shown + " " + e.english
            return words.allSatisfy { Self.startsAWord($0, in: text, options) }
        }
        if let first = words.first {
            let anchored = options.union(.anchored)
            let starts = matching.filter { $0.title.range(of: first, options: anchored) != nil || $0.english.range(of: first, options: anchored) != nil }
            shown = starts + matching.filter { e in !starts.contains { $0.item === e.item } }
        } else {
            shown = matching
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
    }

    /// Whether `word` is found in `text` where a word starts (after a space, a bracket, a slash or the like).
    static func startsAWord(_ word: String, in text: String, _ options: String.CompareOptions) -> Bool {
        var from = text.startIndex
        while let r = text.range(of: word, options: options, range: from..<text.endIndex) {
            if r.lowerBound == text.startIndex { return true }
            let before = text[text.index(before: r.lowerBound)]
            if !before.isLetter && !before.isNumber { return true }
            from = text.index(after: r.lowerBound)
        }
        return false
    }

    func controlTextDidChange(_ obj: Notification) { filter(field.stringValue) }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): runSelected()
        case #selector(NSResponder.cancelOperation(_:)): close()
        default: return false
        }
        return true
    }

    private func move(_ by: Int) {
        guard !shown.isEmpty else { return }
        let row = min(max(table.selectedRow + by, 0), shown.count - 1)
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.scrollRowToVisible(row)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { shown.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let e = shown[row]
        if tableColumn?.identifier.rawValue == "key" {
            let label = NSTextField(labelWithString: e.shortcut)
            label.textColor = .secondaryLabelColor
            label.alignment = .right
            return label
        }
        let title = NSTextField(labelWithString: e.title)
        let path = NSTextField(labelWithString: e.path)
        path.font = .systemFont(ofSize: 10)
        path.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [title, path])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.setAccessibilityElement(true)
        stack.setAccessibilityLabel(e.shortcut.isEmpty ? "\(e.title), \(e.path)" : "\(e.title), \(e.path), \(e.shortcut)") // English: no words of its own
        return stack
    }

    /// Runs the command selected: the palette closes, the window it was opened over comes back in front, and the menu
    /// item's action goes to it as if chosen in the menu bar.
    @objc func runSelected() {
        let row = table.selectedRow
        guard row >= 0, row < shown.count else { return NSSound.beep() }
        let entry = shown[row]
        close()
        target?.makeKeyAndOrderFront(nil)
        lastRun = entry.title
        let item = entry.item, handler = entry.handler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                guard let action = item.action else { return }
                NSApp.sendAction(action, to: handler, from: item)
            }
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        if window?.isVisible == true && !Report.isRunning { close() }
    }
}
