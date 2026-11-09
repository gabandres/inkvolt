namespace InkvoltPrint.Core.Queues;

/// <summary>Where a device that needed its driver is now.</summary>
public enum DeviceNow
{
    /// <summary>Not plugged in (unplugged, perhaps as an installer said to): waiting, never "found".</summary>
    Absent,

    /// <summary>Plugged in, still with no working driver.</summary>
    NeedsDriver,

    /// <summary>Plugged in with a working driver (a printer: or with a queue).</summary>
    Working,
}

/// <summary>
/// Whether a device that needed its driver has it now, from its device nodes as Windows has them (any driver, present or not):
/// "Get the driver" counts it found only when it is plugged in and works, never when it merely left the needs-driver list (an
/// unplugged device leaves it too). A scanner is matched by its USB vendor and product ids, its own interface only (never an
/// all-in-one's composite parent or printer part, which have drivers of their own); a printer by its USB port, or its ids.
/// </summary>
public static class DeviceState
{
    /// <param name="drivers">The spooler's printer drivers (printers only): one matching the printer counts as working even while its
    /// node keeps Microsoft's placeholder, as the list itself has it ("Driver installed, not set up").</param>
    public static DeviceNow Of(NeedsDriverPrinter device, IReadOnlyList<UsbPrinterNode> nodes, IReadOnlyList<SpoolerQueue> queues,
        IReadOnlyList<SpoolerDriver>? drivers = null)
    {
        var mine = nodes.Where(n => n.Present && IsMine(device, n)).ToList();
        if (mine.Count == 0) return DeviceNow.Absent;
        if (device.IsScanner) return mine.Any(n => !n.DriverProblem()) ? DeviceNow.Working : DeviceNow.NeedsDriver;
        return mine.Any(n => NeedsDriver.HasQueue(n, queues) || !NeedsDriver.HasOnlyPlaceholder(n)
                             || drivers is { Count: > 0 } && NeedsDriver.MatchDriver(n, PrinterNames.ForDevice(n.FriendlyName, n.DeviceIdName, n.HardwareIds), drivers) is not null)
            ? DeviceNow.Working : DeviceNow.NeedsDriver;
    }

    /// <summary>Found: plugged in and working, and a scanner listed by WIA too (what the Scan tab uses).</summary>
    public static bool Found(NeedsDriverPrinter device, DeviceNow now, bool wiaLists) => now == DeviceNow.Working && (!device.IsScanner || wiaLists);

    private static bool IsMine(NeedsDriverPrinter device, UsbPrinterNode n)
    {
        if (device.IsScanner)
            return n.Kind == UsbNodeKind.UsbDevice && device.UsbId is { } id && UsbScanners.UsbIdOf(n) == id && !NeedsDriver.IsPrinterClass(n)
                   && !n.CompatibleIds.Any(c => c.StartsWith(@"USB\COMPOSITE", StringComparison.OrdinalIgnoreCase));
        if (device.Port is { Length: > 0 } port)
            return n.Kind == UsbNodeKind.UsbPrint && n.Port is { } p && string.Equals(p.Trim().TrimEnd(':'), port.Trim().TrimEnd(':'), StringComparison.OrdinalIgnoreCase);
        return device.UsbId is { } usb && UsbScanners.UsbIdOf(n) == usb && NeedsDriver.IsPrinterClass(n);
    }
}
