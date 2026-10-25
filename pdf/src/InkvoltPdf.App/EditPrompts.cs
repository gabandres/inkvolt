using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// The WPF adapter of the edit transaction's questions (<see cref="IEditPrompts"/>): dialogs owned by the tab's window.
/// </summary>
internal sealed class TabEditPrompts(DocumentTab tab) : IEditPrompts
{
    private Window? Owner => Window.GetWindow(tab);

    public bool ConfirmSignedEdit() =>
        Prompt.Confirm(Owner, "This document is digitally signed",
            "Any change invalidates its signatures: they will no longer verify. To keep the signed original, save your changes as a copy (Save As).",
            "Edit anyway", warning: true);

    public OpenPasswordAnswer? AskOpenPassword(byte[] data) => SecurityActions.PromptOpenPassword(Owner, tab.Session.DisplayName, data);

    public string? AskOwnerPassword(bool wrong) => PdfFiles.PromptOwnerPassword(Owner!, tab.Session.DisplayName, wrong);

    public bool ConfirmSignatureRewrite(string label, int signatures, string reason)
    {
        Log.Write($"{label}: {reason}");
        return Prompt.Confirm(Owner, "This edit breaks the signatures",
            $"This edit can't be added to the signed file as an update, so saving it will invalidate {(signatures == 1 ? "its signature" : $"its {signatures} signatures")}: they will no longer verify. Continue? To keep the signed original, save your changes as a copy (Save As).",
            "Edit anyway", warning: true);
    }

    public bool ConfirmBreakingEdit(string label, IReadOnlyList<SignatureInfo> broken)
    {
        var who = broken.Count == 1 ? $"the signature of {broken[0].SignerName ?? broken[0].FieldName}" : $"{broken.Count} signatures";
        return Prompt.Confirm(Owner, $"{label} invalidates {who}",
            "A signature allows filling in forms, comments and more signatures afterwards, but not this change: it alters what was signed, " +
            "or it can't be added without rewriting the file. Afterwards the signature shows as invalid.\n\n" +
            "To keep the signed original, undo the change, or save your changes as a copy (Save As).",
            $"{label} anyway", warning: true);
    }
}
