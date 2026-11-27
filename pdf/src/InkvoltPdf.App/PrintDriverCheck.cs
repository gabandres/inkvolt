using System.IO;
using System.Printing;
using System.Windows;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Windows.Printing;
using InkvoltPrint.Windows.Suite;

namespace InkvoltPdf.App;

/// <summary>
/// Before printing: whether Windows can use the printer's driver (<see cref="QueueDriver"/>). A Windows update can leave a driver
/// Windows can't load, and then nothing prints to that printer, the Windows print dialog included, until it is added again. Said
/// before the dialog opens (for the default printer) and once a printer is chosen in the classic one, with what to do: print
/// with Inkvolt Print, which sends the pages straight to a network printer, when it's installed; choose another printer; or
/// fix the printer in Windows.
/// </summary>
internal static class PrintDriverCheck
{
    /// <summary>The default printer's queue, or null when there is none or the spooler won't say.</summary>
    public static QueueInfo? DefaultQueue()
    {
        try
        {
            using var queue = LocalPrintServer.GetDefaultPrintQueue();
            return PrinterCheck.Describe(queue);
        }
        catch (Exception ex) when (ex is PrintSystemException or InvalidOperationException)
        {
            return null;
        }
    }

    /// <summary>
    /// True to go on printing: the queue's driver works, or the person chose to pick another printer (<paramref name="chosen"/>
    /// false: before the dialog). False when it doesn't work and the person printed with Inkvolt Print or cancelled.
    /// </summary>
    public static async Task<bool> ProceedAsync(Window owner, DocumentTab tab, QueueInfo? info, bool chosen)
    {
        if (info?.Name is not { } queue || await Task.Run(() => QueueDriver.Problem(queue)) is not { } problem) return true;
        Log.Write($"Print: Windows can't use the driver for {queue} ({problem})"); // Windows' words for the log only
        // Inkvolt Print prints it straight to the printer when it knows the printer (a network printer it found), not to a virtual queue.
        var handOver = tab.Session.IsPdf && tab.Session.Password is null && Inkvolt.InkvoltPrintPath is not null
            && await PrinterCheck.KnownPrinterAsync(info) is not null;
        var offered = PrintDriverChoices.Offered(handOver, chosen);
        var body = Strings.Print_DriverBrokenBody + Environment.NewLine + Environment.NewLine
            + (handOver ? Strings.Print_DriverBrokenHandOver : Strings.Print_DriverBrokenFix);
        var buttons = offered.Select((choice, i) => (choice switch
        {
            PrintDriverChoice.HandOver => Strings.Print_WithInkvoltPrint,
            PrintDriverChoice.ChooseAnother => Strings.Print_ChooseAnotherPrinter,
            _ => PrintDriverChoices.StopOnlyCloses(offered) ? Strings.Common_Close : Strings.Common_Cancel,
        }, Accent: i == 0)).ToArray(); // the first is the way on; alone, Close
        switch (offered[Prompt.Choose(owner, Loc.Format(Strings.Print_DriverBrokenTitle, queue), body, buttons)])
        {
            case PrintDriverChoice.ChooseAnother:
                return true;
            case PrintDriverChoice.HandOver:
                await HandOverAsync(owner, tab, queue);
                return false;
            default:
                return false;
        }
    }

    /// <summary>
    /// Opens the document in Inkvolt Print's Print tab for the printer of <paramref name="queue"/>: the file itself when it's saved,
    /// else a copy as it is now (in a folder of its own under the temporary files, emptied of copies a day old).
    /// </summary>
    private static async Task HandOverAsync(Window owner, DocumentTab tab, string queue)
    {
        var session = tab.Session;
        string path;
        try
        {
            if (session.FilePath is { } saved && !session.IsDirty && File.Exists(saved) && saved.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase))
                path = saved;
            else
            {
                var folder = Path.Combine(Path.GetTempPath(), "Inkvolt PDF", "Print");
                var data = session.Data;
                path = await Task.Run(() =>
                {
                    Directory.CreateDirectory(folder);
                    foreach (var old in Directory.EnumerateFiles(folder, "*.pdf"))
                        try { if (DateTime.UtcNow - File.GetLastWriteTimeUtc(old) > TimeSpan.FromDays(1)) File.Delete(old); }
                        catch (IOException) { } // still open in Inkvolt Print
                        catch (UnauthorizedAccessException) { }
                    var name = string.Concat(Path.GetFileNameWithoutExtension(session.DisplayName).Split(Path.GetInvalidFileNameChars()));
                    var copy = Path.Combine(folder, $"{(name.Length == 0 ? "Document" : name)} {Guid.NewGuid().ToString("N")[..6]}.pdf");
                    File.WriteAllBytes(copy, data);
                    return copy;
                });
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Print: copy for Inkvolt Print failed: {ex.Message}");
            Prompt.Error(owner, Strings.Print_Failed, Strings.Print_HandOverFailed);
            return;
        }
        Log.Write($"Print: handed to Inkvolt Print for {queue}");
        if (!InkvoltApps.Launch(InkvoltApps.InkvoltPrint, path, "--queue", queue))
            Prompt.Error(owner, Strings.Print_Failed, Strings.Main_InkvoltPrintFailed);
    }
}
