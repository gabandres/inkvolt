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

    /// <summary>The settings of each page transferred, in order (tests read them).</summary>
    public List<WiaScanSettings> Transfers { get; } = [];

    private int _page;

    public Task<T> UseAsync<T>(Func<IWiaDevice, T> work, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        if (ConnectError is { } error) return Task.FromException<T>(new WiaException(error, "Not connected."));
        try { return Task.FromResult(work(this)); }
        catch (Exception ex) { return Task.FromException<T>(ex); }
    }

    public int? ReadHandlingStatus() => HandlingStatus;

    public byte[]? TransferPage(WiaScanSettings settings, bool first)
    {
        if (first)
        {
            _page = 0;
            _left = settings.Feeder ? FeederStack?.Invoke() ?? FeederPages : 1;
        }
        if (FailAtPage == _page) throw new WiaException(PageErrorCode, "Failed.");
        if (_left-- <= 0) throw new WiaException(WiaErrors.PaperEmpty, "Feeder empty.");
        Transfers.Add(settings);
        return draw(settings, _page++);
    }
}
