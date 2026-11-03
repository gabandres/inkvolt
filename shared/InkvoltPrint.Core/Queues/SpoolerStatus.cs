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
    private static readonly (uint Bit, string Id, Severity Severity, Func<string> Message)[] Problems =
    [
        (SpoolerFlags.StatusPaperJam, "media-jam", Severity.Error, () => CoreStrings.Queue_PaperJam),
        (SpoolerFlags.StatusPaperOut, "media-empty", Severity.Error, () => CoreStrings.Queue_PaperOut),
        (SpoolerFlags.StatusDoorOpen, "door-open", Severity.Error, () => CoreStrings.Queue_DoorOpen),
        (SpoolerFlags.StatusNoToner, "no-toner", Severity.Error, () => CoreStrings.Queue_NoToner),
        (SpoolerFlags.StatusOutputBinFull, "output-bin-full", Severity.Error, () => CoreStrings.Queue_OutputBinFull),
        (SpoolerFlags.StatusPaperProblem, "media-problem", Severity.Error, () => CoreStrings.Queue_PaperProblem),
        (SpoolerFlags.StatusPagePunt, "page-punt", Severity.Error, () => CoreStrings.Queue_PagePunt),
        (SpoolerFlags.StatusOutOfMemory, "out-of-memory", Severity.Error, () => CoreStrings.Queue_OutOfMemory),
        (SpoolerFlags.StatusUserIntervention, "user-intervention", Severity.Error, () => CoreStrings.Queue_UserIntervention),
        (SpoolerFlags.StatusManualFeed, "manual-feed", Severity.Warning, () => CoreStrings.Queue_ManualFeed),
        (SpoolerFlags.StatusTonerLow, "toner-low", Severity.Warning, () => CoreStrings.Queue_TonerLow),
        (SpoolerFlags.StatusDriverUpdateNeeded, "driver-update", Severity.Warning, () => CoreStrings.Queue_DriverUpdate),
    ];

    /// <summary>The headline while Windows' "Use Printer Offline" holds the jobs.</summary>
    public static string UsePrinterOfflineMessage => CoreStrings.Queue_UsePrinterOffline;

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
        var server = QueueKinds.Connection(q) == QueueConnection.Shared ? QueueKinds.ServerOf(q.Name) ?? CoreStrings.Queue_AnotherPc : null;
        if (win32Error == ErrorAccessDenied)
            return new(new PrinterStatus("unknown", CoreStrings.Queue_StatusNotAvailable, Severity.Warning, [], server is not null
                ? string.Format(CoreStrings.Queue_SharedNoRead, server)
                : CoreStrings.Queue_WindowsNoRead), false);
        return server is not null
            ? new(new PrinterStatus("offline", CoreStrings.Queue_CantReachSharingPc, Severity.Error, [],
                string.Format(CoreStrings.Queue_CantReachSharingPcDetail, server)), true)
            : new(new PrinterStatus("offline", CoreStrings.Queue_WindowsNotAnswering, Severity.Error, [],
                CoreStrings.Queue_SpoolerNotAnswering), true);
    }

    public static QueueReading Describe(SpoolerQueue q)
    {
        var connection = QueueKinds.Connection(q);
        var waiting = q.Jobs == 0 ? "" : " " + Plural.Of(q.Jobs, CoreStrings.Queue_JobsWaiting_One, CoreStrings.Queue_JobsWaiting_Many);
        var workOffline = (q.Attributes & SpoolerFlags.AttributeWorkOffline) != 0;
        if (workOffline || (q.Status & OfflineBits) != 0)
        {
            var check = connection switch
            {
                QueueConnection.Usb => CoreStrings.Queue_CheckUsb,
                QueueConnection.Shared => CoreStrings.Queue_CheckShared,
                QueueConnection.Network => CoreStrings.Queue_CheckNetwork,
                _ => CoreStrings.Queue_CheckOther,
            };
            return workOffline
                ? new(new PrinterStatus("offline", UsePrinterOfflineMessage, Severity.Error, [],
                    CoreStrings.Queue_WorkOfflineDetail + waiting), true)
                : new(new PrinterStatus("offline", CoreStrings.Queue_Offline, Severity.Error, [], string.Format(CoreStrings.Queue_CantReachPrinter, check) + waiting), true);
        }

        if (q.DevicePresent == false)
        {
            var where = connection switch
            {
                QueueConnection.Usb => CoreStrings.Queue_NotSeenUsb,
                _ => CoreStrings.Queue_NotSeenNetwork,
            };
            return new(new PrinterStatus("offline", CoreStrings.Queue_NotConnected, Severity.Error, [], where + waiting), true);
        }

        if ((q.Status & SpoolerFlags.StatusPendingDeletion) != 0)
            return new(new PrinterStatus("deleting", CoreStrings.Queue_BeingRemoved, Severity.Warning, []), false);

        var alerts = Problems.Where(p => (q.Status & p.Bit) != 0).Select(p => new PrinterAlert(p.Id, p.Severity, p.Message())).ToList();
        if ((q.Status & SpoolerFlags.StatusError) != 0 && !alerts.Any(a => a.Severity == Severity.Error))
            alerts.Insert(0, new PrinterAlert("error", Severity.Error, CoreStrings.Queue_PrinterError));
        var worst = alerts.Select(a => a.Severity).DefaultIfEmpty(Severity.Info).Max();

        if (alerts.FirstOrDefault(a => a.Severity == Severity.Error) is { } error)
            return new(new PrinterStatus("error", error.Message, Severity.Error, alerts, (CoreStrings.Queue_DriverReports + waiting).TrimEnd()), false);

        if ((q.Status & SpoolerFlags.StatusPaused) != 0)
            return new(new PrinterStatus("paused", CoreStrings.Queue_PausedInWindows, Severity.Warning, alerts,
                CoreStrings.Queue_PausedDetail + waiting), false);

        var (code, message) = q.Status switch
        {
            var s when (s & (SpoolerFlags.StatusPrinting | SpoolerFlags.StatusProcessing)) != 0 => ("printing", CoreStrings.Queue_Printing),
            var s when (s & SpoolerFlags.StatusWarmingUp) != 0 => ("warmingUp", CoreStrings.Queue_WarmingUp),
            var s when (s & SpoolerFlags.StatusInitializing) != 0 => ("initializing", CoreStrings.Queue_StartingUp),
            var s when (s & SpoolerFlags.StatusPowerSave) != 0 => ("inPowerSave", CoreStrings.Queue_Sleeping),
            _ => ("ready", CoreStrings.Queue_Ready),
        };
        return new(new PrinterStatus(code, message, worst, alerts, waiting.Length > 0 ? waiting.Trim() : null), false);
    }
}
