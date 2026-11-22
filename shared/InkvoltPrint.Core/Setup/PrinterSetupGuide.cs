using System.Net;

namespace InkvoltPrint.Core.Setup;

/// <summary>Where this PC's Wi-Fi is: no adapter, connected to a network (its name and Windows' saved profile for it), or not connected.</summary>
public sealed record WifiNow(bool HasAdapter, byte[]? Ssid, string? Profile)
{
    public static readonly WifiNow NoAdapter = new(false, null, null);

    public bool Connected => Ssid is { Length: > 0 };

    public bool IsOn(WifiNetwork network) => Ssid is { } ssid && ssid.AsSpan().SequenceEqual(network.Ssid);

    public string? Name => Ssid is { } ssid ? SetupNetworks.Show(ssid) : null;
}

/// <summary>Windows said no to a list of networks: location access is off for desktop apps (Windows 11 asks for it to see Wi-Fi names).</summary>
public sealed class WifiLocationException() : Exception("Location access is off for desktop apps.");

/// <summary>
/// This PC's Wi-Fi, as the setup guide uses it (Windows' WLAN API in the app; a fake in tests and demo mode). Reading changes nothing;
/// the three calls that change networks are made only from the person's own click, never by themselves.
/// </summary>
public interface IWifi
{
    Task<WifiNow> NowAsync(CancellationToken ct);

    /// <summary>The networks in range (asks the adapter to look again first). <see cref="WifiLocationException"/> when Windows won't say.</summary>
    Task<IReadOnlyList<WifiNetwork>> NearbyAsync(CancellationToken ct);

    /// <summary>Joins an open network with a temporary profile (<see cref="SetupNetworks.OpenProfile"/>): nothing is kept in Windows.</summary>
    Task ConnectOpenAsync(WifiNetwork network, string profileXml, CancellationToken ct);

    /// <summary>Joins a network by Windows' own saved profile (the one the PC was on: its password stays Windows').</summary>
    Task ConnectProfileAsync(string profile, CancellationToken ct);

    /// <summary>Leaves the network it's on (when the PC wasn't on Wi-Fi before).</summary>
    Task DisconnectAsync(CancellationToken ct);

    /// <summary>The gateway this PC's Wi-Fi was given (the printer, on its own network); null when none.</summary>
    Task<IPAddress?> GatewayAsync(CancellationToken ct);
}

/// <summary>Where the setup guide is.</summary>
public enum SetupStep
{
    /// <summary>Looking for the printer's network.</summary>
    Looking,

    /// <summary>No Wi-Fi adapter on this PC.</summary>
    NoWifi,

    /// <summary>Windows won't list networks: location access is off.</summary>
    LocationOff,

    /// <summary>Networks listed (<see cref="PrinterSetupGuide.Candidates"/>; none: <see cref="PrinterSetupGuide.Problem"/> says what to try).</summary>
    Choose,

    /// <summary>Joining the printer's network (the person clicked Connect).</summary>
    Connecting,

    /// <summary>A secured network: the person connects in Windows' own Wi-Fi list, the guide waits to see it.</summary>
    InWindows,

    /// <summary>On the printer's network: its setup page is <see cref="PrinterSetupGuide.Page"/>.</summary>
    OnPrinter,

    /// <summary>Going back to the network the PC was on.</summary>
    Returning,

    /// <summary>Back on that network (or off Wi-Fi again, as it was).</summary>
    Back,

    /// <summary>It couldn't go back by itself: <see cref="PrinterSetupGuide.Problem"/> says how.</summary>
    CouldNotReturn,
}

/// <summary>
/// Setting up a new printer's Wi-Fi (roadmap 4.17, the owner's "middle option"): find the printer's setup network nearby, join it on the
/// person's click (an open one with a temporary profile; a secured one through Windows' own Wi-Fi list, where the person types its
/// password into Windows), open the printer's own setup page where the person enters the home Wi-Fi's details, then go back to the
/// network the PC was on. Inkvolt Print never reads, keeps or sends a Wi-Fi password; it never changes networks except on a click; and
/// whatever happens after it left (Done, Cancel, the window closed, the printer's network gone) it goes back, or says how to.
/// Calls are serialized; <see cref="Changed"/> comes from any thread.
/// </summary>
public sealed class PrinterSetupGuide(IWifi wifi, Action<string>? log = null, TimeProvider? time = null)
{
    private readonly Action<string> _log = log ?? (_ => { });
    private readonly TimeProvider _time = time ?? TimeProvider.System;
    private readonly SemaphoreSlim _calls = new(1, 1);
    private readonly Lock _gate = new();
    private SetupStep _step = SetupStep.Looking;
    private IReadOnlyList<SetupCandidate> _candidates = [];
    private SetupCandidate? _joined;
    private WifiNow? _before;
    private Uri? _page;
    private string? _problem;

    /// <summary>How long joining (or going back) may take before it's given up on.</summary>
    public static readonly TimeSpan JoinLimit = TimeSpan.FromSeconds(30);

    /// <summary>How long the guide waits for the person to connect in Windows' own list.</summary>
    public static readonly TimeSpan WindowsLimit = TimeSpan.FromMinutes(3);

    public event Action? Changed;

    public SetupStep Step
    {
        get { lock (_gate) return _step; }
    }

    public IReadOnlyList<SetupCandidate> Candidates
    {
        get { lock (_gate) return _candidates; }
    }

    /// <summary>The printer's network it joined.</summary>
    public SetupCandidate? Joined
    {
        get { lock (_gate) return _joined; }
    }

    /// <summary>The printer's own setup page, while on its network.</summary>
    public Uri? Page
    {
        get { lock (_gate) return _page; }
    }

    /// <summary>What went wrong, or what to do by hand, in plain words.</summary>
    public string? Problem
    {
        get { lock (_gate) return _problem; }
    }

    /// <summary>The network the PC was on before (null: none, or not left yet).</summary>
    public string? HomeName
    {
        get { lock (_gate) return _before?.Name; }
    }

    /// <summary>The PC left its network for the printer's and hasn't gone back yet.</summary>
    public bool IsAway
    {
        get { lock (_gate) return _before is not null && _step is SetupStep.Connecting or SetupStep.InWindows or SetupStep.OnPrinter or SetupStep.Returning or SetupStep.CouldNotReturn; }
    }

    /// <summary>Lists the printers' networks nearby. Read only.</summary>
    public async Task LookAsync(CancellationToken ct = default)
    {
        await _calls.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (IsAway) return;
            Set(SetupStep.Looking, problem: null);
            WifiNow now;
            try
            {
                now = await wifi.NowAsync(ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _log($"Printer setup: Wi-Fi not read: {ex.GetType().Name}");
                now = WifiNow.NoAdapter;
            }
            if (!now.HasAdapter)
            {
                Set(SetupStep.NoWifi, CoreStrings.Setup_NoWifi);
                return;
            }
            IReadOnlyList<WifiNetwork> nearby;
            try
            {
                nearby = await wifi.NearbyAsync(ct).ConfigureAwait(false);
            }
            catch (WifiLocationException)
            {
                Set(SetupStep.LocationOff, CoreStrings.Setup_LocationOff);
                return;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _log($"Printer setup: networks not listed: {ex.GetType().Name}: {ex.Message}");
                Set(SetupStep.Choose, CoreStrings.Setup_NotListed);
                return;
            }
            var found = SetupNetworks.Find(nearby.Where(n => !now.IsOn(n)));
            lock (_gate) _candidates = found;
            _log($"Printer setup: {nearby.Count} network(s) nearby, {found.Count} like a printer's.");
            Set(SetupStep.Choose, found.Count == 0 ? CoreStrings.Setup_NoneFound : null);
        }
        finally
        {
            _calls.Release();
            Raise();
        }
    }

    /// <summary>
    /// The person clicked Connect on <paramref name="candidate"/>: an open network is joined here (temporary profile); a secured one is
    /// left to Windows' own Wi-Fi list (<paramref name="openWindowsList"/>), and the guide waits to see the PC on it. Either way the
    /// network the PC is on now is remembered to go back to.
    /// </summary>
    public async Task ConnectAsync(SetupCandidate candidate, Action openWindowsList, CancellationToken ct = default)
    {
        await _calls.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (IsAway || !Candidates.Contains(candidate)) return;
            var before = await wifi.NowAsync(ct).ConfigureAwait(false);
            lock (_gate)
            {
                _before = before;
                _joined = candidate;
                _page = null;
            }
            if (SetupNetworks.OpenProfile(candidate.Network) is { } profile)
            {
                Set(SetupStep.Connecting, null);
                Raise();
                _log("Printer setup: joining the printer's open network (the person's click).");
                try
                {
                    await wifi.ConnectOpenAsync(candidate.Network, profile, ct).ConfigureAwait(false);
                }
                catch (Exception ex) when (ex is not OperationCanceledException)
                {
                    _log($"Printer setup: not joined: {ex.GetType().Name}: {ex.Message}");
                }
            }
            else
            {
                Set(SetupStep.InWindows, string.Format(CoreStrings.Setup_InWindows, candidate.Network.Name));
                Raise();
                _log("Printer setup: the printer's network asks for a password: Windows' own list is opened.");
                openWindowsList();
            }
            var limit = candidate.Network.Secured ? WindowsLimit : JoinLimit;
            if (await WaitForAsync(n => n.IsOn(candidate.Network), limit, ct).ConfigureAwait(false))
            {
                await FindPageAsync(ct).ConfigureAwait(false);
                return;
            }
            _log("Printer setup: the PC didn't join the printer's network in time.");
            await ReturnCoreAsync(CoreStrings.Setup_NotJoined, ct).ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
            await ReturnCoreAsync(null, CancellationToken.None).ConfigureAwait(false);
            throw;
        }
        finally
        {
            _calls.Release();
            Raise();
        }
    }

    /// <summary>On the printer's network: its setup page is its gateway (the printer is the access point).</summary>
    private async Task FindPageAsync(CancellationToken ct)
    {
        Uri? page = null;
        for (var i = 0; i < 10 && page is null; i++)
        {
            page = SetupNetworks.SetupPage(await wifi.GatewayAsync(ct).ConfigureAwait(false));
            if (page is null) await Task.Delay(TimeSpan.FromSeconds(1), _time, ct).ConfigureAwait(false); // the printer's DHCP answers after the join
        }
        lock (_gate) _page = page;
        Set(SetupStep.OnPrinter, page is null ? CoreStrings.Setup_NoPage : null);
        _log(page is null ? "Printer setup: on the printer's network, no setup page found." : "Printer setup: on the printer's network.");
    }

    /// <summary>The person is done on the printer's page (or cancels): back to the network the PC was on.</summary>
    public async Task ReturnAsync(CancellationToken ct = default)
    {
        await _calls.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            await ReturnCoreAsync(null, ct).ConfigureAwait(false);
        }
        finally
        {
            _calls.Release();
            Raise();
        }
    }

    /// <summary>
    /// Back where the PC was: by Windows' saved profile for that network, or off Wi-Fi if it wasn't on any; already there is fine. When
    /// that fails, <see cref="SetupStep.CouldNotReturn"/> says to choose the network in Windows' list. Inside <see cref="_calls"/>.
    /// </summary>
    private async Task ReturnCoreAsync(string? why, CancellationToken ct)
    {
        WifiNow before;
        lock (_gate)
        {
            if (_before is null) return;
            before = _before;
        }
        Set(SetupStep.Returning, why);
        Raise();
        var home = before.Name ?? "";
        try
        {
            var now = await wifi.NowAsync(ct).ConfigureAwait(false);
            if (before.Connected && before.Ssid is { } ssid && now.Ssid is { } at && at.AsSpan().SequenceEqual(ssid))
            {
                Done(why);
                return;
            }
            if (!before.Connected)
            {
                if (now.Connected) await wifi.DisconnectAsync(ct).ConfigureAwait(false);
                Done(why);
                return;
            }
            if (before.Profile is { Length: > 0 } profile)
            {
                _log("Printer setup: going back to the network the PC was on.");
                await wifi.ConnectProfileAsync(profile, ct).ConfigureAwait(false);
                if (await WaitForAsync(n => n.Ssid is { } s && before.Ssid is { } b && s.AsSpan().SequenceEqual(b), JoinLimit, ct).ConfigureAwait(false))
                {
                    Done(why);
                    return;
                }
            }
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            _log($"Printer setup: not back by itself: {ex.GetType().Name}: {ex.Message}");
        }
        Set(SetupStep.CouldNotReturn, string.Format(CoreStrings.Setup_CouldNotReturn, home));
        _log("Printer setup: couldn't go back by itself; the person is told how.");
    }

    private void Done(string? why)
    {
        lock (_gate) _page = null;
        Set(SetupStep.Back, why);
        _log("Printer setup: back on the network the PC was on.");
    }

    /// <summary>Back by the person's own hand in Windows' list: checked, and the guide goes on as if it had gone back itself.</summary>
    public async Task CheckBackAsync(CancellationToken ct = default)
    {
        await _calls.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (Step != SetupStep.CouldNotReturn) return;
            await ReturnCoreAsync(null, ct).ConfigureAwait(false);
        }
        finally
        {
            _calls.Release();
            Raise();
        }
    }

    /// <summary>
    /// The printer, found on the home network once back: of the printers listed now (<paramref name="now"/>: id and name, as discovery
    /// lists them), one that wasn't there before the PC left (<paramref name="before"/>), the maker's name first. Null while none is.
    /// </summary>
    public static (string Id, string Name)? FoundPrinter(IEnumerable<(string Id, string Name)> now, IReadOnlySet<string> before, string? maker) =>
        now.Where(p => !before.Contains(p.Id))
            .OrderByDescending(p => maker is { Length: > 0 } && p.Name.Contains(maker, StringComparison.OrdinalIgnoreCase))
            .Select(p => ((string, string)?)p).FirstOrDefault();

    private async Task<bool> WaitForAsync(Func<WifiNow, bool> condition, TimeSpan limit, CancellationToken ct)
    {
        var until = _time.GetUtcNow() + limit;
        while (true)
        {
            try
            {
                if (condition(await wifi.NowAsync(ct).ConfigureAwait(false))) return true;
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                // the adapter is between networks: asked again
            }
            if (_time.GetUtcNow() >= until) return false;
            await Task.Delay(TimeSpan.FromSeconds(1), _time, ct).ConfigureAwait(false);
        }
    }

    private void Set(SetupStep step, string? problem)
    {
        lock (_gate)
        {
            _step = step;
            _problem = problem;
        }
    }

    private void Raise()
    {
        try { Changed?.Invoke(); }
        catch (Exception ex) { _log($"Printer setup: {ex.Message}"); }
    }
}
