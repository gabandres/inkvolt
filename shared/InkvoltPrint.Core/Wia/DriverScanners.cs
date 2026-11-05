namespace InkvoltPrint.Core.Wia;

/// <summary>
/// The PC's driver scanners as one list: WIA's and the TWAIN manager's 64-bit sources side by side, behind the one
/// <see cref="IWiaSystem"/> Inkvolt Print's printer list, Scan and Copy tabs and Fleet read, so a TWAIN source is matched to its
/// printer (<see cref="WiaMatch"/>), listed on its own, connected and scanned exactly as a WIA scanner is (<see cref="WiaScanner"/>).
/// A TWAIN source's id is "twain:" and its source name, so it never takes a WIA id and <see cref="Device"/> sends it to its own
/// driver. A TWAIN source that is a WIA scanner already listed (the same name or model, <see cref="WiaMatch"/>) is left out: its
/// Windows driver is used. TWAIN failing to list (no manager, a manager that hangs or fails) never costs the WIA list: the sources
/// listed before are kept, so a scanner on its own doesn't drop off the list for one bad read. WIA failing to list fails the list,
/// as before.
/// </summary>
/// <param name="log">Told why TWAIN's sources couldn't be listed (plain words, no device data beyond the error's message).</param>
public sealed class DriverScanners(IWiaSystem wia, IWiaSystem twain, Action<string>? log = null) : IWiaSystem
{
    /// <summary>Before a TWAIN source's name in its id (as Inkvolt PDF's Scan dialog keys it).</summary>
    public const string TwainPrefix = "twain:";

    /// <summary>At most this many TWAIN sources are listed (a manager that keeps answering "next" can't fill the list).</summary>
    public const int MaxSources = 64;

    private volatile IReadOnlyList<WiaDeviceInfo> _sources = [];

    /// <summary>The longest the list waits for the TWAIN manager; past it, the sources listed before.</summary>
    public TimeSpan TwainListLimit { get; init; } = TimeSpan.FromSeconds(25);

    public async Task<IReadOnlyList<WiaDeviceInfo>> ListScannersAsync(CancellationToken ct)
    {
        var sources = TwainSourcesAsync(ct); // at the same time as WIA's
        var drivers = await wia.ListScannersAsync(ct).ConfigureAwait(false);
        return Merge(drivers, await sources.ConfigureAwait(false));
    }

    public IWiaDeviceHost Device(string deviceId) =>
        deviceId.StartsWith(TwainPrefix, StringComparison.Ordinal) ? twain.Device(deviceId[TwainPrefix.Length..]) : wia.Device(deviceId);

    /// <summary>
    /// WIA's scanners, then the TWAIN sources (with their "twain:" ids) that aren't one of them, at most <see cref="MaxSources"/>.
    /// </summary>
    public static IReadOnlyList<WiaDeviceInfo> Merge(IReadOnlyList<WiaDeviceInfo> wiaScanners, IReadOnlyList<WiaDeviceInfo> twainSources)
    {
        var targets = wiaScanners.Select(d => new ScanTarget(d.Id, new[] { d.Name, d.Description }.OfType<string>().ToList(), [])).ToList();
        return [.. wiaScanners, .. twainSources.Where(s => WiaMatch.Match(s, targets) is null).Take(MaxSources)];
    }

    private async Task<IReadOnlyList<WiaDeviceInfo>> TwainSourcesAsync(CancellationToken ct)
    {
        try
        {
            var listed = await twain.ListScannersAsync(ct).WaitAsync(TwainListLimit, ct).ConfigureAwait(false);
            return _sources = listed.Take(MaxSources).Select(s => s with { Id = TwainPrefix + s.Id, Port = WiaDeviceInfo.TwainPort }).ToList();
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            log?.Invoke($"TWAIN sources couldn't be listed ({(ex is TimeoutException ? "the TWAIN manager didn't answer in time" : ex.Message)}); keeping the {_sources.Count} listed before");
            return _sources;
        }
    }
}
