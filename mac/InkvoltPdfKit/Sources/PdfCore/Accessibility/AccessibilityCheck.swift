import Foundation
import PrintCore

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
    let textKey: LocKey
    public let how: ConditionCheck
    let fixKey: LocKey?
    let noteKey: LocKey?

    /// What fails, in plain words (in the interface's language).
    public var text: String { textKey.text }
    /// What fixes it, in plain words (for a person's check: how to check it).
    public var fix: String { fixKey?.text ?? "" }
    /// Why a machine-checkable condition isn't checked, or where it is checked instead.
    public var note: String? { noteKey?.text }
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
    public var element = loc("Document")
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
    public var place: String { page >= 0 ? loc("Page {0}", page + 1) : loc("Document") }

    // What the Accessibility pane shows for it (the Windows app's `A11yItem`).

    public var rowTitle: String { element == place ? "\(condition) · \(place)" : "\(condition) · \(place) · \(element)" }
    public var rowProblem: String { count > 1 && !problem.contains(String(count)) ? loc("{1} ({0} times)", count, problem) : problem }
    public var rowFix: String { loc("Fix: {0}", fix) }
    /// What a screen reader says for the row.
    public var spoken: String { loc("Condition {0}, {1}, {2}. {3} {4}", condition, place, element, rowProblem, rowFix) }
}

/// A check a person makes (the machine can't tell whether alternate text means anything).
public struct HumanCheck: Sendable {
    /// A stable name ("reading-order"), for keeping ticks.
    public let id: String
    /// The Matterhorn conditions it covers.
    public let conditions: [String]
    let questionKey: LocKey
    let howKey: LocKey

    /// What to check, as a question (in the interface's language).
    public var question: String { questionKey.text }
    /// How to check it with Inkvolt PDF (or a screen reader).
    public var how: String { howKey.text }
}

/// What the check says of a document as a whole.
public enum AccessibilityOutcome: Sendable {
    /// Checked in full, and nothing fails (the person's checks are still to do).
    case passes
    /// Something fails, whether or not all of it was checked.
    case fails
    /// Nothing fails in what was checked, but part of it wasn't: a limit on a crafted or huge file, or something that
    /// couldn't be read.
    case notFullyChecked
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

    public var outcome: AccessibilityOutcome { !failures.isEmpty ? .fails : !notes.isEmpty ? .notFullyChecked : .passes }

    /// All of it was checked and no machine-checkable condition fails (the person's checks are still to do).
    public var passed: Bool { outcome == .passes }

    /// The result in a few words: what the report's verdict and the log say.
    public var verdict: String {
        switch outcome {
        case .passes: loc("Passes the machine checks.")
        case .notFullyChecked: loc("Not fully checked.")
        case .fails: loc("Fails.")
        }
    }

    /// The conditions that fail, each once, in order.
    public var failedConditions: [String] { Array(Set(failures.map(\.condition))).sorted() }

    /// The checks for a person (the same for every document).
    public var humanChecks: [HumanCheck] { AccessibilityCheck.humanChecks }

    /// "Fails 4 conditions (12 problems): …", "Passes every machine check." or "Not fully checked: …"
    public var summary: String {
        if outcome == .passes {
            let machine = AccessibilityCheck.conditions.filter { $0.how == .machine }.count
            return loc("Passes every machine check ({0} conditions). {1} checks are left for a person.", machine, AccessibilityCheck.humanChecks.count)
        }
        if outcome == .notFullyChecked {
            return loc("Not fully checked: nothing fails in what was checked, but part of the file wasn't checked, so it can't be called a pass.")
        }
        let conditions = failedConditions.count, problems = failures.count
        let head: String
        if conditions == 1 {
            head = problems == 1 ? loc("Fails {1} condition ({0} problem)", problems, conditions) : loc("Fails {1} condition ({0} problems)", problems, conditions)
        } else {
            head = problems == 1 ? loc("Fails {1} conditions ({0} problem)", problems, conditions) : loc("Fails {1} conditions ({0} problems)", problems, conditions)
        }
        let end = tagged ? "." : loc(": the document isn't tagged, so a screen reader can't tell its headings, lists, tables or reading order.")
        return head + end + (notes.isEmpty ? "" : " " + loc("Part of the file wasn't checked."))
    }

    /// The pane's line at the top: the result, and what couldn't be checked.
    public var paneSummary: String {
        let result = (passed ? loc("Passes the machine checks of PDF/UA-1.") + " " : "") + summary
        return notes.isEmpty ? result : result + " " + loc("Not checked: {0}", notes.joined(separator: " "))
    }

    /// The title of the pane's list of failures.
    public var failuresTabTitle: String {
        !failures.isEmpty ? loc("Fails ({0})", failures.count) : passed ? loc("Fails (none)") : loc("Fails (none found so far)")
    }

    /// What the pane's list of failures says when it is empty.
    public var nothingFailsText: String {
        passed ? loc("Nothing fails the machine checks. A document is accessible once a person has also made the checks under Checklist.")
            : loc("Nothing fails in what was checked, but part of the file wasn't checked (see above), so it can't be called a pass.")
    }
}

/// Accessibility check (the Windows app's `AccessibilityCheck`): a local checker for the machine-checkable failure
/// conditions of the Matterhorn Protocol 1.1, which spells out PDF/UA-1 (ISO 14289-1). It reads the file's tags (structure
/// tree, role map, marked content on every page and in the forms the pages draw), its metadata, annotations, form fields
/// and fonts, and reports each failure with its Matterhorn number, page and element, what is wrong and what fixes it, in
/// plain words. What only a person can judge (reading order, whether alternate text means anything, contrast) is a
/// checklist (`humanChecks`). Nothing is changed. `AccessibilityReportHtml` writes the report as a web page.
public enum AccessibilityCheck {
    /// The checkpoints' titles, by number ("00": PDF/UA's basic rules).
    private static let checkpointKeys: [String: LocKey] = [
        "00": LocKey("PDF/UA basics"),
        "01": LocKey("Real content tagged"),
        "02": LocKey("Role mapping"),
        "03": LocKey("Flickering"),
        "04": LocKey("Color and contrast"),
        "05": LocKey("Sound"),
        "06": LocKey("Metadata"),
        "07": LocKey("Dictionary"),
        "08": LocKey("OCR validation"),
        "09": LocKey("Appropriate tags"),
        "10": LocKey("Character mappings"),
        "11": LocKey("Declared natural language"),
        "12": LocKey("Stretched characters"),
        "13": LocKey("Graphics"),
        "14": LocKey("Headings"),
        "15": LocKey("Tables"),
        "16": LocKey("Lists"),
        "17": LocKey("Mathematical expressions"),
        "18": LocKey("Page headers and footers"),
        "19": LocKey("Notes and references"),
        "20": LocKey("Optional content"),
        "21": LocKey("Embedded files"),
        "22": LocKey("Article threads"),
        "23": LocKey("Digital signatures"),
        "24": LocKey("Non-interactive forms"),
        "25": LocKey(verbatim: "XFA"),
        "26": LocKey("Security"),
        "27": LocKey("Navigation"),
        "28": LocKey("Annotations"),
        "29": LocKey("Actions"),
        "30": LocKey(verbatim: "XObjects"),
        "31": LocKey("Fonts"),
    ]

    /// The checkpoints' titles, by number, in the interface's language.
    public static var checkpoints: [String: String] { checkpointKeys.mapValues(\.text) }

    private static let tag = LocKey("Tag the document (Word: File › Save As › PDF › Options › Document structure tags for accessibility; InDesign: Export › Create Tagged PDF), or tag it in an editor that can.")
    private static let makeArtifact = LocKey("Mark decorative content (page numbers, running headers, background shapes) as an artifact, and everything else with a tag, in the program that made the PDF or a tag editor.")
    private static let person = LocKey("A person checks this (see the checklist).")
    private static let language = LocKey("Set the document's language in the program that made it (Word: Review › Language, then save as PDF again), or in a PDF editor's document properties (Advanced › Language).")
    private static let fontFix = LocKey("Make the PDF again with the font embedded in full (Word: File › Options › Save › Embed fonts in the file; most PDF printers: “embed all fonts”), or use another font.")
    private static let fontRemake = LocKey("Make the PDF again from its source with a current PDF writer; this font's data is written wrong. A different font can also fix it.")

    private static func m(_ id: String, _ text: LocKey, _ fix: LocKey) -> AccessibilityCondition {
        AccessibilityCondition(id: id, checkpoint: id.hasPrefix("UA") ? "00" : String(id.prefix(2)), textKey: text, how: .machine, fixKey: fix, noteKey: nil)
    }

    private static func h(_ id: String, _ text: LocKey, _ how: LocKey) -> AccessibilityCondition {
        AccessibilityCondition(id: id, checkpoint: String(id.prefix(2)), textKey: text, how: .human, fixKey: how, noteKey: nil)
    }

    private static func n(_ id: String, _ text: LocKey, _ note: LocKey) -> AccessibilityCondition {
        AccessibilityCondition(id: id, checkpoint: String(id.prefix(2)), textKey: text, how: .notChecked, fixKey: nil, noteKey: note)
    }

    private static func noTest(_ id: String, _ text: LocKey) -> AccessibilityCondition {
        AccessibilityCondition(id: id, checkpoint: String(id.prefix(2)), textKey: text, how: .noTest, fixKey: nil, noteKey: nil)
    }

    /// Every condition, in order: the basic rules, then the Matterhorn Protocol's 137. Where a fix names a command, it
    /// names the Mac's (docs/PLAN.md's Mac differences); everything else is word for word the Windows app's.
    public static let conditions: [AccessibilityCondition] = [
        m("UA 7.1", LocKey("The document has no structure tree: it isn't tagged."), tag),
        m("UA 6.2", LocKey("The document doesn't say it is tagged (MarkInfo with Marked true)."), tag),
        m("UA 6.1", LocKey("The file doesn't start with a PDF 1.x header."), LocKey("Save it again as a PDF 1.7 file (PDF/UA-1 is based on PDF 1.7).")),
        m("UA 7.1-P", LocKey("A tag has no link to its parent tag (its P entry is missing)."), LocKey("Re-tag the document, or rebuild its tags in a tag editor.")),
        m("UA 7.2-Lang", LocKey("A language is written in a form that isn't a language code (such as en-US)."), LocKey("Set the language to a code such as en, en-US or es (in a PDF editor's document properties, or the tag's language in a tag editor).")),

        h("01-001", LocKey("Decorative content is tagged as real content."), LocKey("Check that page numbers, running headers and background art are artifacts.")),
        h("01-002", LocKey("Real content is marked as an artifact."), LocKey("Check that nothing a reader needs is hidden from screen readers as an artifact.")),
        m("01-003", LocKey("Content marked as an artifact is inside tagged content."), makeArtifact),
        m("01-004", LocKey("Tagged content is inside content marked as an artifact."), makeArtifact),
        m("01-005", LocKey("Content is neither tagged nor marked as an artifact."), makeArtifact),
        h("01-006", LocKey("A tag's type or attributes don't fit its content."), person),
        m("01-007", LocKey("The document says its tags may be wrong (Suspects is true)."), LocKey("Check and fix the tags, then clear Suspects (re-saving from a tag editor does it).")),

        m("02-001", LocKey("A custom tag type doesn't map to a standard type."), LocKey("Map each custom tag type to the standard type that fits it (the role map), in the program that made the PDF or a tag editor.")),
        h("02-002", LocKey("A custom tag type maps to a standard type that doesn't fit it."), person),
        m("02-003", LocKey("The role map goes round in a circle."), LocKey("Fix the role map so every custom type ends at a standard type.")),
        m("02-004", LocKey("A standard tag type is mapped to another type."), LocKey("Remove standard types (P, H1, Figure…) from the role map.")),

        h("03-001", LocKey("An action makes something flicker."), person),
        h("03-002", LocKey("A video or animation flickers."), person),
        h("03-003", LocKey("A script makes something flicker."), person),
        h("04-001", LocKey("Meaning is carried by color, contrast, format or layout alone."), person),
        h("05-001", LocKey("A video's sound isn't available in another form."), person),
        h("05-002", LocKey("A sound isn't available in another form."), person),
        h("05-003", LocKey("A script beeps without another way of telling."), person),

        m("06-001", LocKey("The document has no XMP metadata."), LocKey("Give it a title in File › Document Properties and save: Inkvolt PDF writes XMP metadata when it saves.")),
        m("06-002", LocKey("The metadata doesn't say the file is PDF/UA (pdfuaid:part 1)."), LocKey("Save it as PDF/UA from the program that made it (Word: PDF options › “PDF/UA compliant”), or add the PDF/UA identifier in a tag editor.")),
        m("06-003", LocKey("The metadata has no title (dc:title)."), LocKey("Give the document a title: File › Document Properties › Title in Inkvolt PDF, then save.")),
        h("06-004", LocKey("The title doesn't say what the document is."), person),

        m("07-001", LocKey("The document doesn't ask viewers to show its title (DisplayDocTitle is missing)."), LocKey("Turn on “Show document title” in a PDF editor's document properties (Initial View), or save the PDF again from Word with document properties included.")),
        m("07-002", LocKey("The document asks viewers to show its file name instead of its title (DisplayDocTitle is false)."), LocKey("Turn on “Show document title” in a PDF editor's document properties (Initial View), or save the PDF again from Word with document properties included.")),

        h("08-001", LocKey("Recognized (OCR) text has many mistakes."), person),
        h("08-002", LocKey("Recognized (OCR) text isn't tagged."), person),

        h("09-001", LocKey("The tags aren't in a sensible reading order."), person),
        h("09-002", LocKey("Tags are nested in a way that makes no sense (a table inside a heading)."), person),
        h("09-003", LocKey("A tag's type doesn't fit its content."), person),
        m("09-004", LocKey("A table's tags are put together wrongly (rows, cells, header and body groups)."), LocKey("Rebuild the table's tags: Table › TR (or THead/TBody/TFoot › TR) › TH or TD, every row with the same number of cells.")),
        m("09-005", LocKey("A list's tags are put together wrongly."), LocKey("Rebuild the list's tags: L › LI › Lbl and LBody.")),
        m("09-006", LocKey("A table of contents' tags are put together wrongly."), LocKey("Rebuild the contents' tags: TOC › TOCI (an optional Caption first).")),
        n("09-007", LocKey("A Ruby tag is put together wrongly."), LocKey("Not checked yet (Ruby is rare; veraPDF doesn't check it either).")),
        n("09-008", LocKey("A Warichu tag is put together wrongly."), LocKey("Not checked yet (Warichu is rare; veraPDF doesn't check it either).")),

        n("10-001", LocKey("A character can't be turned into text (it has no Unicode value)."), LocKey("Checked as 31-027, font by font (each character a font draws must have a Unicode value).")),

        m("11-001", LocKey("The language of text on the page can't be told."), LocKey("Set the document's language in the program that made it (Word: Review › Language, then save as PDF again), or in a PDF editor's document properties (Advanced › Language). Or set the language of the tags that hold the text, in a tag editor.")),
        m("11-002", LocKey("The language of alternate, actual or expansion text can't be told."), language),
        m("11-003", LocKey("The language of the bookmarks can't be told."), language),
        m("11-004", LocKey("The language of a comment's or link's text can't be told."), language),
        m("11-005", LocKey("The language of a form field's description can't be told."), language),
        m("11-006", LocKey("The language of the metadata (title, description) can't be told."), language),
        h("11-007", LocKey("The declared language is wrong."), person),
        h("12-001", LocKey("Stretched characters aren't shown properly."), person),

        h("13-001", LocKey("A picture or drawing that means something isn't tagged as a Figure."), person),
        h("13-002", LocKey("A Figure holds things that don't belong together."), person),
        h("13-003", LocKey("A caption isn't tagged as a Caption."), person),
        m("13-004", LocKey("A figure has no alternate text."), LocKey("Give the figure alternate text that says what it shows (Word: right-click › Edit Alt Text, before making the PDF), or mark it as an artifact if it is decoration.")),
        h("13-005", LocKey("A figure uses actual text where alternate text fits better."), person),
        h("13-006", LocKey("A drawing that only means something with others is tagged on its own."), person),
        h("13-007", LocKey("A more accessible form isn't used."), person),
        h("13-008", LocKey("A figure meant to be read as text has no actual text."), person),

        h("14-001", LocKey("Headings aren't tagged as headings."), person),
        m("14-002", LocKey("The first numbered heading isn't H1."), LocKey("Start with an H1 heading (Word: use the Heading 1 style for the first heading).")),
        m("14-003", LocKey("A heading level is skipped (an H3 right after an H1)."), LocKey("Use heading levels in order without gaps (Word: Heading 1, then Heading 2, …).")),
        h("14-004", LocKey("Numbered headings don't use Arabic numerals."), person),
        h("14-005", LocKey("A 7th-level heading doesn't use H7."), person),
        m("14-006", LocKey("A tag holds more than one H heading."), LocKey("Use numbered headings (H1-H6), or give each H heading its own section.")),
        m("14-007", LocKey("The document uses both H and H1-H6 headings."), LocKey("Use one kind of heading: numbered headings (H1-H6) throughout.")),

        h("15-001", LocKey("A row's header cell isn't tagged as a header."), person),
        h("15-002", LocKey("A column's header cell isn't tagged as a header."), person),
        m("15-003", LocKey("A header cell (TH) has no scope, and the table doesn't link cells to headers."), LocKey("Give each header cell a scope (Row, Column or Both) in a tag editor, or link data cells to their headers (Headers and IDs).")),
        h("15-004", LocKey("Something that isn't a table is tagged as one."), person),
        h("15-005", LocKey("A cell's header can't be told for sure."), person),

        h("16-001", LocKey("An ordered list has no numbering attribute."), person),
        h("16-002", LocKey("An ordered list's numbering attribute isn't a known kind."), person),
        h("16-003", LocKey("A list isn't tagged as a list."), person),

        h("17-001", LocKey("A formula isn't tagged as a Formula."), person),
        m("17-002", LocKey("A formula has no alternate text."), LocKey("Give the formula alternate text that reads it out (in a tag editor, or with a LaTeX package that writes it).")),
        n("17-003", LocKey("A formula's characters can't be turned into text."), LocKey("Checked as 10-001 for every character, formulas included.")),

        h("18-001", LocKey("Running headers and footers aren't marked as pagination artifacts."), person),
        h("18-002", LocKey("Running header or footer artifacts aren't marked as Header or Footer."), person),

        h("19-001", LocKey("Footnotes or endnotes aren't tagged as Note."), person),
        h("19-002", LocKey("References aren't tagged as Reference."), person),
        m("19-003", LocKey("A note has no ID."), LocKey("Give each Note tag an ID (re-tag, or add it in a tag editor).")),
        m("19-004", LocKey("Two notes have the same ID."), LocKey("Give each Note tag its own ID.")),

        m("20-001", LocKey("A layer configuration in Configs has no name."), LocKey("Name every layer configuration (in the program that made the layers).")),
        m("20-002", LocKey("The default layer configuration has no name."), LocKey("Name the default layer configuration (in the program that made the layers).")),
        m("20-003", LocKey("A layer configuration has an AS entry (layers switched automatically)."), LocKey("Remove the automatic layer states (AS) from the layer configurations.")),

        m("21-001", LocKey("An attached file's description lacks its file names (F and UF)."), LocKey("Attach the file again (View › Show Attachments, then Attach… writes both names).")),
        h("22-001", LocKey("Article threads don't follow the reading order."), person),
        noTest("23-001", LocKey("Digital signatures: no test of their own (their form fields are checked).")),
        h("24-001", LocKey("A non-interactive form isn't tagged with PrintField attributes."), person),
        m("25-001", LocKey("The file holds a dynamic XFA form (dynamicRender required)."), LocKey("Save the form as a static (AcroForm) PDF form.")),
        m("26-001", LocKey("The file is encrypted without saying what readers may do (no P entry)."), LocKey("Remove the protection, or protect it again (File › Protect with Password…) with copying for accessibility allowed.")),
        m("26-002", LocKey("The file's protection stops screen readers from reading it."), LocKey("Protect it again allowing copying for accessibility, or remove the protection (File › Remove Password Protection…).")),
        noTest("27-001", LocKey("Navigation: no test of its own (use the right tags).")),

        h("28-001", LocKey("A comment or link isn't in the reading order."), person),
        m("28-002", LocKey("A comment isn't inside an Annot tag."), LocKey("Tag each comment with an Annot tag, or flatten the comments that are only marks (Pages › Flatten…), then tag the page.")),
        h("28-003", LocKey("A comment is used for looks but isn't tagged for what it means."), person),
        m("28-004", LocKey("A comment or link has no description (no Contents, no alternate text)."), LocKey("Give the comment text, or the link a description (in a tag editor, its Contents or alternate text).")),
        m("28-005", LocKey("A form field has no description (no tooltip, no alternate text)."), LocKey("Give each form field a tooltip (in Inkvolt PDF: Tools › Prepare Form, then the field's Tooltip); screen readers read it as the field's name.")),
        n("28-006", LocKey("An annotation of a type ISO 32000 doesn't define doesn't follow the rules for annotations."), LocKey("Checked as 28-002 and 28-004, which every annotation must meet.")),
        m("28-007", LocKey("The file holds a trap network annotation (TrapNet)."), LocKey("Remove the trap network (it is for printing presses, not readers).")),
        m("28-008", LocKey("A page with annotations doesn't set its tab order (Tabs is missing)."), LocKey("Set the page's tab order to follow the tags (Tabs = S): re-save from a program that does, or set it in an editor's page properties.")),
        m("28-009", LocKey("A page with annotations sets a tab order that doesn't follow the tags (Tabs isn't S)."), LocKey("Set the page's tab order to follow the tags (Tabs = S).")),
        m("28-010", LocKey("A form field isn't inside a Form tag."), LocKey("Tag each form field with a Form tag (in a tag editor, or re-tag the form).")),
        m("28-011", LocKey("A link isn't inside a Link tag."), LocKey("Tag each link with a Link tag holding the link and its text.")),
        m("28-012", LocKey("A link has no description (Contents)."), LocKey("Give each link a description of where it goes (its Contents).")),
        h("28-013", LocKey("An image map's links aren't available another way."), person),
        m("28-014", LocKey("A video or sound clip doesn't say its type (CT)."), LocKey("Embed the media again from a program that writes its type.")),
        m("28-015", LocKey("A video or sound clip has no alternate description (Alt)."), LocKey("Give the media clip an alternate description.")),
        m("28-016", LocKey("An attached-file comment's file lacks its file names (F and UF)."), LocKey("Attach the file again.")),
        m("28-017", LocKey("A printer's mark is in the tags."), LocKey("Take printer's marks out of the tags (they are artifacts).")),
        n("28-018", LocKey("A printer's mark's appearance isn't marked as an artifact."), LocKey("Not checked yet (printer's marks are for printing presses; rare in documents for reading).")),
        h("29-001", LocKey("A script needs keys pressed with a particular timing."), person),

        m("30-001", LocKey("The file holds a reference XObject (content taken from another file)."), LocKey("Make the PDF again with the referenced content included.")),
        m("30-002", LocKey("A form XObject with tagged content is drawn more than once."), LocKey("Make the PDF again so repeated content is either an artifact or tagged each time it appears.")),

        m("31-001", LocKey("A composite font's CID system registry doesn't match its CMap's."), fontRemake),
        m("31-002", LocKey("A composite font's CID system ordering doesn't match its CMap's."), fontRemake),
        m("31-003", LocKey("A composite font's CID system supplement is lower than its CMap's."), fontRemake),
        m("31-004", LocKey("A TrueType CID font's glyph map (CIDToGIDMap) is neither a stream nor Identity."), fontRemake),
        m("31-005", LocKey("A TrueType CID font has no glyph map (CIDToGIDMap)."), fontRemake),
        m("31-006", LocKey("A CMap is neither a standard one nor embedded."), fontRemake),
        m("31-007", LocKey("A CMap's writing mode (WMode) differs between its dictionary and its data."), fontRemake),
        m("31-008", LocKey("A CMap uses another CMap that isn't a standard one."), fontRemake),
        m("31-009", LocKey("A font isn't embedded."), fontFix),
        h("31-010", LocKey("A font is embedded that may not be embedded for all uses (its licence)."), person),
        m("31-011", LocKey("An embedded font lacks a glyph the text uses."), fontFix),
        m("31-012", LocKey("A Type 1 font's CharSet doesn't list every glyph in the font."), fontRemake),
        m("31-013", LocKey("A Type 1 font's CharSet lists a glyph the font doesn't have."), fontRemake),
        m("31-014", LocKey("A CID font's CIDSet doesn't list every glyph in the font."), fontRemake),
        m("31-015", LocKey("A CID font's CIDSet lists a glyph the font doesn't have."), fontRemake),
        m("31-016", LocKey("A glyph's width in the PDF differs from its width in the font."), fontRemake),
        m("31-017", LocKey("A non-symbolic TrueType font has no Unicode or Mac character map (cmap)."), fontRemake),
        n("31-018", LocKey("A non-symbolic TrueType font's glyph can't be found through its character maps."), LocKey("Checked as 31-011 and 31-030 (a glyph that can't be found is missing or .notdef).")),
        m("31-019", LocKey("A non-symbolic TrueType font has no Encoding."), fontRemake),
        m("31-020", LocKey("A non-symbolic TrueType font's Encoding dictionary has no base encoding."), fontRemake),
        m("31-021", LocKey("A non-symbolic TrueType font's encoding is neither WinAnsi nor MacRoman."), fontRemake),
        m("31-022", LocKey("A non-symbolic TrueType font's Differences use glyph names outside the Adobe Glyph List."), fontRemake),
        n("31-023", LocKey("A non-symbolic TrueType font has Differences but no Windows Unicode cmap."), LocKey("Not checked yet (veraPDF's PDF/UA-1 rules don't either).")),
        m("31-024", LocKey("A symbolic TrueType font has an Encoding."), fontRemake),
        m("31-025", LocKey("A symbolic TrueType font has no character map (cmap)."), fontRemake),
        m("31-026", LocKey("A symbolic TrueType font has several character maps but no Windows Symbol (3,0) one."), fontRemake),
        m("31-027", LocKey("A font doesn't say which characters its glyphs are (no ToUnicode, no standard encoding)."), fontRemake),
        m("31-028", LocKey("A font's ToUnicode map gives a character the value 0."), fontRemake),
        m("31-029", LocKey("A font's ToUnicode map gives a character the value U+FEFF or U+FFFE."), fontRemake),
        m("31-030", LocKey("Text draws the .notdef glyph (a placeholder box)."), fontFix),
    ]

    private static let byId: [String: AccessibilityCondition] = Dictionary(uniqueKeysWithValues: conditions.map { ($0.id, $0) })

    /// Each condition's place in `conditions`, for sorting findings.
    static let conditionOrder: [String: Int] = Dictionary(uniqueKeysWithValues: conditions.enumerated().map { ($0.element.id, $0.offset) })

    /// The condition with this id, or nil.
    public static func condition(_ id: String) -> AccessibilityCondition? { byId[id] }

    private static func check(_ id: String, _ conditions: [String], _ question: LocKey, _ how: LocKey) -> HumanCheck {
        HumanCheck(id: id, conditions: conditions, questionKey: question, howKey: how)
    }

    /// The checks for a person, in the order to do them.
    public static let humanChecks: [HumanCheck] = [
        check("title", ["06-004"], LocKey("Does the title say what the document is?"),
              LocKey("File › Document Properties › Title. A file name or “Document1” isn't a title.")),
        check("reading-order", ["09-001", "28-001", "22-001"], LocKey("Is the reading order sensible?"),
              LocKey("Turn on Read Aloud (⇧⌘Y) or VoiceOver (⌘F5) and listen to a few pages: columns, sidebars, captions and footnotes should come where a reader expects them.")),
        check("tags-fit", ["01-006", "09-002", "09-003", "02-002", "28-003"], LocKey("Does each tag fit its content?"),
              LocKey("Headings are tagged as headings, lists as lists, tables as tables, quotes as quotes; nothing is a heading just to look big.")),
        check("artifacts", ["01-001", "01-002", "18-001", "18-002"], LocKey("Are decorations artifacts, and is all real content tagged?"),
              LocKey("Page numbers, running headers and footers, background shapes and lines are artifacts (marked Header or Footer where they are). Nothing a reader needs is an artifact.")),
        check("alt-text", ["13-001", "13-002", "13-005", "13-006", "13-007", "13-008"], LocKey("Does every meaningful picture have alternate text that says what it shows?"),
              LocKey("Read each figure's alternate text: it says what the picture shows or means, not “image1.png”. Decorative pictures are artifacts instead. Pictures that only mean something together are one figure.")),
        check("captions", ["13-003"], LocKey("Are captions tagged as captions?"), LocKey("A figure's or table's caption is a Caption tag inside it, not a separate paragraph.")),
        check("color", ["04-001"], LocKey("Is anything said by color, contrast or layout alone, and is there enough contrast?"),
              LocKey("“Fields in red are required” needs words too. Text needs a contrast of at least 4.5:1 with its background (3:1 for large text); check with a contrast tool.")),
        check("headings", ["14-001", "14-004", "14-005"], LocKey("Are all headings tagged, at the right level?"),
              LocKey("Every visual heading is an H1-H6 tag at the level it looks; a seventh level uses H7.")),
        check("tables", ["15-001", "15-002", "15-004", "15-005"], LocKey("Do tables have their header cells marked, and are only real tables tagged as tables?"),
              LocKey("Header rows and columns are TH cells; layout grids aren't tables; each data cell's header can be told.")),
        check("lists", ["16-001", "16-002", "16-003"], LocKey("Are lists tagged as lists, numbered lists with their numbering?"),
              LocKey("Bulleted and numbered lists are L tags; a numbered list says its numbering (Decimal, UpperRoman, …).")),
        check("language", ["11-007"], LocKey("Is the declared language right, also for passages in another language?"),
              LocKey("The document's language should be the language it is written in; quotes in another language carry their own language on their tags.")),
        check("ocr", ["08-001", "08-002"], LocKey("If pages were scanned, is the recognized text right and tagged?"),
              LocKey("Select text on scanned pages (or listen with Read Aloud): it matches the page and is in the tags.")),
        check("notes", ["19-001", "19-002", "17-001", "12-001"], LocKey("Are notes, references and formulas tagged as such?"),
              LocKey("Footnotes and endnotes are Note tags, references Reference tags, math Formula tags with alternate text.")),
        check("media", ["03-001", "03-002", "03-003", "05-001", "05-002", "05-003", "29-001", "28-013"], LocKey("Do sounds, videos and scripts have another way, and does nothing flicker?"),
              LocKey("Media has captions or a transcript; nothing flashes more than three times a second; scripts don't need timed key presses; image maps' links are also listed.")),
        check("forms", ["24-001", "31-010"], LocKey("Are printed (non-interactive) forms tagged, and are the fonts allowed to be embedded?"),
              LocKey("Form-like layouts without fields use PrintField attributes; the fonts' licences allow embedding (most fonts do).")),
    ]
}
