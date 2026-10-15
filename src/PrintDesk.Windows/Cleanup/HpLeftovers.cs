using System.ComponentModel;
using System.Diagnostics;
using Microsoft.Win32;
using System.Text;
using PrintDesk.Windows.Printing;

namespace PrintDesk.Windows.Cleanup;

/// <summary>
/// Pieces HP's Print Support App installs outside its Store package, with no uninstaller, that keep running after
/// the app is removed: two auto-start services in C:\Program Files\HPPSAService (an RPC server and the
/// "Print On The Go" local IPP server) and the virtual "HP Smart Printing" queue that points at that server.
/// Removing them needs administrator rights, so it runs as one elevated PowerShell script (one UAC prompt).
/// The same script turns off Windows' "automatically download manufacturers' apps", which otherwise re-installs
/// HP's print app from the Store the next time the printer is set up.
/// </summary>
public static class HpLeftovers
{
    private static readonly string[] Services = ["HPPSASmartPrinting", "HPPSAService"];
    private const string Folder = @"C:\Program Files\HPPSAService";
    private const string Queue = "HP Smart Printing";

    public sealed record Found(IReadOnlyList<string> Services, bool Queue, bool Folder)
    {
        public bool Any => Services.Count > 0 || Queue || Folder;

        public override string ToString() => string.Join(", ", new[]
        {
            Services.Count > 0 ? $"{Services.Count} background service{(Services.Count == 1 ? "" : "s")}" : null,
            Queue ? "the \"HP Smart Printing\" printer" : null,
            Folder && Services.Count == 0 ? "leftover files" : null,
        }.Where(s => s is not null));
    }

    public static async Task<Found> FindAsync()
    {
        // Readable without admin rights, unlike querying the service manager for config.
        var services = Services.Where(n =>
        {
            using var key = Registry.LocalMachine.OpenSubKey($@"SYSTEM\CurrentControlSet\Services\{n}");
            return key is not null;
        }).ToList();
        var queue = (await QueueFinder.ListAsync()).Any(q => string.Equals(q.Name, Queue, StringComparison.OrdinalIgnoreCase));
        return new Found(services, queue, Directory.Exists(Folder));
    }

    /// <summary>Returns null on success, otherwise what went wrong.</summary>
    private const string MetadataKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata";

    /// <summary>Windows won't fetch manufacturers' apps (HP's Print Support App) for newly set-up devices.</summary>
    public static bool ManufacturerAppsBlocked()
    {
        using var key = Registry.LocalMachine.OpenSubKey(MetadataKey);
        return key?.GetValue("PreventDeviceMetadataFromNetwork") is int v && v == 1;
    }

    public static async Task<string?> RemoveAsync(CancellationToken ct = default)
    {
        var log = Path.Combine(Path.GetTempPath(), $"printdesk-hpcleanup-{Guid.NewGuid():N}.txt");
        var script = new StringBuilder("$ErrorActionPreference='Continue'; $out=@();");
        script.Append($"try {{ New-Item -Path 'HKLM:\\{MetadataKey}' -Force | Out-Null; " +
                      $"Set-ItemProperty -Path 'HKLM:\\{MetadataKey}' -Name PreventDeviceMetadataFromNetwork -Type DWord -Value 1 -EA Stop }} " +
                      "catch { $out += 'auto-install setting: ' + $_.Exception.Message };");
        foreach (var s in Services)
            script.Append($"if (Get-Service '{s}' -EA SilentlyContinue) {{ Stop-Service '{s}' -Force -EA SilentlyContinue; " +
                          $"sc.exe delete '{s}' | Out-Null; if ($LASTEXITCODE -ne 0) {{ $out += 'service {s}: sc delete failed' }} }};");
        script.Append($"if (Get-Printer -Name '{Queue}' -EA SilentlyContinue) {{ try {{ Remove-Printer -Name '{Queue}' -EA Stop }} catch {{ $out += 'queue: ' + $_.Exception.Message }} }};");
        // Services take a moment to release their executables after stopping.
        script.Append($"Start-Sleep 2; if (Test-Path '{Folder}') {{ try {{ Remove-Item '{Folder}' -Recurse -Force -EA Stop }} catch {{ $out += 'files: ' + $_.Exception.Message }} }};");
        script.Append($"$out -join \"`n\" | Out-File -Encoding utf8 '{log}'");

        var psi = new ProcessStartInfo("powershell.exe",
            $"-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {Convert.ToBase64String(Encoding.Unicode.GetBytes(script.ToString()))}")
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        try
        {
            using var p = Process.Start(psi) ?? throw new InvalidOperationException("PowerShell did not start");
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromMinutes(2));
            await p.WaitForExitAsync(cts.Token);
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223)
        {
            return "Cancelled: Windows needs administrator permission to remove HP's background services.";
        }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested)
        {
            return "Windows did not finish removing HP's services in time.";
        }

        string? problems = null;
        if (File.Exists(log))
        {
            problems = (await File.ReadAllTextAsync(log, ct)).Trim();
            File.Delete(log);
        }
        var still = await FindAsync();
        if (still.Any) return $"Some HP components are still present ({still}).{(string.IsNullOrEmpty(problems) ? "" : " " + problems)}";
        return string.IsNullOrEmpty(problems) ? null : problems;
    }
}
