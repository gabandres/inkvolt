using System.Globalization;
using System.Text;

namespace InkvoltPrint.Core.Presets;

/// <summary>What a file-name template's tokens stand for when a scan is saved.</summary>
/// <param name="Number">The preset's counter, <c>{n}</c>.</param>
/// <param name="Pages">Pages saved, <c>{pages}</c>.</param>
/// <param name="Culture">For date and time formats (month names); null = the current culture.</param>
/// <param name="Found">What the first page's text says (<see cref="TextFinds"/>), for <c>{text-date}</c>, <c>{text-title}</c> and <c>{text-number}</c>; null: nothing read.</param>
public sealed record NameContext(DateTime Now, string Preset, string Printer, int Number, int Pages, CultureInfo? Culture = null, FoundInText? Found = null);

/// <summary>
/// File-name and subfolder templates for scan presets: <c>{date}</c> / <c>{date:yyyy-MM}</c>, <c>{time}</c> /
/// <c>{time:HH.mm}</c>, <c>{preset}</c>, <c>{printer}</c>, <c>{n}</c> / <c>{n:000}</c> (the preset's counter),
/// <c>{pages}</c>; from the first page's text (roadmap 4.11) <c>{text-date}</c> / <c>{text-date:yyyy-MM}</c> (a date found on it),
/// <c>{text-title}</c> (its first heading) and <c>{text-number}</c> (an invoice-like number), empty when the page doesn't say (the
/// spaces and dashes they leave are tidied); <c>{{</c> and <c>}}</c> are literal braces. Names come out safe for Windows (no reserved characters or
/// device names, no trailing dots or spaces, never empty); subfolders never leave the chosen folder; and a name already
/// taken gets <c>-2</c>, <c>-3</c>… so nothing is overwritten.
/// </summary>
public static class FileNameTemplate
{
    /// <summary>Longest file name (without extension) a template makes: leaves room for the folder within MAX_PATH-minded tools.</summary>
    public const int MaxNameLength = 120;

    private const string DefaultDate = "yyyy-MM-dd", DefaultTime = "HHmm";
    private static string Fallback => CoreStrings.Preset_FallbackFileName;
    private const string TokenList = "{date}, {time}, {preset}, {printer}, {n}, {pages}, {text-date}, {text-title}", LastToken = "{text-number}";

    // Windows' reserved characters, whatever the OS these run on (Path.GetInvalidFileNameChars differs per platform).
    private static readonly char[] Reserved = ['<', '>', ':', '"', '/', '\\', '|', '?', '*'];

    private enum Kind { Text, Token, Separator }

    private readonly record struct Part(Kind Kind, string Text, string? Format = null);

    /// <summary>What's wrong with the template, in words for the editor; null when it's fine.</summary>
    public static string? Problem(string? template)
    {
        var parts = Parse(template ?? "", out var error);
        foreach (var part in parts)
        {
            if (part.Kind != Kind.Token) continue;
            switch (part.Text.ToLowerInvariant())
            {
                case "date" or "time" or "text-date":
                    if (part.Format is { } f)
                    {
                        try { _ = new DateTime(2026, 1, 2, 3, 4, 5).ToString(f, CultureInfo.InvariantCulture); }
                        catch (FormatException) { return string.Format(CoreStrings.Preset_BadDateFormat, $"{{{part.Text}:{f}}}"); }
                    }
                    break;
                case "n":
                    if (part.Format is { } nf && TooWide(nf)) return string.Format(CoreStrings.Preset_NumberTooWide, $"{{{part.Text}:{nf}}}", MaxDigits);
                    break;
                case "preset" or "printer" or "pages" or "text-title" or "text-number":
                    if (part.Format is not null) return string.Format(CoreStrings.Preset_TokenNoFormat, $"{{{part.Text}}}");
                    break;
                default:
                    return string.Format(CoreStrings.Preset_UnknownToken, $"{{{part.Text}}}", TokenList, LastToken);
            }
        }
        return error;
    }

    /// <summary>
    /// The most digits <c>{n:D&lt;n&gt;}</c> pads a number to: a name is cut long before, and .NET's <c>D999999999</c> would
    /// make a string of a billion zeros.
    /// </summary>
    public const int MaxDigits = 32;

    /// <summary>A <c>D&lt;n&gt;</c> format padding past <see cref="MaxDigits"/> (any count of digits after the D).</summary>
    internal static bool TooWide(string format) =>
        format.Length > 1 && format[0] is 'D' or 'd' && format.AsSpan(1).IndexOfAnyExceptInRange('0', '9') < 0
        && (!int.TryParse(format.AsSpan(1), NumberStyles.None, CultureInfo.InvariantCulture, out var width) || width > MaxDigits);

    /// <summary>
    /// The template pads <c>{n}</c> past <see cref="MaxDigits"/>: <see cref="Problem"/> refuses it, <see cref="ScanPresets.Normalize"/>
    /// puts back a stored one's default, and a name never pads it (the token stays as typed).
    /// </summary>
    public static bool PadsTooWide(string? template) =>
        Parse(template ?? "", out _).Any(p => p.Kind == Kind.Token && p.Text.Equals("n", StringComparison.OrdinalIgnoreCase) && p.Format is { } f && TooWide(f));

    /// <summary>The template as one safe file name (no extension). Unknown tokens stay as typed.</summary>
    public static string FileName(string? template, NameContext ctx)
    {
        var sb = new StringBuilder();
        var trimLead = false; // after an empty {text-…} at the start: the next separator goes too
        foreach (var part in Parse(template ?? "", out _))
        {
            var value = part.Kind == Kind.Token ? Value(part, ctx) : part.Text;
            if (IsTextToken(part) && value.Length == 0)
            {
                // What the page didn't say takes the separator before it with it ("Maple - {text-number} - 2026" → "Maple - 2026");
                // at the start, the one after it. The name's other separators stay as typed.
                var end = sb.Length;
                while (end > 0 && IsJoiner(sb[end - 1])) end--;
                sb.Length = end;
                trimLead = end == 0;
                continue;
            }
            if (trimLead) value = value.TrimStart(Joiners);
            trimLead = trimLead && value.Length == 0;
            sb.Append(value);
        }
        return Sanitize(sb.ToString());
    }

    private static readonly char[] Joiners = [' ', '-', '_'];

    private static bool IsJoiner(char c) => Array.IndexOf(Joiners, c) >= 0;

    /// <summary>The template names the file from the page's text (<c>{text-…}</c>): the scan is read (OCR) for it.</summary>
    public static bool ReadsText(string? template) => Parse(template ?? "", out _).Any(IsTextToken);

    private static bool IsTextToken(Part part) =>
        part.Kind == Kind.Token && part.Text.ToLowerInvariant() is "text-date" or "text-title" or "text-number";

    /// <summary>
    /// The template as a relative folder path ("" = none): <c>/</c> and <c>\</c> outside tokens separate folders; each
    /// folder name is made safe, and empty, <c>.</c> and <c>..</c> parts are dropped, so it never leaves the chosen folder.
    /// </summary>
    public static string Subfolder(string? template, NameContext ctx)
    {
        var segments = new List<string>();
        var sb = new StringBuilder();
        void Flush()
        {
            var raw = sb.ToString();
            sb.Clear();
            var safe = Sanitize(raw, fallback: null);
            if (safe.Length > 0) segments.Add(safe);
        }
        foreach (var part in Parse(template ?? "", out _))
        {
            if (part.Kind == Kind.Separator) Flush();
            else sb.Append(part.Kind == Kind.Token ? Value(part, ctx) : part.Text);
        }
        Flush();
        return string.Join('\\', segments);
    }

    /// <summary><paramref name="stem"/> + <paramref name="extension"/> in <paramref name="folder"/>, else stem-2, stem-3… (first free).</summary>
    public static string UniquePath(string folder, string stem, string extension, Func<string, bool> exists) =>
        UniquePaths(folder, stem, extension, 1, exists)[0];

    /// <summary>
    /// Names for <paramref name="count"/> files saved together (images of one scan): "stem (1).jpg", "stem (2).jpg"…, or
    /// just "stem.jpg" for one. When any of them is taken, the whole set moves on to stem-2, stem-3…, so a scan's pages
    /// keep one name.
    /// </summary>
    public static IReadOnlyList<string> UniquePaths(string folder, string stem, string extension, int count, Func<string, bool> exists)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(count, 1);
        for (var attempt = 1; attempt < 10_000; attempt++)
        {
            var name = attempt == 1 ? stem : $"{stem}-{attempt}";
            var set = count == 1
                ? [Path.Combine(folder, name + extension)]
                : Enumerable.Range(1, count).Select(i => Path.Combine(folder, $"{name} ({i}){extension}")).ToList();
            if (!set.Any(exists)) return set;
        }
        throw new IOException(string.Format(CoreStrings.Preset_TooManyFiles, stem, folder));
    }

    /// <summary>
    /// Moves files already written under temporary names to their final names as one set, never over another file: when a
    /// name turns out to be taken (another program saved there since <see cref="UniquePaths"/> looked), the files moved so far
    /// go back and the whole set tries the next free stem, so a scan's pages are never split across names.
    /// </summary>
    /// <param name="tryMove">Moves the first path to the second unless the second exists (then false; nothing moved).</param>
    /// <returns>The final paths, in the order of <paramref name="temps"/>.</returns>
    public static IReadOnlyList<string> PlaceSet(IReadOnlyList<string> temps, string folder, string stem, string extension,
        Func<string, bool> exists, Func<string, string, bool> tryMove)
    {
        for (var attempt = 0; attempt < 20; attempt++)
        {
            var targets = UniquePaths(folder, stem, extension, temps.Count, exists);
            var moved = 0;
            while (moved < temps.Count && tryMove(temps[moved], targets[moved])) moved++;
            if (moved == temps.Count) return targets;
            for (var i = moved - 1; i >= 0; i--)
                if (!tryMove(targets[i], temps[i])) throw new IOException(string.Format(CoreStrings.Preset_CouldntPutBack, targets[i]));
        }
        throw new IOException(string.Format(CoreStrings.Preset_NoFreeName, stem, folder));
    }

    /// <summary>One safe Windows file or folder name: reserved and control characters become '-', no leading or trailing spaces, no trailing dots, no device names.</summary>
    public static string Sanitize(string name) => Sanitize(name, Fallback);

    private static string Sanitize(string name, string? fallback)
    {
        var sb = new StringBuilder(name.Length);
        foreach (var c in name) sb.Append(c < 32 || Array.IndexOf(Reserved, c) >= 0 ? '-' : c);
        var s = sb.ToString().Trim();
        if (s.Length > MaxNameLength) s = s[..MaxNameLength];
        s = s.TrimEnd('.', ' ').TrimStart(' ');
        if (s.Length == 0) return fallback ?? "";
        // "CON", "nul.txt": Windows maps these to devices whatever the extension.
        if (DeviceNames.IsReserved(s))
        {
            var dot = s.IndexOf('.');
            s = (dot < 0 ? s : s[..dot]) + "_" + (dot < 0 ? "" : s[dot..]);
        }
        return s;
    }

    private static string Value(Part token, NameContext ctx)
    {
        var culture = ctx.Culture ?? CultureInfo.CurrentCulture;
        try
        {
            return token.Text.ToLowerInvariant() switch
            {
                "date" => ctx.Now.ToString(token.Format ?? DefaultDate, culture),
                "time" => ctx.Now.ToString(token.Format ?? DefaultTime, culture),
                "n" when token.Format is { } nf && TooWide(nf) => Literal(token),
                "n" => ctx.Number.ToString(token.Format ?? "0", culture),
                "preset" when token.Format is null => ctx.Preset,
                "printer" when token.Format is null => ctx.Printer,
                "pages" when token.Format is null => ctx.Pages.ToString(culture),
                "text-date" => ctx.Found?.Date is { } found ? found.ToString(token.Format ?? DefaultDate, culture) : "",
                "text-title" when token.Format is null => ctx.Found?.Title ?? "",
                "text-number" when token.Format is null => ctx.Found?.Number ?? "",
                _ => Literal(token),
            };
        }
        catch (FormatException)
        {
            return Literal(token);
        }
    }

    private static string Literal(Part token) => token.Format is null ? $"{{{token.Text}}}" : $"{{{token.Text}:{token.Format}}}";

    /// <summary>Splits into text, tokens and (outside tokens) folder separators. A stray brace is kept as text and reported.</summary>
    private static List<Part> Parse(string template, out string? error)
    {
        error = null;
        var parts = new List<Part>();
        var text = new StringBuilder();
        void FlushText()
        {
            if (text.Length > 0) parts.Add(new(Kind.Text, text.ToString()));
            text.Clear();
        }
        for (var i = 0; i < template.Length; i++)
        {
            var c = template[i];
            if (c == '{' && i + 1 < template.Length && template[i + 1] == '{') { text.Append('{'); i++; }
            else if (c == '}' && i + 1 < template.Length && template[i + 1] == '}') { text.Append('}'); i++; }
            else if (c == '{')
            {
                var end = template.IndexOf('}', i + 1);
                if (end < 0)
                {
                    error ??= CoreStrings.Preset_NoClosingBrace;
                    text.Append(template[i..]);
                    break;
                }
                FlushText();
                var body = template[(i + 1)..end];
                var colon = body.IndexOf(':');
                parts.Add(colon < 0 ? new(Kind.Token, body.Trim()) : new(Kind.Token, body[..colon].Trim(), body[(colon + 1)..]));
                i = end;
            }
            else if (c == '}')
            {
                error ??= CoreStrings.Preset_NoOpeningBrace;
                text.Append(c);
            }
            else if (c is '/' or '\\')
            {
                FlushText();
                parts.Add(new(Kind.Separator, c.ToString()));
            }
            else text.Append(c);
        }
        FlushText();
        return parts;
    }
}
