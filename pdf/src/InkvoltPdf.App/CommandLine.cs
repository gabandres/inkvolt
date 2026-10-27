using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using InkvoltPdf.Core;
using Microsoft.Win32.SafeHandles;

namespace InkvoltPdf.App;

/// <summary>
/// <c>inkvoltpdf --batch | --watch | --help</c> without a window: Core's <see cref="BatchCommandLine"/> with Windows' OCR.
/// Inkvolt PDF is a windowed app (a console app would flash a console window each time a PDF is opened from Explorer), so
/// it writes to the console of the terminal it was started from (attached), or to wherever its output is redirected. A
/// terminal doesn't wait for a windowed app: <c>start /wait</c> (cmd), <c>| Out-Default</c> or
/// <c>Start-Process -Wait</c> (PowerShell) make it wait and see the exit code; a scheduled task always waits. Runs outside
/// the single-instance handoff and never touches the settings.
/// </summary>
internal static class CommandLine
{
    public static async Task<int> RunAsync(string[] args)
    {
        UseConsole();
        try
        {
            // MuPDF's own warnings ("repairing PDF document") would go to stderr between the lines: keep them out.
            await MuPDFCore.MuPDF.RedirectOutput();
        }
        catch (Exception ex)
        {
            Log.Write($"Command line: MuPDF's messages not redirected: {ex.Message}");
        }
        using var cts = new CancellationTokenSource();
        Console.CancelKeyPress += (_, e) =>
        {
            e.Cancel = true; // stop the work, then exit with its code
            cts.Cancel();
        };
        Log.Write($"Command line: {args[0]}");
        var ocr = args[0].ToLowerInvariant() is "--batch" or "--watch" ? PageOcr.Engine : null;
        var ocrGate = new Lock();
        var host = new BatchHost
        {
            // Windows' recognizer, one page at a time (one engine for the files running together).
            Recognize = ocr is null ? null : (engine, page, cancel) =>
            {
                lock (ocrGate) return PageOcr.Recognize(ocr, engine, page, cancel);
            },
        };
        int code;
        try
        {
            code = await BatchCommandLine.RunAsync(args, Console.Out, Console.Error, host, cts.Token);
        }
        catch (Exception ex)
        {
            Log.Write($"Command line failed: {ex}");
            Console.Error.WriteLine($"Inkvolt PDF stopped: {ex.Message}");
            code = BatchCommandLine.Wrong;
        }
        Console.Out.Flush();
        Console.Error.Flush();
        Log.Write($"Command line done: exit code {code}");
        return code;
    }

    /// <summary>Output to the redirected handles when there are some, else to the starting terminal's console.</summary>
    private static void UseConsole()
    {
        if (Valid(GetStdHandle(StdOutput))) return; // redirected: a pipe or a file (a script, | Out-Default, a task's log)
        if (!AttachConsole(AttachParentProcess)) return; // started from Explorer or a task: nowhere to write, the exit code tells
        var console = CreateFile("CONOUT$", GenericRead | GenericWrite, FileShareRead | FileShareWrite, IntPtr.Zero, OpenExisting, 0, IntPtr.Zero);
        if (!Valid(console)) return;
        var writer = TextWriter.Synchronized(new ConsoleWriter(new SafeFileHandle(console, ownsHandle: true)));
        writer.WriteLine(); // the prompt came back already (a windowed app isn't waited for): start on a line of our own
        Console.SetOut(writer);
        Console.SetError(writer);
    }

    /// <summary>Writes to the console as UTF-16 (WriteConsoleW), so names in any script show whatever the console's code page.</summary>
    private sealed class ConsoleWriter(SafeFileHandle console) : TextWriter
    {
        public override Encoding Encoding => Encoding.Unicode;

        public override void Write(char value) => Write(value.ToString());

        public override void Write(string? value)
        {
            if (!string.IsNullOrEmpty(value)) WriteConsole(console, value, value.Length, out _, IntPtr.Zero);
        }

        protected override void Dispose(bool disposing)
        {
            if (disposing) console.Dispose();
            base.Dispose(disposing);
        }
    }

    private static bool Valid(IntPtr handle) => handle != IntPtr.Zero && handle != new IntPtr(-1);

    private const int AttachParentProcess = -1, StdOutput = -11;
    private const uint GenericRead = 0x80000000, GenericWrite = 0x40000000, FileShareRead = 1, FileShareWrite = 2, OpenExisting = 3;

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool AttachConsole(int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr GetStdHandle(int handle);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "WriteConsoleW")]
    private static extern bool WriteConsole(SafeFileHandle console, string text, int length, out int written, IntPtr reserved);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern IntPtr CreateFile(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
}
