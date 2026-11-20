using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>
/// A paragraph's looks as a translation request carries them (roadmap 3.1): its bold, italic, underlined, subscript and
/// superscript stretches as &lt;b&gt;, &lt;i&gt;, &lt;u&gt;, &lt;sub&gt; and &lt;sup&gt; tags in the text, a stretch in another color or class of font
/// as &lt;span&gt; (a second and a third such look as &lt;font&gt; and &lt;mark&gt;), and the reply's tags read back as looks. A model drops, moves and invents tags: a reply whose markup
/// can't be trusted comes back plain, with no tag left in its text.
/// </summary>
internal static partial class TranslationMarkup
{
    /// <summary>The most stretches a paragraph's markup has: past it only its scripts are marked, and past that it goes plain (a crafted page, or a paragraph a model would garble).</summary>
    internal const int MaxStretches = 64;

    /// <summary>The most tags read from a reply before it is given up on as plain.</summary>
    private const int MaxReplyTags = 4 * MaxStretches * 2 + 16;

    /// <summary>The deepest tags nest: bold, italic, underline, another look, then a script.</summary>
    private const int MaxDepth = 5;

    /// <summary>
    /// What a stretch has besides its paragraph's own look. <see cref="Other"/>, <see cref="Other2"/> and <see cref="Other3"/>
    /// are a paragraph's first, second and third other looks (<see cref="OtherOf"/>: a red word, a word in Courier), as
    /// &lt;span&gt;, &lt;font&gt; and &lt;mark&gt;; a character has one of them at most.
    /// </summary>
    [Flags]
    private enum Kind : byte { None = 0, Bold = 1, Italic = 2, Other = 4, Sub = 8, Super = 16, Underline = 32, Other2 = 64, Other3 = 128 }

    private const Kind Scripts = Kind.Sub | Kind.Super;
    private const Kind Faces = Kind.Bold | Kind.Italic;
    private const Kind Others = Kind.Other | Kind.Other2 | Kind.Other3;

    /// <summary>The other looks a paragraph's markup tells apart, in the order of <see cref="Kind.Other"/>, <see cref="Kind.Other2"/>, <see cref="Kind.Other3"/>.</summary>
    private static readonly Kind[] OtherKinds = [Kind.Other, Kind.Other2, Kind.Other3];

    private static readonly (Kind Kind, string Name)[] Names =
        [(Kind.Bold, "b"), (Kind.Italic, "i"), (Kind.Underline, "u"), (Kind.Other, "span"), (Kind.Other2, "font"), (Kind.Other3, "mark"), (Kind.Sub, "sub"), (Kind.Super, "sup")];

    /// <summary>
    /// What a look sets apart from the paragraph's own: bold or italic either way (a bold word, or a regular one in a bold
    /// paragraph), underlined, another look (<see cref="OtherOf"/>; which of the paragraph's is told by <see cref="OthersOf"/>), a script.
    /// </summary>
    private static Kind KindOf(TextLook? look) =>
        look is null ? Kind.None
            : (look.Bold is not null ? Kind.Bold : 0) | (look.Italic is not null ? Kind.Italic : 0) | (look.Underline == true ? Kind.Underline : 0) | (OtherOf(look) is not null ? Kind.Other : 0)
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
    /// <paramref name="text"/> with its looks as tags, nested in one order (bold, italic, underline, another look, then sub or sup);
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
    /// says nothing there); of its stretches in another color or class of font, those of its first three such looks (one
    /// tag each, <see cref="OtherKinds"/>), any further one keeping only its bold, italic, underline or script.
    /// </summary>
    private static List<TextSpan> Kept(IReadOnlyList<TextSpan> spans)
    {
        bool boldOff = spans.Any(s => s.Look.Bold == false), italicOff = spans.Any(s => s.Look.Italic == false);
        var others = new List<(string? Font, int? Color)>(OtherKinds.Length);
        var kept = new List<TextSpan>(spans.Count);
        foreach (var s in spans)
        {
            var look = s.Look;
            // (A family it had went with that face: it isn't another look of its own.)
            if (look.Bold == true && boldOff) look = look with { Bold = null, Font = look.Italic is null ? null : look.Font };
            if (look.Italic == true && italicOff) look = look with { Italic = null, Font = look.Bold is null ? null : look.Font };
            if (OtherOf(look) is { } o && !others.Contains(o))
            {
                if (others.Count < OtherKinds.Length) others.Add(o);
                else look = look with { Color = null, Font = look.Bold is null && look.Italic is null ? null : look.Font };
            }
            if (KindOf(look) != Kind.None) kept.Add(s with { Look = look });
        }
        return kept;
    }

    /// <summary>The other looks of kept stretches (<see cref="Kept"/>), in the order they first come: the n-th is marked as <see cref="OtherKinds"/>' n-th.</summary>
    private static List<(string? Font, int? Color)> OthersOf(IReadOnlyList<TextSpan> kept)
    {
        var others = new List<(string? Font, int? Color)>(OtherKinds.Length);
        foreach (var s in kept)
            if (OtherOf(s.Look) is { } o && !others.Contains(o) && others.Count < OtherKinds.Length) others.Add(o);
        return others;
    }

    /// <summary>A kept look's kinds, its other look told apart among the paragraph's (<paramref name="others"/>).</summary>
    private static Kind KindOf(TextLook look, List<(string? Font, int? Color)> others)
    {
        var k = KindOf(look);
        if ((k & Kind.Other) == 0) return k;
        var at = others.IndexOf(OtherOf(look)!.Value);
        return (k & ~Kind.Other) | (at >= 0 ? OtherKinds[at] : 0);
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
    /// Each character's tags: bold, italic or underline where any span gives it (where none does, for a look
    /// <paramref name="inverted"/>); a later span's script, or other look, replacing an earlier one's (as looks lay over
    /// each other), never sub and sup at once nor two other looks. Linear in the text and the spans, however they overlap
    /// (a crafted page's 256 spans over a paragraph of millions of characters).
    /// </summary>
    private static Kind[] KindsOf(int length, IReadOnlyList<TextSpan> spans, Kind inverted)
    {
        var kinds = new Kind[length];
        var others = OthersOf(spans);
        int[]? bold = null, italic = null, under = null, nextScript = null, nextOther = null;
        for (var s = spans.Count - 1; s >= 0; s--)
        {
            var k = KindOf(spans[s].Look, others);
            int from = Math.Max(0, spans[s].Start), to = Math.Min(length, spans[s].End);
            if (k == Kind.None || from >= to) continue;
            if ((k & Kind.Bold) != 0) Count(ref bold, from, to);
            if ((k & Kind.Italic) != 0) Count(ref italic, from, to);
            if ((k & Kind.Underline) != 0) Count(ref under, from, to);
            // Latest span first: a character's script (other look) is the first one set; next[i] skips characters already set.
            if ((k & Scripts) != 0) Latest(ref nextScript, k & Scripts, from, to);
            if ((k & Others) != 0) Latest(ref nextOther, k & Others, from, to);
        }
        if (bold is null && italic is null && under is null && inverted == Kind.None) return kinds;
        int b = 0, it = 0, u = 0;
        for (var i = 0; i < length; i++)
        {
            if ((bold is not null && (b += bold[i]) > 0) != ((inverted & Kind.Bold) != 0)) kinds[i] |= Kind.Bold;
            if ((italic is not null && (it += italic[i]) > 0) != ((inverted & Kind.Italic) != 0)) kinds[i] |= Kind.Italic;
            if (under is not null && (u += under[i]) > 0) kinds[i] |= Kind.Underline;
        }
        return kinds;

        void Latest(ref int[]? next, Kind kind, int from, int to)
        {
            if (next is null)
            {
                next = new int[length + 1];
                for (var i = 0; i <= length; i++) next[i] = i;
            }
            for (var i = Unset(next, from); i < to; i = Unset(next, i))
            {
                kinds[i] |= kind;
                next[i] = i + 1;
            }
        }

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

    /// <summary>
    /// A reply with every tag taken out but ours of the looks <paramref name="sent"/> (the marked text) has; a model's own
    /// name for one of them ("&lt;bold&gt;", "&lt;strong&gt;", "&lt;em&gt;": a real model wrote them for &lt;b&gt; and &lt;i&gt;) read as ours.
    /// </summary>
    public static string WithoutOtherTags(string reply, string sent)
    {
        var had = Kind.None;
        foreach (Match m in AnyTag().Matches(sent))
            if (IsOurs(m.ValueSpan)) had |= KindNamed(m.ValueSpan[1..^1]);
        if ((had & Faces) != 0)
            reply = Synonym().Replace(reply, m =>
            {
                var bold = m.Groups["name"].Value.ToLowerInvariant() is "bold" or "strong" or "bf";
                return (had & (bold ? Kind.Bold : Kind.Italic)) == 0 ? m.Value : (m.Groups["close"].Length > 0 ? "</" : "<") + (bold ? "b" : "i") + ">";
            });
        return AnyTag().Replace(reply, m => IsOurs(m.ValueSpan) && (KindNamed(m.ValueSpan[1..^1]) & had) != 0 ? m.Value : Unwrapped(reply, m));
    }

    [GeneratedRegex(@"<(?<close>/)?(?<name>bold|strong|bf|em|italic)>", RegexOptions.IgnoreCase)]
    private static partial Regex Synonym();

    /// <summary>
    /// What a bracketed stretch of a reply that isn't kept as one of our tags leaves: nothing when it is shaped as a tag
    /// ("&lt;br/&gt;", "&lt;font color="#00F"&gt;", "&lt;bold&gt;"), its words when it isn't ("&lt;Décodage :&gt;",
    /// "&lt;Aidan N. Gomez&gt;": how a real model marked a label or a name it was sent in bold, which taking out as a tag lost).
    /// </summary>
    /// <remarks>Its words keep a space from a letter or digit right beside it ("Voir<Annexe A>," reads "Voir Annexe A,"), and none from anything else.</remarks>
    /// <param name="input">The text <paramref name="m"/> was found in.</param>
    internal static string Unwrapped(string input, Match m)
    {
        var bracketed = m.Value;
        if (bracketed.Length < 3 || bracketed[1] is '!' or '?') return "";
        // The usual tag, a name alone ("<b>", "</bold>"), without a regex: a crafted reply has hundreds of thousands.
        var name = bracketed.AsSpan(bracketed[1] == '/' ? 2 : 1, bracketed.Length - (bracketed[1] == '/' ? 3 : 2));
        if (name.Length > 0 && !name.ContainsAnyExcept(AsciiLettersAndDigits)) return "";
        if (TagShaped().IsMatch(bracketed)) return "";
        int before = m.Index - 1, after = m.Index + m.Length;
        var left = before >= 0 && char.IsLetterOrDigit(input[before]) ? " " : "";
        var right = after < input.Length && char.IsLetterOrDigit(input[after]) ? " " : "";
        return left + bracketed[1..^1].TrimStart('/').Trim() + right;
    }

    private static readonly System.Buffers.SearchValues<char> AsciiLettersAndDigits =
        System.Buffers.SearchValues.Create("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789");

    // A tag's shape: a name of ASCII letters and digits, then nothing or attributes with '=', an optional '/'.
    [GeneratedRegex(@"^</?[A-Za-z][A-Za-z0-9]*(?:\s+[A-Za-z_:][^<>=]*=[^<>]*)?\s*/?>$")]
    private static partial Regex TagShaped();
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
        var judged = Judge(answer, text, spans);
        if (judged.Plain is { } plain) return (plain, []);
        var (reply, kept, inverted) = (judged.Reply!, judged.Kept, judged.Inverted);
        // What each look was on the page: the family of its face, each other look's family and color; each script stretch's
        // size and rise, in order (a footnote mark and an exponent in one paragraph keep their own).
        var faces = new Dictionary<Kind, string>();
        var others = OthersOf(kept);
        var scripts = new Dictionary<Kind, List<(double? Size, double? Rise)>>();
        TextSpan? last = null;
        foreach (var s in kept.Where(s => s.Look.Script is not null).OrderBy(s => s.Start))
        {
            // One stretch however many runs drew it: a span right after one of the same look goes on it.
            if (last is not { } l || l.Look != s.Look || s.Start > l.End)
            {
                var k = KindOf(s.Look) & Scripts;
                if (!scripts.TryGetValue(k, out var list)) scripts[k] = list = [];
                list.Add((s.Look.Size, s.Look.Rise));
            }
            last = s;
        }
        foreach (var s in kept)
        {
            var k = KindOf(s.Look);
            if ((k & Faces) != 0 && s.Look.Font is { } f) faces.TryAdd(k & Faces, f);
        }
        var result = new List<TextSpan>();
        var kinds = reply.Kinds;
        var seen = new Dictionary<Kind, int>(); // script stretches of each kind met so far in the reply
        var previous = Kind.None;
        for (var i = 0; i < kinds.Length;)
        {
            var k = kinds[i];
            var j = i + 1;
            while (j < kinds.Length && kinds[j] == k) j++;
            var rel = k ^ inverted; // against the paragraph's own: in a bold paragraph, no <b> is a regular word
            var script = k & Scripts;
            if (script != Kind.None && (previous & script) == 0) seen[script] = seen.GetValueOrDefault(script) + 1;
            previous = k;
            if (rel != Kind.None)
            {
                // The reply's n-th stretch of a script takes the source's n-th (its last when the reply has more).
                var (size, rise) = scripts.TryGetValue(script, out var looks) ? looks[Math.Min(seen[script], looks.Count) - 1] : default;
                var at = Array.IndexOf(OtherKinds, rel & Others);
                (string? Font, int? Color)? mine = at >= 0 && at < others.Count ? others[at] : null;
                result.Add(new TextSpan(i, j - i, new TextLook(
                    Font: faces.GetValueOrDefault(rel & Faces) ?? mine?.Font,
                    Size: size,
                    Color: mine?.Color,
                    Bold: (rel & Kind.Bold) != 0 ? (inverted & Kind.Bold) == 0 : null,
                    Italic: (rel & Kind.Italic) != 0 ? (inverted & Kind.Italic) == 0 : null,
                    Script: (k & Kind.Sub) != 0 ? TextScript.Sub : (k & Kind.Super) != 0 ? TextScript.Super : null,
                    Rise: rise,
                    Underline: (rel & Kind.Underline) != 0 ? true : null)));
            }
            i = j;
        }
        return (reply.Text, result);
    }

    /// <summary>
    /// What <see cref="Read"/> makes of a reply, before its looks are rebuilt: the reply as plain text when its markup is
    /// not used (null when it is), the source's and the reply's markup read, the looks marked and which are inverted.
    /// </summary>
    private static (string? Plain, Parsed? Source, Parsed? Reply, List<TextSpan> Kept, Kind Inverted) Judge(string answer, string text, IReadOnlyList<TextSpan> spans)
    {
        if (!Markable(text)) return (answer, null, null, [], Kind.None);
        var (marked, kept) = Marking(text, spans);
        var inverted = Inverted(kept);
        var source = Parse(marked);
        if (answer.AsSpan().IndexOfAny('<', '>') < 0) return (answer, source, null, kept, inverted);
        if (source is null || Parse(answer) is not { } reply) return (Stripped(answer), source, null, kept, inverted);
        if (!Trusted(source, reply, inverted)) return (Stripped(answer), source, reply, kept, inverted);
        return (null, source, reply, kept, inverted);
    }

    /// <summary>
    /// For a real model's report (<c>TranslationRealModelTests</c>), judged as <see cref="Read"/> judges it: how many
    /// stretches the paragraph's markup had and the reply's has, and whether the reply's markup is used (null: it has no
    /// tags at all).
    /// </summary>
    internal static (int Sent, int Back, bool? Trusted) TagsKept(string answer, string text, IReadOnlyList<TextSpan> spans)
    {
        var judged = Judge(answer, text, spans);
        var had = judged.Source?.Stretches.Values.Sum(l => l.Count) ?? 0;
        if (!answer.Contains('<', StringComparison.Ordinal)) return (had, 0, null);
        return (had, judged.Reply?.Stretches.Values.Sum(l => l.Count) ?? 0, judged.Plain is null);
    }

    /// <summary>
    /// The tags marked text has, as a request names them ("&lt;b&gt; (bold) and &lt;sub&gt; (subscript)"), in one order; empty
    /// when it has none.
    /// </summary>
    public static string TagsNamed(string marked)
    {
        var had = Kind.None;
        foreach (Match m in TagNames().Matches(marked)) had |= KindNamed(m.Groups[1].ValueSpan);
        var parts = new List<string>();
        foreach (var (kind, _) in Names)
        {
            if ((had & kind) == 0) continue;
            if ((kind & Others) != 0)
            {
                // The other looks once, together, where the first of them nests.
                if (kind != OtherKinds.First(k => (had & k) != 0)) continue;
                var others = OtherKinds.Where(k => (had & k) != 0).Select(k => $"<{NameOf(k)}>").ToList();
                parts.Add(others.Count == 1 ? $"{others[0]} (another font or color)" : $"{string.Join(", ", others)} (each another font or color)");
                continue;
            }
            parts.Add(kind switch
            {
                Kind.Bold => "<b> (bold)",
                Kind.Italic => "<i> (italic)",
                Kind.Underline => "<u> (underlined)",
                Kind.Sub => "<sub> (subscript)",
                _ => "<sup> (superscript)",
            });
        }
        return parts.Count <= 1 ? string.Concat(parts) : string.Join(", ", parts.Take(parts.Count - 1)) + " and " + parts[^1];
    }

    /// <summary>
    /// The answers to a marked text's pieces (<see cref="Pieces"/>) joined into one, the tags a seam closed and opened
    /// again ("&lt;/b&gt; &lt;b&gt;") taken out, so a stretch cut by a seam is one stretch again.
    /// </summary>
    public static string Join(IEnumerable<string> parts) =>
        Seam().Replace(string.Join(' ', parts), m =>
        {
            var closed = TagNames().Matches(m.Groups["close"].Value).Select(t => t.Groups[1].Value.ToLowerInvariant()).Reverse();
            var opened = TagNames().Matches(m.Groups["open"].Value).Select(t => t.Groups[1].Value.ToLowerInvariant());
            return closed.SequenceEqual(opened) ? m.Groups["space"].Value : m.Value;
        });

    [GeneratedRegex(@"(?<close>(?:</(?:b|i|u|span|font|mark|sub|sup)>){1,5})(?<space>\s+)(?<open>(?:<(?:b|i|u|span|font|mark|sub|sup)>){1,5})", RegexOptions.IgnoreCase)]
    private static partial Regex Seam();

    [GeneratedRegex(@"</?(b|i|u|span|font|mark|sub|sup)>", RegexOptions.IgnoreCase)]
    private static partial Regex TagNames();

    /// <summary>Text read from markup: its characters (spaces collapsed, ends trimmed), each one's looks, and per look its stretches' lengths (not counting spaces).</summary>
    private sealed record Parsed(string Text, Kind[] Kinds, Dictionary<Kind, List<int>> Stretches, int Letters, Kind Opened);

    /// <summary>Whether '&lt;' followed by <paramref name="next"/> opens a tag ("&lt;b", "&lt;/", "&lt;!--"), not a bare bracket ("a &lt; b", "&lt;-").</summary>
    private static bool OpensTag(char next) => char.IsAsciiLetter(next) || next is '/' or '!' or '?';

    /// <summary>
    /// Markup read in one pass; null when it isn't well formed (another tag, one unclosed or crossed, a tag inside itself,
    /// sub and sup together, two other looks together, a piece of one of ours). A bare '&lt;' or '&gt;' ("-&gt;", "a &lt; b") is text.
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
                    if ((cur & kind) != 0 || stack.Count >= MaxDepth || (kind & Scripts) != 0 && (cur & Scripts) != 0 || (kind & Others) != 0 && (cur & Others) != 0) return null;
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
        var s = AnyTag().Replace(reply, m => Unwrapped(reply, m));
        s = TagPiece().Replace(s, "");
        s = TagOpening().Replace(s, "");
        return Collapsed(s);
    }

    [GeneratedRegex(@"</?[A-Za-z][^<>]{0,60}>|<[!?][^<>]{0,60}>")]
    private static partial Regex AnyTag();

    // What is left of one of ours cut short or garbled: "<b", "</sub", "< sup>", "/b>", "/SUB >", "sup>", " i>". A lone
    // letter's '>' counts only when it touches the letter and no number or '=' follows: "i > 0", "b >= a", "i>0" are text.
    [GeneratedRegex(@"<\s*/?\s*(?:b|i|u|span|font|mark|sub|sup)\b(?:\s*>)?|/\s*(?:b|i|u|span|font|mark|sub|sup)\s*>|(?<![\p{L}\p{N}])(?:b|i|u|span|font|mark|sub|sup)>(?![\p{N}=])", RegexOptions.IgnoreCase)]
    private static partial Regex TagPiece();

    // The end of one of ours whose '<' is gone ("negrita/b>", "x /sub>", "word i>"); a whole tag ("<b>", "</b>") isn't one,
    // nor a comparison ("i > 0", "b >= a", "i>0").
    [GeneratedRegex(@"(?<!<)/\s*(?:b|i|u|span|font|mark|sub|sup)\s*>|(?<![\p{L}\p{N}</])(?:b|i|u|span|font|mark|sub|sup)>(?![\p{N}=])", RegexOptions.IgnoreCase)]
    private static partial Regex BrokenEnd();

    // A '<' that opens a tag never closed ("<span", "</").
    [GeneratedRegex(@"<(?=[A-Za-z/!?])")]
    private static partial Regex TagOpening();
}
