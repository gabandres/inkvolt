using System.Net;
using System.Threading.Channels;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Core.Sharing;

/// <summary>One HTTP request to the shared scanner, as the server read it (its size already bounded there).</summary>
/// <param name="Path">The request's path, without the query.</param>
/// <param name="Peer">Who asked: kept in memory with the jobs it starts, never logged.</param>
/// <param name="Authority">The request's Host header (for the job's absolute address); null when it hasn't one or it isn't a plain host and port.</param>
public sealed record ShareRequest(string Method, string Path, byte[] Body, IPAddress Peer, string? Authority = null);

/// <summary>The answer: status, body and the headers eSCL uses.</summary>
public sealed record ShareReply(int Status, string? ContentType = null, byte[]? Body = null, string? Location = null, int? RetryAfterSeconds = null)
{
    public static ShareReply Empty(int status, int? retryAfter = null) => new(status, RetryAfterSeconds: retryAfter);
}

/// <summary>How much one shared scanner takes on (roadmap 3.1: bounded counts, jobs that expire). Tests shorten the times.</summary>
public sealed record ShareLimits
{
    /// <summary>Jobs waiting behind the one scanning; one more gets 503 (try later).</summary>
    public int MaxQueued { get; init; } = 2;

    /// <summary>Jobs kept at all (finished ones are forgotten first).</summary>
    public int MaxJobs { get; init; } = 16;

    /// <summary>Jobs one device may have waiting or scanning.</summary>
    public int MaxJobsPerPeer { get; init; } = 2;

    /// <summary>A job nobody asks about for this long is cancelled (the scan stops, its pages are dropped).</summary>
    public TimeSpan IdleLimit { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>A job is cancelled after this long whatever happens.</summary>
    public TimeSpan MaxJobLife { get; init; } = TimeSpan.FromMinutes(30);

    /// <summary>A finished job is listed this long, then forgotten.</summary>
    public TimeSpan KeepFinished { get; init; } = TimeSpan.FromMinutes(5);

    /// <summary>How long NextDocument waits for a page before answering 503 (the client asks again).</summary>
    public TimeSpan LongPoll { get; init; } = TimeSpan.FromSeconds(90);

    /// <summary>Pages scanned ahead of the client's reading (each held in memory); the scanner waits past that.</summary>
    public int PageBuffer { get; init; } = 2;

    /// <summary>How long ScannerStatus waits for the scanner's feeder state.</summary>
    public TimeSpan StatusTimeout { get; init; } = TimeSpan.FromSeconds(3);
}

/// <summary>
/// A scanner of this PC as an eSCL server (roadmap 3.1): the documents and jobs a client (an iPhone's scan app, a Mac's Image Capture,
/// sane-airscan, another Inkvolt Print) asks for, without the HTTP server around it (the app's is Kestrel, over HTTPS). Every
/// request comes from a device on the network and is read as hostile (<see cref="ShareXml.ReadSettings"/>); nothing in a request
/// names a file, a path on this PC or another scanner. One scan at a time, a few waiting (<see cref="ShareLimits"/>), each job
/// reachable only by the device that started it, scanned pages handed out as JPEG (or a PDF of each) exactly as the scanner gave
/// them. Jobs nobody reads expire. <see cref="Dispose"/> cancels every job at once.
/// </summary>
public sealed class SharedScanner : IDisposable
{
    public const string Root = "/eSCL/";
    private const string Xml = "text/xml";

    private readonly IScanner _scanner;
    private readonly ScannerCapabilities _caps;
    private readonly ShareIdentity _identity;
    private readonly ShareLimits _limits;
    private readonly TimeProvider _time;
    private readonly Func<bool> _busyElsewhere;
    private readonly Action<string> _log;
    private readonly byte[] _capabilities;
    private readonly SemaphoreSlim _scanning = new(1, 1);
    private readonly Lock _gate = new();
    private readonly List<Job> _jobs = [];
    private readonly CancellationTokenSource _closed = new();
    private readonly ITimer _sweep;
    private (DateTimeOffset At, string? Adf)? _status;
    private bool _disposed;

    /// <param name="busyElsewhere">True while this app scans with the scanner itself (a job from here then waits: 503).</param>
    /// <param name="log">Told when a job starts and how it ends: no address or other detail of the device that asked.</param>
    public SharedScanner(IScanner scanner, ScannerCapabilities caps, ShareIdentity identity, ShareLimits? limits = null, TimeProvider? time = null,
        Func<bool>? busyElsewhere = null, Action<string>? log = null)
    {
        _scanner = scanner;
        _caps = caps;
        _identity = identity;
        _limits = limits ?? new ShareLimits();
        _time = time ?? TimeProvider.System;
        _busyElsewhere = busyElsewhere ?? (() => false);
        _log = log ?? (_ => { });
        _capabilities = ShareXml.Capabilities(caps, identity);
        _sweep = _time.CreateTimer(_ => Sweep(), null, TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(5));
    }

    public ShareIdentity Identity => _identity;

    /// <summary>Jobs waiting or scanning now.</summary>
    public int ActiveJobs
    {
        get { lock (_gate) return _jobs.Count(j => j.IsActive); }
    }

    /// <summary>Jobs kept now (active and recently finished).</summary>
    public int KeptJobs
    {
        get { lock (_gate) return _jobs.Count; }
    }

    public async Task<ShareReply> HandleAsync(ShareRequest request, CancellationToken ct)
    {
        if (_disposed) return ShareReply.Empty(503);
        Sweep();
        if (!request.Path.StartsWith(Root, StringComparison.Ordinal)) return ShareReply.Empty(404);
        var parts = request.Path[Root.Length..].TrimEnd('/').Split('/');
        var method = request.Method;
        switch (parts)
        {
            case ["ScannerCapabilities"]:
                return method == "GET" ? new ShareReply(200, Xml, _capabilities) : ShareReply.Empty(405);
            case ["ScannerStatus"]:
                return method == "GET" ? new ShareReply(200, Xml, await StatusAsync(request.Peer, ct).ConfigureAwait(false)) : ShareReply.Empty(405);
            case ["ScanJobs"]:
                return method == "POST" ? Create(request) : ShareReply.Empty(405);
            case ["ScanJobs", var id]:
                return method == "DELETE" ? Delete(id, request.Peer) : ShareReply.Empty(405);
            case ["ScanJobs", var id, "NextDocument"]:
                return method == "GET" ? await NextDocumentAsync(id, request.Peer, ct).ConfigureAwait(false) : ShareReply.Empty(405);
            case ["ScanJobs", var id, "ScanImageInfo"]:
                return method == "GET" ? ImageInfo(id, request.Peer) : ShareReply.Empty(405);
            default:
                return ShareReply.Empty(404);
        }
    }

    private async Task<byte[]> StatusAsync(IPAddress peer, CancellationToken ct)
    {
        List<ShareXml.JobLine> lines;
        bool scanning;
        var now = _time.GetUtcNow();
        lock (_gate)
        {
            scanning = _jobs.Any(j => j.State == "Processing");
            lines = _jobs.Where(j => j.IsFrom(peer)).Select(j => j.Line(now)).ToList();
        }
        // The feeder's state only while idle: asked during a scan, the driver would answer after the page.
        var adf = scanning || _busyElsewhere() ? null : await AdfStateAsync(ct).ConfigureAwait(false);
        return ShareXml.Status(scanning || _busyElsewhere() ? "Processing" : "Idle", adf, lines);
    }

    private async Task<string?> AdfStateAsync(CancellationToken ct)
    {
        if (_caps.Adf is null) return null;
        var now = _time.GetUtcNow();
        lock (_gate)
            if (_status is { } cached && now - cached.At < TimeSpan.FromSeconds(2)) return cached.Adf;
        string? adf;
        try
        {
            using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct, _closed.Token);
            limit.CancelAfter(_limits.StatusTimeout);
            adf = (await _scanner.GetStatusAsync(limit.Token).WaitAsync(limit.Token).ConfigureAwait(false)).AdfState;
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            adf = null; // not known: left out, as a scanner that can't tell does
        }
        lock (_gate) _status = (now, adf);
        return adf;
    }

    private ShareReply Create(ShareRequest request)
    {
        ShareScanSettings settings;
        try
        {
            settings = ShareXml.ReadSettings(request.Body, _caps);
        }
        catch (ShareRequestException ex)
        {
            return ShareReply.Empty(ex.Status);
        }
        Job job;
        var now = _time.GetUtcNow();
        lock (_gate)
        {
            if (_disposed) return ShareReply.Empty(503);
            var active = _jobs.Count(j => j.IsActive);
            if (active > _limits.MaxQueued || _jobs.Count(j => j.IsActive && j.IsFrom(request.Peer)) >= _limits.MaxJobsPerPeer)
                return ShareReply.Empty(503, 10);
            if (active == 0 && _busyElsewhere()) return ShareReply.Empty(503, 5); // this PC scans with it now
            while (_jobs.Count >= _limits.MaxJobs && _jobs.FirstOrDefault(j => !j.IsActive) is { } old) Forget(old);
            if (_jobs.Count >= _limits.MaxJobs) return ShareReply.Empty(503, 10);
            job = new Job(Guid.NewGuid(), request.Peer, settings, now, _limits.PageBuffer, _closed.Token);
            _jobs.Add(job);
        }
        _log(string.Format(System.Globalization.CultureInfo.InvariantCulture, "Shared scanner: a device on the network started a scan ({0}, {1} dpi, {2}).",
            settings.Request.Source, settings.Request.Resolution, settings.Format));
        job.Run = Task.Run(() => RunAsync(job));
        var location = request.Authority is { } host && IsPlainAuthority(host) ? $"https://{host}{job.Path}" : job.Path;
        return new ShareReply(201, Location: location);
    }

    /// <summary>A host and port as Kestrel accepted them: letters, digits, dots, dashes, colons and an IPv6 literal's brackets.</summary>
    private static bool IsPlainAuthority(string host) =>
        host.Length is > 0 and <= 255 && host.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or ':' or '[' or ']' or '%');

    private async Task RunAsync(Job job)
    {
        var entered = false;
        try
        {
            await _scanning.WaitAsync(job.Cancel.Token).ConfigureAwait(false);
            entered = true;
            job.Start();
            var input = _caps.For(job.Settings.Request.Source);
            var dpi = input is null ? job.Settings.Request.Resolution : EsclXml.Resolution(job.Settings.Request, input);
            await foreach (var page in _scanner.ScanAsync(job.Settings.Request, job.Cancel.Token).ConfigureAwait(false))
            {
                var info = Info(page);
                byte[] document;
                if (job.Settings.Format == ShareXml.Pdf)
                {
                    using var pdf = new MemoryStream();
                    PdfWriter.Write(pdf, [new PdfPage(page, dpi)]);
                    document = pdf.ToArray();
                }
                else document = page;
                await job.Pages.Writer.WriteAsync((document, info), job.Cancel.Token).ConfigureAwait(false);
                job.Wrote();
            }
            job.End("Completed", null, _time.GetUtcNow());
        }
        catch (OperationCanceledException) when (job.Cancel.IsCancellationRequested)
        {
            job.End("Canceled", "JobCanceledByUser", _time.GetUtcNow());
        }
        catch (ScanException ex)
        {
            job.End("Aborted", "AbortedBySystem", _time.GetUtcNow());
            _log($"Shared scanner: the scan stopped: {ex.Message}");
        }
        catch (Exception ex) // any other failure ends this job, never the server
        {
            job.End("Aborted", "AbortedBySystem", _time.GetUtcNow());
            _log($"Shared scanner: the scan failed: {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            if (entered) _scanning.Release();
        }
        _log($"Shared scanner: the scan ended ({job.State.ToLowerInvariant()}, {job.Scanned} page(s) scanned).");
    }

    /// <summary>A page's size for ScanImageInfo; zero when its header doesn't say (the page goes out as the scanner gave it all the same).</summary>
    private static (int, int, int) Info(byte[] jpeg)
    {
        try
        {
            return PdfWriter.JpegInfo(jpeg);
        }
        catch (Exception ex) when (ex is FormatException or ArgumentOutOfRangeException or IndexOutOfRangeException)
        {
            return (0, 0, 3);
        }
    }

    private async Task<ShareReply> NextDocumentAsync(string id, IPAddress peer, CancellationToken ct)
    {
        if (Find(id, peer) is not { } job) return ShareReply.Empty(404);
        job.Touch(_time.GetUtcNow());
        if (!job.Reading.Wait(0, CancellationToken.None)) return ShareReply.Empty(503, 1); // one page asked at a time
        try
        {
            using var wait = CancellationTokenSource.CreateLinkedTokenSource(ct);
            wait.CancelAfter(_limits.LongPoll);
            try
            {
                while (await job.Pages.Reader.WaitToReadAsync(wait.Token).ConfigureAwait(false))
                    if (job.Pages.Reader.TryRead(out var page))
                    {
                        job.Delivered(page.Info);
                        return new ShareReply(200, job.Settings.Format, page.Document);
                    }
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                return ShareReply.Empty(503, 2); // still scanning: ask again
            }
            // No more pages: the end of the job, or (nothing sent and it failed) the scan couldn't run.
            return ShareReply.Empty(job.State == "Aborted" && job.Images == 0 ? 409 : 404);
        }
        finally
        {
            job.Touch(_time.GetUtcNow());
            job.Reading.Release();
        }
    }

    private ShareReply ImageInfo(string id, IPAddress peer)
    {
        if (Find(id, peer) is not { LastImage: { } info } job) return ShareReply.Empty(404);
        job.Touch(_time.GetUtcNow());
        return new ShareReply(200, Xml, ShareXml.ImageInfo(job.Path, job.Uuid, info.Width, info.Height, info.Components));
    }

    private ShareReply Delete(string id, IPAddress peer)
    {
        if (Find(id, peer) is not { } job) return ShareReply.Empty(404);
        job.Cancel.Cancel();
        return ShareReply.Empty(200);
    }

    private Job? Find(string id, IPAddress peer)
    {
        if (id.Length != 32 || !Guid.TryParseExact(id, "N", out var uuid)) return null;
        lock (_gate) return _jobs.FirstOrDefault(j => j.Uuid == uuid && j.IsFrom(peer));
    }

    /// <summary>Cancels jobs nobody asks about and forgets finished ones; runs every few seconds and on each request.</summary>
    private void Sweep()
    {
        var now = _time.GetUtcNow();
        List<Job> cancel;
        lock (_gate)
        {
            foreach (var old in _jobs.Where(j => !j.IsActive && j.Ended is { } e && now - e >= _limits.KeepFinished).ToList()) Forget(old);
            cancel = _jobs.Where(j => !j.Cancel.IsCancellationRequested
                && (now - j.Created >= _limits.MaxJobLife || ((j.IsActive || j.HasUnread) && now - j.Touched >= _limits.IdleLimit))).ToList();
        }
        foreach (var job in cancel)
        {
            job.Cancel.Cancel();
            job.DropPages();
        }
    }

    private void Forget(Job job)
    {
        _jobs.Remove(job);
        job.DropPages();
    }

    /// <summary>Stops: every job cancelled and its pages dropped; any later request is answered 503.</summary>
    public void Dispose()
    {
        List<Job> jobs;
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            jobs = [.. _jobs];
            _jobs.Clear();
        }
        _sweep.Dispose();
        _closed.Cancel();
        foreach (var job in jobs) job.DropPages();
    }

    private sealed class Job
    {
        private readonly Lock _gate = new();

        public Job(Guid uuid, IPAddress owner, ShareScanSettings settings, DateTimeOffset now, int buffer, CancellationToken closed)
        {
            Uuid = uuid;
            Owner = Normal(owner);
            Settings = settings;
            Created = Touched = now;
            Cancel = CancellationTokenSource.CreateLinkedTokenSource(closed);
            Pages = Channel.CreateBounded<(byte[], (int, int, int))>(new BoundedChannelOptions(Math.Max(buffer, 1)) { SingleReader = true, SingleWriter = true });
        }

        public Guid Uuid { get; }
        public string Path => $"{Root}ScanJobs/{Uuid:N}";
        public IPAddress Owner { get; }
        public ShareScanSettings Settings { get; }
        public DateTimeOffset Created { get; }
        public CancellationTokenSource Cancel { get; }
        public Channel<(byte[] Document, (int Width, int Height, int Components) Info)> Pages { get; }
        public SemaphoreSlim Reading { get; } = new(1, 1);
        public Task Run { get; set; } = Task.CompletedTask;

        private string _state = "Pending";
        private string? _reason;
        private DateTimeOffset _touched;
        private DateTimeOffset? _ended;
        private int _images, _scanned;
        private (int, int, int)? _last;

        public string State { get { lock (_gate) return _state; } }
        public bool IsActive { get { lock (_gate) return _state is "Pending" or "Processing"; } }
        public DateTimeOffset? Ended { get { lock (_gate) return _ended; } }
        public int Images { get { lock (_gate) return _images; } }
        public int Scanned { get { lock (_gate) return _scanned; } }
        public bool HasUnread => Pages.Reader.Count > 0;
        public (int Width, int Height, int Components)? LastImage { get { lock (_gate) return _last; } }

        public DateTimeOffset Touched
        {
            get { lock (_gate) return _touched; }
            private init => _touched = value;
        }

        public void Touch(DateTimeOffset now)
        {
            lock (_gate) _touched = now;
        }

        public void Start()
        {
            lock (_gate) if (_state == "Pending") _state = "Processing";
        }

        public void Wrote()
        {
            lock (_gate) _scanned++;
        }

        public void Delivered((int, int, int) info)
        {
            lock (_gate)
            {
                _images++;
                _last = info;
            }
        }

        public void End(string state, string? reason, DateTimeOffset now)
        {
            lock (_gate)
            {
                _state = state;
                _reason = reason;
                _ended = now;
            }
            Pages.Writer.TryComplete();
        }

        /// <summary>Unread pages let go (a cancelled or forgotten job's).</summary>
        public void DropPages()
        {
            Pages.Writer.TryComplete();
            while (Pages.Reader.TryRead(out _)) { }
        }

        public bool IsFrom(IPAddress peer) => Normal(peer).Equals(Owner);

        public ShareXml.JobLine Line(DateTimeOffset now)
        {
            lock (_gate)
                return new(Path, Uuid, _state, (int)Math.Clamp((now - Created).TotalSeconds, 0, int.MaxValue), _images, _reason);
        }

        private static IPAddress Normal(IPAddress a) => a.IsIPv4MappedToIPv6 ? a.MapToIPv4() : a;
    }
}
