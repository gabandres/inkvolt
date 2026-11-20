using System.Printing;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.App.Printing;

/// <summary>A printer's Windows queue as a list of jobs. The demo printer has a made-up one (Demo.cs).</summary>
public interface IPrintJobs
{
    /// <summary>The jobs, or null when the printer has no Windows queue.</summary>
    Task<IReadOnlyList<QueueJob>?> ListAsync();

    /// <exception cref="PrintJobCancelException">The spooler refused (someone else's job) or the job is gone.</exception>
    Task CancelAsync(int jobId);

    /// <summary>The printer's Windows queue was set up, re-created or removed: look it up again.</summary>
    void QueueChanged() { }
}

/// <summary>A printer's queue for job alerts (Core.Alerts.AlertTracker.ObserveJobs): read every minute, also while the window is closed.</summary>
public interface IJobQueueReader
{
    /// <summary>The queue now, or null when the printer has none. Throws when it couldn't be read, which says nothing about its jobs.</summary>
    Task<Core.Alerts.JobQueueState?> ReadAsync();
}

/// <summary>
/// Reads through winspool (it has the PC a job came from, which System.Printing doesn't say) on the thread pool with a time limit:
/// a queue shared from a PC that's off holds the call until RPC gives up. "No queue" is kept for a while: looking for
/// one is a PnP query plus every queue's port, too much for each minute.
/// </summary>
public sealed class WindowsJobQueueReader(Func<Task<string?>> findQueue) : IJobQueueReader
{
    private static readonly TimeSpan NoQueueRecheck = TimeSpan.FromMinutes(5);
    private readonly Core.Queues.TimedCalls<string, Core.Alerts.JobQueueState?> _calls = new(TimeSpan.FromSeconds(10));
    private string? _name;
    private DateTime _lookedAt = DateTime.MinValue;

    public async Task<Core.Alerts.JobQueueState?> ReadAsync()
    {
        if (_name is null && DateTime.UtcNow - _lookedAt >= NoQueueRecheck)
        {
            _lookedAt = DateTime.UtcNow;
            _name = await findQueue();
        }
        if (_name is not { } name) return null;
        var (answered, queue) = await _calls.RunAsync(name, () => InkvoltPrint.Windows.Offline.WindowsJobQueue.Read(name));
        if (!answered) throw new TimeoutException("The queue didn't answer in time.");
        if (queue is null) (_name, _lookedAt) = (null, DateTime.MinValue); // gone from Windows, or renamed: look it up again next time
        return queue;
    }
}

/// <summary>
/// Job alerts for a printer that may print without its Windows queue (roadmap 2.1): while jobs go straight to the printer
/// (<paramref name="direct"/> says so, cheaply: it's asked every minute), the printer's own job list
/// (<see cref="Core.Printing.Direct.DirectJobWatch"/>); else the Windows queue's. Never both: a printer with a queue on the IPP class
/// driver lists the spooler's jobs too, under its own ids, and each would be told twice.
/// </summary>
public sealed class RoutedJobQueueReader(IJobQueueReader queue, Func<PrintTarget.Direct?> direct) : IJobQueueReader
{
    private readonly Core.Printing.Direct.DirectJobWatch _watch = new();

    public async Task<Core.Alerts.JobQueueState?> ReadAsync() =>
        direct() is { } d ? await _watch.ReadAsync(d.Ipp, d.User) : await queue.ReadAsync();
}

/// <summary>
/// The print queue card of a printer that may print without its Windows queue (roadmap 2.1): while jobs go straight to the
/// printer, the jobs the printer holds (Get-Jobs, Cancel-Job: <see cref="Core.Printing.Direct.PrinterJobs"/>); else the
/// Windows queue's.
/// </summary>
public sealed class RoutedPrintJobs(IPrintJobs queue, Func<Task<PrintTarget?>> findTarget) : IPrintJobs
{
    public async Task<IReadOnlyList<QueueJob>?> ListAsync()
    {
        if (await findTarget() is not PrintTarget.Direct direct) return await queue.ListAsync();
        var answer = await direct.Ipp.GetJobsAsync(Core.Printing.Direct.PrinterJobs.GetJobsRequest(direct.Ipp.PrinterUri, direct.User));
        return Core.Printing.Direct.PrinterJobs.Parse(answer, DateTime.Now);
    }

    public async Task CancelAsync(int jobId)
    {
        if (await findTarget() is not PrintTarget.Direct direct)
        {
            await queue.CancelAsync(jobId);
            return;
        }
        if (!await Core.Printing.Direct.DirectJob.CancelAsync(direct.Ipp, direct.User, jobId))
            throw new PrintJobCancelException(Strings.Print_CancelFailed, false);
    }

    public void QueueChanged() => queue.QueueChanged();
}

public sealed class PrintJobCancelException(string message, bool accessDenied) : Exception(message)
{
    public bool AccessDenied { get; } = accessDenied;
}

/// <summary>
/// Reads and cancels jobs through System.Printing. Each call opens its own server/queue objects on a pool thread
/// (they're cheap local spooler handles and not meant to be shared across threads). No elevation: anyone may
/// list a queue and cancel their own jobs; cancelling someone else's needs an administrator, and is reported as such.
/// The queue's name is looked up once (a PnP query plus every queue's port) and kept until the queue changes or can't
/// be opened; "no queue" is kept for a while, since a queue added outside Inkvolt Print raises no QueueChanged.
/// </summary>
public sealed class WindowsPrintJobs(Func<Task<string?>> findQueue) : IPrintJobs
{
    private const int AccessDeniedHResult = unchecked((int)0x80070005);
    private static readonly TimeSpan NoQueueRecheck = TimeSpan.FromSeconds(30);

    private string? _name;
    private DateTime _resolvedAt = DateTime.MinValue;

    public void QueueChanged() => _resolvedAt = DateTime.MinValue;

    private async Task<string?> NameAsync()
    {
        if (_name is null ? DateTime.UtcNow - _resolvedAt > NoQueueRecheck : _resolvedAt == DateTime.MinValue)
        {
            _name = await findQueue();
            _resolvedAt = DateTime.UtcNow;
        }
        return _name;
    }

    public async Task<IReadOnlyList<QueueJob>?> ListAsync()
    {
        if (await NameAsync() is not { } name) return null;
        try
        {
            return await Task.Run(() =>
            {
                using var server = new LocalPrintServer();
                using var queue = new PrintQueue(server, name, PrintSystemDesiredAccess.UsePrinter);
                using var infos = queue.GetPrintJobInfoCollection();
                var jobs = new List<QueueJob>();
                foreach (var info in infos)
                    using (info)
                    {
                        try { jobs.Add(ToJob(info)); }
                        catch (PrintSystemException) { } // finished while we were reading it
                    }
                return (IReadOnlyList<QueueJob>)QueueJobText.Order(jobs);
            });
        }
        catch
        {
            QueueChanged(); // renamed or removed under us, or the spooler restarted: look it up again next time
            throw;
        }
    }

    public async Task CancelAsync(int jobId)
    {
        if (await NameAsync() is not { } name) throw new PrintJobCancelException(Strings.Print_NoQueueAnyMore, false);
        await Task.Run(() =>
        {
            try
            {
                using var server = new LocalPrintServer();
                using var queue = new PrintQueue(server, name, PrintSystemDesiredAccess.UsePrinter);
                using var job = queue.GetJob(jobId);
                job.Cancel();
            }
            catch (Exception ex) when (ex is PrintSystemException or UnauthorizedAccessException)
            {
                var denied = ex is UnauthorizedAccessException || ex.HResult == AccessDeniedHResult
                             || ex.InnerException?.HResult == AccessDeniedHResult;
                throw new PrintJobCancelException(denied ? Strings.Print_CancelDenied : Strings.Print_CancelFailed, denied);
            }
        });
    }

    private static QueueJob ToJob(PrintSystemJobInfo info)
    {
        // The spooler reports submission time in UTC.
        var submitted = info.TimeJobSubmitted;
        submitted = submitted.Kind == DateTimeKind.Local ? submitted : DateTime.SpecifyKind(submitted, DateTimeKind.Utc).ToLocalTime();
        return new QueueJob(info.JobIdentifier, info.Name ?? "", info.NumberOfPages, info.NumberOfPagesPrinted,
            (JobStatus)(int)info.JobStatus, submitted, info.Submitter ?? "");
    }
}
