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
    public string Element { get; init; } = PdfStrings.A11y_Document;

    /// <summary>How many times the same thing happens here (content items of a page are counted, not listed one by one).</summary>
    public int Count { get; init; } = 1;

    /// <summary>What fixes it (the condition's own fix unless something more precise is known).</summary>
    public string Fix => FixOverride ?? AccessibilityCheck.Condition(Condition)?.Fix ?? "";

    /// <summary>A fix for this finding in particular.</summary>
    public string? FixOverride { get; init; }

    /// <summary>"Page 3", or "Document".</summary>
    public string Where => Page >= 0 ? Loc.Format(PdfStrings.A11y_PageN, Page + 1) : PdfStrings.A11y_Document;
}

/// <summary>A check a person makes (the machine can't tell whether alternate text means anything).</summary>
/// <param name="Id">A stable name ("reading-order"), for keeping ticks.</param>
/// <param name="Conditions">The Matterhorn conditions it covers.</param>
/// <param name="Question">What to check, as a question.</param>
/// <param name="How">How to check it with Inkvolt PDF (or a screen reader).</param>
public sealed record HumanCheck(string Id, IReadOnlyList<string> Conditions, string Question, string How);

/// <summary>What the check says of a document as a whole.</summary>
public enum AccessibilityOutcome
{
    /// <summary>Checked in full, and nothing fails (the person's checks are still to do).</summary>
    Passes,

    /// <summary>Something fails, whether or not all of it was checked.</summary>
    Fails,

    /// <summary>Nothing fails in what was checked, but part of it wasn't: a limit on a crafted or huge file, or something that couldn't be read.</summary>
    NotFullyChecked,
}

/// <summary>The checker's result for one document.</summary>
/// <param name="Failures">What fails, in checkpoint order, then by page.</param>
/// <param name="Notes">What couldn't be checked in this document, and why.</param>
/// <param name="Tagged">The document has a structure tree (tags).</param>
public sealed record AccessibilityReport(IReadOnlyList<AccessibilityFinding> Failures, IReadOnlyList<string> Notes, int Pages, bool Tagged)
{
    public AccessibilityOutcome Outcome =>
        Failures.Count > 0 ? AccessibilityOutcome.Fails : Notes.Count > 0 ? AccessibilityOutcome.NotFullyChecked : AccessibilityOutcome.Passes;

    /// <summary>All of it was checked and no machine-checkable condition fails (the person's checks are still to do).</summary>
    public bool Passed => Outcome == AccessibilityOutcome.Passes;

    /// <summary>The result in a few words: what the report's verdict and the log say.</summary>
    public string Verdict => Outcome switch
    {
        AccessibilityOutcome.Passes => PdfStrings.A11y_VerdictPasses,
        AccessibilityOutcome.NotFullyChecked => PdfStrings.A11y_VerdictNotFullyChecked,
        _ => PdfStrings.A11y_VerdictFails,
    };

    /// <summary>The conditions that fail, each once, in order.</summary>
    public IReadOnlyList<string> FailedConditions => [.. Failures.Select(f => f.Condition).Distinct().Order(StringComparer.Ordinal)];

    /// <summary>The checks for a person (the same for every document).</summary>
    public IReadOnlyList<HumanCheck> HumanChecks => AccessibilityCheck.HumanChecks;

    /// <summary>"Fails 4 conditions (12 problems): …", "Passes every machine check." or "Not fully checked: …"</summary>
    public string Summary
    {
        get
        {
            if (Outcome == AccessibilityOutcome.Passes)
                return Loc.Format(PdfStrings.A11y_SummaryPasses, AccessibilityCheck.Conditions.Count(c => c.How == ConditionCheck.Machine), AccessibilityCheck.HumanChecks.Count);
            if (Outcome == AccessibilityOutcome.NotFullyChecked)
                return PdfStrings.A11y_SummaryNotFullyChecked;
            var conditions = FailedConditions.Count;
            var problems = Failures.Count;
            var fails = conditions == 1
                ? Loc.Plural(problems, PdfStrings.A11y_SummaryFailsOneCondition_One, PdfStrings.A11y_SummaryFailsOneCondition_Many, conditions)
                : Loc.Plural(problems, PdfStrings.A11y_SummaryFails_One, PdfStrings.A11y_SummaryFails_Many, conditions);
            return fails + (Tagged ? "." : PdfStrings.A11y_SummaryUntaggedEnd) + (Notes.Count > 0 ? PdfStrings.A11y_SummaryPartNotChecked : "");
        }
    }

    /// <summary>The pane's line at the top: the result, and what couldn't be checked.</summary>
    public string PaneSummary =>
        (Passed ? PdfStrings.A11y_PanePasses : "") + Summary + (Notes.Count == 0 ? "" : Loc.Format(PdfStrings.A11y_PaneNotChecked, string.Join(" ", Notes)));

    /// <summary>The title of the pane's list of failures.</summary>
    public string FailuresTitle => Failures.Count > 0 ? Loc.Format(PdfStrings.A11y_FailsTitle, Failures.Count) : Passed ? PdfStrings.A11y_FailsTitleNone : PdfStrings.A11y_FailsTitleNoneSoFar;

    /// <summary>What the pane's list of failures says when it is empty.</summary>
    public string NothingFailsText => Passed
        ? PdfStrings.A11y_NothingFailsPassed
        : PdfStrings.A11y_NothingFailsPartial;
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
    public static IReadOnlyDictionary<string, string> Checkpoints => CheckpointTable.Value;

    private static readonly PerLanguage<IReadOnlyDictionary<string, string>> CheckpointTable = new(() => new Dictionary<string, string>
    {
        ["00"] = PdfStrings.A11y_Cp00,
        ["01"] = PdfStrings.A11y_Cp01,
        ["02"] = PdfStrings.A11y_Cp02,
        ["03"] = PdfStrings.A11y_Cp03,
        ["04"] = PdfStrings.A11y_Cp04,
        ["05"] = PdfStrings.A11y_Cp05,
        ["06"] = PdfStrings.A11y_Cp06,
        ["07"] = PdfStrings.A11y_Cp07,
        ["08"] = PdfStrings.A11y_Cp08,
        ["09"] = PdfStrings.A11y_Cp09,
        ["10"] = PdfStrings.A11y_Cp10,
        ["11"] = PdfStrings.A11y_Cp11,
        ["12"] = PdfStrings.A11y_Cp12,
        ["13"] = PdfStrings.A11y_Cp13,
        ["14"] = PdfStrings.A11y_Cp14,
        ["15"] = PdfStrings.A11y_Cp15,
        ["16"] = PdfStrings.A11y_Cp16,
        ["17"] = PdfStrings.A11y_Cp17,
        ["18"] = PdfStrings.A11y_Cp18,
        ["19"] = PdfStrings.A11y_Cp19,
        ["20"] = PdfStrings.A11y_Cp20,
        ["21"] = PdfStrings.A11y_Cp21,
        ["22"] = PdfStrings.A11y_Cp22,
        ["23"] = PdfStrings.A11y_Cp23,
        ["24"] = PdfStrings.A11y_Cp24,
        ["25"] = "XFA",
        ["26"] = PdfStrings.A11y_Cp26,
        ["27"] = PdfStrings.A11y_Cp27,
        ["28"] = PdfStrings.A11y_Cp28,
        ["29"] = PdfStrings.A11y_Cp29,
        ["30"] = "XObjects",
        ["31"] = PdfStrings.A11y_Cp31,
    });

    private static string Tag => PdfStrings.A11y_FixTag;

    private static string MakeArtifact => PdfStrings.A11y_FixArtifact;

    private static string Person => PdfStrings.A11y_FixPerson;

    private static string Language => PdfStrings.A11y_FixLanguage;

    private static string FontFix => PdfStrings.A11y_FixFont;

    private static string FontRemake => PdfStrings.A11y_FixFontRemake;

    private static AccessibilityCondition M(string id, string text, string fix) => new(id, id.StartsWith("UA", StringComparison.Ordinal) ? "00" : id[..2], text, ConditionCheck.Machine, fix);
    private static AccessibilityCondition H(string id, string text, string how) => new(id, id[..2], text, ConditionCheck.Human, how);
    private static AccessibilityCondition N(string id, string text, string note) => new(id, id[..2], text, ConditionCheck.NotChecked, "", note);

    /// <summary>Every condition, in order: the basic rules, then the Matterhorn Protocol's 137.</summary>
    public static IReadOnlyList<AccessibilityCondition> Conditions => ConditionTable.Value;

    private static readonly PerLanguage<IReadOnlyList<AccessibilityCondition>> ConditionTable = new(() =>
    [
        M("UA 7.1", PdfStrings.A11y_UA7_1, Tag),
        M("UA 6.2", PdfStrings.A11y_UA6_2, Tag),
        M("UA 6.1", PdfStrings.A11y_UA6_1, PdfStrings.A11y_UA6_1_Fix),
        M("UA 7.1-P", PdfStrings.A11y_UA7_1_P, PdfStrings.A11y_UA7_1_P_Fix),
        M("UA 7.2-Lang", PdfStrings.A11y_UA7_2_Lang, PdfStrings.A11y_UA7_2_Lang_Fix),

        H("01-001", PdfStrings.A11y_01_001, PdfStrings.A11y_01_001_How),
        H("01-002", PdfStrings.A11y_01_002, PdfStrings.A11y_01_002_How),
        M("01-003", PdfStrings.A11y_01_003, MakeArtifact),
        M("01-004", PdfStrings.A11y_01_004, MakeArtifact),
        M("01-005", PdfStrings.A11y_01_005, MakeArtifact),
        H("01-006", PdfStrings.A11y_01_006, Person),
        M("01-007", PdfStrings.A11y_01_007, PdfStrings.A11y_01_007_Fix),

        M("02-001", PdfStrings.A11y_02_001, PdfStrings.A11y_02_001_Fix),
        H("02-002", PdfStrings.A11y_02_002, Person),
        M("02-003", PdfStrings.A11y_02_003, PdfStrings.A11y_02_003_Fix),
        M("02-004", PdfStrings.A11y_02_004, PdfStrings.A11y_02_004_Fix),

        H("03-001", PdfStrings.A11y_03_001, Person),
        H("03-002", PdfStrings.A11y_03_002, Person),
        H("03-003", PdfStrings.A11y_03_003, Person),
        H("04-001", PdfStrings.A11y_04_001, Person),
        H("05-001", PdfStrings.A11y_05_001, Person),
        H("05-002", PdfStrings.A11y_05_002, Person),
        H("05-003", PdfStrings.A11y_05_003, Person),

        M("06-001", PdfStrings.A11y_06_001, PdfStrings.A11y_06_001_Fix),
        M("06-002", PdfStrings.A11y_06_002, PdfStrings.A11y_06_002_Fix),
        M("06-003", PdfStrings.A11y_06_003, PdfStrings.A11y_06_003_Fix),
        H("06-004", PdfStrings.A11y_06_004, Person),

        M("07-001", PdfStrings.A11y_07_001, PdfStrings.A11y_07_001_Fix),
        M("07-002", PdfStrings.A11y_07_002, PdfStrings.A11y_07_001_Fix),

        H("08-001", PdfStrings.A11y_08_001, Person),
        H("08-002", PdfStrings.A11y_08_002, Person),

        H("09-001", PdfStrings.A11y_09_001, Person),
        H("09-002", PdfStrings.A11y_09_002, Person),
        H("09-003", PdfStrings.A11y_09_003, Person),
        M("09-004", PdfStrings.A11y_09_004, PdfStrings.A11y_09_004_Fix),
        M("09-005", PdfStrings.A11y_09_005, PdfStrings.A11y_09_005_Fix),
        M("09-006", PdfStrings.A11y_09_006, PdfStrings.A11y_09_006_Fix),
        N("09-007", PdfStrings.A11y_09_007, PdfStrings.A11y_09_007_Note),
        N("09-008", PdfStrings.A11y_09_008, PdfStrings.A11y_09_008_Note),

        N("10-001", PdfStrings.A11y_10_001, PdfStrings.A11y_10_001_Note),

        M("11-001", PdfStrings.A11y_11_001, PdfStrings.A11y_FixLanguageOrTags),
        M("11-002", PdfStrings.A11y_11_002, Language),
        M("11-003", PdfStrings.A11y_11_003, Language),
        M("11-004", PdfStrings.A11y_11_004, Language),
        M("11-005", PdfStrings.A11y_11_005, Language),
        M("11-006", PdfStrings.A11y_11_006, Language),
        H("11-007", PdfStrings.A11y_11_007, Person),
        H("12-001", PdfStrings.A11y_12_001, Person),

        H("13-001", PdfStrings.A11y_13_001, Person),
        H("13-002", PdfStrings.A11y_13_002, Person),
        H("13-003", PdfStrings.A11y_13_003, Person),
        M("13-004", PdfStrings.A11y_13_004, PdfStrings.A11y_13_004_Fix),
        H("13-005", PdfStrings.A11y_13_005, Person),
        H("13-006", PdfStrings.A11y_13_006, Person),
        H("13-007", PdfStrings.A11y_13_007, Person),
        H("13-008", PdfStrings.A11y_13_008, Person),

        H("14-001", PdfStrings.A11y_14_001, Person),
        M("14-002", PdfStrings.A11y_14_002, PdfStrings.A11y_14_002_Fix),
        M("14-003", PdfStrings.A11y_14_003, PdfStrings.A11y_14_003_Fix),
        H("14-004", PdfStrings.A11y_14_004, Person),
        H("14-005", PdfStrings.A11y_14_005, Person),
        M("14-006", PdfStrings.A11y_14_006, PdfStrings.A11y_14_006_Fix),
        M("14-007", PdfStrings.A11y_14_007, PdfStrings.A11y_14_007_Fix),

        H("15-001", PdfStrings.A11y_15_001, Person),
        H("15-002", PdfStrings.A11y_15_002, Person),
        M("15-003", PdfStrings.A11y_15_003, PdfStrings.A11y_15_003_Fix),
        H("15-004", PdfStrings.A11y_15_004, Person),
        H("15-005", PdfStrings.A11y_15_005, Person),

        H("16-001", PdfStrings.A11y_16_001, Person),
        H("16-002", PdfStrings.A11y_16_002, Person),
        H("16-003", PdfStrings.A11y_16_003, Person),

        H("17-001", PdfStrings.A11y_17_001, Person),
        M("17-002", PdfStrings.A11y_17_002, PdfStrings.A11y_17_002_Fix),
        N("17-003", PdfStrings.A11y_17_003, PdfStrings.A11y_17_003_Note),

        H("18-001", PdfStrings.A11y_18_001, Person),
        H("18-002", PdfStrings.A11y_18_002, Person),

        H("19-001", PdfStrings.A11y_19_001, Person),
        H("19-002", PdfStrings.A11y_19_002, Person),
        M("19-003", PdfStrings.A11y_19_003, PdfStrings.A11y_19_003_Fix),
        M("19-004", PdfStrings.A11y_19_004, PdfStrings.A11y_19_004_Fix),

        M("20-001", PdfStrings.A11y_20_001, PdfStrings.A11y_20_001_Fix),
        M("20-002", PdfStrings.A11y_20_002, PdfStrings.A11y_20_002_Fix),
        M("20-003", PdfStrings.A11y_20_003, PdfStrings.A11y_20_003_Fix),

        M("21-001", PdfStrings.A11y_21_001, PdfStrings.A11y_21_001_Fix),
        H("22-001", PdfStrings.A11y_22_001, Person),
        new("23-001", "23", PdfStrings.A11y_23_001, ConditionCheck.NoTest, ""),
        H("24-001", PdfStrings.A11y_24_001, Person),
        M("25-001", PdfStrings.A11y_25_001, PdfStrings.A11y_25_001_Fix),
        M("26-001", PdfStrings.A11y_26_001, PdfStrings.A11y_26_001_Fix),
        M("26-002", PdfStrings.A11y_26_002, PdfStrings.A11y_26_002_Fix),
        new("27-001", "27", PdfStrings.A11y_27_001, ConditionCheck.NoTest, ""),

        H("28-001", PdfStrings.A11y_28_001, Person),
        M("28-002", PdfStrings.A11y_28_002, PdfStrings.A11y_28_002_Fix),
        H("28-003", PdfStrings.A11y_28_003, Person),
        M("28-004", PdfStrings.A11y_28_004, PdfStrings.A11y_28_004_Fix),
        M("28-005", PdfStrings.A11y_28_005, PdfStrings.A11y_28_005_Fix),
        N("28-006", PdfStrings.A11y_28_006, PdfStrings.A11y_28_006_Note),
        M("28-007", PdfStrings.A11y_28_007, PdfStrings.A11y_28_007_Fix),
        M("28-008", PdfStrings.A11y_28_008, PdfStrings.A11y_28_008_Fix),
        M("28-009", PdfStrings.A11y_28_009, PdfStrings.A11y_28_009_Fix),
        M("28-010", PdfStrings.A11y_28_010, PdfStrings.A11y_28_010_Fix),
        M("28-011", PdfStrings.A11y_28_011, PdfStrings.A11y_28_011_Fix),
        M("28-012", PdfStrings.A11y_28_012, PdfStrings.A11y_28_012_Fix),
        H("28-013", PdfStrings.A11y_28_013, Person),
        M("28-014", PdfStrings.A11y_28_014, PdfStrings.A11y_28_014_Fix),
        M("28-015", PdfStrings.A11y_28_015, PdfStrings.A11y_28_015_Fix),
        M("28-016", PdfStrings.A11y_28_016, PdfStrings.A11y_28_016_Fix),
        M("28-017", PdfStrings.A11y_28_017, PdfStrings.A11y_28_017_Fix),
        N("28-018", PdfStrings.A11y_28_018, PdfStrings.A11y_28_018_Note),
        H("29-001", PdfStrings.A11y_29_001, Person),

        M("30-001", PdfStrings.A11y_30_001, PdfStrings.A11y_30_001_Fix),
        M("30-002", PdfStrings.A11y_30_002, PdfStrings.A11y_30_002_Fix),

        M("31-001", PdfStrings.A11y_31_001, FontRemake),
        M("31-002", PdfStrings.A11y_31_002, FontRemake),
        M("31-003", PdfStrings.A11y_31_003, FontRemake),
        M("31-004", PdfStrings.A11y_31_004, FontRemake),
        M("31-005", PdfStrings.A11y_31_005, FontRemake),
        M("31-006", PdfStrings.A11y_31_006, FontRemake),
        M("31-007", PdfStrings.A11y_31_007, FontRemake),
        M("31-008", PdfStrings.A11y_31_008, FontRemake),
        M("31-009", PdfStrings.A11y_31_009, FontFix),
        H("31-010", PdfStrings.A11y_31_010, Person),
        M("31-011", PdfStrings.A11y_31_011, FontFix),
        M("31-012", PdfStrings.A11y_31_012, FontRemake),
        M("31-013", PdfStrings.A11y_31_013, FontRemake),
        M("31-014", PdfStrings.A11y_31_014, FontRemake),
        M("31-015", PdfStrings.A11y_31_015, FontRemake),
        M("31-016", PdfStrings.A11y_31_016, FontRemake),
        M("31-017", PdfStrings.A11y_31_017, FontRemake),
        N("31-018", PdfStrings.A11y_31_018, PdfStrings.A11y_31_018_Note),
        M("31-019", PdfStrings.A11y_31_019, FontRemake),
        M("31-020", PdfStrings.A11y_31_020, FontRemake),
        M("31-021", PdfStrings.A11y_31_021, FontRemake),
        M("31-022", PdfStrings.A11y_31_022, FontRemake),
        N("31-023", PdfStrings.A11y_31_023, PdfStrings.A11y_31_023_Note),
        M("31-024", PdfStrings.A11y_31_024, FontRemake),
        M("31-025", PdfStrings.A11y_31_025, FontRemake),
        M("31-026", PdfStrings.A11y_31_026, FontRemake),
        M("31-027", PdfStrings.A11y_31_027, FontRemake),
        M("31-028", PdfStrings.A11y_31_028, FontRemake),
        M("31-029", PdfStrings.A11y_31_029, FontRemake),
        M("31-030", PdfStrings.A11y_31_030, FontFix),
    ]);

    private static readonly PerLanguage<Dictionary<string, AccessibilityCondition>> ById = new(() => Conditions.ToDictionary(c => c.Id));

    /// <summary>The condition with this id, or null.</summary>
    public static AccessibilityCondition? Condition(string id) => ById.Value.GetValueOrDefault(id);

    /// <summary>The checks for a person, in the order to do them.</summary>
    public static IReadOnlyList<HumanCheck> HumanChecks => HumanCheckTable.Value;

    private static readonly PerLanguage<IReadOnlyList<HumanCheck>> HumanCheckTable = new(() =>
    [
        new("title", ["06-004"], PdfStrings.A11y_CheckTitle,
            PdfStrings.A11y_CheckTitleHow),
        new("reading-order", ["09-001", "28-001", "22-001"], PdfStrings.A11y_CheckReadingOrder,
            PdfStrings.A11y_CheckReadingOrderHow),
        new("tags-fit", ["01-006", "09-002", "09-003", "02-002", "28-003"], PdfStrings.A11y_CheckTagsFit,
            PdfStrings.A11y_CheckTagsFitHow),
        new("artifacts", ["01-001", "01-002", "18-001", "18-002"], PdfStrings.A11y_CheckArtifacts,
            PdfStrings.A11y_CheckArtifactsHow),
        new("alt-text", ["13-001", "13-002", "13-005", "13-006", "13-007", "13-008"], PdfStrings.A11y_CheckAltText,
            PdfStrings.A11y_CheckAltTextHow),
        new("captions", ["13-003"], PdfStrings.A11y_CheckCaptions, PdfStrings.A11y_CheckCaptionsHow),
        new("color", ["04-001"], PdfStrings.A11y_CheckColor,
            PdfStrings.A11y_CheckColorHow),
        new("headings", ["14-001", "14-004", "14-005"], PdfStrings.A11y_CheckHeadings,
            PdfStrings.A11y_CheckHeadingsHow),
        new("tables", ["15-001", "15-002", "15-004", "15-005"], PdfStrings.A11y_CheckTables,
            PdfStrings.A11y_CheckTablesHow),
        new("lists", ["16-001", "16-002", "16-003"], PdfStrings.A11y_CheckLists,
            PdfStrings.A11y_CheckListsHow),
        new("language", ["11-007"], PdfStrings.A11y_CheckLanguage,
            PdfStrings.A11y_CheckLanguageHow),
        new("ocr", ["08-001", "08-002"], PdfStrings.A11y_CheckOcr,
            PdfStrings.A11y_CheckOcrHow),
        new("notes", ["19-001", "19-002", "17-001", "12-001"], PdfStrings.A11y_CheckNotes,
            PdfStrings.A11y_CheckNotesHow),
        new("media", ["03-001", "03-002", "03-003", "05-001", "05-002", "05-003", "29-001", "28-013"], PdfStrings.A11y_CheckMedia,
            PdfStrings.A11y_CheckMediaHow),
        new("forms", ["24-001", "31-010"], PdfStrings.A11y_CheckForms,
            PdfStrings.A11y_CheckFormsHow),
    ]);
}
