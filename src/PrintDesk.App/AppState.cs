using System.IO;
using System.Text.Json;

namespace PrintDesk.App;

public sealed record KnownPrinter(string Uuid, string Name, string? Model, string Host, string? EsclRoot);

/// <summary>Remembered printers and preferences, so the app connects instantly on start instead of waiting for discovery.</summary>
public sealed class AppState
{
    public static readonly string DataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PrintDesk");
    private static readonly string FilePath = Path.Combine(DataDirectory, "state.json");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    private static readonly Lock FileGate = new();
    private readonly Lock _gate = new();

    public List<KnownPrinter> Printers { get; set; } = [];
    public string? SelectedUuid { get; set; }
    public int ScanResolution { get; set; } = 300;
    public bool ScanColor { get; set; } = true;
    public bool ScanOcr { get; set; } = true;
    public string? ScanFolder { get; set; }
    public string? ScanPageSize { get; set; }
    public string? PrintFolder { get; set; }

    /// <summary>HP package set the user chose to keep (banner hidden until the set changes).</summary>
    public string? DismissedHpApps { get; set; }

    /// <summary>Printers the user removed; discovery won't add them back until they're added again by address.</summary>
    public List<string> ForgottenUuids { get; set; } = [];

    /// <summary>Printer UUID → SHA-256 of its TLS certificate (trust on first use).</summary>
    public Dictionary<string, string> CertificatePins { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public string? GetCertificatePin(string uuid)
    {
        lock (_gate) return CertificatePins.GetValueOrDefault(uuid);
    }

    /// <summary>Called from the TLS handshake (thread pool), hence the lock.</summary>
    public void SetCertificatePin(string uuid, string sha256Hex)
    {
        lock (_gate) CertificatePins[uuid] = sha256Hex;
        Save();
    }

    public void ClearCertificatePin(string uuid)
    {
        lock (_gate) CertificatePins.Remove(uuid);
        Save();
    }

    public static AppState Load()
    {
        try
        {
            var state = File.Exists(FilePath) ? JsonSerializer.Deserialize<AppState>(File.ReadAllText(FilePath), Json) ?? new() : new();
            state.CertificatePins = new(state.CertificatePins, StringComparer.OrdinalIgnoreCase);
            return state;
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
            string json;
            lock (_gate) json = JsonSerializer.Serialize(this, Json);
            lock (FileGate)
            {
                Directory.CreateDirectory(DataDirectory);
                var tmp = FilePath + ".tmp";
                File.WriteAllText(tmp, json);
                File.Move(tmp, FilePath, overwrite: true);
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            // Non-fatal: state is a cache.
        }
    }
}
