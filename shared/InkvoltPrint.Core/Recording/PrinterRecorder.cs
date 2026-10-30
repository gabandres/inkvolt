using System.Collections.Concurrent;
using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Text;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Snmp;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Recording;

/// <summary>How a recording is made (<see cref="PrinterRecorder.RecordAsync"/>).</summary>
public sealed record RecordOptions
{
    /// <summary>Replaces the network (a <see cref="FixtureHandler"/> in tests); null: the printer over the network.</summary>
    public HttpMessageHandler? Transport { get; init; }

    /// <summary>Where SNMP goes (UDP, or a made-up agent in tests); null: SNMP isn't recorded.</summary>
    public ISnmpTransport? Snmp { get; init; }

    public string Community { get; init; } = SnmpClient.DefaultCommunity;

    /// <summary>eSCL and IPP addresses from DNS-SD, when the printer's aren't the usual ones (as <see cref="PrinterConnection.OpenAsync"/>).</summary>
    public Uri? EsclHint { get; init; }

    public Uri? IppHint { get; init; }

    /// <summary>Also one glass page and, when the feeder holds paper, its pages (kept as JPEG, as scanned: never scrubbed).</summary>
    public bool Scan { get; init; }

    /// <summary>The address the recording calls the printer by (<see cref="FixtureScrubber.PlaceholderHost"/>).</summary>
    public string PlaceholderHost { get; init; } = FixtureScrubber.DefaultPlaceholderHost;

    /// <summary>This PC's user and computer names, taken out wherever they appear; null: <see cref="Diagnostics.Identity.Current"/>.</summary>
    public Diagnostics.Identity? Who { get; init; }
}

/// <summary>What a recording holds: the files written, what answered, and how many identifiers of each kind were replaced.</summary>
public sealed record RecordResult(
    IReadOnlyList<string> Files,
    IReadOnlyList<string> Interfaces,
    string? Model,
    IReadOnlyDictionary<string, int> Scrubbed,
    IReadOnlyList<string> NotKept);

/// <summary>
/// <c>inkvoltprint record &lt;address&gt; &lt;folder&gt;</c> (print/ROADMAP.md 1.2): asks a printer everything the app's readers ask
/// (the probe, a printer reading, the UUID check, LEDM's settings, firmware and maintenance documents, CDM's, eSCL's capabilities
/// and status, IPP's Get-Printer-Attributes, the SNMP objects the Printer MIB reader walks) and writes each reply in the layout
/// the tests' fixtures use, so <see cref="FixtureHandler"/> and <see cref="SnmpAgent"/> serve the folder unchanged:
/// <c>DevMgmt_ProductStatusDyn.xml</c>, <c>cdm_system_v1_identity.json</c>, <c>eSCL_ScannerCapabilities.xml</c>,
/// <c>ipp_print.ipp.txt</c> (<see cref="IppText"/>), <c>snmp.txt</c> (snmpwalk -On). Every document goes through
/// <see cref="FixtureScrubber"/> first. Read only: the recording handler lets GETs and IPP Get-Printer-Attributes through and
/// nothing else (with <see cref="RecordOptions.Scan"/>, the eSCL scan job too); no credentials are ever sent. Each request's
/// time and status are kept in <see cref="NotesFile"/>.
/// </summary>
public static class PrinterRecorder
{
    /// <summary>The recording's notes: what was asked, how long each reply took, what wasn't kept. Not a fixture document.</summary>
    public const string NotesFile = "recording.tsv";

    /// <summary>The SNMP objects, as <see cref="SnmpAgent.ParseWalk"/> reads them.</summary>
    public const string SnmpFile = "snmp.txt";

    /// <summary>Subtrees walked over SNMP: system, the Host Resources device and printer tables, the Printer MIB.</summary>
    internal static readonly Oid[] SnmpSubtrees =
        [Oid.Parse("1.3.6.1.2.1.1"), Oid.Parse("1.3.6.1.2.1.25.3.2"), Oid.Parse("1.3.6.1.2.1.25.3.5"), Oid.Parse("1.3.6.1.2.1.43")];

    private const int MaxSnmpObjects = 4000;
    private static readonly TimeSpan SnmpWalkLimit = TimeSpan.FromSeconds(60);

    public static async Task<RecordResult> RecordAsync(string host, string folder, RecordOptions? options = null, CancellationToken ct = default)
    {
        options ??= new RecordOptions();
        using var capture = new Capture(options.Transport ?? DeviceHttp.NetworkHandler(host), options.Scan);
        var snmp = options.Snmp is null ? null : new SnmpCapture(options.Snmp);
        var notKept = new List<string>();
        var scans = new List<(string Name, byte[] Jpeg)>();

        var connection = await PrinterConnection.OpenAsync(host, options.EsclHint, ct, pin: null, transport: capture, options.IppHint, snmp).ConfigureAwait(false);
        using (connection)
        {
            var probe = connection.Probe;
            if (!probe.Reachable && snmp is null) throw new InvalidOperationException($"Nothing answered at {host}.");

            await connection.ReadAsync(ct).ConfigureAwait(false);
            await connection.ReadUuidsAsync(ct).ConfigureAwait(false);
            if (connection.Ledm is { } ledm)
            {
                foreach (var resource in LedmResources()) await Quietly(() => ledm.GetAsync(resource, ct)).ConfigureAwait(false);
                await Quietly(() => ledm.GetFirmwareUpdateAsync(ct)).ConfigureAwait(false);
            }
            if (connection.Cdm is { } cdm)
                foreach (var path in new[] { Cdm.CdmPaths.Identity, Cdm.CdmPaths.Supplies, Cdm.CdmPaths.SystemStatus, Cdm.CdmPaths.PrintStatus, Cdm.CdmPaths.Alerts })
                    await Quietly(() => connection.Http.GetBytesOrNullAsync(new Uri(cdm.Root, path), ct: ct)).ConfigureAwait(false);
            await Quietly(() => new Maintenance.MaintenanceClient(connection).DetectAsync(ct)).ConfigureAwait(false);
            if (connection.Scanner is { } scanner)
            {
                await Quietly(() => scanner.GetStatusAsync(ct)).ConfigureAwait(false);
                if (options.Scan) await ScanAsync(scanner, scans, notKept, ct).ConfigureAwait(false);
            }
            if (snmp is not null) await WalkSnmpAsync(snmp, host, options.Community, ct).ConfigureAwait(false);

            // The documents, by the names FixtureHandler serves them under.
            var documents = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            foreach (var x in capture.Exchanges)
            {
                if (x.File is null || documents.ContainsKey(x.File) && x.Ipp is null) continue;
                if (x.Ipp is not null && documents.TryGetValue(x.File, out var had) && had.Length >= x.Ipp.Length) continue; // the fullest attribute list
                documents[x.File] = x.Ipp ?? Encoding.UTF8.GetString(x.Body!);
            }
            if (snmp?.Objects is { Count: > 0 } objects)
                documents[SnmpFile] = $"# {(snmp.V2cAnswered ? "SNMP v2c and v1" : "SNMP v1 only (SnmpAgent v1Only: true)")}, community as recorded\n"
                                      + SnmpAgent.FormatWalk(objects.Select(Readable));

            if (documents.Count == 0) throw new InvalidOperationException($"Nothing answered at {host}.");
            var scrubber = new FixtureScrubber(host, options.PlaceholderHost, options.Who ?? Diagnostics.Identity.Current);
            foreach (var (name, text) in documents) scrubber.Learn(name, text);
            Directory.CreateDirectory(folder);
            var files = new List<string>();
            foreach (var (name, text) in documents.OrderBy(d => d.Key, StringComparer.Ordinal))
            {
                await File.WriteAllTextAsync(Path.Combine(folder, name), scrubber.Scrub(name, text), new UTF8Encoding(false), ct).ConfigureAwait(false);
                files.Add(name);
            }
            foreach (var (name, jpeg) in scans)
            {
                await File.WriteAllBytesAsync(Path.Combine(folder, name), jpeg, ct).ConfigureAwait(false);
                files.Add(name);
            }

            notKept.AddRange(capture.Exchanges.Where(x => x.File is null && x.Status is { } s && s != HttpStatusCode.NotFound && x.Kept != false)
                .Select(x => $"{x.Method} {x.Path}: {(int)x.Status!} {x.Status}, not kept (FixtureHandler serves documents only)"));
            var interfaces = probe.Interfaces.ToList();
            if (snmp?.Objects.Count > 0 && !interfaces.Contains("SNMP")) interfaces.Add("SNMP");
            var model = probe.Model ?? snmp?.Model;
            await File.WriteAllTextAsync(Path.Combine(folder, NotesFile), Notes(capture, snmp, interfaces, model, scrubber, notKept), new UTF8Encoding(false), ct)
                .ConfigureAwait(false);
            files.Add(NotesFile);
            return new RecordResult(files, interfaces, model, scrubber.Counts, notKept);
        }
    }

    /// <summary>The LEDM documents the app reads by type: status, supplies, usage, settings (with their Cap documents), events.</summary>
    private static IEnumerable<string> LedmResources() =>
        new[] { LedmResource.ProductStatusDyn, LedmResource.ProductConfigDyn, LedmResource.ProductConfigCap, LedmResource.ConsumableConfigDyn,
                LedmResource.ProductUsageDyn, LedmResource.PrintConfigDyn, LedmResource.PrintConfigCap, LedmResource.MediaHandlingDyn,
                LedmResource.MediaHandlingCap, LedmResource.EventTable, "ledm:hpLedmProductStatusCap", "ledm:hpLedmEventMgmtCap" }
            .Concat(LedmSettingCatalog.All.SelectMany(d => new[] { d.DynResource, d.CapResource }))
            .Distinct(StringComparer.Ordinal);

    private static async Task ScanAsync(EsclClient scanner, List<(string, byte[])> scans, List<string> notKept, CancellationToken ct)
    {
        var caps = await Quietly(() => scanner.GetCapabilitiesAsync(ct)).ConfigureAwait(false);
        if (caps is null) return;
        try
        {
            if (caps.Platen is not null)
                await foreach (var page in scanner.ScanAsync(new ScanRequest(ScanSource.Platen, Resolution: 150), ct).ConfigureAwait(false))
                    scans.Add(("scan-glass.jpg", page));
            if (caps.Adf is not null && (await scanner.GetStatusAsync(ct).ConfigureAwait(false)).AdfLoaded)
                await foreach (var page in scanner.ScanAsync(new ScanRequest(ScanSource.Adf, Resolution: 150), ct).ConfigureAwait(false))
                    scans.Add(($"scan-feeder-{scans.Count(s => s.Item1.StartsWith("scan-feeder", StringComparison.Ordinal)) + 1}.jpg", page));
        }
        catch (Exception ex) when (ex is ScanException or HttpRequestException or TimeoutException or DeviceHttpException or InvalidOperationException)
        {
            notKept.Add($"scan: {ex.Message}");
        }
    }

    private static async Task WalkSnmpAsync(SnmpCapture snmp, string host, string community, CancellationToken ct)
    {
        // As the app asks first: the probe (v2c and v1 at once). Then each subtree, one GetNext at a time.
        var printer = await SnmpPrinterClient.ProbeAsync(snmp, host, community, ct).ConfigureAwait(false);
        if (printer is null) return;
        snmp.Model = printer.Identity.Model;
        await Quietly(() => printer.ReadAsync(ct)).ConfigureAwait(false);
        var client = new SnmpClient(snmp, host, printer.Identity.Version, community);
        var started = Stopwatch.StartNew();
        foreach (var root in SnmpSubtrees)
        {
            var at = root;
            while (snmp.Objects.Count < MaxSnmpObjects && started.Elapsed < SnmpWalkLimit)
            {
                IReadOnlyList<SnmpVarBind> next;
                try { next = await client.GetNextAsync([at], ct).ConfigureAwait(false); }
                catch (Exception ex) when (ex is TimeoutException or SnmpErrorException or FormatException) { break; }
                if (next is not [var vb] || vb.Value.IsException || !vb.Name.IsUnder(root)) break;
                at = vb.Name;
            }
        }
    }

    /// <summary>
    /// A string the printer padded with NULs or broke over lines, as one line of text (the reader trims and splits on line
    /// breaks the same way), so it can be read and scrubbed as text; binary values stay bytes.
    /// </summary>
    private static SnmpVarBind Readable(SnmpVarBind vb)
    {
        if (vb.Value is not { Tag: Ber.OctetString, Bytes: { Length: > 0 } bytes } || vb.Value.Text is not { } text) return vb;
        var printable = bytes.All(b => b is >= 0x20 or 0x00 or 0x0A or 0x0D or 0x09);
        return printable ? vb with { Value = SnmpValue.String(text.ReplaceLineEndings("; ").Replace('\t', ' ')) } : vb;
    }

    private static string Notes(Capture capture, SnmpCapture? snmp, IReadOnlyList<string> interfaces, string? model, FixtureScrubber scrubber,
        IReadOnlyList<string> notKept)
    {
        var sb = new StringBuilder();
        sb.Append(CultureInfo.InvariantCulture, $"# Inkvolt Print recording, {DateTime.UtcNow:yyyy-MM-dd}: {model ?? "unknown model"}; answered on {string.Join(", ", interfaces)}\n");
        sb.Append("# Scrubbed (stand-ins of the same shape): ")
            .Append(scrubber.Counts.Count == 0 ? "nothing found" : string.Join(", ", scrubber.Counts.Select(kv => $"{kv.Key} {kv.Value}"))).Append('\n');
        sb.Append("# Every request, in order: milliseconds, method, path, status, file it is kept in\n");
        foreach (var x in capture.Exchanges)
            sb.Append(CultureInfo.InvariantCulture,
                $"{x.Milliseconds}\t{x.Method}{(x.Ipp is not null ? " Get-Printer-Attributes" : "")}\t{scrubber.Scrub("", x.Path)}\t{(x.Status is { } s ? ((int)s).ToString(CultureInfo.InvariantCulture) : x.Error)}\t{x.File ?? "-"}\n");
        if (snmp is not null)
            sb.Append(CultureInfo.InvariantCulture, $"{snmp.Milliseconds}\tSNMP\t{snmp.Requests} requests, {snmp.Replies} replies\t\t{(snmp.Objects.Count > 0 ? SnmpFile : "-")}\n");
        foreach (var line in notKept) sb.Append("# ").Append(scrubber.Scrub("", line)).Append('\n');
        return sb.ToString();
    }

    private static async Task<T?> Quietly<T>(Func<Task<T>> read)
    {
        try { return await read().ConfigureAwait(false); }
        catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex) || ex is InvalidOperationException) { return default; }
    }

    // ------------------------------------------------------------------------------------------------ the recording handler

    private sealed record Exchange(string Method, string Path, HttpStatusCode? Status, string? Error, long Milliseconds, string? File, byte[]? Body, string? Ipp)
    {
        /// <summary>False for scan traffic (pages and jobs), which isn't a document.</summary>
        public bool? Kept { get; init; }
    }

    /// <summary>Lets reads through and keeps each reply; refuses anything that would change the printer.</summary>
    private sealed class Capture(HttpMessageHandler inner, bool scan) : DelegatingHandler(inner)
    {
        private readonly ConcurrentQueue<Exchange> _exchanges = new();

        public IReadOnlyList<Exchange> Exchanges => [.. _exchanges];

        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var uri = request.RequestUri!;
            var path = uri.AbsolutePath;
            var body = request.Content is null ? null : await request.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            var ipp = request.Method == HttpMethod.Post && request.Content?.Headers.ContentType?.MediaType == "application/ipp";
            var getAttributes = ipp && body is { Length: >= 8 } && IppCodec.ReadRequestHeader(body).Operation == IppCodec.GetPrinterAttributes;
            var scanJob = scan && path.Contains("/ScanJobs", StringComparison.OrdinalIgnoreCase)
                          && (request.Method == HttpMethod.Post || request.Method == HttpMethod.Delete || request.Method == HttpMethod.Get);
            if (request.Method != HttpMethod.Get && !getAttributes && !scanJob)
                throw new InvalidOperationException($"A recording only reads: {request.Method} {path} not sent.");

            var timer = Stopwatch.StartNew();
            HttpResponseMessage resp;
            try
            {
                resp = await base.SendAsync(request, ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is HttpRequestException or OperationCanceledException)
            {
                _exchanges.Enqueue(new Exchange(request.Method.Method, path, null, ex is OperationCanceledException ? "timed out" : "no answer",
                    timer.ElapsedMilliseconds, null, null, null));
                throw;
            }
            var bytes = await resp.Content.ReadAsByteArrayAsync(ct).ConfigureAwait(false);
            var ms = timer.ElapsedMilliseconds;
            var copy = new ByteArrayContent(bytes);
            foreach (var h in resp.Content.Headers) copy.Headers.TryAddWithoutValidation(h.Key, h.Value);
            resp.Content.Dispose();
            resp.Content = copy;

            string? file = null, text = null;
            var type = resp.Content.Headers.ContentType?.MediaType ?? "";
            if (scanJob)
            {
                _exchanges.Enqueue(new Exchange(request.Method.Method, path, resp.StatusCode, null, ms, null, null, null) { Kept = false });
                return resp;
            }
            if (resp.StatusCode == HttpStatusCode.OK && getAttributes)
            {
                try
                {
                    if (IppCodec.Decode(bytes).Ok) (file, text) = (FixtureHandler.IppDocumentName(path), IppText.FromResponse(bytes));
                }
                catch (FormatException) { }
            }
            else if (resp.StatusCode == HttpStatusCode.OK && request.Method == HttpMethod.Get && bytes.Length > 0 && uri.Query.Length == 0
                     && !type.StartsWith("image/", StringComparison.OrdinalIgnoreCase) && path.Trim('/').Length > 0)
                file = FixtureHandler.DocumentName(path);
            _exchanges.Enqueue(new Exchange(request.Method.Method, path, resp.StatusCode, null, ms, file, bytes, text));
            return resp;
        }
    }

    /// <summary>Passes SNMP through and keeps every object a reply carried.</summary>
    private sealed class SnmpCapture(ISnmpTransport inner) : ISnmpTransport
    {
        private readonly ConcurrentDictionary<Oid, SnmpVarBind> _objects = new();
        private long _ticks;
        private int _requests, _replies;

        public IReadOnlyList<SnmpVarBind> Objects => [.. _objects.Values];
        public bool V2cAnswered { get; private set; }
        public string? Model { get; set; }
        public int Requests => _requests;
        public int Replies => _replies;
        public long Milliseconds => Interlocked.Read(ref _ticks) / TimeSpan.TicksPerMillisecond;

        public async Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct)
        {
            Interlocked.Increment(ref _requests);
            var started = Stopwatch.GetTimestamp();
            var reply = await inner.SendAsync(host, request, timeout, ct).ConfigureAwait(false);
            Interlocked.Add(ref _ticks, Stopwatch.GetElapsedTime(started).Ticks);
            if (reply is null) return null;
            Interlocked.Increment(ref _replies);
            try
            {
                var m = SnmpMessage.Decode(reply);
                if (m.Version == SnmpVersion.V2c) V2cAnswered = true;
                if (m.ErrorStatus == SnmpMessage.NoError)
                    foreach (var vb in m.VarBinds.Where(v => !v.Value.IsException && v.Value.Tag != Ber.Null)) _objects[vb.Name] = vb;
            }
            catch (FormatException) { }
            return reply;
        }
    }
}
