using System.Globalization;
using System.Text;

namespace InkvoltPrint.Core.Presets;

/// <summary>What a file-name template's tokens stand for when a scan is saved.</summary>
/// <param name="Number">The preset's counter, <c>{n}</c>.</param>
/// <param name="Pages">Pages saved, <c>{pages}</c>.</param>
/// <param name="Culture">For date and time formats (month names); null = the current culture.</param>
public sealed record NameContext(DateTime Now, string Preset, string Printer, int Number, int Pages, CultureInfo? Culture = null);

/// <summary>
/// File-name and subfolder templates for scan presets: <c>{date}</c> / <c>{date:yyyy-MM}</c>, <c>{time}</c> /
/// <c>{time:HH.mm}</c>, <c>{preset}</c>, <c>{printer}</c>, <c>{n}</c> / <c>{n:000}</c> (the preset's counter),
/// <c>{pages}</c>; <c>{{</c> and <c>}}</c> are literal braces. Names come out safe for Windows (no reserved characters or
/// device names, no trailing dots or spaces, never empty); subfolders never leave the chosen folder; and a name already
/// taken gets <c>-2</c>, <c>-3</c>… so nothing is overwritten.
/// </summary>
public static class FileNameTemplate
{
    /// <summary>Longest file name (without extension) a template makes: leaves room for the folder within MAX_PATH-minded tools.</summary>
    public const int MaxNameLength = 120;

    private const string DefaultDate = "yyyy-MM-dd", DefaultTime = "HHmm";
    private const string Fallback = "Scan";
    private const string TokenList = "{date}, {time}, {preset}, {printer}, {n} or {pages}";

    // Windows' reserved characters, whatever the OS these run on (Path.GetInvalidFileNameChars differs per platform).
    private static readonly char[] Reserved = ['<', '>', ':', '"', '/', '\\', '|', '?', '*'];

    private static readonly HashSet<string> DeviceNames = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };

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
                case "date" or "time":
                    if (part.Format is { } f)
                    {
                        try { _ = new DateTime(2026, 1, 2, 3, 4, 5).ToString(f, CultureInfo.InvariantCulture); }
                        catch (FormatException) { return $"{{{part.Text}:{f}}} isn't a date or time format .NET understands."; }
                    }
                    break;
                case "n":
                    break;
                case "preset" or "printer" or "pages":
                    if (part.Format is not null) return $"{{{part.Text}}} takes no format.";
                    break;
                default:
                    return $"Unknown token {{{part.Text}}}. Use {TokenList}.";
            }
        }
        return error;
    }

    /// <summary>The template as one safe file name (no extension). Unknown tokens stay as typed.</summary>
    public static string FileName(string? template, NameContext ctx)
    {
        var sb = new StringBuilder();
        foreach (var part in Parse(template ?? "", out _))
            sb.Append(part.Kind switch { Kind.Token => Value(part, ctx), Kind.Separator => part.Text, _ => part.Text });
        return Sanitize(sb.ToString());
    }

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
        throw new IOException($"Too many files called \"{stem}\" in {folder}.");
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
        var dot = s.IndexOf('.');
        var stem = dot < 0 ? s : s[..dot];
        if (DeviceNames.Contains(stem.TrimEnd(' '))) s = stem + "_" + (dot < 0 ? "" : s[dot..]);
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
                "n" => ctx.Number.ToString(token.Format ?? "0", culture),
                "preset" when token.Format is null => ctx.Preset,
                "printer" when token.Format is null => ctx.Printer,
                "pages" when token.Format is null => ctx.Pages.ToString(culture),
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
                    error ??= "A { has no closing }. Type {{ for a brace.";
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
                error ??= "A } has no opening {. Type }} for a brace.";
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
