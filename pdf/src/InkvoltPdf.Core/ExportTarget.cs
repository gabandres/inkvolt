namespace InkvoltPdf.Core;

/// <summary>
/// Where a one-click conversion (the command bar's Convert › Word, Excel…) writes: next to the PDF, so it is found where
/// the PDF is; in Documents when the PDF has no folder yet (a new, unsaved one) or its folder refuses the file (a
/// read-only share, a CD, Program Files). The name is reserved by creating the file (an empty one, which the export
/// replaces), so two conversions at once never pick the same name and nothing is ever written over. No probe file: the
/// real target is tried (call it off the UI thread: a share can be slow).
/// </summary>
public static class ExportTarget
{
    /// <summary>The reserved file, and whether it is in Documents rather than next to the PDF.</summary>
    public sealed record Reserved(string Path, bool InDocuments);

    /// <summary>What creating a file found: made it, a file of that name is there, or the folder refused it.</summary>
    public enum CreateResult { Created, Exists, Refused }

    /// <summary>
    /// Reserves <paramref name="fileName"/> (made unique by <paramref name="uniquePath"/>) next to <paramref name="pdfPath"/>,
    /// else in <paramref name="documents"/>; null when neither takes it (no Documents folder, both refused).
    /// </summary>
    /// <param name="pdfPath">The PDF's file, or null while it isn't saved.</param>
    /// <param name="documents">The user's Documents folder; null or empty when Windows has none.</param>
    /// <param name="uniquePath">A free path for the name in a folder ("name (2).docx" when taken).</param>
    /// <param name="create">Creates the file if it isn't there (<see cref="TryCreate"/>; a seam for tests).</param>
    public static Reserved? Reserve(string? pdfPath, string fileName, string? documents, Func<string, string, string> uniquePath,
        Func<string, CreateResult>? create = null)
    {
        create ??= TryCreate;
        var own = string.IsNullOrEmpty(pdfPath) ? null : System.IO.Path.GetDirectoryName(pdfPath);
        var folders = new List<(string Folder, bool InDocuments)>();
        if (!string.IsNullOrEmpty(own)) folders.Add((own, false));
        if (!string.IsNullOrWhiteSpace(documents) && !string.Equals(documents, own, StringComparison.OrdinalIgnoreCase)) folders.Add((documents, true));
        foreach (var (folder, inDocuments) in folders)
        {
            // A few tries: another conversion may take the free name between choosing it and creating it.
            for (var attempt = 0; attempt < 8; attempt++)
            {
                string path;
                try
                {
                    path = uniquePath(folder, fileName);
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException)
                {
                    break; // no name fits there (the folder's path too long)
                }
                var result = create(path);
                if (result == CreateResult.Created) return new Reserved(path, inDocuments);
                if (result == CreateResult.Refused) break;
            }
        }
        return null;
    }

    /// <summary>
    /// Creates an empty file at <paramref name="path"/> only if nothing is there (FileMode.CreateNew). A device name
    /// (NUL, COM¹: <see cref="InkvoltPrint.Core.DeviceNames"/>) is refused without opening it; a device the path opens
    /// all the same (not seekable, no file left behind) is refused too: it isn't a file the export could replace.
    /// </summary>
    public static CreateResult TryCreate(string path)
    {
        try
        {
            if (InkvoltPrint.Core.DeviceNames.IsReserved(System.IO.Path.GetFileName(path))) return CreateResult.Refused;
            bool isFile;
            using (var fs = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None))
                isFile = fs.CanSeek;
            return isFile && File.Exists(path) ? CreateResult.Created : CreateResult.Refused;
        }
        catch (IOException) when (File.Exists(path) || Directory.Exists(path))
        {
            return CreateResult.Exists;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException or NotSupportedException
                                       or System.Security.SecurityException)
        {
            return CreateResult.Refused;
        }
    }
}
