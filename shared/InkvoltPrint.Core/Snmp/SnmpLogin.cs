namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// How Inkvolt Print signs in to one printer's SNMP agent: a read community (v1, v2c), or (Inkvolt Pro) an SNMPv3 user with
/// its two passphrases (<see cref="SnmpV3User"/>: SHA-256 authentication, AES-128 privacy). A secret: kept by an
/// <see cref="ISnmpLogins"/> (Windows Credential Manager), never in <c>state.json</c>, a recording or the log;
/// <see cref="ToString"/> names no secret. A printer with nothing kept is asked with <see cref="Public"/>.
/// </summary>
public sealed record SnmpLogin
{
    /// <summary>The longest community taken (RFC 3417's OCTET STRING has no limit; net-snmp's agents stop at 255).</summary>
    public const int MaxCommunity = 255;

    private SnmpLogin(string community, SnmpV3User? user = null)
    {
        Community = community;
        User = user;
    }

    /// <summary>"public", the read community nearly every printer ships with.</summary>
    public static SnmpLogin Public { get; } = new(SnmpClient.DefaultCommunity);

    /// <summary>The v1/v2c community; empty for an SNMPv3 login.</summary>
    public string Community { get; }

    /// <summary>The SNMPv3 user (an Inkvolt Pro feature); null for a community.</summary>
    public SnmpV3User? User { get; }

    /// <summary>Nothing to keep: the community every printer is asked with anyway.</summary>
    public bool IsDefault => User is null && Community == SnmpClient.DefaultCommunity;

    /// <summary>
    /// An SNMPv3 user as typed: a name (1 to 32 characters) and two passphrases of at least <see cref="SnmpV3User.MinPassphrase"/>
    /// characters (RFC 3414 §11.2). Null with <paramref name="error"/> otherwise.
    /// </summary>
    public static SnmpLogin? ForUser(string? name, string? authPassphrase, string? privPassphrase, out string? error)
    {
        error = string.IsNullOrWhiteSpace(name) ? CoreStrings.Snmp_EnterUserName
            : name.Length > SnmpV3User.MaxName || name.Any(char.IsControl) ? string.Format(CoreStrings.Snmp_UserNameLength, SnmpV3User.MaxName)
            : (authPassphrase?.Length ?? 0) < SnmpV3User.MinPassphrase ? string.Format(CoreStrings.Snmp_AuthPassphraseLength, SnmpV3User.MinPassphrase)
            : (privPassphrase?.Length ?? 0) < SnmpV3User.MinPassphrase ? string.Format(CoreStrings.Snmp_PrivPassphraseLength, SnmpV3User.MinPassphrase)
            : authPassphrase!.Any(char.IsControl) || privPassphrase!.Any(char.IsControl) ? CoreStrings.Snmp_PassphraseControlChars
            : null;
        return error is null ? new SnmpLogin("", new SnmpV3User(name!, authPassphrase!, privPassphrase!)) : null;
    }

    /// <summary>
    /// A community as typed: blank is <see cref="Public"/>; otherwise as it is (spaces count: an agent compares bytes). Null with
    /// <paramref name="error"/> for one that can't be sent (control characters, longer than <see cref="MaxCommunity"/>).
    /// </summary>
    public static SnmpLogin? ForCommunity(string? text, out string? error)
    {
        error = null;
        if (string.IsNullOrWhiteSpace(text)) return Public;
        if (text.Any(char.IsControl)) error = CoreStrings.Snmp_CommunityControlChars;
        else if (System.Text.Encoding.UTF8.GetByteCount(text) > MaxCommunity) error = string.Format(CoreStrings.Snmp_CommunityLength, MaxCommunity);
        return error is null ? new SnmpLogin(text) : null;
    }

    /// <summary>The login as one string, for <see cref="ISnmpLogins"/> to keep (and only for that).</summary>
    public string ToSecret() => User is { } u
        ? "usm:" + string.Join(':', new[] { u.Name, u.AuthPassphrase, u.PrivPassphrase }.Select(p => Convert.ToBase64String(System.Text.Encoding.UTF8.GetBytes(p))))
        : "community:" + Community;

    /// <summary>A login kept by <see cref="ToSecret"/>; null for anything else (a damaged or unknown entry: asked with public).</summary>
    public static SnmpLogin? FromSecret(string? secret)
    {
        if (secret is null) return null;
        if (secret.StartsWith("community:", StringComparison.Ordinal)) return ForCommunity(secret["community:".Length..], out _);
        if (!secret.StartsWith("usm:", StringComparison.Ordinal) || secret[4..].Split(':') is not { Length: 3 } parts) return null;
        try
        {
            var p = parts.Select(b => System.Text.Encoding.UTF8.GetString(Convert.FromBase64String(b))).ToArray();
            return ForUser(p[0], p[1], p[2], out _);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    /// <summary>For logs: never the community, a user name or a passphrase.</summary>
    public override string ToString() => User is not null ? "SNMPv3 user (kept)" : IsDefault ? "SNMP community public" : "SNMP community (kept)";
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

/// <summary>What every reader of a printer asks the store for (the app, <c>status --all</c>).</summary>
public static class SnmpLoginRules
{
    /// <summary>
    /// The printer's login as it may be used now: an SNMPv3 user only while Inkvolt Pro allows it
    /// (<see cref="Pro.Allows"/> <see cref="ProFeature.SnmpV3"/>), else none (public); a community always (free).
    /// </summary>
    public static SnmpLogin? Usable(this ISnmpLogins logins, string printerId) =>
        logins.Get(printerId) is { User: not null } && !Pro.Allows(ProFeature.SnmpV3) ? null : logins.Get(printerId);
}
