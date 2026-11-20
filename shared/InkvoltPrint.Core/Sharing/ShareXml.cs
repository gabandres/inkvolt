using System.Globalization;
using System.Text;
using System.Xml;
using System.Xml.Linq;
using InkvoltPrint.Core.Escl;

namespace InkvoltPrint.Core.Sharing;

/// <summary>What a shared scanner calls itself on the network: its name, maker and the eSCL UUID kept for it on this PC.</summary>
public sealed record ShareIdentity(string Name, string? Manufacturer, Guid Uuid);

/// <summary>The scan an eSCL client asked for (its ScanSettings), as this PC's scanner will run it.</summary>
/// <param name="Format">What each page is sent as: <c>image/jpeg</c> or <c>application/pdf</c> (one page per document).</param>
public sealed record ShareScanSettings(ScanRequest Request, string Format);

/// <summary>A client's ScanSettings this PC won't run: <see cref="Status"/> is the HTTP answer (400 malformed, 409 not offered).</summary>
public sealed class ShareRequestException(int status, string reason) : Exception(reason)
{
    public int Status { get; } = status;
}

/// <summary>
/// The eSCL documents a shared scanner serves (Mopria eSCL 2.6x, as <see cref="ScannerCapabilities.Parse"/> and sane-airscan read
/// them) and the one it reads: a client's ScanSettings, which comes from any device on the network and is read as hostile.
/// </summary>
public static class ShareXml
{
    public const string Version = "2.63";
    public const string Jpeg = "image/jpeg";
    public const string Pdf = ScannerPdf.MediaType;

    /// <summary>Every page goes out as JPEG, or a PDF of it.</summary>
    public static readonly IReadOnlyList<string> Formats = [Jpeg, Pdf];

    /// <summary>The intents listed; WIA and TWAIN have no such setting, so each scans the same.</summary>
    public static readonly IReadOnlyList<string> Intents = ["Document", "TextAndGraphic", "Photo", "Preview"];

    /// <summary>The longest ScanSettings read (a real one is under 2 KB).</summary>
    public const int MaxSettingsBytes = 16 * 1024;

    /// <summary>The most elements a ScanSettings may hold, and how deep (a real one has about 20, four deep).</summary>
    public const int MaxElements = 200, MaxDepth = 8;

    /// <summary>The longest text an element may hold.</summary>
    public const int MaxText = 128;

    private static readonly XNamespace Scan = EsclXml.Scan, Pwg = EsclXml.Pwg;

    /// <summary>ScannerCapabilities for <paramref name="caps"/> (the scanner's own: sources, sizes, color modes, resolutions).</summary>
    public static byte[] Capabilities(ScannerCapabilities caps, ShareIdentity id)
    {
        var root = new XElement(Scan + "ScannerCapabilities",
            new XAttribute(XNamespace.Xmlns + "scan", Scan),
            new XAttribute(XNamespace.Xmlns + "pwg", Pwg),
            new XElement(Pwg + "Version", Version),
            new XElement(Pwg + "MakeAndModel", id.Name),
            new XElement(Scan + "UUID", id.Uuid.ToString("D")));
        if (id.Manufacturer is { Length: > 0 } maker) root.Add(new XElement(Scan + "Manufacturer", maker));
        if (caps.Platen is { } platen) root.Add(new XElement(Scan + "Platen", Input("PlatenInputCaps", platen)));
        if (caps.Adf is { } adf)
        {
            var feeder = new XElement(Scan + "Adf", Input("AdfSimplexInputCaps", adf));
            if (caps.AdfDuplex) feeder.Add(Input("AdfDuplexInputCaps", adf));
            root.Add(feeder);
        }
        return Bytes(root);
    }

    private static XElement Input(string name, InputCaps input)
    {
        var resolutions = Resolutions(input);
        var max = resolutions.Max();
        return new XElement(Scan + name,
            new XElement(Scan + "MinWidth", input.MinWidth),
            new XElement(Scan + "MaxWidth", input.MaxWidth),
            new XElement(Scan + "MinHeight", input.MinHeight),
            new XElement(Scan + "MaxHeight", input.MaxHeight),
            new XElement(Scan + "MaxScanRegions", 1),
            new XElement(Scan + "SettingProfiles",
                new XElement(Scan + "SettingProfile",
                    new XElement(Scan + "ColorModes", input.ColorModes.Select(m => new XElement(Scan + "ColorMode", m))),
                    new XElement(Scan + "DocumentFormats",
                        Formats.Select(f => new XElement(Pwg + "DocumentFormat", f)),
                        Formats.Select(f => new XElement(Scan + "DocumentFormatExt", f))),
                    new XElement(Scan + "SupportedResolutions",
                        new XElement(Scan + "DiscreteResolutions", resolutions.Select(r => new XElement(Scan + "DiscreteResolution",
                            new XElement(Scan + "XResolution", r), new XElement(Scan + "YResolution", r))))),
                    new XElement(Scan + "ColorSpaces", new XElement(Scan + "ColorSpace", "sRGB")))),
            new XElement(Scan + "SupportedIntents", Intents.Select(i => new XElement(Scan + "Intent", i))),
            new XElement(Scan + "MaxOpticalXResolution", max),
            new XElement(Scan + "MaxOpticalYResolution", max),
            new XElement(Scan + "RiskyLeftMargin", 0),
            new XElement(Scan + "RiskyRightMargin", 0),
            new XElement(Scan + "RiskyTopMargin", 0),
            new XElement(Scan + "RiskyBottomMargin", 0));
    }

    /// <summary>One job as ScannerStatus lists it.</summary>
    /// <param name="Path">The job's address on this server (<c>/eSCL/ScanJobs/…</c>).</param>
    /// <param name="State">eSCL's job state: Pending, Processing, Completed, Canceled or Aborted.</param>
    public sealed record JobLine(string Path, Guid Uuid, string State, int AgeSeconds, int ImagesCompleted, string? Reason);

    /// <summary>ScannerStatus: <paramref name="state"/> (Idle or Processing), the feeder's state when known, and the asker's jobs.</summary>
    public static byte[] Status(string state, string? adfState, IEnumerable<JobLine> jobs)
    {
        var root = new XElement(Scan + "ScannerStatus",
            new XAttribute(XNamespace.Xmlns + "scan", Scan),
            new XAttribute(XNamespace.Xmlns + "pwg", Pwg),
            new XElement(Pwg + "Version", Version),
            new XElement(Pwg + "State", state));
        if (adfState is not null) root.Add(new XElement(Scan + "AdfState", adfState));
        var lines = jobs.ToList();
        if (lines.Count > 0)
            root.Add(new XElement(Scan + "Jobs", lines.Select(j =>
            {
                var info = new XElement(Scan + "JobInfo",
                    new XElement(Pwg + "JobUri", j.Path),
                    new XElement(Pwg + "JobUuid", j.Uuid.ToString("D")),
                    new XElement(Scan + "Age", j.AgeSeconds),
                    new XElement(Pwg + "ImagesCompleted", j.ImagesCompleted),
                    new XElement(Pwg + "ImagesToTransfer", j.State is "Pending" or "Processing" ? 1 : 0),
                    new XElement(Pwg + "JobState", j.State));
                if (j.Reason is not null) info.Add(new XElement(Pwg + "JobStateReasons", new XElement(Pwg + "JobStateReason", j.Reason)));
                return info;
            })));
        return Bytes(root);
    }

    /// <summary>ScanImageInfo for the last page sent: its size in pixels.</summary>
    public static byte[] ImageInfo(string path, Guid uuid, int width, int height, int components) => Bytes(new XElement(Scan + "ScanImageInfo",
        new XAttribute(XNamespace.Xmlns + "scan", Scan),
        new XAttribute(XNamespace.Xmlns + "pwg", Pwg),
        new XElement(Pwg + "JobUri", path),
        new XElement(Pwg + "JobUuid", uuid.ToString("D")),
        new XElement(Scan + "ActualWidth", width),
        new XElement(Scan + "ActualHeight", height),
        new XElement(Scan + "ActualBytesPerLine", (long)width * Math.Max(components, 1))));

    private static byte[] Bytes(XElement root)
    {
        var text = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + root.ToString(SaveOptions.DisableFormatting);
        return Encoding.UTF8.GetBytes(text);
    }

    private static readonly XmlReaderSettings Hostile = new()
    {
        DtdProcessing = DtdProcessing.Prohibit,
        XmlResolver = null,
        MaxCharactersInDocument = MaxSettingsBytes,
        MaxCharactersFromEntities = 0,
        IgnoreComments = true,
        IgnoreProcessingInstructions = true,
    };

    /// <summary>
    /// A client's ScanSettings as a scan this scanner can run, or <see cref="ShareRequestException"/>: 400 for a body that isn't one
    /// (too long, a DTD, too many or too deeply nested elements, a number that isn't one or out of range, a region in other units), 409
    /// for one asking what the scanner doesn't offer (a source, a color mode, a format). Unknown elements are left alone, as eSCL
    /// asks; the resolution is the scanner's nearest and the region is kept inside the source when the scan is planned.
    /// </summary>
    public static ShareScanSettings ReadSettings(ReadOnlySpan<byte> body, ScannerCapabilities caps)
    {
        if (body.Length is 0 or > MaxSettingsBytes) throw new ShareRequestException(400, "ScanSettings missing or too long.");
        var values = new Dictionary<string, string>(StringComparer.Ordinal);
        XNamespace? rootNs = null;
        string? rootName = null;
        try
        {
            using var reader = XmlReader.Create(new MemoryStream(body.ToArray(), writable: false), Hostile);
            var elements = 0;
            var path = new List<string>();
            while (reader.Read())
            {
                switch (reader.NodeType)
                {
                    case XmlNodeType.Element:
                        if (++elements > MaxElements || reader.Depth >= MaxDepth) throw new ShareRequestException(400, "ScanSettings too large.");
                        if (rootName is null)
                        {
                            rootName = reader.LocalName;
                            rootNs = reader.NamespaceURI;
                        }
                        while (path.Count > reader.Depth) path.RemoveAt(path.Count - 1);
                        path.Add(reader.LocalName);
                        if (reader.IsEmptyElement) path.RemoveAt(path.Count - 1);
                        break;
                    case XmlNodeType.EndElement:
                        while (path.Count > reader.Depth) path.RemoveAt(path.Count - 1);
                        break;
                    case XmlNodeType.Text or XmlNodeType.CDATA:
                        var text = reader.Value.Trim();
                        if (text.Length > MaxText) throw new ShareRequestException(400, "ScanSettings value too long.");
                        // The first value of each name wins (one region is all this scanner takes).
                        if (path.Count > 0) values.TryAdd(path[^1], text);
                        break;
                }
            }
        }
        catch (XmlException)
        {
            throw new ShareRequestException(400, "ScanSettings isn't well-formed XML.");
        }
        if (rootName != "ScanSettings" || rootNs != Scan) throw new ShareRequestException(400, "Not an eSCL ScanSettings.");

        var duplex = values.GetValueOrDefault("Duplex") is "true" or "True" or "1";
        var source = values.GetValueOrDefault("InputSource") switch
        {
            // No source named: the glass, or the feeder of a scanner that has only one.
            null or "" => caps.Platen is null && caps.Adf is not null ? (duplex && caps.AdfDuplex ? ScanSource.AdfDuplex : ScanSource.Adf) : ScanSource.Platen,
            "Platen" => ScanSource.Platen,
            "Feeder" => duplex ? ScanSource.AdfDuplex : ScanSource.Adf,
            _ => throw new ShareRequestException(409, "Source not offered."),
        };
        if (!caps.Sources.Contains(source)) throw new ShareRequestException(409, "Source not offered.");
        var input = caps.For(source)!;

        var colorMode = values.GetValueOrDefault("ColorMode");
        var color = colorMode switch
        {
            null or "" => input.ColorModes.Contains("RGB24") || input.ColorModes.Count == 0 ? ScanColor.Color : ScanColor.Grayscale,
            "RGB24" or "RGB48" => ScanColor.Color,
            "Grayscale8" or "Grayscale16" => ScanColor.Grayscale,
            "BlackAndWhite1" => ScanColor.BlackAndWhite,
            _ => throw new ShareRequestException(409, "Color mode not offered."),
        };
        var mode = color switch { ScanColor.Color => "RGB24", ScanColor.Grayscale => "Grayscale8", _ => "BlackAndWhite1" };
        if (input.ColorModes.Count > 0 && !input.ColorModes.Contains(mode)) throw new ShareRequestException(409, "Color mode not offered.");

        var format = values.GetValueOrDefault("DocumentFormatExt") is { Length: > 0 } ext ? ext : values.GetValueOrDefault("DocumentFormat") ?? Jpeg;
        format = format.Split(';')[0].Trim().ToLowerInvariant();
        if (format.Length == 0) format = Jpeg;
        if (!Formats.Contains(format)) throw new ShareRequestException(409, "Format not offered.");

        // Only a resolution the capabilities list (both directions the same): a scanner whose driver gives none lists 300 dpi.
        var offered = Resolutions(input);
        var xRes = Number(values, "XResolution", 1, 19200);
        var yRes = Number(values, "YResolution", 1, 19200);
        if (xRes is { } rx && yRes is { } ry && rx != ry) throw new ShareRequestException(409, "Resolution not offered.");
        var resolution = xRes ?? yRes ?? (offered.Contains(300) ? 300 : offered[0]);
        if (!offered.Contains(resolution)) throw new ShareRequestException(409, "Resolution not offered.");

        var units = values.GetValueOrDefault("ContentRegionUnits");
        if (units is not (null or "" or "escl:ThreeHundredthsOfInches" or "ThreeHundredthsOfInches"))
            throw new ShareRequestException(400, "Region units not ThreeHundredthsOfInches.");
        const int MaxRegion = 300 * 1000; // 1,000 inches: what a number may be at all
        var width = Number(values, "Width", 1, MaxRegion);
        var height = Number(values, "Height", 1, MaxRegion);
        var x = Number(values, "XOffset", 0, MaxRegion);
        var y = Number(values, "YOffset", 0, MaxRegion);
        // Kept inside the source before anything is planned (a client's rounding may overshoot by a little), and the page's pixels bounded.
        x = x is { } ox ? Math.Min(ox, Math.Max(input.MaxWidth - 1, 0)) : null;
        y = y is { } oy ? Math.Min(oy, Math.Max(input.MaxHeight - 1, 0)) : null;
        width = width is { } w ? Math.Min(w, Math.Max(input.MaxWidth - (x ?? 0), 1)) : null;
        height = height is { } h ? Math.Min(h, Math.Max(input.MaxHeight - (y ?? 0), 1)) : null;
        if (Pixels(width ?? input.MaxWidth, resolution) > MaxPixels || Pixels(height ?? input.MaxHeight, resolution) > MaxPixels)
            throw new ShareRequestException(409, "Region too large at that resolution.");
        var intent = values.GetValueOrDefault("Intent") is { Length: > 0 and <= 32 } i && i.All(char.IsAsciiLetterOrDigit) ? i : "Document";
        return new ShareScanSettings(new ScanRequest(source, color, resolution, intent, width, height, x is 0 ? null : x, y is 0 ? null : y), format);
    }

    /// <summary>The most pixels a page may have across or down (JPEG's own limit), whatever the scanner offers.</summary>
    public const int MaxPixels = 65_000;

    /// <summary>The resolutions ScannerCapabilities lists for a source (300 dpi when the driver gives none).</summary>
    public static IReadOnlyList<int> Resolutions(InputCaps input) => input.Resolutions.Count > 0 ? input.Resolutions : [300];

    private static long Pixels(int threeHundredths, int dpi) => (long)threeHundredths * dpi / 300;

    private static int? Number(Dictionary<string, string> values, string name, int min, int max)
    {
        if (!values.TryGetValue(name, out var text) || text.Length == 0) return null;
        if (!int.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var n) || n < min || n > max)
            throw new ShareRequestException(400, $"{name} out of range.");
        return n;
    }
}
