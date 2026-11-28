import Foundation
import Testing
@testable import PrintCore

/// The command palette's matching (PaletteSearch) and Inkvolt Print's list (PrintPalette). Ported from PaletteTests.cs.
/// Adapted: the Mac's tabs (Status, Scan, Printer settings), Set up in macOS, ⌘ shortcuts, SF Symbols (an icon is a symbol
/// name: the report checks each draws), no What's new; `Target` compares objects. Not ported: NavPane's fold (the Windows
/// sidebar; the Mac's split view collapses its own).
struct PaletteTests {
    private static let mfp = PrintPalette.Printer("HP LaserJet MFP M234dw", canPrint: true, canScan: true, canCopy: true, hasSettings: true,
                                                  needsSetup: false, canFix: true, isNetwork: true)

    private static func build(_ selected: PrintPalette.Printer? = nil, _ index: Int = 0) -> [PrintPalette.Entry] {
        PrintPalette.build(selected, selected == nil ? -1 : index, ["HP LaserJet MFP M234dw", "Demo inkjet", "Front desk"], ["Document to PDF", "Photo", "Receipt"])
    }

    private final class Named {
        let name: String
        init(_ name: String) { self.name = name }
    }

    @Test func AnEntryKeepsMeaningThePrinterItNamed_WhenTheListMoves() {
        let a = Named("A"), b = Named("B"), c = Named("C")
        let built = [a, b, c]
        #expect(PrintPalette.target(1, built, [a, b, c]) === b)
        #expect(PrintPalette.target(1, built, [c, a, b]) === b) // a new one sorted in, or the order changed
        #expect(PrintPalette.target(1, built, [a, c]) == nil) // removed meanwhile: nothing runs, not the next one's command
        #expect(PrintPalette.target(3, built, [a, b, c]) == nil)
        #expect(PrintPalette.target(-1, built, [a, b, c]) == nil)
    }

    // MARK: The list

    @Test func EveryCommandOfTheSidebarHeaderTabsAndMenuIsListed() {
        let names = Self.build(Self.mfp).map(\.name)
        // Sidebar and the app's menus
        #expect(names.contains("Add a printer…"))
        #expect(names.contains("Settings"))
        #expect(names.contains("Help and shortcuts"))
        #expect(names.contains("About Inkvolt Print"))
        #expect(names.contains("Search again for printers"))
        // The printer's toolbar and tabs
        #expect(names.contains("Print a PDF…"))
        #expect(names.contains("Scan"))
        #expect(names.filter { $0.hasPrefix("Go to ") } == ["Go to Status", "Go to Scan", "Go to Printer settings"])
        // Its menu
        #expect(names.contains("Reconnect"))
        #expect(names.contains("Print photos…"))
        #expect(names.contains("Fix printing problems…"))
        #expect(names.contains("Printer maintenance…"))
        #expect(names.contains("Remove from Inkvolt Print…"))
        #expect(names.count == Set(Self.build(Self.mfp).map(\.id)).count)
    }

    @Test func OnlyWhatThePrinterOffers() {
        let scannerOnly = PrintPalette.Printer("Photo Scanner", canPrint: false, canScan: true, canCopy: false, hasSettings: false,
                                               needsSetup: false, canFix: false, isNetwork: false)
        let names = Self.build(scannerOnly).map(\.name)
        #expect(!names.contains("Print a PDF…"))
        #expect(!names.contains("Print photos…"))
        #expect(!names.contains("Fix printing problems…"))
        #expect(names.filter { $0.hasPrefix("Go to ") } == ["Go to Status", "Go to Scan"])
        var needsSetup = Self.mfp
        needsSetup.needsSetup = true
        #expect(Self.build(needsSetup).contains { $0.name == "Set up in macOS" })
    }

    @Test func TheOtherPrintersAndTheScanPresetsWithTheirShortcuts() {
        let list = Self.build(Self.mfp)
        #expect(list.filter { $0.category == "Printers" }.map(\.name) == ["Show Demo inkjet", "Show Front desk"])
        #expect(list.filter { $0.category == "Printers" }.map(\.id) == ["show:1", "show:2"])
        let presets = list.filter { $0.category == "Scan presets" }
        #expect(presets.map(\.name) == ["Scan with Document to PDF", "Scan with Photo", "Scan with Receipt"])
        #expect(presets.map(\.gesture) == ["⌘1", "⌘2", "⌘3"])
        // A printer that can't scan has no presets to run.
        var noScan = Self.mfp
        noScan.canScan = false
        #expect(!Self.build(noScan).contains { $0.category == "Scan presets" })
    }

    @Test func WithoutAPrinterTheAppCommandsAndEveryPrinter() {
        let list = Self.build()
        #expect(!list.contains { $0.id.hasPrefix("printer:") || $0.id.hasPrefix("section:") || $0.id.hasPrefix("preset:") })
        #expect(list.filter { $0.category == "Printers" }.count == 3)
        #expect(list.contains { $0.id == "app:add" })
    }

    // MARK: Another printer's menu, without showing it first

    private static let inkjet = PrintPalette.Printer("Demo inkjet", canPrint: true, canScan: true, canCopy: true, hasSettings: false,
                                                     needsSetup: false, canFix: true, isNetwork: true, snmpAccess: false)
    private static let frontDesk = PrintPalette.Printer("Front desk", canPrint: true, canScan: false, canCopy: false, hasSettings: false,
                                                        needsSetup: false, canFix: true, isNetwork: false)

    private static func buildAll(_ selected: Int = 0) -> [PrintPalette.Entry] {
        let all = [mfp, inkjet, frontDesk]
        return PrintPalette.build(selected < 0 ? nil : all[selected], selected, ["HP LaserJet MFP M234dw", "Demo inkjet", "Front desk"],
                                  ["Document to PDF"], every: all)
    }

    @Test func Another_printers_menu_commands_are_entries_of_their_own() {
        let other = Self.buildAll().filter { $0.id.hasPrefix("on:") }
        #expect(other.map(\.name) == [
            "Demo inkjet: Reconnect", "Demo inkjet: Print photos…", "Demo inkjet: Batch print: many files…", "Demo inkjet: Fix printing problems…",
            "Demo inkjet: Printer maintenance…", "Demo inkjet: Remove from Inkvolt Print…",
            "Front desk: Reconnect", "Front desk: Print photos…", "Front desk: Batch print: many files…", "Front desk: Fix printing problems…",
            "Front desk: Remove from Inkvolt Print…",
        ])
        #expect(other.prefix(6).map(\.id) == ["on:1:reconnect", "on:1:photos", "on:1:batch", "on:1:fix", "on:1:maintenance", "on:1:remove"])
        #expect(other.allSatisfy { $0.category == "Other printers" })
        #expect(!other.contains { $0.name.hasPrefix("HP LaserJet") }) // the selected printer's are its plain entries
        // The same commands as the selected printer's menu, and what the printer offers only.
        let inkjetMenu = Self.buildAll(1).filter { $0.id.hasPrefix("printer:") && $0.category == "Demo inkjet" && PrintPalette.menuIds.contains(String($0.id.dropFirst(8))) }
        #expect(inkjetMenu.map(\.name) == other.prefix(6).map { String($0.name.dropFirst("Demo inkjet: ".count)) })
        let ids = Self.buildAll().filter { $0.id.hasPrefix("on:") }.map(\.id)
        #expect(ids.count == Set(ids).count)
    }

    @Test func They_wait_for_a_word_so_the_list_stays_short() throws {
        let all = Self.buildAll()
        let empty = PaletteSearch.filter(all, "", name: \.name, category: \.category, showWhenEmpty: PrintPalette.shownWhenEmpty)
        #expect(!empty.contains { $0.id.hasPrefix("on:") })
        #expect(empty.count == all.filter { !$0.id.hasPrefix("on:") }.count)

        let fix = PaletteSearch.filter(all, "front fix", name: \.name, category: \.category, showWhenEmpty: PrintPalette.shownWhenEmpty)
        #expect(fix.map(\.id) == ["on:2:fix"])
        let inkjet = PaletteSearch.filter(all, "inkjet maint", name: \.name, category: \.category, showWhenEmpty: PrintPalette.shownWhenEmpty)
        #expect(inkjet.map(\.id) == ["on:1:maintenance"])
    }

    @Test func An_entry_for_another_printer_names_which_and_what() {
        #expect(PrintPalette.onOther("on:1:fix").map { "\($0.index) \($0.command)" } == "1 fix")
        #expect(PrintPalette.onOther("printer:fix") == nil)
        #expect(PrintPalette.onOther("on:x:fix") == nil)
        #expect(PrintPalette.onOther("on:1:") == nil)
        // Mac only: the numbered ids read back the same way, hostile ones as nothing.
        #expect(PrintPalette.number("preset:4", after: "preset:") == 4)
        #expect(PrintPalette.number("preset:-1", after: "preset:") == nil)
        #expect(PrintPalette.number("show:", after: "show:") == nil)
        #expect(PrintPalette.number("section:99999999999999999999", after: "section:") == nil)
    }

    @Test func Without_the_printers_details_only_Show_entries_as_before() {
        #expect(!Self.build(Self.mfp).contains { $0.id.hasPrefix("on:") })
    }

    @Test func EveryEntryHasAnIcon() {
        for e in Self.buildAll() { #expect(!e.glyph.isEmpty && !e.glyph.contains(" "), "\(e.name)") }
    }

    @Test func NothingMatchesSaysWhatToTry() {
        #expect(PrintPalette.noMatch(" zzz ") == "Nothing matches “zzz”. Try another word, a printer's name or a scan preset.")
        #expect(PrintPalette.noMatch(String(repeating: "x", count: 80)).contains(String(repeating: "x", count: 40) + "…"))
    }

    // MARK: Matching

    @Test func ANameStartingWithTheWordRanksFirst() {
        let result = PaletteSearch.filter(Self.build(Self.mfp), "scan", name: \.name, category: \.category)
        #expect(result.first?.name == "Scan")
        #expect(result.contains { $0.name == "Go to Scan" })
        #expect(result.contains { $0.name == "Scan with Photo" })
        #expect(!result.contains { $0.name == "Settings" })
    }

    @Test func EveryWordMustMatchInTheNameOrCategory() {
        let result = PaletteSearch.filter(Self.build(Self.mfp), "presets receipt", name: \.name, category: \.category)
        #expect(result.map(\.name) == ["Scan with Receipt"])
        #expect(PaletteSearch.filter(Self.build(Self.mfp), "scan zebra", name: \.name, category: \.category).isEmpty)
    }

    @Test func NothingTypedListsTheFirstOnesShownWhenEmpty() {
        let items = ["Open", "recent.pdf", "Save"]
        #expect(PaletteSearch.filter(items, "  ", name: { $0 }, category: { _ in "" }, showWhenEmpty: { !$0.hasSuffix(".pdf") }) == ["Open", "Save"])
        #expect(PaletteSearch.filter(items, "", name: { $0 }, category: { _ in "" }, max: 1) == ["Open"])
    }

    @Test func ACommandOutranksAFileOnATie() {
        let items = ["report.pdf", "Report a problem"]
        let result = PaletteSearch.filter(items, "report", name: { $0 }, category: { _ in "" }, isCommand: { !$0.hasSuffix(".pdf") })
        #expect(result.first == "Report a problem")
    }

    @Test func ScoresStartOfNameOverStartOfWordOverInside() {
        #expect(PaletteSearch.score("Scan", "", ["sc"]) > PaletteSearch.score("Go to Scan", "", ["sc"]))
        #expect(PaletteSearch.score("Go to Scan", "", ["sc"]) > PaletteSearch.score("Rescan", "", ["sc"]))
        #expect(PaletteSearch.score("Scan", "", ["print"]) == 0)
    }
}
