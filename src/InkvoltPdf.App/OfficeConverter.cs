using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using InkvoltPdf.Core;

namespace InkvoltPdf.App;

/// <summary>
/// Office files to PDF with the user's own Microsoft Office (no converter of our own, no service): Word, Excel or
/// PowerPoint opens the file read-only and hidden, exports it as PDF (ExportAsFixedFormat) and closes it without saving.
/// The automation runs in a helper process (this exe with <c>--office-to-pdf</c>), so a stuck Office (a dialog nobody can
/// see) can't freeze the app: after a timeout, or when the user cancels, the helper and the Office it started are ended.
/// Word and Excel are started as new instances of their own (never the one the user works in: no GetActiveObject),
/// with macros disabled, alerts off and dummy passwords, so a protected file fails instead of asking. PowerPoint runs only
/// one copy at a time, so while it is open the conversion is refused rather than borrowing the user's PowerPoint.
/// Nothing here needs elevation (also packaged).
/// </summary>
internal static class OfficeConverter
{
    public const string ChildSwitch = "--office-to-pdf";

    /// <summary>Default time a conversion may take before Office is stopped.</summary>
    public static readonly TimeSpan Timeout = TimeSpan.FromMinutes(3);

    private static readonly Dictionary<OfficeApp, bool> Installed = [];

    private static string ProgId(OfficeApp app) => app switch
    {
        OfficeApp.Word => "Word.Application",
        OfficeApp.Excel => "Excel.Application",
        _ => "PowerPoint.Application",
    };

    private static string ProcessName(OfficeApp app) => app switch
    {
        OfficeApp.Word => "WINWORD",
        OfficeApp.Excel => "EXCEL",
        _ => "POWERPNT",
    };

    /// <summary>The Office app is installed (its automation class is registered).</summary>
    public static bool IsInstalled(OfficeApp app)
    {
        lock (Installed)
        {
            if (Installed.TryGetValue(app, out var known)) return known;
            bool found;
            try
            {
                found = Type.GetTypeFromProgID(ProgId(app)) is not null;
            }
            catch (Exception ex) when (ex is COMException or System.Security.SecurityException)
            {
                found = false;
            }
            Installed[app] = found;
            return found;
        }
    }

    public static IReadOnlyList<OfficeApp> InstalledApps => [.. Enum.GetValues<OfficeApp>().Where(IsInstalled)];

    /// <summary>What stops <paramref name="path"/> from being converted before Office is started, or null.</summary>
    public static string? Precheck(string path, OfficeApp app)
    {
        if (!IsInstalled(app)) return $"Opening this file needs {OfficeFiles.AppName(app)}, which isn't installed on this PC.";
        try
        {
            var head = new byte[8];
            using (var f = File.OpenRead(path)) _ = f.Read(head, 0, head.Length);
            if (OfficeFiles.IsEncryptedOpenXml(head, path))
                return $"This file is protected with a password. Open it in {OfficeFiles.AppName(app)}, then save it as PDF there (or save a copy without the password).";
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return ex.Message;
        }
        if (app == OfficeApp.PowerPoint && Process.GetProcessesByName(ProcessName(app)).Length > 0)
            return "PowerPoint is open. It runs one copy at a time, and Inkvolt PDF doesn't use the one you work in: close PowerPoint and try again.";
        return null;
    }

    /// <summary>
    /// Converts <paramref name="path"/> to PDF bytes through a helper process. Cancelling (or the timeout) ends the helper
    /// and the Office instance it started.
    /// </summary>
    /// <exception cref="InvalidOperationException">Office couldn't convert the file (the message says why).</exception>
    /// <exception cref="OperationCanceledException">Cancelled.</exception>
    public static async Task<byte[]> ConvertAsync(string path, OfficeApp app, CancellationToken cancel)
    {
        if (Precheck(path, app) is { } problem) throw new InvalidOperationException(problem);
        var dir = Directory.CreateTempSubdirectory("inkvolt-office-");
        var output = Path.Combine(dir.FullName, "out.pdf");
        var exe = Environment.ProcessPath ?? throw new InvalidOperationException("The app's own path is unknown.");
        var info = new ProcessStartInfo(exe)
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var a in new[] { ChildSwitch, app.ToString(), Path.GetFullPath(path), output }) info.ArgumentList.Add(a);
        int officePid = 0;
        string? error = null;
        var before = Pids(app);
        using var child = Process.Start(info) ?? throw new InvalidOperationException("The conversion helper didn't start.");
        try
        {
            var reading = Task.Run(async () =>
            {
                while (await child.StandardOutput.ReadLineAsync() is { } line)
                {
                    if (line.StartsWith("pid ", StringComparison.Ordinal) && int.TryParse(line[4..], out var pid)) Volatile.Write(ref officePid, pid);
                    else if (line.StartsWith("error ", StringComparison.Ordinal)) error = line[6..];
                }
            }, CancellationToken.None);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            timeout.CancelAfter(Timeout);
            try
            {
                await child.WaitForExitAsync(timeout.Token);
                await reading;
            }
            catch (OperationCanceledException)
            {
                await StopAsync(child, () => Volatile.Read(ref officePid), before, app);
                cancel.ThrowIfCancellationRequested();
                throw new InvalidOperationException($"{OfficeFiles.AppName(app)} didn't finish within {Timeout.TotalMinutes:0} minutes (it may have stopped to ask something), so it was closed.");
            }
            if (child.ExitCode != 0 || !File.Exists(output))
                throw new InvalidOperationException(error ?? $"{OfficeFiles.AppName(app)} couldn't save this file as PDF.");
            return await File.ReadAllBytesAsync(output, CancellationToken.None);
        }
        finally
        {
            try { dir.Delete(true); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Log.Write($"Office temp folder left: {ex.Message}"); }
        }
    }

    /// <summary>
    /// Ends the helper and the Office instance it started. Office may still be starting (its process not known yet): wait
    /// for the helper to name it, a while; else take the hidden instances of that app that appeared since the helper
    /// started (one the user starts has a window). Never one that was running before.
    /// </summary>
    private static async Task StopAsync(Process child, Func<int> reportedPid, HashSet<int> before, OfficeApp app)
    {
        for (var i = 0; i < 200 && reportedPid() <= 0 && !child.HasExited; i++) await Task.Delay(100, CancellationToken.None);
        var exitedByItself = child.HasExited;
        try
        {
            if (!exitedByItself) child.Kill(entireProcessTree: true);
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        if (exitedByItself) return; // it closed Office itself
        var pids = reportedPid() is > 0 and var known ? [known] : Pids(app).Except(before).ToList();
        foreach (var pid in pids)
        {
            try
            {
                using var office = Process.GetProcessById(pid);
                if (!string.Equals(office.ProcessName, ProcessName(app), StringComparison.OrdinalIgnoreCase) || before.Contains(pid)) continue;
                if (reportedPid() <= 0 && office.MainWindowHandle != IntPtr.Zero) continue; // not known to be ours, and visible: the user's
                office.Kill();
                Log.Write($"Office conversion: {ProcessName(app)} stopped");
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
    }

    // ───────────────────────────── helper process ─────────────────────────────

    private const int WdExportFormatPdf = 17, WdDoNotSaveChanges = 0, WdAlertsNone = 0, WdExportOptimizeForPrint = 0,
        WdExportCreateHeadingBookmarks = 1, MsoAutomationSecurityForceDisable = 3, XlTypePdf = 0, PpSaveAsPdf = 32,
        MsoTrue = -1, MsoFalse = 0;

    /// <summary>A password no file has: given to Office so a protected file fails to open instead of asking for one
    /// (printable and at most 15 characters: otherwise Excel refuses to open any file).</summary>
    private const string NoPassword = "Inkvolt-NoPw-7f";

    /// <summary>
    /// The helper (<c>InkvoltPdf.exe --office-to-pdf Word|Excel|PowerPoint input output</c>), without a window, on an STA
    /// thread of its own (not WPF's dispatcher thread). Prints "pid N" once Office runs (the process that appeared when the automation object was made;
    /// Word and Excel start a new one for each CreateObject), then "ok" or "error message". Returns the exit code.
    /// </summary>
    public static int RunChild(string[] args)
    {
        if (args.Length < 4 || !Enum.TryParse<OfficeApp>(args[1], out var app))
        {
            Console.Out.WriteLine("error Bad arguments.");
            return 2;
        }
        var code = 1;
        var worker = new Thread(() => code = Convert(app, args[2], args[3])) { IsBackground = true };
        worker.SetApartmentState(ApartmentState.STA);
        worker.Start();
        worker.Join();
        return code;
    }

    private static int Convert(OfficeApp app, string input, string output)
    {
        var before = Pids(app);
        object? instance = null;
        try
        {
            var type = Type.GetTypeFromProgID(ProgId(app)) ?? throw new InvalidOperationException($"{OfficeFiles.AppName(app)} isn't installed.");
            if (app == OfficeApp.PowerPoint && before.Count > 0) throw new InvalidOperationException("PowerPoint is open: close it and try again.");
            instance = Activator.CreateInstance(type) ?? throw new InvalidOperationException($"{OfficeFiles.AppName(app)} didn't start.");
            // Ours is the process that wasn't there before (Word and Excel always start a new one here). A user starting
            // the same app in this second could be mistaken for it; it would only be stopped if the conversion then hung.
            if (Pids(app).Except(before).FirstOrDefault() is > 0 and var pid) Console.Out.WriteLine($"pid {pid}");
            Console.Out.Flush();
            dynamic office = instance;
            switch (app)
            {
                case OfficeApp.Word: Word(office, input, output); break;
                case OfficeApp.Excel: Excel(office, input, output); break;
                default: PowerPoint(office, input, output); break;
            }
            Console.Out.WriteLine("ok");
            return 0;
        }
        catch (Exception ex)
        {
            Console.Out.WriteLine($"error {Describe(ex, app)}");
            return 1;
        }
        finally
        {
            if (instance is not null && Marshal.IsComObject(instance)) Marshal.FinalReleaseComObject(instance);
            Console.Out.Flush();
        }
    }

    private static HashSet<int> Pids(OfficeApp app)
    {
        var set = new HashSet<int>();
        foreach (var p in Process.GetProcessesByName(ProcessName(app)))
        {
            set.Add(p.Id);
            p.Dispose();
        }
        return set;
    }

    private static void Word(dynamic word, string input, string output)
    {
        try
        {
            word.Visible = false;
            word.DisplayAlerts = WdAlertsNone;
            word.AutomationSecurity = MsoAutomationSecurityForceDisable; // no macros run in the file
            dynamic documents = word.Documents;
            dynamic doc = documents.Open(FileName: input, ConfirmConversions: false, ReadOnly: true, AddToRecentFiles: false,
                PasswordDocument: NoPassword, PasswordTemplate: NoPassword, Revert: false, WritePasswordDocument: NoPassword,
                WritePasswordTemplate: NoPassword, Visible: false, OpenAndRepair: false, NoEncodingDialog: true);
            try
            {
                doc.ExportAsFixedFormat(OutputFileName: output, ExportFormat: WdExportFormatPdf, OpenAfterExport: false,
                    OptimizeFor: WdExportOptimizeForPrint, IncludeDocProps: true, KeepIRM: true, CreateBookmarks: WdExportCreateHeadingBookmarks,
                    DocStructureTags: true, BitmapMissingFonts: true, UseISO19005_1: false);
            }
            finally
            {
                doc.Close(SaveChanges: WdDoNotSaveChanges);
                Marshal.FinalReleaseComObject(doc);
                Marshal.FinalReleaseComObject(documents);
            }
        }
        finally
        {
            word.Quit(SaveChanges: WdDoNotSaveChanges);
        }
    }

    private static void Excel(dynamic excel, string input, string output)
    {
        try
        {
            excel.Visible = false;
            excel.DisplayAlerts = false;
            excel.ScreenUpdating = false;
            excel.EnableEvents = false;
            excel.AskToUpdateLinks = false;
            excel.AutomationSecurity = MsoAutomationSecurityForceDisable;
            dynamic books = excel.Workbooks;
            // Just started, Excel can refuse its first Open ("Unable to get the Open property"): wait until it is ready,
            // and try again a few times.
            for (var i = 0; i < 40 && !(bool)excel.Ready; i++) Thread.Sleep(250);
            dynamic? book = null;
            for (var attempt = 1; book is null; attempt++)
            {
                try
                {
                    // Positional: Filename, UpdateLinks, ReadOnly, Format, Password, WriteResPassword, IgnoreReadOnlyRecommended.
                    book = books.Open(input, 0, true, Type.Missing, NoPassword, NoPassword, true);
                }
                catch (COMException) when (attempt < 4)
                {
                    Thread.Sleep(1000);
                }
            }
            try
            {
                book.ExportAsFixedFormat(Type: XlTypePdf, Filename: output, IncludeDocProperties: true, IgnorePrintAreas: false, OpenAfterPublish: false);
            }
            finally
            {
                book.Close(SaveChanges: false);
                Marshal.FinalReleaseComObject(book);
                Marshal.FinalReleaseComObject(books);
            }
        }
        finally
        {
            excel.Quit();
        }
    }

    private static void PowerPoint(dynamic powerPoint, string input, string output)
    {
        // PowerPoint can't be hidden (setting Visible throws); WithWindow: false opens the file without a window. It runs
        // here only when it wasn't running before (Precheck), so quitting it closes nothing of the user's; a protected file
        // is refused before (Precheck) or, in an old format, stops at the password prompt until the timeout ends it.
        try
        {
            powerPoint.AutomationSecurity = MsoAutomationSecurityForceDisable;
            dynamic presentations = powerPoint.Presentations;
            dynamic deck = presentations.Open(FileName: input, ReadOnly: MsoTrue, Untitled: MsoFalse, WithWindow: MsoFalse);
            try
            {
                deck.SaveAs(output, PpSaveAsPdf);
            }
            finally
            {
                deck.Close();
                Marshal.FinalReleaseComObject(deck);
                Marshal.FinalReleaseComObject(presentations);
            }
        }
        finally
        {
            powerPoint.Quit();
        }
    }

    private static string Describe(Exception ex, OfficeApp app)
    {
        var inner = ex is System.Reflection.TargetInvocationException { InnerException: { } i } ? i : ex;
        var message = inner.Message.ReplaceLineEndings(" ").Trim();
        if (inner is COMException com && (uint)com.HResult is 0x800A1520 or 0x800A03EC && message.Contains("password", StringComparison.OrdinalIgnoreCase))
            return $"This file is protected with a password. Open it in {OfficeFiles.AppName(app)} and save it as PDF there.";
        return message.Length > 0 ? $"{OfficeFiles.AppName(app)}: {message}" : $"{OfficeFiles.AppName(app)} couldn't save this file as PDF.";
    }
}
