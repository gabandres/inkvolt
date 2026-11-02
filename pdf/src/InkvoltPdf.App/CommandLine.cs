using InkvoltPdf.Core;

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
        InkvoltPrint.Windows.Suite.ConsoleOutput.Use();
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
            Recognizer = ocr is null ? null : new SerialRecognizer(ocr, ocrGate),
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
}
