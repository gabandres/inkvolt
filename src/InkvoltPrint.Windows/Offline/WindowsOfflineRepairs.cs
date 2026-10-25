using System.ComponentModel;
using System.Net;
using InkvoltPrint.Core.Offline;
using InkvoltPrint.Windows.Queues;

namespace InkvoltPrint.Windows.Offline;

/// <summary>
/// Carries out the offline fixer's repairs on this PC. As the user: resume a queue, turn off "Use Printer Offline",
/// cancel or restart jobs (winspool, no prompt; Windows decides who may). Elevated (one UAC prompt each, unpackaged
/// copies only, see <see cref="RepairRunner"/>): the same through PowerShell/CIM, starting or restarting the Print
/// Spooler, pointing a queue at a new Standard TCP/IP port, and re-adding a queue at a new IPP URL. The scripts are
/// <see cref="RepairScripts"/>: constants that find every queue, port and job by exact name; names, addresses and job ids
/// reach them only as Base64 values (<see cref="Elevated"/>). Setting a discovered queue up again (pairing) is done by
/// the app, not here.
/// </summary>
public sealed class WindowsOfflineRepairs : IOfflineRepairs
{
    private static readonly TimeSpan ScriptTimeout = TimeSpan.FromMinutes(2);

    public Task<Attempt> AsUserAsync(Repair repair, CancellationToken ct) => Task.Run(() =>
    {
        var queue = repair.Queue ?? "";
        if (repair.Kind is RepairKind.CancelStuckJobs or RepairKind.RestartStuckJobs)
        {
            var (denied, error) = Winspool.ControlJobs(queue, repair.JobIds, restart: repair.Kind == RepairKind.RestartStuckJobs);
            // Someone else's jobs: only those go on to the administrator (RepairRunner retries just DeniedJobIds).
            if (denied.Count > 0) return Attempt.Denied with { DeniedJobIds = denied };
            return error == 0 ? Attempt.Done : new Attempt(AttemptResult.Failed, $"Windows said: {new Win32Exception(error).Message}");
        }
        var result = repair.Kind switch
        {
            RepairKind.ResumeQueue => Winspool.Resume(queue),
            RepairKind.ClearWorkOffline => Winspool.ClearWorkOffline(queue),
            _ => Winspool.ErrorAccessDenied, // services and ports: never as a standard user
        };
        return result switch
        {
            0 => Attempt.Done,
            Winspool.ErrorAccessDenied => Attempt.Denied,
            _ => new Attempt(AttemptResult.Failed, $"Windows said: {new Win32Exception(result).Message}"),
        };
    }, ct);

    public async Task<Attempt> ElevatedAsync(Repair repair, CancellationToken ct)
    {
        // Choosing names reads the spooler's ports and the port monitor's registry key: off the UI thread.
        var script = await Task.Run(() => repair.Kind switch
        {
            RepairKind.PointPortAt when repair.Target is { } target => RepairScripts.For(repair, portName: PortNameFor(target, repair.PortNumber)),
            RepairKind.RecreateIppQueue when repair.TargetUrl is { } url =>
                RepairScripts.For(repair, temporaryName: TemporaryName(repair.Queue ?? "Printer"), httpUrl: IppQueueInstaller.HttpForm(url)),
            _ => RepairScripts.For(repair),
        }, ct).ConfigureAwait(false);
        if (script is null) return new Attempt(AttemptResult.Failed, "Inkvolt Print can't do this one itself.");

        var code = await Elevated.RunAsync(script.Script, script.Values, ScriptTimeout, ct).ConfigureAwait(false);
        return code switch
        {
            Elevated.Cancelled => new Attempt(AttemptResult.Cancelled),
            Elevated.StoppedWaiting => new Attempt(AttemptResult.Stopped),
            // The elevated process can't be stopped from here and may still finish: say so, and let the fixer look again.
            Elevated.TimedOut => new Attempt(AttemptResult.Unknown),
            RepairScripts.Done => Attempt.Done,
            _ => new Attempt(AttemptResult.Failed, Explain(repair, code, script.Values)),
        };
    }

    private static string Explain(Repair repair, int code, IReadOnlyList<string> values) => (repair.Kind, code) switch
    {
        (_, RepairScripts.NoSuchQueue) => $"Windows no longer has a printer called “{repair.Queue}”.",
        (RepairKind.RecreateIppQueue, RepairScripts.Failed) => $"Windows couldn't add the printer at {values[2]}. “{repair.Queue}” is unchanged.",
        (RepairKind.RecreateIppQueue, RepairScripts.NotRemoved) =>
            $"The printer was added as “{values[1]}”, but the old “{repair.Queue}” couldn't be removed. Remove it in Settings.",
        (RepairKind.RecreateIppQueue, RepairScripts.NotRenamed) =>
            $"The printer was added as “{values[1]}” and the old one removed, but it couldn't be renamed to “{repair.Queue}”.",
        (RepairKind.CancelStuckJobs or RepairKind.RestartStuckJobs, _) => "Some jobs couldn't be changed. They may have just finished.",
        _ => "Windows couldn't do it.",
    };

    /// <summary>
    /// The name for a Standard TCP/IP port to <paramref name="host"/>: Windows' own convention ("IP_192.0.2.23" for an
    /// address, the name itself for a host name), with a number added when a port of that name points somewhere else.
    /// </summary>
    internal static string PortNameFor(string host, int portNumber)
    {
        var baseName = IPAddress.TryParse(host, out _) ? $"IP_{host}" : host;
        var ports = Winspool.Ports().ToDictionary(p => p.Name, StringComparer.OrdinalIgnoreCase);
        for (var i = 0; ; i++)
        {
            var name = i == 0 ? baseName : $"{baseName}_{i}";
            if (!ports.TryGetValue(name, out var existing)) return name;
            var port = WindowsOfflineProbes.Port(name, existing);
            if (port.Kind == PortKind.TcpIp && !port.Lpr && port.PortNumber == portNumber
                && string.Equals(port.Host, host, StringComparison.OrdinalIgnoreCase)) return name;
        }
    }

    private static string TemporaryName(string queue) => IppQueueInstaller.SafeQueueName($"{queue} (new address)");
}
