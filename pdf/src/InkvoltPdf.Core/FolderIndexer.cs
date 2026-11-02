using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.IO.Enumeration;
using System.Text;

namespace InkvoltPdf.Core;

/// <summary>How an indexer goes about it. Tests shorten the times.</summary>
public sealed record FolderIndexerOptions
{
    /// <summary>The program to start as a worker; by default what <see cref="IndexWorkers.Use"/> was told.</summary>
    public string? WorkerExe { get; init; }

    public IReadOnlyList<string> WorkerArgs { get; init; } = [];

    /// <summary>Workers at most at one time. A background job: half the cores, up to four.</summary>
    public int MaxWorkers { get; init; } = Math.Clamp(Environment.ProcessorCount / 2, 1, 4);

    /// <summary>A file written this recently waits: it may still be changing.</summary>
    public TimeSpan Quiet { get; init; } = TimeSpan.FromSeconds(2);

    /// <summary>The folder is listed at least this often, in case the system's change notices miss something (network drives do).</summary>
    public TimeSpan Rescan { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>After a change notice, how long to wait for the rest of a burst.</summary>
    public TimeSpan Debounce { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>What has been read is committed at least this often, so a crash costs little and a search sees it.</summary>
    public TimeSpan CommitEvery { get; init; } = TimeSpan.FromSeconds(10);

    /// <summary>...or once this much is waiting in memory.</summary>
    public long CommitBytes { get; init; } = 32L * 1048576;

    /// <summary>A worker is given this much processor time for one file: a busy PC doesn't count against a file.</summary>
    public TimeSpan FileDeadline { get; init; } = TimeSpan.FromMinutes(2);

    /// <summary>...and this long between signs of life while the PC is awake, for a worker stuck without using the processor.</summary>
    public TimeSpan Stall { get; init; } = TimeSpan.FromMinutes(10);

    /// <summary>Pausing lets files being read finish for this long, then ends their workers (the files are read again later).</summary>
    public TimeSpan PauseGrace { get; init; } = TimeSpan.FromSeconds(2);

    public long MaxFileBytes { get; init; } = 512L * 1048576;

    public int MaxPages { get; init; } = 50_000;

    public long MaxChars { get; init; } = 32L * 1048576;

    /// <summary>A worker is replaced after this many files, so what MuPDF and the runtime hold on to can't build up.</summary>
    public int FilesPerWorker { get; init; } = 1000;

    /// <summary>More separate lists of terms than this are compacted into one.</summary>
    public int MaxSegments { get; init; } = 8;

    /// <summary>Text of a changed or removed file leaves the index file at the next compaction, this long after the last at the earliest.</summary>
    public TimeSpan CompactAfter { get; init; } = TimeSpan.FromMinutes(2);

    internal IndexLimits Limits => new(MaxFileBytes, MaxPages, MaxChars);
}

public enum IndexerPhase
{
    Starting,
    Scanning,
    Indexing,
    Compacting,
    UpToDate,
    Paused,
    Stopped,

    /// <summary>Something is in the way (<see cref="IndexerStatus.Problem"/>); it tries again by itself.</summary>
    Problem,
}

/// <summary>Where an indexer is now.</summary>
/// <param name="Searchable">Files with text in the index.</param>
/// <param name="Waiting">Files left in this pass.</param>
/// <param name="Done">Files read in this pass.</param>
/// <param name="Skipped">Files that couldn't be indexed, by why; <see cref="IndexedState.NoText"/> among them.</param>
/// <param name="Unavailable">Files that couldn't be opened just now, tried again on the next pass.</param>
/// <param name="CloudOnly">Files only on a cloud drive so far: reading them would download them, so they wait until they are on this PC.</param>
public sealed record IndexerStatus(IndexerPhase Phase, int Searchable, int Waiting, int Done, IReadOnlyDictionary<IndexedState, int> Skipped, int Unavailable, int CloudOnly, string? Problem)
{
    /// <summary>The whole state in one line for the window, and what was left out says so.</summary>
    public string Text
    {
        get
        {
            var sb = new StringBuilder();
            sb.Append(Phase switch
            {
                IndexerPhase.Starting => "Starting.",
                IndexerPhase.Scanning => "Looking through the folder.",
                IndexerPhase.Indexing => string.Create(CultureInfo.CurrentCulture, $"Indexing: {Done:N0} of {Done + Waiting:N0} files read."),
                IndexerPhase.Compacting => "Tidying the index.",
                IndexerPhase.UpToDate => "Up to date.",
                IndexerPhase.Paused => "Paused.",
                IndexerPhase.Stopped => "Stopped.",
                _ => Problem ?? "Something is in the way.",
            });
            sb.Append(string.Create(CultureInfo.CurrentCulture, $" {Searchable:N0} {(Searchable == 1 ? "PDF" : "PDFs")} searchable."));
            var skipped = Skipped.Where(s => s.Value > 0).ToList();
            var left = skipped.Where(s => s.Key != IndexedState.NoText).ToList();
            if (left.Count > 0)
            {
                sb.Append(string.Create(CultureInfo.CurrentCulture, $" {left.Sum(s => s.Value):N0} skipped or cut short: "));
                sb.Append(string.Join(", ", left.Select(s => string.Create(CultureInfo.CurrentCulture, $"{s.Value:N0} {FolderIndexer.Describe(s.Key)}"))));
                sb.Append('.');
            }
            if (Skipped.TryGetValue(IndexedState.NoText, out var scans) && scans > 0)
                sb.Append(string.Create(CultureInfo.CurrentCulture, $" {scans:N0} with no text yet (scans: Recognize Text makes them searchable)."));
            if (Unavailable > 0) sb.Append(string.Create(CultureInfo.CurrentCulture, $" {Unavailable:N0} couldn't be opened just now and will be tried again."));
            if (CloudOnly > 0) sb.Append(string.Create(CultureInfo.CurrentCulture, $" {CloudOnly:N0} only in the cloud, not downloaded for this."));
            return sb.ToString();
        }
    }
}

/// <summary>A file the index has no (or not all of its) text for, and why.</summary>
public sealed record SkippedFile(string RelativePath, IndexedState Why, string Reason);

/// <summary>
/// Keeps one folder's <see cref="FolderIndex"/> current, on a thread of its own at low priority: lists the folder (subfolders too),
/// has <see cref="IndexWorkers">index workers</see> read what is new or changed, commits as it goes, and then waits for
/// the system's change notices or the next look. A file is known by its size and last-write time, so nothing is read twice, and
/// no worker runs while nothing changes. A file that can't be indexed (damaged, a password, too big, too slow, crashes the
/// reader) is counted, kept in the index with why, and tried again only when it changes or the index is rebuilt.
/// Text is what PDFs carry, OCR text layers included; a page with no text isn't recognized here.
/// </summary>
public sealed class FolderIndexer : IDisposable
{
    private readonly string _folder;
    private readonly string _basePath;
    private readonly FolderIndexerOptions _options;
    private readonly CancellationTokenSource _stop = new();
    private readonly AutoResetEvent _wake = new(false);
    private readonly Lock _gate = new();                    // the batch and what workers count
    private readonly Thread _thread;
    private readonly ConcurrentDictionary<IndexWorkers.Link, byte> _links = new();
    private readonly Dictionary<(string Path, long Ticks), int> _crashes = [];
    private FolderIndex? _index;
    private IndexBatch? _batch;
    private FileSystemWatcher? _watcher;
    private ConcurrentQueue<Item> _queue = new();
    private volatile bool _paused;
    private volatile bool _noted;
    private volatile bool _rebuild;
    private volatile bool _workersFailed;
    private volatile bool _deleteIndex;
    private volatile bool _abortPass;
    private volatile IndexerStatus _status = new(IndexerPhase.Starting, 0, 0, 0, new Dictionary<IndexedState, int>(), 0, 0, null);
    private IndexerPhase _phase = IndexerPhase.Starting;
    private string? _problem;
    private int _waiting, _done, _unavailable, _cloudOnly;
    private DateTime _lastCompact = DateTime.MinValue;
    private TimeSpan _compactTook;
    private long _lastPublish;

    /// <summary>The status changed (at most a few times a second; on the indexer's thread).</summary>
    public event Action? Changed;

    public FolderIndexer(string folder, string basePath, FolderIndexerOptions? options = null, bool startPaused = false)
    {
        _folder = Path.TrimEndingDirectorySeparator(Path.GetFullPath(folder));
        _basePath = basePath;
        _options = options ?? new FolderIndexerOptions();
        _paused = startPaused;
        _thread = new Thread(Loop) { IsBackground = true, Priority = ThreadPriority.BelowNormal, Name = "Inkvolt PDF folder index" };
    }

    public string Folder => _folder;

    public IndexerStatus Status => _status;

    public bool IsPaused => _paused;

    /// <summary>Test hook: workers running now.</summary>
    internal int LiveWorkers => _links.Count;

    /// <summary>The index, once it is open; searches go straight to it.</summary>
    public FolderIndex? Index => Volatile.Read(ref _index);

    public void Start() => _thread.Start();

    /// <summary>Stops reading within <see cref="FolderIndexerOptions.PauseGrace"/>; what was read is committed, and nothing is lost.</summary>
    public void Pause()
    {
        _paused = true;
        _wake.Set();
    }

    public void Resume()
    {
        _paused = false;
        _wake.Set();
    }

    /// <summary>Look at the folder now.</summary>
    public void Refresh()
    {
        _noted = true;
        _wake.Set();
    }

    /// <summary>Throws the index away and reads everything again (skipped files get another chance).</summary>
    public void Rebuild()
    {
        _rebuild = true;
        _wake.Set();
    }

    /// <summary>What the index has no text for, and why, in path order.</summary>
    public List<SkippedFile> Skipped()
    {
        if (Index is not { } index) return [];
        return [.. index.Files.Values
            .Where(f => f.State != IndexedState.Indexed || f.FailedPages > 0)
            .OrderBy(f => f.RelativePath, StringComparer.OrdinalIgnoreCase)
            .Select(f => new SkippedFile(f.RelativePath, f.State, f.State == IndexedState.Indexed
                ? string.Create(CultureInfo.CurrentCulture, $"{f.FailedPages:N0} of {f.Pages:N0} pages couldn't be read")
                : Describe(f.State)))];
    }

    /// <summary>Why a file isn't (fully) in the index, in a few words.</summary>
    public static string Describe(IndexedState state) => state switch
    {
        IndexedState.NoText => "no text (a scan)",
        IndexedState.Password => "password protected",
        IndexedState.Damaged => "damaged",
        IndexedState.TooBig => "too big",
        IndexedState.TooSlow => "too slow to read",
        IndexedState.Crashed => "crashed the reader",
        _ => "indexed",
    };

    /// <summary>Stops, as soon as the workers are ended and what was read is committed, and closes the index. Waits up to <paramref name="wait"/>.</summary>
    public void Stop(TimeSpan wait)
    {
        _stop.Cancel();
        _wake.Set();
        foreach (var link in _links.Keys) link.EndFor("stopped");
        if (_thread.IsAlive) _thread.Join(wait);
    }

    /// <summary>Stops and deletes the index.</summary>
    public void StopAndDelete(TimeSpan wait)
    {
        _deleteIndex = true;
        var started = _thread.ThreadState != System.Threading.ThreadState.Unstarted;
        Stop(wait);
        if (started) return;
        try
        {
            FolderIndex.Open(_basePath).DisposeAndDelete();
        }
        catch (IOException) { }
    }

    public void Dispose()
    {
        Stop(TimeSpan.FromSeconds(10));
        if (_thread.IsAlive) return; // still finishing a write: what it uses stays
        _stop.Dispose();
        _wake.Dispose();
    }

    private void Loop()
    {
        try
        {
            while (!_stop.IsCancellationRequested)
            {
                if (Index is null && !OpenIndex())
                {
                    Wait(_options.Rescan);
                    continue;
                }
                if (_rebuild)
                {
                    _rebuild = false;
                    Index!.Clear();
                    _crashes.Clear();
                }
                if (_paused)
                {
                    SetPhase(IndexerPhase.Paused);
                    Wait(Timeout.InfiniteTimeSpan);
                    continue;
                }
                TimeSpan next;
                try
                {
                    next = Pass();
                }
                catch (FolderIndexDamagedException)
                {
                    // Found while tidying: its text is all in the PDFs. Read again from nothing.
                    Index!.Clear();
                    continue;
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    _problem = $"Couldn't write the index: {ex.Message}";
                    SetPhase(IndexerPhase.Problem);
                    next = _options.Rescan;
                }
                catch (OperationCanceledException)
                {
                    continue;
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    // A thread of its own: anything left unhandled here would take the app down with it.
                    _problem = $"Indexing stopped on an error: {ex.Message}";
                    SetPhase(IndexerPhase.Problem);
                    next = _options.Rescan;
                }
                Wait(next);
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            _problem = $"Indexing stopped on an error: {ex.Message}";
        }
        finally
        {
            lock (_gate)
            {
                try
                {
                    if (!_deleteIndex) CommitBatch();
                }
                catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                {
                    // Read again next time.
                }
            }
            SetPhase(IndexerPhase.Stopped);
            _watcher?.Dispose();
            var index = Interlocked.Exchange(ref _index, null);
            if (_deleteIndex) index?.DisposeAndDelete();
            else index?.Dispose();
        }
    }

    private bool OpenIndex()
    {
        try
        {
            var index = FolderIndex.Open(_basePath);
            Volatile.Write(ref _index, index);
            _problem = null;
            StartWatching();
            return true;
        }
        catch (FolderIndexBusyException ex)
        {
            _problem = ex.Message;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _problem = $"Couldn't open the index: {ex.Message}";
        }
        SetPhase(IndexerPhase.Problem);
        return false;
    }

    /// <summary>The system's notices of changes in the folder; without them (some network drives) the regular look still finds everything.</summary>
    private void StartWatching()
    {
        try
        {
            if (!Directory.Exists(_folder)) return;
            _watcher?.Dispose();
            var w = new FileSystemWatcher(_folder)
            {
                IncludeSubdirectories = true,
                InternalBufferSize = 64 * 1024,
                NotifyFilter = NotifyFilters.FileName | NotifyFilters.DirectoryName | NotifyFilters.LastWrite | NotifyFilters.Size,
            };
            void Noted(object? sender, FileSystemEventArgs e)
            {
                var pdf = e.Name is { } name && name.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase);
                if (!pdf && (e.ChangeType == WatcherChangeTypes.Changed || (e.Name is { } other && Path.HasExtension(other)))) return; // not a PDF, and not a folder that came or went
                _noted = true;
                _wake.Set();
            }
            w.Created += Noted;
            w.Changed += Noted;
            w.Deleted += Noted;
            w.Renamed += Noted;
            w.Error += (_, _) => Refresh();
            w.EnableRaisingEvents = true;
            _watcher = w;
        }
        catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException)
        {
            _watcher = null;
        }
    }

    /// <summary>Waits for a notice, a command or the time, and stays a moment after a notice for the rest of the burst.</summary>
    private void Wait(TimeSpan time)
    {
        if (_stop.IsCancellationRequested) return;
        var signaled = WaitHandle.WaitAny([_wake, _stop.Token.WaitHandle], time) == 0;
        if (signaled && _noted && !_stop.IsCancellationRequested)
        {
            _noted = false;
            _stop.Token.WaitHandle.WaitOne(_options.Debounce);
        }
    }

    // ---- One look at the folder ----

    private sealed record Item(string RelativePath, string FullPath, long Size, long Ticks);

    /// <summary>Lists the folder, reads what is new or changed, takes out what is gone. Returns how long until the next look.</summary>
    private TimeSpan Pass()
    {
        _noted = false;
        SetPhase(IndexerPhase.Scanning);
        var index = Index!;
        if (!Directory.Exists(_folder))
        {
            // A drive that is away for now: the index stays as it is. Only a listing that worked can take files out.
            _problem = "The folder isn't there just now. The index stays as it is, and its files are found again when it's back.";
            SetPhase(IndexerPhase.Problem);
            return _options.Rescan;
        }
        if (_watcher is null) StartWatching();
        _problem = null;

        List<Item> listed;
        var cloud = 0;
        var recent = false;
        var known = index.Files;
        var present = new HashSet<string>(known.Count, StringComparer.OrdinalIgnoreCase);
        var queue = new List<Item>();
        var tooBig = new List<Item>();
        try
        {
            var now = DateTime.UtcNow;
            listed = [];
            foreach (var file in ListPdfs(_folder))
            {
                if (file.Name.StartsWith("~$", StringComparison.Ordinal)) continue;
                var rel = Path.GetRelativePath(_folder, file.FullName);
                var (size, ticks) = (file.Length, file.LastWriteTimeUtc.Ticks);
                var same = known.TryGetValue(rel, out var had) && had.Size == size && had.WriteTicks == ticks;
                if (!same && IsLink(file)) continue;
                present.Add(rel);
                if (same) continue;
                if (IsCloudOnly(file.Attributes))
                {
                    cloud++; // reading it would download it
                    continue;
                }
                var age = now - file.LastWriteTimeUtc;
                if (age >= TimeSpan.Zero && age < _options.Quiet)
                {
                    recent = true; // may still be being written: next look
                    continue;
                }
                if (size > _options.MaxFileBytes) tooBig.Add(new Item(rel, file.FullName, size, ticks));
                else queue.Add(new Item(rel, file.FullName, size, ticks));
            }
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            _problem = $"Couldn't list the folder: {ex.Message}";
            SetPhase(IndexerPhase.Problem);
            return _options.Rescan;
        }
        _cloudOnly = cloud;

        var gone = known.Values.Where(f => !present.Contains(f.RelativePath)).ToList();
        _unavailable = 0;
        _done = 0;
        lock (_gate)
        {
            _batch = index.NewBatch();
            foreach (var f in gone) _batch.Remove(f);
            foreach (var item in tooBig) Record(item, IndexedState.TooBig, 0, 0, null);
        }
        Read(queue);
        lock (_gate) CommitBatch();
        Tidy(index);
        if (_stop.IsCancellationRequested) return TimeSpan.Zero;
        if (_workersFailed)
        {
            _workersFailed = false;
            _problem = "Couldn't start the process that reads files. Trying again shortly.";
            SetPhase(IndexerPhase.Problem);
            return _options.Rescan;
        }
        if (_paused) return TimeSpan.Zero;
        _waiting = 0;
        SetPhase(IndexerPhase.UpToDate);
        return recent ? _options.Quiet : _options.Rescan;
    }

    /// <summary>
    /// The PDFs under <paramref name="folder"/>. A link is left alone (it leads outside the folder, or round in a circle), which the
    /// reparse-point attribute can't say by itself: a cloud drive's files and folders carry it too, in a process that sees them
    /// as what they are (a usual one sees them disguised as plain files).
    /// </summary>
    private static FileSystemEnumerable<FileInfo> ListPdfs(string folder) =>
        new(folder, static (ref FileSystemEntry entry) => (FileInfo)entry.ToFileSystemInfo(), new EnumerationOptions
        {
            RecurseSubdirectories = true,
            IgnoreInaccessible = true,
            AttributesToSkip = FileAttributes.Hidden | FileAttributes.System | FileAttributes.Temporary,
        })
        {
            ShouldIncludePredicate = static (ref FileSystemEntry entry) => !entry.IsDirectory && FileSystemName.MatchesSimpleExpression("*.pdf", entry.FileName),
            ShouldRecursePredicate = static (ref FileSystemEntry entry) => (entry.Attributes & FileAttributes.ReparsePoint) == 0 || !IsLink(entry.ToFileSystemInfo()),
        };

    /// <summary>A symbolic link or junction, as against a cloud drive's placeholder. Asking reads no file's data, so downloads nothing.</summary>
    private static bool IsLink(FileSystemInfo entry)
    {
        if ((entry.Attributes & FileAttributes.ReparsePoint) == 0) return false;
        try
        {
            return entry.LinkTarget is not null;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return true; // can't tell: left alone, as anything out of reach is
        }
    }

    /// <summary>A file of a cloud drive with its bytes elsewhere: Offline, RecallOnOpen or RecallOnDataAccess.</summary>
    internal static bool IsCloudOnly(FileAttributes attributes) =>
        (attributes & (FileAttributes.Offline | (FileAttributes)0x40000 | (FileAttributes)0x400000)) != 0;

    private void Tidy(FolderIndex index)
    {
        if (_stop.IsCancellationRequested || _paused) return;
        var due = index.HasDeadText && DateTime.UtcNow - _lastCompact >= Max(_options.CompactAfter, TimeSpan.FromTicks(_compactTook.Ticks * 100));
        if (index.Segments <= _options.MaxSegments && !due) return;
        SetPhase(IndexerPhase.Compacting);
        var started = Stopwatch.GetTimestamp();
        index.Compact(_stop.Token);
        _compactTook = Stopwatch.GetElapsedTime(started);
        _lastCompact = DateTime.UtcNow;
    }

    private static TimeSpan Max(TimeSpan a, TimeSpan b) => a > b ? a : b;

    /// <summary>Reads the files through workers, keeping an eye on them, committing as it goes, until done, paused or stopped.</summary>
    private void Read(List<Item> items)
    {
        if (items.Count == 0) return;
        // Small files first: most of a folder becomes searchable soonest, whatever a huge file takes.
        _queue = new ConcurrentQueue<Item>(items.OrderBy(i => i.Size));
        _waiting = items.Count;
        var (exe, args) = _options.WorkerExe is { } own ? (own, _options.WorkerArgs.ToArray()) : IndexWorkers.Program;
        if (exe is null)
        {
            _workersFailed = true;
            return;
        }
        SetPhase(IndexerPhase.Indexing);
        var count = Math.Clamp(items.Count / 8 + 1, 1, Math.Max(1, _options.MaxWorkers));
        var threads = new List<Thread>();
        for (var i = 0; i < count; i++)
        {
            var thread = new Thread(() => Serve(exe, args)) { IsBackground = true, Priority = ThreadPriority.BelowNormal, Name = "Inkvolt PDF index reader" };
            threads.Add(thread);
            thread.Start();
        }

        var lastCommit = Stopwatch.GetTimestamp();
        long pausedAt = 0;
        Exception? failed = null;
        var ticked = Stopwatch.GetTimestamp();
        while (threads.Exists(t => t.IsAlive))
        {
            threads[0].Join(100);
            threads.RemoveAll(t => !t.IsAlive);
            // Time asleep is no time at all: a tick is never counted as more than a second.
            var tick = Stopwatch.GetElapsedTime(ticked);
            ticked = Stopwatch.GetTimestamp();
            if (tick > TimeSpan.FromSeconds(1)) tick = TimeSpan.FromSeconds(1);
            foreach (var link in _links.Keys)
            {
                if (link.Watch(tick) is not { } watch) continue;
                if (watch.Cpu > _options.FileDeadline || watch.Quiet > _options.Stall) link.EndFor(EndedTooSlow);
            }
            if (_paused)
            {
                if (pausedAt == 0) pausedAt = Stopwatch.GetTimestamp();
                else if (Stopwatch.GetElapsedTime(pausedAt) > _options.PauseGrace)
                    foreach (var link in _links.Keys) link.EndFor(EndedInterrupted);
            }
            else pausedAt = 0;
            lock (_gate)
            {
                if (_batch is { IsEmpty: false } batch &&
                    (batch.Bytes >= _options.CommitBytes || batch.TermCount > 2_000_000 || Stopwatch.GetElapsedTime(lastCommit) >= _options.CommitEvery))
                {
                    try
                    {
                        CommitBatch();
                    }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
                    {
                        // The disk is full, say. The readers stop here; what they read is read again.
                        failed = ex;
                        _abortPass = true;
                    }
                    lastCommit = Stopwatch.GetTimestamp();
                }
            }
            Publish();
        }
        _abortPass = false;
        if (failed is not null) throw failed;
    }

    private const string EndedTooSlow = "too slow", EndedInterrupted = "interrupted";

    /// <summary>One worker's thread: takes files until there are none left or it is told to stop.</summary>
    private void Serve(string exe, string[] args)
    {
        IndexWorkers.Link? link = null;
        var pages = new Dictionary<int, string>();
        try
        {
            while (!_paused && !_abortPass && !_stop.IsCancellationRequested && _queue.TryDequeue(out var item))
            {
                pages.Clear();
                if (!CanOpen(item))
                {
                    Interlocked.Increment(ref _unavailable);
                    Interlocked.Decrement(ref _waiting);
                    continue;
                }
                try
                {
                    if (link is null)
                    {
                        link = new IndexWorkers.Link(exe, args, 15_000);
                        _links[link] = 0;
                    }
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    _workersFailed = true;
                    return; // the file is seen again on the next look
                }

                var (end, count, failed) = default((WorkerEnd, int, int));
                string? ended = null;
                try
                {
                    (end, count, failed) = link.Read(item.FullPath, _options.Limits, pages);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    ended = link.EndedFor ?? "crashed";
                    Close(ref link);
                }

                try
                {
                    switch (ended)
                    {
                        case null:
                            Finish(item, end, count, failed, pages);
                            break;
                        case EndedTooSlow:
                            Record(item, IndexedState.TooSlow, CountOf(pages), 0, pages);
                            break;
                        case "crashed":
                            // Once more in case it was something else that ended the worker; twice is the file.
                            if (Crashes(item) < 2) _queue.Enqueue(item);
                            else Record(item, IndexedState.Crashed, CountOf(pages), 0, pages);
                            break;
                        default:
                            Interlocked.Decrement(ref _waiting); // paused or stopped: the next look finds it
                            break;
                    }
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    // Text no one expected: this file is left out, and the others go on.
                    Record(item, IndexedState.Damaged, 0, 0, null);
                }
                if (link is { } running && running.Files >= _options.FilesPerWorker) Close(ref link);
            }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            _workersFailed = true; // on a thread of its own: nothing here may take the app down
        }
        finally
        {
            Close(ref link);
        }
    }

    private void Close(ref IndexWorkers.Link? link)
    {
        if (link is null) return;
        _links.TryRemove(link, out _);
        link.Dispose();
        link = null;
    }

    private int Crashes(Item item)
    {
        lock (_crashes)
        {
            var key = (item.RelativePath, item.Ticks);
            _crashes.TryGetValue(key, out var n);
            _crashes[key] = ++n;
            return n;
        }
    }

    /// <summary>Not while someone is writing it (a copy under way): no worker is started for a file that can't be read yet.</summary>
    private static bool CanOpen(Item item)
    {
        try
        {
            using var _ = new FileStream(item.FullPath, FileMode.Open, FileAccess.Read, FileShare.Read | FileShare.Delete, 1);
            return true;
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            return false;
        }
    }

    private static int CountOf(Dictionary<int, string> pages) => pages.Count == 0 ? 0 : pages.Keys.Max() + 1;

    private void Finish(Item item, WorkerEnd end, int count, int failed, Dictionary<int, string> pages)
    {
        switch (end)
        {
            case WorkerEnd.Read:
                Record(item, pages.Count > 0 ? IndexedState.Indexed : IndexedState.NoText, count, failed, pages);
                break;
            case WorkerEnd.Password:
                Record(item, IndexedState.Password, 0, 0, null);
                break;
            case WorkerEnd.Damaged:
                Record(item, IndexedState.Damaged, 0, 0, null);
                break;
            case WorkerEnd.TooBig:
                Record(item, IndexedState.TooBig, Math.Max(CountOf(pages), pages.Count > 0 ? count : 0), failed, pages);
                break;
            default:
                Interlocked.Increment(ref _unavailable);
                Interlocked.Decrement(ref _waiting);
                break;
        }
    }

    /// <summary>What became of a file, into the batch: its words outside the file's own lock are the only slow part, and there are never many threads.</summary>
    private void Record(Item item, IndexedState state, int pageCount, int failed, Dictionary<int, string>? pages)
    {
        var list = new string?[pageCount];
        if (pages is not null)
            foreach (var (page, text) in pages)
                if (page < list.Length) list[page] = text;
        var packed = FolderIndex.PackPages(list);
        lock (_gate)
        {
            if (_batch is not { } batch || Index is not { } index) return;
            if (index.Files.TryGetValue(item.RelativePath, out var had)) batch.Remove(had);
            batch.Add(item.RelativePath, item.Size, item.Ticks, state, pageCount, failed, packed, list);
            _done++;
            Interlocked.Decrement(ref _waiting);
        }
    }

    /// <summary>Commits what is waiting (under <see cref="_gate"/>).</summary>
    private void CommitBatch()
    {
        if (_batch is not { IsEmpty: false } batch || Index is not { } index) return;
        var next = default(IndexBatch);
        try
        {
            index.Commit(batch);
            next = index.NewBatch();
        }
        finally
        {
            _batch = next; // on failure the batch is dropped: its files are read again on the next look
        }
        Publish(force: true);
    }

    private void SetPhase(IndexerPhase phase)
    {
        _phase = phase;
        Publish(force: true);
    }

    private void Publish(bool force = false)
    {
        var now = Environment.TickCount64;
        if (!force && now - Volatile.Read(ref _lastPublish) < 250) return;
        Volatile.Write(ref _lastPublish, now);
        var skipped = new Dictionary<IndexedState, int>();
        var searchable = 0;
        if (Index is { } index)
        {
            foreach (var f in index.Files.Values)
            {
                if (f.State is IndexedState.Indexed || (f.State is IndexedState.TooBig or IndexedState.TooSlow or IndexedState.Crashed && f.Pages > 0)) searchable++;
                if (f.State == IndexedState.Indexed) continue;
                skipped.TryGetValue(f.State, out var n);
                skipped[f.State] = n + 1;
            }
        }
        _status = new IndexerStatus(_phase, searchable, Math.Max(0, _waiting), _done, skipped, _unavailable, _cloudOnly, _problem);
        Changed?.Invoke();
    }
}
