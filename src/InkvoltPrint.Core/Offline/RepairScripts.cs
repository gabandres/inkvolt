namespace InkvoltPrint.Core.Offline;

/// <summary>A constant PowerShell script and the values it reads as <c>$v0</c>, <c>$v1</c>… (passed Base64-encoded, never as script text).</summary>
public sealed record RepairScript(string Script, IReadOnlyList<string> Values);

/// <summary>
/// The elevated scripts behind the offline fixer's administrator repairs (run by InkvoltPrint.Windows' <c>Elevated</c>).
/// Every queue, port and job is found by exact name: the <c>-Name</c> parameters of Get-, Set-, Remove- and
/// Rename-Printer and Get-PrinterPort, and <c>-PrinterName</c> of the print-job cmdlets, take wildcards, so a queue
/// called "Office*" would match every Office… queue and "HP [2F]" none. Scripts select with
/// <c>Where-Object { $_.Name -eq $v0 }</c> and pipe the one object on; only Add-Printer and Add-PrinterPort take a
/// name, and they create exactly that name. Exit codes: 0 done, 1 failed, 4 no such queue; re-adding an IPP queue
/// also uses 2 (added, old one not removed) and 3 (not renamed).
/// </summary>
public static class RepairScripts
{
    public const int Done = 0, Failed = 1, NotRemoved = 2, NotRenamed = 3, NoSuchQueue = 4;

    /// <summary>The queue named exactly <c>$v0</c> as <c>$q</c>, else exit 4.</summary>
    private const string Queue =
        "$q = Get-Printer | Where-Object { $_.Name -eq $v0 } | Select-Object -First 1; if (-not $q) { exit 4 };";

    /// <summary>The same queue as a WMI <c>Win32_Printer</c> (Resume, WorkOffline), as <c>$p</c>.</summary>
    private const string WmiQueue =
        "$p = Get-CimInstance -ClassName Win32_Printer | Where-Object { $_.Name -eq $v0 } | Select-Object -First 1; if (-not $p) { exit 4 };";

    /// <param name="portName">For <see cref="RepairKind.PointPortAt"/>: the Standard TCP/IP port to create or reuse.</param>
    /// <param name="temporaryName">For <see cref="RepairKind.RecreateIppQueue"/>: the name the new queue has until the old one is gone.</param>
    /// <param name="httpUrl">For <see cref="RepairKind.RecreateIppQueue"/>: the http(s) URL <c>Add-Printer -IppURL</c> takes.</param>
    /// <returns>Null when the repair has no script (manual-only, or done as the user).</returns>
    public static RepairScript? For(Repair repair, string? portName = null, string? temporaryName = null, Uri? httpUrl = null)
    {
        var queue = repair.Queue ?? "";
        switch (repair.Kind)
        {
            case RepairKind.StartSpooler or RepairKind.RestartSpooler:
                return new("try { $s = Get-Service | Where-Object { $_.Name -eq $v0 } | Select-Object -First 1; " +
                           "if ($s.Status -eq 'Running') { $s | Restart-Service -Force } else { $s | Start-Service }; exit 0 } catch { exit 1 }",
                    ["Spooler"]);
            case RepairKind.ResumeQueue:
                return new("try { " + WmiQueue + " $r = Invoke-CimMethod -InputObject $p -MethodName Resume; if ($r.ReturnValue -ne 0) { exit 1 }; exit 0 } catch { exit 1 }",
                    [queue]);
            case RepairKind.ClearWorkOffline:
                return new("try { " + WmiQueue + " Set-CimInstance -InputObject $p -Property @{ WorkOffline = $false }; exit 0 } catch { exit 1 }",
                    [queue]);
            case RepairKind.CancelStuckJobs or RepairKind.RestartStuckJobs:
                // $v1: comma-separated job ids, each cast to [int] before use.
                var verb = repair.Kind == RepairKind.CancelStuckJobs ? "Remove-PrintJob" : "Restart-PrintJob";
                return new("try { " + Queue + " } catch { exit 1 }; $rc = 0; " +
                           "foreach ($id in ($v1 -split ',' | ForEach-Object { [int]$_ })) { try { Get-PrintJob -PrinterObject $q -ID $id | " + verb +
                           " } catch { $rc = 1 } }; exit $rc",
                    [queue, string.Join(",", repair.JobIds)]);
            case RepairKind.PointPortAt when repair.Target is { } target && portName is not null:
                return new("try { " + Queue + " if (-not (Get-PrinterPort | Where-Object { $_.Name -eq $v1 })) { " +
                           "Add-PrinterPort -Name $v1 -PrinterHostAddress $v2 -PortNumber ([uint32]$v3) }; $q | Set-Printer -PortName $v1; exit 0 } catch { exit 1 }",
                    [queue, portName, target, repair.PortNumber.ToString(System.Globalization.CultureInfo.InvariantCulture)]);
            case RepairKind.RecreateIppQueue when temporaryName is not null && httpUrl is not null:
                // Add first: if Windows can't add it at the new address, the old queue stays exactly as it was. A queue left
                // under the temporary name by an earlier attempt (one that ran on after Inkvolt Print stopped waiting) is
                // reused, never added twice.
                return new("try { " + Queue + " } catch { exit 1 }; " +
                           "try { if (-not (Get-Printer | Where-Object { $_.Name -eq $v1 })) { Add-Printer -Name $v1 -IppURL $v2 } } catch { exit 1 }; " +
                           "try { $q | Remove-Printer } catch { exit 2 }; " +
                           "try { Get-Printer | Where-Object { $_.Name -eq $v1 } | Select-Object -First 1 | Rename-Printer -NewName $v0 } catch { exit 3 }; exit 0",
                    [queue, temporaryName, httpUrl.AbsoluteUri]);
            default:
                return null;
        }
    }
}
