import Testing
@testable import PdfCore

/// Help › Keyboard Shortcuts (Windows' `ShortcutsWindow`, app code without tests there): the rows read from the menus,
/// the fixed rows, the filter. Mac additions.
struct ShortcutListTests {
    @Test func theRowsComeFromTheMenusUnderTheirTopMenu() {
        let menus = [
            MenuNode("File", [MenuNode("Open…", keys: "⌘O"), MenuNode("Export To", [MenuNode("Word…", keys: "⌥⌘E")]), MenuNode("Share…")]),
            MenuNode("View", [MenuNode("Zoom In", keys: "⌘+"), MenuNode("Open…", keys: "⌘K")]),
        ]
        #expect(ShortcutList.rows(menus) == [
            ShortcutRow("File", "Open", "⌘O"), ShortcutRow("File", "Word", "⌥⌘E"), ShortcutRow("View", "Zoom In", "⌘+"),
        ]) // Share has no keys; the second Open is the same name
    }

    @Test func keysAreShownAsTheMenusShowThem() {
        #expect(ShortcutList.keyText("w", [.command, .option]) == "⌥⌘W")
        #expect(ShortcutList.keyText("[", .command) == "⌘[")
        #expect(ShortcutList.keyText("s", [.command, .control]) == "⌃⌘S")
        #expect(ShortcutList.keyText("k", [.command, .shift]) == "⇧⌘K")
        #expect(ShortcutList.keyText(SpecialKey.home, []) == "↖")
        #expect(ShortcutList.keyText(SpecialKey.downArrow, [.command, .option]) == "⌥⌘↓")
        #expect(ShortcutList.keyText("", .command) == "")
    }

    @Test func theMenuTableGivesEveryCommandWithKeysARow() {
        let rows = ShortcutList.rows(ShortcutList.menus())
        let keyed = Set(DocumentCommands.all.filter { !$0.command.key.isEmpty }.map { $0.command.shownTitle.replacingOccurrences(of: "…", with: "") })
        #expect(Set(rows.map(\.name)) == keyed)
        #expect(rows.contains(ShortcutRow("File", "Close All", "⌥⌘W")))
        #expect(rows.contains(ShortcutRow("Go", "Previous View", "⌘[")))
        #expect(rows.contains { $0.group == "Edit" && $0.name == "Find" }) // Edit › Find › Find… under Edit
    }

    @Test func theFixedRowsSayWhatTheMenusCant() {
        let groups = ShortcutList.grouped(ShortcutList.fixedRows).map(\.group)
        #expect(groups == ["Reading", "Drawing", "Anywhere"])
        #expect(ShortcutList.fixedRows.last == ShortcutRow("Anywhere", "Search all commands", "⇧⌘K"))
    }

    @Test func theFilterMatchesTheGroupTheNameOrTheKeys() {
        let rows = [ShortcutRow("File", "Close All", "⌥⌘W"), ShortcutRow("View", "Zoom In", "⌘+"), ShortcutRow("Lectura", "Selección", "⌘A")]
        #expect(ShortcutList.filter(rows, "zoom").map(\.name) == ["Zoom In"])
        #expect(ShortcutList.filter(rows, "file").map(\.name) == ["Close All"])
        #expect(ShortcutList.filter(rows, "⌥⌘").map(\.name) == ["Close All"])
        #expect(ShortcutList.filter(rows, "SELECCION").map(\.name) == ["Selección"])
        #expect(ShortcutList.filter(rows, "  ").count == 3)
    }
}
