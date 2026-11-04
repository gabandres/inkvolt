using System.Globalization;
using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.Core;

/// <summary>How a watched folder judges new files and how often it looks.</summary>
public sealed record WatchOptions
{
    /// <summary>How often the folder is listed.</summary>
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>A file counts as complete once its size and time haven't changed for this long (and nothing else has it open).</summary>
    public TimeSpan QuietPeriod { get; init; } = TimeSpan.FromSeconds(3);

    /// <summary>Stop once nothing has become ready for a while (a scheduled run) instead of watching until cancelled.</summary>
    public bool Once { get; init; }

    /// <summary>Most files taken out of the folder for one run (the rest wait for the next).</summary>
    public int MaxPerRun { get; init; } = 8;
}

/// <summary>A file the watched folder finished with: one line of its log.</summary>
/// <param name="FileName">The file's name as it arrived.</param>
/// <param name="MovedTo">Where the original went (done, failed, or back into the folder after a stop).</param>
public sealed record WatchEntry(DateTime Time, string FileName, BatchItemState State, string Message, IReadOnlyList<string> Outputs, string? MovedTo)
{
    /// <summary>Time, state, file name, what happened, the results ("; " between them): tab-separated, for a spreadsheet or a script.</summary>
    public string LogLine => string.Join('\t',
        Time.ToString("yyyy-MM-dd HH:mm:ss", CultureInfo.InvariantCulture),
        State.ToString().ToLowerInvariant(),
        FileName,
        Message.ReplaceLineEndings(" "),
        string.Join("; ", Outputs));
}

/// <param name="Working">Files being worked on now (0: waiting for files).</param>
/// <param name="Finished">Set when a file is finished.</param>
public sealed record WatchProgress(int Working, WatchEntry? Finished = null);

/// <param name="Done">Files done.</param>
/// <param name="Failed">Files that failed or were skipped (moved to "failed").</param>
public sealed record WatchSummary(int Done, int Failed);

/// <summary>The folder is watched already (by the app or a command line): two watchers would race for its files.</summary>
public sealed class FolderWatchedException(string folder)
    : IOException(Loc.Format(PdfStrings.Batch_FolderWatched, folder));

/// <summary>
/// A watched folder: each PDF or image that lands in the folder (not its subfolders) is run through a batch plan once it
/// is complete, then the original is moved to "done" or "failed" below the folder and a line is added to
/// <see cref="LogName"/> there. A file is complete when its size and last-write time have stayed the same for
/// <see cref="WatchOptions.QuietPeriod"/> and it can be opened with nobody else holding it (a copy in progress, even a
/// slow network copy that sets the full size first, keeps it open); it is then moved into "working" (a rename, so no other
/// watcher or later look can take it again) and run from there. Everything lives in the folder, so a restart picks up
/// where it was: files left in "working" by a run that never finished (the app closed, the PC lost power) go to "failed"
/// with a note, never through again, so a file that brings the app down can't do it twice. A lock file keeps a second
/// watcher (the app and a command line) off the same folder. Passwords are never asked: files that need one fail.
/// </summary>
public static class WatchedFolder
{
    public const string DoneFolder = DropFolder.DoneFolder, FailedFolder = DropFolder.FailedFolder, WorkingFolder = DropFolder.WorkingFolder, ResultsFolder = "results";
    public const string LogName = "inkvolt-watch.log";
    private const string LockName = DropFolder.LockName;

    /// <summary>The results folder a watched folder uses when its preset names none.</summary>
    public static string DefaultOutput(string folder) => Path.Combine(folder, ResultsFolder);

    /// <summary>What is wrong with watching <paramref name="folder"/> into <paramref name="outputFolder"/>, or null.</summary>
    public static string? Validate(string folder, string outputFolder)
    {
        if (string.IsNullOrWhiteSpace(folder) || !Path.IsPathFullyQualified(folder)) return PdfStrings.Batch_WatchChooseFolder;
        if (!Directory.Exists(folder)) return Loc.Format(PdfStrings.Batch_WatchNoFolder, folder);
        if (string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(outputFolder)),
                StringComparison.OrdinalIgnoreCase))
            return PdfStrings.Batch_WatchResultsInside;
        return null;
    }

    /// <summary>
    /// Watches <paramref name="folder"/> until <paramref name="cancel"/> (or, with <see cref="WatchOptions.Once"/>, until
    /// nothing more becomes ready). A stop lets the files being worked on finish their current action; those not finished
    /// go back into the folder for next time (or to "failed" when they had written results already).
    /// </summary>
    /// <exception cref="ArgumentException">The plan or folders aren't valid.</exception>
    /// <exception cref="FolderWatchedException">Another watcher has the folder.</exception>
    public static async Task<WatchSummary> RunAsync(string folder, BatchPlan plan, BatchHost host, WatchOptions? options, IProgress<WatchProgress>? progress,
        CancellationToken cancel)
    {
        options ??= new WatchOptions();
        folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        if (Validate(folder, plan.OutputFolder) is { } folderError) throw new ArgumentException(folderError, nameof(folder));
        plan = plan with { Passwords = PasswordPolicy.Skip, KeepSubfolders = false };
        host = new BatchHost { Recognize = host.Recognize, Recognizer = host.Recognizer }; // no prompts: nobody may be there to answer
        if (plan.Validate(host.Recognize is not null) is { } planError) throw new ArgumentException(planError, nameof(plan));

        using var held = DropFolder.Lock(folder, LockName) ?? throw new FolderWatchedException(folder);
        var working = Directory.CreateDirectory(Path.Combine(folder, WorkingFolder)).FullName;
        Directory.CreateDirectory(Path.Combine(folder, DoneFolder));
        Directory.CreateDirectory(Path.Combine(folder, FailedFolder));
        int done = 0, failed = 0;

        // A run that never finished: its files go to "failed", not through again.
        foreach (var left in Directory.EnumerateFiles(working).Order(StringComparer.OrdinalIgnoreCase))
        {
            var entry = Finish(folder, left, Path.GetFileName(left), BatchItemState.Failed,
                PdfStrings.Batch_WatchInterrupted, []);
            failed++;
            progress?.Report(new WatchProgress(0, entry));
        }

        var look = new DropFolderLook(options.QuietPeriod);
        while (!cancel.IsCancellationRequested)
        {
            var now = DateTime.UtcNow;
            var ready = look.Ready(DropFolder.Candidates(folder, BatchFiles.IsSupported), now);

            var claimed = new List<(string Name, string Path)>();
            foreach (var path in ready)
            {
                if (claimed.Count >= Math.Max(1, options.MaxPerRun)) break;
                if (DropFolder.Claim(path, working) is { } moved)
                {
                    claimed.Add((Path.GetFileName(path), moved));
                    look.Forget(path);
                }
            }

            if (claimed.Count > 0)
            {
                var (d, f) = await RunClaimedAsync(folder, claimed, plan, host, progress, cancel).ConfigureAwait(false);
                done += d;
                failed += f;
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
        return new WatchSummary(done, failed);
    }

    private static async Task<(int Done, int Failed)> RunClaimedAsync(string folder, List<(string Name, string Path)> claimed, BatchPlan plan, BatchHost host,
        IProgress<WatchProgress>? progress, CancellationToken cancel)
    {
        progress?.Report(new WatchProgress(claimed.Count));
        var files = claimed.Select(c => new BatchFile(c.Path, "", Path.Combine(folder, c.Name))).ToList();
        BatchSummary summary;
        try
        {
            summary = await BatchRunner.RunAsync(files, plan with { Date = DateTime.Now }, host, null, cancel).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            summary = new BatchSummary([.. files.Select(f => new BatchItemResult(f, BatchItemState.Failed, BatchRunner.Describe(ex), [], []))]);
        }
        int done = 0, failed = 0;
        for (var i = 0; i < claimed.Count; i++)
        {
            var (name, path) = claimed[i];
            var r = summary.Items[i];
            var message = r.Notes.Count > 0 ? $"{r.Message} ({string.Join("; ", r.Notes)})" : r.Message;
            WatchEntry entry;
            if (r.State == BatchItemState.Cancelled && r.Outputs.Count == 0)
                entry = Finish(folder, path, name, r.State, PdfStrings.Batch_WatchStoppedBefore, [], back: true);
            else
            {
                var state = r.State == BatchItemState.Cancelled ? BatchItemState.Failed : r.State;
                if (r.State == BatchItemState.Cancelled) message = PdfStrings.Batch_WatchStoppedPartWay;
                entry = Finish(folder, path, name, state, message, r.Outputs);
                if (state == BatchItemState.Done) done++;
                else failed++;
            }
            progress?.Report(new WatchProgress(claimed.Count - i - 1, entry));
        }
        return (done, failed);
    }

    /// <summary>Moves the original to "done", "failed" or (<paramref name="back"/>) the folder itself, and logs the line.</summary>
    private static WatchEntry Finish(string folder, string path, string name, BatchItemState state, string message, IReadOnlyList<string> outputs, bool back = false)
    {
        var target = back ? folder : Path.Combine(folder, state == BatchItemState.Done ? DoneFolder : FailedFolder);
        var moved = DropFolder.MoveTo(path, target, name);
        if (moved is null && File.Exists(path)) message += Loc.Format(PdfStrings.Batch_WatchOriginalStays, WorkingFolder);
        var entry = new WatchEntry(DateTime.Now, name, state, message, outputs, moved);
        DropFolder.AppendLog(Path.Combine(folder, LogName), entry.LogLine);
        return entry;
    }
}
