using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Queues;

/// <summary>One read of a queue printer: its status, whether it can be reached, and supply levels when the source has them.</summary>
public sealed record QueueStatusRead(PrinterStatus Status, bool Offline, IReadOnlyList<Consumable> Supplies)
{
    public static QueueStatusRead From(QueueReading r) => new(r.Status, r.Offline, []);
}

/// <summary>
/// Where a printer known only by its Windows queue gets its status: the spooler and driver (<c>SpoolerStatusSource</c> in
/// InkvoltPrint.Windows), a made-up one in demo mode, or a richer source for a queue whose port has an address (SNMP).
/// </summary>
public interface IQueueStatusSource
{
    /// <summary>Where the status comes from, for the status card: "Windows and the printer's driver".</summary>
    string Origin { get; }

    /// <summary>Supply levels can come from this source (a driver's bits only say "low" or "out").</summary>
    bool HasSupplyLevels { get; }

    /// <summary>The queue now. Null when Windows no longer has it (removed meanwhile).</summary>
    Task<QueueStatusRead?> ReadAsync(CancellationToken ct);
}
