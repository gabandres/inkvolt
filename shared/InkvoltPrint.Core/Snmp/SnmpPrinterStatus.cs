using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Snmp;

/// <summary>One row of prtMarkerSuppliesTable (RFC 3805): what it is, how much it holds and how much is left.</summary>
public sealed record SnmpSupply(int Index, int Class, int Type, string? Description, int MaxCapacity, int Level, int ColorantIndex)
{
    /// <summary>A receptacle that fills up (waste toner or ink), whose level is the room left in it (RFC 3805 prtMarkerSuppliesLevel).</summary>
    public bool IsReceptacle => Class == PrinterMib.ClassReceptacle || PrinterMib.SupplyKind(Type).StartsWith("waste", StringComparison.Ordinal);
}

/// <summary>One row of prtAlertTable (RFC 3805): severity, which sub-unit (group and its row), the code and the printer's words.</summary>
public sealed record SnmpAlert(int Index, int Severity, int Group, int GroupIndex, int Code, string? Description);

/// <summary>One read of a printer's status objects (Host Resources MIB and Printer MIB), before turning them into plain words.</summary>
public sealed record SnmpReading(
    int? DeviceStatus,
    int? PrinterStatus,
    byte[] DetectedErrorState,
    IReadOnlyList<SnmpAlert> Alerts,
    IReadOnlyList<SnmpSupply> Supplies,
    IReadOnlyDictionary<int, string> Colorants);

/// <summary>
/// A printer's SNMP objects as a <see cref="PrinterStatus"/> and <see cref="Consumable"/>s. The overall state follows RFC 3805
/// §2.2.13.2 (hrDeviceStatus with hrPrinterStatus); problems come from prtAlertTable, with the alert codes mapped to IPP's
/// printer-state-reasons as PWG 5100.9 does (so they read and alert like an IPP printer's), and from the
/// hrPrinterDetectedErrorState bits (RFC 2790) that no alert already covers.
/// </summary>
public static class SnmpPrinterStatus
{
    /// <summary>hrPrinterDetectedErrorState bits, numbered from the first byte's most significant bit (RFC 2790).</summary>
    private static readonly (int Bit, string Id, Severity Severity, string Message)[] ErrorBits =
    [
        (0, "media-low", Severity.Warning, "Paper low"),
        (1, "media-empty", Severity.Error, "Out of paper"),
        (2, "toner-low", Severity.Warning, "Toner low"),
        (3, "toner-empty", Severity.Error, "Toner empty"),
        (4, "door-open", Severity.Error, "A door is open"),
        (5, "media-jam", Severity.Error, "Paper jam"),
        (6, "offline", Severity.Error, "The printer is offline"),
        (7, "service-requested", Severity.Error, "The printer needs attention"),
        (8, "input-tray-missing", Severity.Error, "Paper tray missing"),
        (9, "output-tray-missing", Severity.Error, "Output tray missing"),
        (10, "marker-supply-missing", Severity.Error, "Cartridge missing"),
        (11, "output-area-almost-full", Severity.Warning, "Output tray almost full"),
        (12, "output-area-full", Severity.Error, "Output tray full"),
        (13, "input-tray-empty", Severity.Warning, "A paper tray is empty"),
        (14, "maintenance-overdue", Severity.Warning, "Maintenance is overdue"),
    ];

    /// <summary>Reasons that say the same thing, so an error bit doesn't repeat an alert in other words.</summary>
    private static readonly string[][] SameProblem =
    [
        ["toner-low", "marker-supply-low"],
        ["toner-empty", "marker-supply-empty"],
        ["door-open", "cover-open", "interlock-open"],
        ["media-empty", "input-tray-empty"],
        ["marker-supply-missing"],
    ];

    /// <summary>Alert codes that report a change, not a problem (cover closed, powered up, media changed, added or removed…).</summary>
    private static readonly HashSet<int> Events = [4, 6, 7, 19, 20, 23, 24, 25, 26, 27, 28, 502, 503, 504, 505, 506, 507, 802, 803, 804, 805, 806];

    /// <summary>PrtAlertCodeTC other(1) and unknown(2): the printer's description is all that says what the alert is.</summary>
    private const int CodeOther = 1, CodeUnknown = 2;

    /// <summary>Codes PWG 5100.9 has no printer-alert mapping for that still mean an IPP reason (RFC 3805's newer marker codes, jams).</summary>
    private static readonly Dictionary<int, string> MoreReasons = new()
    {
        [906] = "media-jam", [1306] = "media-jam", [1312] = "media-jam", [1322] = "media-jam",
        [1116] = "marker-supply-missing", [1117] = "marker-supply-missing", [1118] = "marker-supply-missing",
        [1119] = "marker-supply-missing", [1120] = "marker-supply-missing", [1121] = "marker-supply-missing",
        [1124] = "marker-supply-missing", [1130] = "marker-supply-missing",
        [1122] = "marker-supply-low", [1123] = "marker-supply-empty",
        [1125] = "marker-waste-almost-full", [1126] = "marker-waste-full",
        [1127] = "marker-waste-missing", [1128] = "marker-waste-missing", [1129] = "marker-waste-missing",
        [1302] = "output-area-almost-full", [1303] = "output-area-full", [1323] = "output-area-full",
    };

    public static PrinterStatus ToStatus(SnmpReading r)
    {
        var alerts = new List<PrinterAlert>();
        var texts = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        foreach (var a in r.Alerts)
        {
            if (Classify(a, r.Supplies) is not { } x) continue;
            var existing = alerts.FindIndex(p => p.Id == x.Id);
            if (existing < 0) alerts.Add(new PrinterAlert(x.Id, x.Severity, x.Id is "other" or "unknown" ? "The printer reports a problem" : IppStatusText.Describe(x.Id)));
            else if (x.Severity > alerts[existing].Severity) alerts[existing] = alerts[existing] with { Severity = x.Severity };
            if (Words(a.Description) is { } d)
            {
                if (!texts.TryGetValue(x.Id, out var list)) texts[x.Id] = list = [];
                if (!list.Contains(d, StringComparer.OrdinalIgnoreCase)) list.Add(d);
            }
        }
        // The printer's own descriptions name the sub-unit ("Black toner low", "Tray 2 empty"): they replace the generic words.
        for (var i = 0; i < alerts.Count; i++)
            if (texts.TryGetValue(alerts[i].Id, out var list))
                alerts[i] = alerts[i] with { Message = string.Join(" ", list.Select(t => t.EndsWith('.') || t.EndsWith('!') ? t : t + ".")) };

        foreach (var (bit, id, severity, message) in ErrorBits)
        {
            if (!IsSet(r.DetectedErrorState, bit) || Covered(alerts, id)) continue;
            if (id == "service-requested" && alerts.Count > 0) continue; // set alongside the real problem (a jam, low toner…)
            alerts.Add(new PrinterAlert(id, severity, message));
        }

        var offline = IsSet(r.DetectedErrorState, 6);
        var (code, label) = (r.DeviceStatus, r.PrinterStatus) switch
        {
            (_, _) when offline => ("stopped", "Offline"),
            (_, PrinterMib.PrinterPrinting) => ("processing", "Printing"),
            (_, PrinterMib.PrinterWarmup) => ("warmingUp", "Warming up"),
            (PrinterMib.DeviceDown, _) => ("stopped", "Stopped"),
            (_, PrinterMib.PrinterIdle) => ("ready", "Ready"),
            (PrinterMib.DeviceRunning, PrinterMib.PrinterOther) => ("inPowerSave", "Sleeping"), // RFC 3805's "Standby"
            (PrinterMib.DeviceRunning or PrinterMib.DeviceWarning, _) => ("ready", "Ready"),
            (PrinterMib.DeviceTesting, _) => ("processing", "Testing"),
            _ => ("unknown", "Unknown"),
        };
        var severityAll = alerts.Count > 0 ? alerts.Max(a => a.Severity)
            : code == "stopped" ? Severity.Error : r.DeviceStatus == PrinterMib.DeviceWarning ? Severity.Warning : Severity.Info;
        var top = alerts.FirstOrDefault(a => a.Severity == Severity.Error);
        var detail = alerts.Where(a => a.Severity == severityAll).Select(a => IppStatusText.Explain(a.Id)).FirstOrDefault(e => e is not null);
        // A stopped printer is best named by what stops it ("Paper jam"), as the spooler's and LEDM's headlines do.
        return new PrinterStatus(code, code == "stopped" && top is not null && !offline ? top.Message : label, severityAll, alerts, detail);
    }

    /// <summary>
    /// The supply table as consumables. Levels are a share of the maximum (RFC 3805: -1 other, -2 unknown, -3 "some left";
    /// a maximum of -1, -2 or 0 gives no percentage). Waste boxes report the room left (not how full they are), so they get no
    /// percentage, as with IPP: their state comes from the level (no room: full) and the waste alerts. A supply's alerts
    /// (marker supplies group, its row) make it low, empty or missing.
    /// </summary>
    public static IReadOnlyList<Consumable> ToConsumables(SnmpReading r)
    {
        var list = new List<Consumable>();
        foreach (var s in r.Supplies.OrderBy(s => s.Index))
        {
            var reasons = r.Alerts.Where(a => a.Group == PrinterMib.GroupMarkerSupplies && a.GroupIndex == s.Index)
                .Select(a => Classify(a, r.Supplies)?.Id).OfType<string>().ToHashSet(StringComparer.Ordinal);
            var name = Words(s.Description) ?? PrinterMib.SupplyName(s.Type);
            var kind = PrinterMib.SupplyKind(s.Type);
            if (s.IsReceptacle)
            {
                if (!kind.StartsWith("waste", StringComparison.Ordinal)) kind = "waste-" + kind;
                // A waste box the printer calls consumed (class 3) doesn't say its level is the room left: only alerts make it full.
                var full = (s.Level == 0 && s.Class != PrinterMib.ClassConsumed) || reasons.Any(x => x.EndsWith("-full", StringComparison.Ordinal) && !x.EndsWith("almost-full", StringComparison.Ordinal));
                var state = full ? "full" : reasons.Any(x => x.EndsWith("almost-full", StringComparison.Ordinal)) ? "almostFull" : s.Level == -2 ? "unknown" : "ok";
                list.Add(new Consumable(name, kind, null, null, state, null, null, null, null, null));
                continue;
            }
            int? percent = s.Level >= 0 && s.MaxCapacity > 0 ? (int)Math.Round(100.0 * Math.Min(s.Level, s.MaxCapacity) / s.MaxCapacity) : null;
            var supplyState =
                reasons.Contains("marker-supply-missing") ? "missing"
                : reasons.Any(x => x is "marker-supply-empty" or "toner-empty" or "opc-life-over") || (s.Level == 0 && s.MaxCapacity > 0) ? "out"
                : reasons.Any(x => x is "marker-supply-low" or "toner-low" or "opc-near-eol" or "developer-low") ? "low"
                : s.Level == -3 || percent is not null ? "ok"
                : "unknown";
            var color = r.Colorants.TryGetValue(s.ColorantIndex, out var c) ? ColorCode(c) : null;
            list.Add(new Consumable(name, kind, color, percent, supplyState, null, null, null, null, null));
        }
        return list;
    }

    /// <summary>prtMarkerColorantValue ("black", "cyan"…: RFC 3805 names them in lowercase English) → K, C, M, Y; null for other colors.</summary>
    public static string? ColorCode(string colorant) => colorant.Trim().ToLowerInvariant() switch
    {
        "black" => "K",
        "cyan" => "C",
        "magenta" => "M",
        "yellow" => "Y",
        _ => null,
    };

    /// <summary>
    /// An alert as an IPP reason with a severity; null for change events and alerts that need no attention (an "other" or
    /// "unknown" code counts only as a critical or warning alert, named by the printer's description). Codes PWG 5100.9 maps (by their PrtAlertCodeTC label) use its reason; the generic sub-unit codes take the
    /// meaning of their group (a supply, a tray, an output bin). A warning or critical alert with no known meaning is kept
    /// under its own label, so nothing the printer flags is dropped.
    /// </summary>
    internal static (string Id, Severity Severity)? Classify(SnmpAlert a, IReadOnlyList<SnmpSupply> supplies)
    {
        if (a.Severity == PrinterMib.SeverityBinaryChangeEvent || Events.Contains(a.Code)) return null;
        if (a.Code is CodeOther or CodeUnknown && a.Severity is not (PrinterMib.SeverityCritical or PrinterMib.SeverityWarning)) return null;
        var label = PrinterMib.AlertLabel(a.Code);
        var reason = (label is null ? null : IppStatusText.ReasonForAlert(label)) ?? MoreReasons.GetValueOrDefault(a.Code) ?? FromGroup(a, supplies);
        Severity? severity = a.Severity switch
        {
            PrinterMib.SeverityCritical => Severity.Error,
            PrinterMib.SeverityWarning => Severity.Warning,
            _ => reason is null ? null : IppStatusText.DefaultSeverity(reason), // severity "other": go by what it is
        };
        if (severity is null) return null;
        return (reason ?? label ?? $"alert-{a.Code}", severity.Value);
    }

    private static string? FromGroup(SnmpAlert a, IReadOnlyList<SnmpSupply> supplies)
    {
        switch (a.Group)
        {
            case PrinterMib.GroupMarkerSupplies:
                var supply = supplies.FirstOrDefault(s => s.Index == a.GroupIndex);
                var drum = supply?.Type == 9;
                return a.Code switch
                {
                    9 => supply?.IsReceptacle == true ? "marker-waste-missing" : "marker-supply-missing",
                    10 => drum ? "opc-near-eol" : "marker-supply-low",
                    11 => drum ? "opc-life-over" : "marker-supply-empty",
                    12 or 16 => "marker-supply-low",
                    13 or 17 => "marker-supply-empty",
                    14 => "marker-waste-almost-full",
                    15 => "marker-waste-full",
                    _ => null,
                };
            case PrinterMib.GroupInput:
                return a.Code switch { 9 => "input-tray-missing", 12 => "media-low", 13 => "media-empty", 8 => "media-jam", _ => null };
            case PrinterMib.GroupOutput:
                return a.Code switch { 9 => "output-tray-missing", 14 => "output-area-almost-full", 15 => "output-area-full", 8 => "media-jam", _ => null };
            case PrinterMib.GroupCover:
                return a.Code is 18 ? "cover-open" : null;
            default:
                return null;
        }
    }

    private static bool Covered(IReadOnlyList<PrinterAlert> alerts, string id) =>
        alerts.Any(a => a.Id == id) || SameProblem.Any(g => g.Contains(id) && alerts.Any(a => g.Contains(a.Id)));

    internal static bool IsSet(byte[] bits, int bit) => bit / 8 < bits.Length && (bits[bit / 8] & (0x80 >> (bit % 8))) != 0;

    /// <summary>The printer's own words when they are words (some printers put only a code like "{13.A3.D2}" there).</summary>
    private static string? Words(string? text) =>
        text is { } t && t.Trim() is { Length: > 0 and <= 160 } s && s.Count(char.IsLetter) >= 3 ? s : null;
}
