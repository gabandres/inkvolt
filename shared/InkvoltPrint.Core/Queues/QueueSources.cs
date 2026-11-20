using InkvoltPrint.Core.Snmp;

namespace InkvoltPrint.Core.Queues;

/// <summary>
/// Where a queue printer's status comes from, one rule for the app, the Fleet page and <c>status --all</c>: Windows and the
/// driver (<paramref name="windows"/>); for a queue whose port has the printer's address, the printer over SNMP too, with the
/// port's community; for a WSD queue, the printer over SNMP at the address its device node says now, once it says it is this one
/// (<see cref="WsdQueueStatusSource"/>), over the IPP class driver's and the driver's readings; for the others (USB, IPP), those
/// readings (<see cref="DeviceQueueStatusSource"/>) when there are any.
/// </summary>
public static class QueueSources
{
    /// <param name="readers">The device readers for the queue (IPP class driver, bidi); asked only when they're used.</param>
    /// <param name="latest">The queue as last listed (its WSD device's presence and address move); null: as given.</param>
    public static IQueueStatusSource For(SpoolerQueue q, IQueueStatusSource windows, Func<IReadOnlyList<IQueueDeviceReader>> readers,
        ISnmpTransport snmp, Func<SpoolerQueue>? latest = null)
    {
        if (QueueKinds.IsWsd(q)) return new WsdQueueStatusSource(Device(), latest ?? (() => q), snmp);
        if (QueueKinds.SnmpAddress(q) is { } host) return new SnmpQueueStatusSource(windows, host, snmp, q.PortCommunity);
        return Device();

        IQueueStatusSource Device() => readers() is { Count: > 0 } r ? new DeviceQueueStatusSource(windows, r) : windows;
    }

    /// <summary>
    /// The device readings that give a queue printer's supplies now, through the sources wrapped round them (for "From the
    /// printer over USB", "From its driver"); null when the levels come over SNMP or there are none.
    /// </summary>
    public static DeviceQueueStatusSource? SuppliesFrom(IQueueStatusSource? source) => source switch
    {
        DeviceQueueStatusSource device => device,
        WsdQueueStatusSource wsd => SuppliesFrom(wsd.Current),
        SnmpQueueStatusSource { Answers: false } snmp => SuppliesFrom(snmp.Inner),
        _ => null,
    };
}

/// <summary>
/// A WSD queue's printer: its readings through Windows (<paramref name="device"/>), and over SNMP at the address its device node
/// says while it is there (<see cref="QueueKinds.SnmpAddress"/>), asked again on each read from the queue as last listed: a
/// new address (DHCP) gets a new SNMP source, none (the printer left) drops it. The device that answers is read only once it says
/// it is this printer (<see cref="QueueKinds.SameDevice"/>), and checked again every minute.
/// </summary>
public sealed class WsdQueueStatusSource(IQueueStatusSource device, Func<SpoolerQueue> latest, ISnmpTransport transport) : IQueueStatusSource
{
    private SnmpQueueStatusSource? _snmp;

    /// <summary>The source read now: the SNMP one over the device readings, or those alone.</summary>
    public IQueueStatusSource Current => (IQueueStatusSource?)_snmp ?? device;

    public string Origin => Current.Origin;

    public bool HasSupplyLevels => Current.HasSupplyLevels;

    public Task<QueueStatusRead?> ReadAsync(CancellationToken ct)
    {
        var q = latest();
        var host = QueueKinds.SnmpAddress(q);
        if (host != _snmp?.Host)
            _snmp = host is null ? null : new SnmpQueueStatusSource(device, host, transport, q.PortCommunity, said => QueueKinds.SameDevice(latest(), said));
        return Current.ReadAsync(ct);
    }
}
