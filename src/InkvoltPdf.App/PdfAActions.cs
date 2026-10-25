using System.IO;
using System.Windows;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// File › Save as PDF/A-2b: an archival copy of the document as it is now (edits included), made by <see cref="PdfA"/>;
/// the open document isn't changed. When something can't be made conforming without changing the look, nothing is saved
/// and the reasons are listed.
/// </summary>
internal static class PdfAActions
{
    public static async Task SaveAs(MainWindow host, DocumentTab tab)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        var data = tab.Session.Data;
        var password = tab.Session.Password;
        var name = Path.GetFileNameWithoutExtension(tab.Session.DisplayName);

        PdfAResult? result = null;
        var wrong = false;
        using (var busy = tab.BeginBusy("Making a PDF/A copy…"))
        {
            while (result is null)
            {
                try
                {
                    var pw = password;
                    result = await Task.Run(() => PdfA.Convert(data, pw));
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
                    Prompt.Info(host, "Can't save as PDF/A-2b",
                        "Nothing was saved. This document has what PDF/A-2b doesn't allow, and changing it would change how the document looks:\n\n" +
                        string.Join("\n", ex.Blockers.Select(b => "• " + b)));
                    return;
                }
                catch (Exception ex) when (ex is InvalidOperationException or PdfSharp.PdfSharpException or MuPDFCore.MuPDFException)
                {
                    Log.Write($"PDF/A failed: {ex}");
                    Prompt.Error(host, "Can't save as PDF/A-2b", ex.Message);
                    return;
                }
            }
        }

        var folder = Path.GetDirectoryName(tab.Session.FilePath) ?? AppSettings.Current.LastFolder;
        if (PdfFiles.PickSavePath(host, $"{name} (PDF-A).pdf", folder) is not { } path) return;
        if (string.Equals(Path.GetFullPath(path), tab.Session.FilePath, StringComparison.OrdinalIgnoreCase))
        {
            Prompt.Info(host, "Choose another name", "The PDF/A copy can't replace the open document. Choose another name or folder.");
            return;
        }
        try
        {
            await Task.Run(() => AtomicFile.WriteAllBytes(path, result.Data));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(host, "Can't save the PDF/A copy", $"{ex.Message}\n\nIf the file is open in another program, close it there or choose another name.");
            return;
        }
        Log.Write($"PDF/A: saved {Log.Name(path)}; {string.Join("; ", result.Changes)}");
        var open = Prompt.Confirm(host, "Saved as PDF/A-2b",
            $"{Path.GetFileName(path)} is an archival copy (PDF/A-2b). To get there:\n\n{string.Join("\n", result.Changes.Select(c => "• " + char.ToUpperInvariant(c[0]) + c[1..]))}\n\n" +
            "Inkvolt PDF checks the rules it changes; for a formal check, use a PDF/A validator such as veraPDF.", "Open the Copy");
        if (open) await host.OpenFileAsync(path);
    }

    private static string? AskOwnerPassword(Window owner, string name, bool wrong)
    {
        var dlg = new FormDialog(owner, "Permissions password required", "Continue");
        if (wrong) dlg.AddNote("That password is incorrect. Try again.");
        dlg.AddNote($"A PDF/A copy can't be password protected, so making one of \"{name}\" needs its permissions (owner) password.");
        var box = dlg.Add("Password", new System.Windows.Controls.PasswordBox());
        dlg.Loaded += (_, _) => box.Focus();
        return dlg.ShowModal() ? box.Password : null;
    }
}
