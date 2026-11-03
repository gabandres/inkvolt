namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// How Inkvolt Print signs in to one printer's SNMP agent: a read community (v1, v2c). A secret: kept by an
/// <see cref="ISnmpLogins"/> (Windows Credential Manager), never in <c>state.json</c>, a recording or the log;
/// <see cref="ToString"/> names no secret. A printer with nothing kept is asked with <see cref="Public"/>.
/// </summary>
public sealed record SnmpLogin
{
    /// <summary>The longest community taken (RFC 3417's OCTET STRING has no limit; net-snmp's agents stop at 255).</summary>
    public const int MaxCommunity = 255;

    private SnmpLogin(string community) => Community = community;

    /// <summary>"public", the read community nearly every printer ships with.</summary>
    public static SnmpLogin Public { get; } = new(SnmpClient.DefaultCommunity);

    public string Community { get; }

    /// <summary>Nothing to keep: the community every printer is asked with anyway.</summary>
    public bool IsDefault => Community == SnmpClient.DefaultCommunity;

    /// <summary>
    /// A community as typed: blank is <see cref="Public"/>; otherwise as it is (spaces count: an agent compares bytes). Null with
    /// <paramref name="error"/> for one that can't be sent (control characters, longer than <see cref="MaxCommunity"/>).
    /// </summary>
    public static SnmpLogin? ForCommunity(string? text, out string? error)
    {
        error = null;
        if (string.IsNullOrWhiteSpace(text)) return Public;
        if (text.Any(char.IsControl)) error = "The community can't have tabs, line breaks or other control characters.";
        else if (System.Text.Encoding.UTF8.GetByteCount(text) > MaxCommunity) error = $"The community can be at most {MaxCommunity} characters.";
        return error is null ? new SnmpLogin(text) : null;
    }

    /// <summary>The login as one string, for <see cref="ISnmpLogins"/> to keep (and only for that).</summary>
    public string ToSecret() => "community:" + Community;

    /// <summary>A login kept by <see cref="ToSecret"/>; null for anything else (a damaged or unknown entry: asked with public).</summary>
    public static SnmpLogin? FromSecret(string? secret) =>
        secret is not null && secret.StartsWith("community:", StringComparison.Ordinal)
            ? ForCommunity(secret["community:".Length..], out _) : null;

    /// <summary>For logs: never the community itself.</summary>
    public override string ToString() => IsDefault ? "SNMP community public" : "SNMP community (kept)";
}

/// <summary>Where each printer's <see cref="SnmpLogin"/> is kept, by printer id: Windows Credential Manager, or memory (demo mode, tests).</summary>
public interface ISnmpLogins
{
    /// <summary>The printer's login; null when none is kept (asked with <see cref="SnmpLogin.Public"/>) or it can't be read.</summary>
    SnmpLogin? Get(string printerId);

    /// <summary>Keeps <paramref name="login"/> for the printer; <see cref="SnmpLogin.IsDefault"/> deletes what was kept instead.</summary>
    void Save(string printerId, SnmpLogin login);

    void Delete(string printerId);

    /// <summary>Moves a printer's login to its new id; never overwrites one kept there.</summary>
    void Rename(string oldId, string newId)
    {
        if (Get(oldId) is not { } login) return;
        if (Get(newId) is null) Save(newId, login);
        Delete(oldId);
    }
}

/// <summary>Logins kept for this run only: demo mode writes nothing to Windows Credential Manager; the tests' store.</summary>
public sealed class MemorySnmpLogins : ISnmpLogins
{
    private readonly Dictionary<string, string> _kept = new(StringComparer.OrdinalIgnoreCase);

    public SnmpLogin? Get(string printerId)
    {
        lock (_kept) return SnmpLogin.FromSecret(_kept.GetValueOrDefault(printerId));
    }

    public void Save(string printerId, SnmpLogin login)
    {
        lock (_kept)
        {
            if (login.IsDefault) _kept.Remove(printerId);
            else _kept[printerId] = login.ToSecret();
        }
    }

    public void Delete(string printerId)
    {
        lock (_kept) _kept.Remove(printerId);
    }

    /// <summary>How many printers have a login kept (tests).</summary>
    public int Count
    {
        get { lock (_kept) return _kept.Count; }
    }
}
