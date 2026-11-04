using System.IO;
using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// File › Save as PDF/A-2b, and Save as PDF/A-2a (the accessible archive: the tags kept, Make Accessible first when there
/// are none): an archival copy of the document as it is now (edits included), made by <see cref="PdfA"/>; the open
/// document isn't changed. When something can't be made conforming without changing the look, nothing is saved and the
/// reasons are listed.
/// </summary>
internal static class PdfAActions
{
    public static async Task SaveAs(MainWindow host, DocumentTab tab, PdfAConformance conformance = PdfAConformance.B)
    {
        if (!tab.Session.IsPdf || conformance == PdfAConformance.A && !ProGate.Check(host, ProFeature.AccessibleOutput) || !await tab.SettleAsync()) return;
        var level = conformance == PdfAConformance.A ? "PDF/A-2a" : "PDF/A-2b";
        if (conformance == PdfAConformance.A && !await Task.Run(() => AutoTag.IsTagged(tab.Session.Data, tab.Session.Password)))
        {
            if (!Prompt.Confirm(host, Strings.PdfA_TagFirstTitle,
                    Strings.PdfA_TagFirstBody, Strings.PdfA_MakeAccessible)) return;
            if (!await AccessibleActions.MakeAccessible(host, tab)) return;
            if (!await tab.SettleAsync()) return;
        }
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);

        PdfAResult? result = null;
        var wrong = false;
        using (var busy = tab.BeginBusy(Strings.PdfA_Making))
        {
            while (result is null)
            {
                try
                {
                    var pw = password;
                    result = await Task.Run(() => PdfA.Convert(data, pw, conformance: conformance));
                }
                catch (OwnerPasswordRequiredException ex)
                {
                    // Opened for viewing only: the copy is unencrypted, so its permissions password is needed.
                    if (AskOwnerPassword(host, tab.Session.DisplayName, wrong || ex.WrongPassword && password is not null) is not { } owner) return;
                    password = owner;
                    wrong = true;
                }
                catch (PdfAException ex)
                {
                    Log.Write($"PDF/A: {Log.Name(tab.Session.FilePath)} refused: {string.Join(" ", ex.Blockers)}");
                    Prompt.Info(host, Loc.Format(Strings.PdfA_CantSaveAs, level),
                        Loc.Format(Strings.PdfA_Blocked, level, string.Join("\n", ex.Blockers.Select(b => "• " + b))));
                    return;
                }
                catch (Exception ex) when (ex is InvalidOperationException or PdfSharp.PdfSharpException or MuPDFCore.MuPDFException)
                {
                    Log.Write($"PDF/A failed: {ex}");
                    Prompt.Error(host, Loc.Format(Strings.PdfA_CantSaveAs, level), ex.Message);
                    return;
                }
            }
        }

        var folder = Path.GetDirectoryName(tab.Session.FilePath) ?? AppSettings.Current.LastFolder;
        if (PdfFiles.PickSavePath(host, conformance == PdfAConformance.A ? Loc.Format(Strings.PdfA_FileName2a, name) : Loc.Format(Strings.PdfA_FileName, name), folder) is not { } path) return;
        if (string.Equals(Path.GetFullPath(path), tab.Session.FilePath, StringComparison.OrdinalIgnoreCase))
        {
            Prompt.Info(host, Strings.PdfA_ChooseAnotherName, Strings.PdfA_CantReplace);
            return;
        }
        try
        {
            await Task.Run(() => AtomicFile.WriteAllBytes(path, result.Data));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(host, Strings.PdfA_CantSaveCopy, Loc.Format(Strings.PdfA_SaveFailed, ex.Message));
            return;
        }
        Log.Write($"PDF/A: saved {Log.Name(path)}; {string.Join("; ", result.Changes)}");
        var open = Prompt.Confirm(host, Loc.Format(Strings.PdfA_SavedAs, level),
            Loc.Format(conformance == PdfAConformance.A ? Strings.PdfA_SavedBodyTagged : Strings.PdfA_SavedBody, Path.GetFileName(path), level,
                string.Join("\n", result.Changes.Select(c => "• " + char.ToUpperInvariant(c[0]) + c[1..]))), Strings.PdfA_OpenCopy);
        if (open) await host.OpenFileAsync(path);
    }

    private static string? AskOwnerPassword(Window owner, string name, bool wrong)
    {
        var dlg = new FormDialog(owner, Strings.PdfA_PasswordTitle, Strings.Common_Continue);
        if (wrong) dlg.AddNote(Strings.PdfA_PasswordWrong);
        dlg.AddNote(Loc.Format(Strings.PdfA_PasswordNote, name));
        var box = dlg.Add(Strings.PdfA_Password, new System.Windows.Controls.PasswordBox());
        dlg.Loaded += (_, _) => box.Focus();
        return dlg.ShowModal() ? box.Password : null;
    }
}
