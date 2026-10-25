using System.ComponentModel;
using System.Diagnostics;
using System.Text;

namespace InkvoltPrint.Windows;

/// <summary>
/// Runs a fixed PowerShell script elevated (one UAC prompt). Values never appear inside the script text: each is
/// passed as Base64 and decoded into a variable, so no printer-supplied string (names can contain any quote
/// character PowerShell recognises) can change what the script does. Results come back as the exit code, so no
/// temp file is shared between the elevated process and the user's session.
/// The wait for the UAC prompt can be cancelled (<see cref="StoppedWaiting"/>): the script first checks that this process
/// still holds a named event made for the run, so a prompt answered "Yes" after the user stopped waiting changes nothing.
/// </summary>
public static class Elevated
{
    public const int Cancelled = -1223;
    public const int TimedOut = -1;

    /// <summary>The caller cancelled while the UAC prompt was still unanswered: nothing ran, and a late "Yes" does nothing.</summary>
    public const int StoppedWaiting = -2;

    private static readonly string PowerShellPath = Path.Combine(Environment.SystemDirectory, "WindowsPowerShell", "v1.0", "powershell.exe");

    /// <param name="script">Script body. Reads its inputs from <c>$v0</c>, <c>$v1</c>… and must <c>exit</c> with a code.</param>
    /// <param name="ct">
    /// Cancels the wait: before the prompt is answered, <see cref="StoppedWaiting"/>; after, <see cref="TimedOut"/> (the elevated
    /// process can't be stopped from here and may still finish: callers look again).
    /// </param>
    public static async Task<int> RunAsync(string script, IReadOnlyList<string> values, TimeSpan timeout, CancellationToken ct = default)
    {
        // The gate: a named event only this run knows (a GUID, safe in quotes). Gone (this process stopped waiting and closed
        // it) means "don't run". Any other answer, including access denied when another administrator account approved the
        // prompt, lets the script go on.
        var gateName = $@"Local\InkvoltElevated-{Guid.NewGuid():N}";
        using var gate = new EventWaitHandle(false, EventResetMode.ManualReset, gateName);
        var prologue = new StringBuilder(
            $"$g=$null;try{{if(-not [Threading.EventWaitHandle]::TryOpenExisting('{gateName}',[ref]$g)){{exit 1223}};$g.Dispose()}}catch{{}};");
        prologue.Append("$ErrorActionPreference='Stop';");
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
            var start = Task.Run(() => Process.Start(psi), CancellationToken.None);
            try
            {
                await start.WaitAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                gate.Dispose(); // closes the gate before a late "Yes" can start the script
                _ = start.ContinueWith(t =>
                {
                    if (t.IsCompletedSuccessfully) t.Result?.Dispose();
                    else _ = t.Exception; // declined later: observed, nothing to do
                }, TaskScheduler.Default);
                return StoppedWaiting;
            }
            using var p = await start.ConfigureAwait(false) ?? throw new InvalidOperationException("PowerShell did not start");
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            try
            {
                await p.WaitForExitAsync(cts.Token);
            }
            catch (OperationCanceledException)
            {
                // Timed out, or the caller stopped waiting. The elevated process can't be stopped from this unelevated one; it
                // may still finish. Callers must treat the result as unknown and look again, not as a failure.
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
