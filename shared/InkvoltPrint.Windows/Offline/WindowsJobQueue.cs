using System.ComponentModel;
using InkvoltPrint.Core;
using InkvoltPrint.Core.Alerts;
using InkvoltPrint.Core.Queues;

namespace InkvoltPrint.Windows.Offline;

/// <summary>A queue's own state and its jobs as the signed-in user sees them (GetPrinter, EnumJobs), for job alerts. Read only.</summary>
public static class WindowsJobQueue
{
    /// <summary>The queue now, or null when Windows no longer has it.</summary>
    /// <exception cref="Win32Exception">It couldn't be read: that says nothing about its jobs, so nobody may take it as "no jobs".</exception>
    public static JobQueueState? Read(string queueName)
    {
        var (queue, error) = Winspool.Queue(queueName);
        if (queue is null) return SpoolerStatus.IsRemoved(error) ? null : throw new Win32Exception(error);
        var jobs = Winspool.JobsInDetail(queueName);
        // A failing EnumJobs can look like an empty list: a queue that counts jobs and lists none wasn't read.
        if (jobs.Count == 0 && queue.Jobs > 0) throw new Win32Exception(0, CoreStrings.Win_JobsUnreadable);
        return JobQueueState.Of(queue, jobs);
    }
}
