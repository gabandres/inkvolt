import Foundation
import PrintCore

/// The document window's command bar (Windows' `CommandBarLayout`; docs/design/command-bar.md, approved by the owner
/// 2026-11-08): the groups people coming from Nitro, Foxit and Acrobat know, in their order (the pointer tools; Edit,
/// Convert; Comment, Fill & Sign; Organize, Protect, Scan & OCR), each a split item of the window's toolbar whose body
/// runs the group's main job in one click and whose arrow opens the rest. Draw sits inside Comment, Redact inside
/// Protect, and the pointer tools show their icons only. Every command here is also in the menu bar (and so in the
/// command palette), so nothing is reached only through the bar.
public enum CommandBar {
    /// Convert's coloured file types and Apply Redactions' red (`BarColors`); everything else is monochrome.
    public enum Tint: String, Sendable, CaseIterable {
        case word, excel, powerPoint, pdfA, applyRedactions
    }

    /// One command of a group: what its menu item says (`title`, and `note`, the line under it), its SF Symbol, and what
    /// it runs: a menu bar command (`action`, a `DocumentCommands` selector such as "exportWord:") or a page tool (`tool`,
    /// the app's `Tool` by its English title, picked as Tools › that tool picks it).
    public struct Item: Sendable, Hashable {
        /// Windows' command name ("ExportWord"), what the tests and the self-test know the item by.
        public let id: String
        public let title: String
        public let note: String
        public let symbol: String
        public let action: String?
        public let tool: String?
        /// Run with the defaults, no questions but what can't be defaulted (Option-click asks as the menus do).
        public let atOnce: Bool
        public let tint: Tint?
        /// A line above it in the menu, setting the rarer or riskier commands apart.
        public let startsSection: Bool

        init(_ id: String, _ title: String, _ note: String, _ symbol: String, action: String? = nil, tool: String? = nil,
             atOnce: Bool = false, tint: Tint? = nil, startsSection: Bool = false) {
            self.id = id
            self.title = title
            self.note = note
            self.symbol = symbol
            self.action = action
            self.tool = tool
            self.atOnce = atOnce
            self.tint = tint
            self.startsSection = startsSection
        }
    }

    /// A place on the bar: its label (always shown beside its icon), symbol, priority (lowest goes into the toolbar's »
    /// overflow first) and commands, the main job first.
    public struct Group: Sendable {
        public let id: String
        public let label: String
        public let symbol: String
        public let priority: Int
        public let items: [Item]

        /// A split item: the body runs `main` at once, the arrow opens the menu. The pointer tools have no main job.
        public var hasMainJob: Bool { id != CommandBar.pointer }
        public var main: Item { items[0] }
        /// Whether the toolbar keeps it out of the overflow as long as it can (`keepsLabels` and above).
        public var isKey: Bool { priority >= CommandBar.keepsLabels }
    }

    /// The pointer tools' group: Hand, Select Text, Snapshot, by their icons.
    public static let pointer = "Pointer"
    /// The group whose menu ends with the drawing tools (a Draw submenu, as Foxit's Comment › Drawing).
    public static let drawsIn = "Comment"
    /// From this priority a group stays on the bar, labeled, while the others go into the overflow.
    public static let keepsLabels = 80

    /// Fill & Sign's priority: a key group in English; in Spanish, where "Llenar y firmar" is the bar's longest label,
    /// under `keepsLabels`, so it goes into the overflow before the other groups (the owner, 2026-11-08).
    public static func fillSignPriority(language: String) -> Int { language == "es" ? 75 : 86 }

    /// Whether a click runs the item at once: an at-once item clicked without Option (Windows' Shift+click asks first).
    public static func runsAtOnce(_ item: Item, option: Bool) -> Bool { item.atOnce && !option }

    /// The bar, left to right, in the interface's language.
    public static var groups: [Group] {
        [
            Group(id: pointer, label: loc("Select"), symbol: "cursorarrow", priority: 79, items: [
                Item("ToolHand", loc("Hand"), loc("Drag the page to move around it"), "hand.raised", tool: "Hand"),
                Item("ToolSelect", loc("Select Text"), loc("Select text to copy, mark or look up"), "character.cursor.ibeam", tool: "Select Text"),
                Item("ToolSnapshot", loc("Snapshot"), loc("Copy an area of the page as a picture"), "camera.viewfinder", action: "chooseSnapshot:"),
            ]),
            Group(id: "Edit", label: loc("Edit", context: "toolbar"), symbol: "pencil.and.outline", priority: 84, items: [
                Item("EditContent", loc("Edit Text & Images"), loc("Change the text and pictures on the page"), "pencil.and.outline", tool: "Edit Text & Images"),
                Item("AddImage", loc("Image"), loc("Place a picture on the page"), "photo", tool: "Image"),
                Item("ToolLink", loc("Link"), loc("Draw a box that opens a page or web address"), "link", tool: "Link"),
                Item("AddHeaderFooter", loc("Add Header & Footer…"), loc("Page numbers, dates or text on every page"), "text.append",
                     action: "addHeaderFooter:", startsSection: true),
                Item("AddWatermark", loc("Add Watermark…"), loc("Write DRAFT or a logo across the pages"), "drop", action: "addWatermark:"),
            ]),
            convert,
            Group(id: "Comment", label: loc("Comment", context: "bar"), symbol: "highlighter", priority: 80, items: [
                // With nothing selected, the highlighter (as Preview's Highlight button).
                Item("Highlight", loc("Highlight"), loc("Mark the selected text in color"), "highlighter", action: "highlightText:", atOnce: true),
                Item("Underline", loc("Underline"), loc("Draw a line under the selected text"), "underline", action: "underlineText:"),
                Item("StrikeOut", loc("Strike Out"), loc("Cross out the selected text"), "strikethrough", action: "strikeOutText:"),
                Item("AddNote", loc("Note"), loc("Pin a note to the page"), "note.text", tool: "Note"),
                Item("AddStamp", loc("Stamp"), loc("Stamp Approved, Draft, Confidential or your own"), "seal", tool: "Stamp"),
            ]),
            Group(id: "FillSign", label: loc("Fill & Sign"), symbol: "signature",
                  priority: fillSignPriority(language: CoreLanguage.table?.language ?? "en"), items: [
                // Your saved signature, placed with the next click; the first time, it asks you to make one.
                Item("AddSignature", loc("Signature"), loc("Draw, type or pick your signature or initials"), "signature", tool: "Signature", atOnce: true),
                Item("ToolAddText", loc("Add Text"), loc("Type in a blank or anywhere on the page"), "character.cursor.ibeam", tool: "Add Text", startsSection: true),
                Item("ToolCheck", loc("Check Mark"), loc("Put a check mark in a box"), "checkmark", tool: "Check Mark"),
                Item("ToolCross", loc("Cross"), loc("Put a cross in a box"), "xmark", tool: "Cross"),
                Item("PrepareForm", loc("Prepare Form"), loc("Add fields that others can fill in"), "rectangle.and.pencil.and.ellipsis",
                     action: "togglePrepareForm:", startsSection: true),
            ]),
            Group(id: "Organize", label: loc("Organize"), symbol: "square.grid.2x2", priority: 70, items: [
                Item("Organize", loc("Organize Pages"), loc("Move, turn, delete and insert pages"), "square.grid.2x2", action: "toggleOrganizer:"),
                Item("InsertPages", loc("Insert Pages from File…"), loc("Add the pages of another file"), "doc.badge.plus", action: "insertPagesFromFile:"),
                Item("ExtractPages", loc("Extract Pages…"), loc("Save some pages as a new PDF"), "doc.on.doc", action: "extractPages:"),
                Item("SplitDocument", loc("Split Document…"), loc("Cut the PDF into several files"), "scissors", action: "splitDocument:"),
                Item("Combine", loc("Combine Files…"), loc("Join several files into one PDF"), "square.stack", action: "combineFiles:", startsSection: true),
                Item("ReduceSize", loc("Reduce File Size…"), loc("Make the file smaller to send it"), "arrow.down.right.and.arrow.up.left",
                     action: "reduceFileSize:"),
            ]),
            Group(id: "Protect", label: loc("Protect"), symbol: "lock", priority: 60, items: [
                // Asks only for the password (AES-256, nothing restricted); Option-click opens the full sheet.
                Item("ProtectPassword", loc("Password"), loc("Ask for a password to open or change it"), "lock", action: "protectDocument:", atOnce: true),
                // The selected text marked at once; with none, the marking tool.
                Item("Redact", loc("Redact"), loc("Black out text or areas for good"), "rectangle.fill", tool: "Redact", atOnce: true, startsSection: true),
                Item("ApplyRedactions", loc("Apply Redactions…"), loc("Remove what you marked, for good"), "checkmark.rectangle.fill",
                     action: "applyRedactions:", tint: .applyRedactions),
                Item("RedactPatterns", loc("Redact by Pattern…"), loc("Find and remove numbers, phones, emails"), "text.magnifyingglass",
                     action: "redactByPattern:"),
                Item("CheckRedaction", loc("Check Redaction…"), loc("Make sure nothing removed can be read"), "checkmark.shield", action: "checkRedaction:"),
                Item("Sanitize", loc("Sanitize Document…"), loc("Remove hidden data, metadata and scripts"), "eraser", action: "sanitizeDocument:"),
                Item("Sign", loc("Sign Digitally…"), loc("Sign with a digital ID (certificate)"), "checkmark.seal", action: "signDigitally:",
                     startsSection: true),
                Item("RemoveProtection", loc("Remove Password Protection…"), loc("Take the password off the file"), "lock.open",
                     action: "removeProtection:", startsSection: true),
            ]),
            Group(id: "ScanOcr", label: loc("Scan & OCR"), symbol: "text.viewfinder", priority: 50, items: [
                // Every page that has no text, with the last Recognize Text settings.
                Item("RecognizeText", loc("Recognize Text"), loc("Make scanned pages searchable"), "text.viewfinder", action: "recognizeText:", atOnce: true),
                Item("Scan", loc("Scan…"), loc("A new PDF from your scanner"), "scanner", action: "scan:"),
                Item("InsertFromScanner", loc("Insert from Scanner…"), loc("Scanned pages added to this PDF"), "doc.viewfinder", action: "insertFromScanner:"),
                Item("ReviewSuspectWords", loc("Review Suspect Words"), loc("Check the words OCR wasn't sure of"), "exclamationmark.magnifyingglass",
                     action: "reviewSuspectWords:", startsSection: true),
            ]),
        ]
    }

    /// Convert: the editable formats run at once (name.docx next to the PDF, opened); PDF/A asks, as in the menus. A
    /// coloured file type is a filled document symbol, so its colour reads at menu size; the label says which.
    private static var convert: Group {
        Group(id: "Convert", label: loc("Convert"), symbol: "arrow.left.arrow.right", priority: 90, items: [
            Item("ExportWord", loc("Word (.docx)"), loc("Saved next to the PDF and opened in Word"), filledDocument, action: "exportWord:",
                 atOnce: true, tint: .word),
            Item("ExportExcel", loc("Excel (.xlsx)"), loc("The tables as an Excel workbook"), filledDocument, action: "exportExcel:",
                 atOnce: true, tint: .excel),
            Item("ExportPowerPoint", loc("PowerPoint (.pptx)"), loc("Each page as a slide you can edit"), filledDocument, action: "exportPowerPoint:",
                 atOnce: true, tint: .powerPoint),
            Item("ExportText", loc("Plain text (.txt)"), loc("Just the words, in a plain text file"), "doc.plaintext", action: "exportText:",
                 atOnce: true, startsSection: true),
            Item("ExportHtml", loc("Web page (.html)"), loc("Headings, lists and tables as a web page"), "globe", action: "exportHtml:", atOnce: true),
            Item("SaveAsPdfA", loc("PDF/A for archiving…"), loc("A copy that opens the same for years"), filledDocument, action: "saveAsPdfA:",
                 tint: .pdfA, startsSection: true),
        ])
    }

    /// The symbol of Convert's coloured file types.
    public static let filledDocument = "doc.fill"

    public static func group(_ id: String) -> Group? { groups.first { $0.id == id } }

    /// Where the toolbar ranks a group for its overflow (AppKit's `NSToolbarItem.VisibilityPriority` raw value: the
    /// lowest goes into » first; the window's other items are standard, 0). Key groups stay as long as anything does;
    /// the others go first, lowest priority first.
    public static func visibilityPriority(_ group: Group) -> Int {
        group.isKey ? 1000 + group.priority : group.priority - 100
    }
}

/// The command bar's only colours (the owner, 2026-11-08; Windows' `BarColors`): Convert's Word blue, Excel green,
/// PowerPoint orange and PDF/A grey, and Apply Redactions' red, each with a dark variant, every one at 3:1 or more
/// against the menu's and the bar's backgrounds in its appearance (WCAG's non-text contrast). Under Increase Contrast
/// none is used: the system's label colour draws them, as Windows' high contrast does. Labels always say what an icon
/// means, so colour never carries it alone (Differentiate Without Color has nothing to replace).
public enum BarColors {
    /// A tint and its colour in each appearance (#RRGGBB).
    public struct Shade: Sendable, Equatable {
        public let tint: CommandBar.Tint
        public let light: String
        public let dark: String
    }

    public static let all: [Shade] = [
        Shade(tint: .word, light: "#185ABD", dark: "#4A9EFF"),
        Shade(tint: .excel, light: "#107C41", dark: "#2ECC71"),
        Shade(tint: .powerPoint, light: "#C43E1C", dark: "#FF7A50"),
        Shade(tint: .pdfA, light: "#6B6B6B", dark: "#A0A0A0"),
        Shade(tint: .applyRedactions, light: "#D13438", dark: "#FF6B6B"),
    ]

    /// The backgrounds an icon sits on: the menu, the toolbar, a hovered row; light, then dark (Windows' values, which
    /// cover the Mac's menu and toolbar materials over a white or black window).
    public static let lightBackgrounds = ["#FFFFFF", "#F9F9F9", "#F3F3F3", "#EBEBEB"]
    public static let darkBackgrounds = ["#202020", "#2C2C2C", "#383838", "#454545"]

    /// The colour to draw `tint` with; nil under Increase Contrast (the label colour, a template image).
    public static func color(_ tint: CommandBar.Tint, dark: Bool, increaseContrast: Bool) -> String? {
        guard !increaseContrast, let shade = all.first(where: { $0.tint == tint }) else { return nil }
        return dark ? shade.dark : shade.light
    }

    /// WCAG's contrast ratio of two #RRGGBB colours (1 to 21).
    public static func contrastRatio(_ a: String, _ b: String) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// The three bytes of a #RRGGBB colour; nil for anything else.
    public static func rgb(_ hex: String) -> (r: UInt8, g: UInt8, b: UInt8)? {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, h.allSatisfy(\.isHexDigit), let v = UInt32(h, radix: 16) else { return nil }
        return (UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF))
    }

    private static func luminance(_ hex: String) -> Double {
        guard let (r, g, b) = rgb(hex) else { return 0 }
        func linear(_ c: UInt8) -> Double {
            let x = Double(c) / 255
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        let red = 0.2126 * linear(r), green = 0.7152 * linear(g), blue = 0.0722 * linear(b)
        return red + green + blue
    }
}
