using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Ipp;

/// <summary>
/// Plain words for IPP <c>printer-state-reasons</c> keywords (RFC 8011 §5.4.12, PWG 5100.9 §5.1) and the
/// <c>printer-alert</c> codes (PWG 5100.9 §5.2, IANA PrtAlertCodeTC) that mean the same thing. Unknown keywords are
/// de-hyphenated.
/// </summary>
public static class IppStatusText
{
    private static readonly Dictionary<string, string> Known = new(StringComparer.Ordinal)
    {
        ["media-empty"] = "Out of paper",
        ["media-needed"] = "Load paper",
        ["media-low"] = "Paper low",
        ["media-jam"] = "Paper jam",
        ["media-path-jam"] = "Paper jam",
        ["input-tray-missing"] = "Paper tray missing",
        ["output-tray-missing"] = "Output tray missing",
        ["output-area-almost-full"] = "Output tray almost full",
        ["output-area-full"] = "Output tray full",
        ["cover-open"] = "A cover is open",
        ["door-open"] = "A door is open",
        ["interlock-open"] = "A cover is open",
        ["toner-low"] = "Toner low",
        ["toner-empty"] = "Toner empty",
        ["marker-supply-low"] = "Ink or toner low",
        ["marker-supply-empty"] = "Ink or toner empty",
        ["marker-supply-missing"] = "Cartridge missing",
        ["marker-waste-almost-full"] = "Waste ink or toner box almost full",
        ["marker-waste-full"] = "Waste ink or toner box full",
        ["marker-waste-ink-receptacle-almost-full"] = "Maintenance box almost full",
        ["marker-waste-ink-receptacle-full"] = "Maintenance box full",
        ["marker-waste-toner-receptacle-almost-full"] = "Waste toner box almost full",
        ["marker-waste-toner-receptacle-full"] = "Waste toner box full",
        ["developer-low"] = "Developer low",
        ["developer-empty"] = "Developer empty",
        ["opc-near-eol"] = "Drum nearly worn out",
        ["opc-life-over"] = "Replace the drum",
        ["fuser-over-temp"] = "Fuser too hot",
        ["fuser-under-temp"] = "Fuser warming up",
        ["paused"] = "Paused",
        ["moving-to-paused"] = "Pausing",
        ["shutdown"] = "Shutting down",
        ["stopping"] = "Stopping",
        ["stopped-partly"] = "Partly stopped",
        ["spool-area-full"] = "Printer memory full",
        ["interpreter-resource-unavailable"] = "Printer resource unavailable",
        ["timed-out"] = "Timed out",
        ["connecting-to-device"] = "Connecting",
        ["identify-printer-requested"] = "Identifying itself",
        ["offline"] = "Offline",
        ["deactivated"] = "Turned off by an administrator",
    };

    private static readonly Dictionary<string, string> Details = new(StringComparer.Ordinal)
    {
        ["media-empty"] = "Load paper into the tray.",
        ["media-needed"] = "Load the paper the printer asks for, then press OK on the printer if it asks.",
        ["media-jam"] = "Open the covers the printer's screen points to and gently pull out the jammed paper.",
        ["cover-open"] = "Close it to continue.",
        ["door-open"] = "Close it to continue.",
        ["toner-empty"] = "Replace the toner cartridge to keep printing.",
        ["marker-supply-empty"] = "Replace or refill the empty cartridge or ink tank to keep printing.",
        ["marker-waste-full"] = "Replace the waste ink or toner box (on inkjets: the maintenance box) to keep printing.",
        ["marker-waste-ink-receptacle-full"] = "Replace the maintenance box to keep printing.",
        ["opc-life-over"] = "The drum unit has reached the end of its life. Replace it to keep printing well.",
    };

    /// <summary>Reasons that are warnings by nature: a reason sent without a severity suffix is an error per RFC 8011, except these.</summary>
    private static readonly HashSet<string> Warnings = new(StringComparer.Ordinal)
    {
        "media-low", "toner-low", "marker-supply-low", "developer-low", "opc-near-eol", "output-area-almost-full",
        "marker-waste-almost-full", "marker-waste-ink-receptacle-almost-full", "marker-waste-toner-receptacle-almost-full",
        "fuser-under-temp", "connecting-to-device", "identify-printer-requested", "moving-to-paused",
    };

    /// <summary>printer-alert codes (IANA PrtAlertCodeTC labels) → the printer-state-reasons keyword PWG 5100.9 maps them to.</summary>
    private static readonly Dictionary<string, string> AlertReasons = new(StringComparer.Ordinal)
    {
        ["coverOpen"] = "cover-open",
        ["doorOpen"] = "door-open",
        ["interlockOpen"] = "interlock-open",
        ["jam"] = "media-jam",
        ["inputMediaTrayMissing"] = "input-tray-missing",
        ["inputMediaSupplyLow"] = "media-low",
        ["inputMediaSupplyEmpty"] = "media-empty",
        ["inputMediaChangeRequest"] = "media-needed",
        ["outputMediaTrayMissing"] = "output-tray-missing",
        ["outputMediaTrayAlmostFull"] = "output-area-almost-full",
        ["outputMediaTrayFull"] = "output-area-full",
        ["markerFuserUnderTemperature"] = "fuser-under-temp",
        ["markerFuserOverTemperature"] = "fuser-over-temp",
        ["markerTonerEmpty"] = "toner-empty",
        ["markerTonerAlmostEmpty"] = "toner-low",
        ["markerInkEmpty"] = "marker-supply-empty",
        ["markerInkAlmostEmpty"] = "marker-supply-low",
        ["markerPrintRibbonEmpty"] = "marker-supply-empty",
        ["markerPrintRibbonAlmostEmpty"] = "marker-supply-low",
        ["markerDeveloperEmpty"] = "marker-supply-empty",
        ["markerDeveloperAlmostEmpty"] = "marker-supply-low",
        ["markerWasteTonerReceptacleAlmostFull"] = "marker-waste-almost-full",
        ["markerWasteInkReceptacleAlmostFull"] = "marker-waste-almost-full",
        ["markerWasteTonerReceptacleFull"] = "marker-waste-full",
        ["markerWasteInkReceptacleFull"] = "marker-waste-full",
        ["markerOpcLifeAlmostOver"] = "opc-near-eol",
        ["markerOpcLifeOver"] = "opc-life-over",
        ["markerTonerCartridgeMissing"] = "marker-supply-missing",
        ["interpreterResourceUnavailable"] = "interpreter-resource-unavailable",
    };

    public static string Describe(string reason) => Known.TryGetValue(reason, out var t) ? t : Ledm.StatusText.Humanize(reason);

    /// <summary>One plain sentence on what to do; null when the title says it all.</summary>
    public static string? Explain(string reason) => Details.GetValueOrDefault(reason);

    /// <summary>Severity of a reason keyword without its suffix.</summary>
    public static Severity DefaultSeverity(string reason) => Warnings.Contains(reason) ? Severity.Warning : Severity.Error;

    /// <summary>The printer-state-reasons keyword for an alert code, or null when PWG 5100.9 maps it to none.</summary>
    public static string? ReasonForAlert(string code) => AlertReasons.GetValueOrDefault(code);
}

/// <summary>One <c>printer-alert</c> value (PWG 5100.9 §5.2.2): <c>code=jam;index=22;severity=critical;…</c>.</summary>
public sealed record IppAlert(string Code, string? Severity, IReadOnlyDictionary<string, string> Fields)
{
    /// <summary>Null when the value has no code (malformed or empty: some printers send an empty string for "no alerts").</summary>
    public static IppAlert? Parse(string value)
    {
        var fields = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var part in value.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            var eq = part.IndexOf('=');
            if (eq > 0) fields[part[..eq]] = part[(eq + 1)..];
        }
        return fields.TryGetValue("code", out var code) && code.Length > 0 ? new IppAlert(code, fields.GetValueOrDefault("severity"), fields) : null;
    }
}
