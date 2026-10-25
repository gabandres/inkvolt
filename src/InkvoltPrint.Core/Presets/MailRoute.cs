namespace InkvoltPrint.Core.Presets;

/// <summary>What the PC's mail setup looks like, read from the registry by the app.</summary>
/// <param name="MapiClient">The registered Simple MAPI client (<c>Software\Clients\Mail</c> default value, per user then per machine).</param>
/// <param name="OutlookHasProfile">Classic Outlook has a mail profile (<c>Office\1x.0\Outlook\Profiles</c> has one); null when unknown.</param>
public sealed record MailSetup(string? MapiClient, bool? OutlookHasProfile);

public enum MailRouteKind
{
    /// <summary><c>MAPISendMailW</c>: a new message with the files attached.</summary>
    Mapi,

    /// <summary>The folder opens with the file selected, and a <c>mailto:</c> message starts; the user attaches the file.</summary>
    FolderAndMailto,
}

/// <summary>
/// How "Email it" reaches the mail app. Simple MAPI attaches the files whenever a MAPI client is registered (Thunderbird, eM
/// Client, classic Outlook…), whatever app handles mailto links, except classic Outlook without a mail profile: it shows
/// "create a profile" (modal, for minutes) and then fails. That, and no MAPI client at all, go the mailto way at once.
/// </summary>
public static class MailRoute
{
    public static (MailRouteKind Kind, string Why) Choose(MailSetup setup)
    {
        if (string.IsNullOrWhiteSpace(setup.MapiClient)) return (MailRouteKind.FolderAndMailto, "no Simple MAPI mail client is registered");
        if (IsClassicOutlook(setup.MapiClient) && setup.OutlookHasProfile == false)
            return (MailRouteKind.FolderAndMailto, "the Simple MAPI client is classic Outlook, which has no mail profile");
        return (MailRouteKind.Mapi, $"Simple MAPI ({setup.MapiClient})");
    }

    public static bool IsClassicOutlook(string? mapiClient) => string.Equals(mapiClient?.Trim(), "Microsoft Outlook", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The mailto link for the fallback: the subject, and a body naming the file(s) to attach (a reminder; mailto can't attach).
    /// </summary>
    public static string MailtoUri(string subject, IReadOnlyList<string> fileNames) =>
        $"mailto:?subject={Uri.EscapeDataString(subject)}&body={Uri.EscapeDataString(AttachLine(fileNames))}";

    public static string AttachLine(IReadOnlyList<string> fileNames) => $"Attached: {string.Join(", ", fileNames)}";
}
