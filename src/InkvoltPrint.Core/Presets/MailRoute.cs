namespace InkvoltPrint.Core.Presets;

/// <summary>What the PC's mail setup looks like, read from the registry by the app.</summary>
/// <param name="MapiClient">The registered Simple MAPI client (<c>Software\Clients\Mail</c> default value, per user then per machine).</param>
/// <param name="MailtoProgId">The user's mailto handler (<c>UrlAssociations\mailto\UserChoice</c> ProgId).</param>
/// <param name="MailtoAppId">That ProgId's <c>Application\AppUserModelID</c> (packaged apps such as the new Outlook).</param>
/// <param name="OutlookHasProfile">Classic Outlook has a mail profile (<c>Office\1x.0\Outlook\Profiles</c> has one); null when unknown.</param>
public sealed record MailSetup(string? MapiClient, string? MailtoProgId, string? MailtoAppId, bool? OutlookHasProfile);

public enum MailRouteKind
{
    /// <summary><c>MAPISendMailW</c>: a new message with the files attached.</summary>
    Mapi,

    /// <summary>The folder opens with the file selected, and a <c>mailto:</c> message starts; the user attaches the file.</summary>
    FolderAndMailto,
}

/// <summary>
/// How "Email it" reaches the mail app. Simple MAPI attaches the files, but only when the MAPI client is the one the user
/// mails with and can open a message: the new Outlook has no Simple MAPI (when it is the mailto handler, MAPI would start
/// classic Outlook instead), and classic Outlook without a mail profile shows "create a profile" (modal, minutes) and then
/// fails. Those go the mailto way at once.
/// </summary>
public static class MailRoute
{
    public static (MailRouteKind Kind, string Why) Choose(MailSetup setup)
    {
        if (string.IsNullOrWhiteSpace(setup.MapiClient)) return (MailRouteKind.FolderAndMailto, "no Simple MAPI mail client is registered");
        if (IsNewOutlook(setup.MailtoProgId, setup.MailtoAppId))
            return (MailRouteKind.FolderAndMailto, "the default mail app is the new Outlook, which has no Simple MAPI");
        if (IsClassicOutlook(setup.MapiClient) && setup.OutlookHasProfile == false)
            return (MailRouteKind.FolderAndMailto, "classic Outlook has no mail profile");
        return (MailRouteKind.Mapi, $"Simple MAPI ({setup.MapiClient})");
    }

    /// <summary>The new Outlook (a packaged app, <c>Microsoft.OutlookForWindows_…</c>).</summary>
    public static bool IsNewOutlook(string? progId, string? appId) =>
        appId?.StartsWith("Microsoft.OutlookForWindows", StringComparison.OrdinalIgnoreCase) == true
        || progId?.StartsWith("Microsoft.OutlookForWindows", StringComparison.OrdinalIgnoreCase) == true;

    public static bool IsClassicOutlook(string? mapiClient) => string.Equals(mapiClient?.Trim(), "Microsoft Outlook", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The mailto link for the fallback: the subject, and a body naming the file(s) to attach (a reminder; mailto can't attach).
    /// </summary>
    public static string MailtoUri(string subject, IReadOnlyList<string> fileNames) =>
        $"mailto:?subject={Uri.EscapeDataString(subject)}&body={Uri.EscapeDataString(AttachLine(fileNames))}";

    public static string AttachLine(IReadOnlyList<string> fileNames) =>
        fileNames.Count == 1 ? $"Attached: {fileNames[0]}" : $"Attached: {string.Join(", ", fileNames)}";
}
