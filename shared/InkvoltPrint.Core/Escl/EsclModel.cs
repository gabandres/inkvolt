using System.Xml.Linq;
using InkvoltPrint.Core.Ledm;

namespace InkvoltPrint.Core.Escl;

public enum ScanSource { Platen, Adf, AdfDuplex }

public sealed record InputCaps(
    int MinWidth, int MaxWidth, int MinHeight, int MaxHeight,
    IReadOnlyList<string> ColorModes,
    IReadOnlyList<string> DocumentFormats,
    IReadOnlyList<int> Resolutions,
    IReadOnlyList<string> Intents)
{
    /// <summary>The source lists <c>scan:DocumentFormatExt</c>; scanners that don't may not expect it in ScanSettings either.</summary>
    public bool HasDocumentFormatExt { get; init; } = true;

    /// <summary>Inkvolt asks for JPEG pages; a source listing formats without JPEG can't be scanned from.</summary>
    public bool OffersJpeg => DocumentFormats.Count == 0 || DocumentFormats.Contains("image/jpeg", StringComparer.OrdinalIgnoreCase);

    /// <summary>PDF and no JPEG (some feeders): scanned as PDF, its pages taken out as JPEG (<see cref="ScannerPdf"/>).</summary>
    public bool PdfOnly => !OffersJpeg && DocumentFormats.Contains(ScannerPdf.MediaType, StringComparer.OrdinalIgnoreCase);
}

public sealed record ScannerCapabilities(
    string Version,
    string? MakeAndModel,
    string? Uuid,
    InputCaps? Platen,
    InputCaps? Adf,
    bool AdfDuplex)
{
    /// <summary><c>scan:Manufacturer</c> (e.g. "EPSON"), when the scanner says.</summary>
    public string? Manufacturer { get; init; }

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

    /// <summary>
    /// Reads ScannerCapabilities (Mopria eSCL). Handles what differs between makers: settings given inline or as a named
    /// <c>scan:SettingProfile</c> an input refers to (<c>ref="…"</c>), resolutions as a list or a range, and discrete
    /// resolutions whose X and Y differ (left out, as sane-airscan does).
    /// </summary>
    public static ScannerCapabilities Parse(XDocument doc)
    {
        var r = doc.Root!;
        var named = r.Kid("SettingProfiles")?.Kids("SettingProfile")
            .Where(p => p.Attribute("name")?.Value is { Length: > 0 })
            .GroupBy(p => p.Attribute("name")!.Value)
            .ToDictionary(g => g.Key, g => g.First()) ?? [];
        var adf = r.Kid("Adf");
        return new ScannerCapabilities(
            r.KidValue("Version") ?? "0",
            r.KidValue("MakeAndModel"),
            r.KidValue("UUID"),
            ParseInput(r.Kid("Platen")?.Kid("PlatenInputCaps"), named),
            ParseInput(adf?.Kid("AdfSimplexInputCaps"), named),
            adf?.Kid("AdfDuplexInputCaps") is not null)
        {
            Manufacturer = r.KidValue("Manufacturer"),
        };
    }

    private static InputCaps? ParseInput(XElement? e, IReadOnlyDictionary<string, XElement> named)
    {
        if (e is null) return null;
        // Each profile is inline or a reference to a named one at the top; an unknown reference adds nothing.
        var profiles = e.Kid("SettingProfiles")?.Kids("SettingProfile")
            .Select(p => p.Attribute("ref")?.Value is { } name ? named.GetValueOrDefault(name) : p)
            .OfType<XElement>().ToList() ?? [];
        // No profiles at all (older layouts): read the settings from anywhere under the input.
        IReadOnlyList<XContainer> scope = e.Kid("SettingProfiles") is null ? [e] : profiles;
        var discrete = scope.SelectMany(p => p.All("DiscreteResolution"))
            .Select(d => (X: d.KidValue("XResolution").ToInt() ?? 0, Y: d.KidValue("YResolution").ToInt()))
            .Where(d => d.X > 0 && (d.Y is null || d.Y == d.X)).Select(d => d.X).ToList();
        if (discrete.Count == 0 && e.Kid("SettingProfiles") is null)
            discrete = e.All("XResolution").Select(x => x.Value.Trim().ToInt() ?? 0).Where(x => x > 0).ToList();
        var ranged = scope.SelectMany(p => p.All("XResolutionRange"))
            .SelectMany(x => RangeResolutions(x.KidValue("Min").ToInt() ?? 0, x.KidValue("Max").ToInt() ?? 0,
                x.KidValue("Step").ToInt() ?? 1, x.KidValue("Normal").ToInt() ?? 0));
        return new InputCaps(
            e.KidValue("MinWidth").ToInt() ?? 0, e.KidValue("MaxWidth").ToInt() ?? 2550,
            e.KidValue("MinHeight").ToInt() ?? 0, e.KidValue("MaxHeight").ToInt() ?? 3508,
            scope.SelectMany(p => p.All("ColorMode")).Select(x => x.Value.Trim()).Distinct().ToList(),
            scope.SelectMany(p => p.All("DocumentFormatExt").Concat(p.All("DocumentFormat"))).Select(x => x.Value.Trim()).Distinct().ToList(),
            (discrete.Count > 0 ? discrete : ranged).Distinct().Order().ToList(), // a list wins over a range, as in sane-airscan
            e.All("Intent").Select(x => x.Value.Trim()).Distinct().ToList())
        {
            HasDocumentFormatExt = scope.Any(p => p.All("DocumentFormatExt").Any()),
        };
    }

    private static readonly int[] UsualResolutions = [75, 100, 150, 200, 300, 400, 600, 1200];

    /// <summary>
    /// The resolutions to offer from a <c>scan:ResolutionRange</c>: the usual ones inside it that its step allows;
    /// when none are, the first eight values its step gives. An empty range offers its Normal resolution.
    /// </summary>
    public static IReadOnlyList<int> RangeResolutions(int min, int max, int step, int normal)
    {
        if (min <= 0 || max < min) return normal > 0 ? [normal] : [];
        step = Math.Max(step, 1);
        var usual = UsualResolutions.Where(r => r >= min && r <= max && (r - min) % step == 0).ToList();
        if (usual.Count > 0) return usual;
        var stepped = new List<int>();
        for (var r = min; r <= max && stepped.Count < 8; r += step) stepped.Add(r);
        return stepped;
    }
}

public sealed record ScanJobInfo(string Uri, string State, int? AgeSeconds);

public sealed record ScannerStatus(string State, string? AdfState, IReadOnlyList<ScanJobInfo> Jobs)
{
    public bool IsIdle => State == "Idle";
    public bool AdfLoaded => AdfState is "ScannerAdfLoaded";

    /// <summary>
    /// Why a scan can't start now, in plain words; null when it can. "Processing" and "Testing" (warming up) are fine:
    /// the job request waits while the scanner answers 503. For feeder scans, a reported feeder state other than loaded
    /// stops the scan with its reason (an empty feeder answers with a page error on some scanners instead).
    /// </summary>
    public string? Problem(bool feeder)
    {
        if (feeder && AdfState is not null && !AdfLoaded)
            return AdfState switch
            {
                "ScannerAdfJam" => "The document feeder is jammed. Clear the paper and try again.",
                "ScannerAdfDoorOpen" or "ScannerAdfHatchOpen" => "The document feeder's cover is open. Close it and try again.",
                "ScannerAdfMispick" or "ScannerAdfMultipickDetected" => "The document feeder couldn't pick up a page. Straighten the stack and try again.",
                "ScannerAdfInputTrayOverloaded" => "Too many pages in the document feeder. Take some out and try again.",
                "ScannerAdfDuplexPageTooShort" or "ScannerAdfDuplexPageTooLong" => "This page size can't be scanned on both sides. Scan one side, or use the glass.",
                _ => "Load the pages into the document feeder first.",
            };
        return State is "Idle" or "Processing" or "Testing" ? null : $"Scanner is {State.ToLowerInvariant()}.";
    }

    public static ScannerStatus Parse(XDocument doc)
    {
        var root = doc.Root!;
        var jobs = root.Kid("Jobs")?.Kids("JobInfo")
            .Select(j => new ScanJobInfo(j.KidValue("JobUri") ?? "", j.KidValue("JobState") ?? "", j.KidValue("Age").ToInt()))
            .Where(j => j.Uri.Length > 0)
            .ToList() ?? [];
        return new(root.KidValue("State") ?? "Unknown", root.KidValue("AdfState"), jobs);
    }
}

/// <summary>
/// Maker-specific eSCL behaviour, as documented by sane-airscan (airscan-escl.c): Epson scanners want the port in the
/// Host header even when it's the default; Brother feeders answer 404 if the next page is asked for too soon after the last.
/// </summary>
public sealed record EsclQuirks(bool PortInHost, bool NextLoadDelay)
{
    public static readonly EsclQuirks None = new(false, false);

    public static EsclQuirks For(ScannerCapabilities caps)
    {
        var model = caps.MakeAndModel ?? "";
        return new EsclQuirks(
            PortInHost: model.StartsWith("EPSON ", StringComparison.OrdinalIgnoreCase) || string.Equals(caps.Manufacturer, "EPSON", StringComparison.OrdinalIgnoreCase),
            NextLoadDelay: model.StartsWith("Brother ", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Wait before asking for the next feeder page: half the last page's load time, at most a second.</summary>
    public static TimeSpan NextLoadWait(TimeSpan lastLoad) =>
        TimeSpan.FromMilliseconds(Math.Clamp(lastLoad.TotalMilliseconds / 2, 0, 1000));
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

    /// <summary>
    /// Requests JPEG pages (PDF assembly and OCR happen locally so every page can be previewed), or PDF from a source that
    /// offers nothing else (<paramref name="format"/>: <see cref="ScannerPdf.MediaType"/>; its pages are taken out as JPEG).
    /// </summary>
    public static XDocument BuildScanSettings(ScanRequest req, ScannerCapabilities caps, string format = "image/jpeg")
    {
        var input = caps.For(req.Source) ?? throw new InvalidOperationException($"Scanner has no {req.Source} source");
        var width = Math.Clamp(req.Width ?? input.MaxWidth, input.MinWidth, input.MaxWidth);
        var height = Math.Clamp(req.Height ?? input.MaxHeight, input.MinHeight, input.MaxHeight);
        var res = Resolution(req, input);
        var color = req.Color == ScanColor.Color ? "RGB24" : "Grayscale8";
        // A missing mode falls back to the other of color/grey before black-and-white (which loses too much for OCR).
        if (input.ColorModes.Count > 0 && !input.ColorModes.Contains(color))
            color = input.ColorModes.FirstOrDefault(m => m is "RGB24" or "Grayscale8") ?? input.ColorModes[0];
        // "Document" isn't offered by every source (some feeders list only TextAndGraphic and Photo).
        var intent = input.Intents.Count == 0 || input.Intents.Contains(req.Intent) ? req.Intent
            : input.Intents.FirstOrDefault(i => i == "TextAndGraphic") ?? input.Intents[0];

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
            new XElement(Pwg + "DocumentFormat", format));
        if (input.HasDocumentFormatExt) settings.Add(new XElement(Scan + "DocumentFormatExt", format));
        if (req.Source == ScanSource.AdfDuplex) settings.Add(new XElement(Scan + "Duplex", true));
        return new XDocument(new XDeclaration("1.0", "UTF-8", null), settings);
    }

    /// <summary>The resolution a scan asks for: the source's closest to the request's.</summary>
    public static int Resolution(ScanRequest req, InputCaps input) =>
        input.Resolutions.Count == 0 ? req.Resolution : input.Resolutions.MinBy(r => Math.Abs(r - req.Resolution));
}
