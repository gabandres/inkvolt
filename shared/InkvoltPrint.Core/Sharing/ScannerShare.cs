using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography.X509Certificates;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Core.Sharing;

/// <summary>What the person chose (the app keeps it with its settings): which scanner is shared, if any. Off by default.</summary>
/// <param name="DeviceId">The shared scanner's Windows id (WIA's, or "twain:" and the source); null: nothing shared.</param>
/// <param name="Name">Its name, for the card while it isn't connected.</param>
/// <param name="Uuid">The UUID it is announced with, made once and kept, so clients know it again after a restart.</param>
public sealed record ScannerShareChoice(string? DeviceId = null, string? Name = null, Guid? Uuid = null);

/// <summary>Where a share stands.</summary>
public enum ShareState
{
    /// <summary>Nothing shared: nothing listens.</summary>
    Off,

    /// <summary>Turned on, but Inkvolt Pro isn't unlocked: nothing listens.</summary>
    Locked,

    /// <summary>Turned on, the scanner isn't connected (off, unplugged): nothing listens until it is.</summary>
    WaitingForScanner,

    /// <summary>Turned on, no network Windows calls Private: nothing listens until one is.</summary>
    NoPrivateNetwork,

    /// <summary>Opening the port.</summary>
    Starting,

    /// <summary>Listening and announced.</summary>
    On,

    /// <summary>Couldn't start (<see cref="ScannerShare.Problem"/> says why): nothing listens.</summary>
    Failed,
}

/// <summary>This PC's networks (Windows' category and each address's subnet), and a word when they change.</summary>
public interface IShareNetworks
{
    IReadOnlyList<LocalNetwork> Read();

    /// <summary>An address or a network's category changed (from any thread).</summary>
    event Action? Changed;
}

/// <summary>What the HTTPS server listens with: its address and port, certificate, who may connect, and the scanner it serves.</summary>
public sealed record ShareListen(IPAddress Address, int Port, X509Certificate2 Certificate, Func<IPAddress, bool> AllowPeer, SharedScanner Scanner);

/// <summary>A listening server. Disposing closes its port at once (and ends the requests under way).</summary>
public interface IShareListener : IAsyncDisposable
{
    int Port { get; }
}

/// <summary>Starts the HTTPS server (Kestrel in the app). Fails with <see cref="SocketException"/> (AddressAlreadyInUse) when the port is taken.</summary>
public interface IShareHost
{
    Task<IShareListener> StartAsync(ShareListen listen, CancellationToken ct);
}

/// <summary>Announces the share over DNS-SD on the networks given, until the result is disposed.</summary>
public interface IShareAdvertiser
{
    Task<IAsyncDisposable> AdvertiseAsync(ShareAdvert advert, IReadOnlyList<LocalNetwork> on, CancellationToken ct);
}

/// <summary>The share's certificate with its private key, for this PC's <c>.local</c> name: kept per install (Windows) or made per run.</summary>
public interface IShareCertificates
{
    X509Certificate2 Get(string hostName, DateTimeOffset now);
}

/// <summary>
/// The adapters a share works through. <paramref name="LoopbackOnly"/> (demo mode): it listens on 127.0.0.1 only, for this PC alone,
/// announces nothing and needs no private network.
/// </summary>
public sealed record ShareEnvironment(IShareHost Host, IShareNetworks Networks, IShareAdvertiser Advertiser, IShareCertificates Certificates,
    int Port = ScannerShare.DefaultPort, bool LoopbackOnly = false)
{
    /// <summary>
    /// Sharing to this PC alone (demo mode, tests): <paramref name="host"/> on 127.0.0.1 and any free port, a certificate made for the run
    /// (its key in no store), no networks read and nothing announced.
    /// </summary>
    public static ShareEnvironment ThisPcOnly(IShareHost host) => new(host, NoNetworks.Instance, NoAdvertiser.Instance, RunCertificates.Instance, 0, true);

    private sealed class NoNetworks : IShareNetworks
    {
        public static readonly NoNetworks Instance = new();

        public IReadOnlyList<LocalNetwork> Read() => [];

        public event Action? Changed
        {
            add { }
            remove { }
        }
    }

    private sealed class NoAdvertiser : IShareAdvertiser
    {
        public static readonly NoAdvertiser Instance = new();

        public Task<IAsyncDisposable> AdvertiseAsync(ShareAdvert advert, IReadOnlyList<LocalNetwork> on, CancellationToken ct) =>
            Task.FromResult<IAsyncDisposable>(new Nothing());

        private sealed class Nothing : IAsyncDisposable
        {
            public ValueTask DisposeAsync() => ValueTask.CompletedTask;
        }
    }

    private sealed class RunCertificates : IShareCertificates
    {
        public static readonly RunCertificates Instance = new();

        public X509Certificate2 Get(string hostName, DateTimeOffset now) => ShareCertificate.Ephemeral(hostName, now);
    }
}

/// <summary>
/// A scanner of this PC shared on the network as an eSCL scanner (print/ROADMAP.md 3.1, Inkvolt Pro): one scanner at a time, off by
/// default, only on networks Windows calls Private, only while the app (or its notification-area icon) runs. Turned on, it listens
/// over HTTPS on <see cref="DefaultPort"/> with a self-signed certificate (<see cref="Fingerprint"/>), serves the scanner through a
/// <see cref="SharedScanner"/> and announces it as <c>_uscans._tcp</c>; it stops listening the moment it's turned off, Pro is gone,
/// the scanner goes, the last private network goes, or the app closes. The app hands it the shared device's connected scanner
/// (<see cref="OfferAsync"/>); calls are serialized; <see cref="Changed"/> comes from any thread.
/// </summary>
public sealed class ScannerShare : IAsyncDisposable
{
    /// <summary>The port it listens on (TCP, HTTPS); the packaged app's firewall rule opens it for private networks.</summary>
    public const int DefaultPort = 9780;

    private readonly ShareEnvironment _env;
    private readonly string _computerName;
    private readonly Action<ScannerShareChoice> _save;
    private readonly Func<bool> _allowed;
    private readonly Action<string> _log;
    private readonly ShareLimits? _limits;
    private readonly TimeProvider _time;
    private readonly SemaphoreSlim _calls = new(1, 1);
    private readonly Lock _gate = new();

    private ScannerShareChoice _choice;
    private WiaScanner? _scanner;
    private ShareState _state = ShareState.Off;
    private string? _problem, _fingerprint, _note;
    private int? _port;
    private bool _closed;
    private volatile IReadOnlyList<LocalNetwork> _served = [];
    private (SharedScanner Server, IShareListener Listener, IAsyncDisposable? Advert, X509Certificate2 Certificate, string Networks)? _running;

    /// <param name="allowed">Inkvolt Pro allows sharing (<see cref="Pro.Allows"/>); asked each time it would start.</param>
    /// <param name="save">Keeps the choice when it changes.</param>
    /// <param name="log">Told what happens, in plain words: never a device's address.</param>
    public ScannerShare(ShareEnvironment env, string computerName, ScannerShareChoice? choice, Action<ScannerShareChoice> save, Func<bool> allowed,
        Action<string>? log = null, ShareLimits? limits = null, TimeProvider? time = null)
    {
        _env = env;
        _computerName = computerName;
        _choice = choice ?? new ScannerShareChoice();
        _save = save;
        _allowed = allowed;
        _log = log ?? (_ => { });
        _limits = limits;
        _time = time ?? TimeProvider.System;
        if (!env.LoopbackOnly) env.Networks.Changed += OnNetworksChanged;
    }

    public event Action? Changed;

    public ScannerShareChoice Choice
    {
        get { lock (_gate) return _choice; }
    }

    /// <summary>A scanner is chosen to be shared (whether or not it's listening now).</summary>
    public bool IsOn => Choice.DeviceId is not null;

    public bool IsShared(string deviceId) => string.Equals(Choice.DeviceId, deviceId, StringComparison.OrdinalIgnoreCase);

    public ShareState State
    {
        get { lock (_gate) return _state; }
    }

    /// <summary>The port listened on, while <see cref="ShareState.On"/>.</summary>
    public int? Port
    {
        get { lock (_gate) return _port; }
    }

    /// <summary>The certificate's SHA-256 fingerprint, while <see cref="ShareState.On"/>.</summary>
    public string? Fingerprint
    {
        get { lock (_gate) return _fingerprint; }
    }

    /// <summary>Why it couldn't start, in plain words (<see cref="ShareState.Failed"/>).</summary>
    public string? Problem
    {
        get { lock (_gate) return _problem; }
    }

    /// <summary>The scanner card's line for the scanner <paramref name="deviceId"/>.</summary>
    public string Text(string deviceId)
    {
        ScannerShareChoice choice;
        ShareState state;
        string? problem, note;
        int? port;
        lock (_gate) (choice, state, problem, note, port) = (_choice, _state, _problem, _note, _port);
        if (choice.DeviceId is null) return CoreStrings.Share_Off;
        if (!IsShared(deviceId)) return string.Format(CoreStrings.Share_OtherShared, choice.Name ?? "");
        return state switch
        {
            ShareState.Locked => Pro.Locked(ProFeature.ScannerSharing),
            ShareState.WaitingForScanner => CoreStrings.Share_WaitingForScanner,
            ShareState.NoPrivateNetwork => CoreStrings.Share_NoPrivateNetwork,
            ShareState.Starting => CoreStrings.Share_Starting,
            ShareState.On => string.Format(_env.LoopbackOnly ? CoreStrings.Share_OnThisPc : CoreStrings.Share_On, choice.Name ?? "", port ?? 0)
                + (note is null ? "" : " " + note),
            ShareState.Failed => problem ?? CoreStrings.Share_Failed,
            _ => CoreStrings.Share_Off,
        };
    }

    /// <summary>Shares <paramref name="scanner"/> (instead of any other): it listens once Pro, a private network and the scanner allow.</summary>
    public async Task ShareAsync(WiaScanner scanner)
    {
        await _calls.WaitAsync().ConfigureAwait(false);
        try
        {
            if (Closed) return;
            var device = scanner.Device;
            var old = Choice;
            var choice = new ScannerShareChoice(device.Id, device.Name, old.Uuid ?? Guid.NewGuid());
            if (!string.Equals(old.DeviceId, device.Id, StringComparison.OrdinalIgnoreCase)) await StopRunningAsync().ConfigureAwait(false);
            lock (_gate)
            {
                _choice = choice;
                _scanner = scanner;
            }
            _save(choice);
            _log($"Scanner sharing turned on for {device.Name}.");
            await ApplyAsync().ConfigureAwait(false);
        }
        finally
        {
            _calls.Release();
        }
        Raise();
    }

    /// <summary>Turns sharing off: the port closes and the announcement ends now; jobs under way are cancelled.</summary>
    public async Task StopAsync()
    {
        await _calls.WaitAsync().ConfigureAwait(false);
        try
        {
            var choice = Choice with { DeviceId = null, Name = null };
            lock (_gate)
            {
                _choice = choice;
                _scanner = null;
            }
            await StopRunningAsync().ConfigureAwait(false);
            SetState(ShareState.Off);
            if (!Closed) _save(choice);
            _log("Scanner sharing turned off.");
        }
        finally
        {
            _calls.Release();
        }
        Raise();
    }

    /// <summary>
    /// The app's connected scanner for <paramref name="deviceId"/> (null: it's gone, off or unplugged). The shared one starts listening
    /// when it comes, and stops when it goes. Others are ignored.
    /// </summary>
    public async Task OfferAsync(string deviceId, WiaScanner? scanner)
    {
        if (!IsShared(deviceId)) return;
        await _calls.WaitAsync().ConfigureAwait(false);
        try
        {
            if (Closed || !IsShared(deviceId)) return;
            WiaScanner? before;
            lock (_gate)
            {
                before = _scanner;
                _scanner = scanner;
            }
            if (!ReferenceEquals(before, scanner)) await StopRunningAsync().ConfigureAwait(false);
            await ApplyAsync().ConfigureAwait(false);
        }
        finally
        {
            _calls.Release();
        }
        Raise();
    }

    /// <summary>Asks again whether it may run (after Inkvolt Pro was entered or removed).</summary>
    public async Task RecheckAsync()
    {
        await _calls.WaitAsync().ConfigureAwait(false);
        try
        {
            if (!Closed) await ApplyAsync().ConfigureAwait(false);
        }
        finally
        {
            _calls.Release();
        }
        Raise();
    }

    private bool Closed
    {
        get { lock (_gate) return _closed; }
    }

    private void OnNetworksChanged() => _ = NetworksChangedAsync();

    private async Task NetworksChangedAsync()
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(2), _time).ConfigureAwait(false); // addresses come and go in bursts
            await RecheckAsync().ConfigureAwait(false);
        }
        catch (Exception ex) // fire and forget: never unobserved
        {
            _log($"Scanner sharing: networks not read again: {ex.Message}");
        }
    }

    /// <summary>Starts, stops or re-announces to match the choice, Pro, the scanner and the networks. Inside <see cref="_calls"/>.</summary>
    private async Task ApplyAsync()
    {
        ScannerShareChoice choice;
        WiaScanner? scanner;
        lock (_gate) (choice, scanner) = (_choice, _scanner);
        if (choice.DeviceId is null)
        {
            await StopRunningAsync().ConfigureAwait(false);
            SetState(ShareState.Off);
            return;
        }
        if (!_allowed())
        {
            await StopRunningAsync().ConfigureAwait(false);
            SetState(ShareState.Locked);
            return;
        }
        if (scanner is null)
        {
            await StopRunningAsync().ConfigureAwait(false);
            SetState(ShareState.WaitingForScanner);
            return;
        }
        IReadOnlyList<LocalNetwork> served = [];
        if (!_env.LoopbackOnly)
        {
            try
            {
                served = SharePeers.Served(_env.Networks.Read());
            }
            catch (Exception ex) // can't tell: serve nobody
            {
                _log($"Scanner sharing: this PC's networks couldn't be read: {ex.Message}");
            }
            if (served.Count == 0)
            {
                await StopRunningAsync().ConfigureAwait(false);
                SetState(ShareState.NoPrivateNetwork);
                return;
            }
        }
        _served = served;
        var networks = string.Join(';', served.Select(n => $"{n.InterfaceIndex}/{n.Address}/{n.PrefixLength}").Order());
        if (_running is { } running)
        {
            if (running.Networks == networks) return;
            // The private networks changed: the same server, announced on the networks there are now.
            if (running.Advert is { } old) await DisposeQuietlyAsync(old).ConfigureAwait(false);
            var advert = await AdvertiseAsync(running.Server, scanner, running.Listener.Port, served).ConfigureAwait(false);
            _running = running with { Advert = advert, Networks = networks };
            SetState(ShareState.On);
            return;
        }
        await StartAsync(choice, scanner, served, networks).ConfigureAwait(false);
    }

    private async Task StartAsync(ScannerShareChoice choice, WiaScanner scanner, IReadOnlyList<LocalNetwork> served, string networks)
    {
        SetState(ShareState.Starting);
        Raise();
        var identity = new ShareIdentity(scanner.Device.Name, scanner.Device.Manufacturer, choice.Uuid ?? Guid.NewGuid());
        X509Certificate2? certificate = null;
        SharedScanner? server = null;
        try
        {
            certificate = _env.Certificates.Get(ShareDnssd.HostName(_computerName), _time.GetUtcNow());
            server = new SharedScanner(scanner, scanner.Capabilities, identity, _limits, _time, () => scanner.IsBusy, _log);
            var address = _env.LoopbackOnly ? IPAddress.Loopback : IPAddress.IPv6Any;
            var loopbackOnly = _env.LoopbackOnly;
            var listener = await _env.Host.StartAsync(new ShareListen(address, _env.Port, certificate, peer =>
                loopbackOnly ? IPAddress.IsLoopback(peer.IsIPv4MappedToIPv6 ? peer.MapToIPv4() : peer) : SharePeers.Allows(peer, _served), server),
                CancellationToken.None).ConfigureAwait(false);
            var advert = _env.LoopbackOnly ? null : await AdvertiseAsync(server, scanner, listener.Port, served).ConfigureAwait(false);
            _running = (server, listener, advert, certificate, networks);
            lock (_gate)
            {
                _port = listener.Port;
                _fingerprint = ShareCertificate.Fingerprint(certificate);
                _problem = null;
            }
            SetState(ShareState.On);
            _log($"Scanner sharing: listening on port {listener.Port} ({(_env.LoopbackOnly ? "this PC only" : $"{served.Count} private network address(es)")}).");
        }
        catch (Exception ex) // anything: nothing is left listening, and the card says why
        {
            server?.Dispose();
            certificate?.Dispose();
            var problem = ex is SocketException { SocketErrorCode: SocketError.AddressAlreadyInUse } || ex.InnerException is SocketException { SocketErrorCode: SocketError.AddressAlreadyInUse }
                || ex is IOException && ex.Message.Contains("address already in use", StringComparison.OrdinalIgnoreCase)
                ? string.Format(CoreStrings.Share_PortInUse, _env.Port)
                : CoreStrings.Share_Failed;
            lock (_gate) _problem = problem;
            SetState(ShareState.Failed);
            _log($"Scanner sharing didn't start: {ex.GetType().Name}: {ex.Message}");
        }
    }

    /// <summary>Announces the share; a failure leaves it listening (reachable by address) and says so on the card.</summary>
    private async Task<IAsyncDisposable?> AdvertiseAsync(SharedScanner server, WiaScanner scanner, int port, IReadOnlyList<LocalNetwork> served)
    {
        try
        {
            var advert = await _env.Advertiser.AdvertiseAsync(ShareDnssd.For(server.Identity, scanner.Capabilities, _computerName, port), served, CancellationToken.None)
                .ConfigureAwait(false);
            lock (_gate) _note = null;
            return advert;
        }
        catch (Exception ex)
        {
            lock (_gate) _note = CoreStrings.Share_NotAnnounced;
            _log($"Scanner sharing: not announced on the network: {ex.GetType().Name}: {ex.Message}");
            return null;
        }
    }

    /// <summary>Closes the port and ends the announcement, if running. Inside <see cref="_calls"/>.</summary>
    private async Task StopRunningAsync()
    {
        if (_running is not { } running) return;
        _running = null;
        lock (_gate)
        {
            _port = null;
            _fingerprint = null;
            _note = null;
        }
        running.Server.Dispose(); // jobs cancelled first, so no request waits on a page
        if (running.Advert is { } advert) await DisposeQuietlyAsync(advert).ConfigureAwait(false);
        await DisposeQuietlyAsync(running.Listener).ConfigureAwait(false);
        running.Certificate.Dispose();
        _log("Scanner sharing: stopped listening.");
    }

    private async Task DisposeQuietlyAsync(IAsyncDisposable thing)
    {
        try
        {
            await thing.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _log($"Scanner sharing: not closed cleanly: {ex.GetType().Name}: {ex.Message}");
        }
    }

    private void SetState(ShareState state)
    {
        lock (_gate) _state = state;
    }

    private void Raise()
    {
        try { Changed?.Invoke(); }
        catch (Exception ex) { _log($"Scanner sharing: {ex.Message}"); }
    }

    /// <summary>The app closes: the port closes and the announcement ends; the choice is kept for the next start.</summary>
    public async ValueTask DisposeAsync()
    {
        if (!_env.LoopbackOnly) _env.Networks.Changed -= OnNetworksChanged;
        await _calls.WaitAsync().ConfigureAwait(false);
        try
        {
            lock (_gate) _closed = true;
            await StopRunningAsync().ConfigureAwait(false);
            SetState(ShareState.Off);
        }
        finally
        {
            _calls.Release();
        }
    }
}
