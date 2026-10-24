using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace InkvoltPrint.Windows;

/// <summary>
/// Runs a fixed PowerShell script elevated (one UAC prompt). Values never appear inside the script text: each is
/// passed as Base64 and decoded into a variable, so no printer-supplied string (names can contain any quote
/// character PowerShell recognises) can change what the script does. Results come back as the exit code, so no
/// temp file is shared between the elevated process and the user's session.
/// </summary>
public static class Elevated
{
    public const int Cancelled = -1223;
    public const int TimedOut = -1;

    private static readonly string PowerShellPath = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");

    /// <param name="script">Script body. Reads its inputs from <c>$v0</c>, <c>$v1</c>… and must <c>exit</c> with a code.</param>
    public static async Task<int> RunAsync(string script, IReadOnlyList<string> values, TimeSpan timeout, CancellationToken ct = default)
    {
        var prologue = new StringBuilder("$ErrorActionPreference='Stop';");
        for (var i = 0; i < values.Count; i++)
        {
            var b64 = Convert.ToBase64String(Encoding.UTF8.GetBytes(values[i])); // [A-Za-z0-9+/=] only: safe in quotes
            prologue.Append($"$v{i}=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{b64}'));");
        }
        var full = prologue + script;
        // By full path: never whichever powershell.exe the search path or the current directory offers.
        var psi = new ProcessStartInfo(PowerShellPath,
            $"-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand {Convert.ToBase64String(Encoding.Unicode.GetBytes(full))}")
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        try
        {
            // Process.Start returns only once the UAC prompt is answered: never block the caller's (UI) thread on it.
            using var p = await Task.Run(() => Process.Start(psi), CancellationToken.None).ConfigureAwait(false)
                          ?? throw new InvalidOperationException("PowerShell did not start");
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            try
            {
                await p.WaitForExitAsync(cts.Token);
            }
            catch (OperationCanceledException) when (!ct.IsCancellationRequested)
            {
                // The elevated process can't be stopped from this unelevated one; it may still finish. Callers must treat
                // the result as unknown and look again, not as a failure.
                return TimedOut;
            }
            return p.ExitCode;
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223) // UAC declined
        {
            return Cancelled;
        }
    }
}
