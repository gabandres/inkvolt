using InkvoltPrint.Core.Model;

namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// SNMP access…'s check of a login before it's kept (roadmap 3.2): the printer at its address asked with it, as a probe asks.
/// What the dialog says comes from it (<see cref="SnmpLoginSave"/>): kept once answered; a refusal names the part the agent
/// refused (as Add a printer's <see cref="InkvoltPrint.Core.Probe.ProbeResult.SnmpRefused"/> does) and keeps nothing; no answer may be a printer
/// that's off or an agent ignoring a wrong community (v1 and v2c agents say nothing), so the user may keep it anyway.
/// </summary>
public abstract record SnmpLoginCheck
{
    private SnmpLoginCheck() { }

    /// <summary>The printer answered with it, as itself.</summary>
    public sealed record Answered : SnmpLoginCheck;

    /// <summary>The SNMPv3 agent refused the user or one of its keys.</summary>
    public sealed record Refused(SnmpRefusal Reason) : SnmpLoginCheck;

    /// <summary>Nothing answered with it.</summary>
    public sealed record NoAnswer : SnmpLoginCheck;

    /// <summary>A device answered with it that isn't this printer (another serial number, model or name than the known one's).</summary>
    public sealed record AnotherDevice : SnmpLoginCheck;

    /// <summary>
    /// Asks the printer at <paramref name="host"/> over <paramref name="transport"/> with <paramref name="login"/>;
    /// <paramref name="known"/> is what it said about itself when it was added. A transport that fails in a way the probe doesn't
    /// know is no answer; only cancellation propagates.
    /// </summary>
    public static async Task<SnmpLoginCheck> CheckAsync(SnmpLogin login, string host, SnmpDevice? known, ISnmpTransport transport,
        CancellationToken ct = default)
    {
        var gate = new object();
        SnmpRefusal? refused = null;
        SnmpPrinterClient? found;
        try
        {
            found = await SnmpPrinterClient.ProbeAsync(transport, host, login, ct, r => { lock (gate) refused ??= r; }).ConfigureAwait(false);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !ct.IsCancellationRequested)
        {
            found = null;
        }
        if (found is null)
        {
            lock (gate) return refused is { } why ? new Refused(why) : new NoAnswer();
        }
        return known?.Identify(found.Identity) == DeviceIdentity.Different ? new AnotherDevice() : new Answered();
    }
}

/// <summary>
/// SNMP access…'s Save: the login kept now is kept again without asking; any other is asked first (<see cref="SnmpLoginCheck"/>)
/// and kept only once the printer answers with it as itself. A refusal says which part and keeps nothing; another device keeps
/// nothing; no answer says what may be wrong, and Save again with the same login (Save anyway) keeps it as it is.
/// </summary>
/// <param name="current">The login kept now (public when none).</param>
/// <param name="check">Asks the printer with a login (the app: <see cref="SnmpLoginCheck.CheckAsync"/> at its address).</param>
public sealed class SnmpLoginSave(SnmpLogin current, Func<SnmpLogin, CancellationToken, Task<SnmpLoginCheck>> check)
{
    private SnmpLogin? _unanswered;

    /// <summary>The login typed is the one that got no answer: Save keeps it as it is, and its button says Save anyway.</summary>
    public bool IsSaveAnyway(SnmpLogin? typed) => typed is not null && typed == _unanswered;

    /// <summary>The fields were edited: Save asks the printer again, even when the same login is typed back.</summary>
    public void Edited() => _unanswered = null;

    /// <summary>What Save with <paramref name="login"/> came to: keep it, or the problem to show (nothing kept).</summary>
    public async Task<(bool Keep, string? Problem)> SaveAsync(SnmpLogin login, CancellationToken ct = default)
    {
        if (login == current || login == _unanswered) return (true, null);
        _unanswered = null;
        switch (await check(login, ct).ConfigureAwait(false))
        {
            case SnmpLoginCheck.Answered:
                return (true, null);
            case SnmpLoginCheck.Refused refused:
                return (false, string.Format(CoreStrings.SnmpCheck_Refused, new SnmpAccessException(refused.Reason).Message));
            case SnmpLoginCheck.AnotherDevice:
                return (false, CoreStrings.SnmpCheck_AnotherDevice);
            default:
                _unanswered = login;
                return (false, login.User is not null ? CoreStrings.SnmpCheck_NoAnswerUser : CoreStrings.SnmpCheck_NoAnswerCommunity);
        }
    }
}
