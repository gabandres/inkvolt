using System.Text;
using System.Text.Json;

namespace InkvoltPrint.Core.History;

/// <summary>
/// Where the print log is kept (roadmap 4.9): one file beside <c>state.json</c>, a JSON line per job, appended as jobs finish and written
/// again, trimmed, once it holds a fifth more than <see cref="PrintLog.MaxEntries"/>. Read back as hostile input: a file past
/// <see cref="MaxFileBytes"/> is started again, a line past <see cref="MaxLineBytes"/> or that isn't an entry is skipped, every entry is
/// cleaned (<see cref="PrintLog.Clean"/>). Never throws for a file it can't read or write: the log is a nicety. Thread-safe.
/// </summary>
/// <param name="path">The file; null keeps the log in memory (demo mode).</param>
public sealed class PrintLogFile(string? path, Action<string>? log = null)
{
    public const int MaxFileBytes = 16 * 1024 * 1024, MaxLineBytes = 4096;

    private static readonly JsonSerializerOptions Json = new() { Converters = { new System.Text.Json.Serialization.JsonStringEnumConverter() } };

    private readonly Lock _gate = new();
    private List<PrintLogEntry>? _entries;
    private int _lines;
    private DateTimeOffset _rewritten = DateTimeOffset.MinValue;

    /// <summary>The log, oldest first.</summary>
    public IReadOnlyList<PrintLogEntry> Read(DateTimeOffset now)
    {
        lock (_gate) return [.. Load(now).List];
    }

    /// <summary>Adds the jobs and saves.</summary>
    public void Add(IReadOnlyList<PrintLogEntry> entries, DateTimeOffset now)
    {
        if (entries.Count == 0) return;
        lock (_gate)
        {
            var (list, loaded) = Load(now);
            var added = entries.Select(PrintLog.Clean).OfType<PrintLogEntry>().ToList();
            list.AddRange(added);
            // Trimmed in memory; the file only gets the new lines, and is written again (trimmed) once it holds a fifth more than the log
            // keeps, or at most once a day when jobs have aged out. A file that couldn't be read is never written over: only appended to.
            var aged = list.RemoveAll(e => e.At < now.AddMonths(-PrintLog.KeepMonths));
            if (list.Count > PrintLog.MaxEntries) list.RemoveRange(0, list.Count - PrintLog.MaxEntries);
            _lines += added.Count;
            if (path is null) return;
            if (loaded && (_lines > PrintLog.MaxEntries * 6 / 5 || (aged > 0 && now - _rewritten > TimeSpan.FromDays(1))))
            {
                Rewrite(list);
                _rewritten = now;
            }
            else Append(added);
        }
    }

    /// <summary>Forgets every job (the file is deleted).</summary>
    public void Clear()
    {
        lock (_gate)
        {
            _entries = [];
            _lines = 0;
            if (path is null) return;
            try
            {
                File.Delete(path);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                log?.Invoke($"Print log not cleared: {ex.Message}");
            }
        }
    }

    /// <summary>The log as read from a file's text (for tests and <see cref="Load"/>): bounded, cleaned, oldest first.</summary>
    public static List<PrintLogEntry> Parse(IEnumerable<string> lines, DateTimeOffset now)
    {
        var list = new List<PrintLogEntry>();
        foreach (var line in lines)
        {
            if (line.Length == 0 || line.Length > MaxLineBytes) continue;
            try
            {
                if (PrintLog.Clean(JsonSerializer.Deserialize<PrintLogEntry>(line, Json)) is { } entry) list.Add(entry);
            }
            catch (Exception ex) when (ex is JsonException or NotSupportedException or ArgumentException or InvalidOperationException)
            {
                // not an entry: skipped
            }
            if (list.Count > PrintLog.MaxEntries * 2) list.RemoveRange(0, PrintLog.MaxEntries);
        }
        list.Sort((a, b) => a.At.CompareTo(b.At));
        return PrintLog.Trim(list, now);
    }

    /// <summary>One entry as its line.</summary>
    public static string Line(PrintLogEntry entry) => JsonSerializer.Serialize(entry, Json);

    /// <summary>
    /// The log as kept, read from the file the first time. A read that fails (the file locked, a disk away) isn't kept: an empty list for
    /// now (<c>Loaded</c> false, so nothing writes over the file), and the next call reads again.
    /// </summary>
    private (List<PrintLogEntry> List, bool Loaded) Load(DateTimeOffset now)
    {
        if (_entries is not null) return (_entries, true);
        if (path is null) return (_entries = [], true);
        try
        {
            if (!File.Exists(path)) return (_entries = [], true);
            if (new FileInfo(path).Length > MaxFileBytes)
            {
                log?.Invoke("Print log file too large, starting it again");
                File.Delete(path);
                _lines = 0;
                return (_entries = [], true);
            }
            var lines = File.ReadLines(path, Encoding.UTF8).ToList();
            _lines = lines.Count;
            return (_entries = Parse(lines, now), true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log?.Invoke($"Print log not read: {ex.Message}");
            return ([], false);
        }
    }

    private void Append(List<PrintLogEntry> added)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            File.AppendAllText(path!, string.Concat(added.Select(e => Line(e) + "\n")), new UTF8Encoding(false));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log?.Invoke($"Print log not saved: {ex.Message}");
        }
    }

    private void Rewrite(List<PrintLogEntry> list)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            var tmp = path + ".tmp";
            File.WriteAllText(tmp, string.Concat(list.Select(e => Line(e) + "\n")), new UTF8Encoding(false));
            File.Move(tmp, path!, overwrite: true);
            _lines = list.Count;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            log?.Invoke($"Print log not saved: {ex.Message}");
        }
    }
}
