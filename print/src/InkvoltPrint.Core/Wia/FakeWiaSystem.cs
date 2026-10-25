namespace InkvoltPrint.Core.Wia;

/// <summary>
/// Made-up WIA scanners for tests and demo mode: nothing on the PC is asked. Each <see cref="FakeWiaScanner"/> says what it
/// offers, holds pages in its feeder (or fails as told) and draws its pages with a callback, on the caller's thread.
/// </summary>
public sealed class FakeWiaSystem(IEnumerable<FakeWiaScanner> scanners) : IWiaSystem
{
    private readonly List<FakeWiaScanner> _scanners = [.. scanners];

    public IReadOnlyList<FakeWiaScanner> Scanners => _scanners;

    public Task<IReadOnlyList<WiaDeviceInfo>> ListScannersAsync(CancellationToken ct) =>
        Task.FromResult<IReadOnlyList<WiaDeviceInfo>>(_scanners.Select(s => s.Device).ToList());

    public IWiaDeviceHost Device(string deviceId) =>
        _scanners.FirstOrDefault(s => s.Device.Id == deviceId) ?? throw new WiaException(WiaErrors.NoDeviceAvailable, "No such scanner.");
}

/// <param name="draw">A page for the settings (width and height in pixels, resolution, grey or color): JPEG bytes.</param>
public sealed class FakeWiaScanner(WiaDeviceInfo device, WiaScannerInfo info, Func<WiaScanSettings, int, byte[]> draw) : IWiaDevice, IWiaDeviceHost
{
    private int _left;

    public WiaDeviceInfo Device { get; } = device;
    public WiaScannerInfo Info { get; } = info;

    /// <summary>Pages in the feeder; each feeder job takes them all (the stack is put back for the next job, as in a demo).</summary>
    public int FeederPages { get; set; } = 3;

    /// <summary>When set, the pages in the feeder at the start of each job (demo mode: a batch with separator sheets, or a few pages).</summary>
    public Func<int>? FeederStack { get; set; }

    /// <summary>Connecting fails with this (the scanner is off), when set.</summary>
    public int? ConnectError { get; set; }

    /// <summary>The page with this 0-based number in a job fails with <see cref="PageErrorCode"/>, when set.</summary>
    public int? FailAtPage { get; set; }

    public int PageErrorCode { get; set; } = WiaErrors.PaperJam;

    /// <summary>Document handling status the scanner reports; null: none.</summary>
    public int? HandlingStatus { get; set; }

    /// <summary>During a job, the status says whether sheets are left (<see cref="WiaIds.FeedReady"/> or 0) instead of <see cref="HandlingStatus"/>.</summary>
    public bool DetectsFeed { get; set; }

    /// <summary>The driver refuses the feeder without an error (reads back the glass) and scans the glass for every page.</summary>
    public bool RefusesFeeder { get; set; }

    /// <summary>Once the feeder is empty the driver scans the glass instead of saying so (the same page every time).</summary>
    public bool GlassWhenEmpty { get; set; }

    /// <summary>Calls never return (a hung driver); they end only when the caller cancels.</summary>
    public bool Hangs { get; set; }

    /// <summary>The settings of each page transferred, in order (tests read them).</summary>
    public List<WiaScanSettings> Transfers { get; } = [];

    /// <summary>The settings applied for each job.</summary>
    public List<WiaScanSettings> Applied { get; } = [];

    private int _page, _sides;
    private bool _duplex;

    public Task<T> UseAsync<T>(Func<IWiaDevice, T> work, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (ConnectError is { } error) return Task.FromException<T>(new WiaException(error, "Not connected."));
        if (Hangs) return Task.Delay(Timeout.Infinite, ct).ContinueWith<T>(_ => throw new OperationCanceledException(ct), TaskScheduler.Default);
        try { return Task.FromResult(work(this)); }
        catch (Exception ex) { return Task.FromException<T>(ex); }
    }

    public int? ReadHandlingStatus() =>
        DetectsFeed && Applied.Count > 0 ? ((_duplex && _sides % 2 == 1 ? _left > 1 : _left > 0) ? WiaIds.FeedReady : 0) : HandlingStatus;

    public int? Apply(WiaScanSettings settings)
    {
        Applied.Add(settings);
        _page = 0;
        _sides = 0;
        _duplex = settings.Duplex;
        // Sides left to scan: two per sheet for both sides.
        _left = settings.Feeder ? (FeederStack?.Invoke() ?? FeederPages) * (settings.Duplex ? 2 : 1) : 1;
        return RefusesFeeder ? WiaIds.SelectFlatbed : settings.Handling;
    }

    public byte[]? TransferPage(WiaScanSettings settings)
    {
        if (FailAtPage == _page) throw new WiaException(PageErrorCode, "Failed.");
        Transfers.Add(settings);
        if (RefusesFeeder && settings.Feeder) return draw(settings with { Feeder = false }, 0);
        if (_left-- <= 0)
        {
            if (GlassWhenEmpty) return draw(settings with { Feeder = false }, 255);
            Transfers.RemoveAt(Transfers.Count - 1);
            throw new WiaException(WiaErrors.PaperEmpty, "Feeder empty.");
        }
        _sides++;
        return draw(settings, _page++);
    }
}
