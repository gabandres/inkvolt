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
/// The Pro entitlement check: the one place that decides whether a Pro feature runs. Every Pro feature asks here and
/// nowhere else. The licence (a key signed with our Ed25519 key, checked on the PC, no server) isn't built yet, so
/// everything is allowed; when it comes, only <see cref="Allows"/> changes.
/// </summary>
public static class Pro
{
    /// <summary>True when <paramref name="feature"/> may run. Today always (no licence check yet).</summary>
    public static bool Allows(ProFeature feature) => true;

    /// <summary>What a person is told when a feature isn't unlocked.</summary>
    public static string Locked(ProFeature feature) => feature switch
    {
        ProFeature.BatchPresets => "Saved batch presets are part of Inkvolt Pro.",
        ProFeature.WatchedFolders => "Watched folders are part of Inkvolt Pro.",
        _ => "The command line is part of Inkvolt Pro.",
    };
}
