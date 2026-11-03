using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Queues;

/// <summary>Where a queue printer's supply levels and problems came from, beside Windows' own status.</summary>
public enum QueueReadingFrom
{
    /// <summary>The printer itself over IPP, through Windows' IPP class driver, connected by USB.</summary>
    PrinterOverUsb,

    /// <summary>The printer itself over IPP, through Windows' IPP class driver (a network or WSD queue).</summary>
    PrinterThroughWindows,

    /// <summary>The printer's driver, through Windows' bidirectional printing (bidi).</summary>
    Driver,
}

/// <summary>
/// What a queue printer's printer or driver said: supply levels, and a status when it has one (IPP has a state, a driver's bidi
/// answer usually only alerts). Null <see cref="Status"/>: alerts only, in <see cref="Alerts"/>.
/// </summary>
public sealed record QueueDeviceReading(QueueReadingFrom From, PrinterStatus? Status, IReadOnlyList<PrinterAlert> Alerts, IReadOnlyList<Consumable> Supplies)
{
    /// <summary>It said anything worth showing.</summary>
    public bool SaysAnything => Status is not null || Alerts.Count > 0 || Supplies.Count > 0;
}

/// <summary>
/// One way of asking a queue printer more than the spooler says: the printer over IPP through Windows (route 1, IPP over USB
/// included) or the driver over bidi (route 2). Read-only. Returns null when the queue has no such route (not an IPP queue, a
/// driver without bidi): asked again much later, never an error.
/// </summary>
public interface IQueueDeviceReader
{
    Task<QueueDeviceReading?> ReadAsync(CancellationToken ct);
}

/// <summary>
/// A queue printer whose printer or driver may report more than the spooler (<see cref="IQueueDeviceReader"/>s, asked in order,
/// the first that answers wins): Windows' status from <paramref name="windows"/>, with the supply levels and alerts the reader
/// gives. Each reader call is time-limited (<see cref="CallLimit"/>); one that answers is asked again after <see cref="ReadInterval"/>,
/// one that has nothing (unsupported, timed out, failed) after <see cref="NothingInterval"/>, so most drivers cost one call every
/// few minutes. The last reading stands for a read in between.
/// </summary>
public sealed class DeviceQueueStatusSource(IQueueStatusSource windows, IReadOnlyList<IQueueDeviceReader> readers) : IQueueStatusSource
{
    internal static readonly TimeSpan ReadInterval = TimeSpan.FromSeconds(30);
    internal static readonly TimeSpan NothingInterval = TimeSpan.FromMinutes(5);
    internal static readonly TimeSpan CallLimit = TimeSpan.FromSeconds(8);

    private QueueDeviceReading? _last;
    private DateTime _next = DateTime.MinValue;

    /// <summary>Clock for tests.</summary>
    internal Func<DateTime> Now { get; init; } = () => DateTime.UtcNow;

    /// <summary>The time each reader call gets (tests shorten it).</summary>
    internal TimeSpan Limit { get; init; } = CallLimit;

    /// <summary>Where the last reading came from; null: no reader answered (yet).</summary>
    public QueueReadingFrom? From => _last?.From;

    public string Origin => _last is { } r ? QueueDeviceText.Origin(r.From) : windows.Origin;

    public bool HasSupplyLevels => _last is { Supplies.Count: > 0 } || windows.HasSupplyLevels;

    public async Task<QueueStatusRead?> ReadAsync(CancellationToken ct)
    {
        if (await windows.ReadAsync(ct).ConfigureAwait(false) is not { } fromWindows) return null;
        var now = Now();
        if (now >= _next)
        {
            _last = null;
            foreach (var reader in readers)
            {
                if (await AskAsync(reader, ct).ConfigureAwait(false) is { SaysAnything: true } r)
                {
                    _last = r;
                    break;
                }
            }
            _next = now + (_last is null ? NothingInterval : ReadInterval);
        }
        return _last is { } reading ? QueueDevice.Merge(fromWindows, reading) : fromWindows;
    }

    private async Task<QueueDeviceReading?> AskAsync(IQueueDeviceReader reader, CancellationToken ct)
    {
        using var limit = CancellationTokenSource.CreateLinkedTokenSource(ct);
        limit.CancelAfter(Limit);
        try
        {
            return await reader.ReadAsync(limit.Token).WaitAsync(limit.Token).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return null; // too slow: nothing this time
        }
        catch (Exception ex) when (ex is not OperationCanceledException and not OutOfMemoryException)
        {
            System.Diagnostics.Trace.WriteLine($"queue device reading: {ex.GetType().Name}");
            return null;
        }
    }
}

/// <summary>How Windows' status of a queue and what its printer or driver said make one.</summary>
public static class QueueDevice
{
    /// <summary>
    /// Supplies are the reading's. Windows holding the jobs (paused, Use Printer Offline) or not reaching the printer stays the
    /// headline, with the reading's problems added under it; otherwise a printer's own IPP status leads (as with SNMP), with
    /// Windows' jobs-waiting note, and a driver's alerts are added to Windows' status. A reading taken while Windows says the
    /// printer is offline keeps the offline headline, and its supplies show as the last known.
    /// </summary>
    public static QueueStatusRead Merge(QueueStatusRead windows, QueueDeviceReading reading)
    {
        if (reading.Status is { } printer && !windows.Offline)
            return QueueSnmp.MergeStatus(windows, printer, reading.Supplies);
        var w = windows.Status;
        var extra = (reading.Status?.Alerts ?? []).Concat(reading.Alerts).ToList();
        var alerts = w.Alerts.Concat(extra.Where(a => w.Alerts.All(x => x.Id != a.Id))).GroupBy(a => a.Id).Select(g => g.First()).ToList();
        var severity = alerts.Select(a => a.Severity).Append(w.Severity).Max();
        var detail = w.Detail;
        if (severity > w.Severity && alerts.FirstOrDefault(a => a.Severity == severity) is { } top)
            detail = string.Join(" ", new[] { top.Message, w.Detail }.Where(d => !string.IsNullOrWhiteSpace(d)));
        return new QueueStatusRead(w with { Alerts = alerts, Severity = severity, Detail = detail }, windows.Offline, reading.Supplies);
    }
}

/// <summary>The words for where a reading came from (in the status card's "Status and supply levels from …").</summary>
public static class QueueDeviceText
{
    public static string Origin(QueueReadingFrom from) => from switch
    {
        QueueReadingFrom.PrinterOverUsb => CoreStrings.Queue_FromPrinterOverUsb,
        QueueReadingFrom.PrinterThroughWindows => CoreStrings.Queue_FromPrinterThroughWindows,
        _ => CoreStrings.Queue_FromDriver,
    };

    /// <summary>Short, for the supplies card and the fleet: "From the printer over USB", "From its driver".</summary>
    public static string Source(QueueReadingFrom from) => from switch
    {
        QueueReadingFrom.PrinterOverUsb => CoreStrings.Queue_SourcePrinterOverUsb,
        QueueReadingFrom.PrinterThroughWindows => CoreStrings.Queue_SourcePrinter,
        _ => CoreStrings.Queue_SourceDriver,
    };
}
