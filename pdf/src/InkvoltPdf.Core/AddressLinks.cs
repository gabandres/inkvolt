using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>A web or email address printed on a page: the text, the address its link leads to, and its box on each line.</summary>
public sealed record FoundAddress(int Page, string Text, string Uri, IReadOnlyList<RectD> Boxes);

/// <summary>
/// Links from Addresses (roadmap 4.15): every web address (http, https, or starting www.) and email address printed in
/// the text becomes a link, as the Link tool makes one over selected text (<see cref="Links.PutOnTexts"/>; the same
/// address rules: https for www., mailto for email, international domains as punycode, scripts refused). An address
/// already covered by a link is left alone; one broken over two lines is not found.
/// </summary>
public static partial class AddressLinks
{
    /// <summary>The most addresses one run lists (a directory of thousands is linked in parts).</summary>
    public const int MaxFound = 5000;

    /// <summary>The longest address taken (longer is a run of characters, not an address).</summary>
    private const int MaxLength = 2000;

    // A web address: http(s):// or www. and what follows up to a space or a character addresses don't hold. An email
    // address: a local part, @, then a domain of labels ending in letters (international ones too). Neither may follow a
    // letter, digit or address character (no match inside a longer word).
    [GeneratedRegex(@"(?<![\p{L}\p{N}@._%+/-])(?:(?:https?://|www\.)[^\s<>""{}|\\^`]+|[\p{L}\p{N}._%+-]+@(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?\.)+\p{L}{2,}(?![\p{L}\p{N}_@-]))",
        RegexOptions.IgnoreCase | RegexOptions.CultureInvariant, matchTimeoutMilliseconds: 1000)]
    private static partial Regex Address();

    /// <summary>
    /// The addresses in a page's text, as (start, length): a web address loses the punctuation a sentence puts after it
    /// (a full stop, a comma, quotes, a closing bracket it didn't open).
    /// </summary>
    public static List<(int Start, int Length)> Matches(string text)
    {
        var result = new List<(int Start, int Length)>();
        MatchCollection found;
        try
        {
            found = Address().Matches(text);
            _ = found.Count; // runs the whole search here, inside the time limit's catch
        }
        catch (RegexMatchTimeoutException)
        {
            return result;
        }
        foreach (Match m in found)
        {
            var value = m.Value;
            if (value.Contains('@') && !value.Contains("://", StringComparison.Ordinal) && !value.StartsWith("www.", StringComparison.OrdinalIgnoreCase))
            {
                var local = value[..value.IndexOf('@')];
                if (local.StartsWith('.') || local.EndsWith('.') || local.Contains("..", StringComparison.Ordinal)) continue;
                result.Add((m.Index, m.Length));
                continue;
            }
            if (value.Length > MaxLength) continue; // a run of characters, not an address (checked before it is trimmed)
            var length = Trimmed(value);
            var host = value[..length];
            // "www." or "https://" with nothing worth a link after it.
            var rest = host.StartsWith("www.", StringComparison.OrdinalIgnoreCase) ? host[4..] : host[(host.IndexOf("://", StringComparison.Ordinal) + 3)..];
            if (rest.Length < 3 || !rest.Contains('.') && !rest.StartsWith("localhost", StringComparison.OrdinalIgnoreCase) || length > MaxLength) continue;
            result.Add((m.Index, length));
        }
        return result;
    }

    /// <summary>
    /// A web address's length without what a sentence put after it. The brackets are counted once and kept up to date as
    /// the end moves (counting them again for each character trimmed took minutes for a run of thousands).
    /// </summary>
    private static int Trimmed(string value)
    {
        int round = 0, square = 0, curly = 0; // closing brackets less opening ones, in value[..end]
        foreach (var ch in value)
        {
            switch (ch)
            {
                case '(': round--; break;
                case ')': round++; break;
                case '[': square--; break;
                case ']': square++; break;
                case '{': curly--; break;
                case '}': curly++; break;
            }
        }
        var end = value.Length;
        while (end > 0)
        {
            var c = value[end - 1];
            if (".,;:!?'\"*»”’›".Contains(c)) end--;
            else if (c == ')' && round > 0) { round--; end--; }
            else if (c == ']' && square > 0) { square--; end--; }
            else if (c == '}' && curly > 0) { curly--; end--; }
            else break;
        }
        return end;
    }

    /// <summary>
    /// The addresses on the pages not already behind a link (a link over half or more of the address), in page order;
    /// at most <see cref="MaxFound"/>. A page that can't be read is passed over.
    /// </summary>
    /// <param name="progress">(pages done, pages), before each page.</param>
    public static IReadOnlyList<FoundAddress> Find(PdfEngine engine, IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default)
    {
        var found = new List<FoundAddress>();
        for (var p = 0; p < engine.PageCount && found.Count < MaxFound; p++)
        {
            cancel.ThrowIfCancellationRequested();
            progress?.Report((p, engine.PageCount));
            PageText text;
            IReadOnlyList<PageLink> links;
            try
            {
                text = engine.GetText(p, cache: false, cancel);
                links = engine.GetLinks(p, cancel);
            }
            catch (Exception ex) when (ex is MuPDFCore.MuPDFException or PageRefusedException)
            {
                continue;
            }
            foreach (var (start, length) in Matches(text.Text))
            {
                var value = text.Text.Substring(start, length);
                if (Links.Normalize(value) is not { } uri) continue;
                var boxes = text.GetRects(start, start + length);
                if (boxes.Count == 0 || boxes.Any(b => links.Any(l => Covered(b, l.Area)))) continue;
                found.Add(new FoundAddress(p, value, uri, boxes));
                if (found.Count >= MaxFound) break;
            }
        }
        return found;
    }

    /// <summary>The chosen addresses made links, as one change of the document.</summary>
    public static byte[] Apply(byte[] data, string? password, IReadOnlyList<FoundAddress> chosen) =>
        Links.PutOnTexts(data, password, [.. chosen.Select(a => (a.Page, a.Boxes, a.Uri))]);

    /// <summary>Half or more of <paramref name="box"/> lies under <paramref name="link"/>.</summary>
    private static bool Covered(RectD box, RectD link)
    {
        var w = Math.Min(box.Right, link.Right) - Math.Max(box.X, link.X);
        var h = Math.Min(box.Bottom, link.Bottom) - Math.Max(box.Y, link.Y);
        return w > 0 && h > 0 && w * h >= 0.5 * box.Width * box.Height;
    }
}
