using Microsoft.Win32;
using System.Text;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.Windows.Cleanup;

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

    private const string MetadataKey = @"SOFTWARE\Microsoft\Windows\CurrentVersion\Device Metadata";

    /// <summary>Windows won't fetch manufacturers' apps (HP's Print Support App) for newly set-up devices.</summary>
    public static bool ManufacturerAppsBlocked()
    {
        using var key = Registry.LocalMachine.OpenSubKey(MetadataKey);
        return key?.GetValue("PreventDeviceMetadataFromNetwork") is int v && v == 1;
    }

    // Exit-code bits from the elevated script (no temp files shared with the user's session).
    private const int FailSetting = 2, FailService = 4, FailQueue = 8, FailFiles = 16, SkippedLinkedFolder = 32;

    /// <summary>Returns null on success, otherwise what went wrong.</summary>
    public static async Task<string?> RemoveAsync(CancellationToken ct = default)
    {
        // Every name/path is a constant here; still passed as $v0.. so the script text never embeds a value.
        var script = new StringBuilder("$ErrorActionPreference='Continue'; $rc=0;");
        // Setting only: never recreate the key (New-Item -Force on an existing registry key wipes its values).
        script.Append("try { if (-not (Test-Path $v0)) { New-Item -Path $v0 | Out-Null }; " +
                      "Set-ItemProperty -Path $v0 -Name PreventDeviceMetadataFromNetwork -Type DWord -Value 1 -EA Stop } catch { $rc = $rc -bor 2 };");
        script.Append("foreach ($s in @($v1, $v2)) { if (Get-Service -Name $s -EA SilentlyContinue) { Stop-Service -Name $s -Force -EA SilentlyContinue; " +
                      "& sc.exe delete $s | Out-Null; if ($LASTEXITCODE -ne 0) { $rc = $rc -bor 4 } } };");
        script.Append("if (Get-Printer -Name $v3 -EA SilentlyContinue) { try { Remove-Printer -Name $v3 -EA Stop } catch { $rc = $rc -bor 8 } };");
        // Services take a moment to release their executables. The folder itself must be a real folder; inside it,
        // cmd's rmdir /s removes junctions and symlinks as links and never follows them (PowerShell 5.1's
        // Remove-Item -Recurse can), so nothing outside the folder can be reached, even if a link appears mid-delete.
        script.Append("Start-Sleep 2; if (Test-Path -LiteralPath $v4) { " +
                      "if ((Get-Item -LiteralPath $v4 -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { $rc = $rc -bor 32 } " +
                      "else { & cmd.exe /d /c rmdir /s /q $v4 2>$null; if (Test-Path -LiteralPath $v4) { $rc = $rc -bor 16 } } };");
        script.Append("exit $rc");

        // Anything unexpected (parse error, unhandled throw) exits 64, so it can't be mistaken for one of the bits.
        var wrapped = "try { " + script + " } catch { exit 64 }";
        var code = await Elevated.RunAsync(wrapped,
            [$@"HKLM:\{MetadataKey}", Services[0], Services[1], Queue, Folder], TimeSpan.FromMinutes(2), ct);
        if (code == Elevated.Cancelled) return "Cancelled: Windows needs administrator permission to remove HP's background services.";
        if (code == Elevated.TimedOut) return "Windows did not finish removing HP's services in time.";

        if (code is 64 or 1) return "Windows couldn't run the clean-up. Nothing may have been removed; try again.";
        var problems = new List<string>();
        if ((code & FailSetting) != 0) problems.Add("couldn't stop Windows from re-installing HP's print app");
        if ((code & FailService) != 0) problems.Add("a service couldn't be removed");
        if ((code & FailQueue) != 0) problems.Add("the \"HP Smart Printing\" printer couldn't be removed");
        if ((code & FailFiles) != 0) problems.Add("some files couldn't be deleted");
        if ((code & SkippedLinkedFolder) != 0) problems.Add($"{Folder} is a link, so it was left in place");
        var still = await FindAsync();
        if (still.Any) problems.Insert(0, $"still present: {still}");
        return problems.Count == 0 ? null : char.ToUpperInvariant(problems[0][0]) + string.Join("; ", problems)[1..] + ".";
    }
}
