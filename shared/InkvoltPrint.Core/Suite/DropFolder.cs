namespace InkvoltPrint.Core.Suite;

/// <summary>
/// What a folder that files land in needs, shared by Inkvolt PDF's watched folder and Inkvolt Print's batch print folder. A file
/// is complete when its size and time have stayed the same for a while (<see cref="DropFolderLook"/>) and it can be opened with
/// nobody else holding it (a copy in progress, even a slow network copy that sets the full size first, keeps it open); it is
/// then moved into "working" (a rename, so no other watcher or later look can take it again). Everything lives in the folder,
/// so a restart picks up where it was. A lock file keeps a second watcher off the same folder.
/// </summary>
public static class DropFolder
{
    public const string DoneFolder = "done", FailedFolder = "failed", WorkingFolder = "working";

    /// <summary>The one lock file, whichever app watches: both use "working", and each takes what's left there as interrupted.</summary>
    public const string LockName = ".inkvolt-watch.lock";

    /// <summary>The files at the top of the folder that <paramref name="isSupported"/> takes (not hidden, not temporary, not Office's "~$" owner files).</summary>
    public static IEnumerable<FileInfo> Candidates(string folder, Func<string, bool> isSupported)
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
            if (isSupported(f.Name) && !f.Name.StartsWith('.') && !f.Name.StartsWith("~$", StringComparison.Ordinal))
                yield return f;
    }

    /// <summary>
    /// Takes a complete file: open it alone (fails while anyone writes it or holds it), then move it into "working".
    /// Null: not now (still held, or gone).
    /// </summary>
    public static string? Claim(string path, string working)
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

    /// <summary>Moves a file to <paramref name="folder"/> under a free name, waiting a moment when it is briefly held (a virus scanner reading it). Null: it couldn't be moved or is gone.</summary>
    public static string? MoveTo(string path, string folder, string name)
    {
        for (var attempt = 0; attempt < 20; attempt++)
        {
            try
            {
                var to = Free(folder, name);
                File.Move(path, to);
                return to;
            }
            catch (FileNotFoundException)
            {
                return null;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                Thread.Sleep(100);
            }
        }
        return null;
    }

    /// <summary>Adds a line to the folder's log, waiting a moment when someone has it open to write.</summary>
    public static void AppendLog(string path, string line)
    {
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
                Thread.Sleep(50);
            }
            catch (UnauthorizedAccessException)
            {
                return; // read-only, or not ours to write: the log is a record, and what it records has happened
            }
        }
    }

    /// <summary>A path for <paramref name="name"/> in <paramref name="folder"/> that isn't taken ("report (2).pdf").</summary>
    public static string Free(string folder, string name)
    {
        var stem = Path.GetFileNameWithoutExtension(name);
        var ext = Path.GetExtension(name);
        for (var n = 1; ; n++)
        {
            var path = Path.Combine(folder, n == 1 ? name : $"{stem} ({n}){ext}");
            if (!File.Exists(path)) return path;
        }
    }

    /// <summary>
    /// Holds the folder's lock file for the watch (deleted when closed; the system lets go of it if the process dies).
    /// Null: another watcher has the folder.
    /// </summary>
    public static FileStream? Lock(string folder, string lockName)
    {
        var path = Path.Combine(folder, lockName);
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
            return null;
        }
    }
}

/// <summary>Which of a folder's files have stopped changing: each one's size and time when last looked at, since when they have been so, and when it was first seen.</summary>
public sealed class DropFolderLook(TimeSpan quiet)
{
    private readonly Dictionary<string, (long Size, DateTime Written, DateTime Since, DateTime First)> _seen = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Looks at the folder's files now; returns the full paths of those that have been the same for the quiet period.</summary>
    public List<string> Ready(IEnumerable<FileInfo> files, DateTime now)
    {
        var ready = new List<string>();
        var present = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var file in files)
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
            if (!_seen.TryGetValue(file.FullName, out var last))
                _seen[file.FullName] = (size, written, now, now);
            else if (last.Size != size || last.Written != written)
                _seen[file.FullName] = (size, written, now, last.First);
            else if (now - last.Since >= quiet)
                ready.Add(file.FullName);
        }
        foreach (var gone in _seen.Keys.Where(k => !present.Contains(k)).ToList()) _seen.Remove(gone);
        return ready;
    }

    /// <summary>The file was taken: it starts afresh if it ever comes back.</summary>
    public void Forget(string path) => _seen.Remove(path);

    /// <summary>Since when the file has had this size and time, or null.</summary>
    public DateTime? UnchangedSince(string path) => _seen.TryGetValue(path, out var v) ? v.Since : null;

    /// <summary>Every file there has been seen for at least <paramref name="time"/> (one still growing or held waits for the next run).</summary>
    public bool AllSeenFor(TimeSpan time, DateTime now) => _seen.Values.All(v => now - v.First >= time);
}
