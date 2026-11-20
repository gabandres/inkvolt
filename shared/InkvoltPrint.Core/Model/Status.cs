namespace InkvoltPrint.Core.Model;

public enum Severity { Info, Warning, Error }

public sealed record PrinterAlert(string Id, Severity Severity, string Message);

/// <summary>Device status in protocol-neutral form.</summary>
public sealed record PrinterStatus(string Code, string Message, Severity Severity, IReadOnlyList<PrinterAlert> Alerts, string? Detail = null)
{
    public static PrinterStatus Offline(string why) => new("offline", why, Severity.Error, []);

    /// <summary>The printer answered but the reply was unusable (waking up, busy, malformed). Keep showing the last status.</summary>
    public static PrinterStatus Unavailable(string why) => new("unavailable", why, Severity.Info, []);

    public bool IsUnavailable => Code == "unavailable";

    /// <summary>
    /// What the printer's control panel says now, as the printer sends it (the Printer MIB's prtConsoleDisplayBufferText lines,
    /// IPP's <c>printer-state-message</c>, LEDM's status text); null when it says nothing or wasn't read. CDM has no such text
    /// that we know of.
    /// </summary>
    public string? PanelText { get; init; }

    /// <summary>The longest panel text shown (a panel's few lines; a printer may send pages).</summary>
    public const int MaxPanelText = 160;

    /// <summary>
    /// The panel's text to show with the status: one clean line of at most <see cref="MaxPanelText"/> characters
    /// (<see cref="Fleet.FleetText.Clean"/>), only when it says more than the status line does (not the same words, ignoring case
    /// and a final period, nor a plain "Idle" or "Ready" under the app's own word for it). A ready or idle printer's panel saying one
    /// short line of a word or two is its state in the panel's language ("Prêt", "Bereit", "Lista"): not shown either. Null otherwise.
    /// </summary>
    public string? PanelNote =>
        Fleet.FleetText.Clean(PanelText, MaxPanelText) is { } text && Ipp.IppClient.Headline(text, Message) is var said
        && !string.Equals(said.TrimEnd('.', '!'), Message.Trim().TrimEnd('.', '!'), StringComparison.OrdinalIgnoreCase)
        && !(Code is "ready" or "idle" && IsStateWord(said)) ? said : null;

    /// <summary>One short line of one or two words, no figures: how a panel names its state, in whatever language.</summary>
    private static bool IsStateWord(string text) =>
        text.Length <= 20 && !text.Contains(" · ", StringComparison.Ordinal) && !text.Any(char.IsDigit)
        && text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length <= 2;

    /// <summary>
    /// One line for a list of printers: the state, then for a warning or error the worst alert's words ("Ready · Yellow ink
    /// is low") and how many more there are, so an amber or red dot is never left unexplained. An alert that repeats or
    /// extends the state's words takes its place.
    /// </summary>
    public static string ListLine(string message, Severity severity, IReadOnlyList<PrinterAlert> alerts)
    {
        if (severity == Severity.Info) return message;
        var shown = alerts.Where(a => a.Severity != Severity.Info).OrderByDescending(a => a.Severity).ToList();
        if (shown.Count == 0) return message;
        var reason = shown[0].Message.Trim().TrimEnd('.');
        var line = reason.StartsWith(message.Trim().TrimEnd('.'), StringComparison.OrdinalIgnoreCase) ? reason : $"{message} · {reason}";
        return shown.Count > 1 ? $"{line} · +{shown.Count - 1}" : line;
    }
}

public sealed record Consumable(
    string Name,
    string Kind,
    string? ColorCode,
    int? PercentRemaining,
    string State,
    string? ProductNumber,
    string? SelectibilityNumber,
    int? LowThreshold,
    int? EstimatedPagesRemaining,
    DateOnly? Installed)
{
    private readonly string? _key;

    /// <summary>
    /// The supply's name in English, whatever the interface's language: what the supply history keeps it under and what
    /// alerts are told apart by, so a change of language neither starts a new history nor alerts again. The name itself
    /// (<see cref="Name"/>) is in the interface's language when Inkvolt Print writes it (LEDM, CDM); a printer's own names
    /// (IPP, SNMP) are both.
    /// </summary>
    public string Key { get => _key ?? Name; init => _key = value; }

    /// <summary>
    /// The pages a full cartridge is rated for, when the printer says (CDM's <c>capacity</c> in pages, IPP's <c>printer-supply</c>
    /// and the Printer MIB's prtMarkerSuppliesMaxCapacity counted in impressions or sheets); null otherwise. Beside
    /// <see cref="EstimatedPagesRemaining"/>, the pages left in it now.
    /// </summary>
    public int? PageYield { get; init; }

    /// <summary>Needs attention soon: low, empty, or (a waste box) almost full or full.</summary>
    public bool IsLow => State is "low" or "veryLow" or "out" or "almostFull" or "full" || (PercentRemaining is { } p && LowThreshold is { } t && p <= t);

    /// <summary>A box that fills up (waste ink or toner, an inkjet's maintenance box) rather than a supply that runs out.</summary>
    public bool IsWaste => IsWasteKind(Kind);

    public static bool IsWasteKind(string kind) => kind.StartsWith("waste", StringComparison.OrdinalIgnoreCase);
}

public sealed record ProductInfo(
    string MakeAndModel,
    string? Family,
    string? SerialNumber,
    string? ProductNumber,
    string? Uuid,
    string? FirmwareDate,
    bool? AdminPasswordSet,
    string? FirmwareRevision = null);

/// <summary>
/// The firmware a printer reports. LEDM gives its release date (an HP LaserJet's firmware version is that date) and on
/// some models a revision; IPP printers give <c>printer-firmware-string-version</c>.
/// </summary>
public sealed record FirmwareInfo(string? Version, string? Date)
{
    /// <summary>"2024-08-13", "SAYPRO1N001.2045A (2024-08-13)" or just the version.</summary>
    public string Display => Version is null ? Date ?? "" : Date is null ? Version : $"{Version} ({Date})";

    public static FirmwareInfo? From(ProductInfo? product, Ipp.IppResponse? ipp)
    {
        var version = product?.FirmwareRevision ?? FromIpp(ipp);
        var date = product?.FirmwareDate;
        return version is null && date is null ? null : new FirmwareInfo(version, date);
    }

    /// <summary>
    /// IPP's firmware attributes are parallel lists (one entry per component). The first is the main firmware on the
    /// printers seen so far; prefer an entry whose name says so.
    /// </summary>
    private static string? FromIpp(Ipp.IppResponse? ipp)
    {
        if (ipp is null) return null;
        var versions = ipp.Strs("printer-firmware-string-version").ToList();
        if (versions.Count == 0) return null;
        var names = ipp.Strs("printer-firmware-name").ToList();
        var main = names.FindIndex(n => n.Contains("firmware", StringComparison.OrdinalIgnoreCase) || n.Contains("system", StringComparison.OrdinalIgnoreCase));
        return main >= 0 && main < versions.Count ? versions[main] : versions[0];
    }
}

public sealed record UsageCounters(int? TotalImpressions, int? DuplexSheets, int? JamEvents, int? MispickEvents, int? ScanImages);
