using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.Core;

/// <summary>The features Inkvolt Pro unlocks (ROADMAP.md, "Free and Pro").</summary>
public enum ProFeature
{
    /// <summary>Redaction by pattern beyond the built-in kinds on the open document: saved sets, your own regular expression, the Batch action, the removal report.</summary>
    PatternRedaction,

    /// <summary>Saving, importing and exporting batch presets (Batch itself stays free).</summary>
    BatchPresets,

    /// <summary>Watched folders, in the app and from the command line.</summary>
    WatchedFolders,

    /// <summary><c>inkvoltpdf --batch</c> and <c>--watch</c>.</summary>
    CommandLine,

    /// <summary>Make Accessible: tagging a PDF from its layout, in the app and in Batch (viewing tags and alt text stays free).</summary>
    AutoTagging,

    /// <summary>The Reading order pane's fixes: moving pieces, changing their kind, applying the edited tags.</summary>
    ReadingOrder,

    /// <summary>Save as PDF/A-2a (tagged, PDF/UA identifier kept), in the app and in Batch.</summary>
    AccessibleOutput,

    /// <summary>Adding long-term validation data and document timestamps, when signing and to signed files (verifying stays free).</summary>
    LongTermValidation,
    /// <summary>Comparing Office files and scans, recognized first, and listing formatting changes (comparing two PDFs, moves, the overlay and the annotated copy stay free).</summary>
    CompareOfficeAndScans,
    /// <summary>Indexing folders and searching them (Find and the Search pane on open documents stay free).</summary>
    FolderSearch,
}

/// <summary>
/// The Pro entitlement check: the one place that decides whether a Pro feature runs. Every Pro feature asks
/// <see cref="Allows"/> and nowhere else. Behind it is the suite's <see cref="ProCheck"/> for the "pdf" product: the key
/// format, its verification, the gate (<see cref="ProCheck.Enforced"/>) and the store are shared with Inkvolt Print, so
/// one key listing both products licenses both apps, from wherever it was entered. Removing it never takes away a result
/// already made: presets saved, files a watched folder or the command line produced and their logs stay where they are.
/// </summary>
public static class Pro
{
    /// <summary>The one switch, shared with Inkvolt Print (<see cref="ProCheck.Enforced"/> says when it flips). Tests set it either way.</summary>
    public static bool Enforced
    {
        get => ProCheck.Enforced;
        internal set => ProCheck.Enforced = value;
    }

    public const string Product = ProKeys.ProductPdf;
    public const string PriceText = ProCheck.PriceText;
    public const string BuyUrl = ProCheck.BuyUrl;

    private static readonly ProCheck Check = new(Product);

    /// <summary>Where the key is kept. Setting it forgets what was read from the previous store.</summary>
    public static IProStore Store
    {
        get => Check.Store;
        set => Check.Store = value;
    }

    /// <summary>The installed licence, or null (none, or the stored key no longer checks out: <see cref="Problem"/>).</summary>
    public static ProLicence? Licence => Check.Licence;

    /// <summary>Why the stored key doesn't count, when there is one and it doesn't; null otherwise.</summary>
    public static string? Problem => Check.Problem;

    /// <summary>True when <paramref name="feature"/> may run: always while <see cref="Enforced"/> is off, else with a licence.</summary>
    public static bool Allows(ProFeature feature) => Check.Allowed;

    /// <summary>Checks <paramref name="key"/>, keeps it in the <see cref="Store"/> and returns its licence; refuses with a reason.</summary>
    public static ProLicence Install(string key) => Check.Install(key);

    /// <summary>Forgets the key. What the Pro features made stays.</summary>
    public static void Remove() => Check.Remove();

    /// <summary>The feature's name as the window shows it.</summary>
    public static string Title(ProFeature feature) => feature switch
    {
        ProFeature.PatternRedaction => "Pattern redaction",
        ProFeature.BatchPresets => "Batch presets",
        ProFeature.WatchedFolders => "Watched folders",
        ProFeature.AutoTagging => "Make Accessible",
        ProFeature.ReadingOrder => "Reading order",
        ProFeature.AccessibleOutput => "Accessible PDF/A-2a",
        ProFeature.LongTermValidation => "Long-term validation",
        ProFeature.FolderSearch => "Folder search",
        ProFeature.CompareOfficeAndScans => "Compare Office files and scans",
        _ => "Command line",
    };

    /// <summary>What the feature does, for a person who hasn't unlocked it.</summary>
    public static string Describe(ProFeature feature) => feature switch
    {
        ProFeature.PatternRedaction => "Save your own sets of patterns and phrases on this PC, search with your own regular expression, redact a set over a whole folder in Batch, and get a report per file of each removal's page, pattern and masked value.",
        ProFeature.BatchPresets => "Save the list of Batch actions with their settings under a name and pick it next time; export a preset to share it or for the command line, import one from someone else.",
        ProFeature.WatchedFolders => "Drop PDFs or images into a folder and Inkvolt PDF runs a preset on each one once it has finished copying, moves the original to \"done\" or \"failed\" and logs a line for it.",
        ProFeature.AutoTagging => "Tag a PDF for screen readers on this PC, nothing sent anywhere: headings, paragraphs, lists, tables and pictures read from the pages, running headers and page numbers set aside, the title and language set; in Batch over many files too.",
        ProFeature.ReadingOrder => "See the order a screen reader follows as numbered boxes on the page, move pieces up, down or to another page, change what a piece is, and write the tags again.",
        ProFeature.AccessibleOutput => "Save a tagged PDF as PDF/A-2a, the archival format that keeps the tags and says it is accessible (PDF/UA); in Batch too.",
        ProFeature.LongTermValidation => "Keep signatures checkable for decades: store in the file the proof that each certificate was good when it signed (PAdES B-LT), add a document timestamp over it (B-LTA), and do the same for files signed earlier. You see which addresses are asked before anything goes online.",
        ProFeature.CompareOfficeAndScans => "Compare a Word, Excel or PowerPoint file or a scan with a PDF, the scan's words recognized on this PC, and see font, size, bold, italic and color changes listed apart from wording.",
        ProFeature.FolderSearch => "Index whole folders on this PC, nothing sent anywhere, and find a word across thousands of PDFs in under a second, with the text around each hit; a result opens at the hit, and the index keeps up as files change.",
        _ => "inkvoltpdf --batch runs a preset on files or folders without a window; inkvoltpdf --watch watches a folder from a terminal or a scheduled task.",
    };

    /// <summary>What a person is told when a feature isn't unlocked.</summary>
    public static string Locked(ProFeature feature) => feature switch
    {
        ProFeature.PatternRedaction => "Saved pattern sets, your own regular expression, pattern redaction in Batch and the removal report are part of Inkvolt Pro.",
        ProFeature.BatchPresets => "Saved batch presets are part of Inkvolt Pro.",
        ProFeature.WatchedFolders => "Watched folders are part of Inkvolt Pro.",
        ProFeature.AutoTagging => "Make Accessible is part of Inkvolt Pro.",
        ProFeature.ReadingOrder => "Fixing the reading order is part of Inkvolt Pro.",
        ProFeature.AccessibleOutput => "Saving accessible PDF/A-2a files is part of Inkvolt Pro.",
        ProFeature.LongTermValidation => "Adding long-term validation data is part of Inkvolt Pro.",
        ProFeature.FolderSearch => "Searching folders is part of Inkvolt Pro.",
        ProFeature.CompareOfficeAndScans => "Comparing Office files, scans and formatting is part of Inkvolt Pro.",
        _ => "The command line is part of Inkvolt Pro.",
    };

    /// <summary>Where to get a key and where to enter it (after <see cref="Locked"/> on the command line).</summary>
    public static string HowToGet => $"Inkvolt Pro is a one-time purchase ({PriceText}) at {BuyUrl}; Help › Inkvolt Pro… in Inkvolt PDF enters the key.";
}
