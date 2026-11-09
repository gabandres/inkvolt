using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Drivers;

/// <summary>One download as an Epson support page lists it, read from the page's own markup (all of it untrusted).</summary>
public sealed record EpsonDownload(string Section, string Title, string? SizeText, string FileName, Uri Href, string Description, string Systems);

/// <summary>
/// Epson's drivers, from epson.com (the US site, whose pages list every Windows download): the site's product search
/// (<c>/search/autocomplete/SearchBox?term=</c>, JSON) gives the model's support page, and that page with this PC's Windows as its
/// filter (<c>?review-filter=Windows 11</c>, what its OS menu and GO do) lists the downloads, each with its title, size, file, the
/// systems it is for and a description that says when it is for ARM. The driver chosen is the first Epson lists for the kind of
/// device, this Windows and this processor; a combo package (drivers and every utility, hundreds of MB) is never chosen.
/// </summary>
public sealed partial class EpsonDrivers(BoundedHttp http) : IDriverCatalog
{
    private static readonly MakerSource Source = MakerSource.Epson;
    private const long MaxSearch = 2 << 20, MaxPage = 6 << 20;
    private static readonly TimeSpan Limit = TimeSpan.FromSeconds(30);

    public bool LooksUp(string? maker) => string.Equals(maker, Source.Maker, StringComparison.OrdinalIgnoreCase);

    public async Task<DriverLookup> FindAsync(DriverQuery query, CancellationToken ct)
    {
        var model = ModelWords(query.Model);
        if (model.Length == 0) return DriverLookup.None(NoOffer.NotFound);
        try
        {
            var search = await http.GetTextAsync(new Uri("https://epson.com/search/autocomplete/SearchBox?term=" + Uri.EscapeDataString(model)), Source.PageHosts,
                MaxSearch, Limit, ct).ConfigureAwait(false);
            if (SupportPage(search, query.Model, query.Kind) is not { } support) return DriverLookup.None(NoOffer.NotFound);
            var page = new Uri(support, "?review-filter=" + Uri.EscapeDataString(OsFilter(query.Windows)).Replace("%20", "+", StringComparison.Ordinal));
            var html = await http.GetTextAsync(page, Source.PageHosts, MaxPage, Limit, ct).ConfigureAwait(false);
            return Choose(ParsePage(html), query, support);
        }
        catch (FetchException ex)
        {
            return DriverLookup.None(NoOffer.Unreachable, problem: ex.Problem);
        }
    }

    /// <summary>The value of the page's OS menu for this Windows.</summary>
    public static string OsFilter(PcWindows windows) => windows == PcWindows.Windows11 ? "Windows 11" : "Windows 10 64-bit";

    // ---------------------------------------------------------------- the search: which support page is the model's

    /// <summary>The model's words, Epson's name and the kind dropped: "Epson Perfection V19" → "perfection v19".</summary>
    public static string ModelWords(string name)
    {
        var words = Regex.Replace(name.ToLowerInvariant(), @"[^a-z0-9\-]+", " ").Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Where(w => w != "epson").ToList();
        while (words.Count > 0 && KindWords.Contains(words[^1])) words.RemoveAt(words.Count - 1);
        return string.Join(' ', words);
    }

    private static readonly HashSet<string> KindWords = ["scanner", "printer", "photo", "series", "all-in-one", "allinone", "aio", "mfp", "usb", "-"];

    /// <summary>Words after a model's that make it another model ("V19 II" isn't the V19).</summary>
    private static readonly HashSet<string> VariantWords = ["ii", "iii", "iv", "v", "plus", "pro", "se", "xl", "wide", "max", "mini", "s", "w"];

    [GeneratedRegex(@"^/Support/[A-Za-z0-9/_\-]{1,200}/s/SPT_[A-Za-z0-9_\-]{1,40}$")]
    private static partial Regex SupportPath();

    /// <summary>
    /// The support page of the product the search found for this model and kind: its name the model's words exactly (the kind and
    /// "Epson" aside), else the shortest name that has them in a row with no variant word after; never a refurbished listing's own.
    /// Null: none, or the search's answer can't be read.
    /// </summary>
    public static Uri? SupportPage(string searchJson, string model, NeedsDriverKind kind)
    {
        var want = ModelWords(model);
        if (want.Length == 0) return null;
        var type = kind == NeedsDriverKind.Scanner ? "SCANNER" : "PRINTER";
        try
        {
            using var doc = JsonDocument.Parse(searchJson, new JsonDocumentOptions { MaxDepth = 16 });
            if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("products", out var products)
                || products.ValueKind != JsonValueKind.Array) return null;
            var found = new List<(string Words, string Path)>();
            foreach (var p in products.EnumerateArray().Take(50))
            {
                if (p.ValueKind != JsonValueKind.Object) continue;
                var name = Text(p, "name");
                var path = Text(p, "supportProductId");
                if (name is null || path is null || !SupportPath().IsMatch(path)) continue;
                if (Text(p, "productType") is { } t && !string.Equals(t, type, StringComparison.OrdinalIgnoreCase)) continue;
                if (name.Contains("ReNew", StringComparison.OrdinalIgnoreCase) || name.Contains("Refurbished", StringComparison.OrdinalIgnoreCase)) continue;
                found.Add((ModelWords(name), path));
            }
            var exact = found.FirstOrDefault(f => f.Words == want);
            var pick = exact.Path ?? found.Where(f => Contains(f.Words, want)).OrderBy(f => f.Words.Length).Select(f => f.Path).FirstOrDefault();
            return pick is null ? null : new Uri("https://epson.com" + pick);
        }
        catch (JsonException)
        {
            return null;
        }
    }

    private static string? Text(JsonElement e, string name) =>
        e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 and < 400 } s ? s : null;

    private static bool Contains(string words, string want)
    {
        var w = words.Split(' ');
        var m = want.Split(' ');
        for (var i = 0; i + m.Length <= w.Length; i++)
            if (w.AsSpan(i, m.Length).SequenceEqual(m) && (i + m.Length == w.Length || !VariantWords.Contains(w[i + m.Length])))
                return true;
        return false;
    }

    // ---------------------------------------------------------------- the support page: its downloads

    [GeneratedRegex(@"data-dl_title=""([^""]{1,300})""")]
    private static partial Regex TitleAttr();

    [GeneratedRegex(@"data-dl_name=""([^""]{1,200})""")]
    private static partial Regex NameAttr();

    [GeneratedRegex(@"href=""(https?://[^""\s]{1,500})""\s*>\s*Download")]
    private static partial Regex DownloadHref();

    [GeneratedRegex(@"([\d.]{1,8})&nbsp;(KB|MB|GB)", RegexOptions.IgnoreCase)]
    private static partial Regex Size();

    [GeneratedRegex(@"data-parent=""#([a-z_\-]{1,40})""")]
    private static partial Regex Section();

    [GeneratedRegex(@"class=""sub-body"">(.{0,4000}?)</p>", RegexOptions.Singleline)]
    private static partial Regex SubBody();

    [GeneratedRegex(@"Compatible systems\s*:\s*</p>\s*<p class=""sub-body"">(.{0,4000}?)</p>", RegexOptions.Singleline)]
    private static partial Regex Systems();

    [GeneratedRegex(@"<[^>]{0,2000}>")]
    private static partial Regex Tags();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Spaces();

    /// <summary>
    /// Every download the page lists, in its order, each in the section it's under ("recommended", "driver", "utilities"…). At most
    /// 200; an entry missing its title, file or https address is left out; every text shortened.
    /// </summary>
    public static IReadOnlyList<EpsonDownload> ParsePage(string html)
    {
        var list = new List<EpsonDownload>();
        var parts = html.Split("<div class=\"panel-heading\">", StringSplitOptions.None);
        foreach (var part in parts.Skip(1).Take(200))
        {
            var title = TitleAttr().Match(part);
            var name = NameAttr().Match(part);
            var href = DownloadHref().Match(part);
            var section = Section().Match(part);
            if (!title.Success || !name.Success || !href.Success || !section.Success) continue;
            if (!Uri.TryCreate(WebUtility.HtmlDecode(href.Groups[1].Value), UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps) continue;
            var size = Size().Match(part);
            var body = SubBody().Match(part);
            var systems = Systems().Match(part);
            list.Add(new EpsonDownload(section.Groups[1].Value, Plain(title.Groups[1].Value, 120), size.Success ? $"{size.Groups[1].Value} {size.Groups[2].Value.ToUpperInvariant()}" : null,
                Plain(name.Groups[1].Value, 120), uri, body.Success ? Plain(body.Groups[1].Value, 600) : "", systems.Success ? Plain(systems.Groups[1].Value, 600) : ""));
        }
        return list;
    }

    private static string Plain(string html, int max)
    {
        var s = Spaces().Replace(WebUtility.HtmlDecode(Tags().Replace(html, " ")).Replace(' ', ' '), " ").Trim();
        return s.Length > max ? s[..max].TrimEnd() + "…" : s;
    }

    /// <summary>ARM as Epson and Microsoft write it: "ARM", "Arm64", "Windows on Arm", "arm-based".</summary>
    [GeneratedRegex(@"\b(arm|arm64|aarch64)\b", RegexOptions.IgnoreCase)]
    private static partial Regex Arm();

    [GeneratedRegex(@"\b(x64|x86-64|x86_64|amd64|intel|amd)\b", RegexOptions.IgnoreCase)]
    private static partial Regex X64();

    [GeneratedRegex(@"\bv(\d{1,4}(?:\.\d{1,6}){1,4})\b", RegexOptions.IgnoreCase)]
    private static partial Regex Version();

    /// <summary>
    /// The download to offer: under "driver", the kind's own (a scanner driver for a scanner, a printer driver for a printer), not a
    /// combo package, listed for this Windows (the page's own list of systems), from one of Epson's download hosts: the first in
    /// Epson's order; on ARM64 the first that says it is for ARM, on x64 the first that isn't for ARM only (one that names ARM and not
    /// x64, Intel or AMD). None for ARM64 when the page has the kind's drivers but none for ARM (an x64 driver doesn't load on ARM64
    /// Windows).
    /// </summary>
    public static DriverLookup Choose(IReadOnlyList<EpsonDownload> downloads, DriverQuery query, Uri page)
    {
        var kindWord = query.Kind == NeedsDriverKind.Scanner ? "Scan" : "Printer";
        var os = query.Windows == PcWindows.Windows11 ? "Windows 11" : "Windows 10 64-bit";
        var fits = downloads.Where(d => d.Section is "driver" or "drivers" && d.Title.Contains("Driver", StringComparison.OrdinalIgnoreCase)
                                        && d.Title.Contains(kindWord, StringComparison.OrdinalIgnoreCase)
                                        && !d.Title.Contains("Combo", StringComparison.OrdinalIgnoreCase)
                                        && (d.Systems.Length == 0 || d.Systems.Contains(os, StringComparison.OrdinalIgnoreCase))
                                        && BoundedHttp.IsAllowed(d.Href, Source.DownloadHosts)).ToList();
        static bool ForArm(EpsonDownload d) => Arm().IsMatch(d.Title) || Arm().IsMatch(d.Description);
        static bool ArmOnly(EpsonDownload d) => ForArm(d) && !X64().IsMatch(d.Title) && !X64().IsMatch(d.Description);
        var pick = query.Arch == PcArch.Arm64 ? fits.FirstOrDefault(ForArm) : fits.FirstOrDefault(d => !ArmOnly(d));
        if (pick is null) return DriverLookup.None(fits.Count > 0 ? NoOffer.NoArm64 : NoOffer.NotFound, page);
        var title = Version().Replace(pick.Title, "").Trim();
        var version = Version().Match(pick.Title) is { Success: true } v ? v.Groups[1].Value : null;
        return DriverLookup.Found(new DriverOffer(title.Length > 0 ? title : pick.Title, version, pick.SizeText, pick.Href, SafeFileName(pick.FileName, pick.Href), page));
    }

    /// <summary>The file's own name, kept to letters, digits, '.', '_' and '-', ending in .exe: never a path.</summary>
    private static string SafeFileName(string name, Uri href)
    {
        var raw = Path.GetFileName(href.AbsolutePath);
        var s = Regex.Replace(raw.Length > 0 ? raw : name, @"[^A-Za-z0-9._\-]", "_").Trim('.');
        if (s.Length is 0 or > 100) s = "driver";
        return s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? s : s + ".exe";
    }
}
