namespace InkvoltPrint.Core.Printing;

public enum BatchCommandKind { Help, List, Files, Watch }

/// <summary>A parsed <c>inkvoltprint print</c> (see <see cref="BatchPrintCommandLine.Usage"/>).</summary>
public sealed record BatchCommandRequest(BatchCommandKind Kind, string? Printer = null, string? List = null, IReadOnlyList<string>? Inputs = null, string? Folder = null,
    BatchPrintSettings? Settings = null, string? Report = null, int MaxSheets = BatchPrintLimits.DefaultMaxSheets, bool AllowNetwork = false, bool Recursive = false,
    bool DryRun = false, bool Once = false, bool Quiet = false);

/// <summary>The command line is wrong; the message says how.</summary>
public sealed class BatchCommandException(string message) : Exception(message);

/// <summary>This PC's side of the command line: the files, and the printer a name stands for.</summary>
public interface IBatchPrintHost
{
    IBatchDocuments Documents { get; }

    /// <summary>The printer called <paramref name="name"/>.</summary>
    /// <exception cref="BatchCommandException">There's none, or it isn't one to print a batch to (a virtual printer that would ask where to save).</exception>
    Task<IBatchQueue> FindPrinterAsync(string name, CancellationToken ct);
}

/// <summary>
/// <c>inkvoltprint print</c> (roadmap 2.4, Pro): a saved list, some files or a folder as it fills, without a window, from a terminal, a
/// script or a scheduled task. Lines go to <c>output</c> (one per file) and problems to <c>error</c>; the exit code says how it went,
/// the same as Inkvolt PDF's (<see cref="BatchPrintSummary.Done"/>, <see cref="BatchPrintSummary.SomeFailed"/>,
/// <see cref="BatchPrintSummary.Wrong"/>, <see cref="BatchPrintSummary.Stopped"/>). Nothing is asked: a file that needs a password is
/// tried once with <see cref="PasswordVariable"/> and otherwise skipped. Everything is estimated before the first sheet, and
/// a batch over <c>--max-sheets</c> isn't started. The app's entry point attaches the console and passes the PC's side; the
/// rest is here, so tests run it in-process.
/// </summary>
public static class BatchPrintCommandLine
{
    public const string Verb = "print";
    public const string PasswordVariable = "INKVOLTPRINT_OPEN_PASSWORD";

    public static string Usage { get; } =
        $"""
        Inkvolt Print command line: print without a window.

          inkvoltprint print --list <list file> --printer <name> [options]
              Prints a list saved in Print > Batch (plain JSON), in its order.

          inkvoltprint print <files or folders>... --printer <name> [--copies n] [--two-sided] [--paper key] [--pages range] [--recursive] [options]
              Prints PDFs and pictures (a folder: those at its top, in name order; --recursive: below too).

          inkvoltprint print --watch <folder> --printer <name> [--copies n] [--two-sided] [--paper key] [--once] [options]
              Prints each PDF or picture that lands in the folder, once it has stopped changing and reads as whole.
              Originals move to "done" or "failed" below the folder; {BatchPrintFolder.LogName} there has a line per file.
              A file left in "working" by a run that never finished may have printed: it goes to "failed", never through again.
              Ctrl+C stops. --once handles the files there now, then stops (for a scheduled task).

          inkvoltprint print --help

        Options:
          --max-sheets <n>   the most sheets this run may use (default {BatchPrintLimits.DefaultMaxSheets}); over it, a list doesn't start
          --report <file.csv>  the results as a CSV, a row per file
          --dry-run          the estimate only, nothing is sent (not with --watch)
          --allow-network    a list may open files on other computers (it's refused otherwise)
          --quiet            only problems, and the last line

        --printer is a queue's name in Windows (inkvoltprint queues lists them) or a printer's name in Inkvolt Print.
        A file that needs a password gets the one in the environment variable {PasswordVariable}, once, and is otherwise skipped.
        "Sent" means Windows' print queue has it.

        Exit codes: 0 every file sent; 1 a file failed or was skipped; 2 wrong command line, list, printer or folder, or over
        --max-sheets (nothing sent); 3 stopped before the end (Ctrl+C, or the printer has a problem).
        """;

    /// <summary>The arguments ask for the command line (rather than opening files in the app).</summary>
    public static bool IsCommand(IReadOnlyList<string> args) => args.Count > 0 && string.Equals(args[0], Verb, StringComparison.OrdinalIgnoreCase);

    /// <exception cref="BatchCommandException">The arguments are wrong.</exception>
    public static BatchCommandRequest Parse(IReadOnlyList<string> args)
    {
        if (!IsCommand(args)) throw new BatchCommandException("Say what to do: inkvoltprint print --list <file> --printer <name>.");
        string? printer = null, list = null, watch = null, report = null, paper = null, range = null;
        int copies = 1, maxSheets = BatchPrintLimits.DefaultMaxSheets;
        bool twoSided = false, network = false, recursive = false, dry = false, once = false, quiet = false, help = false, settingsGiven = false;
        var inputs = new List<string>();
        string Value(ref int i, string name) =>
            i + 1 < args.Count && !args[i + 1].StartsWith("--", StringComparison.Ordinal) ? args[++i] : throw new BatchCommandException($"{name} needs a value after it.");
        int Number(ref int i, string name, int low, int high)
        {
            var text = Value(ref i, name);
            if (!int.TryParse(text, out var n) || n < low || n > high) throw new BatchCommandException($"{name} must be a number from {low} to {high:N0} (\"{BatchPrintText.Clean(text)}\" isn't).");
            return n;
        }

        for (var i = 1; i < args.Count; i++)
        {
            var a = args[i];
            switch (a.ToLowerInvariant())
            {
                case "--help" or "-h" or "-?" or "/?": help = true; break;
                case "--printer": printer = Value(ref i, a); break;
                case "--list": list = Value(ref i, a); break;
                case "--watch": watch = Value(ref i, a); break;
                case "--report": report = Value(ref i, a); break;
                case "--copies": copies = Number(ref i, a, 1, BatchPrintLimits.MaxCopies); settingsGiven = true; break;
                case "--paper": paper = Value(ref i, a); settingsGiven = true; break;
                case "--pages": range = Value(ref i, a); settingsGiven = true; break;
                case "--two-sided": twoSided = true; settingsGiven = true; break;
                case "--max-sheets": maxSheets = Number(ref i, a, 1, 1_000_000); break;
                case "--allow-network": network = true; break;
                case "--recursive": recursive = true; break;
                case "--dry-run": dry = true; break;
                case "--once": once = true; break;
                case "--quiet": quiet = true; break;
                default:
                    if (a.StartsWith("--", StringComparison.Ordinal)) throw new BatchCommandException($"\"{BatchPrintText.Clean(a)}\" isn't an option inkvoltprint print knows (--help lists them).");
                    inputs.Add(a);
                    break;
            }
        }
        if (help) return new BatchCommandRequest(BatchCommandKind.Help);
        if ((list is null ? 0 : 1) + (watch is null ? 0 : 1) + (inputs.Count > 0 ? 1 : 0) != 1)
            throw new BatchCommandException("Say what to print: --list <file>, --watch <folder>, or files and folders (only one of those).");
        if (string.IsNullOrWhiteSpace(printer)) throw new BatchCommandException("Say which printer: --printer <name>. Nothing is sent to a default printer.");
        var settings = new BatchPrintSettings(copies, range, twoSided, paper);
        if (list is not null)
        {
            if (settingsGiven) throw new BatchCommandException("A list says how each file prints: --copies, --two-sided, --paper and --pages go with files or --watch.");
            if (recursive || once) throw new BatchCommandException("--recursive goes with folders given on the command line, and --once with --watch.");
            return new BatchCommandRequest(BatchCommandKind.List, printer, list, null, null, null, report, maxSheets, network, false, dry, false, quiet);
        }
        if (watch is not null)
        {
            if (recursive || dry || network) throw new BatchCommandException("--watch takes the files at the folder's top, as they come: no --recursive, --dry-run or --allow-network.");
            if (range is not null) throw new BatchCommandException("--pages goes with files: a folder's files have different pages.");
            return new BatchCommandRequest(BatchCommandKind.Watch, printer, null, null, watch, settings, report, maxSheets, false, false, false, once, quiet);
        }
        if (once) throw new BatchCommandException("--once goes with --watch.");
        return new BatchCommandRequest(BatchCommandKind.Files, printer, null, inputs, null, settings, report, maxSheets, network, recursive, dry, false, quiet);
    }

    /// <summary>Runs the command line; returns the exit code.</summary>
    /// <param name="environment">Reads an environment variable (tests give their own).</param>
    public static async Task<int> RunAsync(IReadOnlyList<string> args, TextWriter output, TextWriter error, IBatchPrintHost host, CancellationToken cancel,
        Func<string, string?>? environment = null, BatchPrintOptions? options = null, TimeSpan? folderQuiet = null, TimeSpan? folderPoll = null)
    {
        environment ??= Environment.GetEnvironmentVariable;
        BatchCommandRequest request;
        try
        {
            request = Parse(args);
        }
        catch (BatchCommandException ex)
        {
            error.WriteLine(ex.Message);
            error.WriteLine("inkvoltprint print --help shows how to use it.");
            return BatchPrintSummary.Wrong;
        }
        if (request.Kind == BatchCommandKind.Help)
        {
            output.WriteLine(Usage);
            return BatchPrintSummary.Done;
        }
        if (!Pro.Allows(ProFeature.BatchPrintAutomation))
        {
            error.WriteLine(Pro.Locked(ProFeature.BatchPrintAutomation));
            error.WriteLine(Pro.HowToGet);
            return BatchPrintSummary.Wrong;
        }
        if (request.Report is { } report && Wrong(CheckReport(report), error)) return BatchPrintSummary.Wrong;

        IBatchQueue queue;
        BatchQueueInfo info;
        try
        {
            queue = await host.FindPrinterAsync(request.Printer!, cancel).ConfigureAwait(false);
            if (await queue.ReadAsync(cancel).ConfigureAwait(false) is not { } read)
                throw new BatchCommandException($"\"{BatchPrintText.Clean(request.Printer!)}\" has no Windows queue to print through.");
            info = read;
        }
        catch (BatchCommandException ex)
        {
            error.WriteLine(ex.Message);
            return BatchPrintSummary.Wrong;
        }
        catch (OperationCanceledException)
        {
            return BatchPrintSummary.Stopped;
        }
        catch (Exception ex) when (ex is not BatchCommandException)
        {
            error.WriteLine($"The printer can't be read: {ex.Message}");
            return BatchPrintSummary.Wrong;
        }

        var password = environment(PasswordVariable);
        return request.Kind == BatchCommandKind.Watch
            ? await WatchAsync(request, queue, info, host.Documents, password, output, error, options, folderQuiet, folderPoll, cancel).ConfigureAwait(false)
            : await BatchAsync(request, queue, info, host.Documents, password, output, error, options, cancel).ConfigureAwait(false);
    }

    private static bool Wrong(string? problem, TextWriter error)
    {
        if (problem is null) return false;
        error.WriteLine(problem);
        return true;
    }

    /// <summary>Why the report can't be written, said before any paper is used.</summary>
    private static string? CheckReport(string report)
    {
        try
        {
            var full = Path.GetFullPath(report);
            if (!full.EndsWith(".csv", StringComparison.OrdinalIgnoreCase)) return "--report needs a .csv file.";
            if (!Directory.Exists(Path.GetDirectoryName(full))) return $"--report: there is no folder {BatchPrintText.Clean(Path.GetDirectoryName(full) ?? report)}.";
            return null;
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return $"--report: {ex.Message}";
        }
    }

    private static async Task<int> BatchAsync(BatchCommandRequest request, IBatchQueue queue, BatchQueueInfo info, IBatchDocuments documents, string? password,
        TextWriter output, TextWriter error, BatchPrintOptions? options, CancellationToken cancel)
    {
        List<BatchListEntry> entries;
        try
        {
            if (request.Kind == BatchCommandKind.List) entries = BatchPrintList.Expand(BatchPrintList.Load(Path.GetFullPath(request.List!), request.AllowNetwork));
            else
            {
                var checks = request.Inputs!.Select(Path.GetFullPath).ToList();
                if (checks.FirstOrDefault(p => !File.Exists(p) && !Directory.Exists(p)) is { } missing) throw new BatchListException($"There is no file or folder {BatchPrintText.Clean(missing)}.");
                var files = BatchPrintFiles.Expand(checks, request.Recursive, out var leftOut);
                if (leftOut > 0) throw new BatchListException($"{BatchPrintText.Clean(checks.FirstOrDefault(p => !Directory.Exists(p) && !BatchPrintFiles.IsSupported(p)) ?? checks[0])} is neither a PDF, a picture nor a folder. Nothing was sent.");
                if (files.Count > BatchPrintLimits.MaxFiles) throw new BatchListException($"That's {files.Count:N0} files: a batch takes at most {BatchPrintLimits.MaxFiles:N0}.");
                entries = files.Select(f => new BatchListEntry(f, request.Settings!)).ToList();
            }
        }
        catch (BatchListException ex)
        {
            error.WriteLine(ex.Message);
            if (ex is BatchListNetworkException) error.WriteLine("--allow-network opens them.");
            return BatchPrintSummary.Wrong;
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException or IOException or UnauthorizedAccessException)
        {
            error.WriteLine(ex.Message);
            return BatchPrintSummary.Wrong;
        }
        if (entries.Count == 0)
        {
            error.WriteLine("No PDFs or pictures to print there.");
            return BatchPrintSummary.Wrong;
        }

        // The estimate: every file is opened, every password tried, before the first sheet.
        var lines = new List<BatchPrintLine>(entries.Count);
        try
        {
            foreach (var (entry, n) in entries.Select((e, i) => (e, i + 1)))
            {
                var measure = await BatchMeasurer.MeasureAsync(entry.Path, password, documents, null, options, cancel).ConfigureAwait(false);
                var line = new BatchPrintLine(entry.Path, entry.Settings, measure, info);
                lines.Add(line);
                if (line.Problem is not null) error.WriteLine($"[{n}/{entries.Count}] left out {BatchPrintText.Clean(line.Name)}: {line.Problem}");
                else if (!request.Quiet) output.WriteLine($"[{n}/{entries.Count}] estimate {BatchPrintText.Clean(line.Name)}: {BatchPrintText.Count(line.Pages.Count, "page")}, {BatchPrintText.Sheets(line.Sheets)}");
            }
        }
        catch (OperationCanceledException)
        {
            error.WriteLine("Stopped during the estimate: nothing was sent.");
            return BatchPrintSummary.Stopped;
        }
        var total = lines.Sum(l => (long)l.Sheets);
        if (!request.Quiet) output.WriteLine($"Estimate: {BatchPrintText.Count(lines.Count, "file")}, {total:N0} {(total == 1 ? "sheet" : "sheets")} on {BatchPrintText.Clean(info.Name)}.");
        if (total > request.MaxSheets)
        {
            error.WriteLine($"That's {total:N0} sheets, more than --max-sheets allows ({request.MaxSheets:N0}). Nothing was sent.");
            return BatchPrintSummary.Wrong;
        }
        if (request.DryRun) return lines.Any(l => l.Problem is not null) ? BatchPrintSummary.SomeFailed : BatchPrintSummary.Done;

        var progress = new Direct<BatchPrintProgress>(p =>
        {
            if (p.Result is not { } r || r.State == BatchPrintState.Skipped) return;
            var word = r.State switch { BatchPrintState.Sent => "sent    ", BatchPrintState.Failed => "failed  ", _ => "not sent" };
            if (r.State == BatchPrintState.Sent && request.Quiet) return;
            (r.State == BatchPrintState.Failed ? error : output).WriteLine($"[{r.Index + 1}/{lines.Count}] {word} {BatchPrintText.Clean(r.Name)}: {r.Message}");
        });
        var summary = await BatchPrintRunner.RunAsync(lines, queue, documents, options, progress, cancel).ConfigureAwait(false);
        output.WriteLine(summary.Text);
        var code = summary.ExitCode;
        if (request.Report is { } report && !WriteReport(report, summary.Items, error) && code == BatchPrintSummary.Done) code = BatchPrintSummary.SomeFailed;
        return code;
    }

    private static async Task<int> WatchAsync(BatchCommandRequest request, IBatchQueue queue, BatchQueueInfo info, IBatchDocuments documents, string? password,
        TextWriter output, TextWriter error, BatchPrintOptions? options, TimeSpan? quiet, TimeSpan? poll, CancellationToken cancel)
    {
        string folder;
        try
        {
            folder = Path.GetFullPath(request.Folder!);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            error.WriteLine(ex.Message);
            return BatchPrintSummary.Wrong;
        }
        if (Wrong(BatchPrintFolder.Validate(folder), error)) return BatchPrintSummary.Wrong;
        var settings = new BatchPrintLine(folder + @"\x.pdf", request.Settings!, new BatchMeasure { State = BatchMeasureState.Ready, PageCount = 1 }, info);
        if (Wrong(settings.Problem, error)) return BatchPrintSummary.Wrong;
        if (!request.Quiet)
            output.WriteLine($"Watching {BatchPrintText.Clean(folder)} for {BatchPrintText.Clean(info.Name)}, at most {request.MaxSheets:N0} sheets. {(request.Once ? "Handling the files there now." : "Ctrl+C stops.")}");

        var results = new List<BatchPrintResult>();
        var progress = new Direct<BatchFolderProgress>(p =>
        {
            if (p.Waiting is { } waiting) error.WriteLine($"Waiting: {waiting}");
            if (p.Finished is not { } e) return;
            results.Add(new BatchPrintResult(results.Count, Path.Combine(folder, e.FileName), e.State, e.Message, 0, request.Settings!.Copies, request.Settings.TwoSided, request.Settings.Paper, e.SheetsSent, e.SheetsSent, e.Time));
            if (e.State == BatchPrintState.Sent && request.Quiet) return;
            (e.State == BatchPrintState.Failed ? error : output).WriteLine($"{e.Time:HH:mm:ss} {e.State.ToString().ToLowerInvariant(),-8} {BatchPrintText.Clean(e.FileName)}: {e.Message}");
        });
        var folderOptions = new BatchFolderOptions { Settings = request.Settings!, Password = password, Once = request.Once, MaxSheets = request.MaxSheets, Print = options ?? new BatchPrintOptions() };
        if (quiet is { } q) folderOptions = folderOptions with { QuietPeriod = q };
        if (poll is { } t) folderOptions = folderOptions with { PollInterval = t };
        try
        {
            var summary = await BatchPrintFolder.RunAsync(folder, queue, documents, folderOptions, progress, cancel).ConfigureAwait(false);
            output.WriteLine($"{BatchPrintText.Count(summary.Sent, "file")} sent ({BatchPrintText.Sheets(summary.SheetsSent)}), {summary.Failed:N0} failed.");
            if (summary.StopReason is { } why) error.WriteLine($"Stopped: {why}");
            if (summary.LeftWaiting > 0) error.WriteLine($"{BatchPrintText.Count(summary.LeftWaiting, "file")} left in the folder for the next run: cut off, or still changing. Not printed.");
            // Ctrl+C is how a plain watch ends; a run that was to finish the folder (--once) stopped before the end.
            var code = summary.StopReason is not null || (request.Once && cancel.IsCancellationRequested) ? BatchPrintSummary.Stopped : summary.Failed > 0 || summary.LeftWaiting > 0 ? BatchPrintSummary.SomeFailed : BatchPrintSummary.Done;
            if (request.Report is { } report && !WriteReport(report, results, error) && code == BatchPrintSummary.Done) code = BatchPrintSummary.SomeFailed;
            return code;
        }
        catch (Exception ex) when (ex is ArgumentException or BatchFolderBusyException or UnauthorizedAccessException or IOException)
        {
            error.WriteLine(ex.Message);
            return BatchPrintSummary.Wrong;
        }
    }

    private static bool WriteReport(string report, IEnumerable<BatchPrintResult> results, TextWriter error)
    {
        try
        {
            var full = Path.GetFullPath(report);
            var temp = full + ".tmp";
            File.WriteAllText(temp, BatchPrintCsv.Build(results), new System.Text.UTF8Encoding(true)); // a spreadsheet reads the names right
            File.Move(temp, full, overwrite: true);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            error.WriteLine($"The report can't be saved: {ex.Message}");
            return false;
        }
    }

    /// <summary>Reports on the reporting thread (Progress&lt;T&gt; would post them later, after the summary line).</summary>
    private sealed class Direct<T>(Action<T> report) : IProgress<T>
    {
        public void Report(T value) => report(value);
    }
}
