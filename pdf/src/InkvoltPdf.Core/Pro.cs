using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.Core;

/// <summary>The features Inkvolt Pro unlocks (ROADMAP.md, "Free and Pro").</summary>
public enum ProFeature
{
    /// <summary>Saving, importing and exporting batch presets (Batch itself stays free).</summary>
    BatchPresets,

    /// <summary>Watched folders, in the app and from the command line.</summary>
    WatchedFolders,

    /// <summary><c>inkvoltpdf --batch</c> and <c>--watch</c>.</summary>
    CommandLine,
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
        ProFeature.BatchPresets => "Batch presets",
        ProFeature.WatchedFolders => "Watched folders",
        _ => "Command line",
    };

    /// <summary>What the feature does, for a person who hasn't unlocked it.</summary>
    public static string Describe(ProFeature feature) => feature switch
    {
        ProFeature.BatchPresets => "Save the list of Batch actions with their settings under a name and pick it next time; export a preset to share it or for the command line, import one from someone else.",
        ProFeature.WatchedFolders => "Drop PDFs or images into a folder and Inkvolt PDF runs a preset on each one once it has finished copying, moves the original to \"done\" or \"failed\" and logs a line for it.",
        _ => "inkvoltpdf --batch runs a preset on files or folders without a window; inkvoltpdf --watch watches a folder from a terminal or a scheduled task.",
    };

    /// <summary>What a person is told when a feature isn't unlocked.</summary>
    public static string Locked(ProFeature feature) => feature switch
    {
        ProFeature.BatchPresets => "Saved batch presets are part of Inkvolt Pro.",
        ProFeature.WatchedFolders => "Watched folders are part of Inkvolt Pro.",
        _ => "The command line is part of Inkvolt Pro.",
    };

    /// <summary>Where to get a key and where to enter it (after <see cref="Locked"/> on the command line).</summary>
    public static string HowToGet => $"Inkvolt Pro is a one-time purchase ({PriceText}) at {BuyUrl}; Help › Inkvolt Pro… in Inkvolt PDF enters the key.";
}
