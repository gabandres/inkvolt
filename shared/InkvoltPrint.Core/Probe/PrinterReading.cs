using System.Xml.Linq;
using InkvoltPrint.Core.Cdm;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Ipp;
using InkvoltPrint.Core.Ledm;
using InkvoltPrint.Core.Model;
using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Core.Probe;

/// <summary>
/// One read of a printer's state (<see cref="PrinterConnection.ReadAsync"/>): its status, supply levels and usage counters,
/// each from the first of its interfaces that can give it.
/// </summary>
/// <param name="Status">
/// <see cref="PrinterStatus.Offline"/> when the printer didn't answer; <see cref="PrinterStatus.Unavailable"/> when it answered
/// with errors or garbage (it is waking up or busy: keep the last good status on screen).
/// </param>
/// <param name="Supplies">Null when they couldn't be read this time (keep the last known levels); empty when the printer reports none.</param>
/// <param name="Usage">Lifetime counters (HP's LEDM only); null when the printer has none or they couldn't be read.</param>
public sealed record PrinterReading(PrinterStatus Status, IReadOnlyList<Consumable>? Supplies, UsageCounters? Usage)
{
    public bool IsOffline => Status.Code == "offline";
}

/// <summary>The parts of a <see cref="PrinterReading"/> a caller wants (only those are asked of the printer).</summary>
[Flags]
internal enum ReadParts
{
    Status = 1,
    Supplies = 2,
    Usage = 4,
    All = Status | Supplies | Usage,
}

/// <summary>
/// The printer status module: the one fallback order (LEDM, then CDM, then IPP, then SNMP; eSCL too for the UUID) and the one
/// error rule over a connection's interfaces, each an adapter (<see cref="ReadingSource"/>).
/// <list type="bullet">
/// <item>An interface that hasn't a part (null, "not supported") passes it to the next.</item>
/// <item>An interface that answers with an error or garbage (<see cref="PrinterConnection.IsTransient"/>: common while a printer
/// wakes up) passes it to the next too; when none gives it, status is Unavailable and supplies unknown.</item>
/// <item>A network failure (<see cref="PrinterConnection.IsOffline"/>) reading status ends the read: the next interface is the
/// same host, so nothing more is asked (no stack of timeouts), and status is Offline. One reading supplies leaves them unknown
/// (not asked of the next interface) and ends nothing: status alone decides online or offline.</item>
/// <item>Usage counters are extra: when they fail they are just missing.</item>
/// </list>
/// Every part an interface gives comes from one request where its protocol allows (IPP: one Get-Printer-Attributes).
/// </summary>
internal sealed class PrinterReader(IReadOnlyList<ReadingSource> sources)
{
    public async Task<PrinterReading> ReadAsync(ReadParts parts, CancellationToken ct)
    {
        PrinterStatus? status = null;
        IReadOnlyList<Consumable>? supplies = null;
        UsageCounters? usage = null;
        bool statusMissed = false, suppliesMissed = false, offline = false;
        var need = parts;
        foreach (var source in sources)
        {
            if (need == 0) break;
            var started = source.Start(need, ct);
            var s = Outcome<PrinterStatus>.Of(started.Status);
            var c = Outcome<IReadOnlyList<Consumable>>.Of(started.Supplies);
            var u = Outcome<UsageCounters>.Of(started.Usage);
            await Task.WhenAll(s, c, u).ConfigureAwait(false);
            if (s.Result.Value is { } gotStatus) (status, need) = (gotStatus, need & ~ReadParts.Status);
            if (c.Result.Value is { } gotSupplies) (supplies, need) = (gotSupplies, need & ~ReadParts.Supplies);
            if (u.Result.Value is { } gotUsage) (usage, need) = (gotUsage, need & ~ReadParts.Usage);
            statusMissed |= s.Result.Missed;
            suppliesMissed |= c.Result.Missed || c.Result.Offline;
            if (s.Result.Offline) // status decides: the printer isn't there
            {
                offline = true;
                break;
            }
            // Supplies that timed out aren't asked of the next interface (the same host), but they end nothing: status still
            // comes from whichever interface gives it. Usage counters are extra: their failure ends nothing either.
            if (c.Result.Offline) need &= ~ReadParts.Supplies;
        }
        if (status is null && offline) return new PrinterReading(PrinterStatus.Offline("Printer is not responding"), null, null); // nothing else counts
        return new PrinterReading(
            status ?? (offline ? PrinterStatus.Offline("Printer is not responding")
                : statusMissed ? PrinterStatus.Unavailable("The printer is busy; status will update shortly")
                : new PrinterStatus("unknown", "Status not available", Severity.Info, [])),
            supplies ?? (offline || suppliesMissed ? null : []),
            usage);
    }

    /// <summary>
    /// The UUID the device reports now, from the first interface that tells (same rule: errors pass to the next interface,
    /// a network failure stops). Empty when none told.
    /// </summary>
    public async Task<IReadOnlyList<string?>> ReadUuidsAsync(CancellationToken ct)
    {
        foreach (var source in sources)
        {
            if (source.ReadUuidAsync(ct) is not { } read) continue;
            var outcome = await Outcome<string>.Of(read).ConfigureAwait(false);
            if (outcome.Value is { Length: > 0 } uuid) return [uuid];
            if (outcome.Offline) break;
        }
        return [];
    }

    private readonly record struct Outcome<T>(T? Value, bool Missed, bool Offline) where T : class
    {
        /// <summary>The part's read, settled: the value, or which kind of failure. Cancellation and other faults propagate.</summary>
        public static async Task<Outcome<T>> Of(Task<T?>? read)
        {
            if (read is null) return default;
            try
            {
                return new(await read.ConfigureAwait(false), false, false);
            }
            catch (Exception ex) when (PrinterConnection.IsOffline(ex))
            {
                return new(null, false, true);
            }
            catch (Exception ex) when (PrinterConnection.IsTransient(ex))
            {
                return new(null, true, false);
            }
        }
    }
}

/// <summary>The parts one interface was asked for, started (null: it hasn't that part, or it wasn't asked).</summary>
internal readonly record struct StartedRead(
    Task<PrinterStatus?>? Status = null, Task<IReadOnlyList<Consumable>?>? Supplies = null, Task<UsageCounters?>? Usage = null);

/// <summary>One of a connection's interfaces as the <see cref="PrinterReader"/> sees it: an adapter over its protocol client.</summary>
internal abstract class ReadingSource
{
    /// <summary>Starts reading the parts asked for that this interface has. A part it hasn't, or answers without, is null.</summary>
    public virtual StartedRead Start(ReadParts parts, CancellationToken ct) => default;

    /// <summary>One small read of the UUID this interface reports; null when it has no UUID.</summary>
    public virtual Task<string?>? ReadUuidAsync(CancellationToken ct) => null;

    /// <summary>
    /// HP's LEDM: status, consumables and usage, three small documents read at the same time. The usage document serves both the
    /// counters and the consumables' page estimates (read once); when it fails the estimates are just missing.
    /// </summary>
    public sealed class Ledm(LedmClient client) : ReadingSource
    {
        public override StartedRead Start(ReadParts parts, CancellationToken ct)
        {
            var wantsSupplies = parts.HasFlag(ReadParts.Supplies);
            var usage = wantsSupplies || parts.HasFlag(ReadParts.Usage) ? client.GetAsync(LedmResource.ProductUsageDyn, ct) : null;
            return new(
                parts.HasFlag(ReadParts.Status) ? client.GetStatusAsync(ct) : null,
                wantsSupplies ? Consumables(client.GetAsync(LedmResource.ConsumableConfigDyn, ct), usage!) : null,
                parts.HasFlag(ReadParts.Usage) ? Map(usage!, d => d is null ? null : LedmParsers.ParseUsage(d)) : null);

            static async Task<IReadOnlyList<Consumable>?> Consumables(Task<XDocument?> consumables, Task<XDocument?> usage)
            {
                XDocument? counters;
                try { counters = await usage.ConfigureAwait(false); }
                catch (Exception ex) when (PrinterConnection.IsOffline(ex) || PrinterConnection.IsTransient(ex)) { counters = null; }
                return await consumables.ConfigureAwait(false) is { } d ? LedmParsers.ParseConsumables(d, counters) : null;
            }
        }

        public override Task<string?> ReadUuidAsync(CancellationToken ct) => Uuid(client.GetProductInfoAsync(ct));
    }

    /// <summary>
    /// HP's CDM: status, then supplies, one after the other (CDM printers time out under bursts). An empty supplies list
    /// counts as none, so the next interface is asked.
    /// </summary>
    public sealed class Cdm(CdmClient client) : ReadingSource
    {
        public override StartedRead Start(ReadParts parts, CancellationToken ct)
        {
            var status = parts.HasFlag(ReadParts.Status) ? client.GetStatusAsync(ct) : null;
            return new(status, parts.HasFlag(ReadParts.Supplies) ? SuppliesAfter(status) : null);

            async Task<IReadOnlyList<Consumable>?> SuppliesAfter(Task? first)
            {
                if (first is not null)
                    try { await first.ConfigureAwait(false); }
                    catch (Exception ex) when (PrinterConnection.IsOffline(ex)) { throw; }
                    catch (Exception ex) when (PrinterConnection.IsTransient(ex)) { } // supplies may still answer
                return await client.GetSuppliesAsync(ct).ConfigureAwait(false) is { Count: > 0 } s ? s : null;
            }
        }

        public override Task<string?> ReadUuidAsync(CancellationToken ct) => Uuid(client.GetIdentityAsync(ct));
    }

    /// <summary>IPP: status and supplies both from one Get-Printer-Attributes request.</summary>
    public sealed class Ipp(IppClient client) : ReadingSource
    {
        public override StartedRead Start(ReadParts parts, CancellationToken ct)
        {
            if ((parts & (ReadParts.Status | ReadParts.Supplies)) == 0) return default;
            var attributes = client.GetPrinterAttributesAsync(ct: ct);
            return new(
                parts.HasFlag(ReadParts.Status) ? Map(attributes, IppClient.ToStatus) : null,
                parts.HasFlag(ReadParts.Supplies) ? Map(attributes, IppClient.ToConsumables) : null);
        }

        public override Task<string?> ReadUuidAsync(CancellationToken ct) =>
            Map(client.GetPrinterAttributesAsync(ct: ct), r => r.Str("printer-uuid"));
    }

    /// <summary>SNMP (Printer MIB): status and supplies from one walk (the client shares a read made moments ago). No UUID.</summary>
    public sealed class Snmp(SnmpPrinterClient client) : ReadingSource
    {
        public override StartedRead Start(ReadParts parts, CancellationToken ct)
        {
            if ((parts & (ReadParts.Status | ReadParts.Supplies)) == 0) return default;
            var reading = client.ReadAsync(ct);
            return new(
                parts.HasFlag(ReadParts.Status) ? Map(reading, SnmpPrinterStatus.ToStatus) : null,
                parts.HasFlag(ReadParts.Supplies) ? Map(reading, SnmpPrinterStatus.ToConsumables) : null);
        }
    }

    /// <summary>eSCL: only the UUID its capabilities carry (a scanner reports no printer status).</summary>
    public sealed class Escl(EsclClient client) : ReadingSource
    {
        public override Task<string?> ReadUuidAsync(CancellationToken ct) => Uuid(client.GetCapabilitiesAsync(ct));
    }

    private static async Task<string?> Uuid(Task<ProductInfo?> read) => (await read.ConfigureAwait(false))?.Uuid;

    private static async Task<string?> Uuid(Task<ScannerCapabilities?> read) => (await read.ConfigureAwait(false))?.Uuid;

    private static async Task<TOut?> Map<TIn, TOut>(Task<TIn> read, Func<TIn, TOut?> map) where TOut : class =>
        map(await read.ConfigureAwait(false));
}
