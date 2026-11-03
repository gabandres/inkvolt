using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace InkvoltPrint.Core.Printing;

/// <summary>A list can't be used; the message says why.</summary>
public class BatchListException(string message) : Exception(message);

/// <summary>The list points at files on other computers, which it can't open until someone agrees: reaching a server shares this PC's sign-in with it.</summary>
public sealed class BatchListNetworkException(IReadOnlyList<string> servers)
    : BatchListException(string.Format(CoreStrings.Batch_ListNetwork, string.Join(", ", servers.Select(BatchPrintText.Clean))))
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
            if (!info.Exists) throw new BatchListException(string.Format(CoreStrings.Batch_ListMissing, BatchPrintText.Clean(path)));
            if (info.Length > MaxFileBytes) throw new BatchListException(CoreStrings.Batch_ListTooLarge);
            bytes = File.ReadAllBytes(path);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
        {
            throw new BatchListException(string.Format(CoreStrings.Batch_ListCantRead, ex.Message));
        }

        ListFile file;
        try
        {
            file = JsonSerializer.Deserialize<ListFile>(WithoutByteOrderMark(bytes), Json) ?? throw new BatchListException(CoreStrings.Batch_ListEmpty);
        }
        catch (JsonException)
        {
            throw new BatchListException(CoreStrings.Batch_ListDamaged);
        }
        if (file.Version > Version) throw new BatchListException(CoreStrings.Batch_ListNewer);
        if (file.Version < 1 || file.Files is null) throw new BatchListException(CoreStrings.Batch_ListNoVersion);
        if (file.Files.Count > BatchPrintLimits.MaxFiles) throw new BatchListException(string.Format(CoreStrings.Batch_ListTooManyLines, file.Files.Count, BatchPrintLimits.MaxFiles));

        var folder = System.IO.Path.GetDirectoryName(System.IO.Path.GetFullPath(path))!;
        var entries = new List<BatchListEntry>(file.Files.Count);
        var servers = new SortedSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var (line, n) in file.Files.Select((l, i) => (l, i + 1)))
        {
            if (line is null) throw new BatchListException(string.Format(CoreStrings.Batch_ListLine, n, CoreStrings.Batch_PathNone));
            if (CheckPath(line.Path, folder, out var server, out var why) is not { } full) throw new BatchListException(string.Format(CoreStrings.Batch_ListLine, n, why));
            if (server is not null) servers.Add(server);
            var copies = line.Copies ?? file.Defaults?.Copies ?? 1;
            if (copies is < 1 or > BatchPrintLimits.MaxCopies) throw new BatchListException(string.Format(CoreStrings.Batch_ListLine, n, string.Format(CoreStrings.Batch_ListCopies, BatchPrintLimits.MaxCopies, copies)));
            if (line.Range is { Length: > MaxRange }) throw new BatchListException(string.Format(CoreStrings.Batch_ListLine, n, CoreStrings.Batch_ListPagesTooLong));
            var paper = line.Paper ?? file.Defaults?.Paper;
            if (paper is { Length: > 200 }) throw new BatchListException(string.Format(CoreStrings.Batch_ListLine, n, CoreStrings.Batch_ListPaperTooLong));
            entries.Add(new BatchListEntry(full, new BatchPrintSettings(copies, line.Range, line.TwoSided ?? file.Defaults?.TwoSided ?? false, paper)));
        }
        if (servers.Count > 0 && !allowNetwork) throw new BatchListNetworkException(servers.ToList());
        return entries;
    }

    /// <summary>The list as plain UTF-8: Notepad and Windows PowerShell write a byte order mark, and PowerShell's &gt; writes UTF-16.</summary>
    private static byte[] WithoutByteOrderMark(byte[] bytes) => bytes switch
    {
        [0xEF, 0xBB, 0xBF, ..] => bytes[3..],
        [0xFF, 0xFE, ..] => Encoding.UTF8.GetBytes(Encoding.Unicode.GetString(bytes, 2, bytes.Length - 2)),
        [0xFE, 0xFF, ..] => Encoding.UTF8.GetBytes(Encoding.BigEndianUnicode.GetString(bytes, 2, bytes.Length - 2)),
        _ => bytes,
    };

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
            else throw new BatchListException(string.Format(CoreStrings.Batch_ListNotPrintable, BatchPrintText.Clean(entry.Path)));
            if (files.Count > BatchPrintLimits.MaxFiles) throw new BatchListException(string.Format(CoreStrings.Batch_ListTooManyFiles, BatchPrintLimits.MaxFiles));
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
        if (string.IsNullOrWhiteSpace(raw) || raw.Length > 4000) return Refuse(CoreStrings.Batch_PathNone, out why);
        var shown = BatchPrintText.Clean(raw);
        if (raw.Any(c => char.IsControl(c) || c is '<' or '>' or '"' or '|' or '?' or '*'))
        {
            // \\?\ and \\.\ reach devices and raw paths; the characters can't be in a file's name anyway.
            return Refuse(string.Format(CoreStrings.Batch_PathNotAllowed, shown), out why);
        }
        var slashed = raw.Replace('/', '\\');
        var isUnc = slashed.StartsWith(@"\\", StringComparison.Ordinal);
        var hasDrive = slashed.Length >= 3 && char.IsAsciiLetter(slashed[0]) && slashed[1] == ':' && slashed[2] == '\\';
        var relative = !isUnc && !hasDrive && !slashed.StartsWith('\\') && !(slashed.Length >= 2 && slashed[1] == ':');
        if (!isUnc && !hasDrive && !relative) return Refuse(string.Format(CoreStrings.Batch_PathNotFull, shown), out why);
        // Past a drive's colon, a colon is a web address or an alternate data stream.
        if (slashed.IndexOf(':', hasDrive ? 2 : 0) >= 0) return Refuse(string.Format(CoreStrings.Batch_PathNotOnPc, shown), out why);

        string full;
        try
        {
            full = System.IO.Path.GetFullPath(relative ? System.IO.Path.Combine(listFolder, slashed) : slashed);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return Refuse(string.Format(CoreStrings.Batch_PathNotAllowed, shown), out why);
        }
        foreach (var part in full.Split('\\', StringSplitOptions.RemoveEmptyEntries))
        {
            var stem = part.Split('.')[0].TrimEnd(' ');
            if (stem.ToUpperInvariant() is "CON" or "PRN" or "AUX" or "NUL" or "CONIN$" or "CONOUT$"
                || (stem.Length == 4 && (stem.StartsWith("COM", StringComparison.OrdinalIgnoreCase) || stem.StartsWith("LPT", StringComparison.OrdinalIgnoreCase)) && (char.IsDigit(stem[3]) || stem[3] is '¹' or '²' or '³')))
                return Refuse(string.Format(CoreStrings.Batch_PathDevice, shown), out why);
        }
        if (relative)
        {
            var below = System.IO.Path.TrimEndingDirectorySeparator(System.IO.Path.GetFullPath(listFolder)) + "\\";
            if (!full.StartsWith(below, StringComparison.OrdinalIgnoreCase)) return Refuse(string.Format(CoreStrings.Batch_PathLeavesFolder, shown), out why);
        }
        if (isUnc)
        {
            var name = full.TrimStart('\\').Split('\\')[0];
            if (name is "." or "?" or "") return Refuse(string.Format(CoreStrings.Batch_PathNotOnPc, shown), out why);
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
