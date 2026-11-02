using System.Globalization;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Printing;

/// <summary>How a batch print folder prints what lands in it, and how it judges new files.</summary>
public sealed record BatchFolderOptions
{
    public BatchPrintSettings Settings { get; init; } = new();

    /// <summary>Tried once on a file that needs a password; none is ever asked for (nobody may be there to answer).</summary>
    public string? Password { get; init; }

    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>A file counts as complete once its size and time haven't changed for this long, nobody else has it open, and it reads as whole.</summary>
    public TimeSpan QuietPeriod { get; init; } = TimeSpan.FromSeconds(3);

    /// <summary>A file that still reads as cut off this long after it last changed is listed as failed rather than printed.</summary>
    public TimeSpan CutOffLimit { get; init; } = TimeSpan.FromMinutes(10);

    /// <summary>Stop once nothing more has become ready (a scheduled run) instead of watching until cancelled.</summary>
    public bool Once { get; init; }

    /// <summary>The most sheets this run sends: a file that alone is more goes to "failed"; one that would pass it waits in the folder and the run stops.</summary>
    public int MaxSheets { get; init; } = BatchPrintLimits.DefaultMaxSheets;

    public BatchPrintOptions Print { get; init; } = new();
}

/// <summary>A file the folder finished with: one line of its log.</summary>
/// <param name="MovedTo">Where the original went: done, failed, or back into the folder.</param>
public sealed record BatchFolderEntry(DateTime Time, string FileName, BatchPrintState State, string Message, int SheetsSent, string? MovedTo)
{
    /// <summary>Time, state, file name, what happened, sheets sent: tab-separated, for a spreadsheet or a script.</summary>
    public string LogLine => string.Join('\t',
        Time.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
        State.ToString().ToLowerInvariant(),
        CsvCell.NotFormula(BatchPrintText.Clean(FileName)),
        CsvCell.NotFormula(BatchPrintText.Clean(Message)),
        SheetsSent.ToString(CultureInfo.InvariantCulture));
}

/// <param name="Finished">Set when a file is finished.</param>
/// <param name="Waiting">Why files are being left in the folder for now (the printer has a problem), or null.</param>
public sealed record BatchFolderProgress(BatchFolderEntry? Finished = null, string? Waiting = null);

/// <param name="Sent">Files sent.</param>
/// <param name="Failed">Files moved to "failed".</param>
/// <param name="SheetsSent">Sheets sent.</param>
/// <param name="StopReason">Why it stopped with files left in the folder (the printer's problem in a run with <see cref="BatchFolderOptions.Once"/>, the run's limit of sheets), or null.</param>
public sealed record BatchFolderSummary(int Sent, int Failed, int SheetsSent, string? StopReason);

/// <summary>The folder is watched already (by the app or a command line): two watchers would race for its files.</summary>
public sealed class BatchFolderBusyException(string folder)
    : IOException($"{BatchPrintText.Clean(folder)} is already watched (by Inkvolt Print or Inkvolt PDF, the app or a command line). Stop that one first.");

/// <summary>
/// A folder printed as it fills: each PDF or picture that lands at its top is printed once when it's complete, then the original
/// is moved to "done" or "failed" below the folder and a line is added to <see cref="LogName"/> there, the way Inkvolt PDF's
/// watched folder works (<see cref="DropFolder"/>). Paper rules what's different: a file goes to "working" before it's sent and
/// only leaves for "done" after, so a file left in "working" by a run that never finished (the app closed, the PC lost power)
/// may have printed, goes to "failed" with a note, and is never sent again by a restart. A file that reads as cut off waits; one
/// that needs a password or would pass the run's sheets isn't sent. While the printer has a problem, files stay in the folder.
/// </summary>
public static class BatchPrintFolder
{
    public const string LogName = "inkvolt-print.log";

    /// <summary>What is wrong with watching this folder, or null.</summary>
    public static string? Validate(string folder)
    {
        if (string.IsNullOrWhiteSpace(folder) || !Path.IsPathFullyQualified(folder)) return "Choose the folder to watch.";
        return Directory.Exists(folder) ? null : $"There is no folder {BatchPrintText.Clean(folder)}.";
    }

    /// <summary>The printable files already at the top of the folder: those would print as soon as the watch starts.</summary>
    public static int ReadyToPrint(string folder) => DropFolder.Candidates(folder, BatchPrintFiles.IsSupported).Count();

    /// <summary>
    /// Watches until <paramref name="cancel"/> (or, with <see cref="BatchFolderOptions.Once"/>, until nothing more becomes ready). A
    /// stop lets a job already handed over finish; a file not sent goes back into the folder for next time.
    /// </summary>
    /// <exception cref="ArgumentException">The folder isn't valid.</exception>
    /// <exception cref="BatchFolderBusyException">Another watcher has the folder.</exception>
    public static async Task<BatchFolderSummary> RunAsync(string folder, IBatchQueue queue, IBatchDocuments documents, BatchFolderOptions? options,
        IProgress<BatchFolderProgress>? progress, CancellationToken cancel)
    {
        options ??= new BatchFolderOptions();
        folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        if (Validate(folder) is { } folderError) throw new ArgumentException(folderError, nameof(folder));

        using var held = DropFolder.Lock(folder, DropFolder.LockName) ?? throw new BatchFolderBusyException(folder);
        var working = Directory.CreateDirectory(Path.Combine(folder, DropFolder.WorkingFolder)).FullName;
        Directory.CreateDirectory(Path.Combine(folder, DropFolder.DoneFolder));
        Directory.CreateDirectory(Path.Combine(folder, DropFolder.FailedFolder));
        int sent = 0, failed = 0, sheets = 0;

        // A run that never finished: the file may have printed, so it's never sent again by itself.
        foreach (var left in Directory.EnumerateFiles(working).Order(NaturalOrder.Instance))
        {
            var entry = Finish(folder, left, Path.GetFileName(left), BatchPrintState.Failed,
                "Interrupted: Inkvolt Print closed while sending it, so it may have printed. Put it back in the folder to print it again.", 0);
            progress?.Report(new BatchFolderProgress(entry));
            failed++;
        }

        var look = new DropFolderLook(options.QuietPeriod);
        string? waiting = null;
        string? stopReason = null;
        while (!cancel.IsCancellationRequested)
        {
            var now = DateTime.UtcNow;
            var ready = look.Ready(DropFolder.Candidates(folder, BatchPrintFiles.IsSupported), now);
            ready.Sort(NaturalOrder.Instance);

            string? taken = null;
            string? takenFrom = null;
            if (ready.Count > 0)
            {
                string? problem;
                try
                {
                    problem = await queue.ProblemAsync(cancel).WaitAsync(options.Print.QueueTimeout, cancel).ConfigureAwait(false);
                }
                catch (TimeoutException)
                {
                    problem = "Windows doesn't answer about the printer.";
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                if (problem is not null)
                {
                    if (problem != waiting) progress?.Report(new BatchFolderProgress(Waiting: problem));
                    waiting = problem;
                    if (options.Once)
                    {
                        stopReason = problem;
                        break;
                    }
                }
                else
                {
                    if (waiting is not null) progress?.Report(new BatchFolderProgress());
                    waiting = null;
                    foreach (var path in ready)
                    {
                        var cutOff = !LooksWhole(path);
                        if (cutOff && now - (look.UnchangedSince(path) ?? now) < options.CutOffLimit) continue;
                        if (DropFolder.Claim(path, working) is not { } moved) continue;
                        look.Forget(path);
                        if (cutOff)
                        {
                            var entry = Finish(folder, moved, Path.GetFileName(path), BatchPrintState.Failed,
                                "It reads as cut off and hasn't changed since. Not printed: if it is whole, print it from Print > Batch.", 0);
                            progress?.Report(new BatchFolderProgress(entry));
                            failed++;
                            continue;
                        }
                        (taken, takenFrom) = (moved, path);
                        break;
                    }
                }
            }

            if (taken is not null)
            {
                var (entry, stop) = await PrintOneAsync(folder, taken, Path.GetFileName(takenFrom!), queue, documents, options, sheets, cancel).ConfigureAwait(false);
                progress?.Report(new BatchFolderProgress(entry));
                if (entry.State == BatchPrintState.Sent) sent++;
                else if (entry.State == BatchPrintState.Failed) failed++;
                sheets += entry.SheetsSent;
                if (stop is not null && (options.Once || stop.Final))
                {
                    stopReason = stop.Why;
                    break;
                }
                continue; // look again at once: more may be waiting
            }
            // Once: stop when every file there has had its chance to settle (one still growing or held waits for the next run).
            if (options.Once && look.AllSeenFor(options.QuietPeriod + options.PollInterval, now)) break;
            try
            {
                await Task.Delay(options.PollInterval, cancel).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
        return new BatchFolderSummary(sent, failed, sheets, stopReason);
    }

    private sealed record Halt(string Why, bool Final);

    private static async Task<(BatchFolderEntry Entry, Halt? Stop)> PrintOneAsync(string folder, string path, string name, IBatchQueue queue, IBatchDocuments documents,
        BatchFolderOptions options, int sheetsSoFar, CancellationToken cancel)
    {
        BatchPrintResult result;
        string? stopReason;
        bool back;
        try
        {
            var info = await queue.ReadAsync(cancel).ConfigureAwait(false);
            if (info is null)
                return (Finish(folder, path, name, BatchPrintState.Stopped, "Not sent: this printer has no queue now. It's back in the folder.", 0, back: true), new Halt("This printer has no queue now.", true));
            var measure = await BatchMeasurer.MeasureAsync(path, options.Password, documents, null, options.Print, cancel).ConfigureAwait(false);
            var line = new BatchPrintLine(path, options.Settings, measure, info);
            if (line.Problem is null && line.Sheets > options.MaxSheets)
                return (Finish(folder, path, name, BatchPrintState.Failed, $"It would print {BatchPrintText.Sheets(line.Sheets)}, more than the {options.MaxSheets:N0} a run may send. Not printed.", 0), null);
            if (line.Problem is null && sheetsSoFar + line.Sheets > options.MaxSheets)
            {
                var why = $"This run has sent {BatchPrintText.Sheets(sheetsSoFar)}, and the next file would pass the {options.MaxSheets:N0} it may send.";
                return (Finish(folder, path, name, BatchPrintState.Stopped, "Not sent: the run's limit of sheets. It's back in the folder.", 0, back: true), new Halt(why, true));
            }
            var summary = await BatchPrintRunner.RunAsync([line], queue, documents, options.Print, null, cancel).ConfigureAwait(false);
            result = summary.Items[0];
            stopReason = summary.StopReason;
            // Sure not sent: it can go back. Anything less sure stays out of the folder, so it can't print twice.
            back = result.State == BatchPrintState.Stopped;
        }
        catch (OperationCanceledException)
        {
            return (Finish(folder, path, name, BatchPrintState.Stopped, "Stopped before it was sent: it's back in the folder for next time.", 0, back: true), null);
        }
        catch (Exception ex)
        {
            // Asking the printer what it takes failed: nothing was sent.
            return (Finish(folder, path, name, BatchPrintState.Stopped, "Not sent: the printer can't be read. It's back in the folder for next time.", 0, back: true), new Halt(ex.Message, false));
        }
        if (back)
            return (Finish(folder, path, name, BatchPrintState.Stopped, $"Not sent: {stopReason} It's back in the folder for next time.", 0, back: true),
                stopReason is null ? null : new Halt(stopReason, false));
        var state = result.State == BatchPrintState.Sent ? BatchPrintState.Sent : BatchPrintState.Failed;
        return (Finish(folder, path, name, state, result.Message, result.SheetsSent),
            stopReason is null ? null : new Halt(stopReason, true));
    }

    /// <summary>Moves the original to "done", "failed" or (<paramref name="back"/>) the folder itself, and logs the line.</summary>
    private static BatchFolderEntry Finish(string folder, string path, string name, BatchPrintState state, string message, int sheets, bool back = false)
    {
        var target = back ? folder : Path.Combine(folder, state == BatchPrintState.Sent ? DropFolder.DoneFolder : DropFolder.FailedFolder);
        var moved = DropFolder.MoveTo(path, target, name);
        if (moved is null && File.Exists(path)) message += $" (the original stays in {DropFolder.WorkingFolder}: it couldn't be moved)";
        var entry = new BatchFolderEntry(DateTime.Now, name, state, message, sheets, moved);
        DropFolder.AppendLog(Path.Combine(folder, LogName), entry.LogLine);
        return entry;
    }

    /// <summary>
    /// False when a PDF, JPEG or PNG stops short of its own end: a copy that paused longer than the quiet period, or a program that
    /// writes, closes and comes back. Printing such a file wastes paper on half a document. Other kinds have no end mark to read.
    /// Only for a file that was read; one that can't be read now is left to the claim.
    /// </summary>
    public static bool LooksWhole(string path)
    {
        try
        {
            using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            return LooksWhole(file);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return true;
        }
    }

    public static bool LooksWhole(Stream file)
    {
        Span<byte> head = stackalloc byte[8];
        file.Position = 0;
        var read = file.ReadAtLeast(head, head.Length, throwOnEndOfStream: false);
        head = head[..read];
        if (read < 4) return false;

        var tail = new byte[(int)Math.Min(file.Length, 1024)];
        file.Position = file.Length - tail.Length;
        file.ReadExactly(tail);
        ReadOnlySpan<byte> end = tail;

        if (head.StartsWith("%PDF"u8)) return end.LastIndexOf("%%EOF"u8) >= 0;
        if (head[0] == 0xFF && head[1] == 0xD8) return end.LastIndexOf<byte>([0xFF, 0xD9]) >= 0;
        if (head.StartsWith<byte>([0x89, 0x50, 0x4E, 0x47])) return end.LastIndexOf("IEND"u8) >= 0;
        return true;
    }
}
