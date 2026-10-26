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
    /// Masks what identifies a person, a printer or a network in a line of text: IP and MAC addresses, host names (in URLs, .local
    /// and other dotted names, host:port, HP's NPI/HP+hex names), UUIDs, serial numbers and serial-like IDs, long hex strings
    /// (certificate pins), e-mail addresses, file paths (keeping the extension) and the user's and PC's names. Leaves times,
    /// versions, models, firmware revisions, .NET type names, file names and error codes.
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
        text = MappedIpv4().Replace(text, "[ip]");
        text = Ipv6().Replace(text, "[ip]");
        text = Ipv4().Replace(text, "[ip]");
        text = DottedHost().Replace(text, "[host]");
        text = HostPort().Replace(text, "[host]");
        text = HpHostName().Replace(text, "[host]");
        text = Serial().Replace(text, "$1$2[serial]");
        text = LongHex().Replace(text, "[hex]");
        text = SerialLike().Replace(text, "[id]");
        text = BracketId().Replace(text, "[id]");
        return text;
    }

    [GeneratedRegex(@"[\w.+-]+@[\w-]+(?:\.[\w-]+)+")]
    private static partial Regex Email();

    // A drive or UNC path: folders may hold spaces (they end at a backslash). The last part runs, spaces included, to the first
    // extension that ends a word ("John Smith tax return.pdf"); one without an extension ends at a space, a closing bracket, a
    // comma or a semicolon (the text around it).
    [GeneratedRegex(@"(?:\b[A-Za-z]:|\\\\[^\\\s/:*?""<>|]+)\\(?:[^\\/:*?""<>|\r\n]+\\)*(?:[^\\/:*?""<>|\r\n]*?\.[A-Za-z0-9]{1,5}(?![\w.])|[^\\/:*?""<>|\s),;\]]*)")]
    private static partial Regex WindowsPath();

    [GeneratedRegex(@"\.[A-Za-z0-9]{1,5}$")]
    private static partial Regex Extension();

    [GeneratedRegex(@"\b((?:https?|ipps?|wss?|socket)://)(?:\[[0-9A-Fa-f:.%\w]+\]|[^/\s:?#\[\]]+)")]
    private static partial Regex UrlHost();

    [GeneratedRegex(@"\b[\w-]+(?:\.[\w-]+)*\.local\b")]
    private static partial Regex LocalHost();

    // A dotted name ending in a lower-case label (lan, home, corp, com…): officeprinter.lan, OfficePrinter.home.arpa. Not .NET
    // type names (their labels are capitalized: System.Text.Json), versions (the last label is a number) nor file names (the
    // last label is a known extension: settings.json, MainWindow.xaml.cs).
    [GeneratedRegex(@"(?<![\w.\-\[@/\\])(?:[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?\.)+(?!(?:pdf|jpe?g|png|tiff?|heic|heif|bmp|gif|webp|txt|log|json|xml|xaml|cs|dll|exe|msix|msixbundle|appx|msi|docx?|xlsx?|pptx?|rtf|odt|ods|odp|html?|csv|ini|config|md|zip|svg|ps|pcl|pwg|urf|xps|oxps|ico|tmp|dat|db|cfg|ttf|otf|lnk|bat|cmd|pri|winmd|js|css|eml|msg|vcf|pfx|cer)(?![\w-]))[a-z]{2,24}(?![\w-]|\.\w)")]
    private static partial Regex DottedHost();

    // A name before ":port" (port kept), any case, starting with a letter: "(officeprinter:9100)", "OFFICE.CORP:443". Not times
    // (12:34:56 starts with a digit; T10:00:00 follows a digit), "cs:line 12" (no number after the colon) or "0x8007" (not a port).
    [GeneratedRegex(@"(?<![\w.\-\[:/@])[A-Za-z][\w-]*(?:\.[\w-]+)*(?=:\d{1,5}(?!\w|:\d|\.\d))")]
    private static partial Regex HostPort();

    // HP's default host names, NPI or HP and the MAC address's last six hex digits, in any case: NPI7A1B2C, npi7a1b2c, HPF0A1B2.
    [GeneratedRegex(@"\b(?:NPI|HP)[0-9A-F]{6}\b", RegexOptions.IgnoreCase)]
    private static partial Regex HpHostName();

    [GeneratedRegex(@"\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\b")]
    private static partial Regex UuidPattern();

    [GeneratedRegex(@"\b[0-9A-Fa-f]{2}(?:[:-][0-9A-Fa-f]{2}){5}\b")]
    private static partial Regex Mac();

    // Has "::" or at least five groups, so times (12:34:56) are left alone.
    // An IPv6 address ending in an IPv4 one (::ffff:192.168.1.5, 64:ff9b::192.0.2.1), whole, before either pattern takes a part.
    [GeneratedRegex(@"(?<![\w:.])(?=[0-9A-Fa-f:]*::)[0-9A-Fa-f:]*:(?:\d{1,3}\.){3}\d{1,3}(?!\d|\.\d)")]
    private static partial Regex MappedIpv4();

    // Has "::" or at least five groups, so times (12:34:56) are left alone.
    [GeneratedRegex(@"(?<![\w:.])(?=[0-9A-Fa-f:]*::|(?:[0-9A-Fa-f]{1,4}:){5})[0-9A-Fa-f]{0,4}(?::[0-9A-Fa-f]{0,4}){2,7}(?:%\w+)?(?![\w:])")]
    private static partial Regex Ipv6();

    // A dotted quad is a version, kept, when it follows "v", "ver" or "version" (Version=10.0.12.0) or when every part is one digit
    // (1.0.7.0: app and assembly versions; the only addresses like that are public resolvers such as 8.8.8.8, nobody's own).
    // Every other one is masked: private and public addresses always have a part of two digits or more.
    [GeneratedRegex(@"(?<![\d.])(?<!\b(?i:v|ver|version)[\s=:]*)(?!\d\.\d\.\d\.\d(?!\d))(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?!\d|\.\d)")]
    private static partial Regex Ipv4();

    // Whole words only: not the "Serial" in System.Text.Json.Serialization.
    [GeneratedRegex(@"\b(serial(?:\s*number)?|s/n)\b(\s*[:=#]?\s*)[A-Za-z0-9-]{4,}", RegexOptions.IgnoreCase)]
    private static partial Regex Serial();

    [GeneratedRegex(@"\b[0-9A-Fa-f]{16,}\b")]
    private static partial Regex LongHex();

    // Capital letters and digits, both, eight or more: serial numbers and the IDs printers name themselves with. Kept: model
    // numbers after a maker's series prefix (one to three letters, three to five digits, up to four letters, after a hyphen: the
    // L8900CDW of MFC-L8900CDW; standing alone, the same shape is as likely an ID, and masked) and the revision
    // after "Firmware" (the printer's About list and the logs label it so; serials are labeled "Serial number", masked above).
    [GeneratedRegex(@"(?<!\b(?i:firmware(?:\s+(?:revision|version))?)\s*[:=]?\s*)\b(?=[A-Z0-9]*\d)(?=[A-Z0-9]*[A-Z])(?!(?<=-)[A-Z]{1,3}\d{3,5}[A-Z]{0,4}\b)[A-Z0-9]{8,}\b")]
    private static partial Regex SerialLike();

    // HP's network names end in the last six digits of the printer's MAC address: "HP OfficeJet Pro 9010 series [A1B2C3]".
    [GeneratedRegex(@"\[[0-9A-Fa-f]{6}\]")]
    private static partial Regex BracketId();
}
