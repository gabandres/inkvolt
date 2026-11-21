using System.Net;
using System.Text.RegularExpressions;

namespace InkvoltPrint.Core.Drivers;

/// <summary>
/// One download a maker's page lists, as read (all of it untrusted): its title and description, version and size as the page says
/// them, and <paramref name="Link"/>: the file itself, or the maker's page that names it (Brother's and Canon's).
/// <paramref name="Licence"/>: the maker's page with the licence the download is under, when the list gives one (PFU's).
/// </summary>
public sealed record MakerDownload(string Title, string Description, string? Version, string? SizeText, Uri Link, string? FileName = null, Uri? Licence = null);

/// <summary>
/// What every maker's lookup does the same way (<see cref="EpsonDrivers"/>, <see cref="CanonDrivers"/>, <see cref="HpDrivers"/>,
/// <see cref="BrotherDrivers"/>, <see cref="PfuDrivers"/>): a model's words, which of the site's products is the model, page text
/// made plain and short, the download for this processor, and the offer built from it with a safe file name.
/// </summary>
public static partial class DriverPages
{
    /// <summary>How long one page may take, and how big a page or an answer may be.</summary>
    public static readonly TimeSpan Limit = TimeSpan.FromSeconds(30);

    public const long MaxPage = 6 << 20;

    private static readonly HashSet<string> TrailingWords = ["printer", "scanner", "series", "all-in-one", "allinone", "aio", "usb"];

    /// <summary>Words after a model's that make it another model ("V19 II" isn't the V19, a "Trade" printer isn't the printer).</summary>
    private static readonly HashSet<string> VariantWords = ["ii", "iii", "iv", "v", "plus", "pro", "se", "xl", "wide", "max", "mini", "s", "w", "trade", "loyal"];

    /// <summary>
    /// A model's words, lower case: the maker's names (<paramref name="makerWords"/>) dropped, and kind words at its end ("printer",
    /// "series"…): "Brother HL-L2350DW series" → "hl-l2350dw". At most 200 characters of the name are read.
    /// </summary>
    public static string ModelWords(string name, params string[] makerWords)
    {
        var text = name.Length > 200 ? name[..200] : name;
        var words = Regex.Replace(text.ToLowerInvariant(), @"[^a-z0-9\-]+", " ").Split(' ', StringSplitOptions.RemoveEmptyEntries)
            .Where(w => w != "-" && !makerWords.Contains(w)).ToList();
        while (words.Count > 0 && TrailingWords.Contains(words[^1])) words.RemoveAt(words.Count - 1);
        return string.Join(' ', words);
    }

    /// <summary>
    /// Which of a site's product names is the model (each made words by <paramref name="words"/>): the first with exactly its words,
    /// else the shortest that has them in a row with no variant word after. -1: none. At most the first 100 names.
    /// </summary>
    public static int BestMatch(IReadOnlyList<string> names, string want, Func<string, string> words)
    {
        if (want.Length == 0) return -1;
        var found = names.Take(100).Select((n, i) => (Words: words(n), Index: i)).ToList();
        if (found.FirstOrDefault(f => f.Words == want) is { Words: not null } exact) return exact.Index;
        return found.Where(f => HasInARow(f.Words, want)).OrderBy(f => f.Words.Length).Select(f => f.Index).DefaultIfEmpty(-1).First();
    }

    private static bool HasInARow(string words, string want)
    {
        var w = words.Split(' ');
        var m = want.Split(' ');
        for (var i = 0; i + m.Length <= w.Length; i++)
            if (w.AsSpan(i, m.Length).SequenceEqual(m) && (i + m.Length == w.Length || !VariantWords.Contains(w[i + m.Length])))
                return true;
        return false;
    }

    [GeneratedRegex(@"<[^>]{0,2000}>")]
    private static partial Regex Tags();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Spaces();

    /// <summary>A page's text without its tags and entities, spaces joined, cut at <paramref name="max"/> characters.</summary>
    public static string Plain(string html, int max)
    {
        var s = Spaces().Replace(WebUtility.HtmlDecode(Tags().Replace(html, " ")).Replace('\u00A0', ' '), " ").Trim();
        return s.Length > max ? s[..max].TrimEnd() + "…" : s;
    }

    /// <summary>ARM as the makers and Microsoft write it: "ARM", "Arm64", "Windows on Arm", "ARM-based", "(ARM 64)".</summary>
    [GeneratedRegex(@"\b(arm|arm64|aarch64)\b", RegexOptions.IgnoreCase)]
    private static partial Regex Arm();

    [GeneratedRegex(@"\b(x64|x86-64|x86_64|amd64|intel|amd)\b", RegexOptions.IgnoreCase)]
    private static partial Regex X64();

    public static bool ForArm(string title, string description) => Arm().IsMatch(title) || Arm().IsMatch(description);

    /// <summary>Names ARM and not x64, Intel or AMD.</summary>
    public static bool ArmOnly(string title, string description) => ForArm(title, description) && !X64().IsMatch(title) && !X64().IsMatch(description);

    /// <summary>
    /// The download for this processor among <paramref name="ranked"/> (the maker's candidates for the kind and Windows, best first):
    /// on ARM64 the first that says it is for ARM, on x64 the first that isn't for ARM only. None: on ARM64
    /// <see cref="NoOffer.NoArm64"/> when there were candidates but none for ARM (an x64 driver doesn't load on ARM64 Windows), else
    /// (and always on x64, even when only ARM builds were listed) <see cref="NoOffer.NotFound"/>.
    /// </summary>
    public static MakerDownload? ForThisPc(IReadOnlyList<MakerDownload> ranked, PcArch arch, out NoOffer why)
    {
        var pick = arch == PcArch.Arm64 ? ranked.FirstOrDefault(d => ForArm(d.Title, d.Description)) : ranked.FirstOrDefault(d => !ArmOnly(d.Title, d.Description));
        why = WhyNone(ranked.Count > 0, arch);
        return pick;
    }

    /// <summary>Why nothing was offered: <see cref="NoOffer.NoArm64"/> only on ARM64 when the kind's drivers were listed.</summary>
    public static NoOffer WhyNone(bool listed, PcArch arch) => listed && arch == PcArch.Arm64 ? NoOffer.NoArm64 : NoOffer.NotFound;

    /// <summary>
    /// The offer for <paramref name="d"/>'s file at <paramref name="file"/>: none when that isn't on the maker's download hosts.
    /// <paramref name="licence"/>: the maker's page with the licence the download is under, when it asks for one to be accepted
    /// (only one on the maker's own site is kept).
    /// </summary>
    public static DriverLookup Offer(MakerDownload d, Uri file, Uri page, MakerSource source, Uri? licence = null)
    {
        if (!BoundedHttp.IsAllowed(file, source.DownloadHosts)) return DriverLookup.None(NoOffer.NotFound, page);
        return DriverLookup.Found(new DriverOffer(Plain(d.Title, 120), d.Version is { Length: > 0 } v ? Plain(v, 40) : null, d.SizeText,
            file, SafeFileName(d.FileName, file, d.Title), page, licence is not null && BoundedHttp.IsAllowed(licence, source.PageHosts) ? licence : null));
    }

    /// <summary>
    /// The name the download is saved under, kept to letters, digits, '.', '_' and '-' and ending in .exe, never a path: the page's
    /// name for the file when that is a program's (.exe), else the address's own file name when it is, else the title.
    /// </summary>
    public static string SafeFileName(string? pageName, Uri href, string title)
    {
        static bool IsExe(string? s) => s is { Length: > 0 } && s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase);
        var fromUrl = Path.GetFileName(href.AbsolutePath);
        var raw = IsExe(pageName) ? pageName! : IsExe(fromUrl) ? fromUrl : title;
        var s = Regex.Replace(Regex.Replace(raw.Length > 200 ? raw[..200] : raw, @"[^A-Za-z0-9._\-]", "_"), @"\.{2,}", ".").Trim('.');
        if (s.Length is 0 or > 100) s = "driver";
        return s.EndsWith(".exe", StringComparison.OrdinalIgnoreCase) ? s : s + ".exe";
    }

    /// <summary>"221.76 MB", "19.81 MB" as the page says it (a number and a unit), else null.</summary>
    public static string? Size(string text) =>
        Regex.Match(text, @"(\d{1,6}(?:[.,]\d{1,3})?)\s*(KB|MB|GB)", RegexOptions.IgnoreCase) is { Success: true } m
            ? $"{m.Groups[1].Value} {m.Groups[2].Value.ToUpperInvariant()}" : null;
}
