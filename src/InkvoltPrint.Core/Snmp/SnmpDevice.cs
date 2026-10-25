using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// A printer that answered only SNMP when it was added (no LEDM, CDM or IPP), remembered with what it said about itself:
/// SNMP has no UUID, so its serial number (prtGeneralSerialNumber), model (hrDeviceDescr) and name (sysName) tell whether the
/// device at its address is still it. Only these printers are read over SNMP: a printer that answers HTTP and doesn't for a
/// moment (asleep, waking) is offline, never turned into an SNMP-only printer.
/// </summary>
public sealed record SnmpDevice(string? SerialNumber, string? Model, string? SystemName)
{
    public static SnmpDevice From(SnmpIdentity id) => new(Clean(id.SerialNumber), Clean(id.Model), Clean(id.SystemName));

    /// <summary>Where a printer's connection may go over SNMP: <paramref name="transport"/> for a printer added as SNMP-only, else nowhere.</summary>
    public static ISnmpTransport? TransportFor(SnmpDevice? addedSnmpOnly, ISnmpTransport transport) => addedSnmpOnly is null ? null : transport;

    /// <summary>
    /// The device answering SNMP now against this one: Different when a serial number, model or name both report disagrees;
    /// Same when all that both report agree; Unknown when there's nothing to compare.
    /// </summary>
    public DeviceIdentity Identify(SnmpIdentity now)
    {
        var compared = new[] { (SerialNumber, Clean(now.SerialNumber)), (Model, Clean(now.Model)), (SystemName, Clean(now.SystemName)) }
            .Where(p => p.Item1 is not null && p.Item2 is not null).ToList();
        if (compared.Count == 0) return DeviceIdentity.Unknown;
        return compared.All(p => string.Equals(p.Item1, p.Item2, StringComparison.OrdinalIgnoreCase)) ? DeviceIdentity.Same : DeviceIdentity.Different;
    }

    /// <summary>A serial number from another interface (LEDM's or CDM's, when the printer starts answering them) against this one.</summary>
    public DeviceIdentity Identify(string? serialNumber) =>
        SerialNumber is null || Clean(serialNumber) is not { } sn ? DeviceIdentity.Unknown
        : string.Equals(SerialNumber, sn, StringComparison.OrdinalIgnoreCase) ? DeviceIdentity.Same : DeviceIdentity.Different;

    private static string? Clean(string? s) => s?.Trim() is { Length: > 0 } t ? t : null;
}
