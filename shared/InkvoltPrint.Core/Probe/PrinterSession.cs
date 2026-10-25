using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Net;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Core.Probe;

/// <summary>Where a remembered printer is reached: its address, the eSCL and IPP addresses it gave, and (SNMP-only printers) what it said about itself.</summary>
public sealed record PrinterWhere(string Host, Uri? EsclHint = null, Uri? IppHint = null, SnmpDevice? Snmp = null);

/// <summary>
/// The connection recipe: what every connection to a printer carries, the same for the first connection, a reconnection, an
/// upgrade from SNMP and a look at another address.
/// </summary>
/// <param name="Transport">A printer's web server for one connection (demo mode, tests); null: the real network.</param>
/// <param name="Snmp">Where SNMP goes; used only for printers added as SNMP-only (<see cref="PrinterWhere.Snmp"/>).</param>
/// <param name="Pin">The printer's certificate pins (trust on first use), for its own connections only.</param>
/// <param name="Clock">For the intervals below; tests pass their own.</param>
public sealed record PrinterRecipe(Func<HttpMessageHandler?> Transport, ISnmpTransport Snmp, ICertificatePin? Pin = null, TimeProvider? Clock = null);

/// <summary>What a session step came to: the view model shows it.</summary>
public abstract record SessionStep
{
    private SessionStep() { }

    /// <summary>Nothing answers at the printer's address.</summary>
    public sealed record Offline : SessionStep;

    /// <summary>
    /// Another device answers at the address (it reports other UUIDs, or over SNMP another serial number, model or name). The
    /// session has let go of every connection: nothing of that device is read under this printer's name.
    /// </summary>
    public sealed record Elsewhere(IReadOnlyList<string> Uuids, SnmpIdentity? Snmp) : SessionStep;

    /// <summary>
    /// A new connection to the printer (the session closed the one before). <paramref name="Upgraded"/>: a printer read over SNMP
    /// that answers LEDM, CDM or IPP now; it isn't an SNMP-only printer any more.
    /// </summary>
    public sealed record Connected(PrinterConnection Connection, bool Upgraded = false) : SessionStep;

    /// <summary>A read of the printer, after making sure it is still this printer.</summary>
    public sealed record Read(PrinterReading Reading) : SessionStep;
}

/// <summary>Why mDNS's announcement of the printer at another address was or wasn't followed.</summary>
public enum AddressCheck
{
    /// <summary>Move there: it answers as this printer, or can't tell and the address in use no longer answers as it.</summary>
    Move,

    /// <summary>Another device answers there.</summary>
    AnotherDevice,

    /// <summary>It answers without saying who it is, and the address in use still answers as this kind of printer.</summary>
    NoId,

    /// <summary>Nothing answers there, and the address in use still does.</summary>
    NoAnswer,

    /// <summary>Not asked: being asked already, or refused a moment ago (an address announced again and again is asked now and then).</summary>
    Skipped,
}

/// <summary>
/// The printer session: one remembered printer's connection life cycle. It connects with one recipe (<see cref="PrinterRecipe"/>),
/// asks who answers before reading (at once on a new or reused connection, then every <see cref="IdentityInterval"/>), so another
/// device that took the address never has its status, supplies or alerts read under this printer's name; upgrades a printer read
/// over SNMP when it answers more (every <see cref="UpgradeInterval"/>); and checks an address mDNS announces the printer at. It
/// owns the connection: callers bind to <see cref="Connection"/> and never close it.
/// </summary>
/// <param name="id">The printer's id: its UUID, or (no UUID) one made from the address it was added at.</param>
/// <param name="accepted">UUIDs the user confirmed are this printer's ("This is my printer"); <paramref name="acceptUuids"/> adds to them.</param>
public sealed class PrinterSession(string id, PrinterRecipe recipe, Func<IEnumerable<string>> accepted, Action<IReadOnlyList<string>> acceptUuids)
    : IDisposable
{
    public static readonly TimeSpan IdentityInterval = TimeSpan.FromSeconds(30);

    /// <summary>How often a printer read over SNMP is asked whether it answers LEDM, CDM or IPP now.</summary>
    public static readonly TimeSpan UpgradeInterval = TimeSpan.FromMinutes(2);

    /// <summary>An address refused is asked again only after this (it may be announced every few seconds).</summary>
    public static readonly TimeSpan RefusedFor = TimeSpan.FromMinutes(1);

    private readonly object _gate = new();
    private readonly TimeProvider _clock = recipe.Clock ?? TimeProvider.System;
    private DateTimeOffset _identityCheckedAt = DateTimeOffset.MinValue, _upgradeTriedAt = DateTimeOffset.MinValue;
    private string? _checkingHost;
    private (string Host, DateTimeOffset At)? _refusedHost;

    /// <summary>The printer's connection; null before the first connection and after another device was found at its address.</summary>
    public PrinterConnection? Connection { get; private set; }

    /// <summary>Connects at <paramref name="where"/>: <see cref="SessionStep.Connected"/>, or Offline, or Elsewhere (nothing kept).</summary>
    public async Task<SessionStep> ConnectAsync(PrinterWhere where, CancellationToken ct)
    {
        var conn = await PrinterConnection.OpenAsync(where.Host, where.EsclHint, ct, recipe.Pin, recipe.Transport(), where.IppHint,
            SnmpDevice.TransportFor(where.Snmp, recipe.Snmp)).ConfigureAwait(false);
        if (!conn.Probe.Reachable)
        {
            conn.Dispose();
            return new SessionStep.Offline();
        }
        if (Identify(where.Host, conn.Probe.ReportedUuids) == DeviceIdentity.Different) return LetGo(conn, conn.Probe.ReportedUuids, where.Host);
        if (conn.Probe.Snmp is { } snmp && where.Snmp?.Identify(snmp) == DeviceIdentity.Different) return LetGo(conn, [], where.Host, snmp);
        var now = _clock.GetUtcNow();
        _identityCheckedAt = now;
        if (conn.OverSnmp) _upgradeTriedAt = now; // HTTP just didn't answer: asked again later
        return Use(conn, upgraded: false);
    }

    /// <summary>
    /// A read of the printer over <see cref="Connection"/>, once it's sure it's still this printer (asked at most every
    /// <see cref="IdentityInterval"/>, and first after <see cref="AskIdentityFirst"/>): Read, or Elsewhere (nothing read).
    /// </summary>
    public async Task<SessionStep> ReadAsync(PrinterWhere where, CancellationToken ct)
    {
        var conn = Connection ?? throw new InvalidOperationException("Not connected");
        if (_clock.GetUtcNow() - _identityCheckedAt > IdentityInterval && await StillThisPrinterAsync(conn, where, ct).ConfigureAwait(false) is { } elsewhere)
            return elsewhere;
        return new SessionStep.Read(await conn.ReadAsync(ct).ConfigureAwait(false));
    }

    /// <summary>Time passed (the window was hidden): the connection is asked who it is before its next read.</summary>
    public void AskIdentityFirst() => _identityCheckedAt = DateTimeOffset.MinValue;

    /// <summary>
    /// A printer read over SNMP is asked now and then (<see cref="UpgradeInterval"/>) whether it answers LEDM, CDM or IPP: one that
    /// was asleep when it was added does once it wakes. Identity before data holds here too: the device at the address is first
    /// asked over SNMP who it is (its serial number, model and name), and another device there ends it
    /// (<see cref="SessionStep.Elsewhere"/>), since an upgrade makes the UUIDs it reports this printer's for good and the HTTP
    /// probe of a printer added by address often can't tell. When it answers more, as the same device (its serial number and
    /// UUIDs), the session switches to that connection (<see cref="SessionStep.Connected"/> with Upgraded) and the UUIDs it
    /// reports count as this printer's from now on. Null when nothing changed.
    /// </summary>
    public async Task<SessionStep?> TryUpgradeAsync(PrinterWhere where, CancellationToken ct)
    {
        if (Connection is not { OverSnmp: true } conn || _clock.GetUtcNow() - _upgradeTriedAt < UpgradeInterval) return null;
        _upgradeTriedAt = _clock.GetUtcNow();
        if (await StillThisPrinterAsync(conn, where, ct).ConfigureAwait(false) is { } elsewhere) return elsewhere;
        var richer = await conn.TryRicherAsync(where.Snmp, where.EsclHint, where.IppHint, recipe.Pin, recipe.Transport(), ct).ConfigureAwait(false);
        if (richer is null) return null;
        if (Identify(where.Host, richer.Probe.ReportedUuids) == DeviceIdentity.Different)
        {
            richer.Dispose();
            return null;
        }
        if (PrinterId.Valid(richer.Probe.ReportedUuids, where.Host) is { Count: > 0 } uuids) acceptUuids(uuids);
        _identityCheckedAt = _clock.GetUtcNow();
        return Use(richer, upgraded: true);
    }

    /// <summary>
    /// mDNS announces the printer at <paramref name="candidate"/> while it's used at <paramref name="current"/>: DHCP may have
    /// moved it, or the announcement is of an address this PC can't use (a VM's or VPN's). Asked with the same recipe as the
    /// printer's own connections (its SNMP identity included), but without the certificate pin: nothing is sent there that
    /// needs one, and trust on first use must not pin a device not yet known to be this printer.
    /// </summary>
    /// <param name="currentAnswers">The address in use answers as this printer now.</param>
    /// <param name="announcedModel">The model the announcement names (compared with the one at the address in use).</param>
    public async Task<AddressCheck> CheckAddressAsync(PrinterWhere current, PrinterWhere candidate, bool currentAnswers, string? announcedModel,
        CancellationToken ct = default)
    {
        var host = candidate.Host;
        lock (_gate)
        {
            if (string.Equals(_checkingHost, host, StringComparison.OrdinalIgnoreCase)) return AddressCheck.Skipped;
            if (_refusedHost is { } refused && string.Equals(refused.Host, host, StringComparison.OrdinalIgnoreCase)
                && _clock.GetUtcNow() - refused.At < RefusedFor)
                return AddressCheck.Skipped;
            _checkingHost = host;
        }
        try
        {
            ProbeResult probe;
            using (var http = new DeviceHttp(host, recipe.Transport()))
                probe = await PrinterConnection.ProbeAsync(http, candidate.EsclHint, ct, candidate.IppHint, SnmpDevice.TransportFor(current.Snmp, recipe.Snmp))
                    .ConfigureAwait(false);
            var identity = !probe.Reachable ? DeviceIdentity.Unknown
                : probe.Snmp is { } snmp && current.Snmp is { } known ? known.Identify(snmp)
                : Identify(host, probe.ReportedUuids);
            // No UUID to go by there: the address in use is kept only while it answers as this kind of printer.
            var move = PrinterId.ShouldMove(identity, currentAnswers, Connection?.Probe.Model, announcedModel);
            lock (_gate) _refusedHost = move ? null : (host, _clock.GetUtcNow());
            return move ? AddressCheck.Move
                : identity == DeviceIdentity.Different ? AddressCheck.AnotherDevice
                : probe.Reachable ? AddressCheck.NoId : AddressCheck.NoAnswer;
        }
        catch
        {
            lock (_gate) _refusedHost = (host, _clock.GetUtcNow());
            throw;
        }
        finally
        {
            lock (_gate) _checkingHost = null;
        }
    }

    /// <summary>Asks the connected device who it is (one small read): null when it's this printer or it can't tell; else Elsewhere.</summary>
    private async Task<SessionStep?> StillThisPrinterAsync(PrinterConnection conn, PrinterWhere where, CancellationToken ct)
    {
        if (conn.OverSnmp)
        {
            // SNMP has no UUID: the serial number, model and name it gave when it was added tell.
            var now = await conn.ReadSnmpIdentityAsync(ct).ConfigureAwait(false);
            _identityCheckedAt = _clock.GetUtcNow();
            return now is null || where.Snmp?.Identify(now) != DeviceIdentity.Different ? null : LetGo(conn, [], where.Host, now);
        }
        var reported = await conn.ReadUuidsAsync(ct).ConfigureAwait(false);
        _identityCheckedAt = _clock.GetUtcNow();
        return Identify(where.Host, reported) != DeviceIdentity.Different ? null : LetGo(conn, reported, where.Host);
    }

    private DeviceIdentity Identify(string host, IEnumerable<string?> reported) => PrinterId.Identify(id, accepted(), host, reported);

    private SessionStep.Connected Use(PrinterConnection conn, bool upgraded)
    {
        var old = Connection;
        Connection = conn;
        if (!ReferenceEquals(old, conn)) old?.Dispose();
        return new SessionStep.Connected(conn, upgraded);
    }

    /// <summary>Another device answers: its connection and the printer's own are closed. Never the UUIDs or serials in a log.</summary>
    private SessionStep.Elsewhere LetGo(PrinterConnection conn, IReadOnlyList<string?> reported, string host, SnmpIdentity? snmp = null)
    {
        var old = Connection;
        Connection = null;
        if (!ReferenceEquals(conn, old)) conn.Dispose();
        old?.Dispose();
        return new SessionStep.Elsewhere(PrinterId.Valid(reported, host), snmp);
    }

    public void Dispose()
    {
        Connection?.Dispose();
        Connection = null;
    }
}
