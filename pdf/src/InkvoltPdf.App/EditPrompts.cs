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
        Prompt.Confirm(Owner, Strings.Prompt_SignedTitle,
            Strings.Prompt_SignedBody,
            Strings.Prompt_EditAnyway, warning: true);

    public OpenPasswordAnswer? AskOpenPassword(byte[] data) => SecurityActions.PromptOpenPassword(Owner, tab.Session.DisplayName, data);

    public string? AskOwnerPassword(bool wrong) => PdfFiles.PromptOwnerPassword(Owner!, tab.Session.DisplayName, wrong);

    public bool ConfirmSignatureRewrite(string label, int signatures, string reason)
    {
        Log.Write($"{label}: {reason}");
        return Prompt.Confirm(Owner, Strings.Prompt_RewriteTitle,
            Loc.Plural(signatures, Strings.Prompt_RewriteBody_One, Strings.Prompt_RewriteBody_Many),
            Strings.Prompt_EditAnyway, warning: true);
    }

    public bool ConfirmBreakingEdit(string label, IReadOnlyList<SignatureInfo> broken)
    {
        var title = broken.Count == 1 ? Loc.Format(Strings.Prompt_BreaksSignatureOf, label, broken[0].SignerName ?? broken[0].FieldName)
            : Loc.Format(Strings.Prompt_BreaksSignatures, label, broken.Count);
        return Prompt.Confirm(Owner, title,
            Strings.Prompt_BreakingBody,
            Loc.Format(Strings.Prompt_EditAnywayNamed, label), warning: true);
    }
}
