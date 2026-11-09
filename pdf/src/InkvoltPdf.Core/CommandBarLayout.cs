namespace InkvoltPdf.Core;

/// <summary>
/// The document command bar, as Fluent 2 lays one out: a few primary commands with their labels, grouped in the order
/// people coming from Nitro, Foxit and Acrobat know (save and undo; the pointer tools; Edit, Convert; Comment, Fill &amp;
/// Sign; Organize, Protect, Scan &amp; OCR: docs/design/command-bar.md), and a "…" overflow that keeps the labels. Each
/// group is one labeled button that drops a flyout of its commands, its main job first; the rest of the old bar's
/// icons (rotate, delete pages, find) are secondary and always in the overflow. The command palette and the
/// menus list every command, so nothing here is the only way to reach anything.
/// </summary>
public static class CommandBarLayout
{
    /// <summary>
    /// One command of a group: the <c>Cmd</c> field it runs, its icon (Segoe Fluent Icons), page-view letter key, and the
    /// line under its name in the group's flyout, saying in a few plain words what it does.
    /// </summary>
    /// <remarks><paramref name="Title"/>: the name in the flyout when the command's own (menu) name would repeat the
    /// group's (Convert › "Word (.docx)", not "Export to Word…"). <paramref name="AtOnce"/>: the flyout runs it with
    /// <see cref="RunAtOnce"/>, no questions (Shift asks). <paramref name="IconBrush"/>: the resource key its icon is drawn
    /// with when defined (one per file type, so Convert's icons can take the formats' colors); unset, the text color.
    /// <paramref name="StartsSection"/>: a line above it in the flyout, setting the rarer or riskier commands apart.</remarks>
    public sealed record Command(string Name, string Glyph, string? Key = null, string Description = "", string? Title = null,
        bool AtOnce = false, string? IconBrush = null, bool StartsSection = false);

    /// <summary>
    /// The parameter a command gets from a group's main-job button (and Convert's at-once items): run with the defaults,
    /// asking only for what can't be defaulted (a password, a signature not made yet). Shift held asks as the menus do.
    /// </summary>
    public const string RunAtOnce = "AtOnce";

    /// <summary>
    /// Whether a command run with <paramref name="parameter"/> goes at once: <see cref="RunAtOnce"/>, and Shift not held
    /// (Shift+click asks). Both a command's enabling and its running ask this, so they agree.
    /// </summary>
    public static bool RunsAtOnce(object? parameter, bool shift) => parameter is RunAtOnce && !shift;

    /// <summary>
    /// Under this many logical DIPs (the window's width over Windows' Text size) the bar's right end makes room: the
    /// palette button shows its icon only (Ctrl+K and its tooltip stay) and Appearance moves into "…". At Text size 150 %
    /// a 1200-DIP window is 800 here.
    /// </summary>
    public const double RoomyWidth = 1100;

    /// <summary>
    /// A place on the bar. <see cref="Priority"/>: when room runs short the lowest goes into the overflow first (on a tie,
    /// the later one). <see cref="Label"/> null: an icon whose meaning is universal (save, print, undo, redo).
    /// </summary>
    public sealed record Entry(string Id, string? Label, int Priority, IReadOnlyList<Command> Commands, string? Glyph = null)
    {
        /// <summary>A labeled button that drops a menu of its commands, rather than running one.</summary>
        public bool IsGroup => Commands.Count > 1;

        /// <summary>
        /// A split button: its body runs <see cref="Main"/> at once (<see cref="RunAtOnce"/>), its arrow (or Alt+Down)
        /// drops the flyout. The pointer group has no main job: it shows the tool in use and only drops its menu.
        /// </summary>
        public bool HasMainJob => IsGroup && Id != Pointer;

        /// <summary>The group's main job: its first command.</summary>
        public Command Main => Commands[0];
    }

    /// <summary>Priority from which a command keeps the bar labeled: if one of these would overflow with labels, the bar goes icons-only first.</summary>
    public const int KeepsLabels = 80;

    /// <summary>The pointer tools' group (labeled with the tool in use).</summary>
    public const string Pointer = "Pointer";
    /// <summary>The group whose flyout ends with the drawing tools (a Draw submenu: Foxit's Comment › Drawing).</summary>
    public const string DrawsIn = "Comment";

    /// <summary>
    /// Fill &amp; Sign's priority: a key group (it keeps the bar labeled) in English; in Spanish, where "Llenar y firmar" is
    /// the bar's longest label, under <see cref="KeepsLabels"/>, so it goes into "…" before the other labels do.
    /// </summary>
    public static int FillSignPriority(System.Globalization.CultureInfo culture) => culture.TwoLetterISOLanguageName == "es" ? 75 : 86;

    /// <summary>The bar, left to right; null is a separator between groups.</summary>
    public static IReadOnlyList<Entry?> Bar => BarTable.Value;

    private static readonly PerLanguage<IReadOnlyList<Entry?>> BarTable = new(() =>
    [
        new("Save", null, 100, [new("Save", "\uE74E")]),
        // Print (Ctrl+P, File › Print) and Redo (Ctrl+Y, Edit › Redo) give way to the groups when room is short, Redo first:
        // at 1280 DIPs Select, Edit, Convert, Comment and Fill & Sign keep their labels and these two go into "…".
        new("Print", null, 55, [new("Print", "\uE749")]),
        new("Undo", null, 100, [new("Undo", "\uE7A7")]),
        new("Redo", null, 45, [new("Redo", "\uE7A6")]),
        null,
        // Icons only (Hand, Select and Snapshot are known by their icons, as in Acrobat and Foxit): its label shows only in
        // "…". Under KeepsLabels, so where room is short it goes into "…" (H, T and G still pick the tools) before Edit,
        // Convert, Comment and Fill & Sign lose their labels (the owner, 2026-11-08).
        new(Pointer, PdfStrings.Bar_Select, 79,
            [new("ToolHand", "\uE7C9", "H", PdfStrings.Bar_HandDesc),
             new("ToolSelect", "\uE8E9", "T", PdfStrings.Bar_SelectDesc),
             new("ToolSnapshot", "\uE722", "G", PdfStrings.Bar_SnapshotDesc)]),
        null,
        // The groups in the order Nitro, Foxit and Acrobat put them (docs/design/command-bar.md): Edit and Convert first,
        // then Comment and Fill & Sign, the pages, Protect, and Scan & OCR. Each group's first command is its main job.
        new("Edit", PdfStrings.Bar_Edit, 84,
            [new("EditContent", "\uE70F", Description: PdfStrings.Bar_EditContentDesc),
             new("AddImage", "\uE91B", "I", PdfStrings.Bar_ImageDesc),
             new("ToolLink", "\uE71B", "N", PdfStrings.Bar_LinkDesc),
             new("AddHeaderFooter", "\uE7C3", Description: PdfStrings.Bar_HeaderFooterDesc, StartsSection: true),
             new("AddWatermark", "\uE8A5", Description: PdfStrings.Bar_WatermarkDesc)], "\uE70F"),
        // The editable formats run at once (name.docx next to the PDF, opened); pictures and PDF/A ask, as in the menus.
        new("Convert", PdfStrings.Bar_Convert, 90,
            [new("ExportWord", "\uE8A5", Description: PdfStrings.Bar_ToWordDesc, Title: PdfStrings.Bar_ToWord, AtOnce: true, IconBrush: "FormatWordBrush"),
             new("ExportExcel", "\uE80A", Description: PdfStrings.Bar_ToExcelDesc, Title: PdfStrings.Bar_ToExcel, AtOnce: true, IconBrush: "FormatExcelBrush"),
             new("ExportPowerPoint", "\uE7F4", Description: PdfStrings.Bar_ToPowerPointDesc, Title: PdfStrings.Bar_ToPowerPoint, AtOnce: true, IconBrush: "FormatPowerPointBrush"),
             new("ExportText", "\uE8C1", Description: PdfStrings.Bar_ToTextDesc, Title: PdfStrings.Bar_ToText, AtOnce: true, IconBrush: "FormatTextBrush", StartsSection: true),
             new("ExportHtml", "\uE774", Description: PdfStrings.Bar_ToHtmlDesc, Title: PdfStrings.Bar_ToHtml, AtOnce: true, IconBrush: "FormatHtmlBrush"),
             new("ExportImages", "\uE91B", Description: PdfStrings.Bar_ToImagesDesc, Title: PdfStrings.Bar_ToImages, IconBrush: "FormatImagesBrush"),
             new("SaveAsPdfA", "\uE7B8", Description: PdfStrings.Bar_ToPdfADesc, Title: PdfStrings.Bar_ToPdfA, IconBrush: "FormatPdfABrush", StartsSection: true)], "\uEDE1"),
        new("Comment", PdfStrings.Bar_Comment, 80,
            [new("Highlight", "\uE7E6", Description: PdfStrings.Bar_HighlightDesc, AtOnce: true), // no selection: the highlighter
             new("Underline", "\uE8DC", Description: PdfStrings.Bar_UnderlineDesc),
             new("StrikeOut", "\uE738", Description: PdfStrings.Bar_StrikeOutDesc),
             new("AddNote", "\uE90A", Description: PdfStrings.Bar_NoteDesc),
             new("AddStamp", "\uEB95", "S", PdfStrings.Bar_StampDesc)], "\uE7E6"),
        // "Llenar y firmar" is the bar's longest label: in Spanish Fill & Sign goes into "\u2026" before the bar drops its
        // labels (the owner, 2026-11-08), rather than shortening it.
        new("FillSign", PdfStrings.Bar_FillSign, FillSignPriority(PdfLanguage.Culture),
            [new("AddSignature", "\uE76D", Description: PdfStrings.Bar_SignatureDesc),
             new("ToolAddText", "\uE8D2", "A", PdfStrings.Bar_AddTextDesc, StartsSection: true),
             new("ToolCheck", "\uE73E", "K", PdfStrings.Bar_CheckDesc),
             new("ToolCross", "\uE711", "X", PdfStrings.Bar_CrossDesc),
             new("PrepareForm", "\uE8A9", Description: PdfStrings.Bar_PrepareFormDesc, StartsSection: true)], "\uE76D"),
        new("Organize", PdfStrings.Bar_Organize, 70,
            [new("Organize", "\uE8B3", Description: PdfStrings.Bar_OrganizeDesc),
             new("InsertPages", "\uE8B5", Description: PdfStrings.Bar_InsertPagesDesc),
             new("ExtractPages", "\uEDE1", Description: PdfStrings.Bar_ExtractPagesDesc),
             new("SplitDocument", "\uE8C6", Description: PdfStrings.Bar_SplitDesc),
             new("Combine", "\uE8F1", Description: PdfStrings.Bar_CombineDesc, StartsSection: true),
             new("ReduceSize", "\uE73F", Description: PdfStrings.Bar_ReduceSizeDesc)], ""),
        new("Protect", PdfStrings.Bar_Protect, 60,
            [new("ProtectPassword", "\uE72E", Description: PdfStrings.Bar_PasswordDesc, AtOnce: true),
             new("Redact", "\uE73B", Description: PdfStrings.Bar_RedactDesc, AtOnce: true, StartsSection: true),
             new("ApplyRedactions", "", Description: PdfStrings.Bar_ApplyRedactionsDesc, IconBrush: "ApplyRedactionsBrush"), // the bar's only red
             new("RedactPatterns", "\uE721", Description: PdfStrings.Bar_RedactPatternsDesc),
             new("CheckRedaction", "\uE9D5", Description: PdfStrings.Bar_CheckRedactionDesc),
             new("Sanitize", "\uE74D", Description: PdfStrings.Bar_SanitizeDesc),
             new("Sign", "\uEB68", Description: PdfStrings.Bar_DigitalSignDesc, StartsSection: true),
             new("RemoveProtection", "\uE785", Description: PdfStrings.Bar_RemoveProtectionDesc, StartsSection: true)], ""),
        new("ScanOcr", PdfStrings.Bar_ScanOcr, 50,
            [new("RecognizeText", "\uE8C1", Description: PdfStrings.Bar_RecognizeDesc, AtOnce: true),
             new("Scan", "\uE8FE", Description: PdfStrings.Bar_ScanDesc),
             new("InsertFromScanner", "\uE8B5", Description: PdfStrings.Bar_ScanInsertDesc),
             new("ReviewSuspectWords", "\uE8FB", Description: PdfStrings.Bar_SuspectWordsDesc, StartsSection: true)], ""),
    ]);

    /// <summary>Always in the overflow, after what didn't fit: page commands and the rest of the old bar.</summary>
    public static readonly IReadOnlyList<Command> Secondary =
    [
        new("RotateLeft", "\uE7AD"), new("RotateRight", "\uE7AD"), new("DeleteSelected", "\uE74D"),
        new("Find", "\uE721"),
    ];

    public static Entry Group(string id) => Bar.First(e => e?.Id == id)!;

    /// <summary>Every command the bar reaches, on the bar or in a group or the overflow (the drawing tools, in a submenu of <see cref="DrawsIn"/>, aside).</summary>
    public static IEnumerable<string> AllCommands =>
        Bar.OfType<Entry>().SelectMany(e => e.Commands).Concat(Secondary).Select(c => c.Name);

    // ── Fitting ──

    /// <summary>A child of the bar: its width with its label and without, its priority; or a separator.</summary>
    public readonly record struct Item(double Full, double Compact, int Priority, bool IsSeparator = false);

    /// <summary>What shows: labels or icons only, each child, and the overflow button.</summary>
    public sealed record Fit(bool Compact, bool[] Shown, bool MoreShown);

    /// <summary>
    /// Lays the bar out in <paramref name="available"/> width: with labels, dropping the lowest priority into the
    /// overflow until it fits; icons-only instead when that would drop a command of priority
    /// <paramref name="keepsLabels"/> or more. A separator shows only between two shown commands, never two in a row.
    /// The overflow button (<paramref name="more"/> wide) shows when something overflowed or <paramref name="moreAlways"/>.
    /// </summary>
    public static Fit Layout(IReadOnlyList<Item> items, double available, double more, bool moreAlways = false, int keepsLabels = int.MinValue)
    {
        var labeled = Place(items, available, more, moreAlways, compact: false);
        var dropsKey = items.Where((it, i) => !it.IsSeparator && !labeled[i] && it.Priority >= keepsLabels).Any();
        var compact = dropsKey && items.Any(it => !it.IsSeparator && it.Compact < it.Full);
        var shown = compact ? Place(items, available, more, moreAlways, compact: true) : labeled;
        var hidden = items.Where((it, i) => !it.IsSeparator && !shown[i]).Any();
        return new Fit(compact, shown, hidden || moreAlways);
    }

    private static bool[] Place(IReadOnlyList<Item> items, double available, double more, bool moreAlways, bool compact)
    {
        var shown = items.Select(it => !it.IsSeparator).ToArray();
        while (true)
        {
            ShowSeparators(items, shown);
            var hidden = items.Where((it, i) => !it.IsSeparator && !shown[i]).Any();
            var width = items.Where((_, i) => shown[i]).Sum(it => compact ? it.Compact : it.Full) + (hidden || moreAlways ? more : 0);
            if (width <= available) return shown;
            var drop = -1;
            for (var i = 0; i < items.Count; i++)
                if (!items[i].IsSeparator && shown[i] && (drop < 0 || items[i].Priority <= items[drop].Priority)) drop = i;
            if (drop < 0) return shown;
            shown[drop] = false;
        }
    }

    private static void ShowSeparators(IReadOnlyList<Item> items, bool[] shown)
    {
        var any = false;
        var pending = -1;
        for (var i = 0; i < items.Count; i++)
        {
            if (items[i].IsSeparator)
            {
                shown[i] = false;
                if (any) pending = i;
            }
            else if (shown[i])
            {
                if (pending >= 0) shown[pending] = true;
                pending = -1;
                any = true;
            }
        }
    }
}
