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
        if (await NameAsync() is not { } name) throw new PrintJobCancelException("This printer has no Windows queue any more.", false);
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
                throw new PrintJobCancelException(denied ? "Windows didn't allow it: only the person who printed it, or an administrator, can cancel it."
                    : "The job couldn't be cancelled. It may have just finished.", denied);
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
