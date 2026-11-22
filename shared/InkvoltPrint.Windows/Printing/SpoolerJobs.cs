using InkvoltPrint.Core.History;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Windows.Printing;

/// <summary>
/// Every job this PC's spooler sees, for the print log (roadmap 4.9): the local print server's job notices (<see cref="SpoolerWatcher"/>,
/// the same watcher as <see cref="SpoolerChanges"/>), asked for the queue, document, user, computer, status, pages, submission time
/// and the job's DEVMODE, each notice read into <see cref="JobChange"/>s (strings and the DEVMODE bounded) for
/// <see cref="PrintLogKeeper"/>. The whole list is asked for as watching begins and after notices were dropped. Read only: nothing
/// about a job is changed.
/// </summary>
public sealed class SpoolerJobs : SpoolerWatcher
{
    /// <summary>PRINTER_CHANGE_JOB: a job added, set, deleted or written.</summary>
    private const uint ChangeJob = 0x0000FF00;

    /// <summary>JOB_NOTIFY_TYPE.</summary>
    private const ushort JobNotifyType = 1;

    /// <summary>winspool.h JOB_NOTIFY_FIELD_*.</summary>
    private const ushort PrinterName = 0x00, MachineName = 0x01, UserName = 0x03, DevMode = 0x09, Status = 0x0A, Document = 0x0D,
        Submitted = 0x10, TotalPages = 0x14, PagesPrinted = 0x15;

    private static readonly ushort[] Asked = [PrinterName, MachineName, UserName, DevMode, Status, Document, Submitted, TotalPages, PagesPrinted];

    private readonly Action<IReadOnlyList<JobChange>, JobNoticeKind> _notice;
    private volatile bool _stopping;

    public SpoolerJobs(Action<IReadOnlyList<JobChange>, JobNoticeKind> notice, Action<string> log)
        : base("Spooler job notices", ChangeJob, JobNotifyType, Asked, log)
    {
        _notice = notice;
        Start();
    }

    protected override bool AsksForEverythingFirst => true;

    protected override void OnNotice(uint what, IntPtr info) => Tell(Read(info), JobNoticeKind.Changes);

    protected override void OnRefresh(IntPtr info, bool first) => Tell(Read(info), first ? JobNoticeKind.EverythingFirst : JobNoticeKind.Everything);

    protected override void OnStopped() => Tell([], JobNoticeKind.Stopped);

    protected override void Stopping() => _stopping = true;

    private void Tell(IReadOnlyList<JobChange> changes, JobNoticeKind kind)
    {
        if (_stopping) return;
        try
        {
            _notice(changes, kind);
        }
        catch (Exception ex) // never let the log stop the watching
        {
            Log($"Print log: {ex.GetType().Name}");
        }
    }

    private static List<JobChange> Read(IntPtr info)
    {
        var changes = new List<JobChange>();
        foreach (var item in Items(info))
        {
            if (item.Type != JobNotifyType) continue;
            var change = new JobChange(item.Id);
            change = item.Field switch
            {
                PrinterName => change with { Printer = item.Text() },
                MachineName => change with { Machine = item.Text() },
                UserName => change with { User = item.Text() },
                Document => change with { Document = item.Text() },
                Status => change with { Status = (JobStatus)item.Number },
                TotalPages => change with { TotalPages = (int)Math.Min(item.Number, int.MaxValue) },
                PagesPrinted => change with { PagesPrinted = (int)Math.Min(item.Number, int.MaxValue) },
                Submitted => change with { Submitted = JobChange.SystemTime(item.Bytes(16)) },
                DevMode => change with { Settings = JobSettings.Read(item.Bytes(4096)) },
                _ => change,
            };
            changes.Add(change);
        }
        return changes;
    }
}
