using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// A scanned page kept on disk: the scanner's JPEG (<see cref="File"/>, in the scan's folder), its resolution, whether it
/// gets OCR when saved, and what the review did to it.
/// </summary>
public sealed record KeptPage(string File, int Dpi, bool Ocr, int QuarterTurns = 0, double Deskew = 0, CropBox? Crop = null,
    bool Skipped = false, bool StartsFile = false, PageFilters Filters = PageFilters.None, string? OcrLanguage = null)
{
    [JsonIgnore] public PageEdits Edits => new(QuarterTurns, Deskew, Crop, Filters & PageFilters.All);
}

/// <summary>One printer's unsaved scan: its pages in order.</summary>
public sealed record KeptScan(string PrinterId, string PrinterName, DateTime SavedUtc, IReadOnlyList<KeptPage> Pages);

/// <summary>A scan a run left unsaved, in <see cref="Folder"/>.</summary>
public sealed record LeftOverScan(string Folder, string ListPath, KeptScan Scan)
{
    public string PagePath(KeptPage page) => Path.Combine(Folder, page.File);
}

/// <summary>
/// Unsaved scans kept on disk while Inkvolt Print runs, so a crash, a killed process or Windows signing out doesn't lose
/// them: each printer's page list beside the scanner's JPEGs, in this run's <see cref="RunFolder"/>. Pages are written once
/// (a scanned page never changes; the review's edits are in the list), the list each time it changes; pages no list names
/// any more are deleted. A clean exit removes the folder.
/// </summary>
public sealed class ScanRecoveryStore : IDisposable
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    private readonly RunFolder _run;
    private readonly Lock _gate = new();
    private bool _ended;

    private ScanRecoveryStore(RunFolder run) => _run = run;

    public static ScanRecoveryStore Start(string root) => new(RunFolder.Start(root));

    /// <summary>A file name for a page not kept yet (see <see cref="KeepPage(string, byte[])"/>).</summary>
    public static string NewPageName() => $"page-{Guid.NewGuid():N}.jpg";

    /// <summary>Writes a scanned page under <paramref name="name"/> (<see cref="NewPageName"/>), for <see cref="KeptPage.File"/>.</summary>
    public void KeepPage(string name, byte[] jpeg)
    {
        lock (_gate)
        {
            if (!_ended) RunFolder.WriteAtomic(Path.Combine(_run.Path, name), stream => stream.Write(jpeg));
        }
    }

    /// <summary>Writes a scanned page and returns its file name.</summary>
    public string KeepPage(byte[] jpeg)
    {
        var name = NewPageName();
        KeepPage(name, jpeg);
        return name;
    }

    /// <summary>Writes (or replaces) a printer's page list, then deletes the pages no list names.</summary>
    public void Keep(KeptScan scan)
    {
        lock (_gate)
        {
            if (_ended) return;
            RunFolder.WriteAtomic(ListPath(_run.Path, scan.PrinterId), stream => JsonSerializer.Serialize(stream, scan, Json));
            DeleteUnlisted(_run.Path);
        }
    }

    /// <summary>
    /// Writes (or replaces) a printer's page list, first writing each page it names that isn't on disk (new, or deleted with a
    /// scan saved and then changed again) from <paramref name="jpeg"/>; then deletes the pages no list names.
    /// </summary>
    public void Keep(KeptScan scan, Func<string, byte[]> jpeg)
    {
        lock (_gate)
        {
            if (_ended) return;
            foreach (var page in scan.Pages)
                if (Path.Combine(_run.Path, page.File) is var path && !File.Exists(path))
                    RunFolder.WriteAtomic(path, stream => stream.Write(jpeg(page.File)));
            RunFolder.WriteAtomic(ListPath(_run.Path, scan.PrinterId), stream => JsonSerializer.Serialize(stream, scan, Json));
            DeleteUnlisted(_run.Path);
        }
    }

    /// <summary>A printer's scan was saved or cleared: its list and pages go.</summary>
    public void Forget(string printerId)
    {
        lock (_gate)
        {
            if (_ended) return;
            RunFolder.TryDelete(ListPath(_run.Path, printerId));
            DeleteUnlisted(_run.Path);
        }
    }

    /// <summary>Scans left by runs that ended without a clean exit: complete ones only (a list that can't be read, or names a missing page, is skipped).</summary>
    public static IReadOnlyList<LeftOverScan> FindLeftOver(string root)
    {
        var found = new List<LeftOverScan>();
        foreach (var folder in RunFolder.LeftOver(root))
        foreach (var list in Directory.GetFiles(folder, "scan-*.json"))
        {
            try
            {
                if (JsonSerializer.Deserialize<KeptScan>(File.ReadAllText(list), Json) is { Pages.Count: > 0, PrinterId.Length: > 0 } scan
                    && scan.Pages.All(p => p.File is { Length: > 0 } && Path.GetFileName(p.File) == p.File && File.Exists(Path.Combine(folder, p.File))))
                    found.Add(new LeftOverScan(folder, list, scan));
            }
            catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
            {
            }
        }
        return found;
    }

    /// <summary>Deletes a left-over scan (restored, or declined): its list and pages, and its folder with the last one.</summary>
    public static void Remove(LeftOverScan scan)
    {
        RunFolder.TryDelete(scan.ListPath);
        DeleteUnlisted(scan.Folder);
        if (Directory.Exists(scan.Folder) && Directory.GetFiles(scan.Folder, "scan-*.json").Length == 0) RunFolder.Delete(scan.Folder);
    }

    /// <summary>Deletes left-over folders with no scan to offer (a run that ended with everything saved).</summary>
    public static void DiscardEmpty(string root)
    {
        foreach (var folder in RunFolder.LeftOver(root))
            if (Directory.GetFiles(folder, "scan-*.json").Length == 0) RunFolder.Delete(folder);
    }

    /// <summary>The list's file name: the printer's id hashed, as ids hold characters file names can't.</summary>
    private static string ListPath(string folder, string printerId) =>
        Path.Combine(folder, $"scan-{Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(printerId)))[..16]}.json");

    private static void DeleteUnlisted(string folder)
    {
        if (!Directory.Exists(folder)) return;
        var listed = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var list in Directory.GetFiles(folder, "scan-*.json"))
        {
            try
            {
                if (JsonSerializer.Deserialize<KeptScan>(File.ReadAllText(list), Json) is { } scan)
                    foreach (var page in scan.Pages) listed.Add(page.File);
            }
            catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
            {
                return; // can't tell what's still needed: keep every page
            }
        }
        foreach (var page in Directory.GetFiles(folder, "page-*.jpg"))
            if (!listed.Contains(Path.GetFileName(page))) RunFolder.TryDelete(page);
    }

    /// <summary>
    /// Ends the run leaving the scans for the next start, as a crash would: Windows is signing out and the questions
    /// about unsaved scans can't wait (and tests).
    /// </summary>
    public void KeepForNextStart()
    {
        lock (_gate)
        {
            _ended = true;
            _run.Abandon();
        }
    }

    /// <summary>A clean exit: every kept scan and the run's folder go.</summary>
    public void Dispose()
    {
        lock (_gate)
        {
            _ended = true;
            _run.Dispose();
        }
    }
}
