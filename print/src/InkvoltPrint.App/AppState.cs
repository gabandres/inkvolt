using System.IO;
using System.Text.Json;
using System.Text.Json.Serialization;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Presets;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.App;

/// <summary>A window's normal (not maximized) rectangle in DIPs, and whether it was maximized.</summary>
public sealed record WindowPlacement(double Left, double Top, double Width, double Height, bool Maximized);

/// <param name="IppUri">The IPP URL the printer answered on last time (DNS-SD <c>rp</c>, IPPS), tried first on the next start.</param>
/// <param name="Snmp">
/// Set for a printer that answered only SNMP when it was added: what it said about itself (serial number, model, name), which
/// tells whether the device at its address is still it. Only these printers are read over SNMP.
/// </param>
public sealed record KnownPrinter(string Uuid, string Name, string? Model, string Host, string? EsclRoot, string? IppUri = null,
    Core.Snmp.SnmpDevice? Snmp = null);

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

    /// <summary>What the Scan tab cleans each scanned page up with (<see cref="Core.Imaging.PageFilters"/>, as a number).</summary>
    public int ScanCleanup { get; set; }

    /// <summary>The OCR language the Scan tab reads in (a BCP-47 tag); null: Windows' first display language that has OCR.</summary>
    public string? ScanOcrLanguage { get; set; }

    /// <summary>Packaged installs: saved scans and sent prints counted toward the one Store rating request (RatingRequest).</summary>
    public RatingProgress? Rating { get; set; }

    /// <summary>
    /// The Inkvolt Pro licence key as entered in Help › Inkvolt Pro ("" = none): this app's own copy, behind the file both
    /// Inkvolt apps share (Core.Suite.ProKeyFile), read by Core's <c>Pro</c> through <c>StateProStore</c>.
    /// </summary>
    public string ProKey { get; set; } = "";

    /// <summary>Batch scanning: what starts a new file (Core.Imaging.SplitAt, as a number), and whether separator sheets are kept.</summary>
    public int ScanSplitAt { get; set; }
    public bool ScanKeepSeparators { get; set; }

    /// <summary>Scans of the glass: find the photos on it and save each one by itself.</summary>
    public bool ScanFindPhotos { get; set; }
    public string? PrintFolder { get; set; }

    /// <summary>Photos tab: the folder pictures were last added from, and the last layout (PhotosViewModel's layout keys).</summary>
    public string? PhotoFolder { get; set; }
    public string? PhotoLayout { get; set; }

    /// <summary>Open each scan saved as PDF in Inkvolt PDF (Inkvolt suite) right away.</summary>
    public bool OpenScansInInkvoltPdf { get; set; }

    /// <summary>The same setting under its pre-rename name, read from older state files; never written back.</summary>
    [JsonInclude, JsonPropertyName("OpenScansInPdfDesk"), JsonIgnore(Condition = JsonIgnoreCondition.WhenWritingDefault)]
    private bool LegacyOpenScansSetting
    {
        get => false;
        set { if (value) OpenScansInInkvoltPdf = true; }
    }

    /// <summary>Scan presets (versioned; null in files from before presets, which then get the built-ins). See Presets/ScanPresetLibrary.</summary>
    public ScanPresetSettings? Presets { get; set; }

    /// <summary>Notification-area icon and alerts (null in older files: off).</summary>
    public TraySettings? Tray { get; set; }

    /// <summary>"System" (follow Windows' light or dark mode, the default), "Light" or "Dark".</summary>
    public string? Theme { get; set; }

    /// <summary>The main window's place and size last time (DIPs), put back on start when it still fits a monitor.</summary>
    public WindowPlacement? Window { get; set; }

    /// <summary>The version this was last run as ("1.0.3"): What's New after an update shows what came since.</summary>
    public string? LastVersionSeen { get; set; }

    /// <summary>No state file yet: a new install, with nothing new to tell about.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IsNewInstall { get; private set; }

    /// <summary>
    /// Settings › Reset to defaults: the app's own preferences (theme, scan folder, opening scans in Inkvolt PDF, the
    /// notification area and alerts). Printers, presets, the Scan tab's choices and the window's place are kept.
    /// </summary>
    public void ResetPreferences()
    {
        Theme = null;
        ScanFolder = null;
        OpenScansInInkvoltPdf = false;
        Tray?.ResetPreferences();
        Save();
    }

    /// <summary>HP package set the user chose to keep (banner hidden until the set changes).</summary>
    public string? DismissedHpApps { get; set; }

    /// <summary>
    /// Printers the user removed; discovery won't add them back until they're added again by address. Read and changed through
    /// <see cref="GetForgotten"/>, <see cref="Forget"/> and <see cref="Unforget"/> (under the lock a save from a TLS handshake takes).
    /// </summary>
    public List<string> ForgottenUuids { get; set; } = [];

    public IReadOnlyCollection<string> GetForgotten()
    {
        lock (_gate) return ForgottenUuids.ToList();
    }

    public bool IsForgotten(string id)
    {
        lock (_gate) return ForgottenUuids.Contains(id, StringComparer.OrdinalIgnoreCase);
    }

    /// <summary>Hides these ids from the list (saved when any is new).</summary>
    public void Forget(IEnumerable<string> ids)
    {
        var changed = false;
        lock (_gate)
            foreach (var id in ids)
                if (!ForgottenUuids.Contains(id, StringComparer.OrdinalIgnoreCase))
                {
                    ForgottenUuids.Add(id);
                    changed = true;
                }
        if (changed) Save();
    }

    /// <summary>Lists these ids again (saved when any was hidden).</summary>
    public void Unforget(IEnumerable<string> ids)
    {
        var set = ids.ToHashSet(StringComparer.OrdinalIgnoreCase);
        int removed;
        lock (_gate) removed = set.Count == 0 ? 0 : ForgottenUuids.RemoveAll(set.Contains);
        if (removed > 0) Save();
    }

    /// <summary>Remembers a printer (replacing what was remembered under its id) and saves.</summary>
    public void RememberPrinter(KnownPrinter printer)
    {
        lock (_gate)
        {
            Printers.RemoveAll(k => string.Equals(k.Uuid, printer.Uuid, StringComparison.OrdinalIgnoreCase));
            Printers.Add(printer);
        }
        Save();
    }

    /// <summary>Forgets the remembered printer with this id (not saved: the caller saves with the rest of the change).</summary>
    public void RemovePrinter(string id)
    {
        lock (_gate)
        {
            Printers.RemoveAll(k => string.Equals(k.Uuid, id, StringComparison.OrdinalIgnoreCase));
            Firmware.Remove(id);
        }
    }

    /// <summary>Printer id → its firmware version, the day first seen and the last change (roadmap 1.5, Core.History.FirmwareWatch).</summary>
    public Dictionary<string, Core.History.FirmwareRecord> Firmware { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public Core.History.FirmwareRecord? GetFirmware(string printerId)
    {
        lock (_gate) return Firmware.GetValueOrDefault(printerId);
    }

    /// <summary>Keeps the record and saves, when it differs from the one kept.</summary>
    public void SetFirmware(string printerId, Core.History.FirmwareRecord record)
    {
        lock (_gate)
        {
            if (Firmware.GetValueOrDefault(printerId) == record) return;
            Firmware[printerId] = record;
        }
        Save();
    }

    /// <summary>Printer UUID → SHA-256 of its TLS certificate (trust on first use).</summary>
    public Dictionary<string, string> CertificatePins { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Printer UUID → queue name Inkvolt Print created with Add-Printer -IppURL (printers added by address).</summary>
    public Dictionary<string, string> QueueNames { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>Queue name → whether its driver reports two-sided printing (cached: the query is slow).</summary>
    public Dictionary<string, bool> TwoSidedQueues { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>
    /// Printer id → other UUIDs the user confirmed are that printer ("This is my printer": a repair, reset or new network board
    /// gave it a new one). The printer keeps its id (pins, password, queue); these just count as it.
    /// </summary>
    public Dictionary<string, List<string>> AcceptedUuids { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public IReadOnlyList<string> GetAcceptedUuids(string printerId)
    {
        lock (_gate) return AcceptedUuids.TryGetValue(printerId, out var list) ? list.ToList() : [];
    }

    public void AcceptUuids(string printerId, IEnumerable<string> uuids)
    {
        lock (_gate)
        {
            if (!AcceptedUuids.TryGetValue(printerId, out var list)) AcceptedUuids[printerId] = list = [];
            foreach (var u in uuids)
                if (!list.Contains(u, StringComparer.OrdinalIgnoreCase)) list.Add(u);
        }
        Save();
    }

    /// <summary>Printers seen turning on automatic firmware installs when only the update check was enabled (no Notify for them).</summary>
    public List<string> NoFirmwareNotify { get; set; } = [];

    public bool KeepsFirmwareNotify(string uuid)
    {
        lock (_gate) return !NoFirmwareNotify.Contains(uuid, StringComparer.OrdinalIgnoreCase);
    }

    public void SetNoFirmwareNotify(string uuid)
    {
        lock (_gate)
        {
            if (NoFirmwareNotify.Contains(uuid, StringComparer.OrdinalIgnoreCase)) return;
            NoFirmwareNotify.Add(uuid);
        }
        Save();
    }

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
            if (AcceptedUuids.Remove(oldId, out var accepted)) AcceptedUuids.TryAdd(newId, accepted);
            if (Firmware.Remove(oldId, out var firmware)) Firmware.TryAdd(newId, firmware);
            for (var i = 0; i < NoFirmwareNotify.Count; i++)
                if (string.Equals(NoFirmwareNotify[i], oldId, StringComparison.OrdinalIgnoreCase)) NoFirmwareNotify[i] = newId;
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
            if (!File.Exists(FilePath)) return new() { IsNewInstall = true };
            var state = JsonSerializer.Deserialize<AppState>(File.ReadAllText(FilePath), Json) ?? new();
            // Hand-edited or older files can hold nulls; never let that stop the app from starting.
            state.Printers = (state.Printers ?? []).Where(k => k is { Uuid: not null, Host: not null }).ToList();
            state.ForgottenUuids ??= [];
            state.NoFirmwareNotify ??= [];
            state.AcceptedUuids = new((state.AcceptedUuids ?? []).Where(kv => kv.Value is not null), StringComparer.OrdinalIgnoreCase);
            state.CertificatePins = new(state.CertificatePins ?? [], StringComparer.OrdinalIgnoreCase);
            state.QueueNames = new(state.QueueNames ?? [], StringComparer.OrdinalIgnoreCase);
            state.TwoSidedQueues = new(state.TwoSidedQueues ?? [], StringComparer.OrdinalIgnoreCase);
            state.Firmware = new((state.Firmware ?? []).Where(kv => kv.Value is { Version: not null }), StringComparer.OrdinalIgnoreCase);
            state.Tray?.Repair();
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

/// <summary>
/// The notification-area icon and its alerts (Tray/TrayController). Off by default: Inkvolt Print then runs only while its window
/// is open, as before. "Start with Windows" lives in the registry (Tray/StartWithWindows), not here.
/// </summary>
public sealed class TraySettings
{
    /// <summary>Show the icon, and keep running there when the window is closed.</summary>
    public bool Enabled { get; set; }

    public bool Alerts { get; set; } = true;
    public int LowPercent { get; set; } = 15;
    public bool OfflineAlerts { get; set; } = true;
    public bool QuietHours { get; set; }

    /// <summary>Quiet hours, whole hours of the local clock (22 → 7).</summary>
    public int QuietFrom { get; set; } = 22;
    public int QuietTo { get; set; } = 7;

    public DateTimeOffset? PausedUntil { get; set; }

    /// <summary>"Still running in the notification area" was said once.</summary>
    public bool HintShown { get; set; }

    /// <summary>Printer UUID → keys of alerts shown that were still going on (Core.Alerts.AlertTracker.Shown).</summary>
    public Dictionary<string, List<string>> Shown { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    public static readonly int[] LowChoices = [5, 10, 15, 20, 25, 30, 40, 50];

    /// <summary>Back to how a new install starts (the alerts already shown and the one-time hint stay as they are).</summary>
    public void ResetPreferences()
    {
        var d = new TraySettings();
        (Enabled, Alerts, LowPercent, OfflineAlerts) = (d.Enabled, d.Alerts, d.LowPercent, d.OfflineAlerts);
        (QuietHours, QuietFrom, QuietTo, PausedUntil) = (d.QuietHours, d.QuietFrom, d.QuietTo, d.PausedUntil);
    }

    /// <summary>Hand-edited or older files: values back in range.</summary>
    public void Repair()
    {
        if (!LowChoices.Contains(LowPercent)) LowPercent = 15;
        if (QuietFrom is < 0 or > 23) QuietFrom = 22;
        if (QuietTo is < 0 or > 23) QuietTo = 7;
        Shown = new((Shown ?? []).Where(kv => kv.Key is not null && kv.Value is not null), StringComparer.OrdinalIgnoreCase);
    }
}
