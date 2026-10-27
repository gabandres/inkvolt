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

    /// <summary>Nothing to look for.</summary>
    public bool IsEmpty => !Patterns.Any(RedactionPatterns.BuiltIn.Contains) && !Phrases.Any(p => !string.IsNullOrWhiteSpace(p))
                           && string.IsNullOrEmpty(Expression);
}

/// <param name="Start">Where the match starts in the page's <see cref="PageText.Text"/>.</param>
/// <param name="End">Where it ends (exclusive).</param>
/// <param name="Rects">Its boxes on the page, one per line it covers (page space).</param>
public sealed record RedactionMatch(int Page, RedactionPattern Pattern, int Start, int End, string Text, IReadOnlyList<RectD> Rects);

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

    public static string Name(RedactionPattern pattern) => pattern switch
    {
        RedactionPattern.SocialSecurity => "US Social Security numbers",
        RedactionPattern.Phone => "Phone numbers",
        RedactionPattern.Email => "Email addresses",
        RedactionPattern.PaymentCard => "Payment card numbers",
        RedactionPattern.Date => "Dates",
        RedactionPattern.ZipCode => "US ZIP codes",
        RedactionPattern.Iban => "Bank account numbers (IBAN)",
        RedactionPattern.IpAddress => "IP addresses",
        RedactionPattern.Phrase => "Your words and phrases",
        _ => "Your pattern",
    };

    /// <summary>What a kind looks like, for the dialog.</summary>
    public static string Example(RedactionPattern pattern) => pattern switch
    {
        RedactionPattern.SocialSecurity => "123-45-6789 or 123456789",
        RedactionPattern.Phone => "(555) 201-3434, +1 555 201 3434, +44 20 7946 0958",
        RedactionPattern.Email => "name@example.com",
        RedactionPattern.PaymentCard => "4111 1111 1111 1111; only numbers whose check digit is right",
        RedactionPattern.Date => "2026-10-27, 10/27/2026, 27.10.2026, October 27, 2026, 27 Oct 2026",
        RedactionPattern.ZipCode => "90210 or 90210-1234; any five-digit number matches, so check the marks",
        RedactionPattern.Iban => "DE89 3704 0044 0532 0130 00; only numbers whose check digits are right",
        RedactionPattern.IpAddress => "192.168.1.10, 2001:db8::1",
        _ => "",
    };

    /// <summary>What is wrong with a user's expression, in plain words; null when it is fine (or empty).</summary>
    public static string? ValidateExpression(string? expression)
    {
        if (string.IsNullOrEmpty(expression)) return null;
        try
        {
            var regex = new Regex(expression, RegexOptions.CultureInvariant, ExpressionTimeout);
            try
            {
                if (regex.IsMatch("")) return "This pattern matches empty text, so it would mark nothing useful. Make at least one part required.";
            }
            catch (RegexMatchTimeoutException)
            {
                return "This pattern takes too long even on empty text. Make it simpler.";
            }
            return null;
        }
        catch (RegexParseException ex)
        {
            // .NET's message starts "Invalid pattern '…' at offset N. "; keep what follows.
            var reason = ex.Message;
            var dot = reason.IndexOf(". ", StringComparison.Ordinal);
            if (dot >= 0) reason = reason[(dot + 2)..];
            return $"The pattern has a mistake near character {ex.Offset}: {reason}";
        }
        catch (ArgumentException ex)
        {
            return $"The pattern isn't valid: {ex.Message}";
        }
    }

    /// <summary>The matches on one page, in reading order.</summary>
    /// <exception cref="ArgumentException">The expression isn't valid (see <see cref="ValidateExpression"/>).</exception>
    /// <exception cref="TimeoutException">The expression took longer than <see cref="ExpressionTimeout"/>.</exception>
    public static List<RedactionMatch> Find(PageText text, int page, RedactionPatternOptions options) =>
        FindOnPage(text, page, options, Compile(options));

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

    private static Regex? Compile(RedactionPatternOptions options)
    {
        if (string.IsNullOrEmpty(options.Expression)) return null;
        if (ValidateExpression(options.Expression) is { } error) throw new ArgumentException(error, nameof(options));
        return new Regex(options.Expression, RegexOptions.CultureInvariant | (options.MatchCase ? RegexOptions.None : RegexOptions.IgnoreCase), ExpressionTimeout);
    }

    private static List<RedactionMatch> FindOnPage(PageText text, int page, RedactionPatternOptions options, Regex? custom)
    {
        var found = new List<RedactionMatch>();
        if (text.IsEmpty) return found;
        var (view, map) = View(text.Text);

        void Add(RedactionPattern pattern, int start, int end, bool inView)
        {
            if (end <= start) return;
            if (inView) (start, end) = (map[start], map[end - 1] + 1);
            var rects = text.GetRects(start, end).Where(r => !r.IsEmpty).ToList();
            if (rects.Count > 0) found.Add(new RedactionMatch(page, pattern, start, end, text.Text[start..end], rects));
        }

        // Built-in kinds: every rule's matches, then where two kinds overlap the stronger (earlier in Strength) keeps the text.
        var builtIn = new List<(RedactionPattern Pattern, int Start, int End)>();
        foreach (var rule in Rules.Where(r => options.Patterns.Contains(r.Pattern)))
        {
            try
            {
                foreach (Match m in rule.Regex.Matches(view))
                    if (Accept(rule, m, view) is { } end) builtIn.Add((rule.Pattern, m.Index, end));
            }
            catch (RegexMatchTimeoutException ex)
            {
                throw new TimeoutException($"Looking for {Name(rule.Pattern).ToLowerInvariant()} took too long on page {page + 1}.", ex);
            }
        }
        var kept = new List<(RedactionPattern Pattern, int Start, int End)>();
        foreach (var m in builtIn.OrderBy(m => Array.IndexOf(Strength, m.Pattern)).ThenByDescending(m => m.End - m.Start))
            if (!kept.Any(k => k.Start < m.End && m.Start < k.End)) kept.Add(m);
        foreach (var (pattern, start, end) in kept) Add(pattern, start, end, inView: true);

        // The user's phrases go through the page search (whole words, case, hyphenation, whitespace as it does).
        foreach (var phrase in options.Phrases.Select(p => p.Trim()).Where(p => p.Length > 0).Distinct(options.MatchCase ? StringComparer.Ordinal : StringComparer.OrdinalIgnoreCase))
            foreach (var (start, end) in text.Find(phrase, options.MatchCase, options.WholeWord))
                Add(RedactionPattern.Phrase, start, end, inView: false);

        if (custom is not null)
        {
            try
            {
                for (var m = custom.Match(view); m.Success; m = m.NextMatch())
                    if (m.Length > 0) Add(RedactionPattern.Expression, m.Index, m.Index + m.Length, inView: true);
            }
            catch (RegexMatchTimeoutException ex)
            {
                throw new TimeoutException($"Your pattern took too long on page {page + 1}, so the search stopped. Make it simpler: " +
                                           "a repeat inside a repeat, such as (a+)+, can take very long on some text.", ex);
            }
        }
        found.Sort((a, b) => a.Start != b.Start ? a.Start.CompareTo(b.Start) : a.End.CompareTo(b.End));
        return found;
    }

    /// <summary>
    /// The page text as the patterns read it, with each character's index in the text: whitespace (line breaks too) as a
    /// space, dashes as '-', soft hyphens dropped, a hyphen at a line break between letters dropped with the break (one
    /// word) and one between digits kept without the break (one number).
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
            if (IsDash(c) && i > 0 && i + 2 < text.Length && text[i + 1] == '\n')
            {
                if (char.IsLetter(text[i - 1]) && char.IsLetter(text[i + 2]))
                {
                    i++;
                    continue;
                }
                if (char.IsAsciiDigit(text[i - 1]) && char.IsAsciiDigit(text[i + 2]))
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

    private static bool IsDash(char c) => c is '-' or (>= '‐' and <= '―') or '−' or '﹣' or '－';

    /// <summary>Where a rule's match ends once checked (a card or IBAN may lose groups that came after it), or null.</summary>
    private static int? Accept(Rule rule, Match m, string view)
    {
        var start = m.Index;
        var end = m.Index + m.Length;
        while (true)
        {
            if (rule.Valid(m, view[start..end])) return end;
            if (!rule.Trim) return null;
            var cut = view.LastIndexOfAny([' ', '-'], end - 1, end - start);
            if (cut <= start) return null;
            end = cut;
        }
    }

    // ───────────────────────────── the patterns ─────────────────────────────

    /// <param name="Trim">On a failed check, try again without the last group (a year or code printed after the number).</param>
    private sealed record Rule(RedactionPattern Pattern, Regex Regex, Func<Match, string, bool> Valid, bool Trim = false);

    /// <summary>Which kind keeps text two kinds claim: checked numbers first, the loosest last.</summary>
    private static readonly RedactionPattern[] Strength =
    [
        RedactionPattern.PaymentCard, RedactionPattern.Iban, RedactionPattern.SocialSecurity, RedactionPattern.Email,
        RedactionPattern.IpAddress, RedactionPattern.Phone, RedactionPattern.Date, RedactionPattern.ZipCode,
    ];

    // A number starts where no letter, digit or '@' comes before it, nor a digit and a separator (it would be the tail
    // of a longer number), and ends the same way.
    private const string Lead = @"(?<![\w@])(?<![0-9][.,/-])";
    private const string Trail = @"(?![\w@])(?![.,/-][0-9])";
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
            Trim: true),

        new(RedactionPattern.Date, R(Lead + @"(?<y>(?:1[89]|2[0-9])[0-9]{2})(?<s>[-/.])(?<m>0?[1-9]|1[0-2])\k<s>(?<d>0?[1-9]|[12][0-9]|3[01])" + Trail),
            (m, _) => IsDay(Int(m, "y"), Int(m, "m"), Int(m, "d"))),
        // 10/27/2026 or 27.10.2026: month first or day first, whichever makes a date; two-digit years only with slashes.
        new(RedactionPattern.Date, R(Lead + @"(?<a>[0-9]{1,2})(?<s>[-/.])(?<b>[0-9]{1,2})\k<s>(?<y>[0-9]{4}|[0-9]{2})" + Trail),
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
            (_, value) => IbanValid(value.Replace(" ", "")), Trim: true),

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
