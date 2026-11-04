using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>What redaction by pattern looks for: the built-in kinds, then the user's own phrases and expression.</summary>
public enum RedactionPattern
{
    /// <summary>123-45-6789, 123 45 6789 or 123456789; not area 000, 666 or 9xx, group 00 or serial 0000.</summary>
    SocialSecurity,

    /// <summary>North American numbers ((555) 201-3434, 555.201.3434, +1 555 201 3434) and international +CC numbers.</summary>
    Phone,

    Email,

    /// <summary>13 to 19 digits (in groups split by spaces or dashes) that pass the Luhn check, starting 2 to 6.</summary>
    PaymentCard,

    /// <summary>2026-10-27, 10/27/2026, 27.10.2026, October 27, 2026, 27 Oct 2026 (days checked against their month).</summary>
    Date,

    /// <summary>US ZIP codes (12345, 12345-6789): five digits alone match too much, so it is off unless chosen.</summary>
    ZipCode,

    /// <summary>International bank account numbers, with their check digits verified (mod 97).</summary>
    Iban,

    /// <summary>IPv4 (192.168.1.10) and IPv6 (2001:db8::1) addresses.</summary>
    IpAddress,

    /// <summary>One of the user's words or phrases.</summary>
    Phrase,

    /// <summary>The user's own regular expression.</summary>
    Expression,
}

/// <summary>What to look for, and on which pages.</summary>
public sealed record RedactionPatternOptions
{
    /// <summary>The built-in kinds to look for (<see cref="RedactionPattern.Phrase"/> and <see cref="RedactionPattern.Expression"/>
    /// come from <see cref="Phrases"/> and <see cref="Expression"/>).</summary>
    public IReadOnlySet<RedactionPattern> Patterns { get; init; } = RedactionPatterns.Defaults;

    /// <summary>Words or phrases found as they are written (whitespace in one matches any whitespace, line breaks too).</summary>
    public IReadOnlyList<string> Phrases { get; init; } = [];

    /// <summary>Phrases match whole words only.</summary>
    public bool WholeWord { get; init; } = true;

    /// <summary>Phrases and <see cref="Expression"/> tell capitals from small letters.</summary>
    public bool MatchCase { get; init; }

    /// <summary>A .NET regular expression, run on the page text with line breaks read as spaces (empty: none).</summary>
    public string? Expression { get; init; }

    /// <summary>The pages to search (0-based); null for all of them.</summary>
    public IReadOnlyList<int>? Pages { get; init; }

    /// <summary>The saved set these came from (<see cref="RedactionPatternSets"/>), when they came from one.</summary>
    public string? SetName { get; init; }

    /// <summary>Nothing to look for.</summary>
    public bool IsEmpty => !Patterns.Any(RedactionPatterns.BuiltIn.Contains) && !Phrases.Any(p => !string.IsNullOrWhiteSpace(p))
                           && string.IsNullOrEmpty(Expression);
}

/// <param name="Start">Where the match starts in the page's <see cref="PageText.Text"/>.</param>
/// <param name="End">Where it ends (exclusive).</param>
/// <param name="Rects">Its boxes on the page, one per line it covers (page space).</param>
public sealed record RedactionMatch(int Page, RedactionPattern Pattern, int Start, int End, string Text, IReadOnlyList<RectD> Rects)
{
    /// <summary>The match as the patterns read it: line breaks as spaces, hyphens at line ends gone, recognizer slips put right.</summary>
    public string Normalized { get; init; } = Text;

    /// <summary>The text just before the match, safe to show (<see cref="RedactionPatterns.Displayable"/>).</summary>
    public string Before { get; init; } = "";

    /// <summary>The text just after the match, safe to show.</summary>
    public string After { get; init; } = "";

    /// <summary>Found in what text recognition read on the page, not in the page's own text.</summary>
    public bool FromOcr { get; init; }
}

/// <summary>A document has more matches than can be reviewed. Nothing is applied: a partial list must not look complete.</summary>
public sealed class TooManyHitsException(int limit)
    : Exception(Loc.Format(PdfStrings.Redact_TooManyHits, limit));

/// <summary>
/// Redaction by pattern: finds Social Security numbers, phone numbers, email addresses, payment card numbers, dates,
/// ZIP codes, IBANs, IP addresses, the user's phrases and the user's regular expression in a document's text, page by
/// page, with each match's boxes ready for <see cref="Redaction.Apply"/>. The patterns run on the page text with line
/// breaks read as spaces, words hyphenated across a line ("exam-" / "ple") joined and a number split after a dash
/// ("555-" / "1234") kept whole, so a match may run onto the next line. Numbers with a check digit (cards, IBANs) count
/// only when it is right, and where two built-in kinds claim the same text the stronger one keeps it (a card number
/// isn't also a phone number). The user's phrases and expression are kept as found.
/// </summary>
public static class RedactionPatterns
{
    /// <summary>The built-in kinds in the order they are offered.</summary>
    public static IReadOnlyList<RedactionPattern> BuiltIn { get; } =
    [
        RedactionPattern.SocialSecurity, RedactionPattern.Phone, RedactionPattern.Email, RedactionPattern.PaymentCard,
        RedactionPattern.Date, RedactionPattern.Iban, RedactionPattern.IpAddress, RedactionPattern.ZipCode,
    ];

    /// <summary>Every built-in kind but ZIP codes.</summary>
    public static IReadOnlySet<RedactionPattern> Defaults { get; } = BuiltIn.Where(p => p != RedactionPattern.ZipCode).ToHashSet();

    /// <summary>How long the user's expression may take on one page before the search stops.</summary>
    public static readonly TimeSpan ExpressionTimeout = TimeSpan.FromSeconds(1);

    /// <summary>How long one page may take in all: each regex call has its own timeout, and a page can make very many calls.</summary>
    internal static TimeSpan PageBudget { get; set; } = TimeSpan.FromSeconds(10);

    /// <summary>Most matches in a document before the search stops (<see cref="TooManyHitsException"/>).</summary>
    public const int MaxHits = 100_000;

    /// <summary>The longest own pattern, the most phrases and the longest phrase: what a hand or a tampered file can give.</summary>
    public const int MaxExpressionLength = 2_000, MaxPhrases = 2_000, MaxPhraseLength = 500;

    public static string Name(RedactionPattern pattern) => pattern switch
    {
        RedactionPattern.SocialSecurity => PdfStrings.Redact_KindSsn,
        RedactionPattern.Phone => PdfStrings.Redact_KindPhone,
        RedactionPattern.Email => PdfStrings.Redact_KindEmail,
        RedactionPattern.PaymentCard => PdfStrings.Redact_KindCard,
        RedactionPattern.Date => PdfStrings.Redact_KindDate,
        RedactionPattern.ZipCode => PdfStrings.Redact_KindZip,
        RedactionPattern.Iban => PdfStrings.Redact_KindIban,
        RedactionPattern.IpAddress => PdfStrings.Redact_KindIp,
        RedactionPattern.Phrase => PdfStrings.Redact_KindPhrase,
        _ => PdfStrings.Redact_KindExpression,
    };

    /// <summary>What a kind looks like, for the dialog.</summary>
    public static string Example(RedactionPattern pattern) => pattern switch
    {
        RedactionPattern.SocialSecurity => "123-45-6789 or 123456789",
        RedactionPattern.Phone => "(555) 201-3434, +1 555 201 3434, +44 20 7946 0958",
        RedactionPattern.Email => "name@example.com",
        RedactionPattern.PaymentCard => PdfStrings.Redact_ExampleCard,
        RedactionPattern.Date => "2026-10-27, 10/27/2026, 27.10.2026, October 27, 2026, 27 Oct 2026",
        RedactionPattern.ZipCode => PdfStrings.Redact_ExampleZip,
        RedactionPattern.Iban => PdfStrings.Redact_ExampleIban,
        RedactionPattern.IpAddress => "192.168.1.10, 2001:db8::1",
        _ => "",
    };

    /// <summary>What is wrong with a user's expression, in plain words; null when it is fine (or empty).</summary>
    public static string? ValidateExpression(string? expression)
    {
        if (string.IsNullOrEmpty(expression)) return null;
        if (expression.Length > MaxExpressionLength) return Loc.Format(PdfStrings.Redact_PatternTooLong, MaxExpressionLength);
        try
        {
            var regex = new Regex(expression, RegexOptions.CultureInvariant, ExpressionTimeout);
            try
            {
                if (regex.IsMatch("")) return PdfStrings.Redact_PatternMatchesEmpty;
            }
            catch (RegexMatchTimeoutException)
            {
                return PdfStrings.Redact_PatternSlow;
            }
            return null;
        }
        catch (RegexParseException ex)
        {
            // .NET's message starts "Invalid pattern '…' at offset N. "; keep what follows.
            var reason = ex.Message;
            var dot = reason.IndexOf(". ", StringComparison.Ordinal);
            if (dot >= 0) reason = reason[(dot + 2)..];
            return Loc.Format(PdfStrings.Redact_PatternMistake, ex.Offset, reason);
        }
        catch (ArgumentException ex)
        {
            return Loc.Format(PdfStrings.Redact_PatternInvalid, ex.Message);
        }
    }

    /// <summary>What is wrong with a whole set of choices (from the dialog, a saved set or a preset), in plain words; null when fine.</summary>
    public static string? Validate(RedactionPatternOptions options)
    {
        if (options.Phrases.Count > MaxPhrases) return Loc.Format(PdfStrings.Redact_TooManyPhrases, MaxPhrases);
        if (options.Phrases.Any(p => p.Length > MaxPhraseLength)) return Loc.Format(PdfStrings.Redact_PhraseTooLong, MaxPhraseLength);
        return ValidateExpression(options.Expression);
    }

    /// <summary>
    /// Text that came from a file, made safe to show: control and invisible format characters (bidirectional overrides that
    /// would make it read differently) gone, whitespace as single spaces, at most <paramref name="max"/> characters.
    /// </summary>
    public static string Displayable(string text, int max = 120)
    {
        var sb = new StringBuilder(Math.Min(text.Length, max + 1));
        foreach (var c in text.Length > max * 8 ? text.AsSpan(0, max * 8) : text.AsSpan())
        {
            if (sb.Length > max) break;
            if (char.IsWhiteSpace(c))
            {
                if (sb.Length > 0 && sb[^1] != ' ') sb.Append(' ');
                continue;
            }
            var kind = char.GetUnicodeCategory(c);
            if (kind is UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.OtherNotAssigned or UnicodeCategory.PrivateUse) continue;
            sb.Append(c);
        }
        if (sb.Length <= max) return sb.ToString();
        sb.Length = max;
        if (char.IsHighSurrogate(sb[^1])) sb.Length--;
        return sb.Append('…').ToString();
    }

    /// <summary>The matches on one page, in reading order.</summary>
    /// <exception cref="ArgumentException">The expression isn't valid (see <see cref="ValidateExpression"/>).</exception>
    /// <exception cref="TimeoutException">The expression took longer than <see cref="ExpressionTimeout"/>.</exception>
    public static List<RedactionMatch> Find(PageText text, int page, RedactionPatternOptions options) =>
        FindOnPage(text, page, options, Compile(options));

    /// <summary>The values the patterns find in text that isn't on a page (a comment, a property), as the patterns read them.</summary>
    internal static List<string> FindValues(string text, RedactionPatternOptions options, Regex? custom)
    {
        var box = new RectD(0, 0, 1, 1);
        var lines = text.Split('\n').Select(l => l.Select(c => (c.ToString(), box)).ToList()).ToList();
        return [.. FindOnPage(new PageText(lines), 0, options, custom).Select(m => m.Normalized)];
    }

    /// <summary>The matches on the chosen pages (all of them when none are chosen), page by page.</summary>
    /// <param name="progress">(pages done, pages to search).</param>
    /// <exception cref="ArgumentException">The expression isn't valid (see <see cref="ValidateExpression"/>).</exception>
    /// <exception cref="TimeoutException">The expression took longer than <see cref="ExpressionTimeout"/> on a page.</exception>
    public static List<RedactionMatch> Find(PdfEngine engine, RedactionPatternOptions options, IProgress<(int Done, int Total)>? progress = null,
        CancellationToken cancel = default)
    {
        var custom = Compile(options);
        var pages = (options.Pages ?? Enumerable.Range(0, engine.PageCount).ToArray()).Where(p => p >= 0 && p < engine.PageCount).Distinct().Order().ToList();
        var matches = new List<RedactionMatch>();
        for (var i = 0; i < pages.Count; i++)
        {
            cancel.ThrowIfCancellationRequested();
            // Cached only for a few pages: a long document would push the pages the viewer shows out of the engine's text cache.
            matches.AddRange(FindOnPage(engine.GetText(pages[i], cache: pages.Count <= 8, cancel), pages[i], options, custom));
            if (matches.Count > MaxHits) throw new TooManyHitsException(MaxHits);
            progress?.Report((i + 1, pages.Count));
        }
        return matches;
    }

    /// <summary>The areas to black out per page: each match's boxes, grown by half a point so no edge of a glyph survives.</summary>
    public static Dictionary<int, IReadOnlyList<RectD>> Areas(IEnumerable<RedactionMatch> matches) =>
        matches.GroupBy(m => m.Page).ToDictionary(g => g.Key, g => (IReadOnlyList<RectD>)[.. g.SelectMany(m => m.Rects).Select(r => r.Inflate(0.5)).Distinct()]);

    /// <summary>Finds the matches and redacts them for good (<see cref="Redaction.Apply"/>); the data as it was when nothing matched.</summary>
    public static (byte[] Data, IReadOnlyList<RedactionMatch> Matches) Redact(byte[] data, string? password, RedactionPatternOptions options,
        CancellationToken cancel = default)
    {
        List<RedactionMatch> matches;
        using (var engine = PdfEngine.Open(data, InputFileTypes.PDF, password))
            matches = Find(engine, options, null, cancel);
        cancel.ThrowIfCancellationRequested();
        return matches.Count == 0 ? (data, matches) : (Redaction.Apply(data, password, Areas(matches)), matches);
    }

    /// <summary>How many matches of each kind, in the order the kinds are offered (kinds without matches left out).</summary>
    public static List<(RedactionPattern Pattern, int Count)> Counts(IEnumerable<RedactionMatch> matches)
    {
        var counts = matches.GroupBy(m => m.Pattern).ToDictionary(g => g.Key, g => g.Count());
        return [.. BuiltIn.Append(RedactionPattern.Phrase).Append(RedactionPattern.Expression)
            .Where(counts.ContainsKey).Select(p => (p, counts[p]))];
    }

    /// <summary>"Email addresses: 3, Dates: 2".</summary>
    public static string Summary(IEnumerable<RedactionMatch> matches) =>
        string.Join(", ", Counts(matches).Select(c => $"{Name(c.Pattern)}: {c.Count}"));

    // ───────────────────────────── finding ─────────────────────────────

    internal static Regex? Compile(RedactionPatternOptions options)
    {
        if (Validate(options) is { } error) throw new ArgumentException(error, nameof(options));
        if (string.IsNullOrEmpty(options.Expression)) return null;
        return new Regex(options.Expression, RegexOptions.CultureInvariant | (options.MatchCase ? RegexOptions.None : RegexOptions.IgnoreCase), ExpressionTimeout);
    }

    /// <param name="lenient">The text came from a recognizer: read slips kindly (<see cref="LenientView"/>), and a number of the
    /// right length counts even when its check digit fails, since one misread digit would otherwise hide it.</param>
    internal static List<RedactionMatch> FindOnPage(PageText text, int page, RedactionPatternOptions options, Regex? custom, bool lenient = false)
    {
        var found = new List<RedactionMatch>();
        if (text.IsEmpty) return found;
        var (plain, plainMap) = View(text.Text);
        // The kinds read a recognizer's text kindly; the person's own pattern reads what was read ("CASE-12" isn't "CA5E-12").
        var (view, map) = lenient ? LenientView(plain, plainMap) : (plain, plainMap);
        var clock = Stopwatch.StartNew();
        void Spend()
        {
            if (clock.Elapsed > PageBudget) throw new TimeoutException(Loc.Format(PdfStrings.Redact_PageTooSlow, page + 1));
        }

        void Add(RedactionPattern pattern, int start, int end, string? readIn, int[]? readMap)
        {
            if (end <= start) return;
            var normalized = readIn is not null ? readIn[start..end] : View(text.Text[start..end]).View.Trim();
            if (readMap is not null) (start, end) = (readMap[start], readMap[end - 1] + 1);
            var rects = text.GetRects(start, end).Where(r => !r.IsEmpty).ToList();
            // Text without a box of its own (glyphs of no size) is still text in the file: its page has to go too.
            if (rects.Count == 0) rects.Add(new RectD(text.BoxAt(start).X, text.BoxAt(start).Y, 1, 1));
            var after = Math.Min(text.Text.Length, end + ContextChars);
            found.Add(new RedactionMatch(page, pattern, start, end, text.Text[start..end], rects)
            {
                Normalized = normalized,
                Before = Displayable(text.Text[Math.Max(0, start - ContextChars)..start], ContextChars),
                After = (end < after && char.IsWhiteSpace(text.Text[end]) ? " " : "") + Displayable(text.Text[end..after], ContextChars),
            });
            if (found.Count > MaxHits) throw new TooManyHitsException(MaxHits);
        }

        // Built-in kinds: every rule's matches, then where two kinds overlap the stronger (earlier in Strength) keeps the text.
        var builtIn = new List<(RedactionPattern Pattern, int Start, int End)>();
        foreach (var rule in Rules.Where(r => options.Patterns.Contains(r.Pattern)))
        {
            try
            {
                for (var m = rule.Regex.Match(view); m.Success;)
                {
                    var end = Accept(rule, m, view, lenient);
                    if (end is { } e) builtIn.Add((rule.Pattern, m.Index, e));
                    if (builtIn.Count > MaxHits * 4) throw new TooManyHitsException(MaxHits);
                    // What a check cut off or refused may hold the next number ("2026 4111 1111 1111 1111"): look again from
                    // where the number that counted ends, or after the first group of one that didn't.
                    var next = !rule.Trim || end == m.Index + m.Length ? -1 : end ?? view.IndexOfAny([' ', '-'], m.Index, m.Length);
                    m = next > m.Index ? rule.Regex.Match(view, next) : m.NextMatch();
                    Spend();
                }
            }
            catch (RegexMatchTimeoutException ex)
            {
                throw new TimeoutException(Loc.Format(PdfStrings.Redact_KindTooSlow, Name(rule.Pattern).ToLowerInvariant(), page + 1), ex);
            }
            Spend();
        }
        // Each character at most once: a page of hostile text can hold hundreds of thousands of matches.
        var taken = new bool[view.Length];
        foreach (var m in builtIn.OrderBy(m => Array.IndexOf(Strength, m.Pattern)).ThenByDescending(m => m.End - m.Start))
        {
            if (taken.AsSpan(m.Start, m.End - m.Start).Contains(true)) continue;
            taken.AsSpan(m.Start, m.End - m.Start).Fill(true);
            Add(m.Pattern, m.Start, m.End, view, map);
        }

        // The user's phrases go through the page search (whole words, case, hyphenation, whitespace as it does).
        foreach (var phrase in options.Phrases.Select(p => p.Trim()).Where(p => p.Length > 0).Distinct(options.MatchCase ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase))
        {
            foreach (var (start, end) in text.Find(phrase, options.MatchCase, options.WholeWord))
                Add(RedactionPattern.Phrase, start, end, null, null);
            Spend();
        }

        if (custom is not null)
        {
            try
            {
                for (var m = custom.Match(plain); m.Success; m = m.NextMatch())
                {
                    if (m.Length > 0) Add(RedactionPattern.Expression, m.Index, m.Index + m.Length, plain, plainMap);
                    Spend();
                }
            }
            catch (RegexMatchTimeoutException ex)
            {
                throw new TimeoutException(Loc.Format(PdfStrings.Redact_ExpressionTooSlow, page + 1), ex);
            }
        }
        found.Sort((a, b) => a.Start != b.Start ? a.Start.CompareTo(b.Start) : a.End.CompareTo(b.End));
        return found;
    }

    private const int ContextChars = 48;

    /// <summary>
    /// The page text as the patterns read it, with each character's index in the text: whitespace (line breaks too) as a
    /// space, dashes as '-', soft hyphens and other invisible characters dropped, wide forms as plain ones ("１２３" as "123"),
    /// a hyphen at a line break between letters dropped with the break (one word) and one between digits kept without the
    /// break (one number), as is one that starts the next line.
    /// </summary>
    private static (string View, int[] Map) View(string text)
    {
        var sb = new StringBuilder(text.Length);
        var map = new List<int>(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c == '­')
            {
                if (i + 1 < text.Length && text[i + 1] == '\n') i++;
                continue;
            }
            if (char.GetUnicodeCategory(c) == UnicodeCategory.Format) continue;
            if (c == '\n' && i > 0 && i + 2 < text.Length && char.IsAsciiDigit(text[i - 1]) && IsDash(text[i + 1]) && char.IsAsciiDigit(text[i + 2])) continue;
            if (c is >= '！' and <= '～' && !IsDash(c)) c = (char)(c - 0xFEE0);
            if (IsDash(c) && i > 0 && i + 2 < text.Length && text[i + 1] == '\n')
            {
                if (char.IsLetter(text[i - 1]) && char.IsLetter(text[i + 2]))
                {
                    i++;
                    continue;
                }
                // Between digits (a number), or a letter and a digit (CASE-0412): the hyphen stays, the break goes.
                if (char.IsLetterOrDigit(text[i - 1]) && char.IsLetterOrDigit(text[i + 2]))
                {
                    sb.Append('-');
                    map.Add(i++);
                    continue;
                }
            }
            sb.Append(char.IsWhiteSpace(c) ? ' ' : IsDash(c) ? '-' : c);
            map.Add(i);
        }
        return (sb.ToString(), [.. map]);
    }

    /// <summary>
    /// The view for text a recognizer read: in a word of digits and letters recognizers take for digits, those letters become
    /// the digits ("l23-45-6789", "4111 1lll 1111 1111"), and spaces it put around a dash, slash or at sign go.
    /// </summary>
    private static (string View, int[] Map) LenientView(string view, int[] map)
    {
        var chars = view.ToCharArray();
        for (var start = 0; start < chars.Length;)
        {
            if (chars[start] == ' ')
            {
                start++;
                continue;
            }
            var end = start;
            while (end < chars.Length && chars[end] != ' ') end++;
            var (digits, others) = (0, 0);
            for (var i = start; i < end; i++)
            {
                if (char.IsAsciiDigit(chars[i])) digits++;
                else if (char.IsLetter(chars[i]) && chars[i] is not ('O' or 'o' or 'l' or 'I' or 'S' or 's' or 'B' or 'Z' or 'z')) others++;
                else if (chars[i] == '@') others++;
            }
            if (digits >= 1 && others == 0)
                for (var i = start; i < end; i++)
                    chars[i] = chars[i] switch
                    {
                        'O' or 'o' => '0',
                        'l' or 'I' or '|' or '!' => '1',
                        'S' or 's' => '5',
                        'B' => '8',
                        'Z' or 'z' => '2',
                        var c => c,
                    };
            start = end;
        }
        var sb = new StringBuilder(chars.Length);
        var kept = new List<int>(chars.Length);
        for (var i = 0; i < chars.Length; i++)
        {
            if (chars[i] == ' ' && sb.Length > 0)
            {
                var next = i + 1;
                while (next < chars.Length && chars[next] == ' ') next++;
                if (next < chars.Length && Joins(sb[^1], chars[next], next + 1 < chars.Length ? chars[next + 1] : ' ')) continue;
            }
            sb.Append(chars[i]);
            kept.Add(map[i]);
        }
        return (sb.ToString(), [.. kept]);

        static bool Joins(char before, char after, char afterThat) =>
            before == '@' || after == '@'
            || (char.IsAsciiDigit(before) && after is '-' or '/' && (char.IsAsciiDigit(afterThat) || afterThat == ' '))
            || (before is '-' or '/' && char.IsAsciiDigit(after));
    }

    private static bool IsDash(char c) => c is '-' or (>= '‐' and <= '―') or '−' or '﹣' or '－';

    /// <summary>Where a rule's match ends once checked (a card or IBAN may lose groups that came after it), or null.</summary>
    private static int? Accept(Rule rule, Match m, string view, bool lenient)
    {
        var start = m.Index;
        var end = m.Index + m.Length;
        while (true)
        {
            var value = view[start..end];
            if (rule.Valid(m, value) || lenient && rule.Relaxed?.Invoke(value) == true) return end;
            if (!rule.Trim) return null;
            var cut = view.LastIndexOfAny([' ', '-'], end - 1, end - start);
            if (cut <= start) return null;
            end = cut;
        }
    }

    // ───────────────────────────── the patterns ─────────────────────────────

    /// <param name="Trim">On a failed check, try again without the last group (a year or code printed after the number).</param>
    /// <param name="Relaxed">What counts on a recognized page, where one misread digit must not hide a number: no check digit.</param>
    private sealed record Rule(RedactionPattern Pattern, Regex Regex, Func<Match, string, bool> Valid, bool Trim = false, Func<string, bool>? Relaxed = null);

    /// <summary>Which kind keeps text two kinds claim: checked numbers first, the loosest last.</summary>
    private static readonly RedactionPattern[] Strength =
    [
        RedactionPattern.PaymentCard, RedactionPattern.Iban, RedactionPattern.SocialSecurity, RedactionPattern.Email,
        RedactionPattern.IpAddress, RedactionPattern.Phone, RedactionPattern.Date, RedactionPattern.ZipCode,
    ];

    // A number starts where no letter, digit or '@' comes before it, nor a digit and a dot or dash (it would be the tail
    // of a longer number), and ends the same way. A comma or slash between numbers is a list ("123-45-6789,987-65-4321",
    // a printed CSV), or a network's size after an address (10.0.0.1/24).
    private const string Lead = @"(?<![\w@])(?<![0-9][.-])";
    private const string Trail = @"(?![\w@])(?![.-][0-9])";

    // A date with numbers for its month ends only at a digit after its own separator: another separator between two dates
    // is a list or a range ("01/01/2025-12/31/2025").
    private const string DateLead = @"(?<![\w@])(?:(?=[0-9]{1,4}-)(?<![0-9]-)|(?=[0-9]{1,4}/)(?<![0-9]/)|(?=[0-9]{1,4}\.)(?<![0-9]\.))";
    private const string DateTrail = @"(?![\w@])(?!\k<s>[0-9])";
    private const string Months = "jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?";
    private const string Octet = "(?:25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])";

    private static Regex R(string pattern, RegexOptions extra = RegexOptions.None) =>
        new(pattern, RegexOptions.CultureInvariant | RegexOptions.Compiled | RegexOptions.ExplicitCapture | extra, TimeSpan.FromSeconds(2));

    private static readonly Rule[] Rules =
    [
        new(RedactionPattern.SocialSecurity, R(Lead + @"(?<a>[0-9]{3})(?<s>[- ]?)(?<g>[0-9]{2})\k<s>(?<n>[0-9]{4})" + Trail),
            (m, _) => m.Groups["a"].Value is not ("000" or "666") && m.Groups["a"].Value[0] != '9' && m.Groups["g"].Value != "00" && m.Groups["n"].Value != "0000"),

        // North American: an optional +1, area code (in parentheses or not), exchange and line, or +1 and ten digits run together.
        new(RedactionPattern.Phone, R(Lead + @"(?:(?:\+?1[-. ]?)?(?:\([2-9][0-9]{2}\)[-. ]?|[2-9][0-9]{2}[-. ])[2-9][0-9]{2}[-. ][0-9]{4}|\+1[-. ]?[2-9][0-9]{2}[2-9][0-9]{6})" + Trail),
            (_, _) => true),
        // International: + and a country code (not 1), then groups, maybe a trunk (0); 8 to 15 digits in all (E.164).
        new(RedactionPattern.Phone, R(Lead + @"\+[2-9][0-9]{0,2}(?:[-. ]?\(0\))?(?:[-. ]?\(?[0-9]{1,5}\)?){2,6}" + Trail),
            (_, value) => Digits(value.Replace("(0)", "")).Length is >= 8 and <= 15),

        new(RedactionPattern.Email, R(@"(?<![\w.%+-])[\p{L}\p{N}._%+-]+@(?:[\p{L}\p{N}](?:[\p{L}\p{N}-]{0,61}[\p{L}\p{N}])?\.)+\p{L}{2,24}(?![\w-])"),
            (_, value) => value[0] != '.' && !value.Contains("..") && !value.Contains(".@")),

        // 13 to 19 digits run together, or in groups (4-4-4-4, 4-6-5, ...) split by spaces or dashes, all the same.
        new(RedactionPattern.PaymentCard, R(Lead + @"[2-6](?:[0-9]{12,18}|[0-9]{3}(?:[ -][0-9]{2,7}){2,4})" + Trail),
            (_, value) => value.Where(c => c is ' ' or '-').Distinct().Count() <= 1 && Digits(value) is { Length: >= 13 and <= 19 } d && Luhn(d),
            Trim: true, Relaxed: value => Digits(value).Length is 15 or 16),

        new(RedactionPattern.Date, R(DateLead + @"(?<y>(?:1[89]|2[0-9])[0-9]{2})(?<s>[-/.])(?<m>0?[1-9]|1[0-2])\k<s>(?<d>0?[1-9]|[12][0-9]|3[01])" + DateTrail),
            (m, _) => IsDay(Int(m, "y"), Int(m, "m"), Int(m, "d"))),
        // 10/27/2026 or 27.10.2026: month first or day first, whichever makes a date; two-digit years only with slashes.
        new(RedactionPattern.Date, R(DateLead + @"(?<a>[0-9]{1,2})(?<s>[-/.])(?<b>[0-9]{1,2})\k<s>(?<y>[0-9]{4}|[0-9]{2})" + DateTrail),
            (m, _) =>
            {
                var y = Int(m, "y");
                if (m.Groups["y"].Length == 2) y = m.Groups["s"].Value == "/" ? 2000 + y : -1;
                if (y is < 1800 or > 2199) return false;
                var (a, b) = (Int(m, "a"), Int(m, "b"));
                return IsDay(y, a, b) || IsDay(y, b, a);
            }),
        new(RedactionPattern.Date, R(@"(?<![\w])(?<mon>" + Months + @")\.? +(?<d>[0-9]{1,2})(?:st|nd|rd|th)?,? +(?<y>[0-9]{4})(?![\w])", RegexOptions.IgnoreCase),
            (m, _) => IsDay(Int(m, "y"), Month(m), Int(m, "d"))),
        new(RedactionPattern.Date, R(@"(?<![\w])(?<d>[0-9]{1,2})(?:st|nd|rd|th)? +(?:of +)?(?<mon>" + Months + @")\.?,? +(?<y>[0-9]{4})(?![\w])", RegexOptions.IgnoreCase),
            (m, _) => IsDay(Int(m, "y"), Month(m), Int(m, "d"))),

        new(RedactionPattern.ZipCode, R(Lead + @"[0-9]{5}(?:-[0-9]{4})?" + Trail), (_, value) => !value.StartsWith("00000", StringComparison.Ordinal)),

        // Two letters, two check digits, then up to 30 letters and digits, printed in groups of four or run together.
        new(RedactionPattern.Iban, R(@"(?<![\w])[A-Z]{2}[0-9]{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?(?![\w])"),
            (_, value) => IbanValid(value.Replace(" ", "")), Trim: true, Relaxed: value => value.Replace(" ", "").Length is >= 15 and <= 34),

        new(RedactionPattern.IpAddress, R(Lead + $@"(?:{Octet}\.){{3}}{Octet}" + Trail), (_, _) => true),
        // IPv6: hex groups and colons; written in full (eight groups) or shortened with "::".
        new(RedactionPattern.IpAddress, R(@"(?<![\w:])(?:[0-9A-Fa-f]{0,4}:){2,7}[0-9A-Fa-f]{0,4}(?![\w:])"),
            (_, value) => (value.Contains("::") || value.Count(c => c == ':') == 7) && value.Any(char.IsAsciiHexDigit)
                          && IPAddress.TryParse(value, out var ip) && ip.AddressFamily == AddressFamily.InterNetworkV6),
    ];

    private static string Digits(string value) => string.Concat(value.Where(char.IsAsciiDigit));

    private static int Int(Match m, string group) => int.Parse(m.Groups[group].Value, CultureInfo.InvariantCulture);

    private static readonly string[] MonthStarts = ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"];

    private static int Month(Match m) => Array.FindIndex(MonthStarts, p => m.Groups["mon"].Value.StartsWith(p, StringComparison.OrdinalIgnoreCase)) + 1;

    private static bool IsDay(int year, int month, int day) =>
        year is >= 1 and <= 9999 && month is >= 1 and <= 12 && day >= 1 && day <= DateTime.DaysInMonth(year, month);

    /// <summary>The Luhn check digit of payment card numbers.</summary>
    internal static bool Luhn(string digits)
    {
        var sum = 0;
        for (var i = 0; i < digits.Length; i++)
        {
            var d = digits[digits.Length - 1 - i] - '0';
            if (i % 2 == 1 && (d *= 2) > 9) d -= 9;
            sum += d;
        }
        return sum % 10 == 0;
    }

    /// <summary>ISO 13616: 15 to 34 characters, the first four moved to the end and letters as 10 to 35 leave 1 mod 97.</summary>
    internal static bool IbanValid(string iban)
    {
        if (iban.Length is < 15 or > 34) return false;
        var rest = 0;
        foreach (var c in iban[4..] + iban[..4])
        {
            if (char.IsAsciiDigit(c)) rest = (rest * 10 + (c - '0')) % 97;
            else if (char.IsAsciiLetterUpper(c)) rest = (rest * 100 + (c - 'A' + 10)) % 97;
            else return false;
        }
        return rest == 1;
    }
}
