namespace PrintDesk.Core.Suite;

/// <summary>
/// Where the Desk apps (PrintDesk, PdfDesk) live and keep their data, whichever way they were installed: unpackaged
/// (the Desk installer, install.ps1, or a build folder) or as an MSIX package (Microsoft Store or sideloaded).
/// Pure path logic, no file access beyond what the caller asks for, so it is testable with any folder as
/// <c>%LOCALAPPDATA%</c>.
/// </summary>
public static class DeskPaths
{
    /// <summary>
    /// Places to look for an installed app (e.g. "PdfDesk.exe"), in order, under <paramref name="localAppData"/>:
    /// the packaged app's execution alias (<c>Microsoft\WindowsApps\pdfdesk.exe</c>, a zero-byte reparse point that
    /// launches the package), then the Desk installer's folder and the single-app install folder. App Paths in the
    /// registry are checked by the caller, between the alias and the folders.
    /// </summary>
    public static (string Alias, IReadOnlyList<string> Folders) AppCandidates(string exeName, string localAppData)
    {
        var stem = Path.GetFileNameWithoutExtension(exeName);
        var programs = Path.Combine(localAppData, "Programs");
        return (Path.Combine(localAppData, "Microsoft", "WindowsApps", exeName.ToLowerInvariant()),
            [Path.Combine(programs, "Desk", stem, exeName), Path.Combine(programs, stem, exeName)]);
    }

    /// <summary>
    /// PrintDesk's <c>state.json</c> candidates under <paramref name="localAppData"/>: the unpackaged location
    /// (<c>PrintDesk\state.json</c>), then the copy a packaged PrintDesk writes. Windows redirects a packaged app's
    /// writes under %LOCALAPPDATA% into its package folder
    /// (<c>Packages\&lt;family name&gt;\LocalCache\Local\PrintDesk\state.json</c>), which other apps don't see at the
    /// plain path. The family name depends on the Store identity, so any package folder whose name contains
    /// "PrintDesk" counts. Only existing files are returned.
    /// </summary>
    public static IReadOnlyList<string> StateFiles(string localAppData)
    {
        var found = new List<string>();
        var plain = Path.Combine(localAppData, "PrintDesk", "state.json");
        if (File.Exists(plain)) found.Add(plain);
        var packages = Path.Combine(localAppData, "Packages");
        try
        {
            if (Directory.Exists(packages))
                foreach (var dir in Directory.EnumerateDirectories(packages, "*PrintDesk*"))
                {
                    var redirected = Path.Combine(dir, "LocalCache", "Local", "PrintDesk", "state.json");
                    if (File.Exists(redirected)) found.Add(redirected);
                }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Unlistable Packages folder: the plain location is all there is.
        }
        return found;
    }

    /// <summary>The most recently written of <see cref="StateFiles"/> (the copy PrintDesk is using), or null.</summary>
    public static string? CurrentStateFile(string localAppData) =>
        StateFiles(localAppData).OrderByDescending(f =>
        {
            try { return File.GetLastWriteTimeUtc(f); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return DateTime.MinValue; }
        }).FirstOrDefault();
}
