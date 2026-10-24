namespace InkvoltPrint.Core.Suite;

/// <summary>
/// Where the Inkvolt apps (Inkvolt Print, Inkvolt PDF) live and keep their data, whichever way they were installed: unpackaged
/// (the Inkvolt installer, install.ps1, or a build folder) or as an MSIX package (Microsoft Store or sideloaded).
/// Pure path logic, no file access beyond what the caller asks for, so it is testable with any folder as
/// <c>%LOCALAPPDATA%</c>.
/// </summary>
public static class InkvoltPaths
{
    /// <summary>
    /// Places to look for an installed app (e.g. "InkvoltPdf.exe"), in order, under <paramref name="localAppData"/>:
    /// the packaged app's execution alias (<c>Microsoft\WindowsApps\inkvoltpdf.exe</c>, a zero-byte reparse point that
    /// launches the package), then the Inkvolt installer's folder and the single-app install folder. App Paths in the
    /// registry are checked by the caller, between the alias and the folders.
    /// </summary>
    public static (string Alias, IReadOnlyList<string> Folders) AppCandidates(string exeName, string localAppData)
    {
        var stem = Path.GetFileNameWithoutExtension(exeName);
        var programs = Path.Combine(localAppData, "Programs");
        return (Path.Combine(localAppData, "Microsoft", "WindowsApps", exeName.ToLowerInvariant()),
            [Path.Combine(programs, "Inkvolt", stem, exeName), Path.Combine(programs, stem, exeName)]);
    }

    /// <summary>
    /// Inkvolt Print's <c>state.json</c> candidates under <paramref name="localAppData"/>: the unpackaged location
    /// (<c>InkvoltPrint\state.json</c>), then the copy a packaged Inkvolt Print writes. Windows redirects a packaged app's
    /// writes under %LOCALAPPDATA% into its package folder
    /// (<c>Packages\&lt;family name&gt;\LocalCache\Local\InkvoltPrint\state.json</c>), which other apps don't see at the
    /// plain path. The family name depends on the Store identity, so any package folder whose name contains "Inkvolt"
    /// followed by "Print" (Inkvolt.Print_…, 12345Me.InkvoltPrint_…) counts. Only existing files are returned.
    /// </summary>
    public static IReadOnlyList<string> StateFiles(string localAppData)
    {
        var found = new List<string>();
        var plain = Path.Combine(localAppData, "InkvoltPrint", "state.json");
        if (File.Exists(plain)) found.Add(plain);
        var packages = Path.Combine(localAppData, "Packages");
        try
        {
            if (Directory.Exists(packages))
                foreach (var dir in Directory.EnumerateDirectories(packages, "*Inkvolt*Print*"))
                {
                    var redirected = Path.Combine(dir, "LocalCache", "Local", "InkvoltPrint", "state.json");
                    if (File.Exists(redirected)) found.Add(redirected);
                }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Unlistable Packages folder: the plain location is all there is.
        }
        return found;
    }

    /// <summary>The most recently written of <see cref="StateFiles"/> (the copy Inkvolt Print is using), or null.</summary>
    public static string? CurrentStateFile(string localAppData) =>
        StateFiles(localAppData).OrderByDescending(f =>
        {
            try { return File.GetLastWriteTimeUtc(f); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return DateTime.MinValue; }
        }).FirstOrDefault();

    /// <summary>
    /// One-time move of an app's per-user data folder from its name before the Inkvolt rename (e.g.
    /// <c>%LOCALAPPDATA%\PrintDesk</c>) to <paramref name="folder"/>, so settings, saved IDs and recent files carry over.
    /// Acts only when <paramref name="folder"/> doesn't exist yet and <paramref name="legacyFolder"/> does. Renames the
    /// folder when it can; otherwise (another volume, a file still in use) copies it into a staging folder beside the
    /// target and renames that into place, so a half-finished copy never counts as done (the old folder then stays).
    /// Never throws; true when the data was carried over.
    /// </summary>
    public static bool AdoptLegacyFolder(string legacyFolder, string folder)
    {
        try
        {
            if (Directory.Exists(folder) || !Directory.Exists(legacyFolder)) return false;
            try
            {
                Directory.Move(legacyFolder, folder);
                return true;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                // Fall back to a copy.
            }
            var staging = folder.TrimEnd(Path.DirectorySeparatorChar) + ".migrating";
            if (Directory.Exists(staging)) Directory.Delete(staging, recursive: true);
            CopyTree(legacyFolder, staging);
            Directory.Move(staging, folder);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or ArgumentException
                                       or NotSupportedException or System.Security.SecurityException)
        {
            return false;
        }
    }

    private static void CopyTree(string from, string to)
    {
        Directory.CreateDirectory(to);
        foreach (var file in Directory.EnumerateFiles(from))
        {
            try { File.Copy(file, Path.Combine(to, Path.GetFileName(file))); }
            catch (IOException) { /* locked by a running old copy (e.g. its log): skip that file */ }
        }
        foreach (var dir in Directory.EnumerateDirectories(from))
            CopyTree(dir, Path.Combine(to, Path.GetFileName(dir)));
    }
}
