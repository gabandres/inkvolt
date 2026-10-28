import AppKit

/// Tools › Command Palette… (⇧⌘K; the Windows app's Ctrl+K, which on the Mac is Link Selected Text, and its Ctrl+Shift+P,
/// which is Page Setup): every menu command that can run now, searched as you type (every word, in any order, in the
/// command or its menu), run with Return or a double-click. The commands are the menu bar's own items, each checked and
/// sent along the responder chain of the window that was in front (its first responder, the window, its controller and
/// document, then the app and its delegate), so the palette offers and does what the menus would for that window.
@MainActor
final class CommandPalette: NSWindowController, NSSearchFieldDelegate, NSTableViewDataSource, NSTableViewDelegate, NSWindowDelegate {
    static var shared: CommandPalette?

    /// A command: its title, the menus it's in, its shortcut, the menu item, and what handles it.
    struct Entry {
        let title: String
        let path: String
        let shortcut: String
        let item: NSMenuItem
        let handler: AnyObject
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
        panel.title = "Command Palette"
        super.init(window: panel)
        panel.delegate = self
        field.placeholderString = "Search all commands"
        field.delegate = self
        field.font = .systemFont(ofSize: 16)
        field.setAccessibilityLabel("Search all commands")
        let title = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        title.width = 400
        let key = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        key.width = 110
        table.addTableColumn(title)
        table.addTableColumn(key)
        table.headerView = nil
        table.rowHeight = 34
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(runSelected)
        table.setAccessibilityLabel("Commands")
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

    /// Every menu item that can run now for `window`, in menu order.
    static func collect(for window: NSWindow?) -> [Entry] {
        var entries: [Entry] = []
        let chain = responders(window)
        func walk(_ menu: NSMenu, _ path: [String]) {
            for item in menu.items where !item.isSeparatorItem && !item.isHidden {
                if let sub = item.submenu {
                    if sub === NSApp.servicesMenu { continue }
                    walk(sub, path + [item.title])
                } else if let action = item.action, action != #selector(NSWindow.makeKeyAndOrderFront(_:)),
                          action != #selector(AppDelegate.showCommandPalette(_:)), let handler = handler(item, action, chain) {
                    entries.append(Entry(title: item.title, path: path.joined(separator: " › "), shortcut: shortcut(item), item: item, handler: handler))
                }
            }
        }
        guard let main = NSApp.mainMenu else { return [] }
        for top in main.items {
            guard let menu = top.submenu else { continue }
            walk(menu, [top.title])
        }
        return entries
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

    /// The commands whose title or menus hold every word of `query` (titles starting with it first).
    func filter(_ query: String) {
        let words = query.split(separator: " ").map(String.init).filter { !$0.isEmpty }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        let matching = all.filter { e in
            let text = e.title + " " + e.path
            return words.allSatisfy { text.range(of: $0, options: options) != nil }
        }
        if let first = words.first {
            let starts = matching.filter { $0.title.range(of: first, options: options.union(.anchored)) != nil }
            shown = starts + matching.filter { e in !starts.contains { $0.item === e.item } }
        } else {
            shown = matching
        }
        table.reloadData()
        if !shown.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
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
        stack.setAccessibilityLabel("\(e.title), \(e.path)\(e.shortcut.isEmpty ? "" : ", " + e.shortcut)")
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
