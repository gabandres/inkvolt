using System.Text.Json;
using InkvoltPrint.Core.Suite;

namespace InkvoltPdf.Core;

/// <summary>What a recovery copy is of: the tab's name, the file it came from (null for a document never saved, such as a
/// combined or scanned one), that file's size and time when the copy was made, when it was made, and the page in view.</summary>
public sealed record RecoveryInfo(string DisplayName, string? OriginalPath, long? OriginalLength, DateTime? OriginalWriteTimeUtc,
    DateTime SavedUtc, int Page);

/// <summary>A recovery copy a run left behind: the copy's bytes are in <see cref="PdfPath"/>.</summary>
public sealed record LeftOverDocument(string PdfPath, RecoveryInfo Info, string Folder);

/// <summary>
/// Copies of documents with unsaved changes, so they can be offered back after Inkvolt PDF closes without saving them
/// (a crash, a killed process, a power cut). They live in this run's <see cref="RunFolder"/>: a copy is the document's
/// bytes as Save would write them (a password-protected document stays protected), written atomically, with a small
/// description beside it. A clean exit removes the folder.
/// </summary>
public sealed class RecoveryStore : IDisposable
{
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    private readonly RunFolder _run;
    private readonly Lock _gate = new();
    private bool _ended;

    private RecoveryStore(RunFolder run) => _run = run;

    /// <summary>Starts this run's folder under <paramref name="root"/>.</summary>
    public static RecoveryStore Start(string root) => new(RunFolder.Start(root));

    /// <summary>Writes (or replaces) the copy for <paramref name="id"/>. Safe from any thread; one write at a time.</summary>
    public void Write(string id, byte[] data, RecoveryInfo info)
    {
        lock (_gate)
        {
            if (_ended) return;
            RunFolder.WriteAtomic(Path.Combine(_run.Path, id + ".pdf"), stream => stream.Write(data));
            RunFolder.WriteAtomic(Path.Combine(_run.Path, id + ".json"), stream => JsonSerializer.Serialize(stream, info, Json));
        }
    }

    /// <summary>Removes the copy for <paramref name="id"/> (saved, back to its saved state, or closed).</summary>
    public void Remove(string id)
    {
        lock (_gate)
        {
            RunFolder.TryDelete(Path.Combine(_run.Path, id + ".json"));
            RunFolder.TryDelete(Path.Combine(_run.Path, id + ".pdf"));
        }
    }

    /// <summary>
    /// Copies left by runs that ended without a clean exit, complete ones only: a copy without its description, or a
    /// description that can't be read, is skipped.
    /// </summary>
    public static IReadOnlyList<LeftOverDocument> FindLeftOver(string root)
    {
        var found = new List<LeftOverDocument>();
        foreach (var folder in RunFolder.LeftOver(root))
        foreach (var description in Directory.GetFiles(folder, "*.json"))
        {
            var pdf = Path.ChangeExtension(description, ".pdf");
            if (!File.Exists(pdf)) continue;
            try
            {
                if (JsonSerializer.Deserialize<RecoveryInfo>(File.ReadAllText(description)) is { DisplayName.Length: > 0 } info)
                    found.Add(new LeftOverDocument(pdf, info, folder));
            }
            catch (Exception ex) when (ex is JsonException or IOException or UnauthorizedAccessException)
            {
            }
        }
        return found;
    }

    /// <summary>Deletes the folders the documents were left in (the user declined them).</summary>
    public static void Discard(IEnumerable<LeftOverDocument> documents)
    {
        foreach (var folder in documents.Select(d => d.Folder).Distinct()) RunFolder.Delete(folder);
    }

    /// <summary>Deletes one left-over copy (restored, or found unreadable); its folder goes with the last one.</summary>
    public static void Remove(LeftOverDocument document)
    {
        RunFolder.TryDelete(Path.ChangeExtension(document.PdfPath, ".json"));
        RunFolder.TryDelete(document.PdfPath);
        if (Directory.Exists(document.Folder) && Directory.GetFiles(document.Folder, "*.json").Length == 0) RunFolder.Delete(document.Folder);
    }

    /// <summary>Deletes left-over folders that hold nothing to offer (a run that crashed with every document saved).</summary>
    public static void DiscardEmpty(string root)
    {
        foreach (var folder in RunFolder.LeftOver(root))
            if (Directory.GetFiles(folder, "*.json").Length == 0) RunFolder.Delete(folder);
    }

    /// <summary>Ends the run as a crash would: the copies stay (tests).</summary>
    internal void Abandon()
    {
        lock (_gate)
        {
            _ended = true;
            _run.Abandon();
        }
    }

    /// <summary>A clean exit: every copy and the run's folder go.</summary>
    public void Dispose()
    {
        lock (_gate)
        {
            _ended = true;
            _run.Dispose();
        }
    }
}
