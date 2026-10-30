import Foundation

/// How a condition of the Matterhorn Protocol is checked.
public enum ConditionCheck: Sendable {
    /// By the checker, on the file.
    case machine
    /// By a person (the checklist): whether something makes sense can't be read from the file.
    case human
    /// Machine-checkable, but this checker doesn't check it yet (`AccessibilityCondition.note` says why).
    case notChecked
    /// The protocol asks for no test of its own here.
    case noTest
}

/// A failure condition: one of the Matterhorn Protocol 1.1's (PDF/UA-1), numbered as it numbers them ("13-004"), or one
/// of PDF/UA-1's own basic rules that the protocol takes for granted ("UA 6.2").
public struct AccessibilityCondition: Sendable {
    /// "13-004", or "UA 6.2" for a basic rule.
    public let id: String
    /// The checkpoint it belongs to ("13"; "00" for the basic rules).
    public let checkpoint: String
    /// What fails, in plain words.
    public let text: String
    public let how: ConditionCheck
    /// What fixes it, in plain words (for a person's check: how to check it).
    public let fix: String
    /// Why a machine-checkable condition isn't checked, or where it is checked instead.
    public let note: String?
}

/// One thing the check found wrong.
public struct AccessibilityFinding: Sendable {
    /// The failure condition's `AccessibilityCondition.id`.
    public var condition: String
    /// What is wrong here, in plain words.
    public var problem: String
    /// The page it is on (index), or -1 for the document as a whole.
    public var page = -1
    /// Where on `page` (page space, points), when known: what the app scrolls to and outlines.
    public var box = RectD.zero
    /// What it is ("Figure", "Link annotation", "Font Arial-BoldMT", "Document").
    public var element = "Document"
    /// How many times the same thing happens here (content items of a page are counted, not listed one by one).
    public var count = 1
    /// A fix for this finding in particular.
    public var fixOverride: String?

    public init(condition: String, problem: String) {
        self.condition = condition
        self.problem = problem
    }

    /// What fixes it (the condition's own fix unless something more precise is known).
    public var fix: String { fixOverride ?? AccessibilityCheck.condition(condition)?.fix ?? "" }

    /// "Page 3", or "Document" (.NET's `Where`).
    public var place: String { page >= 0 ? "Page \(page + 1)" : "Document" }

    // What the Accessibility pane shows for it (the Windows app's `A11yItem`).

    public var rowTitle: String { element == place ? "\(condition) · \(place)" : "\(condition) · \(place) · \(element)" }
    public var rowProblem: String { count > 1 && !problem.contains(String(count)) ? "\(problem) (\(count) times)" : problem }
    public var rowFix: String { "Fix: " + fix }
    /// What a screen reader says for the row.
    public var spoken: String { "Condition \(condition), \(place), \(element). \(rowProblem) \(rowFix)" }
}

/// A check a person makes (the machine can't tell whether alternate text means anything).
public struct HumanCheck: Sendable {
    /// A stable name ("reading-order"), for keeping ticks.
    public let id: String
    /// The Matterhorn conditions it covers.
    public let conditions: [String]
    /// What to check, as a question.
    public let question: String
    /// How to check it with Inkvolt PDF (or a screen reader).
    public let how: String
}

/// The checker's result for one document.
public struct AccessibilityReport: Sendable {
    /// What fails, in checkpoint order, then by page.
    public let failures: [AccessibilityFinding]
    /// What couldn't be checked in this document, and why.
    public let notes: [String]
    public let pages: Int
    /// The document has a structure tree (tags).
    public let tagged: Bool

    /// No machine-checkable condition fails (the person's checks are still to do).
    public var passed: Bool { failures.isEmpty }

    /// The conditions that fail, each once, in order.
    public var failedConditions: [String] { Array(Set(failures.map(\.condition))).sorted() }

    /// The checks for a person (the same for every document).
    public var humanChecks: [HumanCheck] { AccessibilityCheck.humanChecks }

    /// "Fails 4 conditions (12 problems): …" or "Passes every machine check."
    public var summary: String {
        if passed {
            let machine = AccessibilityCheck.conditions.filter { $0.how == .machine }.count
            return "Passes every machine check (\(machine) conditions). \(AccessibilityCheck.humanChecks.count) checks are left for a person."
        }
        let conditions = failedConditions.count, problems = failures.count
        let head = "Fails \(conditions) \(conditions == 1 ? "condition" : "conditions") (\(problems) \(problems == 1 ? "problem" : "problems"))"
        return head + (tagged ? "." : ": the document isn't tagged, so a screen reader can't tell its headings, lists, tables or reading order.")
    }

    /// The pane's line at the top: the result, and what couldn't be checked.
    public var paneSummary: String {
        let result = (passed ? "Passes the machine checks of PDF/UA-1. " : "") + summary
        return notes.isEmpty ? result : result + " Not checked: " + notes.joined(separator: " ")
    }

    /// The title of the pane's list of failures.
    public var failuresTabTitle: String { passed ? "Fails (none)" : "Fails (\(failures.count))" }
}

/// Accessibility check (the Windows app's `AccessibilityCheck`): a local checker for the machine-checkable failure
/// conditions of the Matterhorn Protocol 1.1, which spells out PDF/UA-1 (ISO 14289-1). It reads the file's tags (structure
/// tree, role map, marked content on every page and in the forms the pages draw), its metadata, annotations, form fields
/// and fonts, and reports each failure with its Matterhorn number, page and element, what is wrong and what fixes it, in
/// plain words. What only a person can judge (reading order, whether alternate text means anything, contrast) is a
/// checklist (`humanChecks`). Nothing is changed. `AccessibilityReportHtml` writes the report as a web page.
public enum AccessibilityCheck {
    /// The checkpoints' titles, by number ("00": PDF/UA's basic rules).
    public static let checkpoints: [String: String] = [
        "00": "PDF/UA basics",
        "01": "Real content tagged",
        "02": "Role mapping",
        "03": "Flickering",
        "04": "Color and contrast",
        "05": "Sound",
        "06": "Metadata",
        "07": "Dictionary",
        "08": "OCR validation",
        "09": "Appropriate tags",
        "10": "Character mappings",
        "11": "Declared natural language",
        "12": "Stretched characters",
        "13": "Graphics",
        "14": "Headings",
        "15": "Tables",
        "16": "Lists",
        "17": "Mathematical expressions",
        "18": "Page headers and footers",
        "19": "Notes and references",
        "20": "Optional content",
        "21": "Embedded files",
        "22": "Article threads",
        "23": "Digital signatures",
        "24": "Non-interactive forms",
        "25": "XFA",
        "26": "Security",
        "27": "Navigation",
        "28": "Annotations",
        "29": "Actions",
        "30": "XObjects",
        "31": "Fonts",
    ]

    private static let tag = "Tag the document (Word: File › Save As › PDF › Options › Document structure tags for accessibility; InDesign: Export › Create Tagged PDF), or tag it in an editor that can."
    private static let makeArtifact = "Mark decorative content (page numbers, running headers, background shapes) as an artifact, and everything else with a tag, in the program that made the PDF or a tag editor."
    private static let person = "A person checks this (see the checklist)."
    private static let language = "Set the document's language in the program that made it (Word: Review › Language, then save as PDF again), or in a PDF editor's document properties (Advanced › Language)."
    private static let fontFix = "Make the PDF again with the font embedded in full (Word: File › Options › Save › Embed fonts in the file; most PDF printers: “embed all fonts”), or use another font."
    private static let fontRemake = "Make the PDF again from its source with a current PDF writer; this font's data is written wrong. A different font can also fix it."

    private static func m(_ id: String, _ text: String, _ fix: String) -> AccessibilityCondition {
        AccessibilityCondition(id: id, checkpoint: id.hasPrefix("UA") ? "00" : String(id.prefix(2)), text: text, how: .machine, fix: fix, note: nil)
    }

    private static func h(_ id: String, _ text: String, _ how: String) -> AccessibilityCondition {
        AccessibilityCondition(id: id, checkpoint: String(id.prefix(2)), text: text, how: .human, fix: how, note: nil)
    }

    private static func n(_ id: String, _ text: String, _ note: String) -> AccessibilityCondition {
        AccessibilityCondition(id: id, checkpoint: String(id.prefix(2)), text: text, how: .notChecked, fix: "", note: note)
    }

    private static func noTest(_ id: String, _ text: String) -> AccessibilityCondition {
        AccessibilityCondition(id: id, checkpoint: String(id.prefix(2)), text: text, how: .noTest, fix: "", note: nil)
    }

    /// Every condition, in order: the basic rules, then the Matterhorn Protocol's 137. Where a fix names a command, it
    /// names the Mac's (docs/PLAN.md's Mac differences); everything else is word for word the Windows app's.
    public static let conditions: [AccessibilityCondition] = [
        m("UA 7.1", "The document has no structure tree: it isn't tagged.", tag),
        m("UA 6.2", "The document doesn't say it is tagged (MarkInfo with Marked true).", tag),
        m("UA 6.1", "The file doesn't start with a PDF 1.x header.", "Save it again as a PDF 1.7 file (PDF/UA-1 is based on PDF 1.7)."),
        m("UA 7.1-P", "A tag has no link to its parent tag (its P entry is missing).", "Re-tag the document, or rebuild its tags in a tag editor."),
        m("UA 7.2-Lang", "A language is written in a form that isn't a language code (such as en-US).", "Set the language to a code such as en, en-US or es (in a PDF editor's document properties, or the tag's language in a tag editor)."),

        h("01-001", "Decorative content is tagged as real content.", "Check that page numbers, running headers and background art are artifacts."),
        h("01-002", "Real content is marked as an artifact.", "Check that nothing a reader needs is hidden from screen readers as an artifact."),
        m("01-003", "Content marked as an artifact is inside tagged content.", makeArtifact),
        m("01-004", "Tagged content is inside content marked as an artifact.", makeArtifact),
        m("01-005", "Content is neither tagged nor marked as an artifact.", makeArtifact),
        h("01-006", "A tag's type or attributes don't fit its content.", person),
        m("01-007", "The document says its tags may be wrong (Suspects is true).", "Check and fix the tags, then clear Suspects (re-saving from a tag editor does it)."),

        m("02-001", "A custom tag type doesn't map to a standard type.", "Map each custom tag type to the standard type that fits it (the role map), in the program that made the PDF or a tag editor."),
        h("02-002", "A custom tag type maps to a standard type that doesn't fit it.", person),
        m("02-003", "The role map goes round in a circle.", "Fix the role map so every custom type ends at a standard type."),
        m("02-004", "A standard tag type is mapped to another type.", "Remove standard types (P, H1, Figure…) from the role map."),

        h("03-001", "An action makes something flicker.", person),
        h("03-002", "A video or animation flickers.", person),
        h("03-003", "A script makes something flicker.", person),
        h("04-001", "Meaning is carried by color, contrast, format or layout alone.", person),
        h("05-001", "A video's sound isn't available in another form.", person),
        h("05-002", "A sound isn't available in another form.", person),
        h("05-003", "A script beeps without another way of telling.", person),

        m("06-001", "The document has no XMP metadata.", "Give it a title in a PDF editor's document properties and save: Inkvolt PDF writes XMP metadata when it saves."),
        m("06-002", "The metadata doesn't say the file is PDF/UA (pdfuaid:part 1).", "Save it as PDF/UA from the program that made it (Word: PDF options › “PDF/UA compliant”), or add the PDF/UA identifier in a tag editor."),
        m("06-003", "The metadata has no title (dc:title).", "Give the document a title in the program that made it or a PDF editor's document properties, then save."),
        h("06-004", "The title doesn't say what the document is.", person),

        m("07-001", "The document doesn't ask viewers to show its title (DisplayDocTitle is missing).", "Turn on “Show document title” in a PDF editor's document properties (Initial View), or save the PDF again from Word with document properties included."),
        m("07-002", "The document asks viewers to show its file name instead of its title (DisplayDocTitle is false).", "Turn on “Show document title” in a PDF editor's document properties (Initial View), or save the PDF again from Word with document properties included."),

        h("08-001", "Recognized (OCR) text has many mistakes.", person),
        h("08-002", "Recognized (OCR) text isn't tagged.", person),

        h("09-001", "The tags aren't in a sensible reading order.", person),
        h("09-002", "Tags are nested in a way that makes no sense (a table inside a heading).", person),
        h("09-003", "A tag's type doesn't fit its content.", person),
        m("09-004", "A table's tags are put together wrongly (rows, cells, header and body groups).", "Rebuild the table's tags: Table › TR (or THead/TBody/TFoot › TR) › TH or TD, every row with the same number of cells."),
        m("09-005", "A list's tags are put together wrongly.", "Rebuild the list's tags: L › LI › Lbl and LBody."),
        m("09-006", "A table of contents' tags are put together wrongly.", "Rebuild the contents' tags: TOC › TOCI (an optional Caption first)."),
        n("09-007", "A Ruby tag is put together wrongly.", "Not checked yet (Ruby is rare; veraPDF doesn't check it either)."),
        n("09-008", "A Warichu tag is put together wrongly.", "Not checked yet (Warichu is rare; veraPDF doesn't check it either)."),

        n("10-001", "A character can't be turned into text (it has no Unicode value).", "Checked as 31-027, font by font (each character a font draws must have a Unicode value)."),

        m("11-001", "The language of text on the page can't be told.", language + " Or set the language of the tags that hold the text, in a tag editor."),
        m("11-002", "The language of alternate, actual or expansion text can't be told.", language),
        m("11-003", "The language of the bookmarks can't be told.", language),
        m("11-004", "The language of a comment's or link's text can't be told.", language),
        m("11-005", "The language of a form field's description can't be told.", language),
        m("11-006", "The language of the metadata (title, description) can't be told.", language),
        h("11-007", "The declared language is wrong.", person),
        h("12-001", "Stretched characters aren't shown properly.", person),

        h("13-001", "A picture or drawing that means something isn't tagged as a Figure.", person),
        h("13-002", "A Figure holds things that don't belong together.", person),
        h("13-003", "A caption isn't tagged as a Caption.", person),
        m("13-004", "A figure has no alternate text.", "Give the figure alternate text that says what it shows (Word: right-click › Edit Alt Text, before making the PDF), or mark it as an artifact if it is decoration."),
        h("13-005", "A figure uses actual text where alternate text fits better.", person),
        h("13-006", "A drawing that only means something with others is tagged on its own.", person),
        h("13-007", "A more accessible form isn't used.", person),
        h("13-008", "A figure meant to be read as text has no actual text.", person),

        h("14-001", "Headings aren't tagged as headings.", person),
        m("14-002", "The first numbered heading isn't H1.", "Start with an H1 heading (Word: use the Heading 1 style for the first heading)."),
        m("14-003", "A heading level is skipped (an H3 right after an H1).", "Use heading levels in order without gaps (Word: Heading 1, then Heading 2, …)."),
        h("14-004", "Numbered headings don't use Arabic numerals.", person),
        h("14-005", "A 7th-level heading doesn't use H7.", person),
        m("14-006", "A tag holds more than one H heading.", "Use numbered headings (H1-H6), or give each H heading its own section."),
        m("14-007", "The document uses both H and H1-H6 headings.", "Use one kind of heading: numbered headings (H1-H6) throughout."),

        h("15-001", "A row's header cell isn't tagged as a header.", person),
        h("15-002", "A column's header cell isn't tagged as a header.", person),
        m("15-003", "A header cell (TH) has no scope, and the table doesn't link cells to headers.", "Give each header cell a scope (Row, Column or Both) in a tag editor, or link data cells to their headers (Headers and IDs)."),
        h("15-004", "Something that isn't a table is tagged as one.", person),
        h("15-005", "A cell's header can't be told for sure.", person),

        h("16-001", "An ordered list has no numbering attribute.", person),
        h("16-002", "An ordered list's numbering attribute isn't a known kind.", person),
        h("16-003", "A list isn't tagged as a list.", person),

        h("17-001", "A formula isn't tagged as a Formula.", person),
        m("17-002", "A formula has no alternate text.", "Give the formula alternate text that reads it out (in a tag editor, or with a LaTeX package that writes it)."),
        n("17-003", "A formula's characters can't be turned into text.", "Checked as 10-001 for every character, formulas included."),

        h("18-001", "Running headers and footers aren't marked as pagination artifacts.", person),
        h("18-002", "Running header or footer artifacts aren't marked as Header or Footer.", person),

        h("19-001", "Footnotes or endnotes aren't tagged as Note.", person),
        h("19-002", "References aren't tagged as Reference.", person),
        m("19-003", "A note has no ID.", "Give each Note tag an ID (re-tag, or add it in a tag editor)."),
        m("19-004", "Two notes have the same ID.", "Give each Note tag its own ID."),

        m("20-001", "A layer configuration in Configs has no name.", "Name every layer configuration (in the program that made the layers)."),
        m("20-002", "The default layer configuration has no name.", "Name the default layer configuration (in the program that made the layers)."),
        m("20-003", "A layer configuration has an AS entry (layers switched automatically).", "Remove the automatic layer states (AS) from the layer configurations."),

        m("21-001", "An attached file's description lacks its file names (F and UF).", "Attach the file again from a program that writes both names."),
        h("22-001", "Article threads don't follow the reading order.", person),
        noTest("23-001", "Digital signatures: no test of their own (their form fields are checked)."),
        h("24-001", "A non-interactive form isn't tagged with PrintField attributes.", person),
        m("25-001", "The file holds a dynamic XFA form (dynamicRender required).", "Save the form as a static (AcroForm) PDF form."),
        m("26-001", "The file is encrypted without saying what readers may do (no P entry).", "Remove the protection, or protect it again (File › Protect with Password…) with copying for accessibility allowed."),
        m("26-002", "The file's protection stops screen readers from reading it.", "Protect it again allowing copying for accessibility, or remove the protection (File › Remove Password Protection…)."),
        noTest("27-001", "Navigation: no test of its own (use the right tags)."),

        h("28-001", "A comment or link isn't in the reading order.", person),
        m("28-002", "A comment isn't inside an Annot tag.", "Tag each comment with an Annot tag, or flatten the comments that are only marks (Pages › Flatten…), then tag the page."),
        h("28-003", "A comment is used for looks but isn't tagged for what it means.", person),
        m("28-004", "A comment or link has no description (no Contents, no alternate text).", "Give the comment text, or the link a description (in a tag editor, its Contents or alternate text)."),
        m("28-005", "A form field has no description (no tooltip, no alternate text).", "Give each form field a tooltip (in Inkvolt PDF: Tools › Prepare Form, then the field's Tooltip); screen readers read it as the field's name."),
        n("28-006", "An annotation of a type ISO 32000 doesn't define doesn't follow the rules for annotations.", "Checked as 28-002 and 28-004, which every annotation must meet."),
        m("28-007", "The file holds a trap network annotation (TrapNet).", "Remove the trap network (it is for printing presses, not readers)."),
        m("28-008", "A page with annotations doesn't set its tab order (Tabs is missing).", "Set the page's tab order to follow the tags (Tabs = S): re-save from a program that does, or set it in an editor's page properties."),
        m("28-009", "A page with annotations sets a tab order that doesn't follow the tags (Tabs isn't S).", "Set the page's tab order to follow the tags (Tabs = S)."),
        m("28-010", "A form field isn't inside a Form tag.", "Tag each form field with a Form tag (in a tag editor, or re-tag the form)."),
        m("28-011", "A link isn't inside a Link tag.", "Tag each link with a Link tag holding the link and its text."),
        m("28-012", "A link has no description (Contents).", "Give each link a description of where it goes (its Contents)."),
        h("28-013", "An image map's links aren't available another way.", person),
        m("28-014", "A video or sound clip doesn't say its type (CT).", "Embed the media again from a program that writes its type."),
        m("28-015", "A video or sound clip has no alternate description (Alt).", "Give the media clip an alternate description."),
        m("28-016", "An attached-file comment's file lacks its file names (F and UF).", "Attach the file again."),
        m("28-017", "A printer's mark is in the tags.", "Take printer's marks out of the tags (they are artifacts)."),
        n("28-018", "A printer's mark's appearance isn't marked as an artifact.", "Not checked yet (printer's marks are for printing presses; rare in documents for reading)."),
        h("29-001", "A script needs keys pressed with a particular timing.", person),

        m("30-001", "The file holds a reference XObject (content taken from another file).", "Make the PDF again with the referenced content included."),
        m("30-002", "A form XObject with tagged content is drawn more than once.", "Make the PDF again so repeated content is either an artifact or tagged each time it appears."),

        m("31-001", "A composite font's CID system registry doesn't match its CMap's.", fontRemake),
        m("31-002", "A composite font's CID system ordering doesn't match its CMap's.", fontRemake),
        m("31-003", "A composite font's CID system supplement is lower than its CMap's.", fontRemake),
        m("31-004", "A TrueType CID font's glyph map (CIDToGIDMap) is neither a stream nor Identity.", fontRemake),
        m("31-005", "A TrueType CID font has no glyph map (CIDToGIDMap).", fontRemake),
        m("31-006", "A CMap is neither a standard one nor embedded.", fontRemake),
        m("31-007", "A CMap's writing mode (WMode) differs between its dictionary and its data.", fontRemake),
        m("31-008", "A CMap uses another CMap that isn't a standard one.", fontRemake),
        m("31-009", "A font isn't embedded.", fontFix),
        h("31-010", "A font is embedded that may not be embedded for all uses (its licence).", person),
        m("31-011", "An embedded font lacks a glyph the text uses.", fontFix),
        m("31-012", "A Type 1 font's CharSet doesn't list every glyph in the font.", fontRemake),
        m("31-013", "A Type 1 font's CharSet lists a glyph the font doesn't have.", fontRemake),
        m("31-014", "A CID font's CIDSet doesn't list every glyph in the font.", fontRemake),
        m("31-015", "A CID font's CIDSet lists a glyph the font doesn't have.", fontRemake),
        m("31-016", "A glyph's width in the PDF differs from its width in the font.", fontRemake),
        m("31-017", "A non-symbolic TrueType font has no Unicode or Mac character map (cmap).", fontRemake),
        n("31-018", "A non-symbolic TrueType font's glyph can't be found through its character maps.", "Checked as 31-011 and 31-030 (a glyph that can't be found is missing or .notdef)."),
        m("31-019", "A non-symbolic TrueType font has no Encoding.", fontRemake),
        m("31-020", "A non-symbolic TrueType font's Encoding dictionary has no base encoding.", fontRemake),
        m("31-021", "A non-symbolic TrueType font's encoding is neither WinAnsi nor MacRoman.", fontRemake),
        m("31-022", "A non-symbolic TrueType font's Differences use glyph names outside the Adobe Glyph List.", fontRemake),
        n("31-023", "A non-symbolic TrueType font has Differences but no Windows Unicode cmap.", "Not checked yet (veraPDF's PDF/UA-1 rules don't either)."),
        m("31-024", "A symbolic TrueType font has an Encoding.", fontRemake),
        m("31-025", "A symbolic TrueType font has no character map (cmap).", fontRemake),
        m("31-026", "A symbolic TrueType font has several character maps but no Windows Symbol (3,0) one.", fontRemake),
        m("31-027", "A font doesn't say which characters its glyphs are (no ToUnicode, no standard encoding).", fontRemake),
        m("31-028", "A font's ToUnicode map gives a character the value 0.", fontRemake),
        m("31-029", "A font's ToUnicode map gives a character the value U+FEFF or U+FFFE.", fontRemake),
        m("31-030", "Text draws the .notdef glyph (a placeholder box).", fontFix),
    ]

    private static let byId: [String: AccessibilityCondition] = Dictionary(uniqueKeysWithValues: conditions.map { ($0.id, $0) })

    /// Each condition's place in `conditions`, for sorting findings.
    static let conditionOrder: [String: Int] = Dictionary(uniqueKeysWithValues: conditions.enumerated().map { ($0.element.id, $0.offset) })

    /// The condition with this id, or nil.
    public static func condition(_ id: String) -> AccessibilityCondition? { byId[id] }

    private static func check(_ id: String, _ conditions: [String], _ question: String, _ how: String) -> HumanCheck {
        HumanCheck(id: id, conditions: conditions, question: question, how: how)
    }

    /// The checks for a person, in the order to do them.
    public static let humanChecks: [HumanCheck] = [
        check("title", ["06-004"], "Does the title say what the document is?",
              "The window's title shows it when the document asks for that; a file name or “Document1” isn't a title."),
        check("reading-order", ["09-001", "28-001", "22-001"], "Is the reading order sensible?",
              "Turn on VoiceOver (⌘F5) and listen to a few pages: columns, sidebars, captions and footnotes should come where a reader expects them."),
        check("tags-fit", ["01-006", "09-002", "09-003", "02-002", "28-003"], "Does each tag fit its content?",
              "Headings are tagged as headings, lists as lists, tables as tables, quotes as quotes; nothing is a heading just to look big."),
        check("artifacts", ["01-001", "01-002", "18-001", "18-002"], "Are decorations artifacts, and is all real content tagged?",
              "Page numbers, running headers and footers, background shapes and lines are artifacts (marked Header or Footer where they are). Nothing a reader needs is an artifact."),
        check("alt-text", ["13-001", "13-002", "13-005", "13-006", "13-007", "13-008"], "Does every meaningful picture have alternate text that says what it shows?",
              "Read each figure's alternate text: it says what the picture shows or means, not “image1.png”. Decorative pictures are artifacts instead. Pictures that only mean something together are one figure."),
        check("captions", ["13-003"], "Are captions tagged as captions?", "A figure's or table's caption is a Caption tag inside it, not a separate paragraph."),
        check("color", ["04-001"], "Is anything said by color, contrast or layout alone, and is there enough contrast?",
              "“Fields in red are required” needs words too. Text needs a contrast of at least 4.5:1 with its background (3:1 for large text); check with a contrast tool."),
        check("headings", ["14-001", "14-004", "14-005"], "Are all headings tagged, at the right level?",
              "Every visual heading is an H1-H6 tag at the level it looks; a seventh level uses H7."),
        check("tables", ["15-001", "15-002", "15-004", "15-005"], "Do tables have their header cells marked, and are only real tables tagged as tables?",
              "Header rows and columns are TH cells; layout grids aren't tables; each data cell's header can be told."),
        check("lists", ["16-001", "16-002", "16-003"], "Are lists tagged as lists, numbered lists with their numbering?",
              "Bulleted and numbered lists are L tags; a numbered list says its numbering (Decimal, UpperRoman, …)."),
        check("language", ["11-007"], "Is the declared language right, also for passages in another language?",
              "The document's language should be the language it is written in; quotes in another language carry their own language on their tags."),
        check("ocr", ["08-001", "08-002"], "If pages were scanned, is the recognized text right and tagged?",
              "Select text on scanned pages (or listen with VoiceOver): it matches the page and is in the tags."),
        check("notes", ["19-001", "19-002", "17-001", "12-001"], "Are notes, references and formulas tagged as such?",
              "Footnotes and endnotes are Note tags, references Reference tags, math Formula tags with alternate text."),
        check("media", ["03-001", "03-002", "03-003", "05-001", "05-002", "05-003", "29-001", "28-013"], "Do sounds, videos and scripts have another way, and does nothing flicker?",
              "Media has captions or a transcript; nothing flashes more than three times a second; scripts don't need timed key presses; image maps' links are also listed."),
        check("forms", ["24-001", "31-010"], "Are printed (non-interactive) forms tagged, and are the fonts allowed to be embedded?",
              "Form-like layouts without fields use PrintField attributes; the fonts' licences allow embedding (most fonts do)."),
    ]
}
