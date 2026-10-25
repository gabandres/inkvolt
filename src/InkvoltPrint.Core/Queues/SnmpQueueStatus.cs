using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Core.Queues;

/// <summary>
/// A queue printer whose port has the printer's address (<see cref="QueueKinds.SnmpAddress"/>): Windows' own status (from
/// <paramref name="windows"/>: paused, Use Printer Offline, jobs waiting) joined with what the printer itself says over SNMP
/// (state, paper and jam problems, supply levels; <see cref="SnmpPrinterStatus"/>). A printer that never answered SNMP
/// (switched off in it, another community) gets Windows' status alone and is asked again a minute later; one that answered
/// and stops is taken as unreachable (Windows keeps saying "ready" for a TCP/IP printer that's off) and asked every 20 s.
/// </summary>
public sealed class SnmpQueueStatusSource(IQueueStatusSource windows, string host, ISnmpTransport transport, string? community = null)
    : IQueueStatusSource
{
    /// <summary>How long one SNMP read serves (the queue is read every few seconds; the printer needn't be).</summary>
    internal static readonly TimeSpan ReadInterval = TimeSpan.FromSeconds(15);

    /// <summary>How long before asking again a printer that didn't answer SNMP.</summary>
    internal static readonly TimeSpan ProbeInterval = TimeSpan.FromSeconds(60);

    /// <summary>How long before asking again a printer that answered and stopped (turned off, perhaps: back soon).</summary>
    internal static readonly TimeSpan LostProbeInterval = TimeSpan.FromSeconds(20);

    private SnmpPrinterClient? _client;
    private DateTime _nextProbe = DateTime.MinValue;
    private SnmpReading? _last;
    private DateTime _lastAt;
    private bool _answered, _lost;

    /// <summary>Clock for tests.</summary>
    internal Func<DateTime> Now { get; init; } = () => DateTime.UtcNow;

    public string Host => host;

    /// <summary>The printer answered SNMP on the last read.</summary>
    public bool Answers => _last is not null;

    public string Origin => Answers ? "the printer over SNMP, with Windows for the print queue" : windows.Origin;

    public bool HasSupplyLevels => Answers;

    public async Task<QueueStatusRead?> ReadAsync(CancellationToken ct)
    {
        if (await windows.ReadAsync(ct).ConfigureAwait(false) is not { } fromWindows) return null;
        var now = Now();
        if (_last is null || now - _lastAt >= ReadInterval)
        {
            _last = null;
            if (_client is null && now >= _nextProbe)
            {
                _client = await SnmpPrinterClient.ProbeAsync(transport, host, community is { Length: > 0 } c ? c : SnmpClient.DefaultCommunity, ct)
                    .ConfigureAwait(false);
                if (_client is null) Missed(now);
            }
            if (_client is not null)
            {
                try
                {
                    _last = await _client.ReadNowAsync(ct).ConfigureAwait(false);
                    _lastAt = now;
                    _answered = true;
                    _lost = false;
                }
                catch (Exception ex) when (ex is TimeoutException or FormatException or SnmpErrorException)
                {
                    _client = null; // gone, or turned off
                    Missed(now);
                }
            }
        }
        return _last is not null ? QueueSnmp.Merge(fromWindows, _last) : _lost ? QueueSnmp.Unreachable(fromWindows, host) : fromWindows;
    }

    private void Missed(DateTime now)
    {
        _lost = _answered;
        _nextProbe = now + (_lost ? LostProbeInterval : ProbeInterval);
    }
}

/// <summary>How a queue printer's Windows status and its SNMP status make one.</summary>
public static class QueueSnmp
{
    /// <summary>
    /// Windows holding the jobs (paused, Use Printer Offline, the queue being removed) stays the headline, since that's what
    /// stops printing, with the printer's problems listed under it. Otherwise the printer's own status leads (it answered, so it
    /// is reachable even if the spooler says offline; its paper, jam and door problems are what the driver may not report), with
    /// Windows' jobs-waiting note. Supplies are the printer's.
    /// </summary>
    /// <summary>
    /// The printer answered SNMP before and doesn't now: unreachable, whatever the spooler says (it keeps "ready" for a TCP/IP
    /// printer that's off), unless Windows itself holds the jobs (paused, Use Printer Offline), which stays the headline.
    /// </summary>
    public static QueueStatusRead Unreachable(QueueStatusRead windows, string host)
    {
        if (HeldByWindows(windows.Status)) return windows;
        var waiting = IsOrdinary(windows.Status) && windows.Status.Detail is { Length: > 0 } d ? " " + d : "";
        return new QueueStatusRead(new PrinterStatus("offline", "Can't reach the printer", Severity.Error, [],
            $"It doesn't answer on the network ({host}). Check that it's turned on and on the same network as this PC.{waiting}"), true, []);
    }

    private static bool HeldByWindows(PrinterStatus w) =>
        w.Code is "paused" or "deleting" || (w.Code == "offline" && w.Message == SpoolerStatus.UsePrinterOfflineMessage);

    /// <summary>The spooler's ordinary states, whose only detail is the jobs-waiting note.</summary>
    private static bool IsOrdinary(PrinterStatus w) => w.Code is "ready" or "printing" or "warmingUp" or "initializing" or "inPowerSave";

    public static QueueStatusRead Merge(QueueStatusRead windows, SnmpReading snmp)
    {
        var printer = SnmpPrinterStatus.ToStatus(snmp);
        var supplies = SnmpPrinterStatus.ToConsumables(snmp);
        var w = windows.Status;
        if (HeldByWindows(w))
        {
            var alerts = w.Alerts.Concat(printer.Alerts.Where(a => w.Alerts.All(x => x.Id != a.Id))).ToList();
            var severity = alerts.Select(a => a.Severity).Append(w.Severity).Max();
            return new QueueStatusRead(w with { Alerts = alerts, Severity = severity }, windows.Offline, supplies);
        }
        // The spooler's ordinary states carry only the jobs-waiting note as their detail.
        var waiting = IsOrdinary(w) ? w.Detail : null;
        var detail = string.Join(" ", new[] { printer.Detail, waiting }.Where(d => !string.IsNullOrWhiteSpace(d)));
        return new QueueStatusRead(printer with { Detail = detail.Length > 0 ? detail : null }, false, supplies);
    }
}
