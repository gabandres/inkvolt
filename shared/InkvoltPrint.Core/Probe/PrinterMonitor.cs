using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Core.Probe;

/// <summary>What the printer pane shows for one network printer, as its printer monitor keeps it (<see cref="PrinterMonitor"/>).</summary>
public sealed record PrinterView
{
    /// <summary>A connection is being made (or none was yet). The rest still shows what was shown before it.</summary>
    public bool IsConnecting { get; init; } = true;

    /// <summary>The last read came from the printer itself.</summary>
    public bool IsOnline { get; init; }

    /// <summary>Another device answers at the printer's address: nothing of it is shown, and "This is my printer" may accept it.</summary>
    public bool IsElsewhere { get; init; }

    public string StatusMessage { get; init; } = CoreStrings.Monitor_Connecting;
    public string? StatusDetail { get; init; }
    public Severity Severity { get; init; } = Severity.Info;
    public IReadOnlyList<PrinterAlert> Alerts { get; init; } = [];

    /// <summary>The last levels read: a read that couldn't get them keeps these.</summary>
    public IReadOnlyList<Consumable> Supplies { get; init; } = [];

    /// <summary>The last usage counters read (HP's LEDM only).</summary>
    public UsageCounters? Usage { get; init; }

    /// <summary>What the printer said about itself when it last connected; null before the first connection.</summary>
    public ProbeResult? Probe { get; init; }

    /// <summary>The last firmware change while its notice shows on the status card (roadmap 1.5, <see cref="FirmwareWatch.Notice"/>).</summary>
    public FirmwareChange? FirmwareNotice { get; init; }

    /// <summary>The printer list's line: the state, and for a warning or error the worst alert's words (<see cref="PrinterStatus.ListLine"/>).</summary>
    public string ListLine => IsOnline ? PrinterStatus.ListLine(StatusMessage, Severity, Alerts) : StatusMessage;
}

/// <summary>What a printer monitor tells the app, in the order it happens.</summary>
public abstract record MonitorEvent
{
    private MonitorEvent() { }

    /// <summary>The pane's state changed (<see cref="PrinterMonitor.View"/>).</summary>
    public sealed record Changed(PrinterView View) : MonitorEvent;

    /// <summary>
    /// Connected, or (<paramref name="Upgraded"/>) a printer read over SNMP answers LEDM, CDM or IPP now: bind the scanner, settings
    /// and the rest to <paramref name="Connection"/> (the session closed the one before). After the Changed that carries its probe.
    /// </summary>
    public sealed record Connected(PrinterConnection Connection, bool Upgraded) : MonitorEvent;

    /// <summary>A read, shown (after its Changed): its supplies and counters are null when they couldn't be read this time.</summary>
    public sealed record Read(PrinterReading Reading) : MonitorEvent;

    /// <summary>
    /// Another device answers at the address (before the Changed that says so): the session let go of every connection, so let
    /// go of everything bound to it; nothing (a scan included) may reach that device.
    /// </summary>
    public sealed record Elsewhere : MonitorEvent;

    /// <summary>Each read, or failure to reach the printer: the notification area's alerts follow these.</summary>
    public sealed record Observed(PrinterSnapshot Snapshot) : MonitorEvent;

    /// <summary>The printer is reached at another address from now on (<see cref="PrinterMonitor.Target"/>); <paramref name="From"/> is the one before.</summary>
    public sealed record Moved(string From) : MonitorEvent;
}

/// <summary>
/// The printer monitor: keeps one network printer's state current. It connects through the printer's session, reads on the
/// printer's events (LEDM) or every <see cref="FallbackRefresh"/>, asks a printer read over SNMP now and then whether it answers
/// more, retries every <see cref="RetryDelay"/> while the printer doesn't answer, and follows an address mDNS announces the printer
/// at once the session says it's this printer. Identity before data holds throughout: the session asks who answers before
/// reading. It tells the app what the printer pane shows (<see cref="View"/>) and what to do about it (<see cref="MonitorEvent"/>).
/// </summary>
/// <remarks>
/// Not thread-safe: call it from one context. Its own awaits resume on the caller's context, so the app runs it from its
/// dispatcher and handles events there; tests (no context) get them on the thread pool, one at a time.
/// </remarks>
public sealed class PrinterMonitor : IDisposable
{
    public static readonly TimeSpan RetryDelay = TimeSpan.FromSeconds(20);
    public static readonly TimeSpan FallbackRefresh = TimeSpan.FromSeconds(30);

    private readonly string _id;
    private readonly Func<string> _name;
    private readonly PrinterSession _session;
    private readonly Action<IReadOnlyList<string>> _acceptUuids;
    private readonly FirmwareMemory? _firmware;
    private readonly Action<MonitorEvent> _onEvent;
    private readonly Action<string> _log;
    private readonly TimeSpan _retryDelay, _fallbackRefresh;
    private IReadOnlyList<string> _foreignUuids = [];
    private SnmpIdentity? _foreignSnmp;

    /// <param name="id">The printer's id (its UUID, or one made from the address it was added at).</param>
    /// <param name="name">The printer's name as shown now, for its snapshots.</param>
    /// <param name="target">Where it's reached: its address and the hints it gave.</param>
    /// <param name="accepted">UUIDs the user confirmed are this printer's; <paramref name="acceptUuids"/> adds to them.</param>
    /// <param name="onEvent">Called on the caller's context (see the remarks).</param>
    /// <param name="firmware">Where the printer's firmware record is kept (the firmware watch, roadmap 1.5); null watches nothing.</param>
    /// <param name="log">The app's log, for lines about this printer (never its UUIDs, serial numbers or firmware versions).</param>
    public PrinterMonitor(string id, Func<string> name, PrinterWhere target, PrinterRecipe recipe, Func<IEnumerable<string>> accepted,
        Action<IReadOnlyList<string>> acceptUuids, Action<MonitorEvent> onEvent, FirmwareMemory? firmware = null, Action<string>? log = null,
        TimeSpan? retryDelay = null, TimeSpan? fallbackRefresh = null)
    {
        _id = id;
        _name = name;
        Target = target;
        _acceptUuids = acceptUuids;
        _onEvent = onEvent;
        _firmware = firmware;
        _log = log ?? (_ => { });
        _retryDelay = retryDelay ?? RetryDelay;
        _fallbackRefresh = fallbackRefresh ?? FallbackRefresh;
        _session = new PrinterSession(id, recipe, accepted, acceptUuids);
    }

    /// <summary>Where the printer is reached now. The app sets what it remembers (the IPP address, an SNMP-only printer's identity).</summary>
    public PrinterWhere Target { get; set; }

    public PrinterView View { get; private set; } = new();

    /// <summary>The session's connection: null before the first and after another device was found at the address. Never closed by callers.</summary>
    public PrinterConnection? Connection => _session.Connection;

    /// <summary>Another device answers at the address and said who it is: "This is my printer" can accept it (<see cref="AcceptDevice"/>).</summary>
    public bool CanAcceptDevice => View.IsElsewhere && (_foreignUuids.Count > 0 || _foreignSnmp is not null);

    /// <summary>Time passed (the window was hidden): the connection is asked who it is before its next read.</summary>
    public void AskIdentityFirst() => _session.AskIdentityFirst();

    /// <summary>
    /// Runs until <paramref name="ct"/> is cancelled. <paramref name="reuse"/>: the connection is still good (the window came back),
    /// so while the printer is online it's watched again without probing, after asking who answers.
    /// </summary>
    public async Task RunAsync(CancellationToken ct, bool reuse = false)
    {
        PrinterConnection? reused = null;
        if (reuse)
        {
            _session.AskIdentityFirst();
            reused = View.IsOnline ? _session.Connection : null;
        }
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var conn = reused;
                reused = null;
                if (conn is null)
                {
                    Show(View with { IsConnecting = true });
                    if (!await ConnectAsync(ct))
                    {
                        await Task.Delay(_retryDelay, ct);
                        continue;
                    }
                    conn = _session.Connection!;
                }
                await foreach (var _ in conn.WatchAsync(_fallbackRefresh, ct))
                {
                    switch (await _session.TryUpgradeAsync(Target, ct)) // asks who answers first
                    {
                        case SessionStep.Elsewhere elsewhere:
                            SetElsewhere(elsewhere);
                            break;
                        case SessionStep.Connected upgraded:
                            Upgrade(upgraded.Connection); // the session closed the SNMP connection
                            reused = upgraded.Connection; // watched from here on (its event feed, if it has one)
                            break;
                    }
                    if (View.IsElsewhere || reused is not null) break;
                    // Still this printer? The session asks before reading (a reused connection at once, then every 30 s), so
                    // another device that took the address never has its status or alerts read under this printer's name.
                    if (!await RefreshAsync(ct)) break;
                    // Gone: connect again after a pause, which checks it's still this printer (DHCP may give its address to another device).
                    if (!View.IsOnline) break;
                }
                if (!View.IsOnline && reused is null) await Task.Delay(_retryDelay, ct);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                return;
            }
            catch (Exception ex)
            {
                _log($"connection loop: {ex}");
                SetOffline();
                try { await Task.Delay(_retryDelay, ct); }
                catch (OperationCanceledException) { return; }
            }
        }
    }

    /// <summary>
    /// One background check while the window is hidden (the notification area's, minutes apart; never beside <see cref="RunAsync"/>):
    /// connects when it isn't connected, online, or <paramref name="reconnect"/> says so (it moved meanwhile), then reads once, the
    /// session asking who answers first. True when the printer answered as itself.
    /// </summary>
    public async Task<bool> CheckAsync(bool reconnect, CancellationToken ct)
    {
        try
        {
            if (_session.Connection is null || !View.IsOnline || reconnect)
                if (!await ConnectAsync(ct)) return false;
            return await RefreshAsync(ct) && View.IsOnline;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception ex)
        {
            _log($"check failed: {ex.Message}");
            SetOffline();
            return false;
        }
    }

    /// <summary>
    /// mDNS announces the printer at <paramref name="host"/> (null: it gave none). At its own address (or none) the eSCL and IPP
    /// addresses it gave are taken. At another one (DHCP may have moved it, or it's an address this PC can't use: a VM's or
    /// VPN's) the printer moves there when the session finds that's this printer, or can't tell and the address in use no longer
    /// answers as this kind of printer (<see cref="PrinterSession.CheckAddressAsync"/>); an address that still works is kept.
    /// True when the caller should run the monitor again now: it moved, or it was seen again while offline and not connecting.
    /// </summary>
    /// <param name="model">The model the announcement names.</param>
    public async Task<bool> AnnouncedAsync(string? host, Uri? escl, Uri? ipp, string? model, CancellationToken ct = default)
    {
        if (host is null || string.Equals(host, Target.Host, StringComparison.OrdinalIgnoreCase))
        {
            TakeHints(escl, ipp);
            return !View.IsOnline && !View.IsConnecting && host is not null; // mDNS just saw it again; don't wait for the retry
        }
        try
        {
            var check = await _session.CheckAddressAsync(Target, new PrinterWhere(host, escl, ipp), View.IsOnline && !View.IsElsewhere, model, ct);
            if (check == AddressCheck.Skipped) return false;
            if (check != AddressCheck.Move)
            {
                _log("announced at another address that " +
                     $"{check switch { AddressCheck.AnotherDevice => "is another device", AddressCheck.NoId => "reports no ID", _ => "doesn't answer" }}; " +
                     "keeping its address, which still answers");
                return false;
            }
            if (string.Equals(host, Target.Host, StringComparison.OrdinalIgnoreCase)) return false;
            Move(host);
            TakeHints(escl, ipp);
            return true;
        }
        catch (Exception ex)
        {
            _log($"announced at another address that couldn't be checked: {ex.Message}");
            return false;
        }
    }

    /// <summary>
    /// The printer is reached at <paramref name="host"/> from now on (the offline fixer found it there by its UUID); its hints are
    /// kept. The caller runs the monitor again, which asks who answers before reading.
    /// </summary>
    public void Move(string host)
    {
        if (string.Equals(host, Target.Host, StringComparison.OrdinalIgnoreCase)) return;
        var from = Target.Host;
        Target = Target with { Host = host };
        _onEvent(new MonitorEvent.Moved(from));
    }

    /// <summary>
    /// "This is my printer" (the user said yes): the device at the address counts as this printer from now on, its UUIDs accepted
    /// and over SNMP its identity remembered. The caller runs the monitor again. False when there was none to accept.
    /// </summary>
    public bool AcceptDevice()
    {
        if (!CanAcceptDevice) return false;
        if (_foreignUuids.Count > 0) _acceptUuids(_foreignUuids);
        if (_foreignSnmp is { } snmp) Target = Target with { Snmp = SnmpDevice.From(snmp) }; // remembered when it connects
        _log("the user accepted the device at its address as this printer");
        Show(View with { IsElsewhere = false });
        return true;
    }

    /// <summary>The status card's notice was closed: kept as dismissed, so this change isn't shown or alerted again.</summary>
    public void DismissFirmwareNotice()
    {
        _firmware?.Dismiss();
        Show(View with { FirmwareNotice = null });
    }

    public void Dispose() => _session.Dispose();

    // ---------------------------------------------------------------- steps

    /// <summary>
    /// Connects through the session. False, with the state set, when nothing answers there or another device does: that device's
    /// status, supplies and alerts are never shown or alerted under this printer's name.
    /// </summary>
    private async Task<bool> ConnectAsync(CancellationToken ct)
    {
        switch (await _session.ConnectAsync(Target, ct))
        {
            case SessionStep.Connected connected:
                Attach(connected.Connection, upgraded: false);
                return true;
            case SessionStep.Elsewhere elsewhere:
                SetElsewhere(elsewhere);
                return false;
            default:
                SetOffline();
                return false;
        }
    }

    /// <summary>A printer read over SNMP answers LEDM, CDM or IPP now: it's connected over them and isn't an SNMP-only printer any more.</summary>
    private void Upgrade(PrinterConnection richer)
    {
        _log($"answers more than SNMP now: connected over {string.Join(", ", richer.Probe.Interfaces)}");
        Target = Target with { Snmp = null, EsclHint = richer.Probe.EsclRoot ?? Target.EsclHint };
        Attach(richer, upgraded: true);
    }

    private void Attach(PrinterConnection conn, bool upgraded)
    {
        var p = conn.Probe;
        Target = Target with { IppHint = p.IppEndpoint ?? Target.IppHint };
        var notice = View.FirmwareNotice;
        if (_firmware is { } memory)
        {
            // The connection's version against the one remembered: a change is kept and shown until dismissed (30 days at most).
            var (shown, changed) = memory.Watch(p.Firmware?.Display);
            if (changed) _log("firmware version changed"); // never the versions: they can identify a unit
            notice = shown;
        }
        Show(View with { IsElsewhere = false, Probe = p, FirmwareNotice = notice });
        _onEvent(new MonitorEvent.Connected(conn, upgraded));
    }

    /// <summary>One read through the session, shown. False when another device answers at the address now (nothing of it is read).</summary>
    private async Task<bool> RefreshAsync(CancellationToken ct)
    {
        if (_session.Connection is null) return true;
        var step = await _session.ReadAsync(Target, ct);
        if (step is SessionStep.Elsewhere elsewhere)
        {
            SetElsewhere(elsewhere);
            return false;
        }
        var reading = ((SessionStep.Read)step).Reading;
        var status = reading.Status;
        if (reading.IsOffline)
        {
            SetOffline();
            return true;
        }
        var v = View with
        {
            IsConnecting = false,
            IsOnline = true,
            Supplies = reading.Supplies ?? View.Supplies, // not read this time: they stay as they were
            Usage = reading.Usage ?? View.Usage,
        };
        // An unusable reply (printer waking up) keeps the last good status instead of flashing an error.
        if (!status.IsUnavailable) v = v with { StatusMessage = status.Message, StatusDetail = status.Detail, Severity = status.Severity, Alerts = status.Alerts };
        Show(v);
        _onEvent(new MonitorEvent.Read(reading));
        _onEvent(new MonitorEvent.Observed(new PrinterSnapshot(_id, _name(), true, status.IsUnavailable ? null : status, reading.Supplies)
            { FirmwareChange = View.FirmwareNotice }));
        return true;
    }

    private void SetOffline() => SetOffline(CoreStrings.Monitor_CantReach, string.Format(CoreStrings.Monitor_CantReachDetailHost, Target.Host));

    /// <param name="elsewhere">Another device answers there (otherwise whether one did stays as it was).</param>
    private void SetOffline(string message, string detail, bool elsewhere = false)
    {
        Show(View with
        {
            IsConnecting = false, IsOnline = false, IsElsewhere = elsewhere || View.IsElsewhere, StatusMessage = message, StatusDetail = detail,
            Severity = Severity.Error, Alerts = [],
        });
        _onEvent(new MonitorEvent.Observed(new PrinterSnapshot(_id, _name(), false, null, null)));
    }

    /// <summary>
    /// Another device answers at the printer's address. The session has closed its connection and the printer's own; the app lets
    /// go of what it bound to them. The card says so and offers "This is my printer".
    /// </summary>
    private void SetElsewhere(SessionStep.Elsewhere elsewhere)
    {
        _log("a different device answers at its address; not connecting"); // never the UUIDs or serial numbers themselves
        _foreignUuids = elsewhere.Uuids;
        _foreignSnmp = elsewhere.Snmp;
        _onEvent(new MonitorEvent.Elsewhere());
        SetOffline(CoreStrings.Monitor_ElsewhereTitle, string.Format(CoreStrings.Monitor_ElsewhereDetail, Target.Host), elsewhere: true);
    }

    private void TakeHints(Uri? escl, Uri? ipp) => Target = Target with { EsclHint = escl ?? Target.EsclHint, IppHint = ipp ?? Target.IppHint };

    private void Show(PrinterView v)
    {
        if (v == View) return;
        View = v;
        _onEvent(new MonitorEvent.Changed(v));
    }
}
