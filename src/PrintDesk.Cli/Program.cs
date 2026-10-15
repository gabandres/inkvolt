using System.Diagnostics;
using PrintDesk.Core.Escl;
using PrintDesk.Core.Ledm;
using PrintDesk.Core.Pdf;
using PrintDesk.Core.Probe;
using PrintDesk.Windows.Discovery;
using PrintDesk.Windows.Ocr;

// Developer CLI: exercises the same Core/Windows code the app uses, against a live printer.
var cmd = args.FirstOrDefault() ?? "help";
var host = args.ElementAtOrDefault(1);
using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
var ct = cts.Token;

switch (cmd)
{
    case "discover":
        await Discover();
        break;
    case "probe" when host is not null:
        await Probe(host);
        break;
    case "status" when host is not null:
        await Status(host);
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
    case "pair" when host is not null:
        Console.WriteLine(await PrintDesk.Windows.Queues.QueueInstaller.InstallAsync(host, ct));
        break;
    case "unpair" when host is not null:
        Console.WriteLine($"unpaired: {await PrintDesk.Windows.Queues.QueueInstaller.UninstallAsync(host, ct)}");
        break;
    case "pdf" when host is not null:
        {
            var pdf = await PrintDesk.Windows.Printing.PdfSource.OpenAsync(host);
            Console.WriteLine($"pages={pdf.PageCount} size1={pdf.PageSizeInches(1)}");
            var thumb = await pdf.RenderAsync(1, dpi: 0, maxWidthPx: 220);
            Console.WriteLine($"thumb bytes={thumb.Image.Length}");
            var full = await pdf.RenderAsync(2, dpi: 300);
            Console.WriteLine($"page2 300dpi bytes={full.Image.Length} {full.WidthInches}x{full.HeightInches}");
        }
        break;
    case "pdfbench" when host is not null:
        {
            var sw = Stopwatch.StartNew();
            var pdf = await PrintDesk.Windows.Printing.PdfSource.OpenAsync(host);
            long total = 0;
            for (var n = 1; n <= pdf.PageCount; n++) total += (await pdf.RenderAsync(n, 300)).Image.Length;
            Console.WriteLine($"{pdf.PageCount} pages rendered at 300 dpi in {sw.ElapsedMilliseconds} ms, {total / 1024 / 1024} MB of JPEG held in memory");
        }
        break;
    case "hp":
        foreach (var a in PrintDesk.Windows.Cleanup.HpSoftware.Find())
        {
            Console.WriteLine($"{a.DisplayName} | {a.FullName}");
            if (host == "remove") Console.WriteLine($"  remove: {await PrintDesk.Windows.Cleanup.HpSoftware.RemoveAsync(a) ?? "OK"}");
        }
        var left = await PrintDesk.Windows.Cleanup.HpLeftovers.FindAsync();
        Console.WriteLine($"leftovers: {(left.Any ? left.ToString() : "none")}");
        if (host == "remove" && left.Any) Console.WriteLine($"  remove leftovers: {await PrintDesk.Windows.Cleanup.HpLeftovers.RemoveAsync() ?? "OK"}");
        break;
    case "addipp" when host is not null && args.Length >= 3:
        Console.WriteLine(await PrintDesk.Windows.Queues.IppQueueInstaller.InstallAsync(args[2], new Uri(host)));
        foreach (var q in await PrintDesk.Windows.Printing.QueueFinder.ListAsync()) Console.WriteLine($"  {q.Name} | container={q.ContainerId}");
        break;
    case "queues":
        foreach (var q in await PrintDesk.Windows.Printing.QueueFinder.ListAsync()) Console.WriteLine($"{q.Name} | container={q.ContainerId}");
        break;
    case "ocr" when host is not null && args.Length >= 3:
        await Ocr(host, args[2], int.TryParse(Opt("--dpi"), out var odpi) ? odpi : 300);
        break;
    default:
        Console.WriteLine("""
            printdesk discover
            printdesk probe <host>
            printdesk status <host>
            printdesk watch <host>                      (LEDM event long-poll; Ctrl+C to stop)
            printdesk settings <host>                   (read-only)
            printdesk scan <host> <out.pdf|out.jpg> [--ocr] [--dpi 300]
            printdesk set <host> <key> <value>          (LEDM setting; PRINTDESK_ADMIN_PASSWORD env if needed)
            printdesk pair <endpoint-id> | unpair <endpoint-id>   (install / remove a Windows queue)
            printdesk ocr <in.jpg> <out.pdf> [--dpi 300]   (offline: OCR + searchable PDF from a JPEG)
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
    var status = await c.GetStatusAsync(ct);
    var supplies = await c.GetSuppliesAsync(ct);
    Console.WriteLine($"status ({sw.ElapsedMilliseconds} ms): {status.Message} [{status.Code}, {status.Severity}]");
    foreach (var a in status.Alerts) Console.WriteLine($"  alert: {a.Severity} {a.Message}");
    foreach (var s in supplies)
        Console.WriteLine($"  {s.Name}: {s.PercentRemaining}% {s.State} ~{s.EstimatedPagesRemaining} pages, {s.ProductNumber} ({s.SelectibilityNumber})");
    if (c.Ledm is not null && await c.Ledm.GetUsageAsync(ct) is { } u)
        Console.WriteLine($"  pages printed: {u.TotalImpressions}, scans: {u.ScanImages}, jams: {u.JamEvents}");
    if (c.Ipp is not null)
    {
        var ippStatus = Ipp(await c.Ipp.GetPrinterAttributesAsync(ct: ct));
        Console.WriteLine($"  via IPP: {ippStatus}");
    }

    static string Ipp(PrintDesk.Core.Ipp.IppResponse r) =>
        $"{PrintDesk.Core.Ipp.IppClient.ToStatus(r).Message}; " +
        string.Join(", ", PrintDesk.Core.Ipp.IppClient.ToConsumables(r).Select(s => $"{s.Name} {s.PercentRemaining}%"));
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
    if (Environment.GetEnvironmentVariable("PRINTDESK_ADMIN_PASSWORD") is { Length: > 0 } pw) c.Http.SetCredentials("admin", pw);
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
