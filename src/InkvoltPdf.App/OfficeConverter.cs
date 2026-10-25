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

    /// <summary>
    /// The file's security zone from its Zone.Identifier stream (Windows' mark of the web), or null when it has none.
    /// 3 is the internet, 4 untrusted sites: such a file needs the user's OK first, as automation opens it without
    /// Protected View (macros stay off, but the file could still fetch linked content or a remote template).
    /// </summary>
    public static int? ZoneOf(string path)
    {
        try
        {
            return OfficeFiles.ZoneId(File.ReadAllText(path + ":Zone.Identifier"));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or NotSupportedException or ArgumentException)
        {
            return null; // no mark of the web (or a file system without alternate streams)
        }
    }

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
    /// <param name="fromInternetConfirmed">The user agreed to convert a file marked as from the internet (<see cref="ZoneOf"/>).</param>
    /// <exception cref="InvalidOperationException">Office couldn't convert the file (the message says why).</exception>
    /// <exception cref="OperationCanceledException">Cancelled.</exception>
    public static async Task<OfficeResult> ConvertAsync(string path, OfficeApp app, bool fromInternetConfirmed, CancellationToken cancel)
    {
        if (Precheck(path, app) is { } problem) throw new InvalidOperationException(problem);
        if (ZoneOf(path) >= 3 && !fromInternetConfirmed) throw new InvalidOperationException("This file came from the internet: confirm before it is opened in Office.");
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
        string? error = null, note = null;
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
                    else if (line.StartsWith("note ", StringComparison.Ordinal)) note = line[5..];
                }
            }, CancellationToken.None);
            // Read too, so a helper writing to it never blocks on a full pipe; its first line explains a crash.
            var errors = child.StandardError.ReadToEndAsync(CancellationToken.None);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancel);
            timeout.CancelAfter(Timeout);
            try
            {
                await child.WaitForExitAsync(timeout.Token);
                await reading;
            }
            catch (OperationCanceledException)
            {
                var left = await StopAsync(child, () => Volatile.Read(ref officePid), before, app);
                var leftNote = left ? $" {OfficeFiles.AppName(app)} was left running because it shows a window (it may be asking something, or a document you opened is in it): close it yourself." : "";
                if (cancel.IsCancellationRequested)
                {
                    if (left) Log.Write($"Office conversion cancelled; {ProcessName(app)} left running (it shows a window)");
                    throw new OperationCanceledException(leftNote.Trim(), cancel);
                }
                throw new InvalidOperationException($"{OfficeFiles.AppName(app)} didn't finish within {Timeout.TotalMinutes:0} minutes (it may have stopped to ask something)." +
                    (left ? leftNote : " It was closed.") + Reason(await TakeAsync(errors)));
            }
            var stderr = await TakeAsync(errors);
            if (child.ExitCode != 0 || !File.Exists(output))
                throw new InvalidOperationException(error ?? $"{OfficeFiles.AppName(app)} couldn't save this file as PDF.{Reason(stderr)}");
            return new OfficeResult(await File.ReadAllBytesAsync(output, CancellationToken.None), note);
        }
        finally
        {
            try { dir.Delete(true); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { Log.Write($"Office temp folder left: {ex.Message}"); }
        }
    }

    /// <summary>The helper's error output, if it finished writing it within a moment (empty otherwise).</summary>
    private static async Task<string> TakeAsync(Task<string> errors)
    {
        try
        {
            return await errors.WaitAsync(TimeSpan.FromSeconds(2));
        }
        catch (Exception ex) when (ex is TimeoutException or IOException or ObjectDisposedException or InvalidOperationException)
        {
            return "";
        }
    }

    /// <summary>" (first line of the helper's error output)", short; empty when there is none.</summary>
    internal static string Reason(string stderr)
    {
        var first = stderr.Split('\n', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).FirstOrDefault() ?? "";
        if (first.Length == 0) return "";
        if (first.Length > 160) first = first[..160] + "…";
        return $" ({first})";
    }

    /// <summary>
    /// Ends the helper and the hidden Office instance it started. Office may still be starting (its process not known
    /// yet): wait for the helper to name it, a while; else take the instances of that app that appeared since the helper
    /// started. Never one that was running before, and never one showing a window (a user's document may be in it, as a
    /// PowerPoint opened meanwhile joins the running one): that one is left running. True when one was left so.
    /// </summary>
    private static async Task<bool> StopAsync(Process child, Func<int> reportedPid, HashSet<int> before, OfficeApp app)
    {
        for (var i = 0; i < 200 && reportedPid() <= 0 && !child.HasExited; i++) await Task.Delay(100, CancellationToken.None);
        var exitedByItself = child.HasExited;
        try
        {
            if (!exitedByItself) child.Kill(entireProcessTree: true);
        }
        catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception) { }
        if (exitedByItself) return false; // it closed Office itself
        var left = false;
        var pids = reportedPid() is > 0 and var known ? [known] : Pids(app).Except(before).ToList();
        foreach (var pid in pids)
        {
            try
            {
                using var office = Process.GetProcessById(pid);
                if (!string.Equals(office.ProcessName, ProcessName(app), StringComparison.OrdinalIgnoreCase) || before.Contains(pid)) continue;
                if (HasVisibleWindow(pid))
                {
                    left = true;
                    continue;
                }
                office.Kill();
                Log.Write($"Office conversion: {ProcessName(app)} stopped");
            }
            catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception) { }
        }
        return left;
    }

    private delegate bool EnumWindowsProc(IntPtr hwnd, IntPtr lParam);

    [DllImport("user32.dll")] private static extern bool EnumWindows(EnumWindowsProc callback, IntPtr lParam);
    [DllImport("user32.dll")] private static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] private static extern bool IsWindowVisible(IntPtr hwnd);

    /// <summary>A top-level window of <paramref name="pid"/> is visible.</summary>
    private static bool HasVisibleWindow(int pid)
    {
        var found = false;
        EnumWindows((hwnd, _) =>
        {
            if (GetWindowThreadProcessId(hwnd, out var owner) != 0 && owner == (uint)pid && IsWindowVisible(hwnd)) found = true;
            return !found;
        }, IntPtr.Zero);
        return found;
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
            // Links aren't updated on open. The option is the user's own setting, so it is put back right after.
            dynamic options = word.Options;
            bool? updateLinks = null;
            try
            {
                updateLinks = (bool)options.UpdateLinksAtOpen;
                options.UpdateLinksAtOpen = false;
            }
            catch (Exception ex) when (ex is COMException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException) { }
            dynamic documents = word.Documents;
            dynamic doc;
            try
            {
                doc = documents.Open(FileName: input, ConfirmConversions: false, ReadOnly: true, AddToRecentFiles: false,
                PasswordDocument: NoPassword, PasswordTemplate: NoPassword, Revert: false, WritePasswordDocument: NoPassword,
                WritePasswordTemplate: NoPassword, Visible: false, OpenAndRepair: false, NoEncodingDialog: true);
            }
            finally
            {
                if (updateLinks is { } was)
                    try { options.UpdateLinksAtOpen = was; }
                    catch (COMException) { }
            }
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
            QuitIfIdle((object)word, () => (int)word.Documents.Count, () => word.Quit(SaveChanges: WdDoNotSaveChanges), OfficeApp.Word);
        }
    }

    /// <summary>
    /// Quits the Office instance unless it holds other documents or shows itself (someone works in it now): then it is
    /// left running and the parent is told ("note ...").
    /// </summary>
    private static void QuitIfIdle(object instance, Func<int> openDocuments, Action quit, OfficeApp which)
    {
        bool busy;
        try
        {
            dynamic app = instance;
            busy = openDocuments() > 0 || which != OfficeApp.PowerPoint && (bool)app.Visible || which == OfficeApp.PowerPoint && (int)app.Visible == MsoTrue;
        }
        catch (Exception ex) when (ex is COMException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException or InvalidCastException)
        {
            busy = false;
        }
        if (busy)
        {
            Console.Out.WriteLine($"note {OfficeFiles.AppName(which)} was left running: other documents are open in it.");
            return;
        }
        quit();
    }

    private static void Excel(dynamic excel, string input, string output)
    {
        try
        {
            excel.Visible = false;
            excel.DisplayAlerts = false;
            excel.ScreenUpdating = false;
            excel.EnableEvents = false;
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
                    // Positional (named arguments fail here): Filename, UpdateLinks 0 (external links aren't updated),
                    // ReadOnly, Format, Password, WriteResPassword, IgnoreReadOnlyRecommended, Origin, Delimiter, Editable,
                    // Notify, Converter, AddToMru false.
                    var m = Type.Missing;
                    book = books.Open(input, 0, true, m, NoPassword, NoPassword, true, m, m, false, false, m, false);
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
            QuitIfIdle((object)excel, () => (int)excel.Workbooks.Count, () => excel.Quit(), OfficeApp.Excel);
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
            // PowerPoint runs one copy at a time: a presentation the user opened meanwhile is in this one; then it stays.
            QuitIfIdle((object)powerPoint, () => (int)powerPoint.Presentations.Count, () => powerPoint.Quit(), OfficeApp.PowerPoint);
        }
    }

    /// <summary>A converted Office file, and what the user should know (Office left running).</summary>
    internal sealed record OfficeResult(byte[] Pdf, string? Note);

    private static string Describe(Exception ex, OfficeApp app)
    {
        var inner = ex is System.Reflection.TargetInvocationException { InnerException: { } i } ? i : ex;
        var message = inner.Message.ReplaceLineEndings(" ").Trim();
        if (inner is COMException com && (uint)com.HResult is 0x800A1520 or 0x800A03EC && message.Contains("password", StringComparison.OrdinalIgnoreCase))
            return $"This file is protected with a password. Open it in {OfficeFiles.AppName(app)} and save it as PDF there.";
        return message.Length > 0 ? $"{OfficeFiles.AppName(app)}: {message}" : $"{OfficeFiles.AppName(app)} couldn't save this file as PDF.";
    }
}
