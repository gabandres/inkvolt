using System.Net;
using System.Text.Json;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Drivers;

/// <summary>
/// Canon's drivers, from Canon's Asia site (asia.canon: Canon USA's and Canon Europe's sites refuse a program's requests): its model
/// suggestions (<c>/en/support/suggest?query=</c>, JSON) give the model's name there; its driver list for this Windows
/// (<c>/en/support/{model}/get-search-result-content?fileType=DR&amp;os=</c>, "Windows 11" or "Windows 10 (x64)") lists each
/// download; the chosen one's page names its file and version and links Canon's download server (pdisp01.c-wss.com, which sends
/// it on to gdlp01.c-wss.com). A printer gets its MP Drivers or Printer Driver, a scanner its Scanner Driver, else either gets the
/// Full Driver &amp; Software Package. Models Canon sells only outside Asia aren't on that site: no driver is found for them.
/// </summary>
public sealed partial class CanonDrivers(BoundedHttp http) : IDriverCatalog
{
    private static readonly MakerSource Source = MakerSource.Canon;
    private const string Site = "https://asia.canon/en/support/";

    public bool LooksUp(string? maker) => Source.Is(maker);

    public static string Words(string name) => DriverPages.ModelWords(name, "canon");

    public static string OsFilter(PcWindows windows) => windows == PcWindows.Windows11 ? "Windows 11" : "Windows 10 (x64)";

    public async Task<DriverLookup> FindAsync(DriverQuery query, CancellationToken ct)
    {
        var model = Words(query.Model);
        if (model.Length == 0) return DriverLookup.None(NoOffer.NotFound);
        try
        {
            var suggest = await http.GetTextAsync(new Uri(Site + "suggest?query=" + Uri.EscapeDataString(model)),
                Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            if (ModelName(suggest, query.Model) is not { } name) return DriverLookup.None(NoOffer.NotFound);
            var path = PathOf(name);
            var page = new Uri(Site + path + "/model");
            var list = await http.GetTextAsync(new Uri(Site + path + "/get-search-result-content?fileType=DR&os=" + Uri.EscapeDataString(OsFilter(query.Windows)) + "&q="),
                Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            if (DriverPages.ForThisPc(Ranked(ParseList(list), query.Kind), query.Arch, out var why) is not { } pick) return DriverLookup.None(why, page);
            var detail = await http.GetTextAsync(pick.Link, Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            return ParseDetail(detail, pick) is { } file ? DriverPages.Offer(file.Download, file.Url, page, Source) : DriverLookup.None(NoOffer.NotFound, page);
        }
        catch (FetchException ex)
        {
            return DriverLookup.None(NoOffer.Unreachable, problem: ex.Problem);
        }
    }

    /// <summary>
    /// The suggestion that is the model, as Canon names it there: one name, or several sharing a page ("imageCLASS LBP6030/ LBP6030B/
    /// LBP6030w"), each tried. Null when none is, or the answer can't be read.
    /// </summary>
    public static string? ModelName(string json, string model)
    {
        try
        {
            using var doc = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 8 });
            if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Array) return null;
            var names = data.EnumerateArray().Take(50).Where(e => e.ValueKind == JsonValueKind.String).Select(e => e.GetString()!)
                .Where(s => s.Length is > 0 and <= 200).ToList();
            var want = Words(model);
            // Each name of a shared page as its own: "imageCLASS LBP6030/ LBP6030B" is "imageCLASS LBP6030" and "LBP6030B".
            var each = names.SelectMany((n, i) => n.Split('/').Select(part => (Name: part.Trim(), Index: i))).Where(p => p.Name.Length > 0).ToList();
            var best = DriverPages.BestMatch([.. each.Select(p => p.Name)], want, Words);
            // A name with its line the page leaves out ("imageCLASS LBP6030w" on the page of "… LBP6030/ LBP6030B/ LBP6030w"): its
            // model number alone, when that is a real one (letters and digits, four or more).
            var number = want.Split(' ')[^1];
            if (best < 0 && want.Contains(' ') && number.Length >= 4 && number.Any(char.IsAsciiDigit) && number.Any(char.IsAsciiLetter))
                best = each.FindIndex(p => Words(p.Name) == number);
            return best < 0 ? null : names[each[best].Index];
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>The model's name in the site's paths, as its own pages write it ("/" as "__", "." as "&amp;&amp;"), escaped.</summary>
    public static string PathOf(string name) => Uri.EscapeDataString(name.Replace("/", "__", StringComparison.Ordinal).Replace(".", "&&", StringComparison.Ordinal).Trim());

    [GeneratedRegex(@"softwareCard__content--title"">\s*<a href=""(/en/support/[0-9]{6,14}\?model=[A-Za-z0-9+%._\-]{0,200})"">(.{1,300}?)</a>", RegexOptions.Singleline)]
    private static partial Regex Card();

    [GeneratedRegex(@"softwareCard__content--desc"">(.{0,3000}?)</div>", RegexOptions.Singleline)]
    private static partial Regex Desc();

    [GeneratedRegex(@"Size</div>\s*<p>([^<]{1,30})</p>")]
    private static partial Regex CardSize();

    /// <summary>Every download the list shows, in its order: at most 200, each linking its page on the site.</summary>
    public static IReadOnlyList<MakerDownload> ParseList(string html)
    {
        var list = new List<MakerDownload>();
        foreach (var part in html.Split("class=\"softwareCard\"", StringSplitOptions.None).Skip(1).Take(200))
        {
            if (Card().Match(part) is not { Success: true } c || !Uri.TryCreate("https://asia.canon" + WebUtility.HtmlDecode(c.Groups[1].Value), UriKind.Absolute, out var link))
                continue;
            var desc = Desc().Match(part);
            var size = CardSize().Match(part);
            list.Add(new MakerDownload(DriverPages.Plain(c.Groups[2].Value, 160), desc.Success ? DriverPages.Plain(desc.Groups[1].Value, 600) : "", null,
                size.Success ? DriverPages.Size(size.Groups[1].Value) : null, link));
        }
        return list;
    }

    /// <summary>The candidates for the kind, best first (see the class); patches, firmware and the rest never.</summary>
    public static IReadOnlyList<MakerDownload> Ranked(IReadOnlyList<MakerDownload> list, NeedsDriverKind kind)
    {
        int? Rank(MakerDownload d)
        {
            var t = d.Title;
            if (t.Contains("patch", StringComparison.OrdinalIgnoreCase) || t.Contains("Firmware", StringComparison.OrdinalIgnoreCase)) return null;
            var mp = t.Contains("MP Drivers", StringComparison.OrdinalIgnoreCase);
            if (kind == NeedsDriverKind.Scanner && t.Contains("Scanner Driver", StringComparison.OrdinalIgnoreCase)) return 0;
            if (kind != NeedsDriverKind.Scanner && (mp || t.Contains("Printer Driver", StringComparison.OrdinalIgnoreCase))) return mp ? 0 : 1;
            if (kind == NeedsDriverKind.Scanner && mp) return 1;
            return t.Contains("Full Driver", StringComparison.OrdinalIgnoreCase) ? 2 : null;
        }
        return [.. list.Select(d => (d, Rank: Rank(d))).Where(e => e.Rank is not null).OrderBy(e => e.Rank).Select(e => e.d)];
    }

    [GeneratedRegex(@"data-url=""(https://pdisp01\.c-wss\.com/gdl/WWUFORedirectTarget\.do\?[A-Za-z0-9=&;%_\-]{1,300})""")]
    private static partial Regex DataUrl();

    [GeneratedRegex(@"File name\s*:\s*([A-Za-z0-9._\-]{1,120})")]
    private static partial Regex FileName();

    [GeneratedRegex(@"File version\s*:\s*([A-Za-z0-9._\-]{1,40})")]
    private static partial Regex FileVersion();

    /// <summary>The download's page: Canon's link to the file (on its download server), the file's name and version. Null without the link.</summary>
    public static (MakerDownload Download, Uri Url)? ParseDetail(string html, MakerDownload listed)
    {
        if (DataUrl().Match(html) is not { Success: true } m || !Uri.TryCreate(WebUtility.HtmlDecode(m.Groups[1].Value), UriKind.Absolute, out var url)) return null;
        var name = FileName().Match(html);
        var version = FileVersion().Match(html);
        return (listed with { FileName = name.Success ? name.Groups[1].Value : null, Version = version.Success ? version.Groups[1].Value : null }, url);
    }
}
