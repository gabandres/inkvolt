using InkvoltPrint.Core.Offline;
using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.App;

/// <summary>
/// The offline fixer's view of a made-up PC (demo mode): a running Print Spooler, one Windows queue per demo printer, and
/// a network where the demo printers answer at their addresses. The office laser moved from
/// <see cref="Demo.OfficeOldHost"/> to <see cref="Demo.OfficeNewHost"/>; its queue's Standard TCP/IP port still points at
/// the old address, "Use Printer Offline" is on and one job is stuck in error. Repairs change only this made-up state
/// (a short pause stands in for Windows' permission prompt), so the whole flow can be tried and snapshotted without
/// reading or touching this PC's real queues, ports or spooler.
/// </summary>
internal sealed class DemoOfflinePc : IOfflineProbes, IOfflineRepairs
{
    private const string OfficeQueue = "Demo office laser";
    private readonly Lock _lock = new();
    private readonly IReadOnlyList<(string Uuid, string Host)> _online;
    private readonly string _officeUuid;
    private readonly List<QueueFacts> _queues;

    public DemoOfflinePc(IReadOnlyList<(string Uuid, string Host)> online, string officeUuid)
    {
        _online = online;
        _officeUuid = officeUuid;
        _queues =
        [
            .. online.Select((p, i) => new QueueFacts(i == 0 ? "Demo printer" : "Demo inkjet", new QueuePort($"WSD-demo-{i}", PortKind.DeviceId))
            {
                ContainerId = p.Uuid,
            }),
            new QueueFacts(OfficeQueue, new QueuePort($"IP_{Demo.OfficeOldHost}", PortKind.TcpIp) { Host = Demo.OfficeOldHost })
            {
                WorkOffline = true,
                ReportsOffline = true,
                Jobs = [new(21, "Invoice 1043.pdf", 2, 0, JobStatus.Error | JobStatus.Printing, DateTime.Now.AddMinutes(-14), Environment.UserName)],
            },
        ];
    }

    public Task<SpoolerState> SpoolerAsync(CancellationToken ct) => Task.FromResult(SpoolerState.Running);

    public async Task<Rediscovery?> RediscoverAsync(string uuid, CancellationToken ct)
    {
        await Task.Delay(700, ct); // an mDNS query takes a moment
        if (string.Equals(uuid, _officeUuid, StringComparison.OrdinalIgnoreCase)) return new Rediscovery(Demo.OfficeNewHost, "officelaser-demo.local");
        return _online.Where(p => string.Equals(p.Uuid, uuid, StringComparison.OrdinalIgnoreCase)).Select(p => new Rediscovery(p.Host, null)).FirstOrDefault();
    }

    public async Task<Reachability> ReachAsync(string host, CancellationToken ct)
    {
        await Task.Delay(400, ct);
        var answers = host == Demo.OfficeNewHost || _online.Any(p => p.Host == host);
        return new Reachability(host, answers, answers ? [631, 9100, 80] : []);
    }

    public Task<IReadOnlyList<QueueFacts>> QueuesAsync(CancellationToken ct)
    {
        lock (_lock) return Task.FromResult<IReadOnlyList<QueueFacts>>(_queues.ToList());
    }

    public async Task<Attempt> AsUserAsync(Repair repair, CancellationToken ct)
    {
        await Task.Delay(300, ct);
        switch (repair.Kind)
        {
            case RepairKind.ResumeQueue:
                Change(repair.Queue, q => q with { Paused = false });
                break;
            case RepairKind.ClearWorkOffline:
                Change(repair.Queue, q => q with { WorkOffline = false, ReportsOffline = q.Port.Host == Demo.OfficeOldHost });
                break;
            case RepairKind.CancelStuckJobs:
                Change(repair.Queue, q => q with { Jobs = q.Jobs.Where(j => !repair.JobIds.Contains(j.Id)).ToList() });
                break;
            case RepairKind.RestartStuckJobs:
                Change(repair.Queue, q => q with { Jobs = q.Jobs.Select(j => repair.JobIds.Contains(j.Id) ? j with { Status = JobStatus.None } : j).ToList() });
                break;
            case RepairKind.SetUpAgain:
                Change(repair.Queue, q => q with { ReportsOffline = false });
                break;
            default:
                return Attempt.Denied; // like Windows: ports and services need an administrator
        }
        return Attempt.Done;
    }

    public async Task<Attempt> ElevatedAsync(Repair repair, CancellationToken ct)
    {
        await Task.Delay(800, ct); // where Windows would show its permission prompt
        switch (repair.Kind)
        {
            case RepairKind.PointPortAt when repair.Target is { } target:
                Change(repair.Queue, q => q with
                {
                    Port = new QueuePort(System.Net.IPAddress.TryParse(target, out _) ? $"IP_{target}" : target, PortKind.TcpIp) { Host = target },
                    ReportsOffline = q.WorkOffline,
                });
                return Attempt.Done;
            case RepairKind.StartSpooler or RepairKind.RestartSpooler:
                return Attempt.Done;
            default:
                return await AsUserAsync(repair, ct);
        }
    }

    private void Change(string? queue, Func<QueueFacts, QueueFacts> change)
    {
        lock (_lock)
        {
            var i = _queues.FindIndex(q => q.Name == queue);
            if (i >= 0) _queues[i] = change(_queues[i]);
        }
    }
}
