using System.Globalization;
using System.Text;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Alerts;

/// <summary>One read of a printer's Windows queue, for job alerts: whether it holds its jobs on purpose, and the jobs.</summary>
public sealed record JobQueueState(bool Paused, bool WorkOffline, IReadOnlyList<QueueJob> Jobs)
{
    public static JobQueueState Of(SpoolerQueue queue, IReadOnlyList<QueueJob> jobs) =>
        new((queue.Status & SpoolerFlags.StatusPaused) != 0, (queue.Attributes & SpoolerFlags.AttributeWorkOffline) != 0, jobs);
}

/// <summary>
/// Who "you" are on a queue: the signed-in Windows user. Stricter than <see cref="QueueJobText.IsOwner"/>, which only decides who
/// sees a Cancel button: two PCs sharing a printer often have the same user name ("Owner", "Admin"), so a job that says which
/// domain or PC it came from must say this one. When in doubt the job isn't yours: another person's document is never named.
/// </summary>
public sealed record JobOwner(string? UserName, string? Domain, string? Machine)
{
    /// <summary>Read once: asked for every printer every minute, and a domain name can take a lookup or refuse.</summary>
    public static JobOwner Current { get; } = ReadCurrent();

    private static JobOwner ReadCurrent()
    {
        string? domain = null;
        try { domain = Environment.UserDomainName; }
        catch (Exception ex) when (ex is InvalidOperationException or PlatformNotSupportedException) { }
        return new JobOwner(Environment.UserName, domain, Environment.MachineName);
    }

    public bool Owns(QueueJob job)
    {
        var owner = job.Owner?.Trim() ?? "";
        if (owner.Length == 0 || string.IsNullOrWhiteSpace(UserName)) return false;
        var slash = owner.LastIndexOf('\\');
        var name = owner[(slash + 1)..];
        if (!string.Equals(name, UserName.Trim(), StringComparison.OrdinalIgnoreCase)) return false;
        if (slash > 0 && !string.IsNullOrWhiteSpace(Domain) && !string.Equals(owner[..slash], Domain.Trim(), StringComparison.OrdinalIgnoreCase)) return false;
        var from = Host(job.Machine);
        return from.Length == 0 || Host(Machine).Length == 0 || string.Equals(from, Host(Machine), StringComparison.OrdinalIgnoreCase);
    }

    /// <summary>"\\PC.office.lan" as "PC", at most 15 characters: Windows' short name for a PC is cut there, its full name isn't.</summary>
    private static string Host(string? machine)
    {
        var host = (machine ?? "").Trim().TrimStart('\\');
        var dot = host.IndexOf('.');
        if (dot > 0) host = host[..dot];
        return host.Length > 15 ? host[..15] : host;
    }
}

/// <summary>What a printer's last read says for a job that isn't moving: it's idle, it says it's working, or it can't be expected to move it.</summary>
public enum PrinterWork { NotReady, Ready, Printing }

/// <summary>
/// How far a job has got, as far as the spooler says: pages printed, pages and bytes spooled, how far along it is
/// (<see cref="JobRules.Stage"/>), and how many times someone restarted it. Forward is any of them above the furthest seen. A state going back and
/// forth or a count going down isn't forward, so flicker neither passes for progress nor hides a hung job.
/// </summary>
public readonly record struct JobProgress(int Printed, int Pages, int Stage, long Bytes, int Restarts)
{
    public static JobProgress Of(QueueJob job) => new(job.PagesPrinted, job.Pages, JobRules.Stage(job.Status), job.Bytes, 0);

    public bool Beyond(JobProgress other) =>
        Printed > other.Printed || Pages > other.Pages || Stage > other.Stage || Bytes > other.Bytes || Restarts > other.Restarts;

    public JobProgress Furthest(JobProgress other) => new(Math.Max(Printed, other.Printed), Math.Max(Pages, other.Pages), Math.Max(Stage, other.Stage),
        Math.Max(Bytes, other.Bytes), Math.Max(Restarts, other.Restarts));
}

/// <summary>
/// What a job's state means for job alerts (<see cref="AlertTracker.ObserveJobs"/>). A job is one job for as long as its id and
/// the moment it was submitted stay the same: the spooler uses ids again, and <see cref="Key"/> keeps the two apart. The key
/// says nothing about the document, so it's what gets remembered in <c>state.json</c>.
/// </summary>
public static class JobRules
{
    public const string KeyPrefix = "Job|";

    public static string Key(QueueJob job) =>
        string.Create(CultureInfo.InvariantCulture, $"{KeyPrefix}{job.Id}|{job.Submitted.ToUniversalTime().Ticks}");

    /// <summary>A key this version wrote (remembered keys come from a file that may have been edited).</summary>
    public static bool IsKey(string key)
    {
        var parts = key.Split('|');
        return parts is ["Job", _, _] && int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out _)
                                      && long.TryParse(parts[2], NumberStyles.None, CultureInfo.InvariantCulture, out _);
    }

    /// <summary>Leaving the queue anyway: being cancelled, or printed.</summary>
    public static bool IsFinishing(JobStatus s) =>
        (s & (JobStatus.Deleting | JobStatus.Deleted | JobStatus.Printed | JobStatus.Completed | JobStatus.Retained)) != 0;

    /// <summary>
    /// The spooler says this job can't go on without someone: an error, blocked by the driver, or needing someone at the
    /// printer. Out of paper or offline alone is the printer's state, not the job's, and the printer's own alerts tell that;
    /// a job paused by hand or on its way out isn't failing.
    /// </summary>
    public static bool IsFailed(JobStatus s) =>
        (s & (JobStatus.Error | JobStatus.Blocked | JobStatus.UserIntervention)) != 0 && !IsFinishing(s) && !s.HasFlag(JobStatus.Paused);

    /// <summary>The spooler itself says the printer can't take the job right now.</summary>
    public static bool SaysPrinterNotReady(JobStatus s) => (s & (JobStatus.PaperOut | JobStatus.Offline)) != 0;

    /// <summary>Could be moving if nothing held it: not paused by hand, not still being written by the app printing it, not on its way out.</summary>
    public static bool ShouldMove(JobStatus s) => !s.HasFlag(JobStatus.Paused) && !s.HasFlag(JobStatus.Spooling) && !IsFinishing(s);

    /// <summary>How far along a job is: being written, waiting, printing, done. Only ever read upward (<see cref="JobProgress"/>).</summary>
    public static int Stage(JobStatus s) =>
        IsFinishing(s) && !s.HasFlag(JobStatus.Deleting) && !s.HasFlag(JobStatus.Deleted) ? 3 : s.HasFlag(JobStatus.Printing) ? 2 : s.HasFlag(JobStatus.Spooling) ? 0 : 1;

    /// <summary>
    /// Ready: answering, ready or asleep (it wakes for a job), nothing wrong, not waiting for someone at the manual feed. Printing: the
    /// same but saying it's printing, where the job may simply be long, since many drivers count no pages, so it gets the longer wait.
    /// </summary>
    public static PrinterWork Work(PrinterSnapshot snap)
    {
        if (snap is not { Reachable: true, Status: { IsUnavailable: false, Severity: not Severity.Error } status }
            || status.Alerts.Any(a => a.Severity == Severity.Error || a.Id.Contains("manual", StringComparison.OrdinalIgnoreCase)))
            return PrinterWork.NotReady;
        return status.Code switch
        {
            "ready" or "idle" or "inPowerSave" => PrinterWork.Ready,
            "processing" or "printing" => PrinterWork.Printing,
            _ => PrinterWork.NotReady,
        };
    }
}

/// <summary>
/// Text from outside the app (a document's name comes from whatever printed it; a printer's name from its queue or the printer)
/// made safe to show in a notification. Nothing is interpreted: XML escaping is <see cref="AlertToasts"/>' job, and a toast's text is
/// plain text. This takes out what can't be written to XML at all, what can make text lie about itself (right-to-left
/// overrides, invisible characters, line breaks that fake another line) and what's too long, and leaves whole characters.
/// </summary>
public static class AlertText
{
    /// <summary>A document's name in a title, leaving room for the words around it in a balloon's 63 characters.</summary>
    public const int MaxDocument = 48;

    public const int MaxPrinter = 60;

    public const string Untitled = "Untitled";

    /// <summary>A job's document as a notification names it: a path or address is cut to its last part, which also keeps folders and links off the screen.</summary>
    public static string Document(string? name)
    {
        var text = Clean(name, int.MaxValue);
        return Cut(LastPart(text), MaxDocument) is { Length: > 0 } shown ? shown : Untitled;
    }

    public static string Printer(string? name) => Clean(name, MaxPrinter) is { Length: > 0 } shown ? shown : "the printer";

    /// <summary>One line of visible characters: controls, invisible and private-use characters and broken pairs out, runs of space as one.</summary>
    public static string Clean(string? text, int max)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var sb = new StringBuilder(Math.Min(text.Length, 512));
        var i = 0;
        var pendingSpace = false;
        while (i < text.Length && sb.Length < 4096)
        {
            Rune.DecodeFromUtf16(text.AsSpan(i), out var rune, out var used);
            var valid = used > 1 || !char.IsSurrogate(text[i]);
            i += used;
            if (!valid) continue;
            var category = Rune.GetUnicodeCategory(rune);
            if (Rune.IsWhiteSpace(rune) || rune.Value is '\r' or '\n' or '\t')
            {
                pendingSpace = sb.Length > 0;
                continue;
            }
            if (category is UnicodeCategory.Control or UnicodeCategory.Format or UnicodeCategory.PrivateUse or UnicodeCategory.OtherNotAssigned
                or UnicodeCategory.Surrogate or UnicodeCategory.LineSeparator or UnicodeCategory.ParagraphSeparator) continue;
            if (pendingSpace) sb.Append(' ');
            pendingSpace = false;
            sb.Append(rune.ToString());
        }
        return Cut(sb.ToString(), max);
    }

    /// <summary>Only the characters XML can't hold out, the rest untouched: for text already meant to be shown (it may have line breaks).</summary>
    public static string ForXml(string? text)
    {
        if (string.IsNullOrEmpty(text)) return "";
        var sb = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1])) sb.Append(c).Append(text[++i]);
            else if (!char.IsSurrogate(c) && System.Xml.XmlConvert.IsXmlChar(c)) sb.Append(c);
        }
        return sb.ToString();
    }

    /// <summary>"C:\Users\me\Taxes\return.pdf" or "https://host/a/b.pdf?token=x" as the file's name; a plain title stays as it is.</summary>
    private static string LastPart(string text)
    {
        var isAddress = text.Contains("://", StringComparison.Ordinal);
        var isPath = text.StartsWith(@"\\", StringComparison.Ordinal) || (text.Length > 2 && char.IsAsciiLetter(text[0]) && text[1] == ':' && text[2] is '\\' or '/');
        if (!isAddress && !isPath) return text;
        var end = isAddress ? text.IndexOfAny(['?', '#']) : -1;
        var path = (end >= 0 ? text[..end] : text).TrimEnd('/', '\\');
        var last = path[(path.LastIndexOfAny(['/', '\\']) + 1)..];
        return last.Length > 0 && !last.EndsWith(':') ? last : text;
    }

    /// <summary>At most <paramref name="max"/> UTF-16 units, cut between whole characters (a pair or an accent is never split).</summary>
    private static string Cut(string text, int max)
    {
        if (text.Length <= max) return text;
        var end = 0;
        while (end < text.Length)
        {
            var length = StringInfo.GetNextTextElementLength(text.AsSpan(end));
            if (end + length > max - 1) break;
            end += length;
        }
        return text[..end].TrimEnd() + "…";
    }
}
