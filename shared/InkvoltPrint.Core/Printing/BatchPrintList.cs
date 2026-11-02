using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace InkvoltPrint.Core.Printing;

/// <summary>A list can't be used; the message says why.</summary>
public class BatchListException(string message) : Exception(message);

/// <summary>The list points at files on other computers, which it can't open until someone agrees: reaching a server shares this PC's sign-in with it.</summary>
public sealed class BatchListNetworkException(IReadOnlyList<string> servers)
    : BatchListException($"This list points at files on other computers ({string.Join(", ", servers.Select(BatchPrintText.Clean))}).")
{
    public IReadOnlyList<string> Servers { get; } = servers;
}

/// <summary>A line of a list: a file or a folder (its printable files in Explorer's order), and how they print.</summary>
public sealed record BatchListEntry(string Path, BatchPrintSettings Settings);

/// <summary>
/// A saved batch (roadmap 2.4, Pro): plain JSON a person or a script can write. Passwords are never in it. A list is treated as
/// something that may have come from anywhere: every path is checked before the disk or the network is touched. Relative
/// paths are from the list's own folder and stay below it; device names, alternate data streams, web addresses and anything
/// but a PDF, a picture or a folder are refused; another computer's files need the person's say-so. A bad value (copies 9999) refuses the
/// list rather than being changed quietly. Nothing is ever printed by opening a list.
/// </summary>
public static class BatchPrintList
{
    public const string Extension = ".inkvoltlist";
    private const int Version = 1;
    private const long MaxFileBytes = 4L << 20;
    private const int MaxRange = 1000;

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNameCaseInsensitive = true,
        AllowTrailingCommas = true,
        ReadCommentHandling = JsonCommentHandling.Skip,
        MaxDepth = 8,
        WriteIndented = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private sealed class ListFile
    {
        public int Version { get; set; }
        public ListDefaults? Defaults { get; set; }
        public List<ListLine>? Files { get; set; }
    }

    private sealed class ListDefaults
    {
        public int? Copies { get; set; }
        public bool? TwoSided { get; set; }
        public string? Paper { get; set; }
    }

    private sealed class ListLine
    {
        public string? Path { get; set; }
        public int? Copies { get; set; }
        public string? Range { get; set; }
        public bool? TwoSided { get; set; }
        public string? Paper { get; set; }
    }

    /// <summary>Writes the list whole or not at all: full paths, default values left out, no passwords (the entries don't carry any).</summary>
    public static void Save(string path, IEnumerable<BatchListEntry> entries)
    {
        var file = new ListFile
        {
            Version = Version,
            Files = entries.Select(e => new ListLine
            {
                Path = e.Path,
                Copies = e.Settings.Copies == 1 ? null : e.Settings.Copies,
                Range = string.IsNullOrWhiteSpace(e.Settings.Range) ? null : e.Settings.Range,
                TwoSided = e.Settings.TwoSided ? true : null,
                Paper = e.Settings.Paper,
            }).ToList(),
        };
        var temp = path + ".tmp";
        File.WriteAllText(temp, JsonSerializer.Serialize(file, Json), new UTF8Encoding(false));
        File.Move(temp, path, overwrite: true);
    }

    /// <summary>Reads a list. Only the list file itself is touched; each line's path is checked by words alone.</summary>
    /// <param name="allowNetwork">Files on other computers may be opened (the person said so).</param>
    /// <exception cref="BatchListException">It can't be used, and says why; <see cref="BatchListNetworkException"/> when it only needs that say-so.</exception>
    public static List<BatchListEntry> Load(string path, bool allowNetwork)
    {
        byte[] bytes;
        try
        {
            var info = new FileInfo(path);
            if (!info.Exists) throw new BatchListException($"There is no list file {BatchPrintText.Clean(path)}.");
            if (info.Length > MaxFileBytes) throw new BatchListException("This list file is too large.");
            bytes = File.ReadAllBytes(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            throw new BatchListException($"The list file can't be read: {ex.Message}");
        }

        ListFile file;
        try
        {
            file = JsonSerializer.Deserialize<ListFile>(bytes, Json) ?? throw new BatchListException("This isn't a batch list: it's empty.");
        }
        catch (JsonException)
        {
            throw new BatchListException("This isn't a batch list, or it's damaged.");
        }
        if (file.Version > Version) throw new BatchListException("This list was made by a newer Inkvolt Print: update it to open the list.");
        if (file.Version < 1 || file.Files is null) throw new BatchListException("This isn't a batch list: it says no version or no files.");
        if (file.Files.Count > BatchPrintLimits.MaxFiles) throw new BatchListException($"This list has {file.Files.Count:N0} lines: a batch takes at most {BatchPrintLimits.MaxFiles:N0} files.");

        var folder = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!;
        var entries = new List<BatchListEntry>(file.Files.Count);
        var servers = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (line, n) in file.Files.Select((l, i) => (l, i + 1)))
        {
            if (line is null) throw new BatchListException($"Line {n} of the list: it has no path, or too long a one.");
            if (CheckPath(line.Path, folder, out var server, out var why) is not { } full) throw new BatchListException($"Line {n} of the list: {why}");
            if (server is not null) servers.Add(server);
            var copies = line.Copies ?? file.Defaults?.Copies ?? 1;
            if (copies is < 1 or > BatchPrintLimits.MaxCopies) throw new BatchListException($"Line {n} of the list: copies must be 1 to {BatchPrintLimits.MaxCopies} ({copies} asked for).");
            if (line.Range is { Length: > MaxRange }) throw new BatchListException($"Line {n} of the list: its pages are too long a text.");
            var paper = line.Paper ?? file.Defaults?.Paper;
            if (paper is { Length: > 200 }) throw new BatchListException($"Line {n} of the list: its paper is too long a text.");
            entries.Add(new BatchListEntry(full, new BatchPrintSettings(copies, line.Range, line.TwoSided ?? file.Defaults?.TwoSided ?? false, paper)));
        }
        if (servers.Count > 0 && !allowNetwork) throw new BatchListNetworkException(servers.ToList());
        return entries;
    }

    /// <summary>
    /// The list's lines as files: a folder's printable files in order with the line's settings. A line whose file isn't there stays,
    /// and reads as gone like a file that vanished after the estimate. Anything else that isn't a PDF or a picture refuses the list.
    /// </summary>
    /// <exception cref="BatchListException">A line names something else, or there are too many files.</exception>
    public static List<BatchListEntry> Expand(IReadOnlyList<BatchListEntry> entries)
    {
        var files = new List<BatchListEntry>(entries.Count);
        foreach (var entry in entries)
        {
            if (Directory.Exists(entry.Path)) files.AddRange(BatchPrintFiles.ListFolder(entry.Path, recursive: false).Select(f => entry with { Path = f }));
            else if (BatchPrintFiles.IsSupported(entry.Path)) files.Add(entry);
            else throw new BatchListException($"The list names {BatchPrintText.Clean(entry.Path)}, which is neither a PDF, a picture nor a folder.");
            if (files.Count > BatchPrintLimits.MaxFiles) throw new BatchListException($"This list comes to more than {BatchPrintLimits.MaxFiles:N0} files, the most a batch takes.");
        }
        return files;
    }

    /// <summary>
    /// A line's path made full and checked without touching anything. Null and <paramref name="why"/> when it's refused;
    /// <paramref name="server"/> names the computer when it is another's.
    /// </summary>
    public static string? CheckPath(string? raw, string listFolder, out string? server, out string? why)
    {
        server = null;
        why = null;
        if (string.IsNullOrWhiteSpace(raw) || raw.Length > 4000) return Refuse("it has no path, or too long a one.", out why);
        var shown = BatchPrintText.Clean(raw);
        if (raw.Any(c => char.IsControl(c) || c is '<' or '>' or '"' or '|' or '?' or '*'))
        {
            // \\?\ and \\.\ reach devices and raw paths; the characters can't be in a file's name anyway.
            return Refuse($"\"{shown}\" isn't a path a list may use.", out why);
        }
        var slashed = raw.Replace('/', '\\');
        var isUnc = slashed.StartsWith(@"\\", StringComparison.Ordinal);
        var hasDrive = slashed.Length >= 3 && char.IsAsciiLetter(slashed[0]) && slashed[1] == ':' && slashed[2] == '\\';
        var relative = !isUnc && !hasDrive && !slashed.StartsWith('\\') && !(slashed.Length >= 2 && slashed[1] == ':');
        if (!isUnc && !hasDrive && !relative) return Refuse($"\"{shown}\" isn't a full path, or one from the list's folder.", out why);
        // Past a drive's colon, a colon is a web address or an alternate data stream.
        if (slashed.IndexOf(':', hasDrive ? 2 : 0) >= 0) return Refuse($"\"{shown}\" isn't a file on this PC.", out why);

        string full;
        try
        {
            full = System.IO.Path.GetFullPath(relative ? System.IO.Path.Combine(listFolder, slashed) : slashed);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return Refuse($"\"{shown}\" isn't a path a list may use.", out why);
        }
        foreach (var part in full.Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            var stem = part.Split('.')[0].TrimEnd(' ');
            if (stem.ToUpperInvariant() is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$"
                || (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase) || stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) && (char.IsDigit(stem[3]) || stem[3] is '¹' or '²' or '³')))
                return Refuse($"\"{shown}\" names a device.", out why);
        }
        if (relative)
        {
            var below = System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(listFolder)) + "\\";
            if (!full.StartsWith(below, StringComparison.OrdinalIgnoreCase)) return Refuse($"\"{shown}\" leaves the list's folder: use a full path for that.", out why);
        }
        if (isUnc)
        {
            var name = full.TrimStart('\\').Split('\\')[0];
            if (name is "." or "?" or "") return Refuse($"\"{shown}\" isn't a file on this PC.", out why);
            server = name;
        }
        return full;

        static string? Refuse(string text, out string? reason)
        {
            reason = text;
            return null;
        }
    }
}
