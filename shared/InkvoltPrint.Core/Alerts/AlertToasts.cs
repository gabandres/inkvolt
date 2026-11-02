using System.Security.Cryptography;
using System.Text;
using System.Xml.Linq;

namespace InkvoltPrint.Core.Alerts;

/// <summary>What a click on a toast, or on one of its buttons, asks for (<see cref="AlertToasts.ParseArguments"/>).</summary>
public enum ToastAction
{
    /// <summary>Open the printer (the toast's body, or its Open printer button).</summary>
    OpenPrinter,

    /// <summary>Pause alerts for an hour (the Pause alerts button).</summary>
    PauseAlerts,

    /// <summary>Open the printer's queue (a job's toast: its body, or its Open the queue button).</summary>
    OpenQueue,
}

/// <summary>
/// Inkvolt Print's alerts as Windows toast notifications (the <c>ToastGeneric</c> template), one toast per printer, with
/// <b>Open printer</b> and <b>Pause alerts</b> buttons, and one per print job with <b>Open the queue</b> and <b>Pause alerts</b>
/// (or, when more than <see cref="MaxJobToasts"/> jobs of one printer come at once, one for all of them). Pure text: the XML a
/// toast is made from, the arguments its clicks carry back, and the tag that lets a newer alert for the same printer replace
/// the one still showing, which a job's toast neither does nor suffers. The app's <c>Tray/ToastAlerts</c> hands them to WinRT;
/// <see cref="AlertTracker"/> decides what is alerted on. Text from outside the app can't break the XML: what XML can't hold is
/// left out (<see cref="AlertText.ForXml"/>), the rest is escaped.
/// </summary>
public static class AlertToasts
{
    public const string Group = "alerts";
    public const string OpenPrinterText = "Open printer", PauseAlertsText = "Pause alerts", OpenQueueText = "Open the queue";

    /// <summary>More jobs than this from one printer at once share a toast: a dead printer doesn't fill the screen.</summary>
    public const int MaxJobToasts = 3;

    public static readonly TimeSpan PauseFor = TimeSpan.FromHours(1);

    private const string OpenPrefix = "open:", PausePrefix = "pause:", QueuePrefix = "queue:";

    /// <summary>The notices as toasts, in the order the printers first appear: a printer's problems together, then its jobs.</summary>
    public static IReadOnlyList<IReadOnlyList<AlertNotice>> PerPrinter(IReadOnlyList<AlertNotice> notices)
    {
        var toasts = new List<IReadOnlyList<AlertNotice>>();
        foreach (var printer in notices.GroupBy(n => n.Uuid, StringComparer.OrdinalIgnoreCase))
        {
            if (printer.Where(n => n.JobKey is null).ToList() is { Count: > 0 } problems) toasts.Add(problems);
            var jobs = printer.Where(n => n.JobKey is not null).ToList();
            if (jobs.Count > MaxJobToasts) toasts.Add(jobs);
            else toasts.AddRange(jobs.Select(j => (IReadOnlyList<AlertNotice>)[j]));
        }
        return toasts;
    }

    /// <summary>One toast's title and text: one alert as it is; several, a count and a line per alert (for jobs, the first few).</summary>
    public static (string Title, string Text) Text(IReadOnlyList<AlertNotice> notices)
    {
        if (notices.Count == 1) return (notices[0].Title, notices[0].Body);
        if (notices[0].JobKey is null) return ($"{notices.Count} alerts", string.Join("\n", notices.Select(n => n.Title)));
        var lines = notices.Take(MaxJobToasts).Select(n => n.Title).ToList();
        if (notices.Count > lines.Count) lines.Add($"and {notices.Count - lines.Count} more");
        return ($"{notices.Count} print jobs need attention", string.Join("\n", lines));
    }

    /// <summary>
    /// The toast for one printer's notices (all with one <see cref="AlertNotice.Uuid"/>): title, text, the printer's name
    /// as the attribution line, and the two buttons; the body and Open printer carry <c>open:UUID</c>, Pause alerts
    /// <c>pause:UUID</c>, all foreground activations (handled in the running app). <paramref name="iconPath"/>: an image
    /// file for the app logo, or null for the app's own icon. A job's toast says Open the queue and carries <c>queue:UUID</c> instead.
    /// </summary>
    public static string Xml(IReadOnlyList<AlertNotice> notices, string? iconPath = null)
    {
        if (notices.Count == 0) throw new ArgumentException("A toast needs at least one alert.", nameof(notices));
        var uuid = AlertText.ForXml(notices[0].Uuid);
        var (title, text) = Text(notices);
        var (open, openPrefix) = notices[0].JobKey is null ? (OpenPrinterText, OpenPrefix) : (OpenQueueText, QueuePrefix);
        var binding = new XElement("binding", new XAttribute("template", "ToastGeneric"),
            new XElement("text", AlertText.ForXml(title)),
            new XElement("text", AlertText.ForXml(text)),
            new XElement("text", new XAttribute("placement", "attribution"), AlertText.ForXml(notices[0].PrinterName)));
        if (iconPath is not null)
            binding.Add(new XElement("image", new XAttribute("placement", "appLogoOverride"), new XAttribute("src", iconPath)));
        var toast = new XElement("toast",
            new XAttribute("launch", openPrefix + uuid),
            new XAttribute("activationType", "foreground"),
            new XElement("visual", binding),
            new XElement("actions",
                new XElement("action", new XAttribute("content", open), new XAttribute("arguments", openPrefix + uuid), new XAttribute("activationType", "foreground")),
                new XElement("action", new XAttribute("content", PauseAlertsText), new XAttribute("arguments", PausePrefix + uuid), new XAttribute("activationType", "foreground"))));
        return toast.ToString(SaveOptions.DisableFormatting);
    }

    /// <summary>What a toast's arguments ask for and which printer, or null for arguments that aren't ours.</summary>
    public static (ToastAction Action, string Uuid)? ParseArguments(string? arguments)
    {
        if (string.IsNullOrEmpty(arguments)) return null;
        if (arguments.StartsWith(OpenPrefix, StringComparison.Ordinal) && arguments.Length > OpenPrefix.Length) return (ToastAction.OpenPrinter, arguments[OpenPrefix.Length..]);
        if (arguments.StartsWith(PausePrefix, StringComparison.Ordinal) && arguments.Length > PausePrefix.Length) return (ToastAction.PauseAlerts, arguments[PausePrefix.Length..]);
        if (arguments.StartsWith(QueuePrefix, StringComparison.Ordinal) && arguments.Length > QueuePrefix.Length) return (ToastAction.OpenQueue, arguments[QueuePrefix.Length..]);
        return null;
    }

    /// <summary>
    /// The toast's tag for a printer: a newer alert for the same printer replaces the one showing. At most 16 characters
    /// (older Windows 10 builds allow no more), so a hash of the UUID, not the UUID.
    /// </summary>
    public static string Tag(string uuid) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(uuid.Trim().ToLowerInvariant())))[..16];

    /// <summary>The tag of one toast from <see cref="PerPrinter"/>: a job's is its own, so it replaces neither the printer's alert nor another job's.</summary>
    public static string Tag(IReadOnlyList<AlertNotice> toast) =>
        toast[0].JobKey is not { } job ? Tag(toast[0].Uuid) : Tag($"{toast[0].Uuid}|{(toast.Count == 1 ? job : "jobs")}");
}
