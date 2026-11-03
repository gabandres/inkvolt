namespace InkvoltPrint.Core.Queues;

/// <summary>
/// Every word "Plugged in, needs its driver" shows: the interface's from <see cref="CoreStrings"/> (English and Spanish, as
/// <see cref="CoreLanguage"/> says), the command line's, status --all's, Report a problem's and the log's in English. Never a
/// serial, an instance id or a container id: only the name and the port.
/// </summary>
public static class NeedsDriverText
{
    private static string F(string format, params object?[] args) => string.Format(CoreLanguage.Culture, format, args);

    /// <summary>The accessible name of the sidebar's list of them.</summary>
    public static string ListName => CoreStrings.NeedsDriver_ListName;

    public static string ListStatusNoDriver => CoreStrings.NeedsDriver_ListStatusNoDriver;
    public static string ListStatusNotSetUp => CoreStrings.NeedsDriver_ListStatusNotSetUp;

    public static string ListStatus(NeedsDriverPrinter p) => p.Stage == DriverStage.NoDriver ? ListStatusNoDriver : ListStatusNotSetUp;

    /// <summary>The page's heading under the name.</summary>
    public static string Headline(NeedsDriverPrinter p) =>
        p.Stage == DriverStage.NoDriver ? CoreStrings.NeedsDriver_HeadlineNoDriver : CoreStrings.NeedsDriver_HeadlineNotSetUp;

    /// <summary>"USB (USB001)", or "USB".</summary>
    public static string Where(NeedsDriverPrinter p) => p.Port is { Length: > 0 } port ? F(CoreStrings.NeedsDriver_WherePort, port.TrimEnd(':')) : "USB";

    public static string WhyMakersDriver => CoreStrings.NeedsDriver_WhyMakersDriver;
    public static string StepsTitle => CoreStrings.NeedsDriver_StepsTitle;

    public static string StepGetDriver(NeedsDriverPrinter p) => p.Maker is { } maker && DriverHelp.HasDriverPage(maker)
        ? F(CoreStrings.NeedsDriver_StepGetDriverFromMaker, p.Name, maker) : F(CoreStrings.NeedsDriver_StepGetDriver, p.Name);

    public static string StepPlugIn => CoreStrings.NeedsDriver_StepPlugIn;
    public static string StepInstall => CoreStrings.NeedsDriver_StepInstall;

    public static string MakerButton(NeedsDriverPrinter p) => p.Maker is { } maker && DriverHelp.HasDriverPage(maker)
        ? F(CoreStrings.NeedsDriver_MakerButton, maker) : CoreStrings.NeedsDriver_SearchButton;

    public static string OtherWaysTitle => CoreStrings.NeedsDriver_OtherWaysTitle;
    public static string CheckWindowsButton => CoreStrings.NeedsDriver_CheckWindowsButton;
    public static string CheckWindowsNote => CoreStrings.NeedsDriver_CheckWindowsNote;
    public static string AddInWindowsButton => CoreStrings.NeedsDriver_AddInWindowsButton;
    public static string AddInWindowsNote => CoreStrings.NeedsDriver_AddInWindowsNote;
    public static string ProtectedPrintTitle => CoreStrings.NeedsDriver_ProtectedPrintTitle;

    /// <summary>What to say about Windows protected print mode: only when it's on (null when off).</summary>
    public static string? ProtectedPrint(bool on) => on ? CoreStrings.NeedsDriver_ProtectedPrintOn : null;

    // ---------------------------------------------------------------- set it up (a driver is installed)

    public static string SetUpButton => CoreStrings.NeedsDriver_SetUpButton;

    public static string SetUpNote(NeedsDriverPrinter p) => p.Driver is { } driver
        ? F(CoreStrings.NeedsDriver_SetUpNoteDriver, Where(p), driver) : CoreStrings.NeedsDriver_SetUpNoteNoDriver;

    public static string SetUpDone(string queue) => F(CoreStrings.NeedsDriver_SetUpDone, queue);

    public static string SetUpNeedsAdmin(NeedsDriverPrinter p) => p.Driver is { } d
        ? F(CoreStrings.NeedsDriver_SetUpNeedsAdminDriver, p.Port ?? "USB001", d) : F(CoreStrings.NeedsDriver_SetUpNeedsAdmin, p.Port ?? "USB001");

    public static string SetUpFailed(string why) => F(CoreStrings.NeedsDriver_SetUpFailed, why);

    public static string FailedNoPort => CoreStrings.NeedsDriver_FailedNoPort;
    public static string FailedUnknownPort(string port) => F(CoreStrings.NeedsDriver_FailedUnknownPort, port);
    public static string FailedUnknownDriver => CoreStrings.NeedsDriver_FailedUnknownDriver;
    public static string FailedNameTaken => CoreStrings.NeedsDriver_FailedNameTaken;

    public static string Demo => CoreStrings.NeedsDriver_Demo;

    // ---------------------------------------------------------------- the CLI, status --all, Report a problem and the log (English)

    /// <summary>"plugged in, needs its driver" or "driver installed, not set up": English whatever the interface's language.</summary>
    public static string EnglishStatus(NeedsDriverPrinter p) => p.Stage == DriverStage.NoDriver ? "plugged in, needs its driver" : "driver installed, not set up";

    private static string EnglishWhere(NeedsDriverPrinter p) => p.Port is { Length: > 0 } port ? $"USB ({port.TrimEnd(':')})" : "USB";

    /// <summary>"HP LaserJet P1006 | USB (USB001) | needs its driver": the CLI's <c>queues</c> line.</summary>
    public static string QueuesLine(NeedsDriverPrinter p) =>
        $"{p.Name} | {EnglishWhere(p)} | {(p.Stage == DriverStage.NoDriver ? "needs its driver" : $"driver installed, no queue{(p.Driver is { } d ? $" (driver: {d})" : "")}")}";

    /// <summary>status --all's note: the printer list shows it, the fleet has nothing to read from it.</summary>
    public static string StatusNote(NeedsDriverPrinter p) =>
        $"{p.Name} ({EnglishWhere(p)}): {(p.Stage == DriverStage.NoDriver ? "plugged in, needs its driver" : "driver installed, not set up in Windows")}, so it can't be read or printed to.";

    /// <summary>The log's line when one is found or moves on.</summary>
    public static string LogLine(NeedsDriverPrinter p) => $"[{p.Name}] USB printer on {EnglishWhere(p)}: {EnglishStatus(p)}";

    /// <summary>Report a problem's settings line.</summary>
    public static string ReportLine(IReadOnlyList<NeedsDriverPrinter> list, bool protectedPrint) =>
        (list.Count == 0 ? "none" : $"{list.Count}: {string.Join(", ", list.Select(p => $"{p.Name} on {EnglishWhere(p)}, {EnglishStatus(p)}"))}")
        + $"; Windows protected print {(protectedPrint ? "on" : "off")}";
}

/// <summary>Where to get a printer's driver, by its maker; a web search for the rest.</summary>
public static class DriverHelp
{
    private static readonly Dictionary<string, string> Pages = new(StringComparer.OrdinalIgnoreCase)
    {
        ["HP"] = "https://support.hp.com/drivers",
        ["Samsung"] = "https://support.hp.com/drivers", // Samsung's printers are HP's now
        ["Brother"] = "https://support.brother.com/",
        ["Lexmark"] = "https://support.lexmark.com/",
        ["Xerox"] = "https://www.support.xerox.com/",
    };

    public static bool HasDriverPage(string maker) => Pages.ContainsKey(maker);

    /// <summary>The maker's driver page, else a web search for "&lt;model&gt; driver".</summary>
    public static Uri PageFor(NeedsDriverPrinter p) =>
        p.Maker is { } maker && Pages.TryGetValue(maker, out var page) ? new Uri(page)
            : new Uri("https://www.bing.com/search?q=" + Uri.EscapeDataString($"{p.Name} driver"));

    /// <summary>Windows Update's optional updates (drivers it has but doesn't install by itself).</summary>
    public const string WindowsOptionalUpdates = "ms-settings:windowsupdate-optionalupdates";

    public const string WindowsPrinters = "ms-settings:printers";
}
