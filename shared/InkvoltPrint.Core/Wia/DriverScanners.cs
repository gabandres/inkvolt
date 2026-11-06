namespace InkvoltPrint.Core.Wia;

/// <summary>
/// The PC's driver scanners as one list: WIA's and the TWAIN manager's 64-bit sources side by side, behind the one
/// <see cref="IWiaSystem"/> Inkvolt Print's printer list, Scan and Copy tabs and Fleet, and Inkvolt PDF's Scan dialog, read, so a
/// TWAIN source is matched to its printer (<see cref="WiaMatch"/>), listed on its own, connected and scanned exactly as a WIA
/// scanner is (<see cref="WiaScanner"/>). A TWAIN source's id is "twain:" and its source name, so it never takes a WIA id and
/// <see cref="Device"/> sends it to its own driver. A TWAIN source that is a WIA scanner already listed (the same name or model as
/// any WIA entry, <see cref="WiaMatch"/>) is left out: its Windows driver is used.
/// <para>
/// WIA is read on every list; the TWAIN manager (which opens every source's driver and can take many seconds) only when due: the
/// first time, when WIA's list changed since the read before (a device plugged in or out), and after
/// <see cref="TwainRelistInterval"/>; never while a TWAIN source is in use (a call to it under way, or one within
/// <see cref="TwainQuiet"/>). A read that fails or hangs (<see cref="TwainListLimit"/>) never costs the WIA list: the sources read
/// before are kept, so a scanner on its own doesn't drop off the list for one bad read. WIA failing to list fails the list, as before.
/// </para>
/// </summary>
/// <param name="log">Told why TWAIN's sources couldn't be listed, once per distinct failure (plain words, no device data beyond the
/// error's message).</param>
public sealed class DriverScanners(IWiaSystem wia, IWiaSystem twain, Action<string>? log = null) : IWiaSystem
{
    /// <summary>Before a TWAIN source's name in its id (as Inkvolt PDF's Scan dialog keys it).</summary>
    public const string TwainPrefix = "twain:";

    /// <summary>At most this many TWAIN sources are listed (a manager that keeps answering "next" can't fill the list).</summary>
    public const int MaxSources = 64;

    private readonly Lock _gate = new();
    private volatile IReadOnlyList<WiaDeviceInfo> _sources = [];
    private IReadOnlyList<WiaDeviceInfo>? _lastWia;
    private Task? _reading;
    private bool _due = true;
    private DateTime _readAt, _usedAt = DateTime.MinValue;
    private int _inUse;
    private string? _lastFailure;

    /// <summary>The longest a TWAIN read may take (the only limit on it); past it, the sources read before.</summary>
    public TimeSpan TwainListLimit { get; init; } = TimeSpan.FromSeconds(20);

    /// <summary>TWAIN's sources are read again after this long even when WIA's list stays the same (a TWAIN-only scanner plugged in).</summary>
    public TimeSpan TwainRelistInterval { get; init; } = TimeSpan.FromMinutes(10);

    /// <summary>After a TWAIN source's last call, this long with no TWAIN read (the pause between a scan's pages).</summary>
    public TimeSpan TwainQuiet { get; init; } = TimeSpan.FromMinutes(1);

    /// <summary>A TWAIN read ended with other sources than before, or failed or recovered: list again to show it. Raised on any thread.</summary>
    public event Action? TwainChanged;

    /// <summary>Why the last TWAIN read failed (a <see cref="WiaException"/> when the manager didn't answer); null when it worked or none ended.</summary>
    public Exception? TwainFailure { get; private set; }

    /// <summary>
    /// The whole list: WIA's scanners and, once a TWAIN read that is due (or under way) has ended, the TWAIN sources (for a caller
    /// that lists once: the CLI, Fleet, the demo PC). Up to <see cref="TwainListLimit"/> longer than WIA's own list.
    /// </summary>
    public async Task<IReadOnlyList<WiaDeviceInfo>> ListScannersAsync(CancellationToken ct)
    {
        var reading = ReadTwainIfDue(); // at the same time as WIA's
        var drivers = await ListWiaAsync(ct).ConfigureAwait(false);
        await ReadTwainIfDue().WaitAsync(ct).ConfigureAwait(false); // the same read, or one WIA's change made due
        await reading.WaitAsync(ct).ConfigureAwait(false);
        return Merge(drivers, _sources);
    }

    /// <summary>
    /// WIA's scanners and the TWAIN sources read before, at once (a list shown on screen: the printer list, the Scan dialog). A TWAIN
    /// read that is due starts and ends later; <see cref="TwainChanged"/> says when it found something new.
    /// </summary>
    public async Task<IReadOnlyList<WiaDeviceInfo>> ListNowAsync(CancellationToken ct)
    {
        var drivers = await ListWiaAsync(ct).ConfigureAwait(false);
        _ = ReadTwainIfDue();
        return Merge(drivers, _sources);
    }

    public IWiaDeviceHost Device(string deviceId) =>
        deviceId.StartsWith(TwainPrefix, StringComparison.Ordinal) ? new InUse(twain.Device(deviceId[TwainPrefix.Length..]), this) : wia.Device(deviceId);

    /// <summary>WIA's scanners, then the TWAIN sources (with their "twain:" ids) that aren't any WIA entry.</summary>
    public static IReadOnlyList<WiaDeviceInfo> Merge(IReadOnlyList<WiaDeviceInfo> wiaScanners, IReadOnlyList<WiaDeviceInfo> twainSources)
    {
        // One target per WIA entry: a source that is one all-in-one's USB and WSD entries both matches each alone.
        var targets = wiaScanners.Select(d => new ScanTarget(d.Id, new[] { d.Name, d.Description }.OfType<string>().ToList(), [])).ToList();
        return [.. wiaScanners, .. twainSources.Where(s => !targets.Any(t => WiaMatch.Match(s, [t]) is not null))];
    }

    private async Task<IReadOnlyList<WiaDeviceInfo>> ListWiaAsync(CancellationToken ct)
    {
        var drivers = await wia.ListScannersAsync(ct).ConfigureAwait(false);
        lock (_gate)
        {
            if (_lastWia is { } before && !before.Select(d => d.Id).SequenceEqual(drivers.Select(d => d.Id))) _due = true; // plugged in or out
            _lastWia = drivers;
        }
        return drivers;
    }

    /// <summary>The TWAIN read under way, or one started now when due and no TWAIN source is in use; else nothing to wait for.</summary>
    private Task ReadTwainIfDue()
    {
        lock (_gate)
        {
            if (_reading is { IsCompleted: false } running) return running;
            var now = DateTime.UtcNow;
            if (!_due && now - _readAt < TwainRelistInterval) return Task.CompletedTask;
            if (_inUse > 0 || now - _usedAt < TwainQuiet) return Task.CompletedTask; // asked again on a later list
            _due = false;
            return _reading = Task.Run(ReadTwainAsync); // never inside this lock, nor on the caller's thread
        }
    }

    private async Task ReadTwainAsync()
    {
        var before = _sources;
        var failedBefore = TwainFailure is not null;
        using var limit = new CancellationTokenSource(TwainListLimit);
        try
        {
            // WaitAsync too: a manager stuck in a driver may never look at the token.
            var listed = await twain.ListScannersAsync(limit.Token).WaitAsync(limit.Token).ConfigureAwait(false);
            _sources = listed.Take(MaxSources).Select(s => s with { Id = TwainPrefix + s.Id, Port = WiaDeviceInfo.TwainPort }).ToList();
            TwainFailure = null;
            _lastFailure = null;
        }
        catch (Exception ex)
        {
            var late = ex is OperationCanceledException;
            TwainFailure = late ? new WiaException(WiaErrors.NotAnswering, "The TWAIN manager didn't answer in time.") : ex;
            var why = late ? "the TWAIN manager didn't answer in time" : ex.Message;
            if (why != _lastFailure) log?.Invoke($"TWAIN sources couldn't be listed ({why}); keeping the {_sources.Count} listed before");
            _lastFailure = why;
        }
        finally
        {
            lock (_gate) _readAt = DateTime.UtcNow;
        }
        if (failedBefore != TwainFailure is not null || !before.Select(s => s.Id).SequenceEqual(_sources.Select(s => s.Id))) TwainChanged?.Invoke();
    }

    private void Using(int delta)
    {
        lock (_gate)
        {
            _inUse += delta;
            _usedAt = DateTime.UtcNow;
        }
    }

    /// <summary>A TWAIN source's calls, counted so no TWAIN read starts while it is in use.</summary>
    private sealed class InUse(IWiaDeviceHost host, DriverScanners owner) : IWiaDeviceHost
    {
        public async Task<T> UseAsync<T>(Func<IWiaDevice, T> work, CancellationToken ct)
        {
            owner.Using(+1);
            try
            {
                return await host.UseAsync(work, ct).ConfigureAwait(false);
            }
            finally
            {
                owner.Using(-1);
            }
        }
    }
}
