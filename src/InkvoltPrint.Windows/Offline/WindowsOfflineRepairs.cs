using System.ComponentModel;
using System.Net;
using InkvoltPrint.Core.Offline;
using InkvoltPrint.Windows.Queues;

namespace InkvoltPrint.Windows.Offline;

/// <summary>
/// Carries out the offline fixer's repairs on this PC. As the user: resume a queue, turn off "Use Printer Offline",
/// cancel or restart jobs (winspool, no prompt; Windows decides who may). Elevated (one UAC prompt each, unpackaged
/// copies only, see <see cref="RepairRunner"/>): the same through PowerShell/CIM, starting or restarting the Print
/// Spooler, pointing a queue at a new Standard TCP/IP port, and re-adding a queue at a new IPP URL. Every script is a
/// constant; queue names, addresses and job ids reach it only as Base64 values (<see cref="Elevated"/>), never as
/// script text. Setting a discovered queue up again (pairing) is done by the app, not here.
/// </summary>
public sealed class WindowsOfflineRepairs : IOfflineRepairs
{
    private static readonly TimeSpan ScriptTimeout = TimeSpan.FromMinutes(2);

    public Task<Attempt> AsUserAsync(Repair repair, CancellationToken ct) => Task.Run(() =>
    {
        var queue = repair.Queue ?? "";
        var error = repair.Kind switch
        {
            RepairKind.ResumeQueue => Winspool.Resume(queue),
            RepairKind.ClearWorkOffline => Winspool.ClearWorkOffline(queue),
            RepairKind.CancelStuckJobs => Winspool.ControlJobs(queue, repair.JobIds, restart: false),
            RepairKind.RestartStuckJobs => Winspool.ControlJobs(queue, repair.JobIds, restart: true),
            _ => Winspool.ErrorAccessDenied, // services and ports: never as a standard user
        };
        return error switch
        {
            0 => Attempt.Done,
            Winspool.ErrorAccessDenied => Attempt.Denied,
            _ => new Attempt(AttemptResult.Failed, $"Windows said: {new Win32Exception(error).Message}"),
        };
    }, ct);

    private const string FindPrinter =
        "$p = Get-CimInstance -ClassName Win32_Printer | Where-Object { $_.Name -eq $v0 } | Select-Object -First 1; if (-not $p) { exit 2 };";

    public async Task<Attempt> ElevatedAsync(Repair repair, CancellationToken ct)
    {
        string script;
        IReadOnlyList<string> values;
        switch (repair.Kind)
        {
            case RepairKind.StartSpooler or RepairKind.RestartSpooler:
                script = "try { $s = Get-Service -Name $v0; if ($s.Status -eq 'Running') { Restart-Service -Name $v0 -Force } " +
                         "else { Start-Service -Name $v0 }; exit 0 } catch { exit 1 }";
                values = ["Spooler"];
                break;
            case RepairKind.ResumeQueue:
                script = "try { " + FindPrinter + " $r = Invoke-CimMethod -InputObject $p -MethodName Resume; if ($r.ReturnValue -ne 0) { exit 1 }; exit 0 } catch { exit 1 }";
                values = [repair.Queue ?? ""];
                break;
            case RepairKind.ClearWorkOffline:
                script = "try { " + FindPrinter + " Set-CimInstance -InputObject $p -Property @{ WorkOffline = $false }; exit 0 } catch { exit 1 }";
                values = [repair.Queue ?? ""];
                break;
            case RepairKind.CancelStuckJobs or RepairKind.RestartStuckJobs:
                // $v1 is a comma-separated list of job ids, each cast to [int] before use.
                script = "$rc = 0; foreach ($id in ($v1 -split ',' | ForEach-Object { [int]$_ })) { try { " +
                         (repair.Kind == RepairKind.CancelStuckJobs ? "Remove-PrintJob" : "Restart-PrintJob") +
                         " -PrinterName $v0 -ID $id } catch { $rc = 1 } }; exit $rc";
                values = [repair.Queue ?? "", string.Join(",", repair.JobIds)];
                break;
            case RepairKind.PointPortAt when repair.Target is { } target:
                var port = PortNameFor(target, repair.PortNumber);
                script = "try { if (-not (Get-PrinterPort -Name $v1 -ErrorAction SilentlyContinue)) { " +
                         "Add-PrinterPort -Name $v1 -PrinterHostAddress $v2 -PortNumber ([uint32]$v3) }; Set-Printer -Name $v0 -PortName $v1; exit 0 } catch { exit 1 }";
                values = [repair.Queue ?? "", port, target, repair.PortNumber.ToString(System.Globalization.CultureInfo.InvariantCulture)];
                break;
            case RepairKind.RecreateIppQueue when repair.TargetUrl is { } url:
                // Add first: if Windows can't add it at the new address, the old queue is left exactly as it was.
                script = "try { Add-Printer -Name $v1 -IppURL $v2 } catch { exit 1 }; try { Remove-Printer -Name $v0 } catch { exit 2 }; " +
                         "try { Rename-Printer -Name $v1 -NewName $v0 } catch { exit 3 }; exit 0";
                values = [repair.Queue ?? "", TemporaryName(repair.Queue ?? "Printer"), IppQueueInstaller.HttpForm(url).AbsoluteUri];
                break;
            default:
                return new Attempt(AttemptResult.Failed, "Inkvolt Print can't do this one itself.");
        }

        var code = await Elevated.RunAsync(script, values, ScriptTimeout, ct).ConfigureAwait(false);
        return code switch
        {
            Elevated.Cancelled => new Attempt(AttemptResult.Cancelled),
            Elevated.TimedOut => new Attempt(AttemptResult.Failed, "Windows didn't finish in time."),
            0 => Attempt.Done,
            _ => new Attempt(AttemptResult.Failed, Explain(repair, code, values)),
        };
    }

    private static string Explain(Repair repair, int code, IReadOnlyList<string> values) => (repair.Kind, code) switch
    {
        (_, 2) when repair.Kind is RepairKind.ResumeQueue or RepairKind.ClearWorkOffline => $"Windows no longer has a printer called “{repair.Queue}”.",
        (RepairKind.RecreateIppQueue, 1) => $"Windows couldn't add the printer at {values[2]}. “{repair.Queue}” is unchanged.",
        (RepairKind.RecreateIppQueue, 2) => $"The printer was added as “{values[1]}”, but the old “{repair.Queue}” couldn't be removed. Remove it in Settings.",
        (RepairKind.RecreateIppQueue, 3) => $"The printer was added as “{values[1]}” and the old one removed, but it couldn't be renamed to “{repair.Queue}”.",
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
