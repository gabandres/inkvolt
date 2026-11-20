using System.Globalization;
using System.Text.Json;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Drivers;

/// <summary>
/// HP's drivers, from support.hp.com's own services (what its driver pages ask): the product search
/// (<c>typeahead?q=</c>, JSON) gives the model's product number; its list of systems (<c>wcc-services/swd-v2/osVersionData</c>)
/// gives this Windows' ids ("Windows 11", "Windows 11 on ARM (64-bit)", "Windows 10 (64-bit)"); the driver list
/// (<c>wcc-services/swd-v2/driverDetails</c>, a JSON post naming the product and the system) lists each download by section, the
/// file on ftp.hp.com. A printer gets HP's offline full or basic installer before its other driver installers; a scanner HP's scan
/// driver (the basic one first) before those. Firmware, apps and links to the Microsoft Store never.
/// </summary>
public sealed class HpDrivers(BoundedHttp http) : IDriverCatalog
{
    private static readonly MakerSource Source = MakerSource.Hp;
    private const string Site = "https://support.hp.com/";

    public bool LooksUp(string? maker) => Source.Is(maker);

    public static string Words(string name) => DriverPages.ModelWords(name, "hp", "hewlett", "packard", "hewlett-packard");

    /// <summary>
    /// The name HP's list of systems gives this PC's Windows: on ARM64 its one ARM system, "Windows 11 on ARM (64-bit)" (HP lists no
    /// Windows 10 on ARM), else "Windows 11" or "Windows 10 (64-bit)".
    /// </summary>
    public static string OsName(PcWindows windows, PcArch arch) =>
        arch == PcArch.Arm64 ? "Windows 11 on ARM (64-bit)" : windows == PcWindows.Windows10 ? "Windows 10 (64-bit)" : "Windows 11";

    public async Task<DriverLookup> FindAsync(DriverQuery query, CancellationToken ct)
    {
        var model = Words(query.Model);
        if (model.Length == 0) return DriverLookup.None(NoOffer.NotFound);
        try
        {
            var search = await http.GetTextAsync(new Uri(Site + "typeahead?q=" + Uri.EscapeDataString(model)
                + "&resultLimit=10&store=tmsstore&languageCode=en&filters=class:(pm_series_value%5E1.1%20OR%20pm_name_value%20OR%20pm_number_value)"),
                Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            if (ProductId(search, query.Model) is not { } product) return DriverLookup.None(NoOffer.NotFound);
            var page = new Uri(Site + "us-en/drivers/" + product.ToString(CultureInfo.InvariantCulture));
            var systems = await http.GetTextAsync(new Uri(Site + "wcc-services/swd-v2/osVersionData?cc=us&lc=en&productOid=" + product.ToString(CultureInfo.InvariantCulture)),
                Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            var osName = OsName(query.Windows, query.Arch);
            if (OsIds(systems, osName) is not { } os) return DriverLookup.None(NoOffer.NotFound, page);
            var json = JsonSerializer.Serialize(new Dictionary<string, object>
            {
                ["lc"] = "en", ["cc"] = "us", ["osTMSId"] = os.Version, ["osPlatformId"] = os.Platform, ["productNameOid"] = product,
                ["osName"] = osName, ["platformId"] = os.Platform,
            });
            var list = await http.PostJsonAsync(new Uri(Site + "wcc-services/swd-v2/driverDetails?authState=anonymous&template=SWD_PDP_Drivers"), json,
                Source.PageHosts, DriverPages.MaxPage, DriverPages.Limit, ct).ConfigureAwait(false);
            return DriverPages.ForThisPc(Ranked(ParseList(list), query.Kind), query.Arch, out var why) is { } pick
                ? DriverPages.Offer(pick, pick.Link, page, Source)
                : DriverLookup.None(why, page);
        }
        catch (FetchException ex)
        {
            return DriverLookup.None(NoOffer.Unreachable, problem: ex.Problem);
        }
    }

    private static readonly JsonDocumentOptions Options = new() { MaxDepth = 32 };

    private static string? Text(JsonElement e, string name, int max = 400) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String && v.GetString() is { Length: > 0 } s
            ? s.Length > max ? s[..max] : s : null;

    /// <summary>The product number of the search's product that is the model ("HP LaserJet MFP M234dw Printer", not its "Trade Printer"); null when none is.</summary>
    public static long? ProductId(string json, string model)
    {
        try
        {
            using var doc = JsonDocument.Parse(json, Options);
            if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("matches", out var matches) || matches.ValueKind != JsonValueKind.Array) return null;
            var found = new List<(string Name, long Id)>();
            foreach (var m in matches.EnumerateArray().Take(50))
                if ((Text(m, "productname") ?? Text(m, "name")) is { } name && m.TryGetProperty("productId", out var id) && id.ValueKind == JsonValueKind.Number
                    && id.TryGetInt64(out var n) && n is > 0 and < 1_000_000_000_000)
                    found.Add((name, n));
            var best = DriverPages.BestMatch([.. found.Select(f => f.Name)], Words(model), Words);
            return best < 0 ? null : found[best].Id;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>This Windows' ids in HP's list of systems: the Windows platform's and the version's named <paramref name="osName"/>.</summary>
    public static (string Platform, string Version)? OsIds(string json, string osName)
    {
        try
        {
            using var doc = JsonDocument.Parse(json, Options);
            if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object
                || !data.TryGetProperty("osAvailablePlatformsAnsOS", out var all) || all.ValueKind != JsonValueKind.Object
                || !all.TryGetProperty("osPlatforms", out var platforms) || platforms.ValueKind != JsonValueKind.Array) return null;
            foreach (var p in platforms.EnumerateArray().Take(50))
            {
                if (Text(p, "name") != "Windows" || Text(p, "id", 64) is not { } platform || !p.TryGetProperty("osVersions", out var versions)
                    || versions.ValueKind != JsonValueKind.Array) continue;
                foreach (var v in versions.EnumerateArray().Take(200))
                    if (string.Equals(Text(v, "name"), osName, StringComparison.OrdinalIgnoreCase) && Text(v, "id", 64) is { } id
                        && id.All(char.IsAsciiDigit) && platform.All(char.IsAsciiDigit))
                        return (platform, id);
            }
            return null;
        }
        catch (JsonException)
        {
            return null;
        }
    }

    /// <summary>Every download HP lists, with its section, in its order: at most 200, each file's address as HP gives it.</summary>
    public static IReadOnlyList<(string Section, MakerDownload Download)> ParseList(string json)
    {
        var list = new List<(string, MakerDownload)>();
        try
        {
            using var doc = JsonDocument.Parse(json, Options);
            if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("data", out var data) || data.ValueKind != JsonValueKind.Object
                || !data.TryGetProperty("softwareTypes", out var types) || types.ValueKind != JsonValueKind.Array) return list;
            foreach (var t in types.EnumerateArray().Take(50))
            {
                var section = Text(t, "accordionNameEn") ?? Text(t, "accordionName") ?? "";
                if (t.ValueKind != JsonValueKind.Object || !t.TryGetProperty("softwareDriversList", out var drivers) || drivers.ValueKind != JsonValueKind.Array) continue;
                foreach (var d in drivers.EnumerateArray().Take(50))
                {
                    if (d.ValueKind != JsonValueKind.Object || !d.TryGetProperty("latestVersionDriver", out var l) || Text(l, "title") is not { } title
                        || !Uri.TryCreate(Text(l, "fileUrl", 600), UriKind.Absolute, out var file)) continue;
                    var detail = l.TryGetProperty("detailInformation", out var di) ? di : default; // l is an object: it had a title
                    var version = Text(l, "version", 40) is { } v && v != "N/A" ? v : null;
                    list.Add((DriverPages.Plain(section, 160), new MakerDownload(DriverPages.Plain(title, 160), DriverPages.Plain(Text(detail, "description", 2000) ?? "", 600),
                        version, Text(l, "fileSize", 20) is { } size ? DriverPages.Size(size) : null, file, Text(detail, "fileName", 200))));
                    if (list.Count >= 200) return list;
                }
            }
        }
        catch (JsonException)
        {
            // What was read before the answer went wrong is kept; nothing else.
        }
        return list;
    }

    /// <summary>
    /// The candidates for the kind, best first, only Windows programs (.exe): a printer gets the section of HP's offline full or basic
    /// installers, then its other driver sections that aren't for scanning; a scanner HP's scan driver (basic before full), then the
    /// installers. Firmware never.
    /// </summary>
    public static IReadOnlyList<MakerDownload> Ranked(IReadOnlyList<(string Section, MakerDownload Download)> list, NeedsDriverKind kind)
    {
        int? Rank(string section, MakerDownload d)
        {
            if (!d.Link.AbsolutePath.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) || section.Contains("Firmware", StringComparison.OrdinalIgnoreCase)) return null;
            var installers = section.Contains("Full/Basic", StringComparison.OrdinalIgnoreCase);
            var scan = section.Contains("Scan", StringComparison.OrdinalIgnoreCase) || d.Title.Contains("Universal Scan", StringComparison.OrdinalIgnoreCase);
            var driver = section.StartsWith("Driver", StringComparison.OrdinalIgnoreCase);
            var online = section.StartsWith("Installation Software and Driver", StringComparison.OrdinalIgnoreCase);
            if (kind == NeedsDriverKind.Scanner)
                return scan && driver ? d.Title.Contains("Basic", StringComparison.OrdinalIgnoreCase) ? 0 : 1 : installers ? 2 : online ? 3 : null;
            return installers ? 0 : driver && !scan ? 1 : online ? 2 : null;
        }
        return [.. list.Select(e => (e.Download, Rank: Rank(e.Section, e.Download))).Where(e => e.Rank is not null).OrderBy(e => e.Rank).Select(e => e.Download)];
    }
}
