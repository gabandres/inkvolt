using System.Text.Json;

namespace InkvoltPrint.Core.Presets;

/// <summary>A cloud storage app's local folder (it syncs what's saved there; Inkvolt Print never talks to the service).</summary>
public sealed record SyncFolder(string Name, string Path);

/// <summary>
/// OneDrive and Dropbox folders on this PC, offered as places to save scans. Found only from local settings, never
/// over the network: OneDrive from the <c>OneDrive</c> / <c>OneDriveConsumer</c> / <c>OneDriveCommercial</c> environment
/// variables and the <c>UserFolder</c> of each account under <c>HKCU\Software\Microsoft\OneDrive\Accounts</c>; Dropbox
/// from <c>info.json</c> in <c>%APPDATA%\Dropbox</c> or <c>%LOCALAPPDATA%\Dropbox</c> (<c>personal</c> / <c>business</c>
/// → <c>path</c>, as Dropbox documents it). Gathering those values is the caller's job; this picks the folders that exist.
/// </summary>
public static class SyncFolders
{
    /// <param name="oneDrive">Candidate OneDrive folders (environment variables, registry), any order, repeats and blanks allowed.</param>
    /// <param name="dropboxInfo">Contents of each Dropbox <c>info.json</c> found (null = not there).</param>
    /// <param name="directoryExists">Only folders that exist are offered.</param>
    public static IReadOnlyList<SyncFolder> Find(IEnumerable<string?> oneDrive, IEnumerable<string?> dropboxInfo, Func<string, bool> directoryExists)
    {
        var found = new List<SyncFolder>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Add(string? path)
        {
            if (string.IsNullOrWhiteSpace(path) || !System.IO.Path.IsPathFullyQualified(path)) return;
            var clean = path.Trim().TrimEnd('\\', '/');
            if (clean.Length == 0 || !seen.Add(clean) || !directoryExists(clean)) return;
            var name = System.IO.Path.GetFileName(clean);
            found.Add(new(name.Length > 0 ? name : clean, clean));
        }
        foreach (var path in oneDrive) Add(path);
        foreach (var json in dropboxInfo)
            foreach (var path in DropboxPaths(json)) Add(path);
        return found;
    }

    /// <summary>The <c>path</c> of the personal and business accounts in a Dropbox <c>info.json</c>; nothing when it doesn't parse.</summary>
    public static IEnumerable<string> DropboxPaths(string? json)
    {
        if (string.IsNullOrWhiteSpace(json)) return [];
        var paths = new List<string>();
        try
        {
            using var doc = JsonDocument.Parse(json);
            if (doc.RootElement.ValueKind != JsonValueKind.Object) return [];
            foreach (var account in new[] { "personal", "business" })
                if (doc.RootElement.TryGetProperty(account, out var a) && a.ValueKind == JsonValueKind.Object
                    && a.TryGetProperty("path", out var p) && p.ValueKind == JsonValueKind.String && p.GetString() is { Length: > 0 } path)
                    paths.Add(path);
        }
        catch (JsonException)
        {
            return [];
        }
        return paths;
    }
}
