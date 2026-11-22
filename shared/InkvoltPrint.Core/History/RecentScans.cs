namespace InkvoltPrint.Core.History;

/// <summary>
/// One save of scanned pages (roadmap 4.15): the files it wrote (one PDF, a set of JPEGs, or a batch's PDFs), when, how many
/// pages, and the printer and preset it came from. Kept on this PC only, with the app's settings; nothing is sent.
/// </summary>
/// <param name="Files">Full paths, the first being the one named in the list.</param>
/// <param name="Printer">The scanner's name as the list showed it, or null.</param>
/// <param name="Preset">The preset it was saved with, or null for Save as PDF / JPEG.</param>
public sealed record RecentScan(IReadOnlyList<string> Files, DateTimeOffset SavedAt, int Pages, string? Printer = null, string? Preset = null)
{
    /// <summary>Every file is a PDF: Print opens it in Print a PDF (several: Batch); else the pictures go to Print photos.</summary>
    public bool IsPdf => Files.Count > 0 && Files.All(f => f.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase));

    /// <summary>The first file's name, for the list.</summary>
    public string Name => Path.GetFileName(Files.Count > 0 ? Files[0] : "");
}

/// <summary>Which day a scan was saved, as the list says it.</summary>
public enum RecentScanDay { Today, Yesterday, Earlier }

/// <summary>
/// The list of recent scans (print/GLOSSARY.md, "recent scans"): the last <see cref="Max"/> saves, newest first. A file saved again
/// moves its entry to the top rather than listing it twice; an entry whose files are all gone (deleted, moved, a drive away)
/// drops out when the list is shown. What's read back from the settings file is hostile input: entries, files, paths and
/// names are bounded, and a path that isn't a plain full path (relative, a device path, a web address) is left out.
/// </summary>
public static class RecentScans
{
    /// <summary>Entries kept.</summary>
    public const int Max = 20;

    /// <summary>Files kept per entry (a batch of many files keeps its first ones).</summary>
    public const int MaxFiles = 100;

    public const int MaxPath = 1024, MaxText = 128, MaxPages = 100_000;

    /// <summary><paramref name="scan"/> at the top: any entry sharing one of its files goes (saved again), and the oldest past <see cref="Max"/>.</summary>
    public static IReadOnlyList<RecentScan> Add(IReadOnlyList<RecentScan>? list, RecentScan scan)
    {
        if (Clean(scan) is not { } clean) return Clean(list);
        var files = clean.Files.ToHashSet(StringComparer.OrdinalIgnoreCase);
        return [clean, .. Clean(list).Where(r => !r.Files.Any(files.Contains)).Take(Max - 1)];
    }

    /// <summary>The list as read from the settings file: nulls and unusable entries out, each bounded, at most <see cref="Max"/>.</summary>
    public static IReadOnlyList<RecentScan> Clean(IEnumerable<RecentScan?>? stored) =>
        stored is null ? [] : stored.Take(Max * 4).Select(Clean).OfType<RecentScan>().Take(Max).ToList();

    /// <summary>Each entry with only the files still there (asked through <paramref name="exists"/>); an entry with none left drops out.</summary>
    public static IReadOnlyList<RecentScan> Present(IReadOnlyList<RecentScan> list, Func<string, bool> exists) =>
        list.Select(r => r with { Files = r.Files.Where(f => Exists(exists, f)).ToList() }).Where(r => r.Files.Count > 0).ToList();

    /// <summary>The list without <paramref name="scan"/> (matched by its first file).</summary>
    public static IReadOnlyList<RecentScan> Remove(IReadOnlyList<RecentScan> list, RecentScan scan) =>
        list.Where(r => !string.Equals(r.Files.FirstOrDefault(), scan.Files.FirstOrDefault(), StringComparison.OrdinalIgnoreCase)).ToList();

    public static RecentScanDay Day(DateTimeOffset savedAt, DateTimeOffset now)
    {
        var (day, today) = (DateOnly.FromDateTime(savedAt.LocalDateTime), DateOnly.FromDateTime(now.LocalDateTime));
        return day == today ? RecentScanDay.Today : day == today.AddDays(-1) ? RecentScanDay.Yesterday : RecentScanDay.Earlier;
    }

    /// <summary>A usable entry, bounded, or null.</summary>
    internal static RecentScan? Clean(RecentScan? scan)
    {
        if (scan?.Files is null) return null;
        var files = scan.Files.Take(MaxFiles * 4).Where(Usable).Distinct(StringComparer.OrdinalIgnoreCase).Take(MaxFiles).ToList();
        if (files.Count == 0) return null;
        return new RecentScan(files, scan.SavedAt, Math.Clamp(scan.Pages, 0, MaxPages), Text(scan.Printer), Text(scan.Preset));
    }

    /// <summary>A full path on a drive (<c>C:\…</c>) or a share (<c>\\server\share\…</c>), not a device path, not too long.</summary>
    internal static bool Usable(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || path.Length > MaxPath || path.IndexOfAny(Path.GetInvalidPathChars()) >= 0) return false;
        if (path.StartsWith(@"\\.\", StringComparison.Ordinal) || path.StartsWith(@"\\?\", StringComparison.Ordinal)) return false;
        if (path.Contains("://", StringComparison.Ordinal)) return false;
        var drive = path.Length >= 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] == '\\';
        var share = path.StartsWith(@"\\", StringComparison.Ordinal) && path.Length > 4 && path.IndexOf('\\', 2) > 2;
        return (drive || share) && path.IndexOf(':', 2) < 0 && Path.GetFileName(path).Length > 0; // no alternate data stream
    }

    private static string? Text(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var line = new string(text.Where(c => !char.IsControl(c)).ToArray()).Trim();
        return line.Length == 0 ? null : line.Length > MaxText ? line[..MaxText] : line;
    }

    private static bool Exists(Func<string, bool> exists, string path)
    {
        try { return exists(path); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException) { return false; }
    }
}
