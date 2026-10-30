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
}

/// <summary>
/// Inkvolt Print's alerts as Windows toast notifications (the <c>ToastGeneric</c> template), one toast per printer, with
/// <b>Open printer</b> and <b>Pause alerts</b> buttons. Pure text: the XML a toast is made from, the arguments its clicks
/// carry back, and the tag that lets a newer alert for the same printer replace the one still showing. The app's
/// <c>Tray/ToastAlerts</c> hands them to WinRT; <see cref="AlertTracker"/> decides what is alerted on, unchanged.
/// </summary>
public static class AlertToasts
{
    public const string Group = "alerts";
    public const string OpenPrinterText = "Open printer", PauseAlertsText = "Pause alerts";
    public static readonly TimeSpan PauseFor = TimeSpan.FromHours(1);

    private const string OpenPrefix = "open:", PausePrefix = "pause:";

    /// <summary>The notices grouped by printer, in the order the printers first appear.</summary>
    public static IReadOnlyList<IReadOnlyList<AlertNotice>> PerPrinter(IReadOnlyList<AlertNotice> notices) =>
        notices.GroupBy(n => n.Uuid, StringComparer.OrdinalIgnoreCase).Select(g => (IReadOnlyList<AlertNotice>)g.ToList()).ToList();

    /// <summary>One printer's title and text: one alert as it is; several, a count and a line per alert.</summary>
    public static (string Title, string Text) Text(IReadOnlyList<AlertNotice> notices) =>
        notices.Count == 1
            ? (notices[0].Title, notices[0].Body)
            : ($"{notices.Count} alerts", string.Join("\n", notices.Select(n => n.Title)));

    /// <summary>
    /// The toast for one printer's notices (all with one <see cref="AlertNotice.Uuid"/>): title, text, the printer's name
    /// as the attribution line, and the two buttons; the body and Open printer carry <c>open:UUID</c>, Pause alerts
    /// <c>pause:UUID</c>, all foreground activations (handled in the running app). <paramref name="iconPath"/>: an image
    /// file for the app logo, or null for the app's own icon.
    /// </summary>
    public static string Xml(IReadOnlyList<AlertNotice> notices, string? iconPath = null)
    {
        if (notices.Count == 0) throw new ArgumentException("A toast needs at least one alert.", nameof(notices));
        var uuid = notices[0].Uuid;
        var (title, text) = Text(notices);
        var binding = new XElement("binding", new XAttribute("template", "ToastGeneric"),
            new XElement("text", title),
            new XElement("text", text),
            new XElement("text", new XAttribute("placement", "attribution"), notices[0].PrinterName));
        if (iconPath is not null)
            binding.Add(new XElement("image", new XAttribute("placement", "appLogoOverride"), new XAttribute("src", iconPath)));
        var toast = new XElement("toast",
            new XAttribute("launch", OpenPrefix + uuid),
            new XAttribute("activationType", "foreground"),
            new XElement("visual", binding),
            new XElement("actions",
                new XElement("action", new XAttribute("content", OpenPrinterText), new XAttribute("arguments", OpenPrefix + uuid), new XAttribute("activationType", "foreground")),
                new XElement("action", new XAttribute("content", PauseAlertsText), new XAttribute("arguments", PausePrefix + uuid), new XAttribute("activationType", "foreground"))));
        return toast.ToString(SaveOptions.DisableFormatting);
    }

    /// <summary>What a toast's arguments ask for and which printer, or null for arguments that aren't ours.</summary>
    public static (ToastAction Action, string Uuid)? ParseArguments(string? arguments)
    {
        if (string.IsNullOrEmpty(arguments)) return null;
        if (arguments.StartsWith(OpenPrefix, StringComparison.Ordinal) && arguments.Length > OpenPrefix.Length) return (ToastAction.OpenPrinter, arguments[OpenPrefix.Length..]);
        if (arguments.StartsWith(PausePrefix, StringComparison.Ordinal) && arguments.Length > PausePrefix.Length) return (ToastAction.PauseAlerts, arguments[PausePrefix.Length..]);
        return null;
    }

    /// <summary>
    /// The toast's tag for a printer: a newer alert for the same printer replaces the one showing. At most 16 characters
    /// (older Windows 10 builds allow no more), so a hash of the UUID, not the UUID.
    /// </summary>
    public static string Tag(string uuid) =>
        Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(uuid.Trim().ToLowerInvariant())))[..16];
}
