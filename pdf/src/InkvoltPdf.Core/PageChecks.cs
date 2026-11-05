using System.ComponentModel;
using System.Diagnostics;
using System.IO.Pipes;
using MuPDFCore;

namespace InkvoltPdf.Core;

/// <summary>
/// A page this process won't run through MuPDF: drawing it in its page check took longer than the limit
/// (<see cref="PageChecks"/>), MuPDF gave up on it there, or the check process ended on it twice. The rest of the
/// document can still be used.
/// </summary>
public sealed class PageRefusedException : InvalidOperationException
{
    internal PageRefusedException(int page, PageVerdict verdict)
        : base(Loc.Format(verdict switch
        {
            PageVerdict.TooSlow => PdfStrings.Doc_PageTooSlow,
            PageVerdict.Failed => PdfStrings.Doc_PageUnreadable,
            _ => PdfStrings.Doc_PageCheckFailed,
        }, page + 1))
    {
        Page = page;
        TooSlow = verdict == PageVerdict.TooSlow;
    }

    public int Page { get; }

    /// <summary>True: it took too long; false: MuPDF gave up on it in the check, or the check process ended on it (a crash, or more memory than it may take).</summary>
    public bool TooSlow { get; }

    /// <summary>Whether a verdict refuses the page.</summary>
    internal static bool Refuses(PageVerdict verdict) => verdict is PageVerdict.TooSlow or PageVerdict.Crashed or PageVerdict.Failed;
}

/// <summary>What a page check found.</summary>
internal enum PageVerdict : byte
{
    /// <summary>Not checked yet.</summary>
    Unknown,

    /// <summary>Drawn within the limit: this process may run it.</summary>
    Fine,

    /// <summary>Still drawing when the limit passed: the check process was ended and the page is refused.</summary>
    TooSlow,

    /// <summary>The check process ended on it, on a second try too: refused.</summary>
    Crashed,

    /// <summary>No check could be made (no check process starts, the document doesn't open in one, or it was closed): run here as before.</summary>
    Unchecked,

    /// <summary>MuPDF gave up on it in the check process (a damaged page, or one that needs more memory than the process may take): refused.</summary>
    Failed,
}

/// <summary>
/// Page checks bound MuPDF's own work on a page by time. MuPDF stops a render when its cookie says so, but the content of
/// a page is read (and its streams inflated) while the display list is made, and MuPDFCore's native wrapper has no entry
/// point that takes a cookie there (its GetDisplayList passes none, and the wrapper exports nothing of MuPDF's own); nor
/// does MuPDF look at the cookie while it inflates one picture. A Flate bomb (7 KB inflating twice to 4 GB) took 116 s
/// of one core to draw a page, memory flat. So before this process first runs a page's content, a check process (the
/// app started again with <see cref="Switch"/>) draws it small, every picture decoded; one still drawing after
/// <see cref="Limit"/> is ended and the page refused (<see cref="PageRefusedException"/>), the rest of the document
/// unaffected. Each engine asks once a page; the processes are shared by every engine in this process.
/// </summary>
public static class PageChecks
{
    /// <summary>The command-line switch: <c>--page-check InkvoltPdf.find.&lt;32 hex digits&gt;</c>, nothing else.</summary>
    public const string Switch = "--page-check";

    /// <summary>
    /// How long a page may take to draw in its check. The heaviest real page measured, a sheet of the bench's drawing set
    /// (72,000 paths), takes about 0.3 s there (see pdf/ROADMAP.md 3.6); this is some 30 times that, for a far denser
    /// real drawing on a PC as loaded as the test runs make it, while a page that hostile content holds up is given up
    /// on in seconds instead of minutes.
    /// </summary>
    public static readonly TimeSpan Limit = TimeSpan.FromSeconds(10);

    private static PageCheckPlan? _plan;

    /// <summary>Checks pages from now on, in processes started as <paramref name="exe"/> (with these arguments before the switch).</summary>
    public static void Use(string exe, params string[] args) => _plan = new PageCheckPlan(exe, args);

    /// <summary>The app's plan; null while <see cref="Use"/> hasn't been called (a worker process, a test): pages run unchecked.</summary>
    internal static PageCheckPlan? Plan => _plan;

    public static bool IsCommand(string[] args) => args.Length > 0 && args[0] == Switch;

    /// <summary>
    /// Whether the first page of <paramref name="pdf"/>, one this process made around a document's picture, draws within
    /// the limit in a check process: false when it was refused; true when no check can be had.
    /// </summary>
    internal static bool DrawsInTime(byte[] pdf, PageCheckPlan? plan = null)
    {
        if ((plan ?? _plan) is not { } p) return true;
        var doc = new CheckedDocument(pdf, null, InputFileTypes.PDF, 1);
        try
        {
            var request = p.Ask(doc, 0);
            request.Done.Wait();
            return !PageRefusedException.Refuses(request.Result);
        }
        finally
        {
            p.Forget(doc);
        }
    }

    /// <summary>Test hook: called in the check process before each check (the bench tool sets it, PageCheckTests).</summary>
    internal static Action? TestCheckFault { get; set; }

    /// <summary>The check process's whole life, from the command line to its exit code.</summary>
    public static int Run(string[] args) => Run(args, 10_000);

    internal static int Run(string[] args, int connectMs)
    {
        if (args.Length != 2 || args[0] != Switch || !FindWorkers.IsPipeName(args[1])) return FindWorkers.BadArguments;
        try
        {
            using var pipe = new NamedPipeClientStream(".", args[1], PipeDirection.InOut, PipeOptions.CurrentUserOnly);
            pipe.Connect(connectMs);
            FindWorkers.BecomeWorker(pipe);
            Serve(pipe);
            return 0;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return FindWorkers.Failed; // the parent sees the pipe close
        }
    }

    internal const int AskOpen = 1, AskCheck = 2, AskClose = 3;
    internal const int Opened = 0x4B434850; // "PHCK": the document opened as the parent's did
    internal const int NotOpened = 0, Drawn = 1, Failed = 2;
    internal const int Closed = 0x4C4F4350; // "PCOL": the document let go of

    /// <summary>A check draws the page with its longer side this many pixels: every picture on it is still decoded (MuPDF decodes even one under a pixel).</summary>
    private const double CheckPixels = 64;

    /// <summary>Opens what the parent says, draws each page asked for, and answers; ends when the pipe closes or says something else.</summary>
    private static void Serve(Stream pipe)
    {
        PdfEngine? engine = null;
        IDisposable? view = null;
        void Close()
        {
            engine?.Dispose();
            view?.Dispose();
            engine = null;
            view = null;
        }
        try
        {
            while (true)
            {
                var ask = FindWorkers.ReadInt(pipe);
                switch (ask)
                {
                    case AskOpen:
                        Close();
                        var open = OpenRequest.Read(pipe);
                        var answer = NotOpened;
                        try
                        {
                            engine = FindWorkers.OpenShared(open.Path, open.SectionName, open.SectionBytes, open.Type, out view);
                            if (engine.PageCount == open.Pages) answer = Opened;
                            else Close();
                        }
                        catch (Exception ex) when (ex is not OutOfMemoryException)
                        {
                            Close();
                        }
                        FindWorkers.WriteInt(pipe, answer);
                        pipe.Flush();
                        break;
                    case AskCheck:
                        var page = FindWorkers.ReadInt(pipe);
                        if (engine is null || page < 0 || page >= engine.PageCount) return;
                        var drawn = Drawn;
                        try
                        {
                            TestCheckFault?.Invoke();
                            var g = engine.GetPage(page);
                            var longer = Math.Max(g.Width, g.Height);
                            engine.Render(page, double.IsFinite(longer) && longer > CheckPixels ? CheckPixels / longer : 1);
                        }
                        catch (Exception ex) when (ex is not OutOfMemoryException)
                        {
                            drawn = Failed;
                        }
                        FindWorkers.WriteInt(pipe, page);
                        FindWorkers.WriteInt(pipe, drawn);
                        pipe.Flush();
                        break;
                    case AskClose:
                        Close();
                        FindWorkers.WriteInt(pipe, Closed);
                        pipe.Flush();
                        break;
                    default:
                        return;
                }
            }
        }
        catch (EndOfStreamException)
        {
            // The parent let go.
        }
        finally
        {
            Close();
        }
    }

    /// <summary>The document a check process opens: its file, or a copy of its bytes in shared memory.</summary>
    internal sealed record OpenRequest(string? Path, string? SectionName, long SectionBytes, InputFileTypes Type, int Pages)
    {
        public void Write(Stream s)
        {
            FindWorkers.WriteString(s, Path ?? "");
            FindWorkers.WriteString(s, SectionName ?? "");
            FindWorkers.WriteLong(s, SectionBytes);
            FindWorkers.WriteInt(s, (int)Type);
            FindWorkers.WriteInt(s, Pages);
        }

        public static OpenRequest Read(Stream s)
        {
            var path = FindWorkers.ReadString(s, 32_768);
            var section = FindWorkers.ReadString(s, 256);
            var bytes = FindWorkers.ReadLong(s);
            var type = (InputFileTypes)FindWorkers.ReadInt(s);
            var pages = FindWorkers.ReadInt(s);
            if (path.Length == 0 == (section.Length == 0)) throw new InvalidDataException("One document, by path or in shared memory.");
            if (section.Length > 0 && (!FindWorkers.IsPipeName(section) || bytes <= 0)) throw new InvalidDataException("Not a section of ours.");
            if (type != InputFileTypes.PDF || pages <= 0) throw new InvalidDataException("Not a PDF.");
            return new OpenRequest(path.Length > 0 ? path : null, section.Length > 0 ? section : null, bytes, type, pages);
        }
    }
}

/// <summary>A document as page checks know it: where a check process finds it. Closed once its engine is disposed.</summary>
internal sealed class CheckedDocument(byte[]? data, string? path, InputFileTypes type, int pages)
{
    public byte[]? Data { get; } = data;
    public string? Path { get; } = path;
    public InputFileTypes Type { get; } = type;
    public int Pages { get; } = pages;

    /// <summary>Set under the plan's lock.</summary>
    public bool Closed { get; set; }

    /// <summary>A check process couldn't open it: its pages run unchecked (set under the plan's lock).</summary>
    public bool Unopenable { get; set; }
}

/// <summary>One page asked about. Its waiters are counted by the engine that asked, under the engine's lock.</summary>
internal sealed class CheckRequest(CheckedDocument doc, int page)
{
    private readonly TaskCompletionSource<PageVerdict> _done = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public CheckedDocument Doc { get; } = doc;
    public int Page { get; } = page;
    public Task<PageVerdict> Done => _done.Task;

    /// <summary>The verdict, once <see cref="Done"/> has completed.</summary>
    public PageVerdict Result => _done.Task.Result;
    public int Waiters { get; set; }

    /// <summary>Asked ahead, no one waiting for it yet: checked after the pages someone waits for.</summary>
    public bool Speculative { get; set; }

    /// <summary>A check process has it (under the plan's lock).</summary>
    public bool Started { get; set; }

    public void Complete(PageVerdict verdict) => _done.TrySetResult(verdict);
}

/// <summary>
/// The check processes of one program to start, shared by every engine that uses it: at most <see cref="Workers"/>, each
/// with a thread here that sends it one page at a time, ends it past the limit, and lets it go after <see cref="Idle"/>.
/// </summary>
internal sealed class PageCheckPlan(string exe, IReadOnlyList<string> args) : IDisposable
{
    public string Exe { get; } = exe;
    public IReadOnlyList<string> Args { get; } = args;

    /// <summary>How long one page's check may take.</summary>
    public TimeSpan Limit { get; init; } = PageChecks.Limit;

    /// <summary>How long a check process may take to open a document (MuPDF reading its cross-reference table; the app has opened it already).</summary>
    public TimeSpan OpenLimit { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>How long a check process has to start and connect.</summary>
    public int ConnectMs { get; init; } = 15_000;

    /// <summary>
    /// Check processes at once: one for what is on screen and one for the background (text layers, thumbnails, Find)
    /// in the usual case; each takes about 50 MB.
    /// </summary>
    public int Workers { get; init; } = 2;

    /// <summary>A check process with nothing to do for this long ends (the next page starts one again).</summary>
    public TimeSpan Idle { get; init; } = TimeSpan.FromMinutes(2);

    /// <summary>After this many check processes in a row fail to start, pages run unchecked: there is no check to be had.</summary>
    private const int MaxStartFailures = 3;

    private readonly object _gate = new();
    private readonly LinkedList<CheckRequest> _queue = []; // under _gate
    private readonly List<Link> _links = [];               // under _gate
    private readonly List<int> _pids = [];                  // under _gate
    private int _startFailures;                             // under _gate
    private volatile bool _disposed;                        // set under _gate

    /// <summary>Test hook: every check process started so far.</summary>
    internal IReadOnlyList<int> Pids
    {
        get
        {
            lock (_gate) return [.. _pids];
        }
    }

    /// <summary>Queues a check of <paramref name="page"/>; the request completes when it is decided.</summary>
    public CheckRequest Ask(CheckedDocument doc, int page, bool speculative = false)
    {
        var request = new CheckRequest(doc, page) { Speculative = speculative };
        lock (_gate)
        {
            if (_disposed || doc.Closed || doc.Unopenable || _startFailures >= MaxStartFailures)
            {
                request.Complete(PageVerdict.Unchecked);
                return request;
            }
            _queue.AddLast(request);
            var idle = _links.Count(l => l.Current is null);
            if (idle < _queue.Count && _links.Count < Workers)
            {
                var link = new Link(this);
                _links.Add(link);
                new Thread(() => Serve(link)) { IsBackground = true, Name = "Inkvolt PDF page check" }.Start();
            }
            Monitor.PulseAll(_gate);
        }
        return request;
    }

    /// <summary>Takes a request no one waits for any more off the queue; false if a check process has it already (its verdict is kept).</summary>
    public bool Withdraw(CheckRequest request)
    {
        lock (_gate)
        {
            if (request.Started || request.Done.IsCompleted) return false;
            _queue.Remove(request);
            request.Complete(PageVerdict.Unchecked);
            return true;
        }
    }

    /// <summary>
    /// The engine of <paramref name="doc"/> is gone: its queued checks end, and for a file opened in place, a process
    /// checking one of its pages is ended and an idle one that has it open lets it go (the file is held until then).
    /// </summary>
    public void Forget(CheckedDocument doc)
    {
        Link[] busy;
        lock (_gate)
        {
            doc.Closed = true;
            for (var node = _queue.First; node is not null;)
            {
                var next = node.Next;
                if (node.Value.Doc == doc)
                {
                    _queue.Remove(node);
                    node.Value.Complete(PageVerdict.Unchecked);
                }
                node = next;
            }
            Monitor.PulseAll(_gate);
        }
        // Bytes in memory: a check under way ends within the limit, and its process goes on (an edit makes a new engine
        // and asks again at once). A file opened in place stays held until the process lets go: whoever closed the
        // document may save over it next.
        if (doc.Path is null) return;
        lock (_gate) busy = [.. _links.Where(l => l.Current?.Doc == doc)];
        foreach (var link in busy) link.Kill();
        lock (_gate)
        {
            var since = Stopwatch.GetTimestamp();
            while (_links.Any(l => l.Open == doc))
            {
                var left = CloseLimit - Stopwatch.GetElapsedTime(since);
                if (left <= TimeSpan.Zero) break;
                Monitor.Wait(_gate, left);
            }
            busy = [.. _links.Where(l => l.Open == doc)];
        }
        foreach (var link in busy) link.Kill();
    }

    /// <summary>How long a process has to let go of a document (closing it in MuPDF: milliseconds).</summary>
    private static readonly TimeSpan CloseLimit = TimeSpan.FromSeconds(5);

    public void Dispose()
    {
        Link[] links;
        lock (_gate)
        {
            _disposed = true;
            foreach (var r in _queue) r.Complete(PageVerdict.Unchecked);
            _queue.Clear();
            links = [.. _links];
            Monitor.PulseAll(_gate);
        }
        foreach (var link in links) link.Kill();
    }

    /// <summary>One check process's thread: takes the next page, checks it, and so on until it has been idle for <see cref="Idle"/>.</summary>
    private void Serve(Link link)
    {
        try
        {
            while (true)
            {
                CheckRequest? request = null;
                var close = false;
                lock (_gate)
                {
                    var since = Stopwatch.GetTimestamp();
                    while (true)
                    {
                        if (_disposed) return;
                        if (link.Open is { Closed: true })
                        {
                            close = true;
                            break;
                        }
                        if (Next(link.Open) is { } node)
                        {
                            request = node.Value;
                            _queue.Remove(node);
                            request.Started = true;
                            link.Current = request;
                            break;
                        }
                        var left = Idle - Stopwatch.GetElapsedTime(since);
                        if (left <= TimeSpan.Zero || !Monitor.Wait(_gate, left) && _queue.Count == 0) return;
                    }
                }
                if (close)
                {
                    link.Close();
                    lock (_gate) Monitor.PulseAll(_gate);
                    continue;
                }
                var verdict = PageVerdict.Unchecked;
                try
                {
                    verdict = link.Check(request!);
                }
                finally
                {
                    lock (_gate)
                    {
                        link.Current = null;
                        if (verdict == PageVerdict.Unchecked && link.StartFailed) _startFailures++;
                        else if (link.Started) _startFailures = 0;
                    }
                    request!.Complete(verdict);
                }
            }
        }
        finally
        {
            link.Kill();
            lock (_gate)
            {
                _links.Remove(link);
                // Requests this thread would have taken: another thread, or a new one.
                if (_queue.Count > 0 && !_disposed && _links.Count < Workers)
                {
                    var next = new Link(this);
                    _links.Add(next);
                    new Thread(() => Serve(next)) { IsBackground = true, Name = "Inkvolt PDF page check" }.Start();
                }
                Monitor.PulseAll(_gate);
            }
        }
    }

    /// <summary>
    /// The request to check next: one someone waits for before one asked ahead, and of those, one of the document the
    /// process has open (no opening another for each page), else the oldest. Under _gate.
    /// </summary>
    private LinkedListNode<CheckRequest>? Next(CheckedDocument? open)
    {
        LinkedListNode<CheckRequest>? best = null;
        var bestRank = int.MaxValue;
        for (var n = _queue.First; n is not null; n = n.Next)
        {
            var rank = (n.Value.Speculative ? 2 : 0) + (n.Value.Doc == open ? 0 : 1);
            if (rank >= bestRank) continue;
            best = n;
            bestRank = rank;
            if (rank == 0) break;
        }
        return best;
    }

    /// <summary>This process's end of one check process. A check process reads an untrusted file, so what it says is checked.</summary>
    private sealed class Link(PageCheckPlan plan)
    {
        private readonly Lock _processGate = new();
        private Process? _process;              // under _processGate
        private NamedPipeServerStream? _pipe;
        private bool _killed;                   // under _processGate

        /// <summary>The request it is checking (under the plan's lock).</summary>
        public CheckRequest? Current { get; set; }

        /// <summary>The document the process has open; null if none.</summary>
        public CheckedDocument? Open { get; private set; }

        /// <summary>Its last start failed (the program isn't there, or didn't connect).</summary>
        public bool StartFailed { get; private set; }

        /// <summary>A process was started and connected for it at least once.</summary>
        public bool Started { get; private set; }

        /// <summary>The page drawn in the process, within the limit; a process that ended on it is started again once.</summary>
        public PageVerdict Check(CheckRequest request)
        {
            var doc = request.Doc;
            for (var attempt = 0; ; attempt++)
            {
                if (doc.Closed || plan._disposed) return PageVerdict.Unchecked;
                if (!EnsureStarted()) return PageVerdict.Unchecked;
                StartFailed = false;
                try
                {
                    if (Open != doc && !OpenDocument(doc)) return PageVerdict.Unchecked;
                    FindWorkers.WriteInt(_pipe!, PageChecks.AskCheck);
                    FindWorkers.WriteInt(_pipe!, request.Page);
                    _pipe!.Flush();
                    var page = ReadInt(plan.Limit);
                    var answer = ReadInt(plan.Limit);
                    if (page != request.Page || answer is not (PageChecks.Drawn or PageChecks.Failed)) throw new InvalidDataException("Not an answer.");
                    // MuPDF giving up there (a damaged page, an allocation past the process's memory limit) says nothing
                    // of what the page costs here, where nothing limits it: refused, not tried again.
                    return answer == PageChecks.Drawn ? PageVerdict.Fine : PageVerdict.Failed;
                }
                catch (TimeoutException)
                {
                    Kill();
                    return doc.Closed || plan._disposed ? PageVerdict.Unchecked : PageVerdict.TooSlow;
                }
                catch (Exception ex) when (ex is IOException or InvalidDataException or ObjectDisposedException or AggregateException)
                {
                    // The process ended on the page (a crash, its memory limit) or said something wrong: once more on a new one.
                    Kill();
                    if (doc.Closed || plan._disposed) return PageVerdict.Unchecked;
                    if (attempt > 0) return PageVerdict.Crashed;
                }
            }
        }

        /// <summary>Lets go of the document (the file it holds open in place, the shared bytes).</summary>
        public void Close()
        {
            try
            {
                FindWorkers.WriteInt(_pipe!, PageChecks.AskClose);
                _pipe!.Flush();
                if (ReadInt(CloseLimit) != PageChecks.Closed) throw new InvalidDataException("Not an answer.");
            }
            catch (Exception ex) when (ex is IOException or ObjectDisposedException or InvalidDataException or TimeoutException or AggregateException)
            {
                Kill();
            }
            Open = null;
        }

        private bool EnsureStarted()
        {
            lock (_processGate)
            {
                if (_process is { } p && !_killed) return true;
                _process?.Dispose();
                _pipe?.Dispose();
                _process = null;
                _pipe = null;
                _killed = false;
                Open = null;
            }
            try
            {
                var name = FindWorkers.NewPipeName();
                var pipe = FindWorkers.NewPipe(name);
                Process process;
                try
                {
                    process = FindWorkers.StartWithoutHandles(plan.Exe, [.. plan.Args, PageChecks.Switch, name], System.IO.Path.GetDirectoryName(plan.Exe) ?? "");
                }
                catch
                {
                    pipe.Dispose();
                    throw;
                }
                lock (_processGate)
                {
                    _process = process;
                    _pipe = pipe;
                }
                lock (plan._gate) plan._pids.Add(process.Id);
                // It reads untrusted content: a page made to take all the memory stops at the job's limit, not the PC's.
                FindWorkers.Job.AddLimited(process);
                FindWorkers.AwaitConnection(pipe, process, plan.ConnectMs, CancellationToken.None);
                Started = true;
                return true;
            }
            catch (Exception ex) when (ex is Win32Exception or InvalidOperationException or IOException or UnauthorizedAccessException)
            {
                // The program isn't there or didn't connect: no check to be had.
                StartFailed = true;
                Kill();
                return false;
            }
        }

        private bool OpenDocument(CheckedDocument doc)
        {
            Open = null;
            PdfEngine.SharedBytes? shared = null;
            try
            {
                if (doc.Data is { } data) shared = new PdfEngine.SharedBytes(data);
                FindWorkers.WriteInt(_pipe!, PageChecks.AskOpen);
                new PageChecks.OpenRequest(doc.Data is null ? doc.Path : null, shared?.Name, shared?.Bytes ?? 0, doc.Type, doc.Pages).Write(_pipe!);
                _pipe!.Flush();
                int answer;
                try
                {
                    answer = ReadInt(plan.OpenLimit);
                }
                catch (TimeoutException)
                {
                    Kill();
                    answer = PageChecks.NotOpened;
                }
                if (answer != PageChecks.Opened)
                {
                    lock (plan._gate) doc.Unopenable = true;
                    return false;
                }
                Open = doc;
                return true;
            }
            finally
            {
                shared?.Dispose(); // the process holds its own view of the section from here on
            }
        }

        /// <summary>The next int from the process, within <paramref name="limit"/>.</summary>
        /// <exception cref="TimeoutException">Nothing came in time.</exception>
        private int ReadInt(TimeSpan limit)
        {
            var buffer = new byte[4];
            var read = _pipe!.ReadExactlyAsync(buffer).AsTask();
            if (!read.Wait(limit))
            {
                _ = read.ContinueWith(t => t.Exception, TaskContinuationOptions.OnlyOnFaulted); // observed, when the end of the process ends it
                throw new TimeoutException();
            }
            return System.Buffers.Binary.BinaryPrimitives.ReadInt32LittleEndian(buffer);
        }

        /// <summary>Ends the process and waits for it, so its hold on the document's file is gone too. Any number of times.</summary>
        public void Kill()
        {
            lock (_processGate)
            {
                if (_killed) return;
                _killed = true;
                Open = null;
                if (_process is not { } process) return;
                try
                {
                    if (!process.HasExited) process.Kill();
                    process.WaitForExit(5000);
                }
                catch (Exception ex) when (ex is InvalidOperationException or Win32Exception or NotSupportedException)
                {
                    // Already gone.
                }
                _pipe?.Dispose();
            }
        }
    }
}
