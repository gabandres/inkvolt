using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Queues;

/// <summary>A queue's status in plain words. <see cref="Offline"/>: Windows says the printer can't be reached (or holds jobs for it).</summary>
public sealed record QueueReading(PrinterStatus Status, bool Offline);

/// <summary>
/// The spooler's status bits for a queue (what Windows and the printer's driver report) as a <see cref="PrinterStatus"/>. Alert
/// ids follow IPP's printer-state-reasons where one fits, so tray alerts classify them like a network printer's.
/// </summary>
public static class SpoolerStatus
{
    private static readonly (uint Bit, string Id, Severity Severity, string Message)[] Problems =
    [
        (SpoolerFlags.StatusPaperJam, "media-jam", Severity.Error, "Paper jam"),
        (SpoolerFlags.StatusPaperOut, "media-empty", Severity.Error, "Out of paper"),
        (SpoolerFlags.StatusDoorOpen, "door-open", Severity.Error, "A door or cover is open"),
        (SpoolerFlags.StatusNoToner, "no-toner", Severity.Error, "Out of toner or ink"),
        (SpoolerFlags.StatusOutputBinFull, "output-bin-full", Severity.Error, "Output tray is full"),
        (SpoolerFlags.StatusPaperProblem, "media-problem", Severity.Error, "Paper problem"),
        (SpoolerFlags.StatusPagePunt, "page-punt", Severity.Error, "Can't print the current page"),
        (SpoolerFlags.StatusOutOfMemory, "out-of-memory", Severity.Error, "The printer ran out of memory"),
        (SpoolerFlags.StatusUserIntervention, "user-intervention", Severity.Error, "The printer needs attention"),
        (SpoolerFlags.StatusManualFeed, "manual-feed", Severity.Warning, "Waiting for paper in the manual feed"),
        (SpoolerFlags.StatusTonerLow, "toner-low", Severity.Warning, "Toner or ink is low (as the driver reports it)"),
        (SpoolerFlags.StatusDriverUpdateNeeded, "driver-update", Severity.Warning, "Windows says the printer's driver needs an update"),
    ];

    /// <summary>The headline while Windows' "Use Printer Offline" holds the jobs.</summary>
    public const string UsePrinterOfflineMessage = "Use Printer Offline is on";

    private const uint OfflineBits = SpoolerFlags.StatusOffline | SpoolerFlags.StatusNotAvailable | SpoolerFlags.StatusServerOffline
                                     | SpoolerFlags.StatusServerUnknown;

    /// <summary>Win32 errors from opening a queue (winerror.h).</summary>
    public const int ErrorAccessDenied = 5, ErrorInvalidPrinterName = 1801;

    /// <summary>
    /// Whether a failure to open a queue means Windows no longer has it: only ERROR_INVALID_PRINTER_NAME. A print server that's
    /// off or a spooler restarting (RPC errors such as 1722 and 1726), access denied, or no answer in time say nothing about that.
    /// </summary>
    public static bool IsRemoved(int win32Error) => win32Error == ErrorInvalidPrinterName;

    /// <summary>
    /// The status of a queue Windows has but couldn't read now (<paramref name="win32Error"/> from opening it, 0 when the call didn't
    /// return in time): access denied leaves the status unknown; anything else is offline, for a printer shared from another PC
    /// because that PC can't be reached, for one of this PC's because the Print Spooler isn't answering.
    /// </summary>
    public static QueueReading Unreadable(SpoolerQueue q, int win32Error)
    {
        var server = QueueKinds.Connection(q) == QueueConnection.Shared ? QueueKinds.ServerOf(q.Name) ?? "another PC" : null;
        if (win32Error == ErrorAccessDenied)
            return new(new PrinterStatus("unknown", "Status not available", Severity.Warning, [], server is not null
                ? $"The PC sharing this printer ({server}) doesn't let this PC read its status."
                : "Windows doesn't let Inkvolt Print read this printer's status."), false);
        return server is not null
            ? new(new PrinterStatus("offline", "Can't reach the PC sharing it", Severity.Error, [],
                $"Windows can't reach {server}, the PC sharing this printer. Check that it's on and on the same network as this PC."), true)
            : new(new PrinterStatus("offline", "Windows isn't answering", Severity.Error, [],
                "The Print Spooler isn't answering about this printer (it may be restarting). Inkvolt Print keeps asking."), true);
    }

    public static QueueReading Describe(SpoolerQueue q)
    {
        var connection = QueueKinds.Connection(q);
        var waiting = q.Jobs switch { 0 => "", 1 => " 1 job is waiting.", var n => $" {n} jobs are waiting." };
        var workOffline = (q.Attributes & SpoolerFlags.AttributeWorkOffline) != 0;
        if (workOffline || (q.Status & OfflineBits) != 0)
        {
            var check = connection switch
            {
                QueueConnection.Usb => "Check that it's turned on and its USB cable is plugged in.",
                QueueConnection.Shared => "Check that the PC sharing it is on and the printer is turned on.",
                QueueConnection.Network => "Check that it's turned on and on the same network as this PC.",
                _ => "Check that it's turned on and connected.",
            };
            return workOffline
                ? new(new PrinterStatus("offline", UsePrinterOfflineMessage, Severity.Error, [],
                    $"Windows holds print jobs for this printer until it's turned off in the printer's queue (Open Windows queue › Printer).{waiting}"), true)
                : new(new PrinterStatus("offline", "Offline", Severity.Error, [], $"Windows can't reach the printer. {check}{waiting}"), true);
        }

        if (q.DevicePresent == false)
        {
            var where = connection switch
            {
                QueueConnection.Usb => "Windows doesn't see it on USB. Check that it's turned on and its USB cable is plugged in.",
                _ => "Windows doesn't see it on the network. Check that it's turned on and on the same network as this PC.",
            };
            return new(new PrinterStatus("offline", "Not connected", Severity.Error, [], $"{where}{waiting}"), true);
        }

        if ((q.Status & SpoolerFlags.StatusPendingDeletion) != 0)
            return new(new PrinterStatus("deleting", "Being removed from Windows", Severity.Warning, []), false);

        var alerts = Problems.Where(p => (q.Status & p.Bit) != 0).Select(p => new PrinterAlert(p.Id, p.Severity, p.Message)).ToList();
        if ((q.Status & SpoolerFlags.StatusError) != 0 && !alerts.Any(a => a.Severity == Severity.Error))
            alerts.Insert(0, new PrinterAlert("error", Severity.Error, "Printer error"));
        var worst = alerts.Select(a => a.Severity).DefaultIfEmpty(Severity.Info).Max();

        if (alerts.FirstOrDefault(a => a.Severity == Severity.Error) is { } error)
            return new(new PrinterStatus("error", error.Message, Severity.Error, alerts, $"Windows and the printer's driver report this.{waiting}".TrimEnd()), false);

        if ((q.Status & SpoolerFlags.StatusPaused) != 0)
            return new(new PrinterStatus("paused", "Paused in Windows", Severity.Warning, alerts,
                $"Windows holds print jobs until the queue is resumed (Open Windows queue › Printer › Pause Printing).{waiting}"), false);

        var (code, message) = q.Status switch
        {
            var s when (s & (SpoolerFlags.StatusPrinting | SpoolerFlags.StatusProcessing)) != 0 => ("printing", "Printing"),
            var s when (s & SpoolerFlags.StatusWarmingUp) != 0 => ("warmingUp", "Warming up"),
            var s when (s & SpoolerFlags.StatusInitializing) != 0 => ("initializing", "Starting up"),
            var s when (s & SpoolerFlags.StatusPowerSave) != 0 => ("inPowerSave", "Sleeping"),
            _ => ("ready", "Ready"),
        };
        return new(new PrinterStatus(code, message, worst, alerts, waiting.Length > 0 ? waiting.Trim() : null), false);
    }
}
