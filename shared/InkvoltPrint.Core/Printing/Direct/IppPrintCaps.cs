using System.Globalization;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Printing.Raster;

namespace InkvoltPrint.Core.Printing.Direct;

/// <summary>
/// A paper the printer offers: its PWG self-describing name (<c>na_letter_8.5x11in</c>), size and margins in hundredths of
/// a millimetre (as <c>media-col</c> has them), and where it came from (<c>media-source</c>) when the printer says.
/// </summary>
public sealed record DirectPaper(string Name, int WidthHmm, int HeightHmm, int Left, int Top, int Right, int Bottom)
{
    public string? Source { get; init; }

    public bool Borderless => Left == 0 && Top == 0 && Right == 0 && Bottom == 0;

    public double WidthInches => WidthHmm / 2540.0;
    public double HeightInches => HeightHmm / 2540.0;
}

/// <summary>
/// What a printer says it takes for driverless printing, read from Get-Printer-Attributes (PWG 5100.14 IPP Everywhere,
/// PWG 5102.4, Apple's <c>urf-supported</c>, Mopria's <c>pclm-*</c>). Everything a printer says is hostile input: lists are
/// cut to a few hundred values, sizes and resolutions outside what paper and printers have are left out.
/// </summary>
public sealed record IppPrintCaps
{
    /// <summary>The attributes asked for (<c>media-col-database</c> isn't part of "all" and has to be named).</summary>
    public static readonly string[] Requested =
    [
        "printer-state", "printer-state-reasons", "printer-state-message", "printer-make-and-model", "printer-name",
        "operations-supported", "document-format-supported",
        "pwg-raster-document-type-supported", "pwg-raster-document-resolution-supported", "pwg-raster-document-sheet-back",
        "urf-supported",
        "pclm-source-resolution-supported", "pclm-source-resolution-default", "pclm-strip-height-preferred",
        "pclm-compression-method-preferred", "pclm-raster-back-side",
        "media-col-database", "media-col-default", "media-col-ready", "media-default", "media-supported",
        "media-bottom-margin-supported", "media-left-margin-supported", "media-right-margin-supported", "media-top-margin-supported",
        "media-type-supported", "media-type-default",
        "sides-supported", "print-color-mode-supported", "print-color-mode-default", "copies-supported",
        "print-quality-supported", "print-quality-default",
    ];

    /// <summary>Most papers kept: a real printer lists a few dozen.</summary>
    public const int MaxPapers = 200;

    /// <summary>Most values read from any one list attribute.</summary>
    public const int MaxValues = 256;

    public const string PwgRasterType = "image/pwg-raster", UrfType = "image/urf", PclmType = "application/PCLm";

    /// <summary>The raster formats it takes, the most standard first (PWG raster, Apple raster, PCLm).</summary>
    public IReadOnlyList<RasterFormat> Formats { get; init; } = [];

    public IReadOnlyList<RasterColor> PwgColors { get; init; } = [];
    public IReadOnlyList<int> PwgDpis { get; init; } = [];
    public BackSide PwgBack { get; init; }
    public IReadOnlyList<RasterColor> UrfColors { get; init; } = [];
    public IReadOnlyList<int> UrfDpis { get; init; } = [];
    public BackSide UrfBack { get; init; }
    public IReadOnlyList<int> PclmDpis { get; init; } = [];
    public int PclmStripHeight { get; init; } = 16;
    public bool PclmRunLength { get; init; }
    public BackSide PclmBack { get; init; }

    public IReadOnlyList<DirectPaper> Papers { get; init; } = [];

    /// <summary>The paper it uses when not told (<c>media-col-default</c>, else <c>media-default</c>), null when it says neither.</summary>
    public DirectPaper? DefaultPaper { get; init; }

    public bool TwoSided { get; init; }
    public bool ShortEdge { get; init; }

    /// <summary>It prints in color (<c>print-color-mode-supported</c> lists <c>color</c>).</summary>
    public bool Color { get; init; }

    /// <summary>It prints in color unless told otherwise.</summary>
    public bool ColorByDefault { get; init; }

    /// <summary>Most copies it makes of a document itself (<c>copies-supported</c>); 1: the pages are sent again for each copy.</summary>
    public int MaxCopies { get; init; } = 1;

    /// <summary><c>print-quality</c> values it takes: 3 draft, 4 normal, 5 high.</summary>
    public IReadOnlyList<int> Qualities { get; init; } = [];

    public int? DefaultQuality { get; init; }

    /// <summary><c>media-type</c> keywords (<c>stationery</c>, <c>photographic-glossy</c>…).</summary>
    public IReadOnlyList<string> MediaTypes { get; init; } = [];

    public string? DefaultMediaType { get; init; }

    /// <summary>It takes Print-Job (<c>operations-supported</c> lists 2, or doesn't say).</summary>
    public bool PrintJob { get; init; } = true;

    public bool CancelJob { get; init; } = true;

    /// <summary>A raster format it takes and the operation to send it.</summary>
    public bool CanPrint => PrintJob && Formats.Count > 0;

    /// <summary>The raster formats in <c>document-format-supported</c> alone (the status reading has that much).</summary>
    public static IReadOnlyList<RasterFormat> FormatsIn(IEnumerable<string> documentFormats)
    {
        var listed = documentFormats.Take(MaxValues).Select(f => f.Trim()).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var formats = new List<RasterFormat>();
        if (listed.Contains(PwgRasterType)) formats.Add(RasterFormat.PwgRaster);
        if (listed.Contains(UrfType)) formats.Add(RasterFormat.Urf);
        if (listed.Contains(PclmType)) formats.Add(RasterFormat.Pclm);
        return formats;
    }

    public static IppPrintCaps From(IppResponse r)
    {
        var ops = r.Ints("operations-supported").Take(MaxValues).ToList();
        var pwgColors = Colors(r.Strs("pwg-raster-document-type-supported"), "sgray_8", "srgb_8");
        var pwgDpis = Dpis(r.Resolutions("pwg-raster-document-resolution-supported"));
        var urf = r.Strs("urf-supported").Take(MaxValues).ToList();
        var urfColors = Colors(urf, "W8", "SRGB24");
        var urfDpis = ReadUrfDpis(urf);
        var pclmDpis = Dpis(r.Resolutions("pclm-source-resolution-supported"));
        if (pclmDpis.Count == 0) pclmDpis = Dpis(r.Resolutions("pclm-source-resolution-default"));

        // A format counts only when the printer also says how to make it.
        var formats = FormatsIn(r.Strs("document-format-supported")).Where(f => f switch
        {
            RasterFormat.PwgRaster => pwgColors.Count > 0 && pwgDpis.Count > 0,
            RasterFormat.Urf => urfColors.Count > 0 && urfDpis.Count > 0,
            _ => pclmDpis.Count > 0,
        }).ToList();

        var papers = ReadPapers(r);
        var sides = r.Strs("sides-supported").Take(MaxValues).ToList();
        var colorModes = r.Strs("print-color-mode-supported").Take(MaxValues).ToList();
        var copies = r.Range("copies-supported") is { Upper: >= 1 } c ? Math.Min(c.Upper, 999) : 1;
        var qualities = r.Ints("print-quality-supported").Take(MaxValues).Where(q => q is 3 or 4 or 5).Distinct().Order().ToList();
        var pclmPreferred = r.Strs("pclm-compression-method-preferred").Take(MaxValues).ToList();
        return new IppPrintCaps
        {
            Formats = formats,
            PwgColors = pwgColors,
            PwgDpis = pwgDpis,
            PwgBack = Back(r.Str("pwg-raster-document-sheet-back")),
            UrfColors = urfColors,
            UrfDpis = urfDpis,
            UrfBack = urf.Contains("DM4") ? BackSide.ManualTumble : urf.Contains("DM3") ? BackSide.Rotated : urf.Contains("DM2") ? BackSide.Flipped : BackSide.Normal,
            PclmDpis = pclmDpis,
            PclmStripHeight = r.Int("pclm-strip-height-preferred") is { } strip and >= 1 and <= 4096 ? strip : 16,
            // Flate unless the printer puts run-length before it (JPEG, its other choice, would blur text).
            PclmRunLength = pclmPreferred.FindIndex(m => m == "rle") is var rle and >= 0
                            && (pclmPreferred.FindIndex(m => m == "flate") is var flate && (flate < 0 || rle < flate)),
            PclmBack = Back(r.Str("pclm-raster-back-side")),
            Papers = papers,
            DefaultPaper = ReadDefaultPaper(r, papers),
            TwoSided = sides.Contains("two-sided-long-edge"),
            ShortEdge = sides.Contains("two-sided-short-edge"),
            Color = colorModes.Contains("color") || (colorModes.Count == 0 && (pwgColors.Contains(RasterColor.Rgb8) || urfColors.Contains(RasterColor.Rgb8))),
            ColorByDefault = r.Str("print-color-mode-default") is "color" or "auto" && colorModes.Contains("color"),
            MaxCopies = copies,
            Qualities = qualities,
            DefaultQuality = r.Int("print-quality-default") is { } dq and >= 3 and <= 5 ? dq : null,
            MediaTypes = r.Strs("media-type-supported").Take(MaxValues).Where(Keyword).Distinct().ToList(),
            DefaultMediaType = r.Str("media-type-default") is { } mt && Keyword(mt) ? mt : null,
            PrintJob = ops.Count == 0 || ops.Contains(IppCodec.PrintJob),
            CancelJob = ops.Count == 0 || ops.Contains(IppCodec.CancelJob),
        };
    }

    private static IReadOnlyList<RasterColor> Colors(IEnumerable<string> values, string gray, string rgb)
    {
        var list = values.Take(MaxValues).ToList();
        var colors = new List<RasterColor>();
        if (list.Contains(gray)) colors.Add(RasterColor.Gray8);
        if (list.Contains(rgb)) colors.Add(RasterColor.Rgb8);
        return colors;
    }

    private static List<int> Dpis(IEnumerable<IppResolution> values) =>
        values.Take(MaxValues).Select(v => v.Dpi).OfType<int>().Where(d => d is >= 72 and <= 2400).Distinct().Order().ToList();

    /// <summary><c>RS300</c>, <c>RS300-600</c>: the resolutions in an <c>urf-supported</c> list.</summary>
    internal static List<int> ReadUrfDpis(IEnumerable<string> urf)
    {
        var dpis = new List<int>();
        foreach (var value in urf)
            if (value.StartsWith("RS", StringComparison.Ordinal))
                foreach (var part in value[2..].Split('-').Take(16))
                    if (int.TryParse(part, NumberStyles.None, CultureInfo.InvariantCulture, out var dpi) && dpi is >= 72 and <= 2400) dpis.Add(dpi);
        return dpis.Distinct().Order().ToList();
    }

    private static BackSide Back(string? keyword) => keyword switch
    {
        "flipped" => BackSide.Flipped,
        "rotated" => BackSide.Rotated,
        "manual-tumble" => BackSide.ManualTumble,
        _ => BackSide.Normal,
    };

    private static bool Keyword(string s) => s.Length is > 0 and <= 255 && s.All(c => c is >= 'a' and <= 'z' or >= '0' and <= '9' or '-' or '_' or '.');

    /// <summary>
    /// The papers: <c>media-col-database</c>'s entries with a fixed size (ranges are custom sizes, left out), with their margins;
    /// without it, <c>media-supported</c>'s self-describing names with the smallest margins in <c>media-*-margin-supported</c>.
    /// A paper with no margins is also listed with the smallest non-zero ones, so it can print with margins.
    /// </summary>
    private static List<DirectPaper> ReadPapers(IppResponse r)
    {
        var papers = new List<DirectPaper>();
        foreach (var col in r.Collections("media-col-database").Take(MaxPapers * 2))
            if (FromCollection(col) is { } paper) papers.Add(paper);
        if (papers.Count == 0)
        {
            int Margin(string name, bool zero) =>
                r.Ints(name).Take(MaxValues).Where(m => m is >= 0 and <= 5000 && (zero || m > 0)).DefaultIfEmpty(zero ? 0 : 635).Min();
            var borderless = new[] { "bottom", "left", "right", "top" }.All(s => r.Ints($"media-{s}-margin-supported").Contains(0));
            foreach (var name in r.Strs("media-supported").Take(MaxPapers))
            {
                if (Size(name) is not { } size) continue;
                papers.Add(new DirectPaper(name, size.W, size.H, Margin("media-left-margin-supported", false), Margin("media-top-margin-supported", false),
                    Margin("media-right-margin-supported", false), Margin("media-bottom-margin-supported", false)));
                if (borderless) papers.Add(new DirectPaper(name, size.W, size.H, 0, 0, 0, 0));
            }
        }
        return papers.DistinctBy(p => (p.Name, p.WidthHmm, p.HeightHmm, p.Left, p.Top, p.Right, p.Bottom)).Take(MaxPapers).ToList();
    }

    /// <summary>One <c>media-col</c> value as a paper, or null when it has no fixed size in range.</summary>
    public static DirectPaper? FromCollection(IppCollection col)
    {
        if (col.Collection("media-size") is not { } size || size.Int("x-dimension") is not { } w || size.Int("y-dimension") is not { } h) return null;
        if (w is < 500 or > 200_000 || h is < 500 or > 500_000) return null; // 5 mm to 2 m wide, 5 m long: past that, not paper
        int M(string name) => col.Int(name) is { } m and >= 0 and <= 5000 ? m : 0;
        var name = col.Str("media-size-name") is { } n && Keyword(n) ? n : Name(w, h);
        return new DirectPaper(name, w, h, M("media-left-margin"), M("media-top-margin"), M("media-right-margin"), M("media-bottom-margin"))
        {
            Source = col.Str("media-source") is { } s && Keyword(s) ? s : null,
        };
    }

    private static DirectPaper? ReadDefaultPaper(IppResponse r, IReadOnlyList<DirectPaper> papers)
    {
        if (r.Collections("media-col-default").FirstOrDefault() is { } col && FromCollection(col) is { } fromCol)
            return papers.FirstOrDefault(p => Same(p, fromCol) && p.Left == fromCol.Left && p.Top == fromCol.Top) ?? papers.FirstOrDefault(p => Same(p, fromCol)) ?? fromCol;
        if (r.Str("media-default") is { } name && Size(name) is { } size)
            return papers.FirstOrDefault(p => p.WidthHmm == size.W && p.HeightHmm == size.H && !p.Borderless)
                   ?? papers.FirstOrDefault(p => p.WidthHmm == size.W && p.HeightHmm == size.H);
        return null;
    }

    /// <summary>The same size within half a millimetre.</summary>
    public static bool Same(DirectPaper a, DirectPaper b) => Math.Abs(a.WidthHmm - b.WidthHmm) <= 50 && Math.Abs(a.HeightHmm - b.HeightHmm) <= 50;

    private static readonly Regex SelfDescribing = new(@"^[a-z0-9-]+_[a-z0-9.-]*_(\d{1,4}(?:\.\d{1,4})?)x(\d{1,5}(?:\.\d{1,4})?)(in|mm)$", RegexOptions.CultureInvariant, TimeSpan.FromMilliseconds(50));

    /// <summary>A PWG 5101.1 self-describing media name's size in hundredths of a millimetre (<c>iso_a4_210x297mm</c>), null for custom ranges or others.</summary>
    public static (int W, int H)? Size(string name)
    {
        if (name.Length > 128 || name.StartsWith("custom_min", StringComparison.Ordinal) || name.StartsWith("custom_max", StringComparison.Ordinal)) return null;
        var m = SelfDescribing.Match(name);
        if (!m.Success) return null;
        var unit = m.Groups[3].Value == "in" ? 2540.0 : 100.0;
        var w = double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture) * unit;
        var h = double.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture) * unit;
        if (w is < 500 or > 200_000 || h is < 500 or > 500_000) return null;
        return ((int)Math.Round(w), (int)Math.Round(h));
    }

    private static readonly (string Name, int W, int H)[] Known =
    [
        ("na_letter_8.5x11in", 21590, 27940), ("na_legal_8.5x14in", 21590, 35560), ("iso_a4_210x297mm", 21000, 29700),
        ("iso_a5_148x210mm", 14800, 21000), ("iso_a6_105x148mm", 10500, 14800), ("na_index-4x6_4x6in", 10160, 15240),
        ("na_5x7_5x7in", 12700, 17780), ("na_govt-letter_8x10in", 20320, 25400), ("om_small-photo_100x150mm", 10000, 15000),
        ("oe_photo-l_3.5x5in", 8890, 12700), ("na_executive_7.25x10.5in", 18415, 26670), ("iso_a3_297x420mm", 29700, 42000),
        ("jpn_hagaki_100x148mm", 10000, 14800), ("na_ledger_11x17in", 27940, 43180), ("iso_b5_176x250mm", 17600, 25000),
    ];

    /// <summary>The PWG name for a size: a known one when it matches within half a millimetre, else <c>custom_WxHmm</c>.</summary>
    public static string Name(int w, int h)
    {
        foreach (var k in Known)
            if (Math.Abs(k.W - w) <= 50 && Math.Abs(k.H - h) <= 50) return k.Name;
        return string.Create(CultureInfo.InvariantCulture, $"custom_{w / 100.0:0.##}x{h / 100.0:0.##}mm_{w / 100.0:0.##}x{h / 100.0:0.##}mm");
    }
}
