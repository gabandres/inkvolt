using System.Globalization;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>
/// How a stretch of a paragraph looks where it differs from the paragraph's own (roadmap 2.1, part c): an installed font
/// family ("Georgia"), its size on the page (points), its color (0xRRGGBB), bold, italic. Null keeps the paragraph's own.
/// </summary>
/// <param name="Script">A subscript or superscript: smaller, below or above the line's baseline (a translated copy's "d_model", "2^10").</param>
public sealed record TextLook(string? Font = null, double? Size = null, int? Color = null, bool? Bold = null, bool? Italic = null, TextScript? Script = null)
{
    public static readonly TextLook Plain = new();

    public bool IsPlain => Font is null && Size is null && Color is null && Bold is null && Italic is null && Script is null;

    /// <summary>This look with what <paramref name="other"/> sets laid over it.</summary>
    public TextLook With(TextLook other) => new(other.Font ?? Font, other.Size ?? Size, other.Color ?? Color, other.Bold ?? Bold, other.Italic ?? Italic, other.Script ?? Script);
}

/// <summary>Text set below or above its line's baseline, smaller.</summary>
public enum TextScript { Sub, Super }

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

    /// <summary>
    /// What the tag around styled text says: the font family, bold, italic and subscript or superscript that were asked
    /// for (size and color are read from the text: a script's size is <see cref="ScriptScale"/> of its look's).
    /// </summary>
    internal sealed record LookTag(string? Font, bool? Bold, bool? Italic, TextScript? Script = null)
    {
        public static LookTag Read(CObj props)
        {
            var font = props["Font"] is { Kind: CKind.String } f ? Encoding.UTF8.GetString(f.Bytes) : null;
            bool? Flag(string key) => props[key] is { Kind: CKind.Bool } b ? b.Name == "true" : null;
            var script = props["Script"] is { Kind: CKind.Name } s ? s.Name switch { "Sub" => TextScript.Sub, "Super" => TextScript.Super, _ => (TextScript?)null } : null;
            return new LookTag(font, Flag("Bold"), Flag("Italic"), script);
        }

        public static string Write(TextLook look)
        {
            var sb = new StringBuilder($"/{LookTagName} <<");
            if (look.Font is { } f) sb.Append(" /Font ").Append(ContentLexer.Literal(Encoding.UTF8.GetBytes(f)));
            if (look.Bold is { } b) sb.Append(" /Bold ").Append(b ? "true" : "false");
            if (look.Italic is { } i) sb.Append(" /Italic ").Append(i ? "true" : "false");
            if (look.Script is { } s) sb.Append(" /Script ").Append(s == TextScript.Sub ? "/Sub" : "/Super");
            return sb.Append(" >> BDC ").ToString();
        }
    }

    /// <summary>
    /// A look resolved for writing: its size against the paragraph's (<see cref="Scale"/>), its color (null: the
    /// paragraph's), the installed font it is drawn in (null: a page font), the look as asked (for the tag), and the
    /// page's own font it is drawn in when the paragraph has that face (a bold word's font; null: the paragraph's own).
    /// </summary>
    /// <param name="Rise">How far its baseline sits above the line's (a superscript) or below (negative, a subscript), in ems of the paragraph's text.</param>
    internal sealed record PartLook(double Scale, int? Color, StandInFont? Face, TextLook Asked, TextRun? Page = null, double Rise = 0);

    /// <summary>A subscript's or superscript's size against its line's text, and how far its baseline moves (ems of the line's text, up positive).</summary>
    internal const double ScriptScale = 0.7, SubRise = -0.15, SuperRise = 0.35;

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
    /// generator drew it) as bold or italic; a run in another family as that family (with bold or italic where its
    /// face differs); a subscript or superscript as its tag says, at the size of the look it is in; spans of one look
    /// next to each other or a space apart merged.
    /// </summary>
    private static List<TextSpan> SpansOf(TextRun lead, string text, IEnumerable<(TextRun Run, int Start, int Length)> at)
    {
        var spans = new List<TextSpan>();
        foreach (var (r, start, length) in at)
        {
            if (length <= 0) continue;
            var drawn = r.Tag?.Script is not null ? r.FontSize / ScriptScale : r.FontSize;
            var size = Math.Abs(drawn - lead.FontSize) > Math.Max(0.3, 0.05 * lead.FontSize) ? Math.Round(drawn, 1) : (double?)null;
            TextLook look;
            if (r.Tag is { } tag) look = new TextLook(tag.Font, size, r.Color != lead.Color ? r.Color : null, tag.Bold, tag.Italic, tag.Script);
            else if (!r.StandIn && r.Font is not null && !SameFamily(r, lead))
                look = new TextLook(FontNames.Family(r.FontName), size, r.Color != lead.Color ? r.Color : null, r.Bold != lead.Bold ? r.Bold : null, r.Italic != lead.Italic ? r.Italic : null);
            else if (!r.StandIn && !ReferenceEquals(r.Font, lead.Font) && (r.Bold != lead.Bold || r.Italic != lead.Italic))
                look = new TextLook(null, size, r.Color != lead.Color ? r.Color : null, r.Bold != lead.Bold ? r.Bold : null, r.Italic != lead.Italic ? r.Italic : null);
            else continue;
            if (look.IsPlain) continue;
            if (spans.Count > 0 && spans[^1].Look == look && JoinsAcrossSpace(spans[^1].End, start, i => text[i]))
                spans[^1] = spans[^1] with { Length = start + length - spans[^1].Start };
            else spans.Add(new TextSpan(start, length, look));
        }
        return spans;
    }

    /// <summary>
    /// Whether a stretch starting at <paramref name="start"/> carries on one ending at <paramref name="end"/> of the same
    /// look: right after it, or with a space between ("brown fox"); not across a letter ("a²b³", "BoldxFace").
    /// </summary>
    private static bool JoinsAcrossSpace(int end, int start, Func<int, char> at) => start <= end || start == end + 1 && at(end) == ' ';

    /// <summary>A line's own baseline and size, as most of its characters sit on it (not a big name set higher, nor a script).</summary>
    private static (double Y, double Size) LineBaseline(PLine line)
    {
        var chars = new Dictionary<double, (int Count, Dictionary<double, int> Sizes)>();
        foreach (var r in line.Runs)
        {
            var n = r.Text.Trim().Length;
            if (n == 0) continue;
            var y = Math.Round(r.Origin.Y * 4) / 4;
            if (!chars.TryGetValue(y, out var at)) at = (0, []);
            var size = Math.Round(r.FontSize, 1);
            at.Sizes[size] = at.Sizes.GetValueOrDefault(size) + n;
            chars[y] = (at.Count + n, at.Sizes);
        }
        if (chars.Count == 0) return (line.Lead.Origin.Y, line.Lead.FontSize);
        var (baseline, most) = chars.MaxBy(kv => kv.Value.Count);
        return (baseline, most.Sizes.MaxBy(kv => kv.Value).Key);
    }

    /// <summary>
    /// For a translated copy, the look a run of a paragraph's line has that its translation keeps (<see cref="TranslationMarkup"/>):
    /// bold or italic where the paragraph's own text (<paramref name="own"/>) isn't (with its family when that is another,
    /// so the page's face for it is found again: LaTeX's bold and italic are families of their own); a subscript or a
    /// superscript where it is smaller than its line's text and below or above its baseline (<see cref="LineBaseline"/>).
    /// Null: the paragraph's own.
    /// </summary>
    private static TextLook? TranslationLook(TextRun own, (double Y, double Size) line, TextRun r)
    {
        if (r.Text.Trim().Length == 0) return null;
        TextScript? script = null;
        if (line.Size > 0 && r.FontSize <= 0.85 * line.Size)
        {
            var drop = r.Origin.Y - line.Y; // page space: down is positive
            if (drop >= 0.08 * line.Size) script = TextScript.Sub;
            else if (drop <= -0.12 * line.Size) script = TextScript.Super;
        }
        // A stand-in an earlier edit drew says its look only by its tag.
        bool bold = r.Tag?.Bold ?? (r.StandIn ? own.Bold : r.Bold), italic = r.Tag?.Italic ?? (r.StandIn ? own.Italic : r.Italic);
        var b = bold && !own.Bold;
        var i = italic && !own.Italic;
        if (!b && !i && script is null) return null;
        var family = (b || i) && !r.StandIn && r.Tag is null && r.Font is not null && !SameFamily(r, own) ? FontNames.Family(r.FontName) : null;
        return new TextLook(family, Bold: b ? true : null, Italic: i ? true : null, Script: script);
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
