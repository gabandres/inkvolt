using System.ComponentModel;
using System.Diagnostics;
using System.Text;
using PrintDesk.Windows.Printing;

namespace PrintDesk.Windows.Queues;

/// <summary>
/// For printers Windows can't discover (other subnet, VPN, mDNS blocked): creates an IPP Class Driver queue
/// straight from the printer's IPP URL. Windows only allows this for administrators, so it runs one elevated
/// PowerShell command (a single UAC prompt). No driver download; same driver Windows picks for discovered printers.
/// </summary>
public static class IppQueueInstaller
{
    public static async Task<InstallResult> InstallAsync(string queueName, Uri ippUrl, CancellationToken ct = default)
    {
        if (ippUrl.Scheme is not ("http" or "https" or "ipp" or "ipps")) throw new ArgumentException("Not an IPP URL", nameof(ippUrl));
        var url = ippUrl.Scheme switch { "ipp" => new UriBuilder(ippUrl) { Scheme = "http" }.Uri, "ipps" => new UriBuilder(ippUrl) { Scheme = "https" }.Uri, _ => ippUrl };

        // Arguments go through -EncodedCommand with single-quoted literals: no injection via names or URLs.
        var errorFile = Path.Combine(Path.GetTempPath(), $"printdesk-addprinter-{Guid.NewGuid():N}.txt");
        var script = $"$ErrorActionPreference='Stop'; try {{ Add-Printer -Name {Quote(queueName)} -IppURL {Quote(url.AbsoluteUri)} }} " +
                     $"catch {{ $_.Exception.Message | Out-File -Encoding utf8 {Quote(errorFile)}; exit 1 }}";
        var psi = new ProcessStartInfo("powershell.exe",
            $"-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {Convert.ToBase64String(Encoding.Unicode.GetBytes(script))}")
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        Process process;
        try
        {
            process = Process.Start(psi) ?? throw new InvalidOperationException("PowerShell did not start");
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223) // ERROR_CANCELLED: UAC declined
        {
            return new(InstallOutcome.Failed, "Setup was cancelled. Windows needs administrator permission to add a printer by address.");
        }
        using (process)
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(TimeSpan.FromMinutes(2));
            try
            {
                await process.WaitForExitAsync(cts.Token);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                return new(InstallOutcome.Failed, "Windows did not finish adding the printer in time.");
            }
        }

        string? error = null;
        if (File.Exists(errorFile))
        {
            error = (await File.ReadAllTextAsync(errorFile, ct)).Trim();
            File.Delete(errorFile);
        }
        if (error?.Contains("already exists", StringComparison.OrdinalIgnoreCase) == true)
            return new(InstallOutcome.AlreadyInstalled, "Already installed in Windows.");
        // The exit code of an elevated process isn't reliable to read; check the result instead.
        var queues = await QueueFinder.ListAsync();
        return queues.Any(q => string.Equals(q.Name, queueName, StringComparison.OrdinalIgnoreCase))
            ? new(InstallOutcome.Installed, "Installed.")
            : new(InstallOutcome.Failed, $"Windows could not add the printer at that address{(error is { Length: > 0 } ? $": {error}" : ".")}");
    }

    private static string Quote(string s) => "'" + s.Replace("'", "''") + "'";
}
