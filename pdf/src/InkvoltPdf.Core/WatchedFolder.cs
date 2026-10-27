using System.Globalization;

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
    : IOException($"{folder} is already watched by another Inkvolt PDF (the app or a command line). Stop that one first.");

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
    public const string DoneFolder = "done", FailedFolder = "failed", WorkingFolder = "working", ResultsFolder = "results";
    public const string LogName = "inkvolt-watch.log";
    private const string LockName = ".inkvolt-watch.lock";

    /// <summary>The results folder a watched folder uses when its preset names none.</summary>
    public static string DefaultOutput(string folder) => Path.Combine(folder, ResultsFolder);

    /// <summary>What is wrong with watching <paramref name="folder"/> into <paramref name="outputFolder"/>, or null.</summary>
    public static string? Validate(string folder, string outputFolder)
    {
        if (string.IsNullOrWhiteSpace(folder) || !Path.IsPathFullyQualified(folder)) return "Choose the folder to watch.";
        if (!Directory.Exists(folder)) return $"There is no folder {folder}.";
        if (string.Equals(Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder)), Path.TrimEndingDirectorySeparator(Path.GetFullPath(outputFolder)),
                StringComparison.OrdinalIgnoreCase))
            return "The results can't go into the watched folder itself (they would be picked up again): use a subfolder such as \"results\", or another folder.";
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
        host = new BatchHost { Recognize = host.Recognize }; // no prompts: nobody may be there to answer
        if (plan.Validate(host.Recognize is not null) is { } planError) throw new ArgumentException(planError, nameof(plan));

        using var held = Lock(folder);
        var working = Directory.CreateDirectory(Path.Combine(folder, WorkingFolder)).FullName;
        Directory.CreateDirectory(Path.Combine(folder, DoneFolder));
        Directory.CreateDirectory(Path.Combine(folder, FailedFolder));
        int done = 0, failed = 0;

        // A run that never finished: its files go to "failed", not through again.
        foreach (var left in Directory.EnumerateFiles(working).Order(StringComparer.OrdinalIgnoreCase))
        {
            var entry = Finish(folder, left, Path.GetFileName(left), BatchItemState.Failed,
                "Interrupted: Inkvolt PDF closed while working on it. Put it back in the folder to run it again.", []);
            failed++;
            progress?.Report(new WatchProgress(0, entry));
        }

        // Each file's size and time when last looked at, since when they have been so, and when it was first seen.
        var seen = new Dictionary<string, (long Size, DateTime Written, DateTime Since, DateTime First)>(StringComparer.OrdinalIgnoreCase);
        while (!cancel.IsCancellationRequested)
        {
            var now = DateTime.UtcNow;
            var ready = new List<string>();
            var present = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var file in Candidates(folder))
            {
                present.Add(file.FullName);
                long size;
                DateTime written;
                try
                {
                    file.Refresh();
                    if (!file.Exists) continue;
                    (size, written) = (file.Length, file.LastWriteTimeUtc);
                }
                catch (IOException)
                {
                    continue;
                }
                if (!seen.TryGetValue(file.FullName, out var last))
                    seen[file.FullName] = (size, written, now, now);
                else if (last.Size != size || last.Written != written)
                    seen[file.FullName] = (size, written, now, last.First);
                else if (now - last.Since >= options.QuietPeriod)
                    ready.Add(file.FullName);
            }
            foreach (var gone in seen.Keys.Where(k => !present.Contains(k)).ToList()) seen.Remove(gone);

            var claimed = new List<(string Name, string Path)>();
            foreach (var path in ready)
            {
                if (claimed.Count >= Math.Max(1, options.MaxPerRun)) break;
                if (Claim(path, working) is { } moved)
                {
                    claimed.Add((Path.GetFileName(path), moved));
                    seen.Remove(path);
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
            if (options.Once && seen.Values.All(v => now - v.First >= options.QuietPeriod + options.PollInterval)) break;
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

    /// <summary>The PDFs and images at the top of the folder (not hidden, not temporary, not Office's "~$" owner files).</summary>
    private static IEnumerable<FileInfo> Candidates(string folder)
    {
        IEnumerable<FileInfo> files;
        try
        {
            files = new DirectoryInfo(folder).EnumerateFiles("*", new EnumerationOptions
            {
                IgnoreInaccessible = true,
                AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.ReparsePoint | FileAttributes.Temporary,
            }).ToList();
        }
        catch (IOException)
        {
            yield break; // the folder is away for a moment (a network drop): look again next time
        }
        foreach (var f in files)
            if (BatchFiles.IsSupported(f.Name) && !f.Name.StartsWith('.') && !f.Name.StartsWith("~$", StringComparison.Ordinal))
                yield return f;
    }

    /// <summary>
    /// Takes a complete file: open it alone (fails while anyone writes it or holds it), then move it into "working".
    /// Null: not now (still held, or gone).
    /// </summary>
    private static string? Claim(string path, string working)
    {
        try
        {
            using (new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None)) { }
            var target = Free(working, Path.GetFileName(path));
            File.Move(path, target);
            return target;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
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
                entry = Finish(folder, path, name, r.State, "Stopped before it was done: left in the folder for next time", [], back: true);
            else
            {
                var state = r.State == BatchItemState.Cancelled ? BatchItemState.Failed : r.State;
                if (r.State == BatchItemState.Cancelled) message = "Stopped part-way (some results were written)";
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
        string? moved = null;
        for (var attempt = 0; attempt < 20 && moved is null; attempt++)
        {
            try
            {
                var to = Free(target, name);
                File.Move(path, to);
                moved = to;
            }
            catch (FileNotFoundException)
            {
                break;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(100); // briefly held (a virus scanner reading it): try again
            }
        }
        if (moved is null && File.Exists(path)) message += $" (the original stays in {WorkingFolder}: it couldn't be moved)";
        var entry = new WatchEntry(DateTime.Now, name, state, message, outputs, moved);
        AppendLog(folder, entry.LogLine);
        return entry;
    }

    private static void AppendLog(string folder, string line)
    {
        var path = Path.Combine(folder, LogName);
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                using var log = new FileStream(path, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                using var writer = new StreamWriter(log);
                writer.Write(line + Environment.NewLine);
                return;
            }
            catch (IOException)
            {
                Thread.Sleep(50); // someone has it open to write: wait a moment
            }
        }
    }

    /// <summary>A path for <paramref name="name"/> in <paramref name="folder"/> that isn't taken ("report (2).pdf").</summary>
    private static string Free(string folder, string name)
    {
        var stem = Path.GetFileNameWithoutExtension(name);
        var ext = Path.GetExtension(name);
        for (var n = 1; ; n++)
        {
            var path = Path.Combine(folder, n == 1 ? name : $"{stem} ({n}){ext}");
            if (!File.Exists(path)) return path;
        }
    }

    /// <summary>Holds the folder's lock file for the watch (deleted when closed; the system lets go of it if the process dies).</summary>
    private static FileStream Lock(string folder)
    {
        var path = Path.Combine(folder, LockName);
        try
        {
            var stream = new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None, 1, FileOptions.DeleteOnClose);
            try
            {
                File.SetAttributes(path, FileAttributes.Hidden);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
            return stream;
        }
        catch (IOException ex) when (ex is not FileNotFoundException and not DirectoryNotFoundException)
        {
            throw new FolderWatchedException(folder);
        }
    }
}
