import AppKit
import PdfCore

/// The self-test's scenario for the menu bar (`--edit`, on the synthetic text document; `--only-menus` runs it alone):
/// the whole menu bar listed as built (each item's title, key and modifiers, action, tag, tooltip, picture, state, and
/// whether the window in front would run it now), for the document as opened and again with all its text selected, then
/// the command palette's list for the window. The `MENU`, `MENU-B` and `PALETTE` lines are what a change to the menus is
/// diffed by (the document command table's refactor was checked so: the same lines before and after, but for the Window
/// menu's checkmark, which follows the window AppKit put in front). Then each command of the table is checked to have a
/// method that runs it and an item in the menu bar.
@MainActor
struct MenuTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    /// A key equivalent as text: printable keys as they are, the others (arrows, Home, Delete) as their code.
    static func key(_ s: String) -> String {
        s.unicodeScalars.map { $0.value < 0x21 || $0.value > 0x7E ? String(format: "U+%04X", $0.value) : String($0) }.joined()
    }

    /// One line per item of the menu bar, submenus indented, separators as "—".
    func dump(_ prefix: String) -> [String] {
        guard let main = NSApp.mainMenu else { return ["\(prefix) no menu bar"] }
        let chain = CommandPalette.responders(controller.window)
        var out: [String] = []
        func list(_ menu: NSMenu, _ indent: String) {
            out.append("\(prefix) \(indent)[\(menu.title)] \(type(of: menu))")
            for item in menu.items {
                if item.isSeparatorItem { out.append("\(prefix) \(indent)  —"); continue }
                var enabled = "-"
                if let action = item.action {
                    let candidates: [AnyObject] = item.target.map { [$0] } ?? chain
                    if let found = candidates.first(where: { $0.responds(to: action) }) {
                        let ok: Bool
                        if let v = found as? NSMenuItemValidation { ok = v.validateMenuItem(item) }
                        else if let v = found as? NSUserInterfaceValidations { ok = v.validateUserInterfaceItem(item) }
                        else { ok = true }
                        enabled = ok ? "on" : "off"
                    } else {
                        enabled = "none"
                    }
                }
                var fields = ["\"\(item.title)\""]
                fields.append("key=\(Self.key(item.keyEquivalent))")
                fields.append("mods=\(item.keyEquivalentModifierMask.rawValue)")
                fields.append("action=\(item.action.map { NSStringFromSelector($0) } ?? "nil")")
                if item.target != nil { fields.append("target=\(type(of: item.target!))") }
                if item.tag != 0 { fields.append("tag=\(item.tag)") }
                if let tip = item.toolTip { fields.append("tip=\"\(tip)\"") }
                if item.image != nil { fields.append("image") }
                if item.isHidden { fields.append("hidden") }
                fields.append("state=\(item.state.rawValue)")
                fields.append("enabled=\(enabled)")
                out.append("\(prefix) \(indent)  " + fields.joined(separator: " "))
                if let sub = item.submenu { list(sub, indent + "    ") }
            }
        }
        list(main, "")
        return out
    }

    mutating func run() async {
        lines.append("== \(name): the menu bar and the command palette (\(controller.engine.pageCount) pages)")
        controller.pages.tool = .hand
        controller.pages.clearSelection()
        controller.go(0)
        let opened = dump("MENU")
        lines += opened
        controller.pages.selectAll(nil)
        let selected = dump("MENU-B")
        lines += selected
        controller.pages.clearSelection()
        let palette = CommandPalette.collect(for: controller.window)
        for e in palette { lines.append("PALETTE \"\(e.title)\" | \(e.path) | \(e.shortcut)") }
        check(opened.count > 150 && selected.count == opened.count, "the menu bar listed: \(opened.count) lines, the same with text selected")
        check(palette.count > 100, "the command palette offers \(palette.count) commands for the document")
        // The table names actions as text: each must be a method something in the responder chain has (a typo would
        // leave its item off for good).
        let handlers: [AnyClass] = [DocumentWindowController.self, AppDelegate.self, PdfDocument.self, DocumentController.self, NSWindow.self,
                                    NSApplication.self, NSTextView.self, NSSplitViewController.self, PagesView.self]
        let missing = DocumentCommands.all.map(\.command.action).filter { action in
            !handlers.contains { $0.instancesRespond(to: NSSelectorFromString(action)) }
        }
        check(missing.isEmpty, "each of the table's \(DocumentCommands.all.count) commands has a method that runs it\(missing.isEmpty ? "" : ": not \(missing.joined(separator: ", "))")")
        var inMenus: Set<String> = []
        func collect(_ menu: NSMenu?) {
            for item in menu?.items ?? [] {
                if let action = item.action { inMenus.insert(NSStringFromSelector(action)) }
                collect(item.submenu)
            }
        }
        collect(NSApp.mainMenu)
        let absent = DocumentCommands.all.map(\.command.action).filter { !inMenus.contains($0) }
        check(absent.isEmpty, "each command of the table is in the menu bar\(absent.isEmpty ? "" : ": not \(absent.joined(separator: ", "))")")
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
