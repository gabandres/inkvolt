using System.Globalization;
using System.Text.Json;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Cdm;

/// <summary>
/// HP CDM (Common Device Management: JSON under <c>/cdm/...</c>), the interface newer HP printers have instead of LEDM.
/// HP publishes no specification; the paths and fields here are the ones public, permissively licensed clients read and
/// show in captured replies (iDrunK65/HA-HP-printers and kou147258/ha-hp-printers-cn, both MIT, with fixtures from a Color
/// LaserJet Pro MFP 3302 and a Smart Tank 580-590; HPLIP for the supply fields, facts only). Read only: every path is a GET.
/// </summary>
public static class CdmPaths
{
    public const string Identity = "/cdm/system/v1/identity";
    public const string Supplies = "/cdm/supply/v1/suppliesPublic";
    public const string SystemStatus = "/cdm/system/v1/status";
    public const string PrintStatus = "/cdm/print/v2/status";
    public const string Alerts = "/cdm/alert/v1/alerts";
}

/// <summary>
/// CDM replies → the app's model. Tolerant: fields may be missing, booleans and numbers may come as strings, unknown values
/// are humanised, and anything that isn't the expected JSON gives null or an empty list rather than an exception.
/// </summary>
public static class CdmParsers
{
    /// <summary>The printer's identity; null when the reply has no model (not a CDM identity).</summary>
    public static ProductInfo? ParseIdentity(string json)
    {
        if (Parse(json) is not { ValueKind: JsonValueKind.Object } root) return null;
        var mm = root.TryGetProperty("makeAndModel", out var m) ? m : default;
        var model = mm.ValueKind switch
        {
            JsonValueKind.String => mm.GetString(),
            JsonValueKind.Object => Str(mm, "name") ?? Str(mm, "base"),
            _ => null,
        };
        if (string.IsNullOrWhiteSpace(model)) return null;
        return new ProductInfo(
            MakeAndModel: model.Trim(),
            Family: mm.ValueKind == JsonValueKind.Object ? Str(mm, "family") : null,
            SerialNumber: Str(root, "serialNumber"),
            ProductNumber: Str(root, "productNumber"),
            Uuid: Str(root, "deviceUuid"),
            FirmwareDate: DateCode(Str(root, "firmwareDateCode")),
            AdminPasswordSet: null,
            FirmwareRevision: Str(root, "firmwareVersion"));
    }

    /// <summary>"202607240158" or "20250918" → "2026-07-24"; anything else as given.</summary>
    private static string? DateCode(string? code) =>
        code is { Length: >= 8 } && DateOnly.TryParseExact(code[..8], "yyyyMMdd", CultureInfo.InvariantCulture, DateTimeStyles.None, out var d)
            ? d.ToString("yyyy-MM-dd", CultureInfo.InvariantCulture) : code;

    /// <summary>
    /// <c>suppliesList</c> → supplies: toner, ink cartridges, ink tanks (with their printheads after them: on tank printers
    /// the <c>inkCartridge</c> slots are printheads and report no level), drums. The state is <c>supplyState</c>, made finer by
    /// <c>levelState</c> (low, very low) when the supply itself is fine.
    /// </summary>
    public static IReadOnlyList<Consumable> ParseSupplies(string json)
    {
        if (Parse(json) is not { ValueKind: JsonValueKind.Object } root
            || !root.TryGetProperty("suppliesList", out var list) || list.ValueKind != JsonValueKind.Array) return [];
        var items = list.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.Object).ToList();
        var tanks = items.Any(e => Str(e, "supplyType") == "inkTank");
        var supplies = new List<(Consumable Supply, bool Printhead)>();
        foreach (var e in items)
        {
            var type = Str(e, "supplyType");
            var kind = type switch
            {
                null => "supply",
                "toner" or "tonerCartridge" or "rechargeableToner" => "toner",
                "inkCartridge" when tanks => "printhead",
                "ink" or "inkCartridge" => "ink cartridge",
                "inkTank" => "ink tank",
                "printhead" or "printHead" => "printhead",
                "imageDrum" => "drum",
                _ => StatusText.Humanize(type).ToLowerInvariant(),
            };
            var code = Str(e, "supplyColorCode");
            var level = Int(e, "percentLifeDisplay");
            var name = $"{ColorName(code)} {kind}".Trim();
            supplies.Add((new Consumable(
                Name: char.ToUpperInvariant(name[0]) + name[1..],
                Kind: kind,
                ColorCode: code is "pK" or "mK" ? "K" : code,
                PercentRemaining: level is >= 0 ? Math.Min(level.Value, 100) : null,
                State: State(Str(e, "supplyState"), Str(e, "levelState")),
                ProductNumber: Str(e, "orderPartNumber") ?? Str(e, "productNumber") ?? Str(e, "orderSelectabilityNumber") ?? Str(e, "selectabilityNumber"),
                SelectibilityNumber: Str(e, "selectabilityNumber") ?? Str(e, "orderSelectabilityNumber"),
                LowThreshold: null,
                EstimatedPagesRemaining: Int(e, "approximatePagesRemainingDisplay") is >= 0 and var pages ? pages : null,
                Installed: null), kind == "printhead"));
        }
        return [.. supplies.Where(s => !s.Printhead).Concat(supplies.Where(s => s.Printhead)).Select(s => s.Supply)];
    }

    private static string State(string? supply, string? level) => supply switch
    {
        "ok" or "inform" => level is "low" or "veryLow" or "out" ? level : "ok",
        "low" or "veryLow" or "out" or "missing" => supply,
        "misinstalled" => "missing",
        _ => "unknown",
    };

    private static string ColorName(string? code) => code switch
    {
        "K" => "Black",
        "C" => "Cyan",
        "M" => "Magenta",
        "Y" => "Yellow",
        "CMY" => "Tri-color",
        "pK" => "Photo black",
        "mK" => "Matte black",
        "G" => "Gray",
        null => "",
        _ => code,
    };

    // ---- Status ----

    private static readonly Dictionary<string, (string Text, Severity Severity, string? Detail)> Alerts = new(StringComparer.Ordinal)
    {
        ["doorOpen"] = ("Door open", Severity.Error, "A door or cover is open. Close it to continue."),
        ["trayEmpty"] = ("Load paper", Severity.Error, "Load paper into the tray and push it all the way in."),
        ["trayOpen"] = ("Tray open", Severity.Error, "Push the paper tray all the way in."),
        ["cartridgeLow"] = ("Cartridge low", Severity.Warning, "Printing goes on; have a replacement ready."),
        ["cartridgeVeryLow"] = ("Cartridge very low", Severity.Warning, "Print quality may drop soon; replace the cartridge."),
        ["cartridgeOut"] = ("Cartridge empty", Severity.Error, "Replace the cartridge to keep printing."),
        ["cartridgeMissing"] = ("Cartridge missing", Severity.Error, "Put the cartridge back in and close the door."),
        ["jam"] = ("Paper jam", Severity.Error, "Open the doors the printer shows, gently pull out the jammed paper, and close them."),
    };

    /// <summary>
    /// <c>/cdm/system/v1/status</c> (ready, inPowerSave, processing…) with the alerts of <c>/cdm/alert/v1/alerts</c>; without a
    /// system status, the print status's <c>printerState</c>. Information alerts (such as "genuine HP supply") are left out.
    /// An error alert says what's wrong in the status line instead of "Ready".
    /// </summary>
    public static PrinterStatus ParseStatus(string? systemJson, string? printJson, string? alertsJson)
    {
        var code = Parse(systemJson) is { ValueKind: JsonValueKind.Object } system ? Str(system, "status") : null;
        code ??= Parse(printJson) is { ValueKind: JsonValueKind.Object } print ? Str(print, "printerState") switch
        {
            "idle" => "ready",
            null => null,
            var state => state,
        } : null;

        var alerts = new List<(PrinterAlert Alert, string? Detail)>();
        if (Parse(alertsJson) is { ValueKind: JsonValueKind.Object } root && root.TryGetProperty("alerts", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var a in list.EnumerateArray().Where(e => e.ValueKind == JsonValueKind.Object))
            {
                var category = Str(a, "category") ?? "unknown";
                var key = category.StartsWith("jam", StringComparison.Ordinal) ? "jam" : category;
                var known = Alerts.TryGetValue(key, out var k);
                var severity = Str(a, "severity")?.ToLowerInvariant() switch
                {
                    "error" or "critical" or "fatal" => Severity.Error,
                    "warning" => Severity.Warning,
                    "information" or "info" or "informational" => (Severity?)null,
                    _ => known ? k.Severity : Severity.Warning,
                };
                if (severity is not { } sev) continue;
                var text = known ? k.Text : StatusText.Humanize(category);
                if (Color(a) is { } color) text = $"{text} ({color})";
                alerts.Add((new PrinterAlert(category, sev, text), known ? k.Detail : null));
            }
        }

        if (code is null && alerts.Count == 0) return new PrinterStatus("unknown", "Status not available", Severity.Info, []);
        code ??= "unknown";
        var severityOverall = alerts.Count > 0 ? alerts.Max(a => a.Alert.Severity) : StatusText.SeverityOf(code);
        var error = alerts.FirstOrDefault(a => a.Alert.Severity == Severity.Error);
        var message = error.Alert?.Message ?? StatusText.Describe(code);
        var detail = error.Alert is not null ? error.Detail : StatusText.Explain(code);
        return new PrinterStatus(code, message, severityOverall, [.. alerts.Select(a => a.Alert)], detail);
    }

    /// <summary>The supply colour an alert is about (its data's <c>seValue</c> on a <c>…/colors</c> pointer), as a word.</summary>
    private static string? Color(JsonElement alert)
    {
        if (!alert.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array) return null;
        foreach (var d in data.EnumerateArray())
            if (d.ValueKind == JsonValueKind.Object && Str(d, "propertyPointer")?.EndsWith("/colors", StringComparison.Ordinal) == true
                && d.TryGetProperty("value", out var v) && v.ValueKind == JsonValueKind.Object && Str(v, "seValue") is { } code)
                return ColorName(code) is { Length: > 0 } name ? name : null;
        return null;
    }

    // ---- JSON helpers ----

    private static JsonElement? Parse(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return null;
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.Clone();
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? Str(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) ? v.ValueKind switch
        {
            JsonValueKind.String => v.GetString() is { Length: > 0 } s ? s.Trim() : null,
            JsonValueKind.Number => v.GetRawText(),
            JsonValueKind.True => "true",
            JsonValueKind.False => "false",
            _ => null,
        } : null;

    private static int? Int(JsonElement e, string name) =>
        Str(e, name) is { } s && double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) && d is > int.MinValue and < int.MaxValue
            ? (int)Math.Round(d) : null;
}
