namespace InkvoltPrint.Core.Queues;

/// <summary>
/// A Windows print queue as the spooler describes it (<c>PRINTER_INFO_2</c>): name, port, driver, status and attribute bits,
/// jobs waiting. <see cref="PortMonitor"/> is the port's monitor (<c>PORT_INFO_2</c>), <see cref="ContainerId"/> the queue's
/// PnP container (Windows uses the printer's UUID for IPP and WSD queues), both when known.
/// </summary>
public sealed record SpoolerQueue(string Name, string PortName, string? DriverName, uint Status, uint Attributes, int Jobs)
{
    public string? PortMonitor { get; init; }
    public string? ContainerId { get; init; }
    public string? Location { get; init; }
    public string? Comment { get; init; }

    /// <summary>
    /// The printer's address as a Standard TCP/IP port is set up with (TCPMON's <c>HostAddress</c>), and the port's SNMP
    /// community when SNMP status is on for it; null when not known (other ports, or not looked up).
    /// </summary>
    public string? PortAddress { get; init; }

    public string? PortCommunity { get; init; }

    /// <summary>
    /// Whether Windows sees the printer itself (its USB or WSD device node, <see cref="QueueKinds.DevicePresence"/>); null when
    /// that can't be told (IPP and TCP/IP queues, or not looked up). The spooler keeps saying "ready" for a WSD printer that left.
    /// </summary>
    public bool? DevicePresent { get; init; }
}

/// <summary><c>PRINTER_STATUS_*</c> and <c>PRINTER_ATTRIBUTE_*</c> (winspool.h; the status bits are System.Printing's PrintQueueStatus).</summary>
public static class SpoolerFlags
{
    public const uint StatusPaused = 0x1, StatusError = 0x2, StatusPendingDeletion = 0x4, StatusPaperJam = 0x8, StatusPaperOut = 0x10,
        StatusManualFeed = 0x20, StatusPaperProblem = 0x40, StatusOffline = 0x80, StatusIoActive = 0x100, StatusBusy = 0x200,
        StatusPrinting = 0x400, StatusOutputBinFull = 0x800, StatusNotAvailable = 0x1000, StatusWaiting = 0x2000,
        StatusProcessing = 0x4000, StatusInitializing = 0x8000, StatusWarmingUp = 0x10000, StatusTonerLow = 0x20000,
        StatusNoToner = 0x40000, StatusPagePunt = 0x80000, StatusUserIntervention = 0x100000, StatusOutOfMemory = 0x200000,
        StatusDoorOpen = 0x400000, StatusServerUnknown = 0x800000, StatusPowerSave = 0x1000000, StatusServerOffline = 0x2000000,
        StatusDriverUpdateNeeded = 0x4000000;

    public const uint AttributeNetwork = 0x10, AttributeLocal = 0x40, AttributeWorkOffline = 0x400, AttributeFax = 0x4000,
        AttributeTerminalServer = 0x8000;
}

/// <summary>How the PC reaches a queue's printer, from its port.</summary>
public enum QueueConnection { Usb, Network, Shared, Parallel, Serial, Other }
