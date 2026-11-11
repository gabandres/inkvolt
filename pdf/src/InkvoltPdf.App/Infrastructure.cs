using System.Diagnostics;
using System.IO;
using System.IO.Pipes;
using System.Security.Principal;
using System.Text;
using System.Text.Json;

namespace InkvoltPdf.App;

/// <summary>
/// Where Inkvolt PDF keeps its data. Depends on nothing else in the app (only a path helper from Inkvolt Print's core
/// library), so logging works from the first line of startup.
/// </summary>
public static class AppPaths
{
    /// <summary>
    /// %LOCALAPPDATA%\InkvoltPdf, or INKVOLTPDF_DATA when set (dev/script runs use a throwaway folder). First use moves
    /// the folder over from its pre-rename name (PdfDesk): settings, signatures and recent files carry over.
    /// </summary>
    public static string DataDirectory { get; } = Environment.GetEnvironmentVariable("INKVOLTPDF_DATA") is { Length: > 0 } dev
        ? dev
        : OpenUserDataDirectory();

    /// <summary>True when this run carried the data folder over from its pre-rename location (logged at startup).</summary>
    public static bool MovedLegacyData { get; private set; }

    private static string OpenUserDataDirectory()
    {
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        var folder = Path.Combine(local, "InkvoltPdf");
        MovedLegacyData = InkvoltPrint.Core.Suite.InkvoltPaths.AdoptLegacyFolder(Path.Combine(local, "PdfDesk"), folder);
        return folder;
    }

    /// <summary>Per-user id for the single-instance mutex/pipe and the settings lock.</summary>
    public static string UserId { get; } = WindowsIdentity.GetCurrent().User?.Value ?? Environment.UserName;
}

/// <summary>
/// Plain-text log at %LOCALAPPDATA%\InkvoltPdf\logs\inkvoltpdf.log (kept under ~1 MB, one rotation).
/// Local only; never log passwords or document contents, and prefer file names (<see cref="Name"/>) over full paths.
/// Independent of <see cref="AppSettings"/>, so it works before (and while) settings load.
/// </summary>
public static class Log
{
    private static readonly Lock Gate = new();
    private const long MaxBytes = 1_000_000;

    public static string FilePath { get; } = Path.Combine(AppPaths.DataDirectory, "logs", "inkvoltpdf.log");

    /// <summary>Just the file name of <paramref name="path"/>, for log lines that don't need the folder.</summary>
    public static string Name(string? path) => string.IsNullOrEmpty(path) ? "(unsaved)" : Path.GetFileName(path);

    public static void Write(string message)
    {
        try
        {
            message = message.Replace("\r\n", "\n").Replace("\n", "\n    ");
            Trace.WriteLine(message);
            lock (Gate)
            {
                Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
                if (File.Exists(FilePath) && new FileInfo(FilePath).Length > MaxBytes)
                    File.Move(FilePath, FilePath + ".1", overwrite: true);
                File.AppendAllText(FilePath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {message}{Environment.NewLine}");
            }
        }
        catch (Exception)
        {
            // Logging must never take the app down (it also runs inside crash handlers and static initializers).
        }
    }
}

/// <summary>Writes files via a temporary file in the same folder, then swaps it in, so a crash never leaves half a file.</summary>
public static class AtomicFile
{
    /// <param name="prepare">Runs on the finished temporary file before it is swapped in (e.g. to add a stream).</param>
    public static void WriteAllBytes(string path, byte[] bytes, Action<string>? prepare = null)
    {
        var full = Path.GetFullPath(path);
        var tmp = Path.Combine(Path.GetDirectoryName(full)!, $"~inkvoltpdf-{Guid.NewGuid():N}.tmp");
        try
        {
            using (var fs = new FileStream(tmp, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                fs.Write(bytes);
                fs.Flush(flushToDisk: true);
            }
            prepare?.Invoke(tmp);
            if (!File.Exists(full))
            {
                File.Move(tmp, full);
                return;
            }
            try
            {
                File.Replace(tmp, full, null, ignoreMetadataErrors: true);
            }
            catch (Exception ex) when (ex is IOException or PlatformNotSupportedException)
            {
                // Some file systems (FAT, a few network shares) don't support Replace.
                File.Move(tmp, full, overwrite: true);
            }
        }
        catch
        {
            try { File.Delete(tmp); } catch (Exception) { }
            throw;
        }
    }

    public static void WriteAllText(string path, string text) => WriteAllBytes(path, Encoding.UTF8.GetBytes(text));
}

/// <summary>Opens URLs and folders without letting a missing handler crash the app.</summary>
public static class Shell
{
    /// <summary>Dev scripts' <c>shellopen off</c>: what would open in another app (Word, a folder) is only logged.</summary>
    internal static bool OnlyLog { get; set; }

    public static void Open(string target)
    {
        if (OnlyLog)
        {
            Log.Write($"Shell open (script, not run): {Log.Name(target)}");
            return;
        }
        try
        {
            Process.Start(new ProcessStartInfo(target) { UseShellExecute = true })?.Dispose();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException or FileNotFoundException)
        {
            Log.Write($"Could not open {Log.Name(target)}: {ex.Message}");
        }
    }

    public static void ShowInFolder(string path)
    {
        try
        {
            // Through the shell, which passes on no handle (Process.Start's CreateProcess would pass MuPDF's to files open in place).
            Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true })?.Dispose();
        }
        catch (Exception ex) when (ex is System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            Log.Write($"Could not show {Log.Name(path)}: {ex.Message}");
        }
    }
}

/// <summary>
/// One Inkvolt PDF per user session. A second launch ("Open with Inkvolt PDF" while it's open) hands its file arguments to
/// the running copy over a named pipe only this user can open, then exits.
/// </summary>
public sealed class SingleInstance : IDisposable
{
    // Same scope for mutex and pipe: per user and per logon session. The mutex is Local\ (per session) but pipe names
    // are machine-wide, so the name carries the session id too, or a second session would hand its files to the first.
    private static readonly string Id = $"InkvoltPdf-{AppPaths.UserId}-{Process.GetCurrentProcess().SessionId}";
    private const int ConnectTimeoutMs = 10_000;
    private const int MaxListenFailures = 8;
    private const int MaxForwardedChars = 4 << 20;

    /// <summary>Null when this copy runs standalone because the owner couldn't be reached.</summary>
    private readonly Mutex? _mutex;
    private readonly CancellationTokenSource _cts = new();

    private SingleInstance(Mutex? mutex) => _mutex = mutex;

    /// <summary>True for the copy that owns the session (and listens for other launches).</summary>
    public bool IsOwner => _mutex is not null;

    // A standalone conversion copy's claim (LaunchHandoff): held for the process's life.
    private Mutex? _convertSlot;

    /// <summary>
    /// Returns the owner instance, or null after forwarding <paramref name="args"/> to the running one; for a conversion
    /// launch (<paramref name="convert"/>) also null when it gives up (<see cref="Core.LaunchHandoff"/>).
    /// </summary>
    public static SingleInstance? TryAcquire(string[] args, bool convert = false)
    {
        Mutex? mine = null, slot = null;
        var clock = Stopwatch.StartNew();
        var way = Core.LaunchHandoff.Find(convert,
            own: () =>
            {
                var mutex = new Mutex(initiallyOwned: true, $@"Local\{Id}", out var created);
                if (created) mine = mutex;
                else mutex.Dispose();
                return created;
            },
            forward: () => Forward(args),
            standaloneSlot: () => (slot = ConvertSlot()) is not null,
            elapsed: () => clock.Elapsed,
            wait: Thread.Sleep);
        switch (way)
        {
            case Core.LaunchHandoff.Way.Owner:
                return new SingleInstance(mine);
            case Core.LaunchHandoff.Way.Standalone:
                return new SingleInstance(null) { _convertSlot = slot };
            case Core.LaunchHandoff.Way.Dropped:
                Log.Write("Convert from Explorer: the running Inkvolt PDF didn't answer for a minute and another copy converts on its own; this launch's files were left out.");
                return null;
            default:
                return null;
        }
    }

    // One standalone conversion copy at a time (null: another one has it).
    private static Mutex? ConvertSlot()
    {
        var mutex = new Mutex(initiallyOwned: false, $@"Local\{Id}-convert");
        try
        {
            if (mutex.WaitOne(0)) return mutex;
        }
        catch (AbandonedMutexException)
        {
            return mutex; // its last holder ended without letting go: ours now
        }
        mutex.Dispose();
        return null;
    }

    /// <summary>
    /// Calls <paramref name="onArgs"/> (on a background thread) whenever another launch forwards its arguments.
    /// Start it before opening the startup files so simultaneous launches (a multi-file Explorer open) get through.
    /// Only the owner listens: a standalone fallback copy would just fight over the pipe name.
    /// </summary>
    /// <remarks>
    /// <see cref="StopListening"/> refuses new launches (they then run on their own) without dropping one already
    /// connected: its read goes on, and <see cref="InFlight"/> counts it until <paramref name="onArgs"/> has it.
    /// <paramref name="onRead"/> runs after each read, delivered or not. Listen again to take launches again.
    /// </remarks>
    public void Listen(Action<string[]> onArgs, Action? onRead = null)
    {
        // Already listening: nothing to do. A loop told to stop that hasn't ended yet (StopListening timed out) is no
        // listener: a new one starts beside it (the pipe takes several server instances), so launches are never left waiting.
        if (!IsOwner || _loop is { IsCompleted: false } && !_listen.IsCancellationRequested) return;
        _listen = CancellationTokenSource.CreateLinkedTokenSource(_cts.Token);
        var token = _listen.Token;
        var lifetime = _cts.Token;
        _loop = Task.Run(async () =>
        {
            var failures = 0;
            while (!token.IsCancellationRequested)
            {
                NamedPipeServerStream? server = null;
                try
                {
                    server = new NamedPipeServerStream(Id, PipeDirection.In, NamedPipeServerStream.MaxAllowedServerInstances,
                        PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
                    await server.WaitForConnectionAsync(token);
                    // Counted before the loop can end, so StopListening's caller sees it.
                    Interlocked.Increment(ref _inFlight);
                    failures = 0;
                    var connected = server;
                    server = null;
                    // Read on its own task so the next launch can connect right away; stopping the listening doesn't stop it.
                    _ = Task.Run(async () =>
                    {
                        try
                        {
                            await ReadAsync(connected, onArgs, lifetime);
                        }
                        finally
                        {
                            Interlocked.Decrement(ref _inFlight);
                            onRead?.Invoke();
                        }
                    });
                }
                catch (OperationCanceledException)
                {
                    return;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    // Log the first failure only, back off, and give up after a few tries instead of spinning.
                    if (++failures == 1) Log.Write($"Single-instance pipe: {ex.Message}");
                    if (failures >= MaxListenFailures)
                    {
                        Log.Write($"Single-instance pipe: giving up after {failures} failures; other launches will open their own window.");
                        return;
                    }
                    try
                    {
                        await Task.Delay(Math.Min(30_000, 500 << failures), token);
                    }
                    catch (OperationCanceledException)
                    {
                        return;
                    }
                }
                finally
                {
                    server?.Dispose();
                }
            }
        }, token);
    }

    private CancellationTokenSource _listen = new();
    private Task? _loop;
    private int _inFlight;

    /// <summary>Launches connected whose arguments haven't reached <c>onArgs</c> yet.</summary>
    public int InFlight => Volatile.Read(ref _inFlight);

    /// <summary>Takes no more launches (they open on their own) and waits for the listening to end (2 s at most).</summary>
    /// <returns>
    /// True once the listening has ended; false when it didn't within 2 s (a loaded PC): <see cref="InFlight"/> may then
    /// miss a launch just connecting, so the caller doesn't exit on it (it listens again and tries later).
    /// </returns>
    public bool StopListening()
    {
        _listen.Cancel();
        try
        {
            return _loop?.Wait(2000) ?? true;
        }
        catch (AggregateException)
        {
            return true; // ended (cancelled before it ran, or failed)
        }
    }

    private static async Task ReadAsync(NamedPipeServerStream server, Action<string[]> onArgs, CancellationToken token)
    {
        try
        {
            await using (server)
            {
                using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
                timeout.CancelAfter(10_000);
                using var reader = new StreamReader(server, Encoding.UTF8);
                // Bounded: a launch's command line is at most 32,767 characters (its paths made full stay far below
                // this); anything else writing to the pipe can't fill memory.
                var text = new StringBuilder();
                var buffer = new char[8192];
                int read;
                while ((read = await reader.ReadAsync(buffer, timeout.Token)) > 0)
                {
                    if (text.Length + read > MaxForwardedChars)
                    {
                        Log.Write("Single-instance: dropped a forwarded launch over its size limit");
                        return;
                    }
                    text.Append(buffer, 0, read);
                }
                onArgs(text.ToString().Split('\n', StringSplitOptions.RemoveEmptyEntries));
            }
        }
        catch (Exception ex) when (ex is IOException or OperationCanceledException or ObjectDisposedException)
        {
            if (!token.IsCancellationRequested) Log.Write($"Single-instance: dropped a forwarded launch: {ex.GetType().Name}");
        }
    }

    /// <summary>True when the running instance received the arguments.</summary>
    private static bool Forward(string[] args)
    {
        try
        {
            using var client = new NamedPipeClientStream(".", Id, PipeDirection.Out, PipeOptions.CurrentUserOnly);
            // Generous: the owner may itself be starting up (it listens before opening its own files).
            client.Connect(ConnectTimeoutMs);
            // The owner runs in another folder: every path becomes absolute against this launch's working directory.
            var bytes = Encoding.UTF8.GetBytes(string.Join('\n', args.Select(Absolute)));
            client.Write(bytes);
            client.Flush();
            return true;
        }
        catch (Exception ex) when (ex is IOException or TimeoutException or UnauthorizedAccessException or InvalidOperationException)
        {
            // The other instance is hung or shutting down: run standalone rather than losing the user's file.
            Log.Write($"Could not reach the running Inkvolt PDF ({ex.GetType().Name}); opening a separate window.");
            return false;
        }
    }

    /// <summary><paramref name="arg"/> as a full path (also when no such file exists); options and non-file URIs as they are.</summary>
    internal static string Absolute(string arg)
    {
        if (arg.Length == 0 || arg.StartsWith("--", StringComparison.Ordinal)
            || Uri.TryCreate(arg, UriKind.Absolute, out var uri) && !uri.IsFile)
            return arg;
        try
        {
            return Path.GetFullPath(arg);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return arg;
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        _convertSlot?.Dispose(); // let go at exit (abandoned is taken as free too)
        if (_mutex is null) return;
        try { _mutex.ReleaseMutex(); } catch (ApplicationException) { }
        _mutex.Dispose();
    }
}

/// <summary>
/// User preferences in %LOCALAPPDATA%\InkvoltPdf\settings.json. Saving writes atomically and merges list data (recent files,
/// per-file view state) with what another Inkvolt PDF window may have saved meanwhile.
/// </summary>
public sealed class AppSettings
{
    private const int MaxRecent = 15;
    private const int MaxFiles = 300;

    /// <summary>Same as <see cref="AppPaths.DataDirectory"/>.</summary>
    public static string DataDirectory => AppPaths.DataDirectory;

    private static string FilePath => Path.Combine(DataDirectory, "settings.json");

    // The window position starts as NaN ("not set yet"), which plain JSON can't represent.
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        WriteIndented = true,
        NumberHandling = System.Text.Json.Serialization.JsonNumberHandling.AllowNamedFloatingPointLiterals,
    };

    public static AppSettings Current { get; } = Load();

    /// <summary>Dev/script runs must not overwrite the user's settings.</summary>
    public static bool ReadOnly { get; set; }

    // What this process last read from or wrote to disk, and what it changed since: the base of the three-way merge.
    private HashSet<string> _baseRecent = new(StringComparer.OrdinalIgnoreCase);
    private HashSet<string> _baseFiles = new(StringComparer.OrdinalIgnoreCase);
    private readonly HashSet<string> _touched = new(StringComparer.OrdinalIgnoreCase);

    public List<string> RecentFiles { get; set; } = [];
    public double WindowLeft { get; set; } = double.NaN;
    public double WindowTop { get; set; } = double.NaN;
    public double WindowWidth { get; set; } = 1280;
    public double WindowHeight { get; set; } = 860;
    public bool WindowMaximized { get; set; } = true;
    public double NavPaneWidth { get; set; } = 210;
    public bool NavPaneVisible { get; set; } = true;
    public string Layout { get; set; } = "Continuous";
    public string ZoomMode { get; set; } = "FitWidth";
    public string LastFolder { get; set; } = "";

    /// <summary>"System", "Light" or "Dark".</summary>
    public string Theme { get; set; } = "System";
    /// <summary>The interface's language: null follows Windows' display language, "en" or "es" (AppLanguage, at the next start).</summary>
    public string? Language { get; set; }
    /// <summary>The version this was last run as ("1.0.3"): What's New after an update shows what came since (<see cref="AppHelp"/>).</summary>
    public string LastVersionSeen { get; set; } = "";
    /// <summary>No settings file when this run started: a new install, with nothing new to tell about.</summary>
    [System.Text.Json.Serialization.JsonIgnore]
    public bool IsNewInstall { get; private set; }
    /// <summary>Reopen each file at the page and zoom it was left at.</summary>
    public bool RestorePosition { get; set; } = true;
    /// <summary>Reopen the documents that were open when Inkvolt PDF was closed.</summary>
    public bool ReopenTabs { get; set; }
    /// <summary>Keep a recovery copy of documents with unsaved changes, offered back after a crash (<see cref="Autosave"/>).</summary>
    public bool KeepRecoveryCopies { get; set; } = true;
    /// <summary>Packaged installs: ask the Microsoft Store for updates a while after startup (MainWindow.Updates.cs).</summary>
    public bool CheckForUpdates { get; set; } = true;
    /// <summary>Packaged installs: saved documents counted toward the one Store rating request (MainWindow.Rating.cs).</summary>
    public InkvoltPrint.Core.Suite.RatingProgress? Rating { get; set; }
    /// <summary>The Inkvolt Pro licence key as pasted in Help › Inkvolt Pro ("" = none); checked by Core's <c>Pro</c> through <c>SettingsProStore</c>.</summary>
    public string ProKey { get; set; } = "";
    public List<string> OpenTabs { get; set; } = [];
    /// <summary>Show pages with inverted colors (night reading).</summary>
    public bool DarkPages { get; set; }
    public double OrganizerThumbSize { get; set; } = 170;
    /// <summary>Author name on new comments; empty = the Windows user name.</summary>
    public string AuthorName { get; set; } = "";
    /// <summary>Digital signing: the last digital ID used (certificate thumbprint) and the dialog's last choices.</summary>
    public string SignThumbprint { get; set; } = "";
    public string SignReason { get; set; } = "";
    public string SignLocation { get; set; } = "";
    public bool SignVisible { get; set; } = true;
    public bool SignShowDate { get; set; } = true;
    public bool SignShowReason { get; set; } = true;
    public bool SignShowDn { get; set; }
    public string SignImage { get; set; } = "";
    /// <summary>Add an RFC 3161 timestamp (sends only a hash of the signature to <see cref="TimestampUrl"/>).</summary>
    public bool SignTimestamp { get; set; }
    public string TimestampUrl { get; set; } = "";
    /// <summary>Long-term validation when signing (<see cref="LongTermLevel"/>).</summary>
    public int SignLongTerm { get; set; }
    /// <summary>Scan dialog (Inkvolt suite): the last scanner (a network one's UUID, "wia:…" or "twain:…") and the choices made for it.</summary>
    public string ScanDevice { get; set; } = "";
    public string ScanSource { get; set; } = "";
    public bool ScanColor { get; set; } = true;
    public int ScanResolution { get; set; } = 300;
    public string ScanPageSize { get; set; } = "";
    public bool ScanOcr { get; set; } = true;
    /// <summary>Black and white last chosen (<see cref="ScanColor"/> is then false).</summary>
    public bool ScanBlackAndWhite { get; set; }
    /// <summary>Leave out blank pages (the empty backs of one-sided sheets).</summary>
    public bool ScanSkipBlank { get; set; } = true;
    /// <summary>Scan presets saved in the Scan dialog (Inkvolt Print's preset shape; matched to each scanner when chosen).</summary>
    public List<InkvoltPrint.Core.Presets.ScanPreset> ScanPresets { get; set; } = [];
    /// <summary>Recognize Text: the OCR language last chosen (empty: Windows' default), clean pages first, mark suspect words.</summary>
    public string OcrLanguage { get; set; } = "";
    public bool OcrClean { get; set; } = true;
    public bool OcrSuspects { get; set; } = true;
    /// <summary>Export to Word / Excel / text: recognize scanned pages, open the file when done.</summary>
    public bool ExportOcr { get; set; } = true;
    public bool ExportOpen { get; set; } = true;
    /// <summary>Print: page sizing &amp; handling last chosen (<see cref="Core.PrintHandling"/> and its options).</summary>
    public string WebPaper { get; set; } = "";
    public bool WebLandscape { get; set; }
    public string WebMargins { get; set; } = "";
    public bool WebBackgrounds { get; set; } = true;
    public bool WebHeaderFooter { get; set; }

    public string BatchFolder { get; set; } = "";
    public string BatchTemplate { get; set; } = "";
    public bool BatchNeverOverwrite { get; set; } = true;
    public bool BatchKeepSubfolders { get; set; } = true;
    public bool BatchRecursive { get; set; } = true;
    /// <summary>Watched folders (<c>FolderWatches</c>): watched while the app is open, started again when it starts.</summary>
    public List<WatchSetting> WatchedFolders { get; set; } = [];
    /// <summary>Folders with a search index (<c>FolderSearches</c>): kept current while the app is open, started again when it starts.</summary>
    public List<IndexedFolderSetting> IndexedFolders { get; set; } = [];

    public string PrintHandling { get; set; } = "Fit";
    public bool PrintFitToPaper { get; set; }
    public int PrintPagesPerSheet { get; set; } = 2;
    public bool PrintOrderDown { get; set; }
    public bool PrintBorders { get; set; }
    public bool PrintRightBinding { get; set; }
    public int PrintPosterPercent { get; set; } = 200;
    public int PrintPosterOverlap { get; set; } = 1;
    public bool PrintCutMarks { get; set; } = true;
    /// <summary>
    /// AI assistant (bring your own; off by default): the endpoint ("Ollama", "LMStudio" or "Custom" with
    /// <see cref="AiCustomUrl"/>), model and context size. API keys are never here: see <c>AiKeyStore</c>.
    /// </summary>
    public bool AiEnabled { get; set; }
    public string AiPreset { get; set; } = "Ollama";
    public string AiCustomUrl { get; set; } = "";
    public string AiModel { get; set; } = "";
    public int AiContextTokens { get; set; } = Core.AiText.DefaultContextTokens;
    /// <summary>Endpoints (their base URLs) the user chose "don't ask again" for, and those the first-send warning was shown for.</summary>
    public List<string> AiNoPreview { get; set; } = [];
    public List<string> AiCloudWarned { get; set; } = [];

    /// <summary>The language last translated into.</summary>
    public string AiTranslateLanguage { get; set; } = "English";

    /// <summary>Each drawing tool's last look, by tool name ("Pen", "Rectangle"…); see <c>DrawStyles</c>.</summary>
    public Dictionary<string, DrawStyleSetting> DrawStyles { get; set; } = [];
    /// <summary>Per-file view state, keyed by full path (most recent 300 kept).</summary>
    public Dictionary<string, FileState> Files { get; set; } = new(StringComparer.OrdinalIgnoreCase);

    /// <summary>A watched folder: the preset file it runs, where results go ("" = the preset's folder, else "results" in it), stopped by the user.</summary>
    public sealed class WatchSetting
    {
        public string Folder { get; set; } = "";
        public string Preset { get; set; } = "";
        public string Output { get; set; } = "";
        public bool Paused { get; set; }
    }

    /// <summary>A folder with a search index, paused by the user or not. The index itself is a file in the data folder.</summary>
    public sealed class IndexedFolderSetting
    {
        public string Folder { get; set; } = "";
        public bool Paused { get; set; }
    }

    public sealed class FileState
    {
        public int Page { get; set; }
        public string ZoomMode { get; set; } = "FitWidth";
        public double Zoom { get; set; } = 1;
        public DateTime LastOpened { get; set; }
    }

    /// <summary>A drawing tool's look as saved: colors as "#RRGGBB" (null = none), sizes in points.</summary>
    public sealed class DrawStyleSetting
    {
        public string? Color { get; set; }
        public string? Fill { get; set; }
        public string? TextColor { get; set; }
        public double Width { get; set; }
        public double Opacity { get; set; } = 1;
        public double FontSize { get; set; } = 12;
        public string? StartEnding { get; set; }
        public string? EndEnding { get; set; }
    }

    /// <summary>What <see cref="ClearRecent"/> removed, for its Undo.</summary>
    public sealed record RecentSnapshot(List<string> RecentFiles, Dictionary<string, FileState> Files, List<string> OpenTabs);

    public void AddRecent(string path)
    {
        RecentFiles.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        RecentFiles.Insert(0, path);
        if (RecentFiles.Count > MaxRecent) RecentFiles.RemoveRange(MaxRecent, RecentFiles.Count - MaxRecent);
        LastFolder = Path.GetDirectoryName(path) ?? LastFolder;
        StateOf(path).LastOpened = DateTime.Now;
        Save();
    }

    /// <summary>Forgets a file: its recent entry, its remembered page/zoom and its reopen-at-startup entry.</summary>
    public void RemoveRecent(string path)
    {
        RecentFiles.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        Files.Remove(path);
        OpenTabs.RemoveAll(p => string.Equals(p, path, StringComparison.OrdinalIgnoreCase));
        _touched.Remove(path);
        Save();
    }

    /// <summary>Clears the recent list and every remembered file path (view state, tabs to reopen). Returns them for Undo.</summary>
    public RecentSnapshot ClearRecent()
    {
        var snapshot = new RecentSnapshot([.. RecentFiles], new Dictionary<string, FileState>(Files, StringComparer.OrdinalIgnoreCase), [.. OpenTabs]);
        RecentFiles.Clear();
        Files.Clear();
        OpenTabs.Clear();
        _touched.Clear();
        Save();
        return snapshot;
    }

    public void RestoreRecent(RecentSnapshot snapshot)
    {
        RecentFiles = [.. snapshot.RecentFiles];
        foreach (var (path, state) in snapshot.Files) Files.TryAdd(path, state);
        OpenTabs = [.. snapshot.OpenTabs];
        _touched.UnionWith(RecentFiles);
        _touched.UnionWith(Files.Keys);
        Save();
    }

    public FileState StateOf(string path)
    {
        // A new entry counts as just opened, so pruning (oldest first) never drops the file being viewed now.
        if (!Files.TryGetValue(path, out var state)) Files[path] = state = new FileState { LastOpened = DateTime.Now };
        _touched.Add(path);
        Prune();
        return state;
    }

    /// <summary>Keeps the <see cref="MaxFiles"/> most recently opened files; entries this window used since its last save go last.</summary>
    private void Prune()
    {
        if (Files.Count > MaxFiles)
            foreach (var old in Files.OrderBy(f => _touched.Contains(f.Key)).ThenBy(f => f.Value.LastOpened)
                         .Take(Files.Count - MaxFiles).Select(f => f.Key).ToList())
                Files.Remove(old);
    }

    public void Save()
    {
        if (ReadOnly) return;
        try
        {
            Directory.CreateDirectory(DataDirectory);
            using var gate = new Mutex(false, $@"Local\InkvoltPdf-settings-{AppPaths.UserId}");
            var locked = false;
            try
            {
                try
                {
                    locked = gate.WaitOne(2000);
                }
                catch (AbandonedMutexException)
                {
                    locked = true;
                }
                if (TryRead(out var disk)) MergeFrom(disk);
                AtomicFile.WriteAllText(FilePath, JsonSerializer.Serialize(this, JsonOptions));
                SetBaseline();
            }
            finally
            {
                if (locked) gate.ReleaseMutex();
            }
        }
        catch (Exception ex)
        {
            // Settings are a convenience: failing to save them must never block opening or saving a document.
            Log.Write($"Could not save settings: {ex.Message}");
        }
    }

    /// <summary>
    /// Three-way merge of the list data with the file on disk: keeps entries another window added since this one last read
    /// or wrote the file, drops entries another window removed (unless this window used them since), and keeps the newer
    /// view state when both have one. Plain preferences: last writer wins.
    /// </summary>
    private void MergeFrom(AppSettings disk)
    {
        foreach (var (path, state) in disk.Files)
        {
            if (Files.TryGetValue(path, out var mine))
            {
                if (state.LastOpened > mine.LastOpened) Files[path] = state;
            }
            else if (!_baseFiles.Contains(path))
            {
                Files[path] = state; // added by another window
            }
        }
        foreach (var path in _baseFiles.Where(p => !disk.Files.ContainsKey(p) && !_touched.Contains(p)).ToList())
            Files.Remove(path); // removed by another window

        var recent = new List<string>(RecentFiles);
        recent.RemoveAll(p => _baseRecent.Contains(p) && !disk.RecentFiles.Contains(p, StringComparer.OrdinalIgnoreCase) && !_touched.Contains(p));
        foreach (var path in disk.RecentFiles)
            if (!_baseRecent.Contains(path) && !recent.Contains(path, StringComparer.OrdinalIgnoreCase)) recent.Add(path);
        RecentFiles = [.. recent
            .Select((p, i) => (p, i, when: Files.TryGetValue(p, out var s) ? s.LastOpened : DateTime.MinValue))
            .OrderByDescending(x => x.when).ThenBy(x => x.i)
            .Select(x => x.p)
            .Take(MaxRecent)];
        Prune();
        Rating = InkvoltPrint.Core.Suite.RatingProgress.Merge(Rating, disk.Rating);
    }

    private void SetBaseline()
    {
        _baseRecent = new HashSet<string>(RecentFiles, StringComparer.OrdinalIgnoreCase);
        _baseFiles = new HashSet<string>(Files.Keys, StringComparer.OrdinalIgnoreCase);
        _touched.Clear();
    }

    /// <summary>Reads settings.json. A corrupt file is kept as settings.json.bak and logged, never silently dropped.</summary>
    private static bool TryRead(out AppSettings settings)
    {
        settings = new AppSettings();
        try
        {
            if (!File.Exists(FilePath)) return false;
            settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(FilePath), JsonOptions) ?? new AppSettings();
            settings.Files = new Dictionary<string, FileState>(settings.Files ?? [], StringComparer.OrdinalIgnoreCase);
            settings.RecentFiles ??= [];
            settings.OpenTabs ??= [];
            settings.AiNoPreview ??= [];
            settings.AiCloudWarned ??= [];
            return true;
        }
        catch (JsonException ex)
        {
            try
            {
                File.Copy(FilePath, FilePath + ".bak", overwrite: true);
                Log.Write($"Settings file is damaged; kept a copy as settings.json.bak and started fresh: {ex.Message}");
            }
            catch (Exception copyEx)
            {
                Log.Write($"Settings file is damaged and couldn't be backed up ({copyEx.Message}): {ex.Message}");
            }
            settings = new AppSettings();
            return false;
        }
        catch (Exception ex)
        {
            Log.Write($"Settings unreadable, using defaults: {ex.Message}");
            settings = new AppSettings();
            return false;
        }
    }

    private static AppSettings Load()
    {
        var isNew = !File.Exists(FilePath);
        TryRead(out var loaded);
        loaded.IsNewInstall = isNew;
        loaded.SetBaseline();
        return loaded;
    }
}
