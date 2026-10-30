using System.Globalization;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>
/// How a stretch of a paragraph looks where it differs from the paragraph's own (roadmap 2.1, part c): an installed font
/// family ("Georgia"), its size on the page (points), its color (0xRRGGBB), bold, italic. Null keeps the paragraph's own.
/// </summary>
public sealed record TextLook(string? Font = null, double? Size = null, int? Color = null, bool? Bold = null, bool? Italic = null)
{
    public static readonly TextLook Plain = new();

    public bool IsPlain => Font is null && Size is null && Color is null && Bold is null && Italic is null;

    /// <summary>This look with what <paramref name="other"/> sets laid over it.</summary>
    public TextLook With(TextLook other) => new(other.Font ?? Font, other.Size ?? Size, other.Color ?? Color, other.Bold ?? Bold, other.Italic ?? Italic);
}

/// <summary>A stretch of a paragraph's text (UTF-16 offsets into the text as written, line breaks as "\n") and its look.</summary>
public readonly record struct TextSpan(int Start, int Length, TextLook Look)
{
    public int End => Start + Length;
}

public static partial class ContentEditor
{
    /// <summary>The installed font families a <see cref="TextLook"/> can name ("Arial", "Georgia", …).</summary>
    public static IReadOnlyList<string> LookFonts() => StandInFonts.Installed();

    /// <summary>The marked-content tag a paragraph edit puts around text it gave a look of its own.</summary>
    internal const string LookTagName = "InkvoltLook";

    /// <summary>What the tag around styled text says: the font family, bold and italic that were asked for (size and color are read from the text).</summary>
    internal sealed record LookTag(string? Font, bool? Bold, bool? Italic)
    {
        public static LookTag Read(CObj props)
        {
            var font = props["Font"] is { Kind: CKind.String } f ? Encoding.UTF8.GetString(f.Bytes) : null;
            bool? Flag(string key) => props[key] is { Kind: CKind.Bool } b ? b.Name == "true" : null;
            return new LookTag(font, Flag("Bold"), Flag("Italic"));
        }

        public static string Write(TextLook look)
        {
            var sb = new StringBuilder($"/{LookTagName} <<");
            if (look.Font is { } f) sb.Append(" /Font ").Append(ContentLexer.Literal(Encoding.UTF8.GetBytes(f)));
            if (look.Bold is { } b) sb.Append(" /Bold ").Append(b ? "true" : "false");
            if (look.Italic is { } i) sb.Append(" /Italic ").Append(i ? "true" : "false");
            return sb.Append(" >> BDC ").ToString();
        }
    }

    /// <summary>
    /// A look resolved for writing: its size against the paragraph's (<see cref="Scale"/>), its color (null: the
    /// paragraph's), the installed font it is drawn in (null: a page font), the look as asked (for the tag), and the
    /// page's own font it is drawn in when the paragraph has that face (a bold word's font; null: the paragraph's own).
    /// </summary>
    internal sealed record PartLook(double Scale, int? Color, StandInFont? Face, TextLook Asked, TextRun? Page = null);

    /// <summary>The look of each UTF-16 unit of <paramref name="text"/> (null: the paragraph's own), later spans over earlier ones.</summary>
    private static TextLook?[] LooksOf(string text, IReadOnlyList<TextSpan>? spans)
    {
        var looks = new TextLook?[text.Length];
        if (spans is null) return looks;
        foreach (var s in spans)
            for (var i = Math.Max(0, s.Start); i < Math.Min(text.Length, s.End); i++)
                looks[i] = looks[i] is { } under ? under.With(s.Look) : s.Look;
        return looks;
    }

    /// <summary>
    /// The looks of a paragraph read back: each run an edit gave a look of its own, as a span over its text in
    /// <paramref name="text"/> (where <paramref name="at"/> says each run starts), its size and color as drawn, its font,
    /// bold and italic as its tag says; a run in another face of the paragraph's family (a bold word as the page's
    /// generator drew it) as bold or italic; spans of one look next to each other merged.
    /// </summary>
    private static List<TextSpan> SpansOf(TextRun lead, IEnumerable<(TextRun Run, int Start, int Length)> at)
    {
        var spans = new List<TextSpan>();
        foreach (var (r, start, length) in at)
        {
            if (length <= 0) continue;
            var size = Math.Abs(r.FontSize - lead.FontSize) > Math.Max(0.3, 0.05 * lead.FontSize) ? Math.Round(r.FontSize, 1) : (double?)null;
            TextLook look;
            if (r.Tag is { } tag) look = new TextLook(tag.Font, size, r.Color != lead.Color ? r.Color : null, tag.Bold, tag.Italic);
            else if (!r.StandIn && !ReferenceEquals(r.Font, lead.Font) && (r.Bold != lead.Bold || r.Italic != lead.Italic))
                look = new TextLook(null, size, r.Color != lead.Color ? r.Color : null, r.Bold != lead.Bold ? r.Bold : null, r.Italic != lead.Italic ? r.Italic : null);
            else continue;
            if (look.IsPlain) continue;
            if (spans.Count > 0 && spans[^1].Look == look && spans[^1].End >= start - 1)
                spans[^1] = spans[^1] with { Length = start + length - spans[^1].Start };
            else spans.Add(new TextSpan(start, length, look));
        }
        return spans;
    }

    /// <summary>
    /// Spans of <paramref name="old"/> carried over to <paramref name="now"/> (text typed without looks): each character
    /// both texts share (their longest common subsequence) keeps its look, and a character typed inside a word takes the
    /// look of the one before it, as in a word processor.
    /// </summary>
    internal static List<TextSpan> Carry(string old, string now, IReadOnlyList<TextSpan> spans)
    {
        if (spans.Count == 0) return [];
        if (old == now) return [.. spans];
        var map = new int[old.Length]; // where each old character went (-1: gone)
        Array.Fill(map, -1);
        var pre = 0;
        while (pre < old.Length && pre < now.Length && old[pre] == now[pre]) map[pre] = pre++;
        var suf = 0;
        while (suf < old.Length - pre && suf < now.Length - pre && old[^(suf + 1)] == now[^(suf + 1)])
        {
            map[old.Length - 1 - suf] = now.Length - 1 - suf;
            suf++;
        }
        int n = old.Length - pre - suf, m = now.Length - pre - suf;
        if (n > 0 && m > 0 && (long)n * m <= 1_000_000)
        {
            // The middle: longest common subsequence, filled from the end so it can be walked forward.
            var len = new int[(n + 1) * (m + 1)];
            for (var a = n - 1; a >= 0; a--)
                for (var b = m - 1; b >= 0; b--)
                    len[a * (m + 1) + b] = old[pre + a] == now[pre + b] ? len[(a + 1) * (m + 1) + b + 1] + 1 : Math.Max(len[(a + 1) * (m + 1) + b], len[a * (m + 1) + b + 1]);
            for (int a = 0, b = 0; a < n && b < m;)
            {
                if (old[pre + a] == now[pre + b])
                {
                    map[pre + a] = pre + b;
                    a++;
                    b++;
                }
                else if (len[(a + 1) * (m + 1) + b] >= len[a * (m + 1) + b + 1]) a++;
                else b++;
            }
        }
        var oldLooks = LooksOf(old, spans);
        var looks = new TextLook?[now.Length];
        var mapped = new bool[now.Length];
        for (var i = 0; i < old.Length; i++)
            if (map[i] >= 0)
            {
                looks[map[i]] = oldLooks[i];
                mapped[map[i]] = true;
            }
        for (var i = 1; i < now.Length; i++)
            if (!mapped[i] && !char.IsWhiteSpace(now[i]) && !char.IsWhiteSpace(now[i - 1])) looks[i] = looks[i - 1];
        var result = new List<TextSpan>();
        for (var i = 0; i < now.Length;)
        {
            if (looks[i] is not { IsPlain: false } look)
            {
                i++;
                continue;
            }
            var j = i + 1;
            while (j < now.Length && looks[j] == look) j++;
            result.Add(new TextSpan(i, j - i, look));
            i = j;
        }
        return result;
    }

    /// <summary>A color as an RGB fill operator.</summary>
    private static string RgbOp(int color) =>
        string.Create(CultureInfo.InvariantCulture,
            $"{ContentLexer.Number((color >> 16 & 0xFF) / 255.0)} {ContentLexer.Number((color >> 8 & 0xFF) / 255.0)} {ContentLexer.Number((color & 0xFF) / 255.0)} rg ");
}
