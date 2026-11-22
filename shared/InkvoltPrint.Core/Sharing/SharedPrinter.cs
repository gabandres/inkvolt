using System.Buffers.Binary;
using System.Globalization;
using System.Net;
using System.Text;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Ipp;

namespace InkvoltPrint.Core.Sharing;

/// <summary>A Windows queue as a shared printer offers it (read from the queue by the app): its name, color, two-sided and its paper.</summary>
/// <param name="Media">The queue's default paper as a PWG name (<c>na_letter_8.5x11in</c>, <c>iso_a4_210x297mm</c>); pages are fitted to it.</param>
public sealed record SharedQueue(string Name, bool Color, bool TwoSided, string Media = SharedPrinterMedia.Letter);

/// <summary>A job a phone sent, for the app to print on the Windows queue (pages fitted to its paper).</summary>
/// <param name="Format">What the document is (sniffed, never only what the phone said): PDF, JPEG, PWG Raster or Apple Raster.</param>
public sealed record SharedPrintJob(string Queue, string Format, byte[] Document, int Copies, bool TwoSided, bool Monochrome, string JobName);

/// <summary>Prints a shared printer's job on its Windows queue; throws <see cref="FormatException"/> for a document it can't read.</summary>
public interface ISharedPrintSink
{
    Task PrintAsync(SharedPrintJob job, CancellationToken ct);
}

/// <summary>How much a shared printer takes on (roadmap 4.10: everything comes from a device on the network). Tests shorten the times.</summary>
public sealed record PrinterShareLimits
{
    /// <summary>The largest document: 64 MB (a 20-page color PWG Raster at 300 dpi is about half that).</summary>
    public long MaxDocumentBytes { get; init; } = 64 * 1024 * 1024;

    /// <summary>Where the request's attributes must end (the document follows them).</summary>
    public int MaxAttributeBytes { get; init; } = 64 * 1024;

    public int MaxCopies { get; init; } = 10;

    /// <summary>Jobs waiting behind the one printing; one more is told the printer is busy (try later).</summary>
    public int MaxWaiting { get; init; } = 2;

    /// <summary>Jobs kept to answer about (finished ones are forgotten first, and after <see cref="KeepFinished"/>).</summary>
    public int MaxJobs { get; init; } = 20;

    public TimeSpan KeepFinished { get; init; } = TimeSpan.FromMinutes(10);
}

/// <summary>The paper a shared printer names: PWG self-describing names and their sizes in hundredths of a millimetre.</summary>
public static class SharedPrinterMedia
{
    public const string Letter = "na_letter_8.5x11in", A4 = "iso_a4_210x297mm", Legal = "na_legal_8.5x14in";

    /// <summary>Width and height in hundredths of a millimetre, for the sizes a shared printer names.</summary>
    public static (int Width, int Height) Size(string media) => media switch
    {
        A4 => (21000, 29700),
        Legal => (21590, 35560),
        _ => (21590, 27940),
    };

    /// <summary>The queue's paper first, then Letter and A4 (what a phone may lay out for: the page is fitted to the queue's paper).</summary>
    public static IReadOnlyList<string> Offered(string queueMedia) => [.. new[] { queueMedia, Letter, A4 }.Distinct()];

    /// <summary>A Windows paper name (PrintTicket's PageMediaSizeName) as a PWG name; Letter for anything else.</summary>
    public static string FromWindows(string? name) => name switch
    {
        "ISOA4" => A4,
        "NorthAmericaLegal" => Legal,
        _ => Letter,
    };
}

/// <summary>
/// The shared printers' IPP server (roadmap 4.10): Windows queues as IPP Everywhere / AirPrint / Mopria printers, without the HTTP server
/// around it (the app's is Kestrel). It takes Get-Printer-Attributes, Validate-Job and Print-Job (PDF, JPEG, PWG Raster, Apple Raster),
/// and Get-Job-Attributes, Get-Jobs and Cancel-Job for the jobs a device sent; nothing else. Every request is hostile input: the
/// attributes are read with <see cref="IppCodec.DecodeGroups(ReadOnlySpan{byte}, out int)"/> within <see cref="PrinterShareLimits.MaxAttributeBytes"/>,
/// a document is taken only as what its first bytes show it is, nothing in a request names a file or another queue, and a device sees
/// only its own jobs. One job prints at a time, a few wait (<see cref="PrinterShareLimits"/>); the printing is the app's
/// (<see cref="ISharedPrintSink"/>). <see cref="Dispose"/> cancels every job not yet printing.
/// </summary>
public sealed class SharedPrinter : IDisposable
{
    public const string PathPrefix = "/ipp/print/";

    /// <summary>RFC 8011 / PWG 5100 status codes this server answers with.</summary>
    public const ushort Ok = 0x0000, OkIgnored = 0x0001, BadRequest = 0x0400, NotFound = 0x0406, NotPossible = 0x0404, Conflicting = 0x0409,
        TooLarge = 0x0408, FormatNotSupported = 0x040A, AttributesNotSupported = 0x040B, DocumentFormatError = 0x040E, InternalError = 0x0500,
        OperationNotSupported = 0x0501, VersionNotSupported = 0x0503, Busy = 0x0507;

    private const ushort ValidateJob = 0x0004;

    /// <summary>job-state.</summary>
    private const int Pending = 3, Processing = 5, Canceled = 7, Aborted = 8, Completed = 9;

    public static readonly IReadOnlyList<string> Formats = ["application/pdf", "image/jpeg", "image/pwg-raster", "image/urf", "application/octet-stream"];

    private readonly SharedQueue _queue;
    private readonly Guid _uuid;
    private readonly string _name, _location;
    private readonly ISharedPrintSink _sink;
    private readonly PrinterShareLimits _limits;
    private readonly TimeProvider _time;
    private readonly Action<string> _log;
    private readonly DateTimeOffset _started;
    private readonly SemaphoreSlim _printing = new(1, 1);
    private readonly CancellationTokenSource _closed = new();
    private readonly Lock _gate = new();
    private readonly List<Job> _jobs = [];
    private int _nextId = 1;
    private bool _disposed;

    /// <param name="name">What phones list it as.</param>
    /// <param name="location">Where it is: this PC's name.</param>
    /// <param name="log">Told when a job starts and how it ends: no address, name or document of the device that sent it.</param>
    public SharedPrinter(SharedQueue queue, Guid uuid, string name, string location, ISharedPrintSink sink, PrinterShareLimits? limits = null,
        TimeProvider? time = null, Action<string>? log = null)
    {
        _queue = queue;
        _uuid = uuid;
        _name = Cut(name, 127);
        _location = Cut(location, 127);
        _sink = sink;
        _limits = limits ?? new PrinterShareLimits();
        _time = time ?? TimeProvider.System;
        _log = log ?? (_ => { });
        _started = _time.GetUtcNow();
        Path = PathOf(uuid);
    }

    public SharedQueue Queue => _queue;
    public Guid Uuid => _uuid;
    public string Name => _name;

    /// <summary>Its resource on the server: <c>/ipp/print/</c> and its UUID (stable across restarts, so a phone finds it again).</summary>
    public string Path { get; }

    public static string PathOf(Guid uuid) => PathPrefix + uuid.ToString("N");

    /// <summary>Jobs waiting or printing now.</summary>
    public int ActiveJobs
    {
        get { lock (_gate) return _jobs.Count(j => j.State is Pending or Processing); }
    }

    /// <summary>Raised when a job finishes (for tests and the card).</summary>
    public event Action? JobEnded;

    /// <summary>One IPP request to this printer (the server already matched its path). Never throws for what the request holds.</summary>
    public async Task<ShareReply> HandleAsync(ShareRequest request, CancellationToken ct)
    {
        if (request.Method != "POST") return request.Method == "GET" ? new ShareReply(200, "text/plain; charset=utf-8", Encoding.UTF8.GetBytes(_name)) : ShareReply.Empty(405);
        var body = request.Body;
        if (body.Length < 9) return ShareReply.Empty(400);
        var (major, minor) = (body[0], body[1]);
        var operation = BinaryPrimitives.ReadUInt16BigEndian(body.AsSpan(2));
        var requestId = BinaryPrimitives.ReadInt32BigEndian(body.AsSpan(4));
        if (major is not (1 or 2)) return Reply(1, 1, VersionNotSupported, requestId, "IPP 1.1 or 2.x only");
        Dictionary<string, List<object>> op, job;
        int end;
        try
        {
            var (_, groups) = IppCodec.DecodeGroups(body.AsSpan(0, Math.Min(body.Length, _limits.MaxAttributeBytes)), out end);
            if (end < 0 || groups.Count == 0 || groups[0].Tag != IppCodec.OperationTag) return Reply(major, minor, BadRequest, requestId, "no operation attributes");
            op = groups[0].Attributes;
            job = groups.FirstOrDefault(g => g.Tag == IppCodec.JobTag).Attributes ?? [];
        }
        catch (FormatException)
        {
            return Reply(major, minor, BadRequest, requestId, "malformed request");
        }
        if (Str(op, "attributes-charset") is null || Str(op, "attributes-natural-language") is null)
            return Reply(major, minor, BadRequest, requestId, "attributes-charset and attributes-natural-language come first");
        var peer = SharePeers.Normal(request.Peer);
        Sweep();
        switch (operation)
        {
            case IppCodec.GetPrinterAttributes:
                return Reply(major, minor, Ok, requestId, null, [(IppCodec.PrinterTag, PrinterAttributes(Requested(op), request.Authority))]);
            case ValidateJob:
            {
                var (status, unsupported, _) = Validate(op, job);
                return Reply(major, minor, status, requestId, null, unsupported.Count > 0 ? [(IppCodec.UnsupportedTag, unsupported)] : []);
            }
            case IppCodec.PrintJob:
                return PrintJob(major, minor, requestId, op, job, body.AsMemory(end), peer, request.Authority);
            case IppCodec.GetJobAttributes:
            {
                if (Find(op, peer) is not { } found) return Reply(major, minor, NotFound, requestId, "no such job");
                return Reply(major, minor, Ok, requestId, null, [(IppCodec.JobTag, JobAttributes(found, request.Authority))]);
            }
            case IppCodec.GetJobs:
            {
                var completed = Str(op, "which-jobs") == "completed";
                List<Job> mine;
                lock (_gate) mine = [.. _jobs.Where(j => j.Peer.Equals(peer) && (completed ? j.State >= Canceled : j.State < Canceled)).OrderByDescending(j => j.Id)];
                return Reply(major, minor, Ok, requestId, null, [.. mine.Select(j => (IppCodec.JobTag, JobAttributes(j, request.Authority)))]);
            }
            case IppCodec.CancelJob:
                return Cancel(major, minor, requestId, op, peer);
            default:
                await Task.CompletedTask.ConfigureAwait(false);
                return Reply(major, minor, OperationNotSupported, requestId, "operation not supported");
        }
    }

    private ShareReply PrintJob(byte major, byte minor, int requestId, Dictionary<string, List<object>> op, Dictionary<string, List<object>> template,
        ReadOnlyMemory<byte> document, IPAddress peer, string? authority)
    {
        var (status, unsupported, options) = Validate(op, template);
        if (status >= BadRequest) return Reply(major, minor, status, requestId, null, unsupported.Count > 0 ? [(IppCodec.UnsupportedTag, unsupported)] : []);
        if (document.Length == 0) return Reply(major, minor, BadRequest, requestId, "no document");
        if (document.Length > _limits.MaxDocumentBytes) return Reply(major, minor, TooLarge, requestId, "document too large");
        var sniffed = Sniff(document.Span);
        var said = Str(op, "document-format") ?? "application/octet-stream";
        if (sniffed is null) return Reply(major, minor, said == "application/octet-stream" ? FormatNotSupported : DocumentFormatError, requestId, "not a document this printer takes");
        if (said != "application/octet-stream" && said != sniffed) return Reply(major, minor, DocumentFormatError, requestId, "the document isn't what it says it is");
        Job job;
        lock (_gate)
        {
            if (_disposed) return Reply(major, minor, Busy, requestId, "not sharing");
            var waiting = _jobs.Count(j => j.State == Pending);
            if (waiting >= _limits.MaxWaiting || _jobs.Count(j => j.State == Pending && j.Peer.Equals(peer)) >= _limits.MaxWaiting)
                return Reply(major, minor, Busy, requestId, "busy: try again soon");
            while (_jobs.Count >= _limits.MaxJobs && _jobs.FirstOrDefault(j => j.State >= Canceled) is { } old) Forget(old);
            if (_jobs.Count >= _limits.MaxJobs) return Reply(major, minor, Busy, requestId, "busy: try again soon");
            job = new Job(_nextId++, peer, options.Name, _time.GetUtcNow(), CancellationTokenSource.CreateLinkedTokenSource(_closed.Token));
            _jobs.Add(job);
        }
        var print = new SharedPrintJob(_queue.Name, sniffed, document.ToArray(), options.Copies, options.TwoSided, options.Monochrome, options.Name);
        _ = Task.Run(() => RunAsync(job, print));
        return Reply(major, minor, unsupported.Count > 0 ? OkIgnored : Ok, requestId, null,
            [.. unsupported.Count > 0 ? [(IppCodec.UnsupportedTag, (IReadOnlyList<IppValue>)unsupported)] : Array.Empty<(byte, IReadOnlyList<IppValue>)>(),
                (IppCodec.JobTag, JobAttributes(job, authority))]);
    }

    private async Task RunAsync(Job job, SharedPrintJob print)
    {
        try
        {
            await _printing.WaitAsync(job.Cancel.Token).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is OperationCanceledException or ObjectDisposedException)
        {
            End(job, Canceled, "job-canceled-by-user");
            return;
        }
        try
        {
            lock (_gate)
            {
                if (job.State != Pending) return;
                job.State = Processing;
                job.Reason = "job-printing";
            }
            _log($"Printer sharing: a job came in ({print.Format}, {print.Document.Length / 1024} KB, {print.Copies} copies).");
            await _sink.PrintAsync(print, job.Cancel.Token).ConfigureAwait(false);
            End(job, Completed, "job-completed-successfully");
            _log("Printer sharing: the job went to the Windows queue.");
        }
        catch (OperationCanceledException) when (job.Cancel.IsCancellationRequested)
        {
            End(job, Canceled, "job-canceled-by-user");
        }
        catch (FormatException ex)
        {
            End(job, Aborted, "document-format-error");
            _log($"Printer sharing: the document couldn't be read ({ex.Message}).");
        }
        catch (Exception ex)
        {
            End(job, Aborted, "aborted-by-system");
            _log($"Printer sharing: the job didn't print: {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            _printing.Release();
        }
    }

    private void End(Job job, int state, string reason)
    {
        lock (_gate)
        {
            if (job.State >= Canceled) return;
            job.State = state;
            job.Reason = reason;
            job.Ended = _time.GetUtcNow();
        }
        try { JobEnded?.Invoke(); }
        catch (Exception ex) { _log($"Printer sharing: {ex.Message}"); }
    }

    private ShareReply Cancel(byte major, byte minor, int requestId, Dictionary<string, List<object>> op, IPAddress peer)
    {
        if (Find(op, peer) is not { } job) return Reply(major, minor, NotFound, requestId, "no such job");
        lock (_gate)
        {
            if (job.State != Pending) return Reply(major, minor, NotPossible, requestId, job.State == Processing ? "already printing" : "already ended");
        }
        try { job.Cancel.Cancel(); }
        catch (ObjectDisposedException) { }
        End(job, Canceled, "job-canceled-by-user");
        return Reply(major, minor, Ok, requestId, null);
    }

    /// <summary>The job a request names (job-id with this printer's URI, or a job-uri), if it's the device's own.</summary>
    private Job? Find(Dictionary<string, List<object>> op, IPAddress peer)
    {
        var id = Int(op, "job-id");
        if (id is null && Str(op, "job-uri") is { } uri && uri.LastIndexOf('/') is var slash and >= 0
            && int.TryParse(uri[(slash + 1)..], NumberStyles.None, CultureInfo.InvariantCulture, out var fromUri)) id = fromUri;
        if (id is null) return null;
        lock (_gate) return _jobs.FirstOrDefault(j => j.Id == id && j.Peer.Equals(peer));
    }

    /// <summary>Finished jobs past <see cref="PrinterShareLimits.KeepFinished"/> are forgotten.</summary>
    private void Sweep()
    {
        var now = _time.GetUtcNow();
        lock (_gate)
            foreach (var old in _jobs.Where(j => j.Ended is { } ended && now - ended > _limits.KeepFinished).ToList()) Forget(old);
    }

    /// <summary>An ended job goes: its cancellation source too (it's linked to the printer's). Inside <see cref="_gate"/>.</summary>
    private void Forget(Job job)
    {
        _jobs.Remove(job);
        job.Cancel.Dispose();
    }

    // ---------------------------------------------------------------- validating a job

    private sealed record Options(int Copies, bool TwoSided, bool Monochrome, string Name);

    /// <summary>
    /// A job's attributes against what this printer takes: copies, sides, print-color-mode and media are used (media only to say it's
    /// one it names: pages are fitted to the queue's paper); anything else is ignored and listed back as unsupported. With
    /// ipp-attribute-fidelity true, any of that refuses the job.
    /// </summary>
    private (ushort Status, List<IppValue> Unsupported, Options Options) Validate(Dictionary<string, List<object>> op, Dictionary<string, List<object>> template)
    {
        var unsupported = new List<IppValue>();
        var said = Str(op, "document-format");
        var name = Cut(AlertText.DocumentName(Str(op, "job-name") ?? Str(op, "document-name"), 100), 100);
        if (name.Length == 0) name = CoreStrings.PrinterShare_JobName;
        if (said is not null && !Formats.Contains(said))
            return (FormatNotSupported, [new IppValue("document-format", IppCodec.MimeMediaType, Cut(said, 255))], new Options(1, false, false, name));
        var copies = 1;
        bool twoSided = false, monochrome = false;
        foreach (var (key, values) in template)
        {
            var value = values.FirstOrDefault();
            switch (key)
            {
                case "copies" when value is int n && n >= 1 && n <= _limits.MaxCopies:
                    copies = n;
                    break;
                case "sides" when value is "one-sided":
                    break;
                case "sides" when value is "two-sided-long-edge" && _queue.TwoSided:
                    twoSided = true;
                    break;
                case "print-color-mode" when value is "auto" or "color" && _queue.Color:
                    break;
                case "print-color-mode" when value is "monochrome" or "auto-monochrome" or "auto":
                    monochrome = value is "monochrome" || !_queue.Color;
                    break;
                case "media" when value is string media && SharedPrinterMedia.Offered(_queue.Media).Contains(media):
                case "media-col":
                case "print-scaling" when value is "auto" or "fit" or "auto-fit":
                case "orientation-requested" when value is 3:
                case "print-quality" when value is 3 or 4:
                case "multiple-document-handling" when value is "separate-documents-collated-copies":
                case "job-name" or "job-priority":
                    break;
                default:
                    unsupported.Add(Unsupported(key, value));
                    break;
            }
        }
        if (op.TryGetValue("compression", out var compression) && compression.FirstOrDefault() is string c && c != "none")
            return (AttributesNotSupported, [new IppValue("compression", IppCodec.Keyword, Cut(c, 255))], new Options(1, false, false, name));
        var fidelity = op.TryGetValue("ipp-attribute-fidelity", out var f) && f.FirstOrDefault() is true;
        var status = unsupported.Count == 0 ? Ok : fidelity ? AttributesNotSupported : OkIgnored;
        if (unsupported.Count > 32) unsupported = unsupported[..32];
        return (status, unsupported, new Options(copies, twoSided, monochrome, name));
    }

    /// <summary>An attribute listed back as unsupported: its name, and its value where it's a plain one (else no value).</summary>
    private static IppValue Unsupported(string name, object? value) => value switch
    {
        int n => new IppValue(Cut(name, 255), IppCodec.Integer, n.ToString(CultureInfo.InvariantCulture)),
        string s => new IppValue(Cut(name, 255), IppCodec.Keyword, Cut(s, 255)),
        _ => new IppValue(Cut(name, 255), 0x10, ""), // out-of-band "unsupported"
    };

    /// <summary>What a document's first bytes say it is; null for anything else.</summary>
    public static string? Sniff(ReadOnlySpan<byte> d) =>
        d.StartsWith("%PDF-"u8) ? "application/pdf"
        : d.Length >= 3 && d[0] == 0xFF && d[1] == 0xD8 && d[2] == 0xFF ? "image/jpeg"
        : d.StartsWith("RaS2"u8) ? "image/pwg-raster"
        : d.StartsWith("UNIRAST\0"u8) ? "image/urf"
        : null;

    // ---------------------------------------------------------------- attributes

    /// <summary>The attributes asked for: null for all (none named, "all", or a group name).</summary>
    private static HashSet<string>? Requested(Dictionary<string, List<object>> op)
    {
        if (!op.TryGetValue("requested-attributes", out var asked)) return null;
        var names = asked.OfType<string>().Take(256).ToHashSet(StringComparer.Ordinal);
        return names.Count == 0 || names.Contains("all") || names.Contains("printer-description") || names.Contains("job-template") ? null : names;
    }

    /// <summary>The printer's URI as the device reached it (its Host header), or this PC's name when it gave none.</summary>
    public string Uri(string? authority) => $"ipp://{(Authority(authority) ?? "localhost")}{Path}";

    /// <summary>A Host header that is a plain host and port (letters, digits, dots, dashes, colons, brackets); null otherwise.</summary>
    private static string? Authority(string? authority) =>
        authority is { Length: > 0 and <= 255 } a && a.All(c => char.IsAsciiLetterOrDigit(c) || c is '.' or '-' or ':' or '[' or ']' or '%') ? a : null;

    internal IReadOnlyList<IppValue> PrinterAttributes(HashSet<string>? only, string? authority)
    {
        var all = new List<IppValue>();
        void K(string name, params string[] values) { foreach (var v in values) all.Add(new IppValue(name, IppCodec.Keyword, v)); }
        void I(string name, int value) => all.Add(new IppValue(name, IppCodec.Integer, value.ToString(CultureInfo.InvariantCulture)));
        void E(string name, params int[] values) { foreach (var v in values) all.Add(new IppValue(name, IppCodec.Enum, v.ToString(CultureInfo.InvariantCulture))); }
        void B(string name, bool value) => all.Add(new IppValue(name, IppCodec.Boolean, value ? "true" : "false"));
        void T(string name, byte tag, params string[] values) { foreach (var v in values) all.Add(new IppValue(name, tag, v)); }

        var busy = ActiveJobs;
        var color = _queue.Color;
        var media = SharedPrinterMedia.Offered(_queue.Media);
        T("charset-configured", IppCodec.Charset, "utf-8");
        T("charset-supported", IppCodec.Charset, "utf-8");
        K("compression-supported", "none");
        T("document-format-default", IppCodec.MimeMediaType, "application/octet-stream");
        T("document-format-supported", IppCodec.MimeMediaType, [.. Formats]);
        T("generated-natural-language-supported", IppCodec.NaturalLanguage, "en");
        T("natural-language-configured", IppCodec.NaturalLanguage, "en");
        K("ipp-versions-supported", "1.1", "2.0");
        E("operations-supported", IppCodec.PrintJob, ValidateJob, IppCodec.CancelJob, IppCodec.GetJobAttributes, IppCodec.GetJobs, IppCodec.GetPrinterAttributes);
        K("pdl-override-supported", "attempted");
        B("printer-is-accepting-jobs", true);
        T("printer-name", IppCodec.Name, _name);
        T("printer-info", IppCodec.Text, _name);
        T("printer-make-and-model", IppCodec.Text, Cut($"{_queue.Name} (Inkvolt Print)", 127));
        T("printer-location", IppCodec.Text, _location);
        E("printer-state", busy > 0 ? 4 : 3);
        K("printer-state-reasons", "none");
        T("printer-uri-supported", IppCodec.Uri, Uri(authority));
        K("uri-authentication-supported", "none");
        K("uri-security-supported", "none");
        T("printer-uuid", IppCodec.Uri, $"urn:uuid:{_uuid:D}");
        I("printer-up-time", (int)Math.Clamp((_time.GetUtcNow() - _started).TotalSeconds + 1, 1, int.MaxValue));
        I("queued-job-count", busy);
        T("printer-device-id", IppCodec.Text, Cut($"MFG:Inkvolt Print;MDL:{DeviceIdText(_queue.Name)};CMD:PDF,JPEG,PWGRaster,URF;", 255));
        K("printer-kind", "document", "photo");
        K("which-jobs-supported", "completed", "not-completed");
        B("job-ids-supported", true);
        K("job-creation-attributes-supported", "copies", "multiple-document-handling", "sides", "print-color-mode", "media", "media-col", "print-scaling");
        I("copies-default", 1);
        T("copies-supported", IppCodec.RangeOfInteger, $"1-{_limits.MaxCopies}");
        K("multiple-document-handling-supported", "separate-documents-collated-copies"); // the queue's ticket collates them
        K("sides-default", "one-sided");
        K("sides-supported", _queue.TwoSided ? ["one-sided", "two-sided-long-edge"] : ["one-sided"]);
        B("color-supported", color);
        K("print-color-mode-default", color ? "auto" : "monochrome");
        K("print-color-mode-supported", color ? ["auto", "color", "monochrome"] : ["auto", "monochrome"]);
        K("print-scaling-default", "fit");
        K("print-scaling-supported", "auto", "fit");
        E("orientation-requested-default", 3);
        E("orientation-requested-supported", 3);
        E("print-quality-default", 4);
        E("print-quality-supported", 4);
        T("printer-resolution-default", IppCodec.Resolution, "300dpi");
        T("printer-resolution-supported", IppCodec.Resolution, "300dpi");
        T("pwg-raster-document-resolution-supported", IppCodec.Resolution, "300dpi");
        K("pwg-raster-document-type-supported", color ? ["sgray_8", "srgb_8"] : ["sgray_8"]);
        K("pwg-raster-document-sheet-back", "normal");
        K("urf-supported", [.. Urf(color, _queue.TwoSided)]);
        T("jpeg-k-octets-supported", IppCodec.RangeOfInteger, $"0-{_limits.MaxDocumentBytes / 1024}");
        T("pdf-k-octets-supported", IppCodec.RangeOfInteger, $"0-{_limits.MaxDocumentBytes / 1024}");
        K("media-default", _queue.Media);
        K("media-supported", [.. media]);
        K("media-ready", _queue.Media);
        K("media-source-supported", "auto");
        K("media-type-supported", "stationery");
        foreach (var side in new[] { "bottom", "left", "right", "top" }) I($"media-{side}-margin-supported", 635);
        all.Add(MediaCol("media-col-default", _queue.Media));
        all.Add(MediaCol("media-col-ready", _queue.Media));
        foreach (var m in media) all.Add(MediaCol("media-col-database", m));
        foreach (var m in media)
        {
            var (w, h) = SharedPrinterMedia.Size(m);
            all.Add(new IppValue("media-size-supported", IppCodec.BegCollection, "")
            {
                Members = [new("x-dimension", IppCodec.Integer, w.ToString(CultureInfo.InvariantCulture)), new("y-dimension", IppCodec.Integer, h.ToString(CultureInfo.InvariantCulture))],
            });
        }
        return only is null ? all : [.. all.Where(a => only.Contains(a.Name))];
    }

    /// <summary>Apple Raster's capabilities: version, copies, 8-bit grey (and 24-bit sRGB), 300 dpi, long-edge two-sided, quality, media.</summary>
    private static IEnumerable<string> Urf(bool color, bool twoSided)
    {
        yield return "V1.4";
        yield return "CP1";
        yield return "W8";
        if (color) yield return "SRGB24";
        yield return "RS300";
        if (twoSided) yield return "DM1";
        yield return "IS1";
        yield return "MT1";
        yield return "PQ4";
    }

    private static IppValue MediaCol(string name, string media)
    {
        var (w, h) = SharedPrinterMedia.Size(media);
        string N(int v) => v.ToString(CultureInfo.InvariantCulture);
        return new IppValue(name, IppCodec.BegCollection, "")
        {
            Members =
            [
                new("media-size", IppCodec.BegCollection, "") { Members = [new("x-dimension", IppCodec.Integer, N(w)), new("y-dimension", IppCodec.Integer, N(h))] },
                new("media-bottom-margin", IppCodec.Integer, "635"),
                new("media-left-margin", IppCodec.Integer, "635"),
                new("media-right-margin", IppCodec.Integer, "635"),
                new("media-top-margin", IppCodec.Integer, "635"),
                new("media-source", IppCodec.Keyword, "auto"),
                new("media-type", IppCodec.Keyword, "stationery"),
            ],
        };
    }

    private IReadOnlyList<IppValue> JobAttributes(Job job, string? authority)
    {
        int state;
        string reason;
        lock (_gate) (state, reason) = (job.State, job.Reason);
        var i = (string name, int v) => new IppValue(name, IppCodec.Integer, v.ToString(CultureInfo.InvariantCulture));
        return
        [
            i("job-id", job.Id),
            new IppValue("job-uri", IppCodec.Uri, $"{Uri(authority)}/{job.Id}"),
            new IppValue("job-printer-uri", IppCodec.Uri, Uri(authority)),
            new IppValue("job-name", IppCodec.Name, job.Name),
            new IppValue("job-state", IppCodec.Enum, state.ToString(CultureInfo.InvariantCulture)),
            new IppValue("job-state-reasons", IppCodec.Keyword, reason),
            i("time-at-creation", (int)Math.Clamp((job.Created - _started).TotalSeconds + 1, 1, int.MaxValue)),
        ];
    }

    private static ShareReply Reply(byte major, byte minor, ushort status, int requestId, string? message,
        IEnumerable<(byte, IReadOnlyList<IppValue>)>? groups = null) =>
        new(200, "application/ipp", IppCodec.EncodeReply(major, minor, status, requestId, message, groups ?? []));

    private static string? Str(Dictionary<string, List<object>> attrs, string name) => attrs.TryGetValue(name, out var v) ? v.FirstOrDefault() as string : null;

    private static int? Int(Dictionary<string, List<object>> attrs, string name) => attrs.TryGetValue(name, out var v) && v.FirstOrDefault() is int n ? n : null;

    /// <summary>One line of visible characters, at most <paramref name="max"/> UTF-8 bytes (an IPP name or text value).</summary>
    private static string Cut(string text, int max)
    {
        var clean = AlertText.Clean(text, max);
        while (Encoding.UTF8.GetByteCount(clean) > max) clean = clean[..^(char.IsLowSurrogate(clean[^1]) && clean.Length > 1 ? 2 : 1)];
        return clean;
    }

    /// <summary>A name in an IEEE 1284 device ID: no colons or semicolons (they separate its keys).</summary>
    private static string DeviceIdText(string name) => new([.. AlertText.Clean(name, 100).Select(c => c is ':' or ';' ? ' ' : c)]);

    public void Dispose()
    {
        List<Job> jobs;
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            jobs = [.. _jobs.Where(j => j.State == Pending)];
        }
        _closed.Cancel(); // a job waiting is cancelled; one printing finishes on the Windows queue
        foreach (var j in jobs) End(j, Canceled, "job-canceled-by-user");
    }

    private sealed class Job(int id, IPAddress peer, string name, DateTimeOffset created, CancellationTokenSource cancel)
    {
        public int Id { get; } = id;
        public IPAddress Peer { get; } = peer;
        public string Name { get; } = name;
        public DateTimeOffset Created { get; } = created;
        public CancellationTokenSource Cancel { get; } = cancel;
        public int State { get; set; } = Pending;
        public string Reason { get; set; } = "none";
        public DateTimeOffset? Ended { get; set; }
    }
}
