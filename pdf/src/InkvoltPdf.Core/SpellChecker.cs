using System.Globalization;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Imaging;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// A spelling dictionary people can add words to: Windows' spell checker in the app (the user's own dictionary, which every
/// app using Windows' spell checker shares), a word list in tests.
/// </summary>
public interface ISpellingDictionary : ISpelling
{
    /// <summary>Adds a word to the user's dictionary; false when it couldn't be added.</summary>
    bool Add(string word);
}

/// <summary>A word of typed text the dictionary doesn't know, and where it starts in that text.</summary>
public readonly record struct Misspelling(int Start, string Word)
{
    public int End => Start + Word.Length;
}

/// <summary>
/// Spell check where people type (roadmap 4.1): what in a text is a word to look up, which of those the dictionary doesn't
/// know, and what a person can do about one (a suggestion, Ignore for the rest of the session, Add to dictionary). A word is
/// a run of letters, with an apostrophe inside it ("don't"); a hyphen joins two words that are each looked up. Left alone,
/// as Windows' spell checker leaves them: anything with a digit ("A4", "2nd"), single letters, words in capitals (an acronym),
/// and addresses (a web or e-mail address, a domain, a file path). The app's paragraph editor draws its own underlines from
/// <see cref="Check"/>; a plain text box gets WPF's, from the same Windows dictionary.
/// </summary>
public sealed partial class SpellChecker(ISpellingDictionary dictionary, bool skipAllCaps = true)
{
    /// <summary>Words looked up in one text at most: a pasted book doesn't hold up typing.</summary>
    public const int MaxWords = 2_000;

    /// <summary>A "word" longer than this is no word (a hash, a run of letters a crafted file holds): not looked up.</summary>
    public const int MaxWordLength = 48;

    /// <summary>Suggestions offered for a word at most.</summary>
    public const int MaxSuggestions = 5;

    /// <summary>Answers kept; more and they are forgotten (a long session's typing doesn't grow without end).</summary>
    private const int MaxKnown = 20_000;

    private readonly Dictionary<string, bool> _known = new(StringComparer.Ordinal);
    private readonly HashSet<string> _ignored = new(StringComparer.Ordinal);
    private readonly Lock _gate = new();

    public ISpellingDictionary Dictionary { get; } = dictionary;

    /// <summary>The dictionary's language ("en-US").</summary>
    public string Language => Dictionary.Language;

    /// <summary>The words of <paramref name="text"/> the dictionary doesn't know (and that weren't ignored or added), in order.</summary>
    public IReadOnlyList<Misspelling> Check(string text)
    {
        var found = new List<Misspelling>();
        foreach (var (start, length) in Words(text, skipAllCaps))
        {
            var word = text.Substring(start, length);
            if (!Knows(word)) found.Add(new Misspelling(start, word));
        }
        return found;
    }

    /// <summary>The misspelling at <paramref name="index"/> of the text (the caret just after a word counts), or null.</summary>
    public static Misspelling? At(IReadOnlyList<Misspelling> found, int index)
    {
        foreach (var m in found)
            if (index >= m.Start && index <= m.End) return m;
        return null;
    }

    /// <summary>The dictionary's suggestions for a word, best first, the word itself left out.</summary>
    public IReadOnlyList<string> Suggestions(string word)
    {
        if (word.Length is 0 or > MaxWordLength) return [];
        lock (_gate)
            return [.. Dictionary.Suggest(word).Where(s => s.Length > 0 && s != word).Distinct().Take(MaxSuggestions)];
    }

    /// <summary>Ignore: the word isn't underlined again anywhere for as long as this checker lives (the app's session).</summary>
    public void Ignore(string word)
    {
        lock (_gate) _ignored.Add(word);
    }

    /// <summary>Add to dictionary: the user's dictionary takes the word (then it is known everywhere); false when it couldn't.</summary>
    public bool Add(string word)
    {
        if (word.Length is 0 or > MaxWordLength) return false;
        lock (_gate)
        {
            if (!Dictionary.Add(word)) return false;
            _known[word] = true;
            return true;
        }
    }

    /// <summary>
    /// The text with <paramref name="m"/> replaced by <paramref name="replacement"/>; null when the text no longer has that word
    /// there (it was typed over since it was checked).
    /// </summary>
    public static string? Correct(string text, Misspelling m, string replacement) =>
        m.Start >= 0 && m.End <= text.Length && string.CompareOrdinal(text, m.Start, m.Word, 0, m.Word.Length) == 0
            ? string.Concat(text.AsSpan(0, m.Start), replacement, text.AsSpan(m.End))
            : null;

    private bool Knows(string word)
    {
        lock (_gate)
        {
            if (_ignored.Contains(word)) return true;
            if (_known.TryGetValue(word, out var known)) return known;
            if (_known.Count >= MaxKnown) _known.Clear();
            return _known[word] = Dictionary.IsKnown(word);
        }
    }

    // ---- What is looked up ----

    /// <summary>
    /// The words of <paramref name="text"/> to look up (start, length), at most <see cref="MaxWords"/>: see the class's
    /// summary for what is left alone. <paramref name="skipAllCaps"/>: words in capitals aren't looked up.
    /// </summary>
    public static IReadOnlyList<(int Start, int Length)> Words(string text, bool skipAllCaps = true)
    {
        var result = new List<(int, int)>();
        var i = 0;
        while (i < text.Length && result.Count < MaxWords)
        {
            // A chunk: the characters between white space.
            while (i < text.Length && char.IsWhiteSpace(text[i])) i++;
            var start = i;
            while (i < text.Length && !char.IsWhiteSpace(text[i])) i++;
            if (i == start) break;
            var chunk = text.AsSpan(start, i - start);
            if (IsAddress(chunk)) continue;
            foreach (var (s, l) in WordsIn(chunk))
            {
                if (!Checked(chunk.Slice(s, l), skipAllCaps)) continue;
                result.Add((start + s, l));
                if (result.Count >= MaxWords) break;
            }
        }
        return result;
    }

    /// <summary>The runs of letters (and digits, judged later) in a chunk, an apostrophe between two letters kept inside.</summary>
    private static List<(int Start, int Length)> WordsIn(ReadOnlySpan<char> chunk)
    {
        var result = new List<(int, int)>();
        var i = 0;
        while (i < chunk.Length)
        {
            if (!IsWordChar(chunk[i]))
            {
                i++;
                continue;
            }
            var start = i;
            while (i < chunk.Length && (IsWordChar(chunk[i]) || (IsApostrophe(chunk[i]) && i + 1 < chunk.Length && char.IsLetter(chunk[i + 1]) && i > start)))
                i++;
            result.Add((start, i - start));
        }
        return result;
    }

    private static bool IsWordChar(char c) =>
        char.IsLetterOrDigit(c) || CharUnicodeInfo.GetUnicodeCategory(c) is UnicodeCategory.NonSpacingMark or UnicodeCategory.SpacingCombiningMark;

    private static bool IsApostrophe(char c) => c is '\'' or '’';

    /// <summary>A word worth looking up: two letters or more, no digit, not too long, not in capitals when those are skipped.</summary>
    private static bool Checked(ReadOnlySpan<char> word, bool skipAllCaps)
    {
        if (word.Length < 2 || word.Length > MaxWordLength) return false;
        int letters = 0, upper = 0;
        foreach (var c in word)
        {
            if (char.IsDigit(c)) return false;
            if (!char.IsLetter(c)) continue;
            letters++;
            if (char.IsUpper(c)) upper++;
        }
        if (letters < 2) return false;
        return !(skipAllCaps && upper == letters);
    }

    /// <summary>A web or e-mail address, a domain ("example.com") or a file path: never a word to look up.</summary>
    private static bool IsAddress(ReadOnlySpan<char> chunk)
    {
        if (chunk.Contains("://", StringComparison.Ordinal) || chunk.StartsWith("www.", StringComparison.OrdinalIgnoreCase)) return true;
        if (chunk.IndexOfAny('\\', '/') >= 0) return true;
        var at = chunk.IndexOf('@');
        if (at > 0 && at < chunk.Length - 1) return true;
        return Domain().IsMatch(chunk);
    }

    [GeneratedRegex(@"^[(\[""'“‘]*[\p{L}\p{N}-]+(\.[\p{L}\p{N}-]+)*\.(com|org|net|edu|gov|io|info|biz|co|uk|us|es|mx|de|fr|it|pt|br|ar|cl|ca|eu|app|dev)[)\]""'”’.,;:!?]*$", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant)]
    private static partial Regex Domain();

    // ---- Which language ----

    /// <summary>
    /// The languages to try, in order, for text typed into a document: the document's own (its /Lang, when it names one),
    /// the interface's (in Windows' region when Windows speaks the same language: "es-MX", not "es"), Windows' display
    /// language, then US English. The first one Windows has a dictionary for is used; none, and nothing is checked.
    /// </summary>
    public static IReadOnlyList<string> Languages(string? document, string interfaceLanguage, string windows)
    {
        var result = new List<string>();
        void Add(string? tag)
        {
            if (Tag(tag) is { } t && !result.Contains(t, StringComparer.OrdinalIgnoreCase)) result.Add(t);
        }
        Add(document);
        var ui = Tag(interfaceLanguage)?.Split('-')[0];
        if (ui is not null && Tag(windows) is { } w && w.Split('-')[0] == ui) Add(w);
        else Add(ui switch { "en" => "en-US", "es" => "es-ES", _ => ui });
        Add(windows);
        Add("en-US");
        return result;
    }

    /// <summary>A language tag as BCP 47 writes it ("es-MX"), or null when <paramref name="tag"/> isn't one.</summary>
    internal static string? Tag(string? tag)
    {
        tag = tag?.Trim().Replace('_', '-');
        if (string.IsNullOrEmpty(tag) || tag.Length > 35 || !LanguageTag().IsMatch(tag)) return null;
        var parts = tag.Split('-');
        for (var i = 0; i < parts.Length; i++)
            parts[i] = i == 0 ? parts[i].ToLowerInvariant()
                : parts[i].Length == 2 ? parts[i].ToUpperInvariant()
                : parts[i].Length == 4 ? char.ToUpperInvariant(parts[i][0]) + parts[i][1..].ToLowerInvariant()
                : parts[i].ToLowerInvariant();
        return string.Join('-', parts);
    }

    [GeneratedRegex(@"^[A-Za-z]{2,3}(-[A-Za-z0-9]{1,8})*$", RegexOptions.CultureInvariant)]
    private static partial Regex LanguageTag();

    /// <summary>The language a document says its text is in (its catalog's /Lang), or null when it says none or can't be read.</summary>
    public static string? DocumentLanguage(byte[] data, string? password)
    {
        try
        {
            using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import);
            return Tag(PdfObj.Text(doc.Internals.Catalog.Elements["/Lang"]));
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return null; // a damaged or refused file: the interface's language instead
        }
    }
}
