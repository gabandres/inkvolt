using System.IO;
using System.Printing;
using System.Windows.Threading;
using InkvoltPrint.Core.Photos;
using InkvoltPrint.Core.Printing;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.App.Printing;

/// <summary>
/// Batch print's files: PDFs through Windows' PDF engine, pictures through WIC, each held open (<see cref="BatchHeldFile"/>) so what
/// was fingerprinted is what's drawn. What a file is comes from its first bytes, not its name. A picture's size and pages are read
/// from its headers and checked against <see cref="BatchPrintLimits"/> before any pixel is decoded; Windows' PDF engine caps a
/// page at 50 MP (<see cref="PdfSource.RenderAsync"/>). The runner's timeouts cover an engine that hangs on a hostile file.
/// </summary>
public sealed class WindowsBatchDocuments : IBatchDocuments
{
    public static readonly WindowsBatchDocuments Instance = new();

    /// <summary>A picture is drawn no longer than this on its long side: 14 in at 300 dpi, more than Legal paper shows.</summary>
    private const int MaxEdge = 4200;

    public async Task<IBatchDocument> OpenAsync(string path, string? password, CancellationToken ct)
    {
        var held = await BatchHeldFile.OpenAsync(path, ct).ConfigureAwait(false);
        try
        {
            if (await IsPdfAsync(held.Stream, ct).ConfigureAwait(false))
            {
                try
                {
                    return new PdfDocument(held, await PdfSource.OpenAsync(held.Stream, path, password).ConfigureAwait(false));
                }
                catch (PdfOpenException ex) when (ex.IsPasswordProtected)
                {
                    throw new BatchPasswordException();
                }
                catch (PdfOpenException ex)
                {
                    throw new BatchFileException(ex.IsUnsupportedLock ? ex.Message : Strings.Print_PdfUnreadable);
                }
            }
            if (PhotoFiles.MissingCodec(path) is { } missing) throw new BatchFileException(missing);
            var pictures = await StaThread.RunAsync(() =>
            {
                try
                {
                    return PhotoFiles.Read(path, BatchPrintLimits.MaxPages);
                }
                catch (InvalidDataException ex)
                {
                    throw new BatchFileException(ex.Message);
                }
                catch (Exception ex) when (ex is not BatchFileException)
                {
                    throw new BatchFileException(Strings.Print_PictureUnreadable);
                }
            }).ConfigureAwait(false);
            foreach (var picture in pictures)
                if (BatchPrintLimits.PictureProblem(picture.PixelWidth, picture.PixelHeight) is { } tooLarge) throw new BatchFileException(tooLarge);
            return new PictureDocument(held, pictures);
        }
        catch
        {
            held.Dispose();
            throw;
        }
    }

    /// <summary>"%PDF-" in the first kilobyte, where the format allows it to start.</summary>
    private static async Task<bool> IsPdfAsync(Stream file, CancellationToken ct)
    {
        var head = new byte[1024];
        file.Position = 0;
        var read = await file.ReadAtLeastAsync(head, head.Length, throwOnEndOfStream: false, ct).ConfigureAwait(false);
        file.Position = 0;
        return head.AsSpan(0, read).IndexOf("%PDF-"u8) >= 0;
    }

    private sealed class PdfDocument(BatchHeldFile held, PdfSource pdf) : IBatchDocument
    {
        public BatchFingerprint Fingerprint => held.Fingerprint;
        public int PageCount => pdf.PageCount;
        public PageSizing Sizing => PageSizing.ActualSize;

        public async Task<BatchPrintPage> RenderAsync(int page, CancellationToken ct)
        {
            try
            {
                var rendered = await Task.Run(() => pdf.RenderAsync(page, QueuePrinter.RenderDpi, ct: ct), ct).ConfigureAwait(false);
                return new BatchPrintPage(rendered.Image, rendered.WidthInches, rendered.HeightInches);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                Log.Write($"Batch: a page wasn't drawn: {ex.Message}");
                throw new BatchFileException(string.Format(Strings.Print_PdfPageNotDrawn, page));
            }
        }

        public void Dispose() => held.Dispose();
    }

    private sealed class PictureDocument(BatchHeldFile held, IReadOnlyList<PhotoSource> pictures) : IBatchDocument
    {
        public BatchFingerprint Fingerprint => held.Fingerprint;
        public int PageCount => pictures.Count;
        public PageSizing Sizing => PageSizing.FitToPaper;

        public async Task<BatchPrintPage> RenderAsync(int page, CancellationToken ct)
        {
            ct.ThrowIfCancellationRequested();
            var picture = pictures[page - 1];
            try
            {
                return await StaThread.RunAsync(() =>
                {
                    var longest = Math.Max(picture.PixelWidth, picture.PixelHeight);
                    var width = longest > MaxEdge ? Math.Max(1, (int)(picture.PixelWidth * (double)MaxEdge / longest)) : 0;
                    var (w, h) = ExifOrientation.Oriented(picture.PixelWidth, picture.PixelHeight, picture.Orientation, 0);
                    return new BatchPrintPage(PhotoFiles.ForPrintJpeg(picture, width, upright: true), w / 300.0, h / 300.0);
                }).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                Log.Write($"Batch: a picture wasn't drawn: {ex.Message}");
                throw new BatchFileException(pictures.Count > 1 ? string.Format(Strings.Print_PicturePageNotDrawn, page) : Strings.Print_PictureNotDrawn);
            }
        }

        public void Dispose() => held.Dispose();
    }
}

/// <summary>Runs a call on an STA thread of its own: what WPF's imaging and drawing want, and it may block without holding up anything else.</summary>
internal static class StaThread
{
    public static Task<T> RunAsync<T>(Func<T> work)
    {
        var done = new TaskCompletionSource<T>(TaskCreationOptions.RunContinuationsAsynchronously);
        var thread = new Thread(() =>
        {
            try
            {
                done.SetResult(work());
            }
            catch (Exception ex)
            {
                done.SetException(ex);
            }
            finally
            {
                Dispatcher.CurrentDispatcher.InvokeShutdown();
            }
        })
        { IsBackground = true, Name = "Inkvolt Print batch" };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        return done.Task;
    }
}

/// <summary>
/// A batch's jobs through the printer's Windows queue, the same XPS path as Print a PDF (<see cref="QueuePrinter"/>). Each job's ticket
/// is checked before anything's drawn and again as it's spooled: a driver that wouldn't keep the copies, the side or the paper
/// fails that file, never prints something else. Every page is drawn to disk before the job starts, as a half-written XPS job
/// gets stuck in the queue and a page that can't be drawn should cost no paper. Straight to the printer (roadmap 2.1): <see cref="RoutedBatchQueue"/>.
/// </summary>
public sealed class WindowsBatchQueue(Func<Task<string?>> findQueue) : IBatchQueue
{
    private IReadOnlyList<PaperChoice> _papers = [];

    public async Task<BatchQueueInfo?> ReadAsync(CancellationToken ct)
    {
        if (await findQueue().ConfigureAwait(false) is not { } name) return null;
        return await Task.Run(() =>
        {
            var options = PhotoPrinting.ReadOptions(name);
            _papers = options.Papers;
            using var queue = QueuePrinter.Open(name);
            return new BatchQueueInfo(name, options.Papers.Select(p => new BatchPaper(p.Key, p.Label)).ToList(), options.DefaultPaper, QueuePrinter.SupportsTwoSided(queue));
        }, ct).ConfigureAwait(false);
    }

    public async Task<string?> ProblemAsync(CancellationToken ct)
    {
        if (await findQueue().ConfigureAwait(false) is not { } name) return Strings.Print_NoQueueNow;
        var queue = (await InstalledQueues.ListAsync().ConfigureAwait(false)).FirstOrDefault(q => string.Equals(q.Name, name, StringComparison.OrdinalIgnoreCase));
        if (queue is null) return Strings.Print_QueueGone;
        var reading = SpoolerStatus.Describe(queue);
        return reading.Offline || reading.Status.Severity == Core.Model.Severity.Error ? $"{reading.Status.Message}." : null;
    }

    public async Task<BatchReceipt> SendAsync(IBatchDocument document, BatchPrintJob job, IProgress<string>? progress, Action? onSpooling, CancellationToken ct)
    {
        if (await findQueue().ConfigureAwait(false) is not { } name) throw new BatchQueueException(Strings.Print_NoQueueNow, mayHaveSent: false);
        var paper = job.Paper is null ? null : await PaperAsync(name, job.Paper, ct).ConfigureAwait(false);
        try
        {
            await Task.Run(() =>
            {
                using var server = new LocalPrintServer();
                using var queue = new PrintQueue(server, name);
                Ticket(queue, job, paper);
            }, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is PrintSystemException or PrintQueueException)
        {
            throw new BatchQueueException(string.Format(Strings.Print_QueueUnusable, ex.Message), mayHaveSent: false);
        }

        using var pages = await DiskPages.DrawAsync(document, job, progress, ct).ConfigureAwait(false);

        // From here the job belongs to the spooler.
        onSpooling?.Invoke();
        progress?.Report(Strings.Print_SendingIt);
        try
        {
            await QueuePrinter.PrintPagesAsync(name, pages, job.Name, document.Sizing, queue => Ticket(queue, job, paper)).ConfigureAwait(false);
        }
        catch (BatchSettingRefusedException)
        {
            throw;
        }
        catch (Exception ex)
        {
            Log.Write($"Batch: spooling failed: {ex}");
            throw new BatchQueueException(string.Format(Strings.Print_QueueFailed, ex.Message), mayHaveSent: true);
        }
        return new BatchReceipt(pages.Count, BatchPrintSettings.Sheets(pages.Count, job.Copies, job.TwoSided));
    }

    private async Task<PaperChoice> PaperAsync(string name, string key, CancellationToken ct)
    {
        PaperChoice? Find() => _papers.FirstOrDefault(p => string.Equals(p.Key, key, StringComparison.OrdinalIgnoreCase));
        if (Find() is null) await ReadAsync(ct).ConfigureAwait(false);
        return Find() ?? throw new BatchSettingRefusedException(string.Format(Strings.Print_PaperNotOffered, name));
    }

    /// <summary>The job's ticket as the driver validated it. Refuses one that didn't keep what was asked.</summary>
    private static PrintTicket Ticket(PrintQueue queue, BatchPrintJob job, PaperChoice? paper)
    {
        var ticket = queue.DefaultPrintTicket.Clone();
        ticket.CopyCount = job.Copies;
        ticket.Collation = Collation.Collated;
        ticket.Duplexing = job.TwoSided ? Duplexing.TwoSidedLongEdge : Duplexing.OneSided;
        ticket.PageOrientation = PageOrientation.Portrait;
        if (paper?.Media is { } media) ticket.PageMediaSize = media;
        var valid = queue.MergeAndValidatePrintTicket(queue.DefaultPrintTicket, ticket).ValidatedPrintTicket;
        (double, double)? asked = paper is null ? null : (paper.WidthIn * 96, paper.HeightIn * 96);
        (double, double)? got = valid.PageMediaSize is { Width: { } w, Height: { } h } ? (w, h) : null;
        bool? twoSided = valid.Duplexing switch
        {
            Duplexing.TwoSidedLongEdge or Duplexing.TwoSidedShortEdge => true,
            Duplexing.OneSided => false,
            _ => null,
        };
        if (BatchTicketCheck.Problem(job.Copies, job.TwoSided, asked, valid.CopyCount, twoSided, got) is { } problem) throw new BatchSettingRefusedException(problem);
        return valid;
    }
}

/// <summary>
/// A batch job's pages on disk until it's written, so a long PDF doesn't sit in memory; read back one at a time as the job asks.
/// Every page is drawn before the job starts, to a Windows queue (a half-written XPS job gets stuck) or a printer (a page that
/// can't be drawn should cost no paper).
/// </summary>
internal sealed class DiskPages : IReadOnlyList<RenderedPage>, IDisposable
{
    private const long RoomPerPage = 2L << 20;
    private readonly string _folder = Directory.CreateDirectory(Path.Combine(PrintImages.Root, Guid.NewGuid().ToString("N"))).FullName;
    private readonly List<(double Width, double Height)> _sizes = [];

    /// <summary>Draws the job's pages of <paramref name="document"/>, in order; a page 0 is a blank side (two-sided by hand), the size of the page before it.</summary>
    /// <exception cref="BatchFileException">No room on disk, or a page wasn't drawn.</exception>
    public static async Task<DiskPages> DrawAsync(IBatchDocument document, BatchPrintJob job, IProgress<string>? progress, CancellationToken ct)
    {
        var pages = new DiskPages();
        try
        {
            if (!pages.HasRoomFor(job.Pages.Count)) throw new BatchFileException(Strings.Print_NoDiskSpace);
            for (var i = 0; i < job.Pages.Count; i++)
            {
                ct.ThrowIfCancellationRequested();
                progress?.Report(string.Format(Strings.Print_PreparingPage, i + 1, job.Pages.Count));
                if (job.Pages[i] == 0)
                {
                    var (w, h) = pages._sizes.Count > 0 ? pages._sizes[^1] : (8.5, 11);
                    pages.Add(new BatchPrintPage(BlankJpeg.Value, w, h));
                    continue;
                }
                pages.Add(await document.RenderAsync(job.Pages[i], ct).ConfigureAwait(false));
            }
            ct.ThrowIfCancellationRequested();
            if (pages.Count != job.Pages.Count) throw new BatchFileException(Strings.Print_FewerPages);
            return pages;
        }
        catch
        {
            pages.Dispose();
            throw;
        }
    }

    /// <summary>A small white JPEG: a blank side, stretched to its paper like any page.</summary>
    private static readonly Lazy<byte[]> BlankJpeg = new(() =>
    {
        var white = System.Windows.Media.Imaging.BitmapSource.Create(8, 8, 96, 96, System.Windows.Media.PixelFormats.Gray8, null, Enumerable.Repeat((byte)255, 64).ToArray(), 8);
        var jpeg = new System.Windows.Media.Imaging.JpegBitmapEncoder();
        jpeg.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(white));
        using var stream = new MemoryStream();
        jpeg.Save(stream);
        return stream.ToArray();
    });

    public int Count => _sizes.Count;

    public bool HasRoomFor(int pages)
    {
        try
        {
            return new DriveInfo(Path.GetPathRoot(_folder)!).AvailableFreeSpace > pages * RoomPerPage;
        }
        catch (Exception ex) when (ex is IOException or ArgumentException or UnauthorizedAccessException)
        {
            return true; // can't tell: writing the pages says so
        }
    }

    public void Add(BatchPrintPage page)
    {
        try
        {
            File.WriteAllBytes(Path.Combine(_folder, $"{_sizes.Count}.jpg"), page.Jpeg);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new BatchFileException($"The file's pages can't be prepared on this PC's disk: {ex.Message}");
        }
        _sizes.Add((page.WidthInches, page.HeightInches));
    }

    public RenderedPage this[int index] => new(File.ReadAllBytes(Path.Combine(_folder, $"{index}.jpg")), _sizes[index].Width, _sizes[index].Height);

    public IEnumerator<RenderedPage> GetEnumerator()
    {
        for (var i = 0; i < Count; i++) yield return this[i];
    }

    System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator() => GetEnumerator();

    public void Dispose()
    {
        try { Directory.Delete(_folder, recursive: true); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            Log.Write($"Batch pages not removed: {ex.Message}"); // the next job removes them (PrintImages)
        }
    }
}

/// <summary>
/// A batch straight to the printer (roadmap 2.1; what decides it: <see cref="Core.Printing.Direct.DirectBatchQueue"/>, and where
/// it goes: <see cref="Core.Printing.Direct.RoutedBatchQueue"/>): this side draws each file's pages to disk as for a Windows queue,
/// then lays each on its sheet as Print a PDF does and sends it, followed to the job's end.
/// </summary>
public static class DirectBatchJobs
{
    public static IBatchQueue For(string printerName, PrintTarget.Direct target) =>
        new Core.Printing.Direct.DirectBatchQueue(printerName, target.Ipp, target.Caps,
            (document, job, request, progress, onSending, ct) => SendAsync(target, document, job, request, progress, onSending, ct));

    private static async Task SendAsync(PrintTarget.Direct target, IBatchDocument document, BatchPrintJob job, Core.Printing.Direct.DirectPrintRequest request,
        IProgress<string>? progress, Action onSending, CancellationToken ct)
    {
        using var pages = await DiskPages.DrawAsync(document, job, progress, ct);
        await DirectPrinter.PrintAsync(target, job.Name, request,
            (paper, images) => QueuePrinter.PagesPaginator.OnePerSheet(pages, paper, document.Sizing, images), progress, ct, onSending, finishOnceSent: true);
    }
}

/// <summary>
/// This PC's side of <c>inkvoltprint print</c>: the real files, and the printer a name stands for (<see cref="BatchPrinterLookup"/>
/// decides): its Windows queue, or straight to it over IPP with the certificate pins Inkvolt Print keeps for it, read only.
/// </summary>
public sealed class BatchPrintHost : IBatchPrintHost
{
    public IBatchDocuments Documents => WindowsBatchDocuments.Instance;

    public async Task<IBatchQueue> FindPrinterAsync(string name, CancellationToken ct)
    {
        var known = Core.Suite.InkvoltPrinters.Load();
        // An address given needs no queue list (and a PC whose spooler is off can still print straight).
        IReadOnlyList<SpoolerQueue> queues = name.Contains("://", StringComparison.Ordinal) ? [] : await InstalledQueues.ListAsync().ConfigureAwait(false);
        switch (BatchPrinterLookup.Find(name, queues, known))
        {
            case BatchPrinterChoice.Direct direct:
                // Lives as long as the command: the process ends with the batch.
                var http = new Core.Net.DeviceHttp(direct.Endpoint.Host, pin: direct.Printer is { } p ? new ReadOnlyPins(known, p.Uuid) : null);
                return DirectBatchJobs.For(direct.Name, PrintTarget.Direct.For(new Core.Ipp.IppClient(http, direct.Endpoint), Environment.UserName));
            case BatchPrinterChoice.Queue { Name: var queueName }:
                return new WindowsBatchQueue(() => Task.FromResult<string?>(queueName));
            default:
                throw new BatchCommandException($"There is no printer \"{BatchPrintText.Clean(name)}\".");
        }
    }
}
