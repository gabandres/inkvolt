using System.IO;
using InkvoltPrint.App.Printing;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Photos;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Printing.Raster;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App;

/// <summary>
/// Developer check of roadmap 2.1 against a test printer, CUPS's <c>ippeveprinter</c> (in WSL:
/// <c>ippeveprinter -2 -k -d spool -f image/pwg-raster,image/urf,application/PCLm -p 8631 Test</c>), through the same code
/// Print a PDF, Copy and Print photos use: <c>InkvoltPrint.exe --direct-print ipp://127.0.0.1:8631/ipp/print</c> with
/// <c>--pdf file</c> (or <c>--sample-pdf n</c>, a made-up n-page PDF), <c>--copy</c> (two made-up scanned pages) or
/// <c>--photos</c> (the demo's sample pictures on a contact sheet), and <c>--format pwg|urf|pclm</c>, <c>--copies n</c>,
/// <c>--two-sided</c>, <c>--keep folder</c> (each raster is copied there before it's sent, to compare with what the printer
/// kept) and <c>--report file</c> (what happened, line by line). No window; exits 0 when the printer took the job.
/// <c>--batch file… [--copies n] [--two-sided] [--stop-after-seconds s]</c> runs Batch print's command line with the files going
/// straight to the printer (the report has its lines and exit code); <c>--watch-jobs n</c> reads the printer's job list n times,
/// 3 s apart, through job alerts' rules on a clock a minute on at each read (the report lists the jobs and the alerts raised).
/// <c>--direct-print --read-pclm file.pclm [--keep folder]</c> opens a kept PCLm file with Windows' own PDF engine instead.
/// </summary>
internal static class DevDirectPrint
{
    public const string Argument = "--direct-print";

    public static async Task<int> RunAsync(string[] args)
    {
        var report = new List<string>();
        var code = 1;
        try
        {
            if (args[1] == "--read-pclm")
            {
                // A kept PCLm file opened by Windows' own PDF engine, a reader that isn't ours: its pages and their sizes.
                var pclm = await PdfSource.OpenAsync(args[2]);
                for (var n = 1; n <= pclm.PageCount; n++)
                {
                    var (w, h) = pclm.PageSizeInches(n);
                    var drawn = await pclm.RenderAsync(n, 50);
                    report.Add($"page {n}: {w:0.##} x {h:0.##} in, drawn {drawn.Image.Length} bytes");
                    if (Value(args, "--keep") is { } folder) await File.WriteAllBytesAsync(Path.Combine(folder, $"pclm-page{n}.jpg"), drawn.Image);
                }
                report.Add("result: read");
                code = 0;
                return code;
            }
            var url = new Uri(args[1]);
            var endpoint = new UriBuilder(url.Scheme == "ipps" ? Uri.UriSchemeHttps : Uri.UriSchemeHttp, url.Host, url.Port, url.AbsolutePath).Uri;
            using var http = new DeviceHttp(url.Host);
            var target = PrintTarget.Direct.For(new IppClient(http, endpoint), Environment.UserName);
            DirectPrinter.KeepCopyIn = Value(args, "--keep");
            if (DirectPrinter.KeepCopyIn is { } keep) Directory.CreateDirectory(keep);
            DirectPrinter.OnlyFormat = Value(args, "--format") switch
            {
                "pwg" => RasterFormat.PwgRaster,
                "urf" => RasterFormat.Urf,
                "pclm" => RasterFormat.Pclm,
                _ => null,
            };
            var copies = int.TryParse(Value(args, "--copies"), out var c) ? c : 1;
            var twoSided = args.Contains("--two-sided");
            var progress = new Progress<string>(m => report.Add($"progress: {m}"));
            if (args.Contains("--batch"))
            {
                // Batch print's command line, its files sent straight to the printer (RoutedBatchQueue, DirectBatchQueue).
                var rest = args.SkipWhile(a => a != "--batch").Skip(1).ToList();
                var cut = rest.IndexOf("--report");
                if (cut >= 0) rest.RemoveRange(cut, Math.Min(2, rest.Count - cut));
                using var stop = new CancellationTokenSource();
                if (double.TryParse(Value(args, "--stop-after-seconds"), System.Globalization.CultureInfo.InvariantCulture, out var seconds))
                {
                    stop.CancelAfter(TimeSpan.FromSeconds(seconds));
                    rest.RemoveRange(rest.IndexOf("--stop-after-seconds"), 2);
                }
                var output = new StringWriter();
                var exit = await BatchPrintCommandLine.RunAsync(["print", .. rest, "--printer", "direct"], output, output, new DirectHost(target), stop.Token);
                report.AddRange(output.ToString().Split(Environment.NewLine, StringSplitOptions.RemoveEmptyEntries).Select(l => $"batch: {l}"));
                report.Add($"exit: {exit}");
            }
            else if (args.Contains("--watch-jobs"))
            {
                // Job alerts on the printer's own job list: a real read every few seconds, the rules' clock a minute on at each.
                var reads = int.TryParse(Value(args, "--watch-jobs"), out var n) ? n : 20;
                var tracker = new Core.Alerts.AlertTracker(new Core.Alerts.AlertRules { Jobs = true });
                var watch = new Core.Printing.Direct.DirectJobWatch();
                var clock = DateTimeOffset.Now;
                for (var i = 0; i < reads; i++, clock = clock.AddMinutes(1))
                {
                    var printer = await target.Ipp.GetPrinterAttributesAsync();
                    tracker.Observe(new Core.Alerts.PrinterSnapshot("test", "Test printer", true, IppClient.ToStatus(printer), []), clock);
                    var queue = await watch.ReadAsync(target.Ipp, target.User);
                    report.Add($"read {i}: {string.Join("; ", queue.Jobs.Select(j => $"job {j.Id} {j.Status} {j.PagesPrinted}/{j.Pages} {j.Owner} {j.Problem}"))}");
                    foreach (var notice in tracker.ObserveJobs("test", "Test printer", queue, Core.Alerts.JobOwner.Current, clock))
                        report.Add($"alert: {notice.Kind}: {notice.Title} | {notice.Body}");
                    await Task.Delay(TimeSpan.FromSeconds(3));
                }
            }
            else if (args.Contains("--copy"))
            {
                // Two "scans": a made-up PDF's pages drawn at 300 dpi, as a scanner's JPEGs would come in.
                var scans = await PdfSource.OpenAsync(BatchPrintSamples.Pdf(2, "Scanned"));
                var pages = new[] { await scans.RenderAsync(1, 300), await scans.RenderAsync(2, 300) };
                await PrintTargets.PrintCopyAsync(target, pages, copies, twoSided, collate: true, pagesPerSheet: 1, "copy", Core.Printing.PageSizing.ActualSize, progress);
            }
            else if (args.Contains("--photos"))
            {
                var photos = Demo.SamplePhotos().SelectMany(p => PhotoFiles.Read(p)).Select(s => new PhotoJobPhoto(s, 0, 1, new PhotoCrop(1, 0, 0))).ToList();
                var options = await PhotoPrinting.ReadOptionsAsync(target);
                var paper = options.Papers.FirstOrDefault(p => p.Key == options.DefaultPaper) ?? options.Papers[0];
                var settings = new PhotoJobSettings(paper, null, null, "Color", Borderless: false);
                var sheets = await PhotoPrinting.PrintAsync(target, settings, photos, new PhotoLayoutOptions { Kind = PhotoLayoutKind.ContactSheet, PerSheet = 6 }, "photos");
                report.Add($"sheets: {sheets}");
            }
            else
            {
                var path = Value(args, "--pdf") ?? Path.Combine(Path.GetTempPath(), "Inkvolt Print direct sample.pdf");
                if (Value(args, "--pdf") is null)
                    await File.WriteAllBytesAsync(path, BatchPrintSamples.Pdf(int.TryParse(Value(args, "--sample-pdf"), out var n) ? n : 3, "Sample"));
                var pdf = await PdfSource.OpenAsync(path);
                var pages = Enumerable.Range(1, pdf.PageCount).ToList();
                var printed = await PrintTargets.PrintPdfAsync(target, pdf, new PrintOptions(pages, copies, twoSided, "pdf"), progress, CancellationToken.None);
                report.Add($"printed: {printed}");
            }
            report.Add("result: sent");
            code = 0;
        }
        catch (Exception ex)
        {
            report.Add($"result: {ex.GetType().Name}: {ex.Message}");
        }
        finally
        {
            await Task.Delay(200); // the last progress lines
            if (Value(args, "--report") is { } file) await File.WriteAllLinesAsync(file, report);
        }
        return code;
    }

    /// <summary>The command line's printer, whatever its name: the test printer, straight.</summary>
    private sealed class DirectHost(PrintTarget.Direct target) : IBatchPrintHost
    {
        public IBatchDocuments Documents => WindowsBatchDocuments.Instance;

        public Task<IBatchQueue> FindPrinterAsync(string name, CancellationToken ct) =>
            Task.FromResult<IBatchQueue>(new RoutedBatchQueue(new WindowsBatchQueue(() => Task.FromResult<string?>(null)),
                () => Task.FromResult<PrintTarget?>(target), () => "Test printer"));
    }

    private static string? Value(string[] args, string name) =>
        Array.IndexOf(args, name) is var i and >= 0 && i + 1 < args.Length ? args[i + 1] : null;
}
