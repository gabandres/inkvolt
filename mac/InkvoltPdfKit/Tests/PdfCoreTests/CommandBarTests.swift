import Foundation
import Testing
@testable import PdfCore
import PrintCore

/// Windows' `CommandBarLayoutTests` (the table) and `BarColorsTests`, for the Mac's toolbar groups. The fitting tests
/// have no Mac port: the toolbar's own overflow (») places the items by `visibilityPriority`, tested here instead.
struct CommandBarTests {
    private var groups: [CommandBar.Group] { CommandBar.groups }
    private var items: [CommandBar.Item] { groups.flatMap(\.items) }

    // ── The table ──

    @Test func TheGroupsComeInTheOrderOtherPdfEditorsUse() {
        // docs/design/command-bar.md: the pointer tools, Edit and Convert first, then Comment and Fill & Sign, the pages,
        // Protect (with Redact), Scan & OCR.
        #expect(groups.map(\.id) == ["Pointer", "Edit", "Convert", "Comment", "FillSign", "Organize", "Protect", "ScanOcr"])
        #expect(groups.map(\.label) == ["Select", "Edit", "Convert", "Comment", "Fill & Sign", "Organize", "Protect", "Scan & OCR"])
        #expect(groups.allSatisfy { $0.items.count > 1 })
        #expect(items.allSatisfy { !$0.symbol.isEmpty } && groups.allSatisfy { !$0.symbol.isEmpty })
    }

    @Test func EachGroupLeadsWithItsMainJob() {
        let split = groups.filter(\.hasMainJob)
        #expect(split.map(\.id) == ["Edit", "Convert", "Comment", "FillSign", "Organize", "Protect", "ScanOcr"])
        #expect(split.map(\.main.id) == ["EditContent", "ExportWord", "Highlight", "AddSignature", "Organize", "ProtectPassword", "RecognizeText"])
        #expect(CommandBar.group(CommandBar.pointer)?.hasMainJob == false)
    }

    @Test func DrawSitsInCommentAndRedactInProtect() {
        #expect(CommandBar.drawsIn == "Comment")
        #expect(CommandBar.group("Protect")?.items.map(\.id).contains("Redact") == true)
        #expect(CommandBar.group("Protect")?.items.first { $0.id == "Redact" }?.atOnce == true)
        #expect(CommandBar.group(CommandBar.pointer)?.items.map(\.id) == ["ToolHand", "ToolSelect", "ToolSnapshot"])
    }

    @Test func OptionMakesACommandAskInsteadOfRunningAtOnce() {
        // The Mac's Shift+click: Option-click (as Finder's and the Dock's alternate actions).
        let word = CommandBar.group("Convert")!.main
        #expect(CommandBar.runsAtOnce(word, option: false))
        #expect(!CommandBar.runsAtOnce(word, option: true))
        #expect(!CommandBar.runsAtOnce(CommandBar.group("Organize")!.main, option: false))
    }

    @Test func FlyoutsAreSplitIntoSectionsByTheTable() {
        #expect(groups.allSatisfy { !$0.items[0].startsSection })
        #expect(groups.filter { $0.items.count > 4 && $0.id != CommandBar.drawsIn }.allSatisfy { $0.items.contains(where: \.startsSection) })
        #expect(CommandBar.group("Protect")?.items.filter(\.startsSection).map(\.id) == ["Redact", "Sign", "RemoveProtection"])
        #expect(CommandBar.group("Convert")?.items.filter(\.startsSection).map(\.id) == ["ExportText", "SaveAsPdfA"])
    }

    @Test func ConvertNamesTheFormatsAndRunsTheEditableOnesAtOnce() {
        // "Word (.docx)", not "Export to Word…"; the editable formats at once (no "…"), PDF/A asks. Windows' Images… has
        // no Mac export yet (mac/docs/PLAN.md).
        let convert = CommandBar.group("Convert")!.items
        #expect(convert.filter(\.atOnce).map(\.id) == ["ExportWord", "ExportExcel", "ExportPowerPoint", "ExportText", "ExportHtml"])
        #expect(convert.allSatisfy { $0.atOnce != $0.title.hasSuffix("…") })
    }

    @Test func EveryBarCommandIsInTheMenusSoThePaletteListsIt() {
        // A command item sends a menu bar command (its enabling is the menu's: `DocumentCommands`); a tool item names a
        // tool the Tools menu picks (the app's `Tool` titles, checked by the self-test).
        for item in items {
            #expect((item.action == nil) != (item.tool == nil), "\(item.id): one command or one tool")
            if let action = item.action { #expect(DocumentCommands.command(action: action) != nil, "\(item.id): \(action) isn't in the menus") }
        }
        #expect(Set(items.map(\.id)).count == items.count)
    }

    @Test func EachCommandOfAGroupSaysInALineWhatItDoes() {
        for item in items {
            #expect((12...50).contains(item.note.count), "\(item.id): \(item.note)")
            #expect(item.note.first?.isUppercase == true && !item.note.hasSuffix(".") && !item.note.contains("\n"), "\(item.id)")
        }
        #expect(Set(items.map(\.note)).count == items.count)
    }

    // ── Fitting (the toolbar's overflow) ──

    @Test func TheFourCommonGroupsStayOnTheBarLongest() {
        // Edit, Convert, Comment and Fill & Sign keep their places (and labels) while the rest go into » first, lowest
        // priority first: Scan & OCR, Protect, Organize, then the pointer tools.
        let byPlace = groups.sorted { CommandBar.visibilityPriority($0) > CommandBar.visibilityPriority($1) }.map(\.id)
        #expect(byPlace == ["Convert", "FillSign", "Edit", "Comment", "Pointer", "Organize", "Protect", "ScanOcr"])
        #expect(groups.filter(\.isKey).allSatisfy { CommandBar.visibilityPriority($0) > 0 }) // above the window's standard items
        #expect(groups.filter { !$0.isKey }.allSatisfy { CommandBar.visibilityPriority($0) < 0 })
    }

    @Test func InSpanishFillAndSignGoesFirst() {
        // "Llenar y firmar" is the longest label: it goes into » before the other labeled groups (the owner, 2026-11-08).
        #expect(CommandBar.fillSignPriority(language: "es") < CommandBar.keepsLabels)
        #expect(CommandBar.fillSignPriority(language: "en") >= CommandBar.keepsLabels)
    }

    // ── Colours (Windows' BarColorsTests) ──

    @Test func OnlyWordExcelPowerPointPdfAAndApplyRedactionsAreColored() {
        let colored = items.filter { $0.tint != nil }.map(\.id).sorted()
        #expect(colored == ["ApplyRedactions", "ExportExcel", "ExportPowerPoint", "ExportWord", "SaveAsPdfA"])
        #expect(Set(BarColors.all.map(\.tint)) == Set(CommandBar.Tint.allCases))
        #expect(BarColors.all.count == CommandBar.Tint.allCases.count)
    }

    @Test func EachColorHasALightAndADarkVariantWithThreeToOneContrast() {
        for shade in BarColors.all {
            #expect(shade.light != shade.dark)
            for bg in BarColors.lightBackgrounds { #expect(BarColors.contrastRatio(shade.light, bg) >= 3, "\(shade.tint) on \(bg)") }
            for bg in BarColors.darkBackgrounds { #expect(BarColors.contrastRatio(shade.dark, bg) >= 3, "\(shade.tint) dark on \(bg)") }
            #expect(BarColors.color(shade.tint, dark: false, increaseContrast: false) == shade.light)
            #expect(BarColors.color(shade.tint, dark: true, increaseContrast: false) == shade.dark)
        }
        // The owner's exact colours.
        #expect(BarColors.all.map(\.light) == ["#185ABD", "#107C41", "#C43E1C", "#6B6B6B", "#D13438"])
        #expect(BarColors.all.map(\.dark) == ["#4A9EFF", "#2ECC71", "#FF7A50", "#A0A0A0", "#FF6B6B"])
    }

    @Test func ColoredFileTypesAreFilledSoTheColorReads() {
        for item in CommandBar.group("Convert")!.items {
            #expect((item.tint != nil) == (item.symbol == CommandBar.filledDocument), "\(item.id)")
        }
    }

    @Test(arguments: [(CommandBar.Tint.word, 205.0, 225.0), (.excel, 135, 155), (.powerPoint, 8, 20), (.applyRedactions, -5, 5)])
    func EachColorReadsAsItsHueInBothThemes(_ tint: CommandBar.Tint, _ from: Double, _ to: Double) {
        let shade = BarColors.all.first { $0.tint == tint }!
        for hex in [shade.light, shade.dark] {
            var (h, s) = Self.hueSaturation(hex)
            if h > 180 && from < 0 { h -= 360 }
            #expect((from...to).contains(h), "\(tint) \(hex) hue \(h)")
            #expect(s >= 0.6, "\(tint) \(hex) saturation \(s)")
        }
    }

    @Test func UnderIncreaseContrastNoColorIsUsed() {
        for tint in CommandBar.Tint.allCases {
            #expect(BarColors.color(tint, dark: false, increaseContrast: true) == nil)
            #expect(BarColors.color(tint, dark: true, increaseContrast: true) == nil)
        }
    }

    @Test func ContrastIsWcags() {
        #expect(abs(BarColors.contrastRatio("#000000", "#FFFFFF") - 21) < 0.001)
        #expect(abs(BarColors.contrastRatio("#777777", "#777777") - 1) < 0.001)
        #expect(abs(BarColors.contrastRatio("#777777", "#FFFFFF") - 4.48) < 0.01)
        #expect(BarColors.rgb("blue") == nil)
    }

    /// HSL hue (degrees) and saturation of a #RRGGBB colour.
    private static func hueSaturation(_ hex: String) -> (Double, Double) {
        let (r8, g8, b8) = BarColors.rgb(hex)!
        let r = Double(r8) / 255, g = Double(g8) / 255, b = Double(b8) / 255
        let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn, l = (mx + mn) / 2
        let s = d == 0 ? 0 : d / (1 - abs(2 * l - 1))
        var h: Double
        if d == 0 { h = 0 } else if mx == r { h = 60 * ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if mx == g { h = 60 * ((b - r) / d + 2) } else { h = 60 * ((r - g) / d + 4) }
        if h < 0 { h += 360 }
        return (h, s)
    }

    // ── In Spanish ──

    @Test func TheLabelsAndLinesAreInSpanishThroughLoc() {
        let table = CoreLanguage.Table(language: "es", sentences: ["Convert": "Convertir", "Saved next to the PDF and opened in Word": "Se guarda junto al PDF y se abre en Word"])
        CoreLanguage.withTable(table) {
            let convert = CommandBar.group("Convert")!
            #expect(convert.label == "Convertir")
            #expect(convert.main.note == "Se guarda junto al PDF y se abre en Word")
            #expect(CommandBar.group("FillSign")!.priority < CommandBar.keepsLabels)
        }
    }
}
