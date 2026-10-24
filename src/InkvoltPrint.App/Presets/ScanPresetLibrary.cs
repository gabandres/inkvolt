using System.Collections.ObjectModel;
using System.IO;
using Microsoft.Win32;
using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.App.Presets;

/// <summary>
/// The scan presets, shared by every printer's Scan tab and the Overview's scan card, kept in <see cref="AppState.Presets"/>.
/// Demo mode keeps them in memory and saves into a folder under %TEMP%, never into the user's own folders. Presets written
/// by a newer version are used as they are but never written over (<see cref="IsReadOnly"/>). Only touched on the UI thread,
/// so reserving a counter value is one step.
/// </summary>
public sealed class ScanPresetLibrary
{
    private readonly AppState _state;

    public ScanPresetLibrary(AppState state, bool demo)
    {
        _state = state;
        IsDemo = demo;
        IsReadOnly = state.Presets?.IsNewer == true;
        var normalized = ScanPresets.Normalize(state.Presets);
        foreach (var p in normalized) Items.Add(p);
        if (IsReadOnly) Log.Write($"Scan presets are from a newer Inkvolt Print (version {state.Presets!.Version}): used, not changed");
        // Written back only when something was added or repaired, not on every start.
        else if (state.Presets is not { Items: { } stored } settings || settings.Version != ScanPresets.CurrentVersion || !stored.SequenceEqual(normalized))
            Store();
    }

    public bool IsDemo { get; }

    /// <summary>
    /// The presets were saved by a newer Inkvolt Print: this one runs them but doesn't change them (the editor says so, and
    /// counters go up for this session only), so going back to the newer version loses nothing.
    /// </summary>
    public bool IsReadOnly { get; }

    /// <summary>In the user's order: the first nine are Ctrl+1…Ctrl+9.</summary>
    public ObservableCollection<ScanPreset> Items { get; } = [];

    /// <summary>The list changed (edited, reordered, a counter went up): the jump list follows.</summary>
    public event Action? Changed;

    public ScanPreset? Find(string idOrName) =>
        FindById(idOrName) ?? Items.FirstOrDefault(p => string.Equals(p.Name, idOrName, StringComparison.OrdinalIgnoreCase));

    public ScanPreset? FindById(string id) => Items.FirstOrDefault(p => p.Id == id);

    /// <summary>The editor's result replaces the list; counters stay as they are now (scans saved while it was open count).</summary>
    public void Replace(IEnumerable<ScanPreset> presets)
    {
        if (IsReadOnly) return;
        var list = ScanPresets.KeepCounters(presets, Items);
        Items.Clear();
        foreach (var p in list) Items.Add(p);
        Store();
    }

    /// <summary>Takes the preset's next <c>{n}</c> and moves its counter on (<see cref="ScanPresets.Reserve"/>); null when it was deleted.</summary>
    public int? IncrementCounter(string id)
    {
        var list = Items.ToList();
        if (ScanPresets.Reserve(list, id) is not { } n) return null;
        var i = list.FindIndex(p => p.Id == id);
        Items[i] = list[i];
        Store();
        return n;
    }

    /// <summary>One preset changed (the snapshot aid's --then): same place in the list.</summary>
    public void Update(ScanPreset preset)
    {
        var i = Items.ToList().FindIndex(p => p.Id == preset.Id);
        if (i < 0) return;
        Items[i] = preset;
        Store();
    }

    private void Store()
    {
        if (!IsReadOnly)
        {
            // Fields a newer version added at the top level stay (they'd only be there from a hand edit or a downgrade).
            _state.Presets = new ScanPresetSettings { Items = [.. Items], Unknown = _state.Presets?.Unknown };
            _state.Save();
        }
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
