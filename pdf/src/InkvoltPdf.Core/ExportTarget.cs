namespace InkvoltPdf.Core;

/// <summary>
/// Where a one-click conversion (the command bar's Convert › Word, Excel…) writes: next to the PDF, so it is found where
/// the PDF is; in Documents when the PDF has no folder yet (a new, unsaved one) or its folder can't be written to (a
/// read-only share, a CD, Program Files). The file name is made unique by the caller, never replacing a file.
/// </summary>
public static class ExportTarget
{
    /// <summary>The folder to write into, and whether it is <paramref name="documents"/> rather than the PDF's own.</summary>
    /// <param name="pdfPath">The PDF's file, or null while it isn't saved.</param>
    /// <param name="documents">The user's Documents folder.</param>
    /// <param name="canWrite">Whether a file can be created in a folder (asked only of the PDF's own).</param>
    public static (string Folder, bool InDocuments) Folder(string? pdfPath, string documents, Func<string, bool> canWrite)
    {
        var folder = string.IsNullOrEmpty(pdfPath) ? null : Path.GetDirectoryName(pdfPath);
        return folder is not null && canWrite(folder) ? (folder, false) : (documents, true);
    }

    /// <summary>Whether a new file can be created in <paramref name="folder"/>: tried with a hidden file deleted at once.</summary>
    public static bool CanWrite(string folder)
    {
        if (!Directory.Exists(folder)) return false;
        try
        {
            using var probe = new FileStream(Path.Combine(folder, $".inkvolt-{Guid.NewGuid():N}.tmp"), FileMode.CreateNew,
                FileAccess.Write, FileShare.None, 1, FileOptions.DeleteOnClose);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Security.SecurityException)
        {
            return false;
        }
    }
}
