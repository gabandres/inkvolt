using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Ipp;

/// <summary>
/// Plain words for IPP <c>printer-state-reasons</c> keywords (RFC 8011 §5.4.12, PWG 5100.9 §5.1) and the
/// <c>printer-alert</c> codes (PWG 5100.9 §5.2, IANA PrtAlertCodeTC) that mean the same thing. Unknown keywords are
/// de-hyphenated.
/// </summary>
public static class IppStatusText
{
    // Read at the moment of use: the interface's language is chosen at start-up.
    private static string? KnownText(string reason) => reason switch
    {
        "media-empty" => CoreStrings.Status_OutOfPaper,
        "media-needed" => CoreStrings.Status_LoadPaper,
        "media-low" => CoreStrings.Status_PaperLow,
        "media-jam" => CoreStrings.Status_PaperJam,
        "media-path-jam" => CoreStrings.Status_PaperJam,
        "input-tray-missing" => CoreStrings.Status_PaperTrayMissing,
        "output-tray-missing" => CoreStrings.Status_OutputTrayMissing,
        "output-area-almost-full" => CoreStrings.Status_OutputTrayAlmostFull,
        "output-area-full" => CoreStrings.Status_OutputTrayFull,
        "cover-open" => CoreStrings.Status_CoverOpen,
        "door-open" => CoreStrings.Status_DoorOpen,
        "interlock-open" => CoreStrings.Status_CoverOpen,
        "toner-low" => CoreStrings.Status_TonerLow,
        "toner-empty" => CoreStrings.Status_TonerEmpty,
        "marker-supply-low" => CoreStrings.Status_InkOrTonerLow,
        "marker-supply-empty" => CoreStrings.Status_InkOrTonerEmpty,
        "marker-supply-missing" => CoreStrings.Status_CartridgeMissing,
        "marker-waste-almost-full" => CoreStrings.Status_WasteBoxAlmostFull,
        "marker-waste-full" => CoreStrings.Status_WasteBoxFull,
        "marker-waste-ink-receptacle-almost-full" => CoreStrings.Status_MaintenanceBoxAlmostFull,
        "marker-waste-ink-receptacle-full" => CoreStrings.Status_MaintenanceBoxFull,
        "marker-waste-toner-receptacle-almost-full" => CoreStrings.Status_WasteTonerBoxAlmostFull,
        "marker-waste-toner-receptacle-full" => CoreStrings.Status_WasteTonerBoxFull,
        "developer-low" => CoreStrings.Status_DeveloperLow,
        "developer-empty" => CoreStrings.Status_DeveloperEmpty,
        "opc-near-eol" => CoreStrings.Status_DrumNearlyWornOut,
        "opc-life-over" => CoreStrings.Status_ReplaceDrum,
        "fuser-over-temp" => CoreStrings.Status_FuserTooHot,
        "fuser-under-temp" => CoreStrings.Status_FuserWarmingUp,
        "paused" => CoreStrings.Status_Paused,
        "moving-to-paused" => CoreStrings.Status_Pausing,
        "shutdown" => CoreStrings.Status_ShuttingDown,
        "stopping" => CoreStrings.Status_Stopping,
        "stopped-partly" => CoreStrings.Status_PartlyStopped,
        "spool-area-full" => CoreStrings.Status_PrinterMemoryFull,
        "interpreter-resource-unavailable" => CoreStrings.Status_PrinterResourceUnavailable,
        "timed-out" => CoreStrings.Status_TimedOut,
        "connecting-to-device" => CoreStrings.Status_Connecting,
        "identify-printer-requested" => CoreStrings.Status_IdentifyingItself,
        "offline" => CoreStrings.Status_Offline,
        "deactivated" => CoreStrings.Status_Deactivated,
        _ => null,
    };

    private static string? Details(string reason) => reason switch
    {
        "media-empty" => CoreStrings.Status_MediaEmpty_Detail,
        "media-needed" => CoreStrings.Status_MediaNeeded_Detail,
        "media-jam" => CoreStrings.Status_MediaJam_Detail,
        "cover-open" => CoreStrings.Status_CloseItToContinue,
        "door-open" => CoreStrings.Status_CloseItToContinue,
        "toner-empty" => CoreStrings.Status_TonerEmpty_Detail,
        "marker-supply-empty" => CoreStrings.Status_SupplyEmpty_Detail,
        "marker-waste-full" => CoreStrings.Status_WasteFull_Detail,
        "marker-waste-ink-receptacle-full" => CoreStrings.Status_MaintenanceBoxFull_Detail,
        "opc-life-over" => CoreStrings.Status_ReplaceDrum_Detail,
        _ => null,
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

    public static string Describe(string reason) => KnownText(reason) ?? Ledm.StatusText.Humanize(reason);

    /// <summary>One plain sentence on what to do; null when the title says it all.</summary>
    public static string? Explain(string reason) => Details(reason);

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
