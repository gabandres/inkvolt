import AppKit
import PdfCore
import PrintCore

/// Help › Keyboard Shortcuts (Windows' `ShortcutsWindow`): every command with keys, read from the menu bar as it is
/// (the tools' single keys included), under its menu's name, then PdfCore's fixed rows; a filter box at the top, Esc
/// closes.
@MainActor
final class ShortcutsWindowController: NSWindowController, NSSearchFieldDelegate {
    static var shared: ShortcutsWindowController?

    let filter = NSSearchField()
    private let list = NSStackView()
    private(set) var rows: [ShortcutRow] = []
    /// What the list shows now (the self-test reads it).
    private(set) var shown: [ShortcutRow] = []

    static func show() {
        let controller = shared ?? ShortcutsWindowController()
        shared = controller
        controller.rows = rows(NSApp.mainMenu)
        controller.filter.stringValue = ""
        controller.fill()
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.filter)
    }

    /// The menu bar's rows (Windows' `Walk` over its menus), the app menu's and the Services' left out, then the fixed ones.
    static func rows(_ menu: NSMenu?) -> [ShortcutRow] {
        func node(_ item: NSMenuItem) -> MenuNode? {
            if item.isSeparatorItem || item.isHidden || item.isAlternate { return nil }
            if let sub = item.submenu { return MenuNode(item.title, sub.items.compactMap(node)) }
            return MenuNode(item.title, keys: CommandPalette.shortcut(item))
        }
        let top = (menu?.items ?? []).dropFirst().compactMap { $0.submenu.map { MenuNode($0.title, $0.items.compactMap(node)) } }
        return ShortcutList.rows(top) + ShortcutList.fixedRows
    }

    init() {
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 600), styleMask: [.titled, .closable, .resizable, .utilityWindow],
                             backing: .buffered, defer: false)
        window.title = loc("Keyboard shortcuts")
        window.minSize = NSSize(width: 420, height: 300)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        filter.placeholderString = loc("Type to filter: zoom, rotate, ⇧⌘…")
        filter.setAccessibleName(loc("Filter shortcuts"))
        filter.delegate = self
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 6
        list.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 20, right: 20)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        list.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(list)
        scroll.documentView = flipped
        NSLayoutConstraint.activate([
            list.topAnchor.constraint(equalTo: flipped.topAnchor), list.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: flipped.trailingAnchor), list.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
            flipped.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        let root = NSStackView(views: [filter, scroll])
        root.orientation = .vertical
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 0, right: 20)
        window.contentView = root
        window.center()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    func controlTextDidChange(_ obj: Notification) { fill() }

    /// Esc in the filter closes the window, as Windows'.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        if filter.stringValue.isEmpty { close() } else { filter.stringValue = ""; fill() }
        return true
    }

    private func fill() {
        shown = ShortcutList.filter(rows, filter.stringValue)
        for view in list.arrangedSubviews { view.removeFromSuperview() }
        for group in ShortcutList.grouped(shown) {
            let heading = NSTextField(labelWithString: group.group)
            heading.font = .systemFont(ofSize: 15, weight: .semibold)
            heading.setAccessibilityRole(.staticText)
            list.addArrangedSubview(heading)
            list.setCustomSpacing(8, after: heading)
            for row in group.rows {
                let name = NSTextField(labelWithString: row.name)
                let keys = NSTextField(labelWithString: row.keys)
                keys.font = .systemFont(ofSize: 12)
                keys.textColor = .secondaryLabelColor
                keys.alignment = .right
                keys.setContentHuggingPriority(.required, for: .horizontal)
                let line = NSStackView(views: [name, keys])
                line.distribution = .fill
                line.setAccessibilityElement(true)
                line.setAccessibilityLabel("\(row.name), \(row.keys)")
                list.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: list.widthAnchor, constant: -40).isActive = true
            }
        }
    }
}
