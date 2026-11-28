using System.IO;
using System.Windows.Interop;
using InkvoltPdf.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage;

namespace InkvoltPdf.App;

/// <summary>
/// File › Share… (the Mac's Share…): the document to Windows' share sheet (DataTransferManager through the window's
/// interop). A saved file is shared as it is; with changes not saved, the person chooses to save first or to share a
/// copy with them (<see cref="DocumentShare"/>); a document never saved is shared as a copy.
/// </summary>
internal static class ShareActions
{
    /// <summary>Set by the developer script: the file that would go to the share sheet, which isn't opened.</summary>
    internal static Action<string>? DevShared;

    public static async Task Share(MainWindow host, DocumentTab tab, Func<DocumentTab, Task<bool>> save)
    {
        if (!tab.Session.IsPdf || !await tab.SettleAsync()) return;
        string path;
        switch (DocumentShare.SourceFor(tab.Session.FilePath, tab.Session.IsDirty))
        {
            case ShareSource.SavedFile:
                path = tab.Session.FilePath!;
                break;
            case ShareSource.AskSaveOrCopy:
            {
                var choice = Prompt.Choose(host, Loc.Format(Strings.Share_UnsavedTitle, tab.Session.DisplayName), Strings.Share_UnsavedBody,
                    (Strings.Share_SaveAndShare, true), (Strings.Share_Copy, false), (Strings.Common_Cancel, false));
                if (choice == 0)
                {
                    if (!await save(tab) || tab.Session.FilePath is not { } saved) return;
                    path = saved;
                }
                else if (choice == 1 && WriteCopy(host, tab) is { } copy) path = copy;
                else return;
                break;
            }
            default:
                if (WriteCopy(host, tab) is not { } fresh) return;
                path = fresh;
                break;
        }
        Log.Write($"Share {Log.Name(path)}");
        if (DevShared is { } dev)
        {
            dev(path);
            return;
        }
        await ShowSheet(host, path);
    }

    private static string? WriteCopy(MainWindow host, DocumentTab tab)
    {
        try
        {
            return DocumentShare.WriteCopy(Path.GetTempPath(), tab.Session.DisplayName, tab.Session.Data, DateTime.UtcNow);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Prompt.Error(host, Loc.Format(Strings.Share_CantTitle, tab.Session.DisplayName), ex.Message);
            return null;
        }
    }

    private static async Task ShowSheet(MainWindow host, string path)
    {
        var name = Path.GetFileName(path);
        try
        {
            var file = await StorageFile.GetFileFromPathAsync(path);
            var hwnd = new WindowInteropHelper(host).Handle;
            var manager = DataTransferManagerInterop.GetForWindow(hwnd);
            void OnRequested(DataTransferManager sender, DataRequestedEventArgs e)
            {
                sender.DataRequested -= OnRequested; // one request per Share…
                e.Request.Data.Properties.Title = name;
                e.Request.Data.SetStorageItems([file]);
            }
            manager.DataRequested += OnRequested;
            DataTransferManagerInterop.ShowShareUIForWindow(hwnd);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.COMException)
        {
            Log.Write($"Share failed: {ex.Message}");
            Prompt.Error(host, Loc.Format(Strings.Share_CantTitle, name), Strings.Share_CantBody);
        }
    }
}
