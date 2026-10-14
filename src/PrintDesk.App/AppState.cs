using System.IO;
using System.Text.Json;

namespace PrintDesk.App;

public sealed record KnownPrinter(string Uuid, string Name, string? Model, string Host, string? EsclRoot);

/// <summary>Remembered printers and preferences, so the app connects instantly on start instead of waiting for discovery.</summary>
public sealed class AppState
{
    private static readonly string Dir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PrintDesk");
    private static readonly string FilePath = Path.Combine(Dir, "state.json");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    public List<KnownPrinter> Printers { get; set; } = [];
    public string? SelectedUuid { get; set; }
    public int ScanResolution { get; set; } = 300;
    public bool ScanColor { get; set; } = true;
    public bool ScanOcr { get; set; } = true;
    public string? ScanFolder { get; set; }

    public static AppState Load()
    {
        try
        {
            return File.Exists(FilePath) ? JsonSerializer.Deserialize<AppState>(File.ReadAllText(FilePath), Json) ?? new() : new();
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException)
        {
            return new();
        }
    }

    public void Save()
    {
        try
        {
            Directory.CreateDirectory(Dir);
            var tmp = FilePath + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(this, Json));
            File.Move(tmp, FilePath, overwrite: true);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Non-fatal: state is a cache.
        }
    }
}
