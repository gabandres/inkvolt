using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Probe;
using InkvoltPrint.Core.Queues;
using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Suite;
using InkvoltPrint.Core.Wia;

namespace InkvoltPrint.Core.Fleet;

/// <summary>What <see cref="FleetReader"/> reads a PC's printers through: the real one (<c>WindowsFleetPc</c>), or the demo's made-up one.</summary>
public interface IFleetPc
{
    /// <summary>The printers Inkvolt Print remembers, as its state file has them.</summary>
    InkvoltPrinters Remembered { get; }

    /// <summary>Queues and scanners the user removed from the list: they stay out of the fleet too.</summary>
    IReadOnlyCollection<string> Hidden { get; }

    /// <summary>How to reach a remembered printer. Its certificate pin, if any, is read only: this read writes nothing.</summary>
    PrinterRecipe Recipe(InkvoltPrinter printer);

    Task<IReadOnlyList<SpoolerQueue>> QueuesAsync(Func<SpoolerQueue, bool> needsPresence, CancellationToken ct);

    IQueueStatusSource QueueStatus(SpoolerQueue queue);

    Task<IReadOnlyList<WiaDeviceInfo>> ScannersAsync(CancellationToken ct);

    IWiaSystem Wia { get; }

    /// <summary>The supply history, for what a silent printer last said. Only read.</summary>
    SupplyHistoryStore? History { get; }
}

/// <summary>The fleet as read now: its printers, most trouble first, and what couldn't be read for the list as a whole.</summary>
public sealed record FleetRead(IReadOnlyList<FleetPrinter> Printers, IReadOnlyList<string> Notes);

/// <summary>
/// One read of every printer the printer list would show (<see cref="PrinterList"/> decides, as for the sidebar), for
/// <c>status --all</c>. Read only: it writes no state, history or pin, so it runs beside the app. A printer gets
/// <see cref="PrinterLimit"/> and then reads as not answering, whatever its read is doing (a hung driver, a printer gone mid-read);
/// a few are read at a time, so forty silent printers take a couple of minutes at most and each holds up only its own row. Identity
/// before data holds: another device at a printer's address is never read under its name (<see cref="PrinterSession"/>).
/// </summary>
public static class FleetReader
{
    public static readonly TimeSpan PrinterLimit = TimeSpan.FromSeconds(30);

    private const int AtOnce = 8;

    public static async Task<FleetRead> ReadAllAsync(IFleetPc pc, DateTimeOffset now, TimeSpan? limit = null, CancellationToken ct = default)
    {
        var each = limit ?? PrinterLimit;
        var remembered = pc.Remembered;
        var listed = remembered.Printers.Select(p => new ListedPrinter(p.Uuid, ListedKind.Network, p.Name, p.Model, p.Host, p.EsclRoot)
        {
            AcceptedUuids = p.AcceptedUuids,
            QueueName = remembered.QueueNames.GetValueOrDefault(p.Uuid),
        }).ToList();
        var notes = new List<string>();
        var claims = PrinterList.Claims(listed);
        var queues = await Whole(() => pc.QueuesAsync(q => QueueKinds.NeedsPresence(q, claims), ct), each, "Windows' printers couldn't be read, so printers known only to Windows aren't listed.", notes, ct).ConfigureAwait(false);
        var scanners = await Whole(() => pc.ScannersAsync(ct), each, "Windows' scanners couldn't be read, so scanners on their own aren't listed.", notes, ct).ConfigureAwait(false);
        var change = PrinterList.Reconcile(new PrinterListInput(listed, null, queues, SweepDone: true, scanners, pc.Hidden));

        using var gate = new SemaphoreSlim(AtOnce);
        var reads = new List<Task<FleetPrinter>>();
        foreach (var p in remembered.Printers)
            reads.Add(BoundedAsync(() => Silent(p, pc, "It didn't answer in time"), c => ReadNetworkAsync(p, pc, now, c), gate, each, ct));
        foreach (var q in change.AddedQueues)
            reads.Add(BoundedAsync(() => SilentQueue(q, "It didn't answer in time"), c => ReadQueueAsync(q, pc, now, c), gate, each, ct));
        foreach (var d in change.AddedScanners)
            reads.Add(BoundedAsync(() => SilentScanner(d), c => ReadScannerAsync(d, pc, now, c), gate, each, ct));
        return new FleetRead(FleetOrder.Sort(await Task.WhenAll(reads).ConfigureAwait(false)), notes);
    }

    private static async Task<IReadOnlyList<T>?> Whole<T>(Func<Task<IReadOnlyList<T>>> read, TimeSpan limit, string note, List<string> notes, CancellationToken ct)
    {
        try
        {
            return await read().WaitAsync(limit, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            notes.Add(note);
            return null;
        }
    }

    private static async Task<FleetPrinter> BoundedAsync(Func<FleetFacts> silent, Func<CancellationToken, Task<FleetFacts>> read, SemaphoreSlim gate, TimeSpan limit, CancellationToken ct)
    {
        await gate.WaitAsync(ct).ConfigureAwait(false);
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(ct);
        try
        {
            stop.CancelAfter(limit);
            var task = Task.Run(() => read(stop.Token), CancellationToken.None); // on the pool: a read that blocks can't hold the others
            _ = task.ContinueWith(t => _ = t.Exception, TaskContinuationOptions.OnlyOnFaulted); // given up on, it may still fail
            return FleetPrinter.Of(await task.WaitAsync(limit, ct).ConfigureAwait(false));
        }
        catch (Exception ex) when (ex is TimeoutException || (ex is OperationCanceledException && !ct.IsCancellationRequested))
        {
            return FleetPrinter.Of(silent());
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return FleetPrinter.Of(silent() with { Status = PrinterStatus.Offline("Inkvolt Print couldn't read it") });
        }
        finally
        {
            stop.Cancel();
            gate.Release();
        }
    }

    private static async Task<FleetFacts> ReadNetworkAsync(InkvoltPrinter p, IFleetPc pc, DateTimeOffset now, CancellationToken ct)
    {
        using var session = new PrinterSession(p.Uuid, pc.Recipe(p), () => p.AcceptedUuids, _ => { });
        var where = new PrinterWhere(p.Host, p.EsclRoot, p.IppUri, p.Snmp);
        var step = await session.ConnectAsync(where, ct).ConfigureAwait(false);
        if (step is SessionStep.Elsewhere) return Elsewhere(p);
        if (step is not SessionStep.Connected { Connection: var conn }) return Silent(p, pc, "Can't reach the printer");
        if (await session.ReadAsync(where, ct).ConfigureAwait(false) is not SessionStep.Read { Reading: var reading }) return Elsewhere(p);
        if (reading.IsOffline) return Silent(p, pc, "Can't reach the printer");
        var known = reading.Supplies is null || reading.Usage is null ? Known(p.Uuid, pc) : null;
        return new FleetFacts(p.Uuid, conn.Probe.Product?.MakeAndModel ?? p.Name, FleetKind.Network)
        {
            Model = conn.Probe.Model ?? p.Model,
            Connection = string.Join(", ", conn.Probe.Interfaces),
            Reachable = true,
            Status = reading.Status,
            Supplies = reading.Supplies ?? known?.Supplies ?? [],
            Pages = reading.Usage?.TotalImpressions ?? known?.Pages,
            Firmware = conn.Probe.Firmware?.Display ?? p.Firmware,
            LastReading = now,
        };
    }

    /// <summary>Another device answers at the address: nothing of it, and nothing kept that could be taken for it.</summary>
    private static FleetFacts Elsewhere(InkvoltPrinter p) => new(p.Uuid, p.Name, FleetKind.Network)
    {
        Model = p.Model,
        Reachable = false,
        Status = PrinterStatus.Offline("A different device answers at this address"),
    };

    private static FleetFacts Silent(InkvoltPrinter p, IFleetPc pc, string why)
    {
        var known = Known(p.Uuid, pc);
        return new FleetFacts(p.Uuid, p.Name, FleetKind.Network)
        {
            Model = p.Model,
            Reachable = false,
            Status = PrinterStatus.Offline(why),
            Supplies = known?.Supplies ?? [],
            Pages = known?.Pages,
            Firmware = p.Firmware,
            LastReadingDay = known?.Day,
            LastKnown = known is not null || p.Firmware is not null,
        };
    }

    private static FleetLastKnown? Known(string id, IFleetPc pc) => pc.History is { } history ? FleetLastKnown.From(history.Rows(id)) : null;

    private static async Task<FleetFacts> ReadQueueAsync(SpoolerQueue q, IFleetPc pc, DateTimeOffset now, CancellationToken ct)
    {
        var read = await pc.QueueStatus(q).ReadAsync(ct).ConfigureAwait(false);
        if (read is null) return SilentQueue(q, "Not found in Windows");
        return Queue(q) with
        {
            Reachable = !read.Offline,
            Status = read.Status,
            Supplies = read.Supplies,
            LastReading = read.Offline ? null : now,
        };
    }

    private static FleetFacts SilentQueue(SpoolerQueue q, string why) => Queue(q) with { Reachable = false, Status = PrinterStatus.Offline(why) };

    private static FleetFacts Queue(SpoolerQueue q) => new(QueueKinds.IdFor(q.Name), QueueKinds.DisplayName(q), FleetKind.Queue)
    {
        Model = q.DriverName,
        Connection = ConnectionWord(QueueKinds.Connection(q)),
    };

    /// <summary>How a queue is connected, without the server's or port's name.</summary>
    public static string ConnectionWord(QueueConnection c) => c switch
    {
        QueueConnection.Usb => "USB",
        QueueConnection.Network => "Network",
        QueueConnection.Shared => "Shared from another PC",
        QueueConnection.Parallel => "Parallel port",
        QueueConnection.Serial => "Serial port",
        _ => "Other",
    };

    private static async Task<FleetFacts> ReadScannerAsync(WiaDeviceInfo d, IFleetPc pc, DateTimeOffset now, CancellationToken ct)
    {
        try
        {
            // Connecting only reads what it offers (as inkvoltprint scanners --caps does); nothing scans.
            await WiaScanner.OpenAsync(pc.Wia, d, ct).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return SilentScanner(d);
        }
        return Scanner(d) with { Reachable = true, Status = new PrinterStatus("ready", "Ready to scan", Severity.Info, []), LastReading = now };
    }

    private static FleetFacts SilentScanner(WiaDeviceInfo d) => Scanner(d) with { Reachable = false, Status = PrinterStatus.Offline("Scanner not answering") };

    private static FleetFacts Scanner(WiaDeviceInfo d) => new(PrinterList.ScannerIdFor(d.Id), d.Name, FleetKind.Scanner)
    {
        Model = d.Description,
        Connection = "Windows scanner",
    };
}
