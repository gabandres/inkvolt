using System.Runtime.InteropServices;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Windows.Printing;

/// <summary>
/// Watches the spooler for queues added, deleted or renamed (or moved to another port or driver) and says so through
/// <c>changed</c>, a burst once (<see cref="QueueChangeNotices"/>): the local print server's notices (<see cref="SpoolerWatcher"/>)
/// asked for add and delete and for the name, port and driver fields, so a queue's status changing while it prints isn't a notice
/// (<see cref="QueueChanges"/>). When the spooler isn't running, or restarts, it tries again every 30 s; the app's own 30 s listing
/// goes on either way.
/// </summary>
public sealed class SpoolerChanges : SpoolerWatcher
{
    private static readonly TimeSpan Quiet = TimeSpan.FromMilliseconds(750), Longest = TimeSpan.FromSeconds(3);

    /// <summary>PRINTER_NOTIFY_TYPE (the queue's own fields, not its jobs').</summary>
    private const ushort PrinterNotifyType = 0;

    private readonly QueueChangeNotices _notices;

    public SpoolerChanges(Action changed, Action<string> log)
        : base("Spooler change notices", QueueChanges.AddPrinter | QueueChanges.DeletePrinter, PrinterNotifyType, QueueChanges.Fields, log)
    {
        _notices = new QueueChangeNotices(changed, Quiet, Longest);
        Start();
    }

    protected override void OnNotice(uint what, IntPtr info)
    {
        uint flags = 0, count = 0;
        if (info != IntPtr.Zero)
        {
            // PRINTER_NOTIFY_INFO: Version, Flags, Count, then the data (only whether there is any matters here).
            flags = (uint)Marshal.ReadInt32(info, 4);
            count = (uint)Marshal.ReadInt32(info, 8);
        }
        if (QueueChanges.NeedsRelist(what, flags, count)) _notices.Notice();
    }

    protected override void Stopping() => _notices.Dispose(); // no more calls, whatever the thread is doing
}
