using System.Net;
using System.Net.Sockets;
using System.Text;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Core.Sharing;

/// <summary>One Windows queue chosen to be shared with phones (the app keeps the list with its settings), and the UUID it's announced with, made once and kept.</summary>
public sealed record PrinterShareChoice(string Queue, Guid Uuid);

/// <summary>Where the shared printers stand (one server for all of them).</summary>
public enum PrinterShareState
{
    /// <summary>No queue is shared: nothing listens.</summary>
    Off,

    /// <summary>Queues are chosen, none of them is on this PC now (removed, renamed): nothing listens until one is.</summary>
    WaitingForPrinter,

    /// <summary>No network Windows calls Private: nothing listens until one is.</summary>
    NoPrivateNetwork,

    Starting,

    /// <summary>Listening and announced.</summary>
    On,

    /// <summary>Couldn't start (<see cref="PrinterShare.Problem"/> says why).</summary>
    Failed,
}

/// <summary>
/// What the IPP server listens with: address and port, who may connect, how a request is answered, the largest body. A POST's first
/// <paramref name="HeadBytes"/> (its attributes) go to <paramref name="Precheck"/> with the body's declared length before the rest is
/// read: an answer there (busy, too large) is sent and the rest never read. Only a request <paramref name="CarriesDocument"/> says
/// carries one (Print-Job) is read, and held, past its head, up to <paramref name="MaxBodyBytes"/>; with none given, no request is.
/// </summary>
public sealed record PrinterListen(IPAddress Address, int Port, Func<IPAddress, IPAddress, bool> AllowPeer,
    Func<ShareRequest, CancellationToken, Task<ShareReply>> Handle, long MaxBodyBytes, int HeadBytes = 64 * 1024,
    Func<ShareRequest, long?, ShareReply?>? Precheck = null, ShareBudget? Budget = null, Func<ShareRequest, bool>? CarriesDocument = null);

/// <summary>Starts the shared printers' IPP server (Kestrel in the app, plain HTTP as IPP printers use). Fails with <see cref="SocketException"/> when the port is taken.</summary>
public interface IPrinterShareHost
{
    Task<IShareListener> StartAsync(PrinterListen listen, CancellationToken ct);
}

/// <summary>
/// What printer sharing works through: the server, this PC's networks, DNS-SD, what a queue offers (<paramref name="Describe"/>: null for
/// a queue it can't read or that can't be shared) and where jobs print (<paramref name="Sink"/>). <paramref name="LoopbackOnly"/> (demo
/// mode, tests): 127.0.0.1 only, any free port, nothing announced, no private network needed.
/// </summary>
public sealed record PrinterShareEnvironment(IPrinterShareHost Host, IShareNetworks Networks, IShareAdvertiser Advertiser,
    Func<string, CancellationToken, Task<SharedQueue?>> Describe, ISharedPrintSink Sink, int Port = PrinterShare.DefaultPort, bool LoopbackOnly = false);

/// <summary>What a printer's "Share with phones" card shows.</summary>
public sealed record PrinterShareCard(bool IsShown, bool IsOn, string Text);

/// <summary>
/// Windows queues shared with phones (print/ROADMAP.md 4.10, free): each a printer phones find over DNS-SD (<c>_ipp._tcp</c>, with
/// AirPrint's and Mopria's TXT keys) and print to over IPP (<see cref="SharedPrinter"/>), printed on the Windows queue. Off by default, a
/// switch per printer, only on networks Windows calls Private, only while the app (or its notification-area icon) runs; one server on
/// <see cref="DefaultPort"/> for all of them, which stops the moment the last is turned off, the last private network goes or the app
/// closes. A queue that saves to a file or an app (<see cref="CanShare"/>) isn't offered. Calls are serialized; <see cref="Changed"/>
/// comes from any thread.
/// </summary>
public sealed class PrinterShare : IAsyncDisposable
{
    /// <summary>The port (TCP, IPP over plain HTTP); the packaged app's firewall rule opens it for private networks.</summary>
    public const int DefaultPort = 9782;

    private readonly PrinterShareEnvironment _env;
    private readonly string _computerName;
    private readonly Action<IReadOnlyList<PrinterShareChoice>> _save;
    private readonly Action<string> _log;
    private readonly PrinterShareLimits _limits;
    private readonly TimeProvider _time;
    private readonly SemaphoreSlim _calls = new(1, 1);
    private readonly Lock _gate = new();
    private readonly CancellationTokenSource _closing = new();
    private readonly ShareBudget _budget;

    private List<PrinterShareChoice> _choices;
    private HashSet<string> _present = new(StringComparer.OrdinalIgnoreCase);
    private HashSet<string> _unreadable = new(StringComparer.OrdinalIgnoreCase);
    private PrinterShareState _state = PrinterShareState.Off;
    private string? _problem, _note;
    private int? _port;
    private bool _closed, _watchingNetworks;
    private volatile IReadOnlyList<LocalNetwork> _served = [];
    private volatile Dictionary<string, SharedPrinter> _printers = new(StringComparer.Ordinal);
    private (IShareListener Listener, List<IAsyncDisposable> Adverts, string Key)? _running;

    public PrinterShare(PrinterShareEnvironment env, string computerName, IReadOnlyList<PrinterShareChoice>? choices,
        Action<IReadOnlyList<PrinterShareChoice>> save, Action<string>? log = null, PrinterShareLimits? limits = null, TimeProvider? time = null)
    {
        _env = env;
        _computerName = computerName;
        _choices = [.. (choices ?? []).Where(c => c is { Queue.Length: > 0 }).DistinctBy(c => c.Queue, StringComparer.OrdinalIgnoreCase).Take(MaxShared)];
        _save = save;
        _log = log ?? (_ => { });
        _limits = limits ?? new PrinterShareLimits();
        _budget = new ShareBudget(_limits.MaxBytesHeld);
        _time = time ?? TimeProvider.System;
    }

    /// <summary>Printers shared at once.</summary>
    public const int MaxShared = 8;

    public event Action? Changed;

    public IReadOnlyList<PrinterShareChoice> Choices
    {
        get { lock (_gate) return [.. _choices]; }
    }

    public bool IsShared(string queue) => Choices.Any(c => string.Equals(c.Queue, queue, StringComparison.OrdinalIgnoreCase));

    public PrinterShareState State
    {
        get { lock (_gate) return _state; }
    }

    public int? Port
    {
        get { lock (_gate) return _port; }
    }

    public string? Problem
    {
        get { lock (_gate) return _problem; }
    }

    /// <summary>The printers served now (for tests and the server).</summary>
    public IReadOnlyList<SharedPrinter> Served => [.. _printers.Values];

    /// <summary>
    /// Whether a queue can take jobs from phones: not one that saves to a file (Microsoft Print to PDF, the XPS writer, a FILE: or
    /// PORTPROMPT: port, which would ask this PC for a file name) or hands the job to an app (OneNote).
    /// </summary>
    public static bool CanShare(SpoolerQueue queue)
    {
        var port = queue.PortName.Trim();
        if (port.Length == 0 || port.Equals("FILE:", StringComparison.OrdinalIgnoreCase) || port.Equals("PORTPROMPT:", StringComparison.OrdinalIgnoreCase)
            || port.Equals("NUL:", StringComparison.OrdinalIgnoreCase) || port.Contains("onenote", StringComparison.OrdinalIgnoreCase)
            || port.EndsWith(".prn", StringComparison.OrdinalIgnoreCase) || port.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase)) return false;
        var driver = queue.DriverName ?? "";
        return !(driver.Contains("Print To PDF", StringComparison.OrdinalIgnoreCase) || driver.Contains("XPS Document Writer", StringComparison.OrdinalIgnoreCase)
                 || driver.Contains("Virtual Print", StringComparison.OrdinalIgnoreCase) || driver.Contains("OneNote", StringComparison.OrdinalIgnoreCase)
                 || driver.Contains("Fax", StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>The card for a printer known by <paramref name="queue"/> (hidden for none, or one that can't be shared).</summary>
    public PrinterShareCard Card(SpoolerQueue? queue)
    {
        if (queue is null || !CanShare(queue)) return new PrinterShareCard(false, false, "");
        var on = IsShared(queue.Name);
        return new PrinterShareCard(true, on, Text(queue.Name));
    }

    /// <summary>The card's line for <paramref name="queue"/>.</summary>
    public string Text(string queue)
    {
        PrinterShareState state;
        string? problem, note;
        int? port;
        bool present, unreadable;
        lock (_gate) (state, problem, note, port, present, unreadable) = (_state, _problem, _note, _port, _present.Contains(queue), _unreadable.Contains(queue));
        if (!IsShared(queue)) return CoreStrings.PrinterShare_Off;
        if (!present && state != PrinterShareState.NoPrivateNetwork) return CoreStrings.PrinterShare_WaitingForPrinter;
        if (unreadable && state is PrinterShareState.On or PrinterShareState.WaitingForPrinter) return CoreStrings.PrinterShare_Unreadable;
        return state switch
        {
            PrinterShareState.WaitingForPrinter => CoreStrings.PrinterShare_WaitingForPrinter,
            PrinterShareState.NoPrivateNetwork => CoreStrings.PrinterShare_NoPrivateNetwork,
            PrinterShareState.Starting => CoreStrings.PrinterShare_Starting,
            PrinterShareState.On => string.Format(_env.LoopbackOnly ? CoreStrings.PrinterShare_OnThisPc : CoreStrings.PrinterShare_On,
                InstanceName(queue, _computerName), port ?? 0) + (note is null ? "" : " " + note),
            PrinterShareState.Failed => problem ?? CoreStrings.PrinterShare_Failed,
            _ => CoreStrings.PrinterShare_Off,
        };
    }

    /// <summary>Shares <paramref name="queue"/> (kept on across restarts); refused for one that can't be shared or past <see cref="MaxShared"/>.</summary>
    public async Task<bool> TurnOnAsync(SpoolerQueue queue)
    {
        if (!CanShare(queue)) return false;
        await _calls.WaitAsync().ConfigureAwait(false);
        try
        {
            if (Closed) return false;
            List<PrinterShareChoice> choices;
            lock (_gate)
            {
                if (_choices.Any(c => string.Equals(c.Queue, queue.Name, StringComparison.OrdinalIgnoreCase))) return true;
                if (_choices.Count >= MaxShared) return false;
                _choices.Add(new PrinterShareChoice(queue.Name, Guid.NewGuid()));
                _present.Add(queue.Name);
                choices = [.. _choices];
            }
            _save(choices);
            _log("Printer sharing turned on for a printer.");
            await ApplyAsync().ConfigureAwait(false);
        }
        finally
        {
            _calls.Release();
        }
        Raise();
        return true;
    }

    /// <summary>Stops sharing <paramref name="queue"/>: it's no longer announced or served; the server stops with the last one.</summary>
    public async Task TurnOffAsync(string queue)
    {
        await _calls.WaitAsync().ConfigureAwait(false);
        try
        {
            List<PrinterShareChoice> choices;
            lock (_gate)
            {
                _choices.RemoveAll(c => string.Equals(c.Queue, queue, StringComparison.OrdinalIgnoreCase));
                choices = [.. _choices];
            }
            if (!Closed) _save(choices);
            _log("Printer sharing turned off for a printer.");
            if (!Closed) await ApplyAsync().ConfigureAwait(false);
        }
        finally
        {
            _calls.Release();
        }
        Raise();
    }

    /// <summary>The queues on this PC now (the app's list, read every 30 s and on the spooler's notices): a shared one that's gone stops being served.</summary>
    public async Task OfferAsync(IEnumerable<string> queues)
    {
        var present = queues.ToHashSet(StringComparer.OrdinalIgnoreCase);
        lock (_gate)
        {
            // Nothing new, unless a shared queue couldn't be read or the server couldn't start last time: both are tried again with each list.
            if (present.SetEquals(_present) && _unreadable.Count == 0
                && (_choices.Count == 0 || _state is not (PrinterShareState.Off or PrinterShareState.Failed))) return;
        }
        await _calls.WaitAsync().ConfigureAwait(false);
        try
        {
            lock (_gate) _present = present;
            if (!Closed) await ApplyAsync().ConfigureAwait(false);
        }
        finally
        {
            _calls.Release();
        }
        Raise();
    }

    /// <summary>Asks again whether it may run (after the networks changed).</summary>
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

    private void WatchNetworks(bool on)
    {
        on &= !_env.LoopbackOnly && !Closed;
        if (on == _watchingNetworks) return;
        _watchingNetworks = on;
        if (on) _env.Networks.Changed += OnNetworksChanged;
        else _env.Networks.Changed -= OnNetworksChanged;
    }

    private void OnNetworksChanged() => _ = NetworksChangedAsync();

    private async Task NetworksChangedAsync()
    {
        try
        {
            await Task.Delay(TimeSpan.FromSeconds(2), _time).ConfigureAwait(false);
            await RecheckAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _log($"Printer sharing: networks not read again: {ex.Message}");
        }
    }

    /// <summary>Starts, stops, or changes what's served and announced to match the choices, the queues and the networks. Inside <see cref="_calls"/>.</summary>
    private async Task ApplyAsync()
    {
        List<PrinterShareChoice> wanted;
        lock (_gate) wanted = [.. _choices.Where(c => _present.Contains(c.Queue))];
        bool any;
        lock (_gate) any = _choices.Count > 0;
        WatchNetworks(any);
        if (!any) lock (_gate) _unreadable = new(StringComparer.OrdinalIgnoreCase);
        if (!any || wanted.Count == 0)
        {
            await StopRunningAsync().ConfigureAwait(false);
            SetState(any ? PrinterShareState.WaitingForPrinter : PrinterShareState.Off);
            return;
        }
        IReadOnlyList<LocalNetwork> served = [];
        if (!_env.LoopbackOnly)
        {
            try
            {
                served = SharePeers.Served(_env.Networks.Read());
            }
            catch (Exception ex)
            {
                _log($"Printer sharing: this PC's networks couldn't be read: {ex.Message}");
            }
            if (served.Count == 0)
            {
                await StopRunningAsync().ConfigureAwait(false);
                SetState(PrinterShareState.NoPrivateNetwork);
                return;
            }
        }
        _served = served;

        // What each queue offers now (read off the queue: color, two-sided, paper); one that can't be read isn't served this time.
        var printers = new Dictionary<string, SharedPrinter>(StringComparer.Ordinal);
        var old = _printers;
        var unreadable = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var choice in wanted)
        {
            SharedQueue? queue;
            try
            {
                queue = await _env.Describe(choice.Queue, _closing.Token).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException)
            {
                _log($"Printer sharing: a queue couldn't be read: {ex.GetType().Name}");
                queue = null;
            }
            if (queue is null)
            {
                unreadable.Add(choice.Queue); // said on its card; read again with the next list of queues
                continue;
            }
            var path = SharedPrinter.PathOf(choice.Uuid);
            printers[path] = old.TryGetValue(path, out var kept) && kept.Queue == queue
                ? kept
                : new SharedPrinter(queue, choice.Uuid, InstanceName(choice.Queue, _computerName), _computerName, _env.Sink, _limits, _time, _log, _budget);
        }
        foreach (var (path, printer) in old)
            if (!printers.TryGetValue(path, out var same) || !ReferenceEquals(same, printer)) printer.Dispose();
        _printers = printers;
        lock (_gate) _unreadable = unreadable;
        if (printers.Count == 0)
        {
            await StopRunningAsync().ConfigureAwait(false);
            SetState(PrinterShareState.WaitingForPrinter);
            return;
        }
        var key = string.Join(';', served.Select(n => $"{n.InterfaceIndex}/{n.Address}/{n.PrefixLength}").Order())
                  + "|" + string.Join(';', printers.Values.Select(p => $"{p.Uuid}/{p.Queue}").Order());
        if (_running is { } running)
        {
            if (running.Key == key) return;
            await Task.WhenAll(running.Adverts.Select(DisposeQuietlyAsync)).ConfigureAwait(false);
            var adverts = _env.LoopbackOnly ? [] : await AdvertiseAsync(printers.Values, running.Listener.Port, served).ConfigureAwait(false);
            _running = (running.Listener, adverts, key);
            SetState(PrinterShareState.On);
            return;
        }
        await StartAsync(served, key).ConfigureAwait(false);
    }

    private async Task StartAsync(IReadOnlyList<LocalNetwork> served, string key)
    {
        SetState(PrinterShareState.Starting);
        Raise();
        try
        {
            var address = _env.LoopbackOnly ? IPAddress.Loopback : IPAddress.IPv6Any;
            var loopbackOnly = _env.LoopbackOnly;
            var listener = await _env.Host.StartAsync(new PrinterListen(address, _env.Port,
                (peer, local) => loopbackOnly ? IPAddress.IsLoopback(SharePeers.Normal(peer)) : SharePeers.Allows(peer, local, _served),
                HandleAsync, _limits.MaxDocumentBytes + _limits.MaxAttributeBytes, _limits.MaxAttributeBytes, Precheck, _budget, SharedPrinter.CarriesDocument), _closing.Token).ConfigureAwait(false);
            if (_closing.IsCancellationRequested)
            {
                await DisposeQuietlyAsync(listener).ConfigureAwait(false);
                throw new OperationCanceledException(_closing.Token);
            }
            var adverts = _env.LoopbackOnly ? [] : await AdvertiseAsync(_printers.Values, listener.Port, served).ConfigureAwait(false);
            _running = (listener, adverts, key);
            lock (_gate)
            {
                _port = listener.Port;
                _problem = null;
            }
            SetState(PrinterShareState.On);
            _log($"Printer sharing: listening on port {listener.Port} ({(_env.LoopbackOnly ? "this PC only" : $"{served.Count} private network address(es)")}, {_printers.Count} printer(s)).");
        }
        catch (Exception ex)
        {
            var problem = ex is SocketException { SocketErrorCode: SocketError.AddressAlreadyInUse } || ex.InnerException is SocketException { SocketErrorCode: SocketError.AddressAlreadyInUse }
                ? string.Format(CoreStrings.PrinterShare_PortInUse, _env.Port)
                : CoreStrings.PrinterShare_Failed;
            lock (_gate) _problem = problem;
            SetState(PrinterShareState.Failed);
            _log($"Printer sharing didn't start: {ex.GetType().Name}: {ex.Message}");
        }
    }

    /// <summary>A request's head, before its document is read: the printer it names may refuse it now (<see cref="SharedPrinter.Precheck"/>).</summary>
    public ShareReply? Precheck(ShareRequest head, long? declaredLength) =>
        _printers.TryGetValue(head.Path.TrimEnd('/'), out var printer) ? printer.Precheck(head, declaredLength) : null;

    /// <summary>A request to the server: to the printer whose path it names; anything else isn't found.</summary>
    public Task<ShareReply> HandleAsync(ShareRequest request, CancellationToken ct)
    {
        var path = request.Path.TrimEnd('/');
        return _printers.TryGetValue(path, out var printer) ? printer.HandleAsync(request, ct) : Task.FromResult(ShareReply.Empty(404));
    }

    private async Task<List<IAsyncDisposable>> AdvertiseAsync(IEnumerable<SharedPrinter> printers, int port, IReadOnlyList<LocalNetwork> served)
    {
        var adverts = new List<IAsyncDisposable>();
        var failed = false;
        foreach (var printer in printers)
        {
            try
            {
                adverts.Add(await _env.Advertiser.AdvertiseAsync(PrinterDnssd.For(printer, _computerName, port), served, _closing.Token).ConfigureAwait(false));
            }
            catch (Exception ex) when (ex is not OperationCanceledException || !_closing.IsCancellationRequested)
            {
                failed = true;
                _log($"Printer sharing: not announced on the network: {ex.GetType().Name}: {ex.Message}");
            }
        }
        lock (_gate) _note = failed ? CoreStrings.PrinterShare_NotAnnounced : null;
        return adverts;
    }

    private async Task StopRunningAsync()
    {
        if (_running is { } running)
        {
            _running = null;
            lock (_gate)
            {
                _port = null;
                _note = null;
            }
            await Task.WhenAll([.. running.Adverts.Select(DisposeQuietlyAsync), DisposeQuietlyAsync(running.Listener)]).ConfigureAwait(false);
            _log("Printer sharing: stopped listening.");
        }
        foreach (var printer in _printers.Values) printer.Dispose();
        _printers = new Dictionary<string, SharedPrinter>(StringComparer.Ordinal);
    }

    private async Task DisposeQuietlyAsync(IAsyncDisposable thing)
    {
        try
        {
            await thing.DisposeAsync().ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _log($"Printer sharing: not closed cleanly: {ex.GetType().Name}: {ex.Message}");
        }
    }

    private void SetState(PrinterShareState state)
    {
        lock (_gate) _state = state;
    }

    private void Raise()
    {
        try { Changed?.Invoke(); }
        catch (Exception ex) { _log($"Printer sharing: {ex.Message}"); }
    }

    /// <summary>"Printer on PC" in the app's language: no dots or control characters, cut to DNS-SD's 63 bytes.</summary>
    public static string InstanceName(string queue, string computerName)
    {
        var name = string.Format(CoreStrings.PrinterShare_InstanceName, queue.Trim(), computerName.Trim());
        var clean = string.Join(' ', new string([.. name.Select(c => char.IsControl(c) || c is '.' or '\\' ? ' ' : c)]).Split(' ', StringSplitOptions.RemoveEmptyEntries));
        if (clean.Length == 0) clean = "Inkvolt Print printer";
        while (Encoding.UTF8.GetByteCount(clean) > 63) clean = clean[..^(char.IsLowSurrogate(clean[^1]) && clean.Length > 1 ? 2 : 1)];
        return clean.TrimEnd();
    }

    /// <summary>The app closes: the port closes and every announcement ends; the choices are kept for the next start.</summary>
    public async ValueTask DisposeAsync()
    {
        lock (_gate) _closed = true;
        _closing.Cancel();
        await _calls.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_watchingNetworks)
            {
                _watchingNetworks = false;
                _env.Networks.Changed -= OnNetworksChanged;
            }
            await StopRunningAsync().ConfigureAwait(false);
            SetState(PrinterShareState.Off);
        }
        finally
        {
            _calls.Release();
        }
    }
}

/// <summary>
/// The DNS-SD record for a shared printer (<c>_ipp._tcp</c>): IPP Everywhere's and Mopria's keys (txtvers, qtotal, rp, ty, pdl, UUID,
/// Color, Duplex, note, kind, PaperMax) and AirPrint's (URF). Windows' DNS-SD API registers no subtype: AirPrint's <c>_universal</c>
/// is answered by Inkvolt Print's own responder (<see cref="MdnsSubtype"/>; README, "Share a printer with phones").
/// </summary>
public static class PrinterDnssd
{
    public static ShareAdvert For(SharedPrinter printer, string computerName, int port)
    {
        var queue = printer.Queue;
        var txt = new List<KeyValuePair<string, string>>
        {
            new("txtvers", "1"),
            new("qtotal", "1"),
            new("rp", printer.Path.TrimStart('/')),
            new("ty", Cut($"{queue.Name} (Inkvolt Print)", 200)),
            new("product", "(Inkvolt Print)"),
            new("note", Cut(computerName, 200)),
            new("pdl", string.Join(',', SharedPrinter.Formats.Where(f => f != "application/octet-stream"))),
            new("URF", string.Join(',', new[] { "V1.4", "CP1", "W8", queue.Color ? "SRGB24" : null, "RS300", queue.TwoSided ? "DM1" : null, "IS1", "MT1", "PQ4" }.OfType<string>())),
            new("UUID", printer.Uuid.ToString("D")),
            new("Color", queue.Color ? "T" : "F"),
            new("Duplex", queue.TwoSided ? "T" : "F"),
            new("kind", "document,photo"),
            new("PaperMax", "legal-A4"),
        };
        // AirPrint's subtype: Windows' API can't register one; Inkvolt Print's own responder answers it (MdnsSubtype).
        return new ShareAdvert(printer.Name, ShareDnssd.HostName(computerName), port, txt, ShareAdvert.PrinterService) { Subtypes = ["_universal"] };
    }

    private static string Cut(string text, int max)
    {
        var clean = Alerts.AlertText.Clean(text, max);
        while (Encoding.UTF8.GetByteCount(clean) > max) clean = clean[..^1];
        return clean;
    }
}
