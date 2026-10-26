using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPrint.Core.Suite;

/// <summary>
/// "Report a problem" in both apps: the details a report needs (version, Windows, a few settings, the end of the log) as text
/// the user copies and sends themselves. Nothing is sent from the app. Everything but the version line goes through
/// <see cref="Scrub"/> first, so addresses, printer IDs and serials, file paths and the user's own names don't leave in it.
/// </summary>
public static partial class Diagnostics
{
    /// <summary>Names that identify this PC's user, masked wherever they appear.</summary>
    public sealed record Identity(string? UserName, string? MachineName)
    {
        public static Identity Current => new(Environment.UserName, Environment.MachineName);
    }

    /// <summary>Lines of the log a report carries.</summary>
    public const int LogLines = 200;

    public static string Report(string app, string version, string windows, string architecture, bool packaged,
        IEnumerable<(string Name, string Value)> settings, IReadOnlyList<string> logTail, Identity who)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"{app} {version}{(packaged ? " (Store package)" : "")}");
        sb.AppendLine($"Windows: {windows}, {architecture}");
        sb.AppendLine($".NET: {Environment.Version}");
        sb.AppendLine();
        sb.AppendLine("Settings");
        foreach (var (name, value) in settings) sb.AppendLine($"{name}: {Scrub(value, who)}");
        sb.AppendLine();
        sb.AppendLine($"Log (last {LogLines} lines)");
        if (logTail.Count == 0) sb.AppendLine("(no log yet)");
        foreach (var line in logTail) sb.AppendLine(Scrub(line, who));
        return sb.ToString();
    }

    /// <summary>The last <paramref name="count"/> lines of a log, read while the app may be writing to it; none when it's missing.</summary>
    public static IReadOnlyList<string> Tail(string path, int count = LogLines)
    {
        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            var lines = new Queue<string>(count + 1);
            while (reader.ReadLine() is { } line)
            {
                lines.Enqueue(line);
                if (lines.Count > count) lines.Dequeue();
            }
            return [.. lines];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return [];
        }
    }

    /// <summary>A new GitHub issue with the version and Windows filled in, asking to paste the copied details (too long for a URL).</summary>
    public static string IssueUrl(string repository, string app, string version, string windows)
    {
        var body = $"""
            **App:** {app} {version}
            **Windows:** {windows}

            **What happened?**


            **What did you expect to happen?**


            **Steps to get there**


            **Details**
            Paste here the details {app} copied (Report a problem). Read them first: delete anything you'd rather not share.

            """;
        return $"{repository.TrimEnd('/')}/issues/new?title={Uri.EscapeDataString($"[{app}] ")}&body={Uri.EscapeDataString(body.ReplaceLineEndings("\n"))}";
    }

    /// <summary>
    /// Masks what identifies a person, a printer or a network in a line of text: IP and MAC addresses, host names (in URLs and
    /// .local names), UUIDs, serial numbers and serial-like IDs, long hex strings (certificate pins), e-mail addresses, file
    /// paths (keeping the extension) and the user's and PC's names. Leaves times, versions, models and error codes.
    /// </summary>
    public static string Scrub(string text, Identity who)
    {
        if (who.MachineName is { Length: >= 3 } pc) text = Regex.Replace(text, $@"\b{Regex.Escape(pc)}\b", "[pc]", RegexOptions.IgnoreCase);
        if (who.UserName is { Length: >= 3 } user) text = Regex.Replace(text, $@"\b{Regex.Escape(user)}\b", "[user]", RegexOptions.IgnoreCase);
        text = Email().Replace(text, "[email]");
        text = WindowsPath().Replace(text, m => "[path]" + Extension().Match(m.Value).Value);
        text = UrlHost().Replace(text, "$1[host]");
        text = LocalHost().Replace(text, "[host].local");
        text = UuidPattern().Replace(text, "[uuid]");
        text = Mac().Replace(text, "[mac]");
        text = Ipv6().Replace(text, "[ip]");
        text = Ipv4().Replace(text, "[ip]");
        text = Serial().Replace(text, "$1$2[serial]");
        text = LongHex().Replace(text, "[hex]");
        text = SerialLike().Replace(text, "[id]");
        text = BracketId().Replace(text, "[id]");
        return text;
    }

    [GeneratedRegex(@"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")]
    private static partial Regex Email();

    // A drive or UNC path: folders may hold spaces (they end at a backslash); the last part may not, nor a closing bracket,
    // comma or semicolon (the text around it).
    [GeneratedRegex(@"(?:\b[A-Za-z]:|\\\\[^\\\s/:*?""<>|]+)\\(?:[^\\/:*?""<>|\r\n]+\\)*[^\\/:*?""<>|\s),;\]]*")]
    private static partial Regex WindowsPath();

    [GeneratedRegex(@"\.[A-Za-z0-9]{1,5}$")]
    private static partial Regex Extension();

    [GeneratedRegex(@"\b((?:https?|ipps?|wss?|socket)://)(?:\[[0-9A-Fa-f:.%\w]+\]|[^/\s:?#\[\]]+)")]
    private static partial Regex UrlHost();

    [GeneratedRegex(@"\b[\w-]+\.local\b")]
    private static partial Regex LocalHost();

    [GeneratedRegex(@"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")]
    private static partial Regex UuidPattern();

    [GeneratedRegex(@"\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b")]
    private static partial Regex Mac();

    // Has "::" or at least five groups, so times (12:34:56) are left alone.
    [GeneratedRegex(@"(?<![\w:.])(?=[0-9A-Fa-f:]*::|(?:[0-9A-Fa-f]{1,4}:){5})[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:%\w+)?(?![\w:])")]
    private static partial Regex Ipv6();

    [GeneratedRegex(@"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b")]
    private static partial Regex Ipv4();

    [GeneratedRegex(@"\b(serial(?:\s*number)?|s/n)(\s*[:=#]?\s*)[A-Za-z0-9-]{4,}", RegexOptions.IgnoreCase)]
    private static partial Regex Serial();

    [GeneratedRegex(@"\b[0-9A-Fa-f]{16,}\b")]
    private static partial Regex LongHex();

    // Capital letters and digits, both, eight or more: serial numbers and the IDs printers name themselves with.
    [GeneratedRegex(@"\b(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])[A-Z0-9]{8,}\b")]
    private static partial Regex SerialLike();

    // HP's network names end in the last six digits of the printer's MAC address: "HP OfficeJet Pro 9010 series [A1B2C3]".
    [GeneratedRegex(@"\[[0-9A-Fa-f]{6}\]")]
    private static partial Regex BracketId();
}
