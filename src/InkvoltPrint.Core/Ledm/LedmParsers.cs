using System.Globalization;
using System.Xml.Linq;
using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Ledm;

public static class LedmParsers
{
    public static PrinterStatus ParseStatus(XDocument doc)
    {
        var root = doc.Root!;
        var status = root.Kid("Status");
        var code = status?.KidValue("StatusCategory") ?? "unknown";
        var message = StatusText.IsKnown(code) ? StatusText.Describe(code) : status?.KidValue("LocString") ?? StatusText.Describe(code);

        var alerts = root.All("Alert")
            .Select(a =>
            {
                var id = a.FirstValue("ProductStatusAlertID") ?? "unknown";
                var sev = (a.FirstValue("Severity") ?? "").ToLowerInvariant() switch
                {
                    "error" => Severity.Error,
                    "warning" => Severity.Warning,
                    "info" or "informational" => Severity.Info,
                    _ => StatusText.SeverityOf(id),
                };
                var color = a.FirstValue("AlertDetailsMarkerColor");
                var text = StatusText.Describe(id);
                if (color is not null) text = $"{text} ({color})";
                return new PrinterAlert(id, sev, text);
            })
            .ToList();

        var severity = alerts.Count > 0 ? alerts.Max(a => a.Severity) : StatusText.SeverityOf(code);
        var detail = StatusText.Explain(alerts.FirstOrDefault(a => a.Severity == Severity.Error)?.Id ?? code);
        return new PrinterStatus(code, message, severity, alerts, detail);
    }

    public static IReadOnlyList<Consumable> ParseConsumables(XDocument doc, XDocument? usage = null)
    {
        var pagesLeft = new Dictionary<string, int?>();
        foreach (var c in usage?.Root?.All("Consumable") ?? [])
            if (c.KidValue("ConsumableStation") is { } st) pagesLeft[st] = c.KidValue("EstimatedPagesRemaining").ToInt();

        return doc.Root!.Kids("ConsumableInfo").Select(ci =>
        {
            var label = ci.KidValue("ConsumableLabelCode");
            var kind = ci.KidValue("ConsumableTypeEnum") ?? "supply";
            var station = ci.KidValue("ConsumableStation");
            return new Consumable(
                Name: $"{ColorName(label)} {kind}".Trim(),
                Kind: kind,
                ColorCode: label,
                PercentRemaining: ci.KidValue("ConsumablePercentageLevelRemaining").ToInt(),
                State: ci.Kid("ConsumableLifeState")?.KidValue("ConsumableState") ?? "unknown",
                ProductNumber: ci.KidValue("ProductNumber"),
                SelectibilityNumber: ci.KidValue("ConsumableSelectibilityNumber"),
                LowThreshold: ci.KidValue("ConsumableLowThreshold").ToInt(),
                EstimatedPagesRemaining: station is not null ? pagesLeft.GetValueOrDefault(station) : null,
                Installed: DateOnly.TryParse(ci.Kid("Installation")?.KidValue("Date"), CultureInfo.InvariantCulture, out var d) ? d : null);
        }).ToList();
    }

    public static ProductInfo ParseProductConfig(XDocument doc)
    {
        var info = doc.Root!.Kid("ProductInformation") ?? doc.Root!;
        return new ProductInfo(
            MakeAndModel: info.KidValue("MakeAndModel") ?? "Unknown printer",
            Family: info.KidValue("MakeAndModelFamily"),
            SerialNumber: info.KidValue("SerialNumber"),
            ProductNumber: info.KidValue("ProductNumber"),
            Uuid: info.KidValue("UUID"),
            FirmwareDate: info.Kid("Version")?.KidValue("Date"),
            AdminPasswordSet: info.KidValue("PasswordStatus") switch { "set" => true, "notSet" => false, _ => null });
    }

    public static UsageCounters ParseUsage(XDocument doc)
    {
        var printer = doc.Root!.Kid("PrinterSubunit");
        var scanner = doc.Root!.Kid("ScannerEngineSubunit");
        return new UsageCounters(
            printer?.KidValue("TotalImpressions").ToInt(),
            printer?.KidValue("DuplexSheets").ToInt(),
            printer?.KidValue("JamEvents").ToInt(),
            printer?.KidValue("MispickEvents").ToInt(),
            scanner?.Elements().Sum(e => e.Value.Trim().ToInt() ?? 0));
    }

    public static IReadOnlyList<LedmEvent> ParseEventTable(XDocument doc) =>
        doc.Root!.Kids("Event").Select(e => new LedmEvent(
            e.KidValue("UnqualifiedEventCategory") ?? "unknown",
            e.KidValue("AgingStamp"),
            e.Kid("Payload")?.KidValue("ResourceType"),
            e.Kid("Payload")?.KidValue("ResourceURI"))).ToList();

    private static string ColorName(string? code) => code switch
    {
        "K" => "Black",
        "C" => "Cyan",
        "M" => "Magenta",
        "Y" => "Yellow",
        "CMY" => "Tri-color",
        null => "",
        _ => code,
    };
}

public sealed record LedmEvent(string Category, string? AgingStamp, string? ResourceType, string? ResourceUri);
