using System.Text;

namespace InkvoltPdf.Core;

/// <summary>
/// Where a launch <see cref="LaunchHandoff"/> drops leaves its arguments (Explorer's conversions, hundreds at once, while the
/// running copy doesn't answer): a folder of small files, one per launch, that the copy converting (the owner once it
/// answers again, or the one converting on its own) takes and handles as a forwarded launch. So a dropped file is still
/// converted, without a message per launch. Each launch is taken once, by one copy; the folder is bounded in count and
/// size, and what is in it is checked as a forwarded launch is (its parse refuses anything else).
/// </summary>
public static class LaunchDropBox
{
    /// <summary>Launches waiting at most: as many files as a conversion list lets wait (one file each, from Explorer).</summary>
    public const int MaxLaunches = ConvertQueue.MaxWaiting;

    /// <summary>A launch's arguments at most, in characters: as a forwarded launch's.</summary>
    public const int MaxChars = 4 << 20;

    /// <summary>Taken at most at once: the rest come at the next look.</summary>
    public const int TakeAtOnce = 500;

    /// <summary>
    /// One older than this is let go of unread: whoever selected it has stopped waiting, and a later start of the app, for
    /// something else, mustn't convert it (one left when the copy that didn't answer was ended, say).
    /// </summary>
    public static readonly TimeSpan MaxAge = TimeSpan.FromMinutes(5);

    /// <summary>What became of a launch given to <see cref="Leave"/>.</summary>
    public enum Left
    {
        /// <summary>Left for the copy that converts.</summary>
        Waiting,

        /// <summary><see cref="MaxLaunches"/> are waiting already.</summary>
        Full,

        /// <summary>Its arguments are past <see cref="MaxChars"/>, or one holds a line break (it would read as two).</summary>
        TooLong,

        /// <summary>The folder couldn't be written.</summary>
        Failed,
    }

    private const string Extension = ".launch";

    /// <summary>Leaves <paramref name="args"/> in <paramref name="folder"/>, and says whether it did and why not.</summary>
    public static Left Leave(string folder, IReadOnlyList<string> args)
    {
        var text = string.Join('\n', args);
        if (text.Length > MaxChars || args.Any(a => a.Contains('\n'))) return Left.TooLong;
        try
        {
            Directory.CreateDirectory(folder);
            if (Directory.EnumerateFiles(folder, "*" + Extension).Take(MaxLaunches).Count() >= MaxLaunches) return Left.Full;
            // Written aside, then named: a taker never reads half a launch. Named by time, so they are taken in order.
            var name = $"{NextTicks():D19}-{Guid.NewGuid():N}";
            var part = Path.Combine(folder, name + ".part");
            File.WriteAllText(part, text, new UTF8Encoding(false));
            File.Move(part, Path.Combine(folder, name + Extension));
            return Left.Waiting;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return Left.Failed;
        }
    }

    /// <summary>
    /// The conversion launches waiting (<see cref="Take"/>): only a conversion is ever left there, so anything else in the
    /// folder (written by another program of this user's) is dropped, never opened as files.
    /// </summary>
    public static IReadOnlyList<string[]> TakeConversions(string folder, DateTime? now = null) =>
        [.. Take(folder, now).Where(ConvertCommand.IsCommand)];

    /// <summary>
    /// The launches waiting in <paramref name="folder"/>, oldest first, <see cref="TakeAtOnce"/> at most: each removed as it is
    /// read, so another copy taking at the same time never gets the same one. One over the size limit, older than
    /// <see cref="MaxAge"/> or unreadable is removed unread.
    /// </summary>
    public static IReadOnlyList<string[]> Take(string folder, DateTime? now = null)
    {
        var taken = new List<string[]>();
        string[] names;
        try
        {
            if (!Directory.Exists(folder)) return taken;
            names = [.. Directory.EnumerateFiles(folder, "*" + Extension).Take(MaxLaunches)];
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return taken;
        }
        Array.Sort(names, StringComparer.Ordinal);
        var oldest = (now ?? DateTime.UtcNow) - MaxAge;
        foreach (var path in names)
        {
            if (taken.Count >= TakeAtOnce) break;
            if (!string.Equals(Path.GetExtension(path), Extension, StringComparison.OrdinalIgnoreCase)) continue;
            try
            {
                // Opened alone and removed when closed: a second taker can't open it, and finds it gone after.
                using var file = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.None, 4096, FileOptions.DeleteOnClose);
                if (File.GetLastWriteTimeUtc(path) < oldest || file.Length > (long)MaxChars * 3) continue;
                using var reader = new StreamReader(file, new UTF8Encoding(false));
                var text = reader.ReadToEnd();
                if (text.Length > MaxChars) continue;
                taken.Add(text.Split('\n', StringSplitOptions.RemoveEmptyEntries));
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // Another copy has it, or it went: not ours.
            }
        }
        LetGoOfParts(folder, oldest);
        return taken;
    }

    private static long _lastTicks;

    /// <summary>The time now, later than any this process named a launch by (two in one tick keep their order).</summary>
    private static long NextTicks()
    {
        while (true)
        {
            var seen = Volatile.Read(ref _lastTicks);
            var ticks = Math.Max(DateTime.UtcNow.Ticks, seen + 1);
            if (Interlocked.CompareExchange(ref _lastTicks, ticks, seen) == seen) return ticks;
        }
    }

    /// <summary>A launch that ended while writing leaves its part behind: removed once it is old.</summary>
    private static void LetGoOfParts(string folder, DateTime oldest)
    {
        try
        {
            foreach (var part in Directory.EnumerateFiles(folder, "*.part").Take(MaxLaunches))
                if (File.GetLastWriteTimeUtc(part) < oldest) File.Delete(part);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { }
    }
}
