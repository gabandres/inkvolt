using System.Collections.ObjectModel;
using System.IO;
using Microsoft.Win32;
using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.App.Presets;

/// <summary>
/// The scan presets, shared by every printer's Scan tab and the Overview's scan card, kept in <see cref="AppState.Presets"/>.
/// Demo mode keeps them in memory and saves into a folder under %TEMP%, never into the user's own folders.
/// </summary>
public sealed class ScanPresetLibrary
{
    private readonly AppState _state;

    public ScanPresetLibrary(AppState state, bool demo)
    {
        _state = state;
        IsDemo = demo;
        var normalized = ScanPresets.Normalize(state.Presets);
        foreach (var p in normalized) Items.Add(p);
        // Written back only when something was added or repaired, not on every start.
        if (state.Presets is not { Items: { } stored } settings || settings.Version != ScanPresets.CurrentVersion || !stored.SequenceEqual(normalized))
            Store();
    }

    public bool IsDemo { get; }

    /// <summary>In the user's order: the first nine are Ctrl+1…Ctrl+9.</summary>
    public ObservableCollection<ScanPreset> Items { get; } = [];

    /// <summary>The list changed (edited, reordered, a counter went up): the jump list follows.</summary>
    public event Action? Changed;

    public ScanPreset? Find(string idOrName) =>
        Items.FirstOrDefault(p => p.Id == idOrName) ?? Items.FirstOrDefault(p => string.Equals(p.Name, idOrName, StringComparison.OrdinalIgnoreCase));

    /// <summary>The editor's result replaces the list.</summary>
    public void Replace(IEnumerable<ScanPreset> presets)
    {
        var list = presets.ToList();
        Items.Clear();
        foreach (var p in list) Items.Add(p);
        Store();
    }

    /// <summary>One preset changed (its counter after a save): same place in the list.</summary>
    public void Update(ScanPreset preset)
    {
        var i = Items.ToList().FindIndex(p => p.Id == preset.Id);
        if (i < 0) return;
        Items[i] = preset;
        Store();
    }

    private void Store()
    {
        _state.Presets = new ScanPresetSettings { Items = [.. Items] };
        _state.Save();
        Changed?.Invoke();
    }

    /// <summary>Where demo scans go: a folder of their own under %TEMP%.</summary>
    public static string DemoFolder => Path.Combine(Path.GetTempPath(), "Inkvolt Print demo scans");

    /// <summary>The folder the preset saves into (subfolder not included), or null with the reason.</summary>
    public string? Folder(ScanPreset preset, out string? problem)
    {
        problem = null;
        if (IsDemo) return Path.Combine(DemoFolder, preset.Folder == PresetFolder.Pictures ? "Pictures" : "Documents");
        switch (preset.Folder)
        {
            case PresetFolder.Pictures:
                return Environment.GetFolderPath(Environment.SpecialFolder.MyPictures);
            case PresetFolder.Custom when preset.FolderPath is { Length: > 0 } path:
                if (Directory.Exists(path)) return path;
                problem = $"The folder \"{path}\" isn't there any more. Choose another in Manage presets.";
                return null;
            default:
                return Environment.GetFolderPath(Environment.SpecialFolder.MyDocuments);
        }
    }

    /// <summary>Demo mode's made-up sync folders (never looked up: the demo doesn't read this PC's settings).</summary>
    public static IReadOnlyList<SyncFolder> DemoSyncFolders { get; } =
        [new("OneDrive", Path.Combine(DemoFolder, "OneDrive")), new("Dropbox", Path.Combine(DemoFolder, "Dropbox"))];

    /// <summary>OneDrive and Dropbox folders on this PC (local settings only; see <see cref="SyncFolders"/>).</summary>
    public static IReadOnlyList<SyncFolder> FindSyncFolders()
    {
        var oneDrive = new List<string?>
        {
            Environment.GetEnvironmentVariable("OneDriveConsumer"),
            Environment.GetEnvironmentVariable("OneDrive"),
            Environment.GetEnvironmentVariable("OneDriveCommercial"),
        };
        try
        {
            using var accounts = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\OneDrive\Accounts");
            foreach (var name in accounts?.GetSubKeyNames() ?? [])
            {
                using var account = accounts!.OpenSubKey(name);
                oneDrive.Add(account?.GetValue("UserFolder") as string);
            }
        }
        catch (Exception ex) when (ex is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            Log.Write($"OneDrive accounts not readable: {ex.Message}");
        }
        var dropbox = new[] { Environment.SpecialFolder.ApplicationData, Environment.SpecialFolder.LocalApplicationData }
            .Select(f => Path.Combine(Environment.GetFolderPath(f), "Dropbox", "info.json"))
            .Select(ReadSmall);
        return SyncFolders.Find(oneDrive, dropbox, Directory.Exists);
    }

    private static string? ReadSmall(string path)
    {
        try
        {
            return File.Exists(path) && new FileInfo(path).Length < 64 * 1024 ? File.ReadAllText(path) : null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return null;
        }
    }
}
