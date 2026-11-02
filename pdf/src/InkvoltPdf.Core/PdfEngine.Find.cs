using System.ComponentModel;
using System.Diagnostics;
using System.IO.MemoryMappedFiles;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>Find across a document: <see cref="FindAll"/>, on threads here and, for a long search, in worker processes (<see cref="FindWorkers"/>).</summary>
public sealed partial class PdfEngine
{
    /// <summary>Pages <see cref="FindAll"/>'s threads may read ahead of the caller.</summary>
    private const int FindReadAhead = 64;

    /// <summary>
    /// Threads (each with its own MuPDF instance) <see cref="FindAll"/> reads pages on. Two, not one per core: MuPDFCore's
    /// native wrapper guards MuPDF's allocations with process-wide mutexes, so instances in one process wait on each other
    /// (four threads take four times the CPU of one for no gain; four processes run four times as fast). The second
    /// thread overlaps one page's MuPDF work with another's conversion (about 15% on a long text).
    /// </summary>
    internal static int FindThreads { get; set; } = Math.Min(2, Environment.ProcessorCount);

    /// <summary>Test hook: pages whose text was read from MuPDF so far (any instance, any process).</summary>
    internal int Extractions => Volatile.Read(ref _extractions);

    /// <summary>Test hook: this engine's own plan for workers instead of the app's.</summary>
    internal FindWorkerPlan? WorkerPlan { get; set; }

    /// <summary>Test hook: called with each page about to be read for Find; what it throws is that page's failure.</summary>
    internal Action<int>? PageFault { get; set; }

    /// <summary>Test hook: every worker process this engine started so far.</summary>
    internal IReadOnlyList<int> FindWorkerPids
    {
        get
        {
            lock (_workerPids) return [.. _workerPids];
        }
    }

    /// <summary>What the workers of the last search that could have used them did; null if there has been none.</summary>
    public FindWorkerStats? LastFindWorkers { get; private set; }

    private readonly List<int> _workerPids = [];
    private readonly HashSet<FindRun> _finds = [];          // under _readerGate
    private readonly DocumentSource? _source;               // null: only in process

    /// <summary>
    /// Where a worker can find the same document, with no secret passing: a file with a password has none, and
    /// stays in process. Formats other than PDF stay too (they are small, and laid out with the app's settings).
    /// </summary>
    private sealed record DocumentSource(byte[]? Data, string? Path, InputFileTypes Type);

    private static DocumentSource? SourceFor(byte[]? data, string? path, InputFileTypes type, string? password) =>
        type == InputFileTypes.PDF && string.IsNullOrEmpty(password) ? new DocumentSource(data, path, type) : null;

    /// <summary>One page's outcome in <see cref="FindAll"/>: its matches (and its text when there are any), or why it couldn't be read.</summary>
    public sealed record PageMatches(int Page, PageText? Text, IReadOnlyList<(int Start, int End)> Hits, Exception? Error = null);

    /// <summary>
    /// <see cref="PageText.Find"/> on every page, as one search: pages are read on <see cref="FindThreads"/> threads (each
    /// with its own MuPDF instance), or in worker processes once the search's pace says it will take over a second, and
    /// come back in page order as soon as each page and those before it are done, so the first matches show before the
    /// end. A page whose text was read before (by any call) and can't match is not read again, nor one whose whole text
    /// is kept. A page that can't be read comes back with its <see cref="PageMatches.Error"/>. A worker that fails
    /// loses nothing: its pages are read here.
    /// </summary>
    /// <exception cref="OperationCanceledException"><paramref name="cancel"/> fired.</exception>
    /// <exception cref="ObjectDisposedException">The engine was disposed (the document changed) meanwhile.</exception>
    public IEnumerable<PageMatches> FindAll(string query, bool matchCase, bool wholeWord, bool ignoreAccents = false, CancellationToken cancel = default)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_pages.Length == 0) return [];
        return new FindRun(this, query, matchCase, wholeWord, ignoreAccents, cancel).Pages();
    }

    /// <summary>A page's matches from what is already known of it, without reading it; null if it has to be read.</summary>
    private PageMatches? FindKnown(int page, string query, bool matchCase, bool wholeWord, bool ignoreAccents)
    {
        if (Volatile.Read(ref _pageStrings[page]) is { } known && !PageText.Matches(known, query, matchCase, wholeWord, ignoreAccents))
            return new PageMatches(page, null, []);
        var text = Volatile.Read(ref _pageTexts[page]);
        if (text is null && _textGate.TryEnter(2)) // a moment: another page's thread may be passing through
        {
            try
            {
                if (!_disposed && _textCache.TryGetValue(page, out var hit)) text = hit;
            }
            finally
            {
                _textGate.Exit();
            }
        }
        if (text is null) return null;
        var hits = text.Find(query, matchCase, wholeWord, ignoreAccents);
        return new PageMatches(page, hits.Count > 0 ? text : null, hits);
    }

    private PageText ReadPage(ref TextReader? reader, int page)
    {
        PageFault?.Invoke(page);
        reader ??= RentReader();
        lock (reader.Gate)
        {
            ObjectDisposedException.ThrowIf(reader.Disposed, this);
            reader.Loaded.Touch(page);
            return ExtractText(reader.Doc, page);
        }
    }

    private PageMatches FindOn(ref TextReader? reader, int page, string query, bool matchCase, bool wholeWord, bool ignoreAccents)
    {
        if (FindKnown(page, query, matchCase, wholeWord, ignoreAccents) is { } known) return known;
        var text = ReadPage(ref reader, page);
        Remember(page, text);
        var hits = text.Find(query, matchCase, wholeWord, ignoreAccents);
        return new PageMatches(page, hits.Count > 0 ? text : null, hits);
    }

    /// <summary>A page's text for an index worker, read on the document's one instance: no second opening for a file read once from start to end.</summary>
    internal string ReadTextForIndex(int page)
    {
        lock (_gate)
        {
            ObjectDisposedException.ThrowIf(_disposed, this);
            _loaded.Touch(page);
            return ExtractText(_doc, page).Text;
        }
    }

    /// <summary>The worker's side of a search: reads the pages asked for, in order, and answers each one until told there are no more.</summary>
    internal void ServeFind(Stream input, Stream output, FindWorkers.OpenRequest search)
    {
        TextReader? reader = null;
        var keptChars = 0L;
        while (true)
        {
            var count = FindWorkers.ReadInt(input);
            if (count <= 0 || count > MaxWorkerBatch) return;
            for (var n = 0; n < count; n++)
            {
                var page = FindWorkers.ReadInt(input);
                if (page < 0 || page >= _pages.Length) throw new InvalidDataException("No such page.");
                PageText text;
                IReadOnlyList<(int Start, int End)> hits;
                try
                {
                    text = ReadPage(ref reader, page);
                    hits = text.Find(search.Query, search.MatchCase, search.WholeWord, search.IgnoreAccents);
                }
                catch (Exception ex) when (ex is not OutOfMemoryException)
                {
                    FindWorkers.WriteInt(output, page);
                    FindWorkers.WriteInt(output, AnswerFailed); // the parent reads it itself: the same error, or the page
                    output.Flush();
                    continue;
                }
                // The boxes go back when there are hits to show, or while the parent may still keep the page's text whole.
                var whole = hits.Count > 0 || keptChars + text.Text.Length <= search.KeepChars;
                keptChars += text.Text.Length;
                FindWorkers.WriteInt(output, page);
                FindWorkers.WriteInt(output, whole ? AnswerWhole : AnswerString);
                if (whole) text.WriteTo(output);
                else FindWorkers.WriteString(output, text.Text);
                FindWorkers.WriteInt(output, hits.Count);
                foreach (var (start, end) in hits)
                {
                    FindWorkers.WriteInt(output, start);
                    FindWorkers.WriteInt(output, end);
                }
                output.Flush();
            }
        }
    }

    private const int MaxWorkerBatch = 64;
    private const int AnswerFailed = 0, AnswerWhole = 1, AnswerString = 2;

    /// <summary>One search under way: who reads which page, and the pages waiting for the caller.</summary>
    private sealed class FindRun
    {
        private readonly PdfEngine _engine;
        private readonly string _query;
        private readonly bool _matchCase, _wholeWord, _ignoreAccents;
        private readonly CancellationToken _cancel;
        private readonly PageMatches?[] _results;
        private readonly int _count;
        private readonly object _sync = new();
        private readonly Queue<int> _returned = new();       // pages a worker gave back, for this process's threads
        private readonly List<WorkerLink> _links = [];       // under _sync
        private readonly List<Thread> _threads = [];         // under _sync
        private readonly FindWorkerPlan? _plan;
        private readonly long _startedAt = Stopwatch.GetTimestamp();
        private readonly Lazy<SharedBytes?> _shared;
        private int _next, _consumed, _done;
        private int _readAhead = FindReadAhead;
        private int _alive, _connected, _reserved;           // workers not yet ended; connected and asking for pages
        private int _failed, _pagesFromWorkers;
        private bool _planned, _stop, _noWorkers;

        public FindRun(PdfEngine engine, string query, bool matchCase, bool wholeWord, bool ignoreAccents, CancellationToken cancel)
        {
            _engine = engine;
            _query = query;
            _matchCase = matchCase;
            _wholeWord = wholeWord;
            _ignoreAccents = ignoreAccents;
            _cancel = cancel;
            _count = engine._pages.Length;
            _results = new PageMatches?[_count];
            _plan = engine._source is { } source ? engine.WorkerPlan ?? FindWorkers.PlanFor(source.Data?.Length ?? 0) : null;
            _shared = new Lazy<SharedBytes?>(() => engine._source?.Data is { } data ? new SharedBytes(data) : null);
            if (engine._source is null || _plan is null) _planned = true;
        }

        public IEnumerable<PageMatches> Pages()
        {
            lock (_engine._readerGate)
            {
                ObjectDisposedException.ThrowIf(_engine._disposed, _engine);
                _engine._finds.Add(this);
            }
            try
            {
                lock (_sync)
                {
                    if (_plan is { PaysMs: <= 0, MinPages: <= 0 }) StartWorkers(_plan.Workers); // tests: from the start
                    for (var t = 0; t < Math.Min(FindThreads, _count); t++)
                    {
                        var thread = new Thread(Work) { IsBackground = true, Priority = ThreadPriority.Normal, Name = "Inkvolt PDF find" };
                        _threads.Add(thread);
                        thread.Start();
                    }
                }
                var checkedStalls = Stopwatch.GetTimestamp();
                for (var i = 0; i < _count; i++)
                {
                    PageMatches? r;
                    _cancel.ThrowIfCancellationRequested();
                    lock (_sync)
                    {
                        while ((r = _results[i]) is null)
                        {
                            _cancel.ThrowIfCancellationRequested();
                            ObjectDisposedException.ThrowIf(_engine._disposed, _engine);
                            Monitor.Wait(_sync, 50);
                            if (Stopwatch.GetElapsedTime(checkedStalls).TotalSeconds >= 1)
                            {
                                checkedStalls = Stopwatch.GetTimestamp();
                                foreach (var link in _links) link.KillIfStalled(_plan!.StallMs);
                            }
                        }
                        _results[i] = null;
                        _consumed = i + 1;
                        Monitor.PulseAll(_sync);
                    }
                    if (r.Error is ObjectDisposedException) throw new ObjectDisposedException(nameof(PdfEngine), r.Error);
                    yield return r;
                }
            }
            finally
            {
                Finish();
            }
        }

        /// <summary>The search is over, one way or another: nothing of it stays running.</summary>
        private void Finish()
        {
            Thread[] threads;
            lock (_sync)
            {
                _stop = true;
                Monitor.PulseAll(_sync);
                threads = [.. _threads];
            }
            KillWorkers();
            foreach (var t in threads) t.Join();
            lock (_engine._readerGate) _engine._finds.Remove(this);
            if (_shared.IsValueCreated) _shared.Value?.Dispose();
            FindWorkers.Release(_reserved);
            if (_plan is not null)
            {
                long peak;
                int started;
                lock (_sync)
                {
                    peak = _links.Sum(l => l.PeakBytes);
                    started = _links.Count;
                    foreach (var link in _links) link.Dispose();
                }
                _engine.LastFindWorkers = new FindWorkerStats(started, _failed, _pagesFromWorkers, peak);
            }
        }

        /// <summary>Ends the workers now (and no new ones start): the search is over or the engine is going away, and its file with it.</summary>
        public void KillWorkers()
        {
            WorkerLink[] links;
            lock (_sync)
            {
                _noWorkers = true;
                links = [.. _links];
                Monitor.PulseAll(_sync);
            }
            foreach (var link in links) link.Kill();
        }

        /// <summary>This process's threads: all pages until workers connect, then only those a worker gave back.</summary>
        private void Work()
        {
            TextReader? reader = null;
            try
            {
                while (true)
                {
                    int i;
                    lock (_sync)
                    {
                        while (true)
                        {
                            if (_stop) return;
                            if (_returned.TryDequeue(out i)) break;
                            var workersRead = _connected > 0 || _plan is { InProcessWaits: true } && _alive > 0;
                            if (!workersRead && _next < _count && _next < _consumed + _readAhead)
                            {
                                i = _next++;
                                break;
                            }
                            if (_next >= _count && _alive == 0) return;
                            Monitor.Wait(_sync);
                        }
                    }
                    if (_cancel.IsCancellationRequested) return;
                    PageMatches m;
                    try
                    {
                        m = _engine.FindOn(ref reader, i, _query, _matchCase, _wholeWord, _ignoreAccents);
                    }
                    catch (Exception ex)
                    {
                        m = new PageMatches(i, null, [], ex);
                    }
                    lock (_sync)
                    {
                        Put(m);
                        ConsiderWorkers();
                    }
                    if (m.Error is ObjectDisposedException) return;
                }
            }
            finally
            {
                if (reader is not null) _engine.ReturnReader(reader);
            }
        }

        private void Put(PageMatches m)
        {
            _results[m.Page] = m;
            _done++;
            Monitor.PulseAll(_sync);
        }

        /// <summary>
        /// Starts workers if the search's pace says it will go on long enough to pay for them. Asked after every page, so a
        /// document that turns slow further on still gets them. Under _sync.
        /// </summary>
        private void ConsiderWorkers()
        {
            if (_planned || _plan is null || _noWorkers) return;
            var left = _count - _next;
            if (left < _plan.MinPages || left == 0) return;
            var elapsed = Stopwatch.GetElapsedTime(_startedAt).TotalMilliseconds;
            if (elapsed < _plan.ProbeMs) return;
            var estimate = elapsed * left / _done;
            if (estimate < _plan.PaysMs) return;
            StartWorkers(Math.Max(2, (int)Math.Ceiling(_plan.Workers * estimate / _plan.FullCrewMs)));
        }

        private void StartWorkers(int want)
        {
            _planned = true;
            _reserved = FindWorkers.Reserve(Math.Min(want, _plan!.Workers), _plan.Workers);
            _readAhead = _plan.ReadAhead;
            var keep = Math.Max(0, KeptTextChars - Interlocked.Read(ref _engine._keptChars));
            for (var w = 0; w < _reserved; w++)
            {
                var link = new WorkerLink(_engine);
                _links.Add(link);
                _alive++;
                var thread = new Thread(() => RunWorker(link, keep)) { IsBackground = true, Name = "Inkvolt PDF find worker" };
                _threads.Add(thread);
                thread.Start();
            }
            Monitor.PulseAll(_sync);
        }

        /// <summary>One worker from start to end. Whatever goes wrong, the pages it hadn't answered go back to this process's threads.</summary>
        private void RunWorker(WorkerLink link, long keep)
        {
            var pending = new Queue<int>();
            var connected = false;
            try
            {
                var source = _engine._source!;
                var shared = _shared.Value;
                link.Start(_plan!);
                link.Send(new FindWorkers.OpenRequest(source.Path, shared?.Name, shared?.Bytes ?? 0, source.Type, _count, _query, _matchCase, _wholeWord, _ignoreAccents, keep));
                link.AwaitReady();
                lock (_sync)
                {
                    if (_stop || _noWorkers) return;
                    connected = true;
                    _connected++;
                    Monitor.PulseAll(_sync);
                }
                var batch = 1;
                while (Claim(pending, batch))
                {
                    var asked = Stopwatch.GetTimestamp();
                    link.Ask(pending);
                    var pages = pending.Count;
                    while (pending.TryPeek(out var page))
                    {
                        var answer = link.ReadAnswer(page);
                        lock (_sync)
                        {
                            pending.Dequeue();
                            if (answer is null) _returned.Enqueue(page);
                            else
                            {
                                _engine.TakeAnswer(page, answer);
                                _pagesFromWorkers++;
                                Put(answer.Matches);
                            }
                            Monitor.PulseAll(_sync);
                        }
                    }
                    link.Idle();
                    // About a tenth of a second of work at a time, so a slow worker doesn't hold many pages and the pipe isn't asked for each one.
                    var ms = Stopwatch.GetElapsedTime(asked).TotalMilliseconds;
                    if (ms < 50) batch = Math.Min(batch * 2, MaxWorkerBatch);
                    else if (ms > 200 && pages > 1) batch = Math.Max(1, pages / 2);
                }
                link.Finished = true;
            }
            catch (Exception ex) when (ex is not OutOfMemoryException)
            {
                // Couldn't start, connect or answer, was killed, or sent something wrong: the pages are read here, and no one is troubled.
            }
            finally
            {
                link.Kill();
                lock (_sync)
                {
                    foreach (var page in pending) _returned.Enqueue(page);
                    if (connected) _connected--;
                    _alive--;
                    if (!link.Finished && !_stop && !_noWorkers) _failed++;
                    Monitor.PulseAll(_sync);
                }
            }
        }

        /// <summary>The next pages for a worker: those that need reading, within the read-ahead; the rest are answered here. False when there are no more.</summary>
        private bool Claim(Queue<int> into, int size)
        {
            lock (_sync)
            {
                while (true)
                {
                    if (_stop || _noWorkers) return false;
                    while (into.Count < size && _next < _count && _next < _consumed + _readAhead)
                    {
                        var i = _next++;
                        if (_engine.FindKnown(i, _query, _matchCase, _wholeWord, _ignoreAccents) is { } known) Put(known);
                        else into.Enqueue(i);
                    }
                    if (into.Count > 0) return true;
                    if (_next >= _count) return false;
                    Monitor.Wait(_sync);
                }
            }
        }
    }

    /// <summary>A worker's answer about one page.</summary>
    private sealed record WorkerAnswer(PageMatches Matches, string Text, PageText? Whole);

    /// <summary>What a worker read becomes what this process would have remembered. Text and hits were checked as they arrived.</summary>
    private void TakeAnswer(int page, WorkerAnswer answer)
    {
        Interlocked.Increment(ref _extractions);
        if (answer.Whole is { } whole) Remember(page, whole);
        else RememberString(page, answer.Text);
    }

    /// <summary>A copy of the document's bytes in memory the workers read from, all from one place; no file behind it.</summary>
    private sealed class SharedBytes : IDisposable
    {
        private readonly MemoryMappedFile _file;
        public string Name { get; } = FindWorkers.NewPipeName();
        public long Bytes { get; }

        public SharedBytes(byte[] data)
        {
            if (!OperatingSystem.IsWindows()) throw new PlatformNotSupportedException();
            Bytes = data.Length;
            _file = MemoryMappedFile.CreateNew(Name, data.Length, MemoryMappedFileAccess.ReadWrite);
            using var view = _file.CreateViewStream(0, data.Length, MemoryMappedFileAccess.Write);
            view.Write(data);
        }

        public void Dispose() => _file.Dispose();
    }

    /// <summary>The parent's end of one worker: its process and its pipe. A worker reads an untrusted file, so what it says is checked.</summary>
    private sealed class WorkerLink(PdfEngine engine) : IDisposable
    {
        private readonly CancellationTokenSource _ended = new();
        private readonly Lock _gate = new();
        private Process? _process;
        private NamedPipeServerStream? _pipe;
        private bool _disposed;         // under _gate
        private long _waitingSince;     // timestamp of the question or last answer; 0 when none is awaited

        public long PeakBytes { get; private set; }
        public bool Finished { get; set; }

        public void Start(FindWorkerPlan plan)
        {
            var name = FindWorkers.NewPipeName();
            _pipe = FindWorkers.NewPipe(name);
            var process = FindWorkers.StartWithoutHandles(plan.Exe, [.. plan.Args, FindWorkers.Switch, name], Path.GetDirectoryName(plan.Exe) ?? "");
            lock (_gate)
            {
                _process = process;
                if (_ended.IsCancellationRequested) throw new OperationCanceledException(); // the caller's Kill ends it
            }
            lock (engine._workerPids) engine._workerPids.Add(process.Id);
            FindWorkers.Job.Add(process);
            FindWorkers.AwaitConnection(_pipe, process, plan.ConnectMs, _ended.Token);
        }

        public void Send(FindWorkers.OpenRequest request)
        {
            request.Write(_pipe!);
            _pipe!.Flush();
            Volatile.Write(ref _waitingSince, Stopwatch.GetTimestamp());
        }

        public void AwaitReady()
        {
            if (FindWorkers.ReadInt(_pipe!) != FindWorkers.ReadyWord) throw new InvalidDataException("Not a worker's greeting.");
            Volatile.Write(ref _waitingSince, 0);
        }

        public void Ask(IReadOnlyCollection<int> pages)
        {
            using var message = new MemoryStream((pages.Count + 1) * 4);
            FindWorkers.WriteInt(message, pages.Count);
            foreach (var page in pages) FindWorkers.WriteInt(message, page);
            Volatile.Write(ref _waitingSince, Stopwatch.GetTimestamp());
            _pipe!.Write(message.GetBuffer().AsSpan(0, (int)message.Length));
            _pipe.Flush();
        }

        /// <summary>The answer about <paramref name="page"/>; null if the worker couldn't read it (this process tries). Throws on anything else.</summary>
        public WorkerAnswer? ReadAnswer(int page)
        {
            var pipe = _pipe!;
            if (FindWorkers.ReadInt(pipe) != page) throw new InvalidDataException("An answer about another page.");
            var kind = FindWorkers.ReadInt(pipe);
            if (kind == AnswerFailed) return Answered(null);
            if (kind is not (AnswerWhole or AnswerString)) throw new InvalidDataException("Not an answer.");
            var whole = kind == AnswerWhole ? PageText.ReadFrom(pipe) : null;
            var text = whole?.Text ?? FindWorkers.ReadString(pipe, PageText.MaxWireChars);
            var count = FindWorkers.ReadInt(pipe);
            if (count < 0 || count > text.Length || (count > 0 && whole is null)) throw new InvalidDataException("Hits that can't be.");
            var hits = new (int Start, int End)[count];
            for (var i = 0; i < count; i++)
            {
                var start = FindWorkers.ReadInt(pipe);
                var end = FindWorkers.ReadInt(pipe);
                if (start < 0 || end < start || end > text.Length) throw new InvalidDataException("A hit outside the page.");
                hits[i] = (start, end);
            }
            return Answered(new WorkerAnswer(new PageMatches(page, count > 0 ? whole : null, hits), text, whole));
        }

        private WorkerAnswer? Answered(WorkerAnswer? answer)
        {
            Volatile.Write(ref _waitingSince, Stopwatch.GetTimestamp());
            return answer;
        }

        /// <summary>Nothing is asked of it for now.</summary>
        public void Idle() => Volatile.Write(ref _waitingSince, 0);

        public void KillIfStalled(int stallMs)
        {
            var since = Volatile.Read(ref _waitingSince);
            if (since != 0 && Stopwatch.GetElapsedTime(since).TotalMilliseconds > stallMs) Kill();
        }

        /// <summary>Ends the process and waits for it, so its hold on the document's file is gone too. Any number of times.</summary>
        public void Kill()
        {
            lock (_gate)
            {
                if (_disposed) return;
                _ended.Cancel();
                if (_process is not { } process) return;
                try
                {
                    if (!process.HasExited)
                    {
                        process.Refresh();
                        PeakBytes = Math.Max(PeakBytes, process.PeakWorkingSet64);
                        process.Kill();
                    }
                    process.WaitForExit(5000);
                }
                catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or NotSupportedException)
                {
                    // Already gone.
                }
            }
        }

        public void Dispose()
        {
            lock (_gate)
            {
                _disposed = true;
                _pipe?.Dispose();
                _process?.Dispose();
                _ended.Dispose();
            }
        }
    }
}
