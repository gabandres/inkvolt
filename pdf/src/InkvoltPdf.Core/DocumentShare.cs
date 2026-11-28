namespace InkvoltPdf.Core;

/// <summary>What File › Share… hands to Windows' share sheet.</summary>
public enum ShareSource
{
    /// <summary>The file on disk, as saved.</summary>
    SavedFile,

    /// <summary>The file has changes that aren't saved: ask whether to save it first or share a copy with them.</summary>
    AskSaveOrCopy,

    /// <summary>A copy of the document as it is (it has never been saved).</summary>
    Copy,
}

/// <summary>
/// File › Share… (the Mac's Share…): which bytes are shared, and the copy written for the share sheet when the file on
/// disk isn't the document as it is. The copies live in their own folder under the temporary folder, one folder each
/// (the share target reads the file after the sheet closes), and go after a day.
/// </summary>
public static class DocumentShare
{
    /// <summary>The folder the copies go in, under <paramref name="tempRoot"/>.</summary>
    public const string FolderName = "Inkvolt PDF share";

    /// <summary>How long a copy is kept for the app that received it.</summary>
    public static readonly TimeSpan KeepFor = TimeSpan.FromDays(1);

    public static ShareSource SourceFor(string? filePath, bool dirty) =>
        string.IsNullOrEmpty(filePath) ? ShareSource.Copy : dirty ? ShareSource.AskSaveOrCopy : ShareSource.SavedFile;

    /// <summary>The copy's file name: the document's name (characters Windows refuses as "_", shortened) ending in .pdf.</summary>
    public static string CopyName(string displayName)
    {
        var name = Path.GetFileName(displayName.Replace('/', '\\'));
        if (name.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) name = name[..^4];
        return BatchNames.Clean(name, "Document") + ".pdf";
    }

    /// <summary>Writes the copy in a folder of its own and returns its path; first removes copies older than <see cref="KeepFor"/>.</summary>
    public static string WriteCopy(string tempRoot, string displayName, byte[] data, DateTime utcNow)
    {
        var root = Path.Combine(tempRoot, FolderName);
        Sweep(root, utcNow);
        var folder = Path.Combine(root, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(folder);
        var path = Path.Combine(folder, CopyName(displayName));
        File.WriteAllBytes(path, data);
        return path;
    }

    /// <summary>Removes the copies' folders older than <see cref="KeepFor"/> (ones in use are left for next time).</summary>
    public static void Sweep(string root, DateTime utcNow)
    {
        if (!Directory.Exists(root)) return;
        foreach (var dir in Directory.EnumerateDirectories(root).Take(500))
        {
            try
            {
                if (utcNow - Directory.GetCreationTimeUtc(dir) > KeepFor) Directory.Delete(dir, recursive: true);
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // still open in the app it went to: next time
            }
        }
    }
}
