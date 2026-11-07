using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>
/// A paragraph's looks as a translation request carries them (roadmap 3.1): its bold, italic, subscript and superscript
/// stretches as &lt;b&gt;, &lt;i&gt;, &lt;sub&gt; and &lt;sup&gt; tags in the text, and the reply's tags read back as looks. A model
/// drops, moves and invents tags: a reply whose markup can't be trusted comes back plain, with no tag left in its text.
/// </summary>
internal static partial class TranslationMarkup
{
    /// <summary>The most stretches a paragraph's markup has: more goes plain (a crafted page, or a paragraph a model would garble).</summary>
    internal const int MaxStretches = 64;

    /// <summary>The most tags read from a reply before it is given up on as plain.</summary>
    private const int MaxReplyTags = 4 * MaxStretches * 2 + 16;

    [Flags]
    private enum Kind : byte { None = 0, Bold = 1, Italic = 2, Sub = 4, Super = 8 }

    private const Kind Scripts = Kind.Sub | Kind.Super;

    private static readonly (Kind Kind, string Name)[] Names = [(Kind.Bold, "b"), (Kind.Italic, "i"), (Kind.Sub, "sub"), (Kind.Super, "sup")];

    private static Kind KindOf(TextLook? look) =>
        look is null ? Kind.None
            : (look.Bold == true ? Kind.Bold : 0) | (look.Italic == true ? Kind.Italic : 0)
            | (look.Script == TextScript.Sub ? Kind.Sub : look.Script == TextScript.Super ? Kind.Super : 0);

    /// <summary>Whether text can carry markup at all: angle brackets of its own would be read as tags.</summary>
    private static bool Markable(string text) => text.AsSpan().IndexOfAny('<', '>') < 0;

    /// <summary>
    /// <paramref name="text"/> with its looks as tags, nested in one order (bold, italic, then sub or sup); the text as it
    /// is when it has none, has angle brackets of its own, or more than <see cref="MaxStretches"/> stretches.
    /// </summary>
    public static string Mark(string text, IReadOnlyList<TextSpan> spans)
    {
        if (spans.Count == 0 || spans.Count > 4 * MaxStretches || !Markable(text)) return text;
        var kinds = KindsOf(text.Length, spans);
        var sb = new StringBuilder(text.Length + 32);
        var open = new List<Kind>(3);
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
                if (++stretches > MaxStretches) return text;
            }
            if (i < text.Length) sb.Append(text[i]);
        }
        return stretches == 0 ? text : sb.ToString();
    }

    /// <summary>
    /// Each character's looks: bold or italic where any span gives it; a later span's script replacing an earlier one's
    /// (as looks lay over each other), never sub and sup at once. Linear in the text and the spans, however they overlap
    /// (a crafted page's 256 spans over a paragraph of millions of characters).
    /// </summary>
    private static Kind[] KindsOf(int length, IReadOnlyList<TextSpan> spans)
    {
        var kinds = new Kind[length];
        int[]? bold = null, italic = null, next = null;
        for (var s = spans.Count - 1; s >= 0; s--)
        {
            var k = KindOf(spans[s].Look);
            int from = Math.Max(0, spans[s].Start), to = Math.Min(length, spans[s].End);
            if (k == Kind.None || from >= to) continue;
            if ((k & Kind.Bold) != 0) Count(ref bold, from, to);
            if ((k & Kind.Italic) != 0) Count(ref italic, from, to);
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
        if (bold is null && italic is null) return kinds;
        int b = 0, it = 0;
        for (var i = 0; i < length; i++)
        {
            if (bold is not null && (b += bold[i]) > 0) kinds[i] |= Kind.Bold;
            if (italic is not null && (it += italic[i]) > 0) kinds[i] |= Kind.Italic;
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
        var list = new List<Kind>(3);
        foreach (var (kind, _) in Names)
            if ((k & kind) != 0) list.Add(kind);
        return list;
    }

    private static string NameOf(Kind k) => Names.First(n => n.Kind == k).Name;

    /// <summary>The text of marked text with its tags taken out (what goes to a model when the markup can't go whole).</summary>
    public static string Plain(string marked) => Stripped(marked);

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

    /// <summary>A reply with every tag but ours taken out (for text sent with markup).</summary>
    public static string WithoutOtherTags(string reply) => AnyTag().Replace(reply, m => IsOurs(m.ValueSpan) ? m.Value : "");

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
    /// as the paragraph's longest of that look and a little more, at most twice its share of the text and a little more);
    /// a tag dropped only leaves its words plain. Otherwise the reply comes back plain, every tag and fragment of one taken
    /// out. Text with angle brackets of its own was sent as it is and comes back as it is. Linear in the reply's length.
    /// </summary>
    public static (string Text, List<TextSpan> Spans) Read(string answer, string text, IReadOnlyList<TextSpan> spans)
    {
        if (!Markable(text)) return (answer, []);
        if (answer.AsSpan().IndexOfAny('<', '>') < 0) return (answer, []);
        var marked = Mark(text, spans);
        if (Parse(marked) is not { } source || Parse(answer) is not { } reply || !Trusted(source, reply)) return (Stripped(answer), []);
        // Each combination of looks back as a look: the family the paragraph had it in, if any.
        var families = new Dictionary<Kind, string>();
        foreach (var s in spans)
            if (s.Look.Font is { } f) families.TryAdd(KindOf(s.Look) & (Kind.Bold | Kind.Italic), f);
        var result = new List<TextSpan>();
        var kinds = reply.Kinds;
        for (var i = 0; i < kinds.Length;)
        {
            var k = kinds[i];
            var j = i + 1;
            while (j < kinds.Length && kinds[j] == k) j++;
            if (k != Kind.None)
                result.Add(new TextSpan(i, j - i, new TextLook(
                    Font: families.GetValueOrDefault(k & (Kind.Bold | Kind.Italic)),
                    Bold: (k & Kind.Bold) != 0 ? true : null,
                    Italic: (k & Kind.Italic) != 0 ? true : null,
                    Script: (k & Kind.Sub) != 0 ? TextScript.Sub : (k & Kind.Super) != 0 ? TextScript.Super : null)));
            i = j;
        }
        return (reply.Text, result);
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
        var stack = new List<(Kind Kind, int Letters)>(3);
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
                    if ((cur & kind) != 0 || stack.Count >= 3 || (kind & Scripts) != 0 && (cur & Scripts) != 0) return null;
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
    private static bool Trusted(Parsed source, Parsed reply)
    {
        if ((reply.Opened & ~source.Opened) != 0) return false; // a look the paragraph didn't have, even around nothing
        foreach (var (kind, lengths) in reply.Stretches)
        {
            if (!source.Stretches.TryGetValue(kind, out var had)) return false; // a look the paragraph didn't have
            if (lengths.Count > 2 * had.Count + 1) return false;
            var script = kind is Kind.Sub or Kind.Super;
            if (lengths.Max() > 2 * had.Max() + (script ? 4 : 12)) return false;
            double share = (double)had.Sum() / Math.Max(1, source.Letters), now = (double)lengths.Sum() / Math.Max(1, reply.Letters);
            if (now > 2 * share + 0.1) return false;
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
    [GeneratedRegex(@"<\s*/?\s*(?:b|i|sub|sup)\b(?:\s*>)?|/\s*(?:b|i|sub|sup)\s*>|(?<![\p{L}\p{N}])(?:b|i|sub|sup)>(?![\p{N}=])", RegexOptions.IgnoreCase)]
    private static partial Regex TagPiece();

    // The end of one of ours whose '<' is gone ("negrita/b>", "x /sub>", "word i>"); a whole tag ("<b>", "</b>") isn't one,
    // nor a comparison ("i > 0", "b >= a", "i>0").
    [GeneratedRegex(@"(?<!<)/\s*(?:b|i|sub|sup)\s*>|(?<![\p{L}\p{N}</])(?:b|i|sub|sup)>(?![\p{N}=])", RegexOptions.IgnoreCase)]
    private static partial Regex BrokenEnd();

    // A '<' that opens a tag never closed ("<span", "</").
    [GeneratedRegex(@"<(?=[A-Za-z/!?])")]
    private static partial Regex TagOpening();
}
