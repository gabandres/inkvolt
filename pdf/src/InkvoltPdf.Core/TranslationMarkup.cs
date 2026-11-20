using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>
/// A paragraph's looks as a translation request carries them (roadmap 3.1): its bold, italic, subscript and superscript
/// stretches as &lt;b&gt;, &lt;i&gt;, &lt;sub&gt; and &lt;sup&gt; tags in the text, a stretch in another color or class of font
/// as &lt;span&gt;, and the reply's tags read back as looks. A model drops, moves and invents tags: a reply whose markup
/// can't be trusted comes back plain, with no tag left in its text.
/// </summary>
internal static partial class TranslationMarkup
{
    /// <summary>The most stretches a paragraph's markup has: past it only its scripts are marked, and past that it goes plain (a crafted page, or a paragraph a model would garble).</summary>
    internal const int MaxStretches = 64;

    /// <summary>The most tags read from a reply before it is given up on as plain.</summary>
    private const int MaxReplyTags = 4 * MaxStretches * 2 + 16;

    /// <summary>The deepest tags nest: bold, italic, another look, then a script.</summary>
    private const int MaxDepth = 4;

    [Flags]
    private enum Kind : byte { None = 0, Bold = 1, Italic = 2, Other = 4, Sub = 8, Super = 16 }

    private const Kind Scripts = Kind.Sub | Kind.Super;
    private const Kind Faces = Kind.Bold | Kind.Italic;

    private static readonly (Kind Kind, string Name)[] Names = [(Kind.Bold, "b"), (Kind.Italic, "i"), (Kind.Other, "span"), (Kind.Sub, "sub"), (Kind.Super, "sup")];

    /// <summary>
    /// What a look sets apart from the paragraph's own: bold or italic either way (a bold word, or a regular one in a bold
    /// paragraph), another look (<see cref="OtherOf"/>), a script.
    /// </summary>
    private static Kind KindOf(TextLook? look) =>
        look is null ? Kind.None
            : (look.Bold is not null ? Kind.Bold : 0) | (look.Italic is not null ? Kind.Italic : 0) | (OtherOf(look) is not null ? Kind.Other : 0)
            | (look.Script == TextScript.Sub ? Kind.Sub : look.Script == TextScript.Super ? Kind.Super : 0);

    /// <summary>A look's family and color where neither bold nor italic explains them (a name in Times among Arial, a red word); null when it has neither.</summary>
    private static (string? Font, int? Color)? OtherOf(TextLook look)
    {
        var font = look.Bold is null && look.Italic is null ? look.Font : null;
        return font is null && look.Color is null ? null : (font, look.Color);
    }

    /// <summary>
    /// Whether text can carry markup: its own angle brackets, if any, read as text whatever happens to the reply ("a &lt; b",
    /// "-&gt;", "p&lt;0.05"); not when one would be read as a tag or a piece of one ("&lt;html&gt;", "x&lt;y", "b&gt;").
    /// </summary>
    private static bool Markable(string text)
    {
        if (text.AsSpan().IndexOfAny('<', '>') < 0) return true;
        for (var i = 0; i + 1 < text.Length; i++)
            if (text[i] == '<' && OpensTag(text[i + 1])) return false;
        return !BrokenEnd().IsMatch(text) && !TagPiece().IsMatch(text) && Stripped(text) == Collapsed(text);
    }

    /// <summary>
    /// <paramref name="text"/> with its looks as tags, nested in one order (bold, italic, another look, then sub or sup);
    /// the text as it is when it has none or can't carry them (<see cref="Markable"/>), only its scripts when it has more
    /// than <see cref="MaxStretches"/> stretches, plain when even those are more.
    /// </summary>
    public static string Mark(string text, IReadOnlyList<TextSpan> spans) => Marking(text, spans).Marked;

    /// <summary>The markup <see cref="Mark"/> writes, and the looks it marked (<see cref="Kept"/>, or only the scripts of them).</summary>
    private static (string Marked, List<TextSpan> Kept) Marking(string text, IReadOnlyList<TextSpan> spans)
    {
        if (spans.Count == 0 || spans.Count > 4 * MaxStretches || !Markable(text)) return (text, []);
        var kept = Kept(spans);
        var marked = Write(text, kept);
        if (marked is null)
        {
            // Too many looks: the scripts alone ("x_1", "10^3": they change what the text says), else none.
            kept = [.. kept.Where(s => s.Look.Script is not null).Select(s => s with { Look = new TextLook(Size: s.Look.Size, Script: s.Look.Script, Rise: s.Look.Rise) })];
            marked = Write(text, kept);
        }
        return marked is null || marked == text ? (text, []) : (marked, kept);
    }

    /// <summary>
    /// The looks a paragraph's markup carries: in a bold (italic) paragraph, its regular stretches (a bold word's "bold"
    /// says nothing there); of its stretches in another color or class of font, those of the first such look only
    /// (one &lt;span&gt; can't tell two apart), the others keeping only their bold, italic or script.
    /// </summary>
    private static List<TextSpan> Kept(IReadOnlyList<TextSpan> spans)
    {
        bool boldOff = spans.Any(s => s.Look.Bold == false), italicOff = spans.Any(s => s.Look.Italic == false);
        (string? Font, int? Color)? other = null;
        var kept = new List<TextSpan>(spans.Count);
        foreach (var s in spans)
        {
            var look = s.Look;
            // (A family it had went with that face: it isn't another look of its own.)
            if (look.Bold == true && boldOff) look = look with { Bold = null, Font = look.Italic is null ? null : look.Font };
            if (look.Italic == true && italicOff) look = look with { Italic = null, Font = look.Bold is null ? null : look.Font };
            if (OtherOf(look) is { } o)
            {
                other ??= o;
                if (o != other) look = look with { Color = null, Font = look.Bold is null && look.Italic is null ? null : look.Font };
            }
            if (KindOf(look) != Kind.None) kept.Add(s with { Look = look });
        }
        return kept;
    }

    /// <summary>The looks set the other way round: bold (italic) where the paragraph's own text is, its regular stretches being the ones its spans name.</summary>
    private static Kind Inverted(IReadOnlyList<TextSpan> kept) =>
        (kept.Any(s => s.Look.Bold == false) ? Kind.Bold : 0) | (kept.Any(s => s.Look.Italic == false) ? Kind.Italic : 0);

    /// <summary>The text with the looks as tags; null past <see cref="MaxStretches"/> stretches.</summary>
    private static string? Write(string text, IReadOnlyList<TextSpan> kept)
    {
        if (kept.Count == 0) return text;
        var kinds = KindsOf(text.Length, kept, Inverted(kept));
        var sb = new StringBuilder(text.Length + 32);
        var open = new List<Kind>(MaxDepth);
        var stretches = 0;
        for (var i = 0; i <= text.Length; i++)
        {
            if (i > 0 && i < text.Length && kinds[i] == kinds[i - 1])
            {
                sb.Append(text[i]);
                continue;
            }
            var want = i < text.Length ? kinds[i] : Kind.None;
            var wanted = Ordered(want);
            var keep = 0;
            while (keep < open.Count && keep < wanted.Count && open[keep] == wanted[keep]) keep++;
            for (var k = open.Count - 1; k >= keep; k--) sb.Append("</").Append(NameOf(open[k])).Append('>');
            open.RemoveRange(keep, open.Count - keep);
            for (var k = keep; k < wanted.Count; k++)
            {
                sb.Append('<').Append(NameOf(wanted[k])).Append('>');
                open.Add(wanted[k]);
                if (++stretches > MaxStretches) return null;
            }
            if (i < text.Length) sb.Append(text[i]);
        }
        return sb.ToString();
    }

    /// <summary>
    /// Each character's tags: bold, italic or another look where any span gives it (where none does, for a look
    /// <paramref name="inverted"/>); a later span's script replacing an earlier one's (as looks lay over each other), never
    /// sub and sup at once. Linear in the text and the spans, however they overlap (a crafted page's 256 spans over a
    /// paragraph of millions of characters).
    /// </summary>
    private static Kind[] KindsOf(int length, IReadOnlyList<TextSpan> spans, Kind inverted)
    {
        var kinds = new Kind[length];
        int[]? bold = null, italic = null, other = null, next = null;
        for (var s = spans.Count - 1; s >= 0; s--)
        {
            var k = KindOf(spans[s].Look);
            int from = Math.Max(0, spans[s].Start), to = Math.Min(length, spans[s].End);
            if (k == Kind.None || from >= to) continue;
            if ((k & Kind.Bold) != 0) Count(ref bold, from, to);
            if ((k & Kind.Italic) != 0) Count(ref italic, from, to);
            if ((k & Kind.Other) != 0) Count(ref other, from, to);
            if ((k & Scripts) == 0) continue;
            // Latest span first: a character's script is the first one set; next[i] skips characters already set.
            if (next is null)
            {
                next = new int[length + 1];
                for (var i = 0; i <= length; i++) next[i] = i;
            }
            for (var i = Unset(next, from); i < to; i = Unset(next, i))
            {
                kinds[i] = k & Scripts;
                next[i] = i + 1;
            }
        }
        if (bold is null && italic is null && other is null && inverted == Kind.None) return kinds;
        int b = 0, it = 0, o = 0;
        for (var i = 0; i < length; i++)
        {
            if ((bold is not null && (b += bold[i]) > 0) != ((inverted & Kind.Bold) != 0)) kinds[i] |= Kind.Bold;
            if ((italic is not null && (it += italic[i]) > 0) != ((inverted & Kind.Italic) != 0)) kinds[i] |= Kind.Italic;
            if (other is not null && (o += other[i]) > 0) kinds[i] |= Kind.Other;
        }
        return kinds;

        void Count(ref int[]? starts, int from, int to)
        {
            starts ??= new int[length + 1];
            starts[from]++;
            starts[to]--;
        }
    }

    /// <summary>The first character at or after <paramref name="i"/> with no script set yet (path halving).</summary>
    private static int Unset(int[] next, int i)
    {
        while (next[i] != i)
        {
            next[i] = next[next[i]];
            i = next[i];
        }
        return i;
    }

    private static List<Kind> Ordered(Kind k)
    {
        var list = new List<Kind>(MaxDepth);
        foreach (var (kind, _) in Names)
            if ((k & kind) != 0) list.Add(kind);
        return list;
    }

    private static string NameOf(Kind k) => Names.First(n => n.Kind == k).Name;

    /// <summary>The text of marked text with its tags taken out (what goes to a model when the markup can't go whole).</summary>
    public static string Plain(string marked) => Stripped(marked);

    /// <summary>
    /// Marked text in pieces of at most about <paramref name="maxTokens"/> tokens (<see cref="AiText.Pieces"/>), each with its
    /// tags closed at its end and opened again at the next one's start, so each piece is markup of its own and the answers
    /// joined are markup for the whole. Null when a cut falls inside a tag.
    /// </summary>
    public static List<string>? Pieces(string marked, int maxTokens)
    {
        var pieces = AiText.Pieces(marked, maxTokens).ToList();
        if (pieces.Count <= 1) return pieces;
        var open = new List<Kind>(MaxDepth);
        var result = new List<string>(pieces.Count);
        foreach (var piece in pieces)
        {
            var sb = new StringBuilder(piece.Length + 32);
            foreach (var k in open) sb.Append('<').Append(NameOf(k)).Append('>');
            sb.Append(piece);
            for (var i = 0; i < piece.Length; i++)
            {
                if (piece[i] != '<' || i + 1 >= piece.Length || !OpensTag(piece[i + 1])) continue;
                var end = piece.IndexOf('>', i + 1, Math.Min(6, piece.Length - i - 1));
                if (end < 0) return null;
                var name = piece.AsSpan(i + 1, end - i - 1);
                var kind = KindNamed(name);
                if (kind == Kind.None) return null;
                if (name[0] != '/') open.Add(kind);
                else if (open.Count > 0 && open[^1] == kind) open.RemoveAt(open.Count - 1);
                else return null;
                i = end;
            }
            for (var k = open.Count - 1; k >= 0; k--) sb.Append("</").Append(NameOf(open[k])).Append('>');
            result.Add(sb.ToString());
        }
        return open.Count == 0 ? result : null;
    }

    /// <summary>
    /// Whether <paramref name="answer"/> to a paragraph's <paramref name="text"/> (sent as <paramref name="sent"/>, its
    /// markup if it had looks) is the text itself: the markup echoed, or the plain text, or the markup with tags dropped.
    /// </summary>
    public static bool Echoes(string answer, string text, string sent)
    {
        if (answer == sent || answer == text) return true;
        return sent != text && Collapsed(Stripped(answer)) == Collapsed(text);
    }

    private static string Collapsed(string s) => string.Join(' ', s.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    /// <summary>A reply with every tag taken out but ours of the looks <paramref name="sent"/> (the marked text) has.</summary>
    public static string WithoutOtherTags(string reply, string sent)
    {
        var had = Kind.None;
        foreach (Match m in AnyTag().Matches(sent))
            if (IsOurs(m.ValueSpan)) had |= KindNamed(m.ValueSpan[1..^1]);
        return AnyTag().Replace(reply, m => IsOurs(m.ValueSpan) && (KindNamed(m.ValueSpan[1..^1]) & had) != 0 ? m.Value : "");
    }

    /// <summary>Whether a whole tag ("&lt;b&gt;", "&lt;/SUB&gt;") is one of ours.</summary>
    private static bool IsOurs(ReadOnlySpan<char> tag) => tag.Length >= 3 && tag[0] == '<' && tag[^1] == '>' && KindNamed(tag[1..^1]) != Kind.None;

    /// <summary>The look a tag's name (with or without its closing slash) stands for; none when it isn't ours.</summary>
    private static Kind KindNamed(ReadOnlySpan<char> name)
    {
        if (name.Length > 0 && name[0] == '/') name = name[1..];
        foreach (var (k, n) in Names)
            if (name.Equals(n, StringComparison.OrdinalIgnoreCase)) return k;
        return Kind.None;
    }

    /// <summary>
    /// A reply to the paragraph <paramref name="text"/> with looks <paramref name="spans"/>: its text and its looks. The
    /// markup is trusted when its tags are ours and balanced, nest properly (no tag inside itself, no sub and sup
    /// together), name only looks the paragraph had, and cover about as much as they did (a stretch at most twice as long
    /// as the paragraph's longest of that look and a little more, at most twice its share of the text and a little more;
    /// a look the paragraph had nearly everywhere, its bold around a regular word, at least about half its share); a tag
    /// dropped only leaves its words plain. Otherwise the reply comes back plain, every tag and fragment of one taken out.
    /// Text with angle brackets of its own that could be read as tags was sent as it is and comes back as it is. Linear
    /// in the reply's length.
    /// </summary>
    public static (string Text, List<TextSpan> Spans) Read(string answer, string text, IReadOnlyList<TextSpan> spans)
    {
        if (!Markable(text)) return (answer, []);
        if (answer.AsSpan().IndexOfAny('<', '>') < 0) return (answer, []);
        var (marked, kept) = Marking(text, spans);
        var inverted = Inverted(kept);
        if (Parse(marked) is not { } source || Parse(answer) is not { } reply || !Trusted(source, reply, inverted)) return (Stripped(answer), []);
        // What each look was on the page: the family of its face, the other look's family and color, a script's size and rise.
        var faces = new Dictionary<Kind, string>();
        (string? Font, int? Color)? other = null;
        var scripts = new Dictionary<Kind, (double? Size, double? Rise)>();
        foreach (var s in kept)
        {
            var k = KindOf(s.Look);
            if ((k & Faces) != 0 && s.Look.Font is { } f) faces.TryAdd(k & Faces, f);
            other ??= OtherOf(s.Look);
            if ((k & Scripts) != 0) scripts.TryAdd(k & Scripts, (s.Look.Size, s.Look.Rise));
        }
        var result = new List<TextSpan>();
        var kinds = reply.Kinds;
        for (var i = 0; i < kinds.Length;)
        {
            var k = kinds[i];
            var j = i + 1;
            while (j < kinds.Length && kinds[j] == k) j++;
            var rel = k ^ inverted; // against the paragraph's own: in a bold paragraph, no <b> is a regular word
            if (rel != Kind.None)
            {
                var (size, rise) = scripts.GetValueOrDefault(k & Scripts);
                var mine = (rel & Kind.Other) != 0 ? other : null;
                result.Add(new TextSpan(i, j - i, new TextLook(
                    Font: faces.GetValueOrDefault(rel & Faces) ?? mine?.Font,
                    Size: size,
                    Color: mine?.Color,
                    Bold: (rel & Kind.Bold) != 0 ? (inverted & Kind.Bold) == 0 : null,
                    Italic: (rel & Kind.Italic) != 0 ? (inverted & Kind.Italic) == 0 : null,
                    Script: (k & Kind.Sub) != 0 ? TextScript.Sub : (k & Kind.Super) != 0 ? TextScript.Super : null,
                    Rise: rise)));
            }
            i = j;
        }
        return (reply.Text, result);
    }

    /// <summary>
    /// For a real model's report (<c>TranslationRealModelTests</c>): how many stretches the markup <paramref name="sent"/>
    /// had and <paramref name="answer"/> has, and whether its markup would be trusted (null: it has no tags at all).
    /// </summary>
    internal static (int Sent, int Back, bool? Trusted) Kept(string answer, string sent)
    {
        if (Parse(sent) is not { } source) return (0, 0, null);
        var had = source.Stretches.Values.Sum(l => l.Count);
        if (!answer.Contains('<', StringComparison.Ordinal)) return (had, 0, null);
        if (Parse(answer) is not { } reply) return (had, 0, false);
        // Bold or italic over most of the text: a paragraph of that look, marked the other way round.
        var inverted = Kind.None;
        foreach (var k in new[] { Kind.Bold, Kind.Italic })
            if (source.Stretches.TryGetValue(k, out var l) && l.Sum() * 2 > source.Letters) inverted |= k;
        return (had, reply.Stretches.Values.Sum(l => l.Count), Trusted(source, reply, inverted));
    }

    /// <summary>Text read from markup: its characters (spaces collapsed, ends trimmed), each one's looks, and per look its stretches' lengths (not counting spaces).</summary>
    private sealed record Parsed(string Text, Kind[] Kinds, Dictionary<Kind, List<int>> Stretches, int Letters, Kind Opened);

    /// <summary>Whether '&lt;' followed by <paramref name="next"/> opens a tag ("&lt;b", "&lt;/", "&lt;!--"), not a bare bracket ("a &lt; b", "&lt;-").</summary>
    private static bool OpensTag(char next) => char.IsAsciiLetter(next) || next is '/' or '!' or '?';

    /// <summary>
    /// Markup read in one pass; null when it isn't well formed (another tag, one unclosed or crossed, a tag inside itself,
    /// sub and sup together, a piece of one of ours). A bare '&lt;' or '&gt;' ("-&gt;", "a &lt; b") is text.
    /// </summary>
    private static Parsed? Parse(string s)
    {
        if (BrokenEnd().IsMatch(s)) return null;
        var text = new StringBuilder(s.Length);
        var kinds = new List<Kind>(s.Length);
        var stack = new List<(Kind Kind, int Letters)>(MaxDepth);
        var stretches = new Dictionary<Kind, List<int>>();
        Kind cur = Kind.None, opened = Kind.None;
        int tags = 0, letters = 0;
        for (var i = 0; i < s.Length;)
        {
            var c = s[i];
            if (c == '<' && i + 1 < s.Length && OpensTag(s[i + 1]))
            {
                var end = s.IndexOf('>', i + 1, Math.Min(6, s.Length - i - 1));
                if (end < 0) return null;
                var name = s.AsSpan(i + 1, end - i - 1);
                var closing = name.Length > 0 && name[0] == '/';
                var kind = KindNamed(name);
                if (kind == Kind.None || ++tags > MaxReplyTags) return null;
                if (!closing)
                {
                    if ((cur & kind) != 0 || stack.Count >= MaxDepth || (kind & Scripts) != 0 && (cur & Scripts) != 0) return null;
                    stack.Add((kind, letters));
                    cur |= kind;
                    opened |= kind;
                }
                else
                {
                    if (stack.Count == 0 || stack[^1].Kind != kind) return null;
                    var length = letters - stack[^1].Letters;
                    stack.RemoveAt(stack.Count - 1);
                    cur &= ~kind;
                    if (length > 0)
                    {
                        if (!stretches.TryGetValue(kind, out var list)) stretches[kind] = list = [];
                        list.Add(length);
                    }
                }
                i = end + 1;
                continue;
            }
            if (char.IsWhiteSpace(c))
            {
                // One space between words, whatever tags stand between them; none at the start.
                if (text.Length > 0 && text[^1] != ' ')
                {
                    text.Append(' ');
                    kinds.Add(cur);
                }
            }
            else
            {
                text.Append(c);
                kinds.Add(cur);
                letters++;
            }
            i++;
        }
        if (stack.Count > 0) return null;
        while (text.Length > 0 && text[^1] == ' ')
        {
            text.Length--;
            kinds.RemoveAt(kinds.Count - 1);
        }
        return new Parsed(text.ToString(), [.. kinds], stretches, letters, opened);
    }

    /// <summary>Whether a reply's markup says about what the source's did (see <see cref="Read"/>).</summary>
    private static bool Trusted(Parsed source, Parsed reply, Kind inverted)
    {
        if ((reply.Opened & ~source.Opened) != 0) return false; // a look the paragraph didn't have, even around nothing
        foreach (var (kind, lengths) in reply.Stretches)
        {
            if (!source.Stretches.TryGetValue(kind, out var had)) return false; // a look the paragraph didn't have
            if (lengths.Count > 2 * had.Count + 1) return false;
            var script = kind is Kind.Sub or Kind.Super;
            // A look set the other way round covers most of its paragraph: its stretches are as long as the text between regular words.
            if ((kind & inverted) == 0 && lengths.Max() > 2 * had.Max() + (script ? 4 : 12)) return false;
            double share = (double)had.Sum() / Math.Max(1, source.Letters), now = (double)lengths.Sum() / Math.Max(1, reply.Letters);
            if (now > 2 * share + 0.1) return false;
        }
        // A bold paragraph's bold dropped around its words would make them regular: most of it must still be bold.
        foreach (var kind in new[] { Kind.Bold, Kind.Italic })
        {
            if ((kind & inverted) == 0 || !source.Stretches.TryGetValue(kind, out var had)) continue;
            double share = (double)had.Sum() / Math.Max(1, source.Letters);
            var now = reply.Stretches.TryGetValue(kind, out var got) ? (double)got.Sum() / Math.Max(1, reply.Letters) : 0;
            if (now < share / 2 - 0.1) return false;
        }
        return true;
    }

    /// <summary>
    /// A reply with every tag, and every piece of one of ours, taken out; then any '&lt;' left that opens a tag; spaces
    /// collapsed. A bare '&lt;' or '&gt;' ("-&gt;", "a &lt; b") stays.
    /// </summary>
    private static string Stripped(string reply)
    {
        var s = AnyTag().Replace(reply, "");
        s = TagPiece().Replace(s, "");
        s = TagOpening().Replace(s, "");
        return Collapsed(s);
    }

    [GeneratedRegex(@"</?[A-Za-z][^<>]{0,60}>|<[!?][^<>]{0,60}>")]
    private static partial Regex AnyTag();

    // What is left of one of ours cut short or garbled: "<b", "</sub", "< sup>", "/b>", "/SUB >", "sup>", " i>". A lone
    // letter's '>' counts only when it touches the letter and no number or '=' follows: "i > 0", "b >= a", "i>0" are text.
    [GeneratedRegex(@"<\s*/?\s*(?:b|i|span|sub|sup)\b(?:\s*>)?|/\s*(?:b|i|span|sub|sup)\s*>|(?<![\p{L}\p{N}])(?:b|i|span|sub|sup)>(?![\p{N}=])", RegexOptions.IgnoreCase)]
    private static partial Regex TagPiece();

    // The end of one of ours whose '<' is gone ("negrita/b>", "x /sub>", "word i>"); a whole tag ("<b>", "</b>") isn't one,
    // nor a comparison ("i > 0", "b >= a", "i>0").
    [GeneratedRegex(@"(?<!<)/\s*(?:b|i|span|sub|sup)\s*>|(?<![\p{L}\p{N}</])(?:b|i|span|sub|sup)>(?![\p{N}=])", RegexOptions.IgnoreCase)]
    private static partial Regex BrokenEnd();

    // A '<' that opens a tag never closed ("<span", "</").
    [GeneratedRegex(@"<(?=[A-Za-z/!?])")]
    private static partial Regex TagOpening();
}
