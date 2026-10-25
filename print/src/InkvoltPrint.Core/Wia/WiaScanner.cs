using System.Runtime.CompilerServices;
using InkvoltPrint.Core.Escl;

namespace InkvoltPrint.Core.Wia;

/// <summary>
/// A connected WIA scanner. Its methods block and must run on the thread that connected it (WIA is COM in a single-threaded
/// apartment): <see cref="IWiaDeviceHost.UseAsync{T}"/> runs them there. Failures are <see cref="WiaException"/>s.
/// </summary>
public interface IWiaDevice
{
    WiaScannerInfo Info { get; }

    /// <summary>Document handling status bits (<see cref="WiaIds.FeedReady"/>…), or null when the driver doesn't report them.</summary>
    int? ReadHandlingStatus();

    /// <summary>
    /// Sets a job's settings on the device (before its first page). Returns the document handling select the driver has then
    /// (read back: a driver may refuse the feeder without an error), or null when it has no such property.
    /// </summary>
    int? Apply(WiaScanSettings settings);

    /// <summary>
    /// Scans one page as JPEG with the settings applied: the next page from the feeder, or the glass. Null when the driver gave
    /// no image (some say "no more pages" that way).
    /// </summary>
    byte[]? TransferPage(WiaScanSettings settings);
}

/// <summary>
/// Runs work on a WIA device's thread, connecting first when needed. Cancelling stops waiting at once and skips work that hasn't
/// started; a call already in the driver runs to its end (and the device takes no more work until it returns:
/// <see cref="WiaErrors.NotAnswering"/>).
/// </summary>
public interface IWiaDeviceHost
{
    Task<T> UseAsync<T>(Func<IWiaDevice, T> work, CancellationToken ct);
}

/// <summary>The PC's WIA scanners: Windows' (InkvoltPrint.Windows) or made up (<see cref="FakeWiaSystem"/>, tests and demo mode).</summary>
public interface IWiaSystem
{
    /// <summary>Scanners Windows has a driver for (installed, not necessarily on). Reads nothing from the devices.</summary>
    Task<IReadOnlyList<WiaDeviceInfo>> ListScannersAsync(CancellationToken ct);

    IWiaDeviceHost Device(string deviceId);
}

/// <summary>
/// Scanning through Windows Image Acquisition, for scanners without eSCL (USB, WSD, driver-only): the device's capabilities as
/// <see cref="ScannerCapabilities"/> and its pages as JPEG, so the Scan and Copy tabs treat it like any other scanner. Glass and
/// feeder (one side or both, where the driver offers them), color or grey, resolution and page size; a feeder job takes pages
/// until the driver says the feeder is empty.
/// </summary>
public sealed class WiaScanner : IScanner
{
    /// <summary>Feeder jobs stop here even if a driver never says the feeder is empty.</summary>
    public const int MaxFeederPages = 500;

    private readonly IWiaDeviceHost _host;

    private WiaScanner(IWiaDeviceHost host, WiaDeviceInfo device, WiaScannerInfo info)
    {
        _host = host;
        Device = device;
        Info = info;
        Capabilities = WiaCapabilities.From(info, device.Name);
    }

    public WiaDeviceInfo Device { get; }
    public WiaScannerInfo Info { get; }
    public ScannerCapabilities Capabilities { get; }

    /// <summary>The longest one page may take (a slow scanner at its highest resolution); past it the driver is taken as hung.</summary>
    public TimeSpan PageTimeout { get; set; } = TimeSpan.FromMinutes(5);

    /// <summary>Connects (reads what the scanner offers). <see cref="WiaException"/> when it can't (off, unplugged).</summary>
    public static async Task<WiaScanner> OpenAsync(IWiaSystem system, WiaDeviceInfo device, CancellationToken ct)
    {
        var host = system.Device(device.Id);
        var info = await host.UseAsync(d => d.Info, ct).ConfigureAwait(false);
        return new WiaScanner(host, device, info);
    }

    public async Task<ScannerStatus> GetStatusAsync(CancellationToken ct = default)
    {
        var status = await _host.UseAsync(d => d.ReadHandlingStatus(), ct).ConfigureAwait(false);
        return WiaCapabilities.Status(Info.Handling, status);
    }

    /// <summary>
    /// The pages of one job. A feeder job takes pages until the driver says the feeder is empty, and also stops (see
    /// <see cref="WiaFeeder"/>) when the driver didn't take the feeder (scans nothing), when it says no paper is ready before the
    /// next sheet, when a page is byte for byte the one before (a driver scanning the glass again), and at
    /// <see cref="MaxFeederPages"/>. A page that takes longer than <see cref="PageTimeout"/> ends the job (the driver hung).
    /// </summary>
    public async IAsyncEnumerable<byte[]> ScanAsync(ScanRequest request, [EnumeratorCancellation] CancellationToken ct = default)
    {
        var settings = WiaCapabilities.Plan(request, Capabilities, Info);
        byte[]? last = null;
        for (var page = 0; page < (settings.Feeder ? MaxFeederPages : 1); page++)
        {
            ct.ThrowIfCancellationRequested();
            var (jpeg, end) = await PageAsync(settings, page, ct).ConfigureAwait(false);
            if (end) yield break;
            if (WiaFeeder.Repeats(last, jpeg!)) yield break; // the glass scanned again, not a new sheet
            last = jpeg;
            yield return jpeg!;
        }
    }

    /// <summary>One page of a job: (its JPEG, false), or (null, true) when the feeder job is over. <see cref="ScanException"/> when it fails.</summary>
    private async Task<(byte[]? Jpeg, bool End)> PageAsync(WiaScanSettings settings, int page, CancellationToken ct)
    {
        var first = page == 0;
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(PageTimeout);
        byte[]? jpeg;
        try
        {
            if (first && !WiaFeeder.FeederTaken(settings, await _host.UseAsync(d => d.Apply(settings), limit.Token).ConfigureAwait(false)))
                throw new ScanException(WiaFeeder.NotTakenMessage);
            if (WiaFeeder.ChecksBefore(settings, page) && WiaFeeder.Empty(Info.Handling, await StatusAsync(limit.Token).ConfigureAwait(false)))
            {
                if (first) throw new ScanException(WiaErrors.Message(WiaErrors.PaperEmpty, true)); // load the pages first (some drivers would scan the glass)
                return (null, true);
            }
            jpeg = await _host.UseAsync(d => d.TransferPage(settings), limit.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            throw new ScanException(WiaErrors.Message(WiaErrors.NotAnswering, settings.Feeder));
        }
        catch (WiaException ex) when (ex.Code == WiaErrors.PaperEmpty && settings.Feeder && !first)
        {
            return (null, true); // the feeder ran out: that's the end of the job
        }
        catch (WiaException ex)
        {
            throw new ScanException(WiaErrors.Message(ex.Code, settings.Feeder));
        }
        if (jpeg is not null) return (jpeg, false);
        if (first) throw new ScanException(settings.Feeder ? WiaErrors.Message(WiaErrors.PaperEmpty, true) : "The scanner returned no image.");
        return (null, true);
    }

    /// <summary>The feeder's status bits; null when the driver can't say (a failed read doesn't stop the job).</summary>
    private async Task<int?> StatusAsync(CancellationToken ct)
    {
        try
        {
            return await _host.UseAsync(d => d.ReadHandlingStatus(), ct).ConfigureAwait(false);
        }
        catch (WiaException)
        {
            return null;
        }
    }
}

/// <summary>
/// When a feeder job stops, beyond the driver's "feeder empty": a WIA driver that doesn't take the feeder, or falls back to the
/// glass once the feeder is empty, scans the glass again for every page and never says it's empty.
/// </summary>
public static class WiaFeeder
{
    public const string NotTakenMessage = "The scanner's driver didn't switch to the document feeder, so nothing was scanned. " +
                                          "Scan from the glass, or use the scanner's own app.";

    /// <summary>
    /// The driver took the feeder (read back after setting it), or the job is from the glass, or the driver has no document handling
    /// select to read back (the other checks still apply).
    /// </summary>
    public static bool FeederTaken(WiaScanSettings settings, int? selectReadBack) =>
        !settings.Feeder || selectReadBack is not { } s || (s & WiaIds.SelectFeeder) != 0;

    /// <summary>
    /// Whether to read the feeder's status before this page (0-based): before each sheet, so every page, or every second one for
    /// both sides (the last sheet's back comes when the feeder is already empty).
    /// </summary>
    public static bool ChecksBefore(WiaScanSettings settings, int page) => settings.Feeder && (!settings.Duplex || page % 2 == 0);

    /// <summary>The driver can tell whether paper is in the feeder and says none is ready.</summary>
    public static bool Empty(int? handlingCapabilities, int? status) =>
        handlingCapabilities is { } caps && (caps & WiaIds.CapDetectFeedAvailable) != 0 && status is { } s && (s & WiaIds.FeedReady) == 0;

    /// <summary>A page byte for byte the one before: no two sheets scan that alike, a driver sending the glass again does.</summary>
    public static bool Repeats(byte[]? previous, byte[] page) => previous is not null && previous.AsSpan().SequenceEqual(page);
}

/// <summary>The pure part of WIA scanning: capabilities, scan settings and feeder state from the driver's properties.</summary>
public static class WiaCapabilities
{
    // eSCL's defaults when a scanner gives no size (as ScannerCapabilities.Parse uses): 8.5 in wide, A4 long.
    private const int DefaultWidth = 2550, DefaultHeight = 3508, LegalHeight = 4200;

    /// <summary>Thousandths of an inch to the 1/300 inch eSCL units the Scan tab works in.</summary>
    public static int ToThreeHundredths(int thousandths) => (int)Math.Round(thousandths * 0.3);

    /// <summary>
    /// The scanner as the Scan tab sees it: glass and feeder from the document handling capabilities (glass only when the driver
    /// has none), their sizes (the feeder's from the sheet feed size, else the glass's; a feeder of any length gets Legal), color
    /// and grey as offered, resolutions from the driver's list or range (as eSCL ranges are turned into choices). Pages always
    /// arrive as JPEG (converted when the driver sends another format).
    /// </summary>
    public static ScannerCapabilities From(WiaScannerInfo info, string name)
    {
        var handling = info.Handling;
        var hasFlat = handling is null || (handling & WiaIds.CapFlat) != 0 || (handling & WiaIds.CapFeed) == 0;
        var hasFeed = handling is { } h && (h & WiaIds.CapFeed) != 0;
        var bedW = Size(info.BedWidth, DefaultWidth);
        var bedH = Size(info.BedHeight, DefaultHeight);
        var colors = new List<string>();
        if (info.DataTypes.Count == 0 || info.DataTypes.Contains(WiaIds.DataColor)) colors.Add("RGB24");
        if (info.DataTypes.Count == 0 || info.DataTypes.Contains(WiaIds.DataGrayscale)) colors.Add("Grayscale8");
        if (colors.Count == 0) colors.Add("RGB24"); // black and white only: asked for color, the driver gives what it has
        var resolutions = Resolutions(info.Resolutions);
        InputCaps Input(int w, int h) => new(0, w, 0, h, colors, ["image/jpeg"], resolutions, []);
        return new ScannerCapabilities("WIA", name, null,
            hasFlat ? Input(bedW, bedH) : null,
            hasFeed ? Input(Size(info.FeederWidth, bedW), Size(info.FeederHeight, hasFlat ? Math.Max(bedH, LegalHeight) : LegalHeight)) : null,
            hasFeed && (handling & WiaIds.CapDuplex) != 0);
    }

    private static int Size(int? thousandths, int fallback) => thousandths is > 0 ? ToThreeHundredths(thousandths.Value) : fallback;

    /// <summary>The resolutions to offer: the driver's list, the usual ones its range allows, or its one current value.</summary>
    public static IReadOnlyList<int> Resolutions(WiaValues values)
    {
        if (values.List.Count > 0) return values.List.Where(r => r > 0).Distinct().Order().ToList();
        if (values.Min is { } min && values.Max is { } max)
            return ScannerCapabilities.RangeResolutions(min, max, values.Step ?? 1, values.Current);
        return values.Current > 0 ? [values.Current] : [];
    }

    /// <summary>
    /// What to set for <paramref name="request"/>: the source (both sides front first), color (24-bit) or grey (8-bit) as offered,
    /// the offered resolution nearest the one asked for, the area (the source's whole area when none is asked) in pixels at that
    /// resolution, and the pages per transfer (<see cref="WiaScanSettings.Pages"/>).
    /// </summary>
    public static WiaScanSettings Plan(ScanRequest request, ScannerCapabilities caps, WiaScannerInfo info)
    {
        var source = caps.For(request.Source) is null ? caps.Sources.First() : request.Source;
        var input = caps.For(source)!;
        var feeder = source != ScanSource.Platen;
        var res = input.Resolutions.Count == 0 ? request.Resolution : input.Resolutions.MinBy(r => Math.Abs(r - request.Resolution));
        var grey = request.Color == ScanColor.Grayscale ? input.ColorModes.Contains("Grayscale8") : !input.ColorModes.Contains("RGB24");
        var width = Math.Clamp(request.Width ?? input.MaxWidth, Math.Max(input.MinWidth, 1), input.MaxWidth);
        var height = Math.Clamp(request.Height ?? input.MaxHeight, Math.Max(input.MinHeight, 1), input.MaxHeight);
        int? handling = info.Handling is null ? null
            : source switch
            {
                ScanSource.Adf => WiaIds.SelectFeeder,
                ScanSource.AdfDuplex => WiaIds.SelectFeeder | WiaIds.SelectDuplex | WiaIds.SelectFrontFirst,
                _ => WiaIds.SelectFlatbed,
            };
        int? pages = !feeder ? null : source == ScanSource.AdfDuplex ? 0 : 1;
        return new WiaScanSettings(handling, feeder, grey ? WiaIds.DataGrayscale : WiaIds.DataColor, grey ? 8 : 24, res,
            Pixels(width, res), Pixels(height, res), pages);
    }

    private static int Pixels(int threeHundredths, int dpi) => Math.Max(1, (int)((long)threeHundredths * dpi / 300));

    /// <summary>
    /// The scanner's state as eSCL words, so the Scan tab's checks (a preset choosing the feeder when it's loaded) work the same:
    /// a jam or an open feeder cover, loaded when the driver says the feeder is ready, empty when it can tell paper is there or not.
    /// </summary>
    public static ScannerStatus Status(int? handling, int? status)
    {
        if (status is not { } s || handling is not { } h || (h & WiaIds.CapFeed) == 0) return new ScannerStatus("Idle", null, []);
        var adf = (s & WiaIds.PaperJam) != 0 ? "ScannerAdfJam"
            : (s & WiaIds.PathCoverUp) != 0 ? "ScannerAdfHatchOpen"
            : (s & WiaIds.FeedReady) != 0 ? "ScannerAdfLoaded"
            : (h & WiaIds.CapDetectFeedAvailable) != 0 ? "ScannerAdfEmpty"
            : null;
        return new ScannerStatus("Idle", adf, []);
    }
}
