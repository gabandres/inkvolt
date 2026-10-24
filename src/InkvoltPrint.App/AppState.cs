using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App;

/// <param name="IppUri">The IPP URL the printer answered on last time (DNS-SD <c>rp</c>, IPPS), tried first on the next start.</param>
public sealed record KnownPrinter(string Uuid, string Name, string? Model, string Host, string? EsclRoot, string? IppUri = null);

/// <summary>Remembered printers and preferences, so the app connects instantly on start instead of waiting for discovery.</summary>
public sealed class AppState
{
    /// <summary>%LOCALAPPDATA%\InkvoltPrint. First use moves the folder over from its pre-rename name (PrintDesk).</summary>
    public static readonly string DataDirectory = OpenDataDirectory();

    /// <summary>True when this run carried the data folder over from its pre-rename name (logged at startup).</summary>
    public static bool MovedLegacyData { get; private set; }

    private static string OpenDataDirectory()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var folder = Path.Combine(local, "InkvoltPrint");
        MovedLegacyData = InkvoltPaths.AdoptLegacyFolder(Path.Combine(local, "PrintDesk"), folder);
        return folder;
    }
    private static readonly string FilePath = Path.Combine(DataDirectory, "state.json");
    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };
    private static readonly Lock FileGate = new();
    private readonly Lock _gate = new();

    /// <summary>Demo mode: never written to disk.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IsInMemory { get; init; }

    public List<KnownPrinter> Printers { get; set; } = [];
    public string? SelectedUuid { get; set; }
    public int ScanResolution { get; set; } = 300;
    public bool ScanColor { get; set; } = true;
    public bool ScanOcr { get; set; } = true;
    public string? ScanFolder { get; set; }
    public string? ScanPageSize { get; set; }

    /// <summary>Scan review: leave near-blank pages out of what's saved (they stay listed, dimmed, with Keep).</summary>
    public bool ScanSkipBlank { get; set; } = true;

    /// <summary>Scan review: straighten pages scanned a little crooked.</summary>
    public bool ScanStraighten { get; set; } = true;
    public string? PrintFolder { get; set; }

    /// <summary>Open each scan saved as PDF in Inkvolt PDF (Inkvolt suite) right away.</summary>
    public bool OpenScansInInkvoltPdf { get; set; }

    /// <summary>The same setting under its pre-rename name, read from older state files; never written back.</summary>
    [JsonInclude, JsonPropertyName("OpenScansInPdfDesk"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    private bool LegacyOpenScansSetting
    {
        get => false;
        set { if (value) OpenScansInInkvoltPdf = true; }
    }

    /// <summary>HP package set the user chose to keep (banner hidden until the set changes).</summary>
    public string? DismissedHpApps { get; set; }

    /// <summary>Printers the user removed; discovery won't add them back until they're added again by address.</summary>
    public List<string> ForgottenUuids { get; set; } = [];

    /// <summary>Printer UUID → SHA-256 of its TLS certificate (trust on first use).</summary>
    public Dictionary<string, string> CertificatePins { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Printer UUID → queue name Inkvolt Print created with Add-Printer -IppURL (printers added by address).</summary>
    public Dictionary<string, string> QueueNames { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Queue name → whether its driver reports two-sided printing (cached: the query is slow).</summary>
    public Dictionary<string, bool> TwoSidedQueues { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public bool? GetTwoSided(string queue)
    {
        lock (_gate) return TwoSidedQueues.TryGetValue(queue, out var v) ? v : null;
    }

    public void SetTwoSided(string queue, bool value)
    {
        lock (_gate)
        {
            if (TwoSidedQueues.TryGetValue(queue, out var old) && old == value) return;
            TwoSidedQueues[queue] = value;
        }
        Save();
    }

    /// <summary>Moves everything stored under an old (non-GUID) printer id to its normalised id.</summary>
    public void RenamePrinterId(string oldId, string newId)
    {
        if (string.Equals(oldId, newId, StringComparison.OrdinalIgnoreCase)) return;
        lock (_gate)
        {
            foreach (var key in CertificatePins.Keys.Where(k => CertificatePinKey.Belongs(k, oldId)).ToList())
                if (CertificatePins.Remove(key, out var pin)) CertificatePins.TryAdd(newId + key[oldId.Length..], pin);
            if (QueueNames.Remove(oldId, out var queue)) QueueNames.TryAdd(newId, queue);
            for (var i = 0; i < ForgottenUuids.Count; i++)
                if (string.Equals(ForgottenUuids[i], oldId, StringComparison.OrdinalIgnoreCase)) ForgottenUuids[i] = newId;
            if (string.Equals(SelectedUuid, oldId, StringComparison.OrdinalIgnoreCase)) SelectedUuid = newId;
        }
        Save();
    }

    public string? GetQueueName(string uuid)
    {
        lock (_gate) return QueueNames.GetValueOrDefault(uuid);
    }

    public void SetQueueName(string uuid, string name)
    {
        lock (_gate) QueueNames[uuid] = name;
        Save();
    }

    /// <summary>The printer's pin for <paramref name="port"/> (443, its web server, by default).</summary>
    public string? GetCertificatePin(string uuid, int port = 443)
    {
        lock (_gate) return CertificatePins.GetValueOrDefault(CertificatePinKey.For(uuid, port));
    }

    /// <summary>Called from the TLS handshake (thread pool), hence the lock. Never overwrites an existing pin.</summary>
    public string SetCertificatePinIfAbsent(string uuid, int port, string sha256Hex)
    {
        string stored;
        var key = CertificatePinKey.For(uuid, port);
        lock (_gate)
        {
            if (!CertificatePins.TryGetValue(key, out stored!)) CertificatePins[key] = stored = sha256Hex;
        }
        Save();
        return stored;
    }

    /// <summary>Forgets every pin of the printer (all ports): the user chose to trust its new certificate.</summary>
    public void ClearCertificatePin(string uuid)
    {
        lock (_gate)
            foreach (var key in CertificatePins.Keys.Where(k => CertificatePinKey.Belongs(k, uuid)).ToList()) CertificatePins.Remove(key);
        Save();
    }

    public static AppState Load()
    {
        try
        {
            var state = File.Exists(FilePath) ? JsonSerializer.Deserialize<AppState>(File.ReadAllText(FilePath), Json) ?? new() : new();
            // Hand-edited or older files can hold nulls; never let that stop the app from starting.
            state.Printers = (state.Printers ?? []).Where(k => k is { Uuid: not null, Host: not null }).ToList();
            state.ForgottenUuids ??= [];
            state.CertificatePins = new(state.CertificatePins ?? [], StringComparer.OrdinalIgnoreCase);
            state.QueueNames = new(state.QueueNames ?? [], StringComparer.OrdinalIgnoreCase);
            state.TwoSidedQueues = new(state.TwoSidedQueues ?? [], StringComparer.OrdinalIgnoreCase);
            return state;
        }
        catch (Exception ex) when (ex is IOException or JsonException or UnauthorizedAccessException or NotSupportedException)
        {
            Log.Write($"State file unreadable, starting fresh: {ex.Message}");
            return new();
        }
    }

    public void Save()
    {
        if (IsInMemory) return;
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
        catch (Exception ex)
        {
            // Non-fatal (state is a cache) and may run on a TLS callback thread while the UI edits lists: never throw.
            Log.Write($"State not saved: {ex.Message}");
        }
    }
}
