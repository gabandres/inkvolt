using System.Text.RegularExpressions;
using InkvoltPrint.Core;
using InkvoltPrint.Windows.Printing;

namespace InkvoltPrint.Windows.Queues;

/// <summary>
/// For printers Windows can't discover (other subnet, VPN, mDNS blocked): creates an IPP Class Driver queue
/// straight from the printer's IPP URL. Windows only allows this for administrators, so it runs one elevated
/// PowerShell command (a single UAC prompt). No driver download; same driver Windows picks for discovered printers.
/// </summary>
public static partial class IppQueueInstaller
{
    private const int ExitOk = 0, ExitFailed = 1;

    public static async Task<InstallResult> InstallAsync(string queueName, Uri ippUrl, CancellationToken ct = default)
    {
        if (ippUrl.Scheme is not ("http" or "https" or "ipp" or "ipps")) throw new ArgumentException("Not an IPP URL", nameof(ippUrl));
        var url = HttpForm(ippUrl);
        var name = SafeQueueName(queueName);

        // Decide "already there" by looking, not by parsing (localised) PowerShell error text, and before elevating.
        if ((await QueueFinder.ListAsync()).Any(q => string.Equals(q.Name, name, StringComparison.OrdinalIgnoreCase)))
            return new(InstallOutcome.AlreadyInstalled, CoreStrings.Win_AlreadyInstalled);

        const string script = "try { Add-Printer -Name $v0 -IppURL $v1; exit 0 } catch { exit 1 }";
        var code = await Elevated.RunAsync(script, [name, url.AbsoluteUri], TimeSpan.FromMinutes(2), ct);

        switch (code)
        {
            case Elevated.Cancelled or Elevated.StoppedWaiting:
                return new(InstallOutcome.Failed, CoreStrings.Win_SetupCancelled);
            case Elevated.TimedOut:
                return new(InstallOutcome.Failed, CoreStrings.Win_AddTimedOut);
        }
        // Trust the outcome, not just the exit code.
        var queues = await QueueFinder.ListAsync();
        if (code == ExitOk && queues.Any(q => string.Equals(q.Name, name, StringComparison.OrdinalIgnoreCase)))
            return new(InstallOutcome.Installed, CoreStrings.Win_Installed);
        return new(InstallOutcome.Failed, code is ExitFailed or ExitOk
            ? CoreStrings.Win_AddFailedAddress
            : string.Format(CoreStrings.Win_AddFailedCode, code));
    }

    /// <summary>The http(s) form Windows' <c>Add-Printer -IppURL</c> takes: ipp → http, ipps → https, on 631 unless another port is given.</summary>
    public static Uri HttpForm(Uri ippUrl) => ippUrl.Scheme switch
    {
        "ipp" => new UriBuilder(ippUrl) { Scheme = "http", Port = ippUrl.IsDefaultPort || ippUrl.Port < 0 ? 631 : ippUrl.Port }.Uri,
        "ipps" => new UriBuilder(ippUrl) { Scheme = "https", Port = ippUrl.IsDefaultPort || ippUrl.Port < 0 ? 631 : ippUrl.Port }.Uri, // RFC 7472
        _ => ippUrl,
    };

    /// <summary>Queue names come partly from what the printer reports: keep letters, digits and simple punctuation.</summary>
    public static string SafeQueueName(string name)
    {
        var cleaned = Spaces().Replace(Unsafe().Replace(name, " "), " ").Trim();
        if (cleaned.Length == 0) cleaned = "Network printer";
        return cleaned.Length > 60 ? cleaned[..60].TrimEnd() : cleaned;
    }

    [GeneratedRegex(@"[^\w .()\-]")]
    private static partial Regex Unsafe();

    [GeneratedRegex(@"\s{2,}")]
    private static partial Regex Spaces();
}
