using System.Diagnostics;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Pdf;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Windows.Discovery;
using InkvoltPrint.Windows.Ocr;

// Developer CLI: exercises the same Core/Windows code the app uses, against a live printer.
var cmd = args.FirstOrDefault() ?? "help";
var host = args.ElementAtOrDefault(1);
using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
var ct = cts.Token;
InkvoltPrint.Core.Escl.ScannerPdf.Renderer = new InkvoltPrint.Windows.Printing.ScannedPdfPages(); // PDF-only scanners, as the app

switch (cmd)
{
    case "discover":
        await Discover();
        break;
    case "probe" when host is not null:
        await Probe(host);
        break;
    case "status" when InkvoltPrint.Core.Fleet.FleetCommand.IsFor(args) && (host is null || host.StartsWith("--", StringComparison.Ordinal)):
        {
            // Every printer at once, as the app's own "status --all" (Inkvolt Pro).
            var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            var pc = new InkvoltPrint.Windows.Fleet.WindowsFleetPc(local);
            InkvoltPrint.Core.Pro.Store = pc.ProStore(local);
            Environment.Exit(await InkvoltPrint.Core.Fleet.FleetCommand.RunAsync(args, Console.Out, Console.Error, pc, () => DateTimeOffset.Now,
                InkvoltPrint.Core.Suite.Diagnostics.Identity.Current, ct));
            break;
        }
    case "status" when host is not null:
        await Status(host);
        break;
    case "snmp" when host is not null:
        await Snmp(host, Opt("--community") ?? InkvoltPrint.Core.Snmp.SnmpClient.DefaultCommunity, args.Contains("--walk"));
        break;
    case "record" when host is not null && args.Length >= 3:
        await Record(host, args[2]);
        break;
    case "watch" when host is not null:
        await Watch(host);
        break;
    case "settings" when host is not null:
        await Settings(host);
        break;
    case "scan" when host is not null && args.Length >= 3:
        await Scan(host, args[2], args.Contains("--ocr"), int.TryParse(Opt("--dpi"), out var dpi) ? dpi : 300);
        break;
    case "set" when host is not null && args.Length >= 4:
        await Set(host, args[2], args[3]);
        break;
    case "spooler":
        await SpoolerQueues();
        break;
    case "offline" when host is not null:
        await Offline(host, args.ElementAtOrDefault(2));
        break;
    case "pair" when host is not null:
        Console.WriteLine(await InkvoltPrint.Windows.Queues.QueueInstaller.InstallAsync(host, ct));
        break;
    case "unpair" when host is not null:
        Console.WriteLine($"unpaired: {await InkvoltPrint.Windows.Queues.QueueInstaller.UninstallAsync(host, ct)}");
        break;
    case "pdf" when host is not null:
        {
            var pdf = await InkvoltPrint.Windows.Printing.PdfSource.OpenAsync(host);
            Console.WriteLine($"pages={pdf.PageCount} size1={pdf.PageSizeInches(1)}");
            var thumb = await pdf.RenderAsync(1, dpi: 0, maxWidthPx: 220);
            Console.WriteLine($"thumb bytes={thumb.Image.Length}");
            var full = await pdf.RenderAsync(2, dpi: 300);
            Console.WriteLine($"page2 300dpi bytes={full.Image.Length} {full.WidthInches}x{full.HeightInches}");
        }
        break;
    case "scanpdf" when host is not null:
        {
            // Offline: a scanner's PDF as the Scan tab gets it (pictures taken out as they are, else drawn by Windows' PDF engine).
            var bytes = await File.ReadAllBytesAsync(host, ct);
            var dpiArg = int.TryParse(Opt("--dpi"), out var sd) ? sd : 300;
            var sw = Stopwatch.StartNew();
            var pages = await InkvoltPrint.Core.Escl.ScannerPdf.PagesAsync(bytes, dpiArg, ct);
            foreach (var (page, n) in pages.Select((p, i) => (p, i + 1)))
            {
                var (w, h, comps) = PdfWriter.JpegInfo(page);
                Console.WriteLine($"page {n}: {w}x{h}, {comps} channel(s), {page.Length} bytes, {(InkvoltPrint.Core.Escl.ScannerPdf.OriginOf(page)!.Rendered ? $"drawn at {dpiArg} dpi" : "taken out as it is")}");
            }
            Console.WriteLine($"{pages.Count} pages in {sw.ElapsedMilliseconds} ms");
        }
        break;
    case "pdfbench" when host is not null:
        {
            var sw = Stopwatch.StartNew();
            var pdf = await InkvoltPrint.Windows.Printing.PdfSource.OpenAsync(host);
            long total = 0;
            for (var n = 1; n <= pdf.PageCount; n++) total += (await pdf.RenderAsync(n, 300)).Image.Length;
            Console.WriteLine($"{pdf.PageCount} pages rendered at 300 dpi in {sw.ElapsedMilliseconds} ms, {total / 1024 / 1024} MB of JPEG held in memory");
        }
        break;
    case "hp":
        foreach (var a in InkvoltPrint.Windows.Cleanup.HpSoftware.Find())
        {
            Console.WriteLine($"{a.DisplayName} | {a.FullName}");
            if (host == "remove") Console.WriteLine($"  remove: {await InkvoltPrint.Windows.Cleanup.HpSoftware.RemoveAsync(a) ?? "OK"}");
        }
        var left = await InkvoltPrint.Windows.Cleanup.HpLeftovers.FindAsync();
        Console.WriteLine($"leftovers: {(left.Any ? left.ToString() : "none")}");
        if (host == "remove" && left.Any) Console.WriteLine($"  remove leftovers: {await InkvoltPrint.Windows.Cleanup.HpLeftovers.RemoveAsync() ?? "OK"}");
        break;
    case "addipp" when host is not null && args.Length >= 3:
        Console.WriteLine(await InkvoltPrint.Windows.Queues.IppQueueInstaller.InstallAsync(args[2], new Uri(host)));
        foreach (var q in await InkvoltPrint.Windows.Printing.QueueFinder.ListAsync()) Console.WriteLine($"  {q.Name} | container={q.ContainerId}");
        break;
    case "queues":
        // Read-only: each installed queue as the app's sidebar sees it (virtual or not, connection, status from the spooler).
        foreach (var q in await InkvoltPrint.Windows.Printing.InstalledQueues.ListAsync(_ => true))
        {
            var status = InkvoltPrint.Core.Queues.SpoolerStatus.Describe(q).Status;
            Console.WriteLine($"{q.Name} | {(InkvoltPrint.Core.Queues.QueueKinds.IsVirtual(q) ? "virtual, left out" : InkvoltPrint.Core.Queues.QueueKinds.ConnectionText(q))} | " +
                              $"{status.Message}{string.Concat(status.Alerts.Select(a => $"; {a.Message}"))} | port={q.PortName} monitor={q.PortMonitor} " +
                              $"driver={q.DriverName} status=0x{q.Status:X} attributes=0x{q.Attributes:X} container={q.ContainerId}");
        }
        break;
    case "scanners":
        // Read-only: the WIA scanners Windows has drivers for; --caps connects to each and prints what it offers (never scans).
        foreach (var d in await InkvoltPrint.Windows.Scanning.WindowsWia.Instance.ListScannersAsync(ct))
        {
            Console.WriteLine($"{d.Name} | maker={d.Manufacturer} | port={d.Port}{(d.IsEscl ? " (Windows' eSCL driver)" : "")}");
            if (!args.Contains("--caps")) continue;
            try
            {
                var w = await InkvoltPrint.Core.Wia.WiaScanner.OpenAsync(InkvoltPrint.Windows.Scanning.WindowsWia.Instance, d, ct);
                var c = w.Capabilities;
                Console.WriteLine($"  sources: {string.Join(", ", c.Sources)}; colors: {string.Join(", ", (c.Platen ?? c.Adf)!.ColorModes)}; " +
                                  $"resolutions: {string.Join(", ", (c.Platen ?? c.Adf)!.Resolutions)}; formats: {string.Join(", ", w.Info.Formats)}");
                Console.WriteLine($"  handling=0x{w.Info.Handling ?? 0:X} glass={w.Info.BedWidth}x{w.Info.BedHeight} feeder={w.Info.FeederWidth}x{w.Info.FeederHeight} (1/1000 in)");
            }
            catch (InkvoltPrint.Core.Wia.WiaException ex)
            {
                Console.WriteLine($"  can't connect: {InkvoltPrint.Core.Wia.WiaErrors.Message(ex.Code, false)} (0x{ex.Code:X8})");
            }
        }
        break;
    case "ocr" when host is not null && args.Length >= 3:
        await Ocr(host, args[2], int.TryParse(Opt("--dpi"), out var odpi) ? odpi : 300);
        break;
    case "separator-sheet" when host is not null:
        // Offline: the batch scanning separator sheet as a PDF ("host" is the output file here).
        using (var fs = File.Create(host))
            SeparatorSheet.Write(fs, Enum.TryParse<InkvoltPrint.Core.Imaging.PatchCode>(Opt("--patch") is { } p ? "Patch" + p : "PatchT", true, out var patch)
                ? patch : InkvoltPrint.Core.Imaging.PatchCode.PatchT, args.Contains("--a4") ? 210 / 25.4 : 8.5, args.Contains("--a4") ? 297 / 25.4 : 11);
        Console.WriteLine($"Wrote {host}");
        break;
    case "print":
        // Printing draws with WPF, which this developer CLI doesn't load: the app's own command line does it (the Store's inkvoltprint alias is the app).
        Console.Error.WriteLine("Batch printing runs from the app: InkvoltPrint.exe print --help.");
        Environment.ExitCode = InkvoltPrint.Core.Printing.BatchPrintSummary.Wrong;
        break;
    default:
        Console.WriteLine("""
            inkvoltprint discover
            inkvoltprint probe <host>
            inkvoltprint status <host>
            inkvoltprint status --all [--json] [--out file]   (read-only: every printer, most trouble first; Inkvolt Pro)
            inkvoltprint watch <host>                      (LEDM event long-poll; Ctrl+C to stop)
            inkvoltprint settings <host>                   (read-only)
            inkvoltprint spooler                           (read-only: spooler, Windows queues, ports, jobs)
            inkvoltprint offline <uuid> [last-host]        (read-only: the offline fixer's diagnosis and repairs it would offer)
            inkvoltprint scan <host> <out.pdf|out.jpg> [--ocr] [--dpi 300]
            inkvoltprint set <host> <key> <value>          (LEDM setting; INKVOLTPRINT_ADMIN_PASSWORD env if needed)
            inkvoltprint queues                            (read-only: installed queues as the sidebar sees them)
            inkvoltprint scanners [--caps]                 (read-only: WIA scanners; --caps connects and reads what each offers)
            inkvoltprint snmp <host> [--community c] [--walk]   (read-only SNMP GETs: Printer MIB status, alerts, supplies)
            inkvoltprint record <host> <folder> [--scan] [--community c] [--escl url] [--ipp url] [--force]
                                                           (read-only: every reply the app reads, scrubbed, as test fixtures)
            inkvoltprint pair <endpoint-id> | unpair <endpoint-id>   (install / remove a Windows queue)
            inkvoltprint ocr <in.jpg> <out.pdf> [--dpi 300]   (offline: OCR + searchable PDF from a JPEG)
            inkvoltprint scanpdf <in.pdf> [--dpi 300]      (offline: a scanner's PDF as the Scan tab takes its pages)
            inkvoltprint separator-sheet <out.pdf> [--patch T|2|3] [--a4]   (offline: printable batch scanning separator sheet)
            InkvoltPrint.exe print --help                  (the app's own command line: print a saved list or a folder)
            """);
        break;
}

string? Opt(string name) => args.SkipWhile(a => a != name).Skip(1).FirstOrDefault();

async Task Discover()
{
    using var d = new PrinterDiscovery();
    var done = new TaskCompletionSource();
    var sw = Stopwatch.StartNew();
    d.Changed += list => Console.WriteLine($"[{sw.ElapsedMilliseconds,5} ms] {list.Count} printer(s)");
    d.InitialSweepCompleted += () => { Console.WriteLine($"[{sw.ElapsedMilliseconds,5} ms] initial sweep complete"); done.TrySetResult(); };
    d.Start();
    await Task.WhenAny(done.Task, Task.Delay(TimeSpan.FromSeconds(Opt("--wait") is { } w ? int.Parse(w) : 8), ct));
    await Task.Delay(1500, ct); // let late mDNS answers land
    foreach (var p in d.Snapshot())
        Console.WriteLine($"""
            {p.Name}  [{p.Uuid}]
              model={p.Model} host={p.Host} ({p.HostName}) escl={p.EsclRoot}
              queue: endpoint={p.PrintEndpointId ?? "-"} installed={p.QueueInstalled}   scanner: endpoint={p.ScanEndpointId ?? "-"} installed={p.ScannerInstalled}
            """);
}

async Task Probe(string h)
{
    var sw = Stopwatch.StartNew();
    using var c = await PrinterConnection.OpenAsync(h, ct: ct);
    var p = c.Probe;
    Console.WriteLine($"probed in {sw.ElapsedMilliseconds} ms: reachable={p.Reachable} interfaces={string.Join(",", p.Interfaces)}");
    Console.WriteLine($"model={p.Model} uuid={p.Uuid} escl={p.EsclRoot}");
    if (p.Ipp is { } ipp) Console.WriteLine($"ipp formats: {string.Join(", ", ipp.Strs("document-format-supported"))}");
}

async Task Status(string h)
{
    using var c = await PrinterConnection.OpenAsync(h, ct: ct);
    var sw = Stopwatch.StartNew();
    var reading = await c.ReadAsync(ct);
    var status = reading.Status;
    Console.WriteLine($"status ({sw.ElapsedMilliseconds} ms): {status.Message} [{status.Code}, {status.Severity}]");
    foreach (var a in status.Alerts) Console.WriteLine($"  alert: {a.Severity} {a.Message}");
    foreach (var s in reading.Supplies ?? [])
        Console.WriteLine($"  {s.Name}: {s.PercentRemaining}% {s.State} ~{s.EstimatedPagesRemaining} pages, {s.ProductNumber} ({s.SelectibilityNumber})");
    if (reading.Usage is { } u)
        Console.WriteLine($"  pages printed: {u.TotalImpressions}, scans: {u.ScanImages}, jams: {u.JamEvents}");
    if (c.Ipp is not null) // a diagnostic: what IPP says, beside what the reading took from LEDM or CDM
    {
        var ippStatus = Ipp(await c.Ipp.GetPrinterAttributesAsync(ct: ct));
        Console.WriteLine($"  via IPP: {ippStatus}");
    }

    static string Ipp(InkvoltPrint.Core.Ipp.IppResponse r) =>
        $"{InkvoltPrint.Core.Ipp.IppClient.ToStatus(r).Message}; " +
        string.Join(", ", InkvoltPrint.Core.Ipp.IppClient.ToConsumables(r).Select(s => $"{s.Name} {s.PercentRemaining}%"));
}

// Read only: Get, GetNext and GetBulk (SnmpClient can't send a Set). --walk also lists the Printer MIB objects read.
async Task Snmp(string h, string community, bool walk)
{
    var transport = InkvoltPrint.Core.Snmp.UdpSnmpTransport.Instance;
    var sw = Stopwatch.StartNew();
    var printer = await InkvoltPrint.Core.Snmp.SnmpPrinterClient.ProbeAsync(transport, h, community, ct);
    if (printer is null) { Console.WriteLine($"no SNMP printer answered ({sw.ElapsedMilliseconds} ms)"); return; }
    var id = printer.Identity;
    Console.WriteLine($"SNMP {id.Version}, device index {id.DeviceIndex}, probed in {sw.ElapsedMilliseconds} ms: model={id.Model}");
    sw.Restart();
    var reading = await printer.ReadAsync(ct);
    Console.WriteLine($"read in {sw.ElapsedMilliseconds} ms: hrDeviceStatus={reading.DeviceStatus} hrPrinterStatus={reading.PrinterStatus} " +
                      $"hrPrinterDetectedErrorState={Convert.ToHexString(reading.DetectedErrorState)}");
    foreach (var a in reading.Alerts) Console.WriteLine($"  prtAlert {a.Index}: severity={a.Severity} group={a.Group}/{a.GroupIndex} code={a.Code} \"{a.Description}\"");
    foreach (var s in reading.Supplies) Console.WriteLine($"  prtMarkerSupplies {s.Index}: class={s.Class} type={s.Type} \"{s.Description}\" {s.Level}/{s.MaxCapacity} colorant={s.ColorantIndex}");
    var status = InkvoltPrint.Core.Snmp.SnmpPrinterStatus.ToStatus(reading);
    Console.WriteLine($"status: {status.Message} [{status.Code}, {status.Severity}]");
    foreach (var a in status.Alerts) Console.WriteLine($"  alert: {a.Severity} {a.Id}: {a.Message}");
    foreach (var c in InkvoltPrint.Core.Snmp.SnmpPrinterStatus.ToConsumables(reading))
        Console.WriteLine($"  {c.Name} ({c.Kind}, {c.ColorCode}): {c.PercentRemaining}% {c.State}");
    if (!walk) return;
    var client = new InkvoltPrint.Core.Snmp.SnmpClient(transport, h, id.Version, community);
    foreach (var column in await client.WalkAsync([InkvoltPrint.Core.Snmp.Oid.Parse("1.3.6.1.2.1.43.11"), InkvoltPrint.Core.Snmp.Oid.Parse("1.3.6.1.2.1.43.18")], ct))
        foreach (var (index, value) in column) Console.WriteLine($"  .{string.Join('.', index)} = {value}");
}

async Task Record(string h, string folder)
{
    if (Directory.Exists(folder) && Directory.EnumerateFileSystemEntries(folder).Any() && !args.Contains("--force"))
    {
        Console.WriteLine($"{folder} isn't empty: choose a new folder, or add --force to write into it.");
        return;
    }
    var sw = Stopwatch.StartNew();
    InkvoltPrint.Core.Recording.RecordResult result;
    try
    {
        result = await InkvoltPrint.Core.Recording.PrinterRecorder.RecordAsync(h, folder, Options(), ct);
    }
    catch (InvalidOperationException ex)
    {
        Console.WriteLine($"Nothing recorded: {ex.Message}");
        return;
    }
    Console.WriteLine($"Recorded {result.Model ?? "the printer"} ({string.Join(", ", result.Interfaces)}) in {sw.ElapsedMilliseconds} ms: {result.Files.Count} files in {folder}");
    foreach (var f in result.Files) Console.WriteLine($"  {f}");
    Console.WriteLine($"Scrubbed: {(result.Scrubbed.Count == 0 ? "nothing found" : string.Join(", ", result.Scrubbed.Select(kv => $"{kv.Key} {kv.Value}")))}");
    foreach (var n in result.NotKept) Console.WriteLine($"  {n}");
    Console.WriteLine($"Served as the printer at {InkvoltPrint.Core.Recording.FixtureScrubber.DefaultPlaceholderHost}. Read the files before sharing them" +
                      (args.Contains("--scan") ? "; the scanned pages are kept as they are." : "."));

    InkvoltPrint.Core.Recording.RecordOptions Options() => new()
    {
        Snmp = InkvoltPrint.Core.Snmp.UdpSnmpTransport.Instance,
        Community = Opt("--community") ?? InkvoltPrint.Core.Snmp.SnmpClient.DefaultCommunity,
        EsclHint = Opt("--escl") is { } e ? new Uri(e) : null,
        IppHint = Opt("--ipp") is { } i ? new Uri(i) : null,
        Scan = args.Contains("--scan"),
    };
}

async Task Watch(string h)
{
    using var c = await PrinterConnection.OpenAsync(h, ct: ct);
    var sw = Stopwatch.StartNew();
    try
    {
        await foreach (var why in c.WatchAsync(TimeSpan.FromSeconds(30), ct))
        {
            var s = await c.GetStatusAsync(ct);
            Console.WriteLine($"[{sw.Elapsed:mm\\:ss}] {why}: {s.Message}");
        }
    }
    catch (OperationCanceledException) { }
}

async Task Settings(string h)
{
    using var c = await PrinterConnection.OpenAsync(h, ct: ct);
    if (c.Ledm is null) { Console.WriteLine("No LEDM on this printer."); return; }
    foreach (var (dyn, cap) in new[] { (LedmResource.ProductConfigDyn, LedmResource.ProductConfigCap), (LedmResource.PrintConfigDyn, LedmResource.PrintConfigCap), (LedmResource.MediaHandlingDyn, LedmResource.MediaHandlingCap) })
    {
        var d = await c.Ledm.GetAsync(dyn, ct);
        if (d is null) continue;
        var capDoc = await c.Ledm.GetAsync(cap, ct);
        foreach (var s in LedmSettingCatalog.Read(LedmSettingCatalog.All.Where(x => x.DynResource == dyn), d, capDoc))
            Console.WriteLine($"  [{s.Def.Group}] {s.Def.Label}: {s.Display(s.Value)}" +
                              (s.Choices.Count > 0 ? $"   ({string.Join(" | ", s.Choices.Select(s.Display))})" : ""));
    }
}

async Task Scan(string h, string output, bool ocr, int resolution)
{
    using var c = await PrinterConnection.OpenAsync(h, ct: ct);
    if (c.Scanner is null) { Console.WriteLine("No eSCL scanner."); return; }
    var sw = Stopwatch.StartNew();
    var pages = new List<PdfPage>();
    await foreach (var jpeg in c.Scanner.ScanAsync(new ScanRequest(Resolution: resolution), ct))
    {
        Console.WriteLine($"page {pages.Count + 1}: {jpeg.Length / 1024} KB at {sw.ElapsedMilliseconds} ms");
        var words = ocr ? await WindowsOcr.RecognizeAsync(jpeg, resolution, ct) : null;
        if (words is not null) Console.WriteLine($"  OCR: {words.Count} words ({sw.ElapsedMilliseconds} ms) \"{string.Join(' ', words.Take(8).Select(w => w.Text))}…\"");
        pages.Add(new PdfPage(jpeg, resolution, words));
    }
    if (output.EndsWith(".jpg", StringComparison.OrdinalIgnoreCase)) await File.WriteAllBytesAsync(output, pages[0].Jpeg, ct);
    else
    {
        await using var f = File.Create(output);
        PdfWriter.Write(f, pages, Path.GetFileNameWithoutExtension(output));
    }
    Console.WriteLine($"saved {output} ({new FileInfo(output).Length / 1024} KB) in {sw.ElapsedMilliseconds} ms");
}

async Task Ocr(string input, string output, int resolution)
{
    var sw = Stopwatch.StartNew();
    var jpeg = await File.ReadAllBytesAsync(input, ct);
    var words = await WindowsOcr.RecognizeAsync(jpeg, resolution, ct);
    Console.WriteLine($"OCR: {words.Count} words in {sw.ElapsedMilliseconds} ms: \"{string.Join(' ', words.Take(12).Select(w => w.Text))}\"");
    await using var f = File.Create(output);
    PdfWriter.Write(f, [new PdfPage(jpeg, resolution, words)], Path.GetFileNameWithoutExtension(output));
}

async Task Set(string h, string key, string value)
{
    using var c = await PrinterConnection.OpenAsync(h, ct: ct);
    if (c.Ledm is null) { Console.WriteLine("No LEDM on this printer."); return; }
    var def = LedmSettingCatalog.All.FirstOrDefault(d => d.Key.Equals(key, StringComparison.OrdinalIgnoreCase))
        ?? throw new ArgumentException($"Unknown setting. Known: {string.Join(", ", LedmSettingCatalog.All.Select(d => d.Key))}");
    if (Environment.GetEnvironmentVariable("INKVOLTPRINT_ADMIN_PASSWORD") is { Length: > 0 } pw) c.Http.SetCredentials("admin", pw);
    var dyn = await c.Ledm.GetAsync(def.DynResource, ct) ?? throw new InvalidOperationException("Resource missing");
    var before = LedmSettingCatalog.Read([def], dyn, await c.Ledm.GetAsync(def.CapResource, ct)).Single();
    try
    {
        await c.Ledm.PutAsync(def.DynResource, LedmSettingCatalog.BuildPut(dyn, [(def, value)]), ct);
    }
    catch (LedmAuthRequiredException ex)
    {
        Console.WriteLine(ex.Message);
        return;
    }
    var after = LedmSettingCatalog.Read([def], (await c.Ledm.GetAsync(def.DynResource, ct))!, null).SingleOrDefault()?.Value
        ?? (await c.Ledm.GetAsync(def.DynResource, ct))!.Descendants().First(e => e.Name.LocalName == def.Path[^1]).Value;
    Console.WriteLine($"{def.Label}: \"{before.Value}\" -> \"{after}\"");
}

// Read-only: the offline fixer's view of this PC's spooler and queues (no repairs from the CLI).
async Task SpoolerQueues()
{
    var probes = new InkvoltPrint.Windows.Offline.WindowsOfflineProbes();
    Console.WriteLine($"spooler: {await probes.SpoolerAsync(ct)}");
    foreach (var q in await probes.QueuesAsync(ct))
        Console.WriteLine($"{q.Name}: {q.Port.Kind} port={q.Port.Name} host={q.Port.Host} raw={q.Port.PortNumber} lpr={q.Port.Lpr} snmp={q.Port.Snmp} " +
                          $"container={(q.ContainerId is null ? "-" : "yes")} paused={q.Paused} workOffline={q.WorkOffline} offline={q.ReportsOffline} " +
                          $"error={q.ReportsError} jobs={q.Jobs.Count}");
}

// Read-only: runs the offline fixer's diagnosis for a printer UUID (and its last known address) and lists the repairs it would offer.
async Task Offline(string uuid, string? lastHost)
{
    var device = new InkvoltPrint.Core.Offline.OfflineDevice(uuid, "printer", null, lastHost);
    var report = await InkvoltPrint.Core.Offline.OfflineDiagnosis.RunAsync(device, new InkvoltPrint.Windows.Offline.WindowsOfflineProbes(),
        new Progress<InkvoltPrint.Core.Offline.CheckResult>(r => Console.WriteLine($"  {r.Kind}: {r.State}")), ct: ct);
    foreach (var c in report.Checks) Console.WriteLine($"{c.Title}: {c.State}\n    {c.Detail.Replace("\n", "\n    ")}");
    Console.WriteLine($"{report.Headline}. {report.Advice}");
    foreach (var r in report.Repairs) Console.WriteLine($"  repair: {r.Title}{(r.AdminOnly ? " (admin)" : "")}{(r.ManualOnly ? " (steps only)" : "")}");
}
