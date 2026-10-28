namespace InkvoltPdf.Core;

/// <summary>How a condition of the Matterhorn Protocol is checked.</summary>
public enum ConditionCheck
{
    /// <summary>By the checker, on the file.</summary>
    Machine,

    /// <summary>By a person (the checklist): whether something makes sense can't be read from the file.</summary>
    Human,

    /// <summary>Machine-checkable, but this checker doesn't check it yet (<see cref="AccessibilityCondition.Note"/> says why).</summary>
    NotChecked,

    /// <summary>The protocol asks for no test of its own here.</summary>
    NoTest,
}

/// <summary>
/// A failure condition: one of the Matterhorn Protocol 1.1's (PDF/UA-1), numbered as it numbers them ("13-004"), or one
/// of PDF/UA-1's own basic rules that the protocol takes for granted ("UA 6.2").
/// </summary>
/// <param name="Id">"13-004", or "UA 6.2" for a basic rule.</param>
/// <param name="Checkpoint">The checkpoint it belongs to ("13"; "00" for the basic rules).</param>
/// <param name="Text">What fails, in plain words.</param>
/// <param name="Fix">What fixes it, in plain words (for a person's check: how to check it).</param>
/// <param name="Note">Why a machine-checkable condition isn't checked, or where it is checked instead.</param>
public sealed record AccessibilityCondition(string Id, string Checkpoint, string Text, ConditionCheck How, string Fix, string? Note = null);

/// <summary>One thing the check found wrong.</summary>
/// <param name="Condition">The failure condition's <see cref="AccessibilityCondition.Id"/>.</param>
/// <param name="Problem">What is wrong here, in plain words.</param>
public sealed record AccessibilityFinding(string Condition, string Problem)
{
    /// <summary>The page it is on (index), or -1 for the document as a whole.</summary>
    public int Page { get; init; } = -1;

    /// <summary>Where on <see cref="Page"/> (page space, points), when known: what the app scrolls to and outlines.</summary>
    public RectD Box { get; init; }

    /// <summary>What it is ("Figure", "Link annotation", "Font Arial-BoldMT", "Document").</summary>
    public string Element { get; init; } = "Document";

    /// <summary>How many times the same thing happens here (content items of a page are counted, not listed one by one).</summary>
    public int Count { get; init; } = 1;

    /// <summary>What fixes it (the condition's own fix unless something more precise is known).</summary>
    public string Fix => FixOverride ?? AccessibilityCheck.Condition(Condition)?.Fix ?? "";

    /// <summary>A fix for this finding in particular.</summary>
    public string? FixOverride { get; init; }

    /// <summary>"Page 3", or "Document".</summary>
    public string Where => Page >= 0 ? $"Page {Page + 1}" : "Document";
}

/// <summary>A check a person makes (the machine can't tell whether alternate text means anything).</summary>
/// <param name="Id">A stable name ("reading-order"), for keeping ticks.</param>
/// <param name="Conditions">The Matterhorn conditions it covers.</param>
/// <param name="Question">What to check, as a question.</param>
/// <param name="How">How to check it with Inkvolt PDF (or a screen reader).</param>
public sealed record HumanCheck(string Id, IReadOnlyList<string> Conditions, string Question, string How);

/// <summary>The checker's result for one document.</summary>
/// <param name="Failures">What fails, in checkpoint order, then by page.</param>
/// <param name="Notes">What couldn't be checked in this document, and why.</param>
/// <param name="Tagged">The document has a structure tree (tags).</param>
public sealed record AccessibilityReport(IReadOnlyList<AccessibilityFinding> Failures, IReadOnlyList<string> Notes, int Pages, bool Tagged)
{
    /// <summary>No machine-checkable condition fails (the person's checks are still to do).</summary>
    public bool Passed => Failures.Count == 0;

    /// <summary>The conditions that fail, each once, in order.</summary>
    public IReadOnlyList<string> FailedConditions => [.. Failures.Select(f => f.Condition).Distinct().Order(StringComparer.Ordinal)];

    /// <summary>The checks for a person (the same for every document).</summary>
    public IReadOnlyList<HumanCheck> HumanChecks => AccessibilityCheck.HumanChecks;

    /// <summary>"Fails 4 conditions (12 problems): …" or "Passes every machine check."</summary>
    public string Summary
    {
        get
        {
            if (Passed) return $"Passes every machine check ({AccessibilityCheck.Conditions.Count(c => c.How == ConditionCheck.Machine)} conditions). " +
                               $"{AccessibilityCheck.HumanChecks.Count} checks are left for a person.";
            var conditions = FailedConditions.Count;
            var problems = Failures.Count;
            return $"Fails {conditions} {(conditions == 1 ? "condition" : "conditions")} ({problems} {(problems == 1 ? "problem" : "problems")})" +
                   (Tagged ? "." : ": the document isn't tagged, so a screen reader can't tell its headings, lists, tables or reading order.");
        }
    }
}

/// <summary>
/// Accessibility check: a local checker for the machine-checkable failure conditions of the Matterhorn Protocol 1.1, which
/// spells out PDF/UA-1 (ISO 14289-1). It reads the file's tags (structure tree, role map, marked content on every page and
/// in the forms the pages draw), its metadata, annotations, form fields and fonts, and reports each failure with its
/// Matterhorn number, page and element, what is wrong and what fixes it, in plain words. What only a person can judge
/// (reading order, whether alternate text means anything, contrast) is a checklist (<see cref="HumanChecks"/>). Nothing
/// is changed. <see cref="AccessibilityReportHtml"/> writes the report as a web page.
/// </summary>
public static partial class AccessibilityCheck
{
    /// <summary>The checkpoints' titles, by number ("00": PDF/UA's basic rules).</summary>
    public static readonly IReadOnlyDictionary<string, string> Checkpoints = new Dictionary<string, string>
    {
        ["00"] = "PDF/UA basics",
        ["01"] = "Real content tagged",
        ["02"] = "Role mapping",
        ["03"] = "Flickering",
        ["04"] = "Color and contrast",
        ["05"] = "Sound",
        ["06"] = "Metadata",
        ["07"] = "Dictionary",
        ["08"] = "OCR validation",
        ["09"] = "Appropriate tags",
        ["10"] = "Character mappings",
        ["11"] = "Declared natural language",
        ["12"] = "Stretched characters",
        ["13"] = "Graphics",
        ["14"] = "Headings",
        ["15"] = "Tables",
        ["16"] = "Lists",
        ["17"] = "Mathematical expressions",
        ["18"] = "Page headers and footers",
        ["19"] = "Notes and references",
        ["20"] = "Optional content",
        ["21"] = "Embedded files",
        ["22"] = "Article threads",
        ["23"] = "Digital signatures",
        ["24"] = "Non-interactive forms",
        ["25"] = "XFA",
        ["26"] = "Security",
        ["27"] = "Navigation",
        ["28"] = "Annotations",
        ["29"] = "Actions",
        ["30"] = "XObjects",
        ["31"] = "Fonts",
    };

    private const string Tag = "Tag the document (Word: File › Save As › PDF › Options › Document structure tags for accessibility; " +
                               "InDesign: Export › Create Tagged PDF), or tag it in an editor that can.";

    private const string MakeArtifact = "Mark decorative content (page numbers, running headers, background shapes) as an artifact, and " +
                                        "everything else with a tag, in the program that made the PDF or a tag editor.";

    private const string Person = "A person checks this (see the checklist).";

    private const string Language = "Set the document's language in the program that made it (Word: Review › Language, then save as PDF again), " +
                                    "or in a PDF editor's document properties (Advanced › Language).";

    private const string FontFix = "Make the PDF again with the font embedded in full (Word: File › Options › Save › Embed fonts in the file; " +
                                   "most PDF printers: “embed all fonts”), or use another font.";

    private const string FontRemake = "Make the PDF again from its source with a current PDF writer; this font's data is written wrong. " +
                                      "A different font can also fix it.";

    private static AccessibilityCondition M(string id, string text, string fix) => new(id, id.StartsWith("UA", StringComparison.Ordinal) ? "00" : id[..2], text, ConditionCheck.Machine, fix);
    private static AccessibilityCondition H(string id, string text, string how) => new(id, id[..2], text, ConditionCheck.Human, how);
    private static AccessibilityCondition N(string id, string text, string note) => new(id, id[..2], text, ConditionCheck.NotChecked, "", note);

    /// <summary>Every condition, in order: the basic rules, then the Matterhorn Protocol's 137.</summary>
    public static readonly IReadOnlyList<AccessibilityCondition> Conditions =
    [
        M("UA 7.1", "The document has no structure tree: it isn't tagged.", Tag),
        M("UA 6.2", "The document doesn't say it is tagged (MarkInfo with Marked true).", Tag),
        M("UA 6.1", "The file doesn't start with a PDF 1.x header.", "Save it again as a PDF 1.7 file (PDF/UA-1 is based on PDF 1.7)."),
        M("UA 7.1-P", "A tag has no link to its parent tag (its P entry is missing).", "Re-tag the document, or rebuild its tags in a tag editor."),
        M("UA 7.2-Lang", "A language is written in a form that isn't a language code (such as en-US).", "Set the language to a code such as en, en-US or es (in a PDF editor's document properties, or the tag's language in a tag editor)."),

        H("01-001", "Decorative content is tagged as real content.", "Check that page numbers, running headers and background art are artifacts."),
        H("01-002", "Real content is marked as an artifact.", "Check that nothing a reader needs is hidden from screen readers as an artifact."),
        M("01-003", "Content marked as an artifact is inside tagged content.", MakeArtifact),
        M("01-004", "Tagged content is inside content marked as an artifact.", MakeArtifact),
        M("01-005", "Content is neither tagged nor marked as an artifact.", MakeArtifact),
        H("01-006", "A tag's type or attributes don't fit its content.", Person),
        M("01-007", "The document says its tags may be wrong (Suspects is true).", "Check and fix the tags, then clear Suspects (re-saving from a tag editor does it)."),

        M("02-001", "A custom tag type doesn't map to a standard type.", "Map each custom tag type to the standard type that fits it (the role map), in the program that made the PDF or a tag editor."),
        H("02-002", "A custom tag type maps to a standard type that doesn't fit it.", Person),
        M("02-003", "The role map goes round in a circle.", "Fix the role map so every custom type ends at a standard type."),
        M("02-004", "A standard tag type is mapped to another type.", "Remove standard types (P, H1, Figure…) from the role map."),

        H("03-001", "An action makes something flicker.", Person),
        H("03-002", "A video or animation flickers.", Person),
        H("03-003", "A script makes something flicker.", Person),
        H("04-001", "Meaning is carried by color, contrast, format or layout alone.", Person),
        H("05-001", "A video's sound isn't available in another form.", Person),
        H("05-002", "A sound isn't available in another form.", Person),
        H("05-003", "A script beeps without another way of telling.", Person),

        M("06-001", "The document has no XMP metadata.", "Give it a title in File › Document Properties and save: Inkvolt PDF writes XMP metadata when it saves."),
        M("06-002", "The metadata doesn't say the file is PDF/UA (pdfuaid:part 1).", "Save it as PDF/UA from the program that made it (Word: PDF options › “PDF/UA compliant”), or add the PDF/UA identifier in a tag editor."),
        M("06-003", "The metadata has no title (dc:title).", "Give the document a title: File › Document Properties › Title in Inkvolt PDF, then save."),
        H("06-004", "The title doesn't say what the document is.", Person),

        M("07-001", "The document doesn't ask viewers to show its title (DisplayDocTitle is missing).", "Turn on “Show document title” in a PDF editor's document properties (Initial View), or save the PDF again from Word with document properties included."),
        M("07-002", "The document asks viewers to show its file name instead of its title (DisplayDocTitle is false).", "Turn on “Show document title” in a PDF editor's document properties (Initial View), or save the PDF again from Word with document properties included."),

        H("08-001", "Recognized (OCR) text has many mistakes.", Person),
        H("08-002", "Recognized (OCR) text isn't tagged.", Person),

        H("09-001", "The tags aren't in a sensible reading order.", Person),
        H("09-002", "Tags are nested in a way that makes no sense (a table inside a heading).", Person),
        H("09-003", "A tag's type doesn't fit its content.", Person),
        M("09-004", "A table's tags are put together wrongly (rows, cells, header and body groups).", "Rebuild the table's tags: Table › TR (or THead/TBody/TFoot › TR) › TH or TD, every row with the same number of cells."),
        M("09-005", "A list's tags are put together wrongly.", "Rebuild the list's tags: L › LI › Lbl and LBody."),
        M("09-006", "A table of contents' tags are put together wrongly.", "Rebuild the contents' tags: TOC › TOCI (an optional Caption first)."),
        N("09-007", "A Ruby tag is put together wrongly.", "Not checked yet (Ruby is rare; veraPDF doesn't check it either)."),
        N("09-008", "A Warichu tag is put together wrongly.", "Not checked yet (Warichu is rare; veraPDF doesn't check it either)."),

        N("10-001", "A character can't be turned into text (it has no Unicode value).", "Checked as 31-027, font by font (each character a font draws must have a Unicode value)."),

        M("11-001", "The language of text on the page can't be told.", Language + " Or set the language of the tags that hold the text, in a tag editor."),
        M("11-002", "The language of alternate, actual or expansion text can't be told.", Language),
        M("11-003", "The language of the bookmarks can't be told.", Language),
        M("11-004", "The language of a comment's or link's text can't be told.", Language),
        M("11-005", "The language of a form field's description can't be told.", Language),
        M("11-006", "The language of the metadata (title, description) can't be told.", Language),
        H("11-007", "The declared language is wrong.", Person),
        H("12-001", "Stretched characters aren't shown properly.", Person),

        H("13-001", "A picture or drawing that means something isn't tagged as a Figure.", Person),
        H("13-002", "A Figure holds things that don't belong together.", Person),
        H("13-003", "A caption isn't tagged as a Caption.", Person),
        M("13-004", "A figure has no alternate text.", "Give the figure alternate text that says what it shows (Word: right-click › Edit Alt Text, before making the PDF), or mark it as an artifact if it is decoration."),
        H("13-005", "A figure uses actual text where alternate text fits better.", Person),
        H("13-006", "A drawing that only means something with others is tagged on its own.", Person),
        H("13-007", "A more accessible form isn't used.", Person),
        H("13-008", "A figure meant to be read as text has no actual text.", Person),

        H("14-001", "Headings aren't tagged as headings.", Person),
        M("14-002", "The first numbered heading isn't H1.", "Start with an H1 heading (Word: use the Heading 1 style for the first heading)."),
        M("14-003", "A heading level is skipped (an H3 right after an H1).", "Use heading levels in order without gaps (Word: Heading 1, then Heading 2, …)."),
        H("14-004", "Numbered headings don't use Arabic numerals.", Person),
        H("14-005", "A 7th-level heading doesn't use H7.", Person),
        M("14-006", "A tag holds more than one H heading.", "Use numbered headings (H1-H6), or give each H heading its own section."),
        M("14-007", "The document uses both H and H1-H6 headings.", "Use one kind of heading: numbered headings (H1-H6) throughout."),

        H("15-001", "A row's header cell isn't tagged as a header.", Person),
        H("15-002", "A column's header cell isn't tagged as a header.", Person),
        M("15-003", "A header cell (TH) has no scope, and the table doesn't link cells to headers.", "Give each header cell a scope (Row, Column or Both) in a tag editor, or link data cells to their headers (Headers and IDs)."),
        H("15-004", "Something that isn't a table is tagged as one.", Person),
        H("15-005", "A cell's header can't be told for sure.", Person),

        H("16-001", "An ordered list has no numbering attribute.", Person),
        H("16-002", "An ordered list's numbering attribute isn't a known kind.", Person),
        H("16-003", "A list isn't tagged as a list.", Person),

        H("17-001", "A formula isn't tagged as a Formula.", Person),
        M("17-002", "A formula has no alternate text.", "Give the formula alternate text that reads it out (in a tag editor, or with a LaTeX package that writes it)."),
        N("17-003", "A formula's characters can't be turned into text.", "Checked as 10-001 for every character, formulas included."),

        H("18-001", "Running headers and footers aren't marked as pagination artifacts.", Person),
        H("18-002", "Running header or footer artifacts aren't marked as Header or Footer.", Person),

        H("19-001", "Footnotes or endnotes aren't tagged as Note.", Person),
        H("19-002", "References aren't tagged as Reference.", Person),
        M("19-003", "A note has no ID.", "Give each Note tag an ID (re-tag, or add it in a tag editor)."),
        M("19-004", "Two notes have the same ID.", "Give each Note tag its own ID."),

        M("20-001", "A layer configuration in Configs has no name.", "Name every layer configuration (in the program that made the layers)."),
        M("20-002", "The default layer configuration has no name.", "Name the default layer configuration (in the program that made the layers)."),
        M("20-003", "A layer configuration has an AS entry (layers switched automatically).", "Remove the automatic layer states (AS) from the layer configurations."),

        M("21-001", "An attached file's description lacks its file names (F and UF).", "Attach the file again (Review › Attach a File… writes both names)."),
        H("22-001", "Article threads don't follow the reading order.", Person),
        new("23-001", "23", "Digital signatures: no test of their own (their form fields are checked).", ConditionCheck.NoTest, ""),
        H("24-001", "A non-interactive form isn't tagged with PrintField attributes.", Person),
        M("25-001", "The file holds a dynamic XFA form (dynamicRender required).", "Save the form as a static (AcroForm) PDF form."),
        M("26-001", "The file is encrypted without saying what readers may do (no P entry).", "Remove the protection, or protect it again (File › Protect with Password…) with copying for accessibility allowed."),
        M("26-002", "The file's protection stops screen readers from reading it.", "Protect it again allowing copying for accessibility, or remove the protection (File › Remove Protection…)."),
        new("27-001", "27", "Navigation: no test of its own (use the right tags).", ConditionCheck.NoTest, ""),

        H("28-001", "A comment or link isn't in the reading order.", Person),
        M("28-002", "A comment isn't inside an Annot tag.", "Tag each comment with an Annot tag, or flatten the comments that are only marks (File › Flatten…), then tag the page."),
        H("28-003", "A comment is used for looks but isn't tagged for what it means.", Person),
        M("28-004", "A comment or link has no description (no Contents, no alternate text).", "Give the comment text, or the link a description (in a tag editor, its Contents or alternate text)."),
        M("28-005", "A form field has no description (no tooltip, no alternate text).", "Give each form field a tooltip (in Inkvolt PDF: Forms › field properties › Tooltip); screen readers read it as the field's name."),
        N("28-006", "An annotation of a type ISO 32000 doesn't define doesn't follow the rules for annotations.", "Checked as 28-002 and 28-004, which every annotation must meet."),
        M("28-007", "The file holds a trap network annotation (TrapNet).", "Remove the trap network (it is for printing presses, not readers)."),
        M("28-008", "A page with annotations doesn't set its tab order (Tabs is missing).", "Set the page's tab order to follow the tags (Tabs = S): re-save from a program that does, or set it in an editor's page properties."),
        M("28-009", "A page with annotations sets a tab order that doesn't follow the tags (Tabs isn't S).", "Set the page's tab order to follow the tags (Tabs = S)."),
        M("28-010", "A form field isn't inside a Form tag.", "Tag each form field with a Form tag (in a tag editor, or re-tag the form)."),
        M("28-011", "A link isn't inside a Link tag.", "Tag each link with a Link tag holding the link and its text."),
        M("28-012", "A link has no description (Contents).", "Give each link a description of where it goes (its Contents)."),
        H("28-013", "An image map's links aren't available another way.", Person),
        M("28-014", "A video or sound clip doesn't say its type (CT).", "Embed the media again from a program that writes its type."),
        M("28-015", "A video or sound clip has no alternate description (Alt).", "Give the media clip an alternate description."),
        M("28-016", "An attached-file comment's file lacks its file names (F and UF).", "Attach the file again."),
        M("28-017", "A printer's mark is in the tags.", "Take printer's marks out of the tags (they are artifacts)."),
        N("28-018", "A printer's mark's appearance isn't marked as an artifact.", "Not checked yet (printer's marks are for printing presses; rare in documents for reading)."),
        H("29-001", "A script needs keys pressed with a particular timing.", Person),

        M("30-001", "The file holds a reference XObject (content taken from another file).", "Make the PDF again with the referenced content included."),
        M("30-002", "A form XObject with tagged content is drawn more than once.", "Make the PDF again so repeated content is either an artifact or tagged each time it appears."),

        M("31-001", "A composite font's CID system registry doesn't match its CMap's.", FontRemake),
        M("31-002", "A composite font's CID system ordering doesn't match its CMap's.", FontRemake),
        M("31-003", "A composite font's CID system supplement is lower than its CMap's.", FontRemake),
        M("31-004", "A TrueType CID font's glyph map (CIDToGIDMap) is neither a stream nor Identity.", FontRemake),
        M("31-005", "A TrueType CID font has no glyph map (CIDToGIDMap).", FontRemake),
        M("31-006", "A CMap is neither a standard one nor embedded.", FontRemake),
        M("31-007", "A CMap's writing mode (WMode) differs between its dictionary and its data.", FontRemake),
        M("31-008", "A CMap uses another CMap that isn't a standard one.", FontRemake),
        M("31-009", "A font isn't embedded.", FontFix),
        H("31-010", "A font is embedded that may not be embedded for all uses (its licence).", Person),
        M("31-011", "An embedded font lacks a glyph the text uses.", FontFix),
        M("31-012", "A Type 1 font's CharSet doesn't list every glyph in the font.", FontRemake),
        M("31-013", "A Type 1 font's CharSet lists a glyph the font doesn't have.", FontRemake),
        M("31-014", "A CID font's CIDSet doesn't list every glyph in the font.", FontRemake),
        M("31-015", "A CID font's CIDSet lists a glyph the font doesn't have.", FontRemake),
        M("31-016", "A glyph's width in the PDF differs from its width in the font.", FontRemake),
        M("31-017", "A non-symbolic TrueType font has no Unicode or Mac character map (cmap).", FontRemake),
        N("31-018", "A non-symbolic TrueType font's glyph can't be found through its character maps.", "Checked as 31-011 and 31-030 (a glyph that can't be found is missing or .notdef)."),
        M("31-019", "A non-symbolic TrueType font has no Encoding.", FontRemake),
        M("31-020", "A non-symbolic TrueType font's Encoding dictionary has no base encoding.", FontRemake),
        M("31-021", "A non-symbolic TrueType font's encoding is neither WinAnsi nor MacRoman.", FontRemake),
        M("31-022", "A non-symbolic TrueType font's Differences use glyph names outside the Adobe Glyph List.", FontRemake),
        N("31-023", "A non-symbolic TrueType font has Differences but no Windows Unicode cmap.", "Not checked yet (veraPDF's PDF/UA-1 rules don't either)."),
        M("31-024", "A symbolic TrueType font has an Encoding.", FontRemake),
        M("31-025", "A symbolic TrueType font has no character map (cmap).", FontRemake),
        M("31-026", "A symbolic TrueType font has several character maps but no Windows Symbol (3,0) one.", FontRemake),
        M("31-027", "A font doesn't say which characters its glyphs are (no ToUnicode, no standard encoding).", FontRemake),
        M("31-028", "A font's ToUnicode map gives a character the value 0.", FontRemake),
        M("31-029", "A font's ToUnicode map gives a character the value U+FEFF or U+FFFE.", FontRemake),
        M("31-030", "Text draws the .notdef glyph (a placeholder box).", FontFix),
    ];

    private static readonly Dictionary<string, AccessibilityCondition> ById = Conditions.ToDictionary(c => c.Id);

    /// <summary>The condition with this id, or null.</summary>
    public static AccessibilityCondition? Condition(string id) => ById.GetValueOrDefault(id);

    /// <summary>The checks for a person, in the order to do them.</summary>
    public static readonly IReadOnlyList<HumanCheck> HumanChecks =
    [
        new("title", ["06-004"], "Does the title say what the document is?",
            "File › Document Properties › Title. A file name or “Document1” isn't a title."),
        new("reading-order", ["09-001", "28-001", "22-001"], "Is the reading order sensible?",
            "Turn on Read Aloud (Ctrl+Shift+Y) or a screen reader and listen to a few pages: columns, sidebars, captions and footnotes should come where a reader expects them."),
        new("tags-fit", ["01-006", "09-002", "09-003", "02-002", "28-003"], "Does each tag fit its content?",
            "Headings are tagged as headings, lists as lists, tables as tables, quotes as quotes; nothing is a heading just to look big."),
        new("artifacts", ["01-001", "01-002", "18-001", "18-002"], "Are decorations artifacts, and is all real content tagged?",
            "Page numbers, running headers and footers, background shapes and lines are artifacts (marked Header or Footer where they are). Nothing a reader needs is an artifact."),
        new("alt-text", ["13-001", "13-002", "13-005", "13-006", "13-007", "13-008"], "Does every meaningful picture have alternate text that says what it shows?",
            "Read each figure's alternate text: it says what the picture shows or means, not “image1.png”. Decorative pictures are artifacts instead. Pictures that only mean something together are one figure."),
        new("captions", ["13-003"], "Are captions tagged as captions?", "A figure's or table's caption is a Caption tag inside it, not a separate paragraph."),
        new("color", ["04-001"], "Is anything said by color, contrast or layout alone, and is there enough contrast?",
            "“Fields in red are required” needs words too. Text needs a contrast of at least 4.5:1 with its background (3:1 for large text); check with a contrast tool."),
        new("headings", ["14-001", "14-004", "14-005"], "Are all headings tagged, at the right level?",
            "Every visual heading is an H1-H6 tag at the level it looks; a seventh level uses H7."),
        new("tables", ["15-001", "15-002", "15-004", "15-005"], "Do tables have their header cells marked, and are only real tables tagged as tables?",
            "Header rows and columns are TH cells; layout grids aren't tables; each data cell's header can be told."),
        new("lists", ["16-001", "16-002", "16-003"], "Are lists tagged as lists, numbered lists with their numbering?",
            "Bulleted and numbered lists are L tags; a numbered list says its numbering (Decimal, UpperRoman, …)."),
        new("language", ["11-007"], "Is the declared language right, also for passages in another language?",
            "The document's language should be the language it is written in; quotes in another language carry their own language on their tags."),
        new("ocr", ["08-001", "08-002"], "If pages were scanned, is the recognized text right and tagged?",
            "Select text on scanned pages (or listen with Read Aloud): it matches the page and is in the tags."),
        new("notes", ["19-001", "19-002", "17-001", "12-001"], "Are notes, references and formulas tagged as such?",
            "Footnotes and endnotes are Note tags, references Reference tags, math Formula tags with alternate text."),
        new("media", ["03-001", "03-002", "03-003", "05-001", "05-002", "05-003", "29-001", "28-013"], "Do sounds, videos and scripts have another way, and does nothing flicker?",
            "Media has captions or a transcript; nothing flashes more than three times a second; scripts don't need timed key presses; image maps' links are also listed."),
        new("forms", ["24-001", "31-010"], "Are printed (non-interactive) forms tagged, and are the fonts allowed to be embedded?",
            "Form-like layouts without fields use PrintField attributes; the fonts' licences allow embedding (most fonts do)."),
    ];
}
