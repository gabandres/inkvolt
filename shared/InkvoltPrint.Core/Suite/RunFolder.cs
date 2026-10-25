namespace InkvoltPrint.Core.Suite;

/// <summary>
/// A folder of this run's own under a root, for work kept on disk in case the app doesn't get to close normally (Inkvolt
/// PDF's recovery copies, Inkvolt Print's unsaved scans). A lock file in it is held open while the run lives, with
/// delete-on-close, so Windows removes it when the process ends in any way: a folder without a held lock belongs to a run
/// that ended without a clean exit, and the next start can offer what it left. A clean exit (<see cref="Dispose"/>)
/// deletes the folder.
/// </summary>
public sealed class RunFolder : IDisposable
{
    private const string LockName = "running.lock";

    private FileStream? _lock;

    private RunFolder(string path, FileStream lockFile) => (Path, _lock) = (path, lockFile);

    public string Path { get; }

    /// <summary>Makes this run's folder under <paramref name="root"/> and holds its lock.</summary>
    public static RunFolder Start(string root)
    {
        var path = System.IO.Path.Combine(root, $"{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(path);
        var lockFile = new FileStream(System.IO.Path.Combine(path, LockName), FileMode.CreateNew, FileAccess.ReadWrite, FileShare.None, 1,
            FileOptions.DeleteOnClose);
        return new RunFolder(path, lockFile);
    }

    /// <summary>The folders under <paramref name="root"/> whose run ended without a clean exit (oldest first).</summary>
    public static IReadOnlyList<string> LeftOver(string root) =>
        Directory.Exists(root) ? [.. Directory.GetDirectories(root).Where(f => !IsRunning(f)).Order(StringComparer.Ordinal)] : [];

    /// <summary>Deletes a left-over folder (never a running one's). Best effort.</summary>
    public static void Delete(string folder)
    {
        try
        {
            if (Directory.Exists(folder) && !IsRunning(folder)) Directory.Delete(folder, recursive: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    private static bool IsRunning(string folder)
    {
        var lockPath = System.IO.Path.Combine(folder, LockName);
        if (!File.Exists(lockPath)) return false;
        try
        {
            using var _ = new FileStream(lockPath, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            return false;
        }
        catch (IOException)
        {
            return true; // held open by its run
        }
        catch (UnauthorizedAccessException)
        {
            return true; // a delete-on-close lock being torn down, or not ours to judge: leave it
        }
    }

    /// <summary>
    /// Writes a file so a crash part way leaves the old one or none, never half of one: a flushed temp file beside it,
    /// then moved into place.
    /// </summary>
    public static void WriteAtomic(string path, Action<Stream> write)
    {
        var temp = path + ".tmp";
        using (var stream = new FileStream(temp, FileMode.Create, FileAccess.Write, FileShare.None, 1 << 16))
        {
            write(stream);
            stream.Flush(flushToDisk: true);
        }
        File.Move(temp, path, overwrite: true);
    }

    /// <summary>Deletes a file, best effort.</summary>
    public static void TryDelete(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }

    /// <summary>Ends the run as a crash would: the lock goes (as Windows closes a dead process's handles) and the folder stays (tests).</summary>
    public void Abandon()
    {
        _lock?.Dispose();
        _lock = null;
    }

    /// <summary>A clean exit: the folder and everything in it go.</summary>
    public void Dispose()
    {
        if (_lock is null) return;
        _lock.Dispose();
        _lock = null;
        try
        {
            Directory.Delete(Path, recursive: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
    }
}
