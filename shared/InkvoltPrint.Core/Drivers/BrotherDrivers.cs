using System.Net;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Drivers;

/// <summary>
/// Brother's drivers, from support.brother.com (the US site): its product search (<c>productlist.aspx?q=</c>) opens the model's own
/// downloads page when it knows the model, which names its product code; the download list for this Windows
/// (<c>downloadlist.aspx?prod=…&amp;os=</c>, 10068 Windows 11, 10013 Windows 10 64-bit) lists each download by section; the chosen
/// one's page past the licence (<c>downloadhowto.aspx</c>, what "Agree to the EULA and Download" opens) names the file on
/// download.brother.com. The kind's own driver is chosen (Printer Driver, Scanner Driver), else Brother's Full Driver &amp; Software
/// Package (a scanner often has only that). Brother lists ARM drivers only where it has them, saying so in the title.
/// </summary>
public sealed partial class BrotherDrivers(BoundedHttp http) : IDriverCatalog
{
    private static readonly MakerSource Source = MakerSource.Brother;
    private const string Site = "https://support.brother.com/g/b/";

    public bool LooksUp(string? maker) => Source.Is(maker);

    public static string Words(string name) => DriverPages.ModelWords(name, "brother");

    /// <summary>
    /// The download list's code for this Windows and processor: 10068 Windows 11, 10013 Windows 10 64-bit. Brother lists no ARM
    /// system (none on five current models, 2026-11-20): on ARM64 the Windows 11 list is read, where an ARM build would be, and
    /// only an entry that says it is for ARM is taken.
    /// </summary>
    public static string OsCode(PcWindows windows, PcArch arch) => windows == PcWindows.Windows11 || arch == PcArch.Arm64 ? "10068" : "10013";

    public async Task<DriverLookup> FindAsync(DriverQuery query, CancellationToken ct)
    {
        var model = Words(query.Model);
        if (model.Length == 0) return DriverLookup.None(NoOffer.NotFound);
        try
        {
            var search = await http.GetTextAsync(new Uri(Site + "productlist.aspx?c=us&lang=en&content=dl&q=" + Uri.EscapeDataString(model)),
                Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            if (ProductCode(search, query.Model) is not { } prod) return DriverLookup.None(NoOffer.NotFound);
            var page = new Uri(Site + "downloadtop.aspx?c=us&lang=en&prod=" + prod);
            var list = await http.GetTextAsync(new Uri(Site + $"downloadlist.aspx?c=us&lang=en&prod={prod}&os={OsCode(query.Windows, query.Arch)}"),
                Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            if (DriverPages.ForThisPc(Ranked(ParseList(list), query.Kind), query.Arch, out var why) is not { } pick) return DriverLookup.None(why, page);
            var howto = await http.GetTextAsync(pick.Link, Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            // The licence the "Agree to the EULA and Download" button accepts is on the download's own page: shown before downloading.
            return FileOf(howto) is { } file ? DriverPages.Offer(pick, file, page, Source, LicencePage(pick.Link)) : DriverLookup.None(NoOffer.NotFound, page);
        }
        catch (FetchException ex)
        {
            return DriverLookup.None(NoOffer.Unreachable, problem: ex.Problem);
        }
    }

    [GeneratedRegex(@"<h3 class=""title""><a href=""/g/b/producttop\.aspx\?c=us&(?:amp;)?lang=en&(?:amp;)?prod=([a-z0-9_]{1,60})"">([^<]{1,100})</a>")]
    private static partial Regex Product();

    /// <summary>
    /// The product code of the model's page the search opened: its title's model the model's own (Brother's "(XL)" and the like aside).
    /// Null: the search listed several products, or another model, or nothing.
    /// </summary>
    public static string? ProductCode(string html, string model)
    {
        if (Product().Match(html) is not { Success: true } m) return null;
        var name = Regex.Replace(WebUtility.HtmlDecode(m.Groups[2].Value), @"\([^)]{0,20}\)", " ");
        var want = Words(model);
        return want.Length > 0 && Words(name) == want ? m.Groups[1].Value : null;
    }

    [GeneratedRegex(@"<h3 class=""h3"">([^<]{1,80})</h3>")]
    private static partial Regex Section();

    [GeneratedRegex(@"<a href=""(/g/b/downloadend\.aspx\?[A-Za-z0-9_=&;.%\-]{1,300})"">([^<]{1,200})</a>")]
    private static partial Regex Entry();

    [GeneratedRegex(@"class=""type3comment"">(.{0,3000}?)</div>", RegexOptions.Singleline)]
    private static partial Regex Comment();

    [GeneratedRegex(@"<br>\(([^)<]{1,40})\)</em>", RegexOptions.IgnoreCase)]
    private static partial Regex VersionCell();

    [GeneratedRegex(@"<em>([\d.,]{1,10})<BR>(KB|MB|GB)</em>", RegexOptions.IgnoreCase)]
    private static partial Regex SizeCell();

    /// <summary>
    /// Every download the list shows, in its order, with the section it's under ("Drivers", "Full Software Package"…). At most 200,
    /// every text shortened; the link is the download's page past the licence.
    /// </summary>
    public static IReadOnlyList<(string Section, MakerDownload Download)> ParseList(string html)
    {
        var list = new List<(string, MakerDownload)>();
        var sections = Section().Matches(html);
        for (var s = 0; s < sections.Count && list.Count < 200; s++)
        {
            var start = sections[s].Index;
            var end = s + 1 < sections.Count ? sections[s + 1].Index : html.Length;
            var name = DriverPages.Plain(sections[s].Groups[1].Value, 80);
            foreach (var row in html[start..end].Split("<tr>", StringSplitOptions.None).Skip(1).Take(100))
            {
                if (Entry().Match(row) is not { Success: true } e) continue;
                var howto = "https://support.brother.com" + WebUtility.HtmlDecode(e.Groups[1].Value).Replace("/downloadend.aspx", "/downloadhowto.aspx", StringComparison.Ordinal);
                if (!Uri.TryCreate(howto, UriKind.Absolute, out var link)) continue;
                var comment = Comment().Match(row);
                var version = VersionCell().Match(row);
                var size = SizeCell().Match(row);
                list.Add((name, new MakerDownload(DriverPages.Plain(e.Groups[2].Value, 120), comment.Success ? DriverPages.Plain(comment.Groups[1].Value, 600) : "",
                    version.Success ? version.Groups[1].Value.Trim() : null, size.Success ? $"{size.Groups[1].Value} {size.Groups[2].Value.ToUpperInvariant()}" : null, link)));
                if (list.Count >= 200) break;
            }
        }
        return list;
    }

    /// <summary>
    /// The candidates for the kind, best first: under Drivers the kind's own driver (a printer's before its XML Paper Specification
    /// one), then the Full Driver &amp; Software Package. Firmware, utilities and the rest never.
    /// </summary>
    public static IReadOnlyList<MakerDownload> Ranked(IReadOnlyList<(string Section, MakerDownload Download)> list, NeedsDriverKind kind)
    {
        int? Rank((string Section, MakerDownload D) e)
        {
            var t = e.D.Title;
            if (e.Section.Equals("Drivers", StringComparison.OrdinalIgnoreCase))
            {
                if (kind == NeedsDriverKind.Scanner && (t.Contains("Scanner Driver", StringComparison.OrdinalIgnoreCase) || t.Contains("TWAIN", StringComparison.OrdinalIgnoreCase)))
                    return 0;
                if (kind != NeedsDriverKind.Scanner && t.Contains("Printer Driver", StringComparison.OrdinalIgnoreCase))
                    return t.Contains("XML Paper", StringComparison.OrdinalIgnoreCase) ? 1 : 0;
            }
            return t.Contains("Full Driver", StringComparison.OrdinalIgnoreCase) ? 2 : null;
        }
        return [.. list.Select(e => (e.Download, Rank: Rank(e))).Where(e => e.Rank is not null).OrderBy(e => e.Rank).Select(e => e.Download)];
    }

    /// <summary>The download's page that shows Brother's EULA and its "Agree to the EULA and Download" button (the link is the page past it).</summary>
    public static Uri LicencePage(Uri howto) => new(howto.AbsoluteUri.Replace("/downloadhowto.aspx", "/downloadend.aspx", StringComparison.Ordinal));

    [GeneratedRegex(@"<a id=""downloadfile"" href=""(https://[^""\s]{1,500})""")]
    private static partial Regex DownloadFile();

    /// <summary>The file the page past the licence starts (its "click here" link); null when it names none.</summary>
    public static Uri? FileOf(string html) =>
        DownloadFile().Match(html) is { Success: true } m && Uri.TryCreate(WebUtility.HtmlDecode(m.Groups[1].Value), UriKind.Absolute, out var u) ? u : null;
}
