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
