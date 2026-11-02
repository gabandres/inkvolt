using System.Globalization;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>
/// The words a <see cref="FolderIndex"/> files a page under, and the words of a query, read the same way. A term is a run of
/// letters and digits folded so that everything Find treats as equal with case and accents ignored
/// (<see cref="CompareOptions.IgnoreCase"/> | <see cref="CompareOptions.IgnoreNonSpace"/>) comes out the same: "É", "é", "e"
/// and "ｅ" are all "e", "ﬁ" is "fi", "ß" is "ss" (<see cref="FindComparer"/> asks the comparer). It may fold more than Find does, never less: the index only proposes pages,
/// and Find's own comparison has the last word on the stored text. Scripts written without spaces (Chinese, Japanese, Thai…)
/// have no words to cut, so they are filed as overlapping pairs of characters. Changing what comes out here means bumping
/// <see cref="Version"/>: indexes are then built again.
/// </summary>
internal static class IndexTerms
{
    /// <summary>The folding's version, kept in the index file's header.</summary>
    public const int Version = 1;

    /// <summary>A longer run (a base64 blob, hostile text) is filed under its start; a query's long word is cut the same way.</summary>
    public const int MaxChars = 48;

    public delegate void TermAction(ReadOnlySpan<char> term);

    private const string Separator = " ";
    private static readonly string?[] Folded = new string?[0x10000];

    /// <summary>Calls <paramref name="emit"/> with each term of <paramref name="text"/>, in order, repeats included.</summary>
    public static void Read(ReadOnlySpan<char> text, TermAction emit)
    {
        Span<char> word = stackalloc char[MaxChars];
        Span<char> pair = stackalloc char[4];
        var length = 0;
        var full = false;
        var previous = -1;     // the last character of a run of spaceless script, or -1
        var paired = false;    // that run has given a pair already: a run of one is filed alone

        for (var i = 0; i < text.Length; i++)
        {
            int cp = text[i];
            if (char.IsHighSurrogate((char)cp) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
                cp = char.ConvertToUtf32((char)cp, text[++i]);
            else if (char.IsSurrogate((char)cp))
                cp = ' '; // half a pair, as a damaged PDF can give: nothing to file

            if (cp < 0x80)
            {
                // Most text is here: letters and digits as they are, the rest breaks words.
                if (cp is >= 'a' and <= 'z' or >= '0' and <= '9' or >= 'A' and <= 'Z')
                {
                    if (previous >= 0) EndRun(ref previous, ref paired, pair, emit);
                    if (length < MaxChars) word[length++] = (char)(cp is >= 'A' and <= 'Z' ? cp + 32 : cp);
                    else full = true;
                }
                else if (length > 0 || previous >= 0)
                {
                    EndWord(word, ref length, ref full, emit);
                    if (previous >= 0) EndRun(ref previous, ref paired, pair, emit);
                }
                continue;
            }

            var folded = FoldOf(cp);
            for (var f = 0; f < folded.Length; f++)
            {
                int c = folded[f];
                if (char.IsHighSurrogate((char)c) && f + 1 < folded.Length) c = char.ConvertToUtf32((char)c, folded[++f]);
                if (c == ' ')
                {
                    EndWord(word, ref length, ref full, emit);
                    if (previous >= 0) EndRun(ref previous, ref paired, pair, emit);
                }
                else if (IsSpaceless(c))
                {
                    EndWord(word, ref length, ref full, emit);
                    if (previous >= 0)
                    {
                        var used = new Rune(previous).EncodeToUtf16(pair);
                        used += new Rune(c).EncodeToUtf16(pair[used..]);
                        emit(pair[..used]);
                        paired = true;
                    }
                    previous = c;
                }
                else
                {
                    if (previous >= 0) EndRun(ref previous, ref paired, pair, emit);
                    var units = c > 0xFFFF ? 2 : 1;
                    if (!full && length + units <= MaxChars) length += new Rune(c).EncodeToUtf16(word[length..]);
                    else full = true;
                }
            }
        }
        EndWord(word, ref length, ref full, emit);
        if (previous >= 0) EndRun(ref previous, ref paired, pair, emit);
    }

    /// <summary>The terms of a query, in order, repeats included.</summary>
    public static List<string> Of(string query)
    {
        var terms = new List<string>();
        Read(query, t => terms.Add(t.ToString()));
        return terms;
    }

    private static void EndWord(Span<char> word, ref int length, ref bool full, TermAction emit)
    {
        if (length > 0) emit(word[..length]);
        length = 0;
        full = false;
    }

    private static void EndRun(ref int previous, ref bool paired, Span<char> pair, TermAction emit)
    {
        if (!paired) emit(pair[..new Rune(previous).EncodeToUtf16(pair)]);
        previous = -1;
        paired = false;
    }

    /// <summary>What a character files as: its folded letters, "" when it is ignored (accents, soft hyphens), a space when it breaks words.</summary>
    private static string FoldOf(int cp)
    {
        if (cp > 0xFFFF) return ByCategory(cp);
        return Folded[cp] ??= ByCategory(cp);
    }

    private static string ByCategory(int cp)
    {
        switch (CharUnicodeInfo.GetUnicodeCategory(cp))
        {
            case UnicodeCategory.NonSpacingMark:
            case UnicodeCategory.EnclosingMark:
            case UnicodeCategory.Format:
                return "";
            case UnicodeCategory.UppercaseLetter:
            case UnicodeCategory.LowercaseLetter:
            case UnicodeCategory.TitlecaseLetter:
            case UnicodeCategory.ModifierLetter:
            case UnicodeCategory.OtherLetter:
            case UnicodeCategory.SpacingCombiningMark:
            case UnicodeCategory.DecimalDigitNumber:
            case UnicodeCategory.LetterNumber:
            case UnicodeCategory.OtherNumber:
                if (cp is >= 0xAC00 and <= 0xD7A3) return char.ConvertFromUtf32(cp); // Korean has spaces, and its syllables stay whole
                return cp <= 0xFFFF && Comparer.Value.Map.TryGetValue((char)cp, out var same) ? same : Decomposed(cp);
            default:
                return Separator;
        }
    }

    /// <summary>The letter taken apart by Unicode, its marks left out, in lower case.</summary>
    private static string Decomposed(int cp)
    {
        var sb = new StringBuilder(4);
        foreach (var rune in char.ConvertFromUtf32(cp).Normalize(NormalizationForm.FormKD).EnumerateRunes())
        {
            switch (Rune.GetUnicodeCategory(rune))
            {
                case UnicodeCategory.NonSpacingMark:
                case UnicodeCategory.EnclosingMark:
                case UnicodeCategory.Format:
                    continue;
                case UnicodeCategory.UppercaseLetter:
                case UnicodeCategory.LowercaseLetter:
                case UnicodeCategory.TitlecaseLetter:
                case UnicodeCategory.ModifierLetter:
                case UnicodeCategory.OtherLetter:
                case UnicodeCategory.SpacingCombiningMark:
                case UnicodeCategory.DecimalDigitNumber:
                case UnicodeCategory.LetterNumber:
                case UnicodeCategory.OtherNumber:
                    sb.Append(Rune.ToLowerInvariant(rune).ToString());
                    continue;
                default:
                    sb.Append(' ');
                    continue;
            }
        }
        return sb.ToString();
    }

    /// <summary>Written without spaces between words, so filed as pairs of characters.</summary>
    private static bool IsSpaceless(int c) => c is
        >= 0x0E00 and <= 0x0EFF    // Thai, Lao
        or >= 0x1000 and <= 0x109F // Myanmar
        or >= 0x1780 and <= 0x17FF // Khmer
        or >= 0x3040 and <= 0x30FF // Hiragana, Katakana
        or >= 0x3400 and <= 0x4DBF or >= 0x4E00 and <= 0x9FFF or >= 0xF900 and <= 0xFAFF // CJK ideographs
        or >= 0x20000 and <= 0x3FFFF;

    /// <summary>
    /// What Find's comparer sees as the same letter, asked of the comparer itself: every letter of the Basic Multilingual Plane
    /// goes by its sort key with case and accents ignored. Letters with one key file as one (ø and o, ς and σ, the Hebrew final
    /// forms, small kana), a letter with the key of two Latin letters files as those (ß, æ, œ), a letter with an empty key is
    /// ignored as Find ignores it. About 30 ms, the first time a character outside ASCII comes along. Windows' collation data can
    /// change with an update: <see cref="Stamp"/> is kept in the index file, so an index built on other data is built again.
    /// </summary>
    private sealed class FindComparer
    {
        public Dictionary<char, string> Map { get; } = [];
        public uint Stamp { get; }

        public FindComparer()
        {
            var ci = CultureInfo.InvariantCulture.CompareInfo;
            const CompareOptions options = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace;
            var seen = new Dictionary<string, string>();
            for (var a = 'a'; a <= 'z'; a++)
                for (var b = 'a'; b <= 'z'; b++)
                {
                    var pair = new string([a, b]);
                    seen[Convert.ToHexString(ci.GetSortKey(pair, options).KeyData)] = pair;
                }
            var stamp = 2166136261u; // FNV-1a: the same on every run, unlike HashCode
            for (var cp = 0x30; cp < 0xFFFF; cp++)
            {
                if (cp is >= 0xD800 and <= 0xF8FF or >= 0xAC00 and <= 0xD7A3 or >= 0x3400 and <= 0x9FFF) continue; // surrogates, private use, Korean syllables and ideographs: each its own
                if (CharUnicodeInfo.GetUnicodeCategory(cp) is not (UnicodeCategory.UppercaseLetter or UnicodeCategory.LowercaseLetter or UnicodeCategory.TitlecaseLetter
                    or UnicodeCategory.ModifierLetter or UnicodeCategory.OtherLetter or UnicodeCategory.SpacingCombiningMark or UnicodeCategory.DecimalDigitNumber
                    or UnicodeCategory.LetterNumber or UnicodeCategory.OtherNumber))
                    continue;
                var c = (char)cp;
                var key = ci.GetSortKey(c.ToString(), options).KeyData;
                string text;
                if (key.Length == 0) text = "";
                else
                {
                    var hex = Convert.ToHexString(key);
                    if (!seen.TryGetValue(hex, out text!)) seen[hex] = text = Decomposed(cp);
                }
                Map[c] = text;
                foreach (var f in text) stamp = (stamp ^ f) * 16777619;
                stamp = (stamp ^ c) * 16777619;
            }
            Stamp = stamp;
        }
    }

    private static readonly Lazy<FindComparer> Comparer = new(() => new FindComparer());

    /// <summary>Says which folding wrote an index: <see cref="Version"/> and what Windows' collation data says today.</summary>
    public static long Stamp => ((long)Version << 32) | Comparer.Value.Stamp;
}
