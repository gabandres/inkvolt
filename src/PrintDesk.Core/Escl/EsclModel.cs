using System.Xml.Linq;
using PrintDesk.Core.Ledm;

namespace PrintDesk.Core.Escl;

public enum ScanSource { Platen, Adf, AdfDuplex }

public sealed record InputCaps(
    int MinWidth, int MaxWidth, int MinHeight, int MaxHeight,
    IReadOnlyList<string> ColorModes,
    IReadOnlyList<string> DocumentFormats,
    IReadOnlyList<int> Resolutions,
    IReadOnlyList<string> Intents);

public sealed record ScannerCapabilities(
    string Version,
    string? MakeAndModel,
    string? Uuid,
    InputCaps? Platen,
    InputCaps? Adf,
    bool AdfDuplex)
{
    public IEnumerable<ScanSource> Sources
    {
        get
        {
            if (Platen is not null) yield return ScanSource.Platen;
            if (Adf is not null) yield return ScanSource.Adf;
            if (Adf is not null && AdfDuplex) yield return ScanSource.AdfDuplex;
        }
    }

    public InputCaps? For(ScanSource s) => s == ScanSource.Platen ? Platen : Adf;

    public static ScannerCapabilities Parse(XDocument doc)
    {
        var r = doc.Root!;
        var adf = r.Kid("Adf");
        return new ScannerCapabilities(
            r.KidValue("Version") ?? "0",
            r.KidValue("MakeAndModel"),
            r.KidValue("UUID"),
            ParseInput(r.Kid("Platen")?.Kid("PlatenInputCaps")),
            ParseInput(adf?.Kid("AdfSimplexInputCaps")),
            adf?.Kid("AdfDuplexInputCaps") is not null);
    }

    private static InputCaps? ParseInput(XElement? e)
    {
        if (e is null) return null;
        return new InputCaps(
            e.KidValue("MinWidth").ToInt() ?? 0, e.KidValue("MaxWidth").ToInt() ?? 2550,
            e.KidValue("MinHeight").ToInt() ?? 0, e.KidValue("MaxHeight").ToInt() ?? 3508,
            e.All("ColorMode").Select(x => x.Value.Trim()).Distinct().ToList(),
            e.All("DocumentFormatExt").Concat(e.All("DocumentFormat")).Select(x => x.Value.Trim()).Distinct().ToList(),
            e.All("XResolution").Select(x => x.Value.Trim().ToInt() ?? 0).Where(x => x > 0).Distinct().Order().ToList(),
            e.All("Intent").Select(x => x.Value.Trim()).Distinct().ToList());
    }
}

public sealed record ScannerStatus(string State, string? AdfState)
{
    public bool IsIdle => State == "Idle";
    public bool AdfLoaded => AdfState is "ScannerAdfLoaded";

    public static ScannerStatus Parse(XDocument doc) =>
        new(doc.Root!.KidValue("State") ?? "Unknown", doc.Root!.KidValue("AdfState"));
}

public enum ScanColor { Color, Grayscale }

public sealed record ScanRequest(
    ScanSource Source = ScanSource.Platen,
    ScanColor Color = ScanColor.Color,
    int Resolution = 300,
    string Intent = "Document",
    /// <summary>Region in 1/300 inch. Null = the source's full area, clamped to device max.</summary>
    int? Width = null,
    int? Height = null);

public static class EsclXml
{
    public static readonly XNamespace Scan = "http://schemas.hp.com/imaging/escl/2011/05/03";
    public static readonly XNamespace Pwg = "http://www.pwg.org/schemas/2010/12/sm";

    /// <summary>Always requests JPEG pages; PDF assembly and OCR happen locally so every page can be previewed.</summary>
    public static XDocument BuildScanSettings(ScanRequest req, ScannerCapabilities caps)
    {
        var input = caps.For(req.Source) ?? throw new InvalidOperationException($"Scanner has no {req.Source} source");
        var width = Math.Clamp(req.Width ?? input.MaxWidth, input.MinWidth, input.MaxWidth);
        var height = Math.Clamp(req.Height ?? input.MaxHeight, input.MinHeight, input.MaxHeight);
        var res = input.Resolutions.Count == 0 ? req.Resolution
            : input.Resolutions.MinBy(r => Math.Abs(r - req.Resolution));
        var color = req.Color == ScanColor.Color ? "RGB24" : "Grayscale8";
        if (input.ColorModes.Count > 0 && !input.ColorModes.Contains(color)) color = input.ColorModes[0];
        var intent = input.Intents.Count == 0 || input.Intents.Contains(req.Intent) ? req.Intent : input.Intents[0];

        var settings = new XElement(Scan + "ScanSettings",
            new XAttribute(XNamespace.Xmlns + "scan", Scan),
            new XAttribute(XNamespace.Xmlns + "pwg", Pwg),
            new XElement(Pwg + "Version", caps.Version),
            new XElement(Scan + "Intent", intent),
            new XElement(Pwg + "ScanRegions",
                new XElement(Pwg + "ScanRegion",
                    new XElement(Pwg + "Height", height),
                    new XElement(Pwg + "ContentRegionUnits", "escl:ThreeHundredthsOfInches"),
                    new XElement(Pwg + "Width", width),
                    new XElement(Pwg + "XOffset", 0),
                    new XElement(Pwg + "YOffset", 0))),
            new XElement(Pwg + "InputSource", req.Source == ScanSource.Platen ? "Platen" : "Feeder"),
            new XElement(Scan + "ColorMode", color),
            new XElement(Scan + "XResolution", res),
            new XElement(Scan + "YResolution", res),
            new XElement(Pwg + "DocumentFormat", "image/jpeg"),
            new XElement(Scan + "DocumentFormatExt", "image/jpeg"));
        if (req.Source == ScanSource.AdfDuplex) settings.Add(new XElement(Scan + "Duplex", true));
        return new XDocument(new XDeclaration("1.0", "UTF-8", null), settings);
    }
}
