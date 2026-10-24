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
    public bool IsLow => State is "low" or "veryLow" or "out" || (PercentRemaining is { } p && LowThreshold is { } t && p <= t);
}

public sealed record ProductInfo(
    string MakeAndModel,
    string? Family,
    string? SerialNumber,
    string? ProductNumber,
    string? Uuid,
    string? FirmwareDate,
    bool? AdminPasswordSet);

public sealed record UsageCounters(int? TotalImpressions, int? DuplexSheets, int? JamEvents, int? MispickEvents, int? ScanImages);
