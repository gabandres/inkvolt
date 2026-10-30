namespace InkvoltPrint.Core.Suite;

/// <summary>
/// The licence key where both apps find it: <c>%LOCALAPPDATA%\Inkvolt\pro-key.txt</c>, one line, the key as it is shown.
/// A packaged (Microsoft Store) copy's write to that path lands in its own package folder
/// (<c>Packages\&lt;family name&gt;\LocalCache\Local\Inkvolt\pro-key.txt</c>; Windows redirects a packaged app's writes
/// under %LOCALAPPDATA%, as <see cref="InkvoltPaths.StateFiles"/> says of state.json), so a reader looks in every Inkvolt
/// package's folder too and takes the copy written last. Pure path and file logic, testable with any folder as
/// <c>%LOCALAPPDATA%</c>.
/// </summary>
public static class ProKeyFile
{
    public const string FileName = "pro-key.txt";

    /// <summary>Where a key is written: <c>%LOCALAPPDATA%\Inkvolt\pro-key.txt</c>.</summary>
    public static string PathUnder(string localAppData) => Path.Combine(localAppData, "Inkvolt", FileName);

    /// <summary>Every copy that exists: the plain path, then each Inkvolt package's redirected copy.</summary>
    public static IReadOnlyList<string> Candidates(string localAppData)
    {
        var found = new List<string>();
        var plain = PathUnder(localAppData);
        if (File.Exists(plain)) found.Add(plain);
        var packages = Path.Combine(localAppData, "Packages");
        try
        {
            if (Directory.Exists(packages))
                foreach (var dir in Directory.EnumerateDirectories(packages, "*Inkvolt*"))
                {
                    var redirected = Path.Combine(dir, "LocalCache", "Local", "Inkvolt", FileName);
                    if (File.Exists(redirected)) found.Add(redirected);
                }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Unlistable Packages folder: the plain location is all there is.
        }
        return found;
    }

    /// <summary>The key from the copy written last, or null (none, empty, or unreadable).</summary>
    public static string? Read(string localAppData)
    {
        foreach (var file in Candidates(localAppData).OrderByDescending(LastWrite))
        {
            try
            {
                if (File.ReadAllText(file).Trim() is { Length: > 0 } key) return key;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // Try the next copy.
            }
        }
        return null;
    }

    /// <summary>Writes the key (making the folder), or with null deletes every copy. False when the file system refused.</summary>
    public static bool Write(string localAppData, string? key)
    {
        var ok = true;
        try
        {
            if (key is { Length: > 0 })
            {
                var path = PathUnder(localAppData);
                Directory.CreateDirectory(Path.GetDirectoryName(path)!);
                File.WriteAllText(path, key + Environment.NewLine);
                return true;
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
        foreach (var file in Candidates(localAppData))
        {
            try { File.Delete(file); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { ok = false; }
        }
        return ok;
    }

    private static DateTime LastWrite(string file)
    {
        try { return File.GetLastWriteTimeUtc(file); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return DateTime.MinValue; }
    }
}

/// <summary>
/// An app's key store: the shared file (<see cref="ProKeyFile"/>) is the key's home; the app's own settings
/// (<paramref name="own"/>) hold a key only from before the file existed (Inkvolt PDF 1.2.1 kept it there) or when the file
/// couldn't be written. Such a key is moved into the file on the first read, so the other app finds it and removing it in
/// either app removes it for both. Installing writes the file (the settings only if that fails); removing clears both.
/// </summary>
public sealed class SharedProStore(IProStore own, string localAppData) : IProStore
{
    public string? Read()
    {
        if (ProKeyFile.Read(localAppData) is { } shared) return shared;
        if (own.Read() is not { Length: > 0 } mine) return null;
        if (ProKeyFile.Write(localAppData, mine)) own.Write(null);
        return mine;
    }

    public void Write(string? key)
    {
        var written = ProKeyFile.Write(localAppData, key);
        if (key is null || !written) own.Write(key);
        else if (own.Read() is not null) own.Write(null);
    }
}
