using System.Text.Json;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Drivers;

/// <summary>
/// PFU's scanner drivers (fi and SP series, sold as Fujitsu's and now Ricoh's), from www.pfu.ricoh.com's global download pages: the
/// list of models (<c>/global/scanners/fisp/dl/</c>) links each model's page, which carries its downloads as JSON (each section's
/// downloads for each system, "win-11" or "win-10", with the file on origin.pfultd.com). The driver is PaperStream IP (TWAIN), the
/// 64-bit one first (what Inkvolt Print scans through), its ARM build on ARM64; then its ISIS one. ScanSnap models have no page
/// there (their software comes through ScanSnap's own account site and has no driver Inkvolt Print could use): none is found.
/// </summary>
public sealed partial class PfuDrivers(BoundedHttp http) : IDriverCatalog
{
    private static readonly MakerSource Source = MakerSource.Pfu;
    private const string Site = "https://www.pfu.ricoh.com/global/scanners/fisp/dl/";

    public bool LooksUp(string? maker) => Source.Is(maker);

    public static string Words(string name) => DriverPages.ModelWords(name, "pfu", "fujitsu", "ricoh", "image", "imaging");

    /// <summary>The page's system for this Windows and processor: "win-11" or "win-10"; on ARM64 "win-11", where PFU lists its ARM builds.</summary>
    public static string OsId(PcWindows windows, PcArch arch) => windows == PcWindows.Windows11 || arch == PcArch.Arm64 ? "win-11" : "win-10";

    public async Task<DriverLookup> FindAsync(DriverQuery query, CancellationToken ct)
    {
        var model = Words(query.Model);
        if (model.Length == 0 || query.Kind != NeedsDriverKind.Scanner) return DriverLookup.None(NoOffer.NotFound);
        try
        {
            var index = await http.GetTextAsync(new Uri(Site), Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            if (ModelPage(index, query.Model) is not { } page) return DriverLookup.None(NoOffer.NotFound);
            var html = await http.GetTextAsync(page, Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            return DriverPages.ForThisPc(Ranked(ParsePage(html, OsId(query.Windows, query.Arch))), query.Arch, out var why) is { } pick
                ? DriverPages.Offer(pick, pick.Link, page, Source)
                : DriverLookup.None(why, page);
        }
        catch (FetchException ex)
        {
            return DriverLookup.None(NoOffer.Unreachable, problem: ex.Problem);
        }
    }

    [GeneratedRegex(@"<a href=""/global/scanners/fisp/dl/([a-z0-9\-]{2,40})\.html"" class=""product-card"" data-product-id=""([a-z0-9\-]{2,40})""")]
    private static partial Regex Card();

    /// <summary>The model's page in the list of models (its product id the model's own words: "fi-8170", "sp-1130n"); null when none is.</summary>
    public static Uri? ModelPage(string html, string model)
    {
        var want = Words(model).Replace(' ', '-');
        if (want.Length == 0) return null;
        foreach (Match m in Card().Matches(html).Take(1000))
            if (m.Groups[1].Value == m.Groups[2].Value && m.Groups[1].Value == want) return new Uri(Site + want + ".html");
        return null;
    }

    [GeneratedRegex(@"<script type=""application/json"" data-support-app-json>(.{1,4000000}?)</script>", RegexOptions.Singleline)]
    private static partial Regex Data();

    [GeneratedRegex(@"https://origin\.pfultd\.com/[A-Za-z0-9/_.\-]{1,300}")]
    private static partial Regex FileUrl();

    /// <summary>The scanner-driver section's downloads for this system (<paramref name="os"/>), in PFU's order: at most 200.</summary>
    public static IReadOnlyList<MakerDownload> ParsePage(string html, string os)
    {
        var list = new List<MakerDownload>();
        if (Data().Match(html) is not { Success: true } m) return list;
        try
        {
            using var doc = JsonDocument.Parse(m.Groups[1].Value, new JsonDocumentOptions { MaxDepth = 32 });
            if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("sections", out var sections) || sections.ValueKind != JsonValueKind.Object
                || !sections.TryGetProperty("software-scanner-driver", out var section) || section.ValueKind != JsonValueKind.Object
                || !section.TryGetProperty("downloadsByOs", out var byOs) || byOs.ValueKind != JsonValueKind.Object
                || !byOs.TryGetProperty(os, out var downloads) || downloads.ValueKind != JsonValueKind.Array) return list;
            foreach (var d in downloads.EnumerateArray().Take(200))
            {
                if (Text(d, "title") is not { } title || !d.TryGetProperty("action", out var action) || Text(action, "onclick", 2000) is not { } onclick
                    || FileUrl().Match(onclick) is not { Success: true } url || !Uri.TryCreate(url.Value, UriKind.Absolute, out var file)) continue;
                list.Add(new MakerDownload(DriverPages.Plain(title, 160), DriverPages.Plain(Text(d, "description", 2000) ?? "", 600),
                    Regex.Match(title, @"(\d{1,3}(?:\.\d{1,4}){1,3})\s*(?:\(|$)") is { Success: true } v ? v.Groups[1].Value : null,
                    Text(d, "fileSize", 20) is { } size ? DriverPages.Size(size) : null, file, Text(d, "fileName", 120)));
            }
        }
        catch (JsonException)
        {
            // A page whose data can't be read lists nothing.
        }
        return list;
    }

    private static string? Text(JsonElement e, string name, int max = 400) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 } s
            ? s.Length > max ? s[..max] : s : null;

    /// <summary>
    /// PaperStream IP's installers (.exe, not the ISO images) Inkvolt Print can scan through: TWAIN x64 (its 64-bit TWAIN sources), then
    /// TWAIN's ARM build, only for ARM64. Never the 32-bit TWAIN driver on x64 (Inkvolt Print reads no 32-bit source) nor ISIS.
    /// </summary>
    public static IReadOnlyList<MakerDownload> Ranked(IReadOnlyList<MakerDownload> list)
    {
        int? Rank(MakerDownload d)
        {
            if (!d.Link.AbsolutePath.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || !d.Title.Contains("PaperStream IP", StringComparison.OrdinalIgnoreCase)) return null;
            if (d.Title.Contains("TWAIN x64", StringComparison.OrdinalIgnoreCase)) return 0;
            return d.Title.Contains("TWAIN", StringComparison.OrdinalIgnoreCase) && DriverPages.ForArm(d.Title, d.Description) ? 1 : null;
        }
        return [.. list.Select(d => (d, Rank: Rank(d))).Where(e => e.Rank is not null).OrderBy(e => e.Rank).Select(e => e.d)];
    }
}
