import Foundation
import PrintCore

/// One line of Help › Keyboard Shortcuts: the group it's under, the command, its keys.
public struct ShortcutRow: Sendable, Equatable {
    public let group: String
    public let name: String
    public let keys: String

    public init(_ group: String, _ name: String, _ keys: String) {
        self.group = group
        self.name = name
        self.keys = keys
    }
}

/// A menu item as the shortcuts list reads it: its title, its keys as shown ("⌥⌘W", "" for none) and its submenu.
public struct MenuNode: Sendable {
    public let title: String
    public let keys: String
    public let children: [MenuNode]

    public init(_ title: String, keys: String = "", _ children: [MenuNode] = []) {
        self.title = title
        self.keys = keys
        self.children = children
    }
}

/// Help › Keyboard Shortcuts (Windows' `ShortcutsWindow`): every menu command with keys, read from the menus, under
/// its menu's name, then what the menus can't show (scrolling, zooming, selecting, the selected comment), and a filter.
public enum ShortcutList {
    /// The rows of `menus` (the menu bar's top menus), in menu order: a submenu's commands under their top menu, each
    /// name once (Windows' `Walk`), the title's "…" dropped.
    public static func rows(_ menus: [MenuNode]) -> [ShortcutRow] {
        var rows: [ShortcutRow] = []
        func walk(_ items: [MenuNode], _ group: String) {
            for item in items {
                let name = item.title.hasSuffix("…") ? String(item.title.dropLast()) : item.title
                if !item.children.isEmpty {
                    walk(item.children, group)
                    continue
                }
                if !item.keys.isEmpty && !name.isEmpty && !rows.contains(where: { $0.name == name }) { rows.append(ShortcutRow(group, name, item.keys)) }
            }
        }
        for menu in menus { walk(menu.children, menu.title) }
        return rows
    }

    /// The menu table (`DocumentCommands`) as the shortcuts list reads it, titles in the interface's language.
    public static func menus(_ table: [CommandMenu] = DocumentCommands.menuBar) -> [MenuNode] {
        func node(_ entry: MenuEntry) -> MenuNode? {
            switch entry {
            case .command(let c): MenuNode(c.shownTitle, keys: keyText(c.key, c.modifiers))
            case .submenu(let sub): MenuNode(sub.shownTitle, sub.entries.compactMap(node))
            case .separator, .tools, .checkForUpdates: nil
            }
        }
        return table.map { MenuNode($0.shownTitle, $0.entries.compactMap(node)) }
    }

    /// A key equivalent as macOS's menus show it: ⌃⌥⇧⌘ then the key ("⌥⌘W", "⌘[", "↖"); "" for none.
    public static func keyText(_ key: String, _ modifiers: KeyModifiers) -> String {
        guard !key.isEmpty else { return "" }
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) || (key.uppercased() == key && key.lowercased() != key) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        let names: [String: String] = [SpecialKey.upArrow: "↑", SpecialKey.downArrow: "↓", SpecialKey.home: "↖", SpecialKey.end: "↘",
                                       SpecialKey.backspace: "⌫"]
        return text + (names[key] ?? key.uppercased())
    }

    /// What the menus can't show: the page view's own keys and gestures, and the selected comment's (Windows' fixed
    /// rows, as the Mac has them).
    public static var fixedRows: [ShortcutRow] {
        let reading = loc("Reading"), comments = loc("Drawing"), anywhere = loc("Anywhere")
        return [
            ShortcutRow(reading, loc("Scroll by a screen"), loc("⇞ / ⇟ / Space")),
            ShortcutRow(reading, loc("Zoom at the pointer"), loc("Pinch")),
            ShortcutRow(reading, loc("Select a word / line"), loc("Double-click / triple-click (Select text tool)")),
            ShortcutRow(comments, loc("Back to the Select Text tool"), "Esc"),
            ShortcutRow(comments, loc("Move the selected drawing"), loc("Drag, or arrow keys (Shift: 10 pt)")),
            ShortcutRow(comments, loc("Delete the selected drawing"), "⌫"),
            ShortcutRow(comments, loc("Next / previous comment"), "⇥ / ⇧⇥"),
            ShortcutRow(comments, loc("Open the inspector"), "↩"),
            ShortcutRow(anywhere, loc("Search all commands"), keyText("k", [.command, .shift])),
        ]
    }

    /// The rows whose group, name or keys hold `query` (case and accents ignored); all for an empty one.
    public static func filter(_ rows: [ShortcutRow], _ query: String) -> [ShortcutRow] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty { return rows }
        return rows.filter { "\($0.group) \($0.name) \($0.keys)".range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// The rows by group, in the order the groups first come.
    public static func grouped(_ rows: [ShortcutRow]) -> [(group: String, rows: [ShortcutRow])] {
        var out: [(group: String, rows: [ShortcutRow])] = []
        for row in rows {
            if let i = out.firstIndex(where: { $0.group == row.group }) { out[i].rows.append(row) } else { out.append((row.group, [row])) }
        }
        return out
    }
}
