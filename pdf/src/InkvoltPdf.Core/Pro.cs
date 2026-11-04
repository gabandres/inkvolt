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
    /// <summary>Certifying with a choice of form fields to lock: all, these, or all but these (certifying itself stays free).</summary>
    FieldLocking,
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
        ProFeature.PatternRedaction => PdfStrings.Pro_TitlePatternRedaction,
        ProFeature.BatchPresets => PdfStrings.Pro_TitleBatchPresets,
        ProFeature.WatchedFolders => PdfStrings.Pro_TitleWatchedFolders,
        ProFeature.AutoTagging => PdfStrings.Pro_TitleAutoTagging,
        ProFeature.ReadingOrder => PdfStrings.Pro_TitleReadingOrder,
        ProFeature.AccessibleOutput => PdfStrings.Pro_TitleAccessibleOutput,
        ProFeature.LongTermValidation => PdfStrings.Pro_TitleLtv,
        ProFeature.FolderSearch => PdfStrings.Pro_TitleFolderSearch,
        ProFeature.CompareOfficeAndScans => PdfStrings.Pro_TitleCompare,
        ProFeature.FieldLocking => PdfStrings.Pro_TitleFieldLocking,
        _ => PdfStrings.Pro_TitleCommandLine,
    };

    /// <summary>What the feature does, for a person who hasn't unlocked it.</summary>
    public static string Describe(ProFeature feature) => feature switch
    {
        ProFeature.PatternRedaction => PdfStrings.Pro_DescPatternRedaction,
        ProFeature.BatchPresets => PdfStrings.Pro_DescBatchPresets,
        ProFeature.WatchedFolders => PdfStrings.Pro_DescWatchedFolders,
        ProFeature.AutoTagging => PdfStrings.Pro_DescAutoTagging,
        ProFeature.ReadingOrder => PdfStrings.Pro_DescReadingOrder,
        ProFeature.AccessibleOutput => PdfStrings.Pro_DescAccessibleOutput,
        ProFeature.LongTermValidation => PdfStrings.Pro_DescLtv,
        ProFeature.CompareOfficeAndScans => PdfStrings.Pro_DescCompare,
        ProFeature.FieldLocking => PdfStrings.Pro_DescFieldLocking,
        ProFeature.FolderSearch => PdfStrings.Pro_DescFolderSearch,
        _ => PdfStrings.Pro_DescCommandLine,
    };

    /// <summary>What a person is told when a feature isn't unlocked.</summary>
    public static string Locked(ProFeature feature) => feature switch
    {
        ProFeature.PatternRedaction => PdfStrings.Pro_LockedPatternRedaction,
        ProFeature.BatchPresets => PdfStrings.Pro_LockedBatchPresets,
        ProFeature.WatchedFolders => PdfStrings.Pro_LockedWatchedFolders,
        ProFeature.AutoTagging => PdfStrings.Pro_LockedAutoTagging,
        ProFeature.ReadingOrder => PdfStrings.Pro_LockedReadingOrder,
        ProFeature.AccessibleOutput => PdfStrings.Pro_LockedAccessibleOutput,
        ProFeature.LongTermValidation => PdfStrings.Pro_LockedLtv,
        ProFeature.FolderSearch => PdfStrings.Pro_LockedFolderSearch,
        ProFeature.FieldLocking => PdfStrings.Pro_LockedFieldLocking,
        ProFeature.CompareOfficeAndScans => PdfStrings.Pro_LockedCompare,
        _ => PdfStrings.Pro_LockedCommandLine,
    };

    /// <summary>Where to get a key and where to enter it (after <see cref="Locked"/> on the command line).</summary>
    public static string HowToGet => Loc.Format(PdfStrings.Pro_HowToGet, PriceText, BuyUrl);
}
