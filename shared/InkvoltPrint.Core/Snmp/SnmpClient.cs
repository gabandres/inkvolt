using System.Security.Cryptography;

namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// A read-only SNMP manager for one agent: Get, GetNext and (v2c, v3) GetBulk, and table walks built on them. It has no
/// way to send a Set. Each request waits <see cref="Timeout"/> and is sent again <see cref="Retries"/> times (UDP may drop
/// it); no reply at all is a <see cref="TimeoutException"/> (the printer is off or has no agent), a reply that isn't SNMP a
/// <see cref="FormatException"/>, an error the client can't work around a <see cref="SnmpErrorException"/>. Over SNMPv3
/// (a login with a <see cref="SnmpV3User"/>) every request is authenticated and encrypted (authPriv) after the agent's
/// engine is discovered (RFC 3414 §4), every reply is checked before it's read, and an agent that refuses the user or its
/// keys is a <see cref="SnmpAccessException"/>.
/// </summary>
public sealed partial class SnmpClient
{
    /// <summary>The read community nearly every printer ships with.</summary>
    public const string DefaultCommunity = "public";

    private readonly ISnmpTransport transport;
    private readonly string community;
    private readonly SnmpV3User? _user;

    public SnmpClient(ISnmpTransport transport, string host, SnmpVersion version, string community = DefaultCommunity)
    {
        if (version == SnmpVersion.V3) throw new ArgumentException("SNMPv3 needs a login with a user.", nameof(version));
        this.transport = transport;
        this.community = community;
        Host = host;
        Version = version;
    }

    /// <summary>A client with <paramref name="login"/>: its community over <paramref name="version"/>, or its SNMPv3 user (version 3).</summary>
    public SnmpClient(ISnmpTransport transport, string host, SnmpVersion version, SnmpLogin login)
    {
        if ((version == SnmpVersion.V3) != (login.User is not null))
            throw new ArgumentException("SNMPv3 goes with a login with a user, and only it.", nameof(version));
        this.transport = transport;
        community = login.Community;
        _user = login.User;
        Host = host;
        Version = version;
    }

    public string Host { get; }
    public SnmpVersion Version { get; }
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(1);
    public int Retries { get; init; } = 1;

    /// <summary>Rows a walk reads at most per column (a printer's alert or supply table is far shorter).</summary>
    public int MaxRows { get; init; } = 64;

    private int _requestId = RandomNumberGenerator.GetInt32(1, int.MaxValue / 2);

    /// <summary>
    /// The values of <paramref name="names"/>, in order. An object the agent doesn't have comes back as an exception value
    /// (SNMPv2's noSuchObject / noSuchInstance; for v1, whose noSuchName fails the whole request, the request is sent again
    /// without that object).
    /// </summary>
    public Task<IReadOnlyList<SnmpVarBind>> GetAsync(IReadOnlyList<Oid> names, CancellationToken ct = default) =>
        PerObjectAsync(SnmpPduType.GetRequest, names, SnmpValue.NoSuchObject, ct);

    /// <summary>The object after each of <paramref name="names"/>; past the last object, endOfMibView (also for v1's noSuchName).</summary>
    public Task<IReadOnlyList<SnmpVarBind>> GetNextAsync(IReadOnlyList<Oid> names, CancellationToken ct = default) =>
        PerObjectAsync(SnmpPduType.GetNextRequest, names, SnmpValue.EndOfMibView, ct);

    private async Task<IReadOnlyList<SnmpVarBind>> PerObjectAsync(SnmpPduType type, IReadOnlyList<Oid> names, SnmpValue missing, CancellationToken ct)
    {
        var result = new SnmpVarBind?[names.Count];
        var pending = Enumerable.Range(0, names.Count).ToList();
        while (pending.Count > 0)
        {
            var reply = await SendAsync(type, 0, 0, pending.Select(i => names[i]).ToList(), ct).ConfigureAwait(false);
            if (reply.ErrorStatus == SnmpMessage.NoSuchName && reply.ErrorIndex >= 1 && reply.ErrorIndex <= pending.Count)
            {
                var i = pending[reply.ErrorIndex - 1]; // v1: that object isn't there (or nothing follows it); ask for the others
                result[i] = new SnmpVarBind(names[i], missing);
                pending.RemoveAt(reply.ErrorIndex - 1);
                continue;
            }
            ThrowOnError(reply);
            if (reply.VarBinds.Count != pending.Count) throw new FormatException("SNMP: the reply doesn't answer every object asked for.");
            for (var k = 0; k < pending.Count; k++) result[pending[k]] = reply.VarBinds[k];
            break;
        }
        return result.Select(r => r!).ToList();
    }

    /// <summary>RFC 3416 §4.2.3 GetBulk (v2c only): <paramref name="nonRepeaters"/> objects once, then up to <paramref name="maxRepetitions"/> successors of the rest.</summary>
    public async Task<IReadOnlyList<SnmpVarBind>> GetBulkAsync(int nonRepeaters, int maxRepetitions, IReadOnlyList<Oid> names, CancellationToken ct = default)
    {
        if (Version == SnmpVersion.V1) throw new InvalidOperationException("GetBulk is SNMPv2 and v3 only.");
        var reply = await SendAsync(SnmpPduType.GetBulkRequest, nonRepeaters, maxRepetitions, names, ct).ConfigureAwait(false);
        ThrowOnError(reply);
        return reply.VarBinds;
    }

    /// <summary>
    /// Walks table columns side by side (GetBulk on v2c, GetNext on v1): for each prefix in <paramref name="columns"/>, every
    /// object under it, as (arcs after the prefix, value), in order. A column ends when the agent moves past it, reports the
    /// end of its MIB, or doesn't move forward (a broken agent never loops the walk). When GetBulk fails with an error the walk
    /// goes on with GetNext; an error on GetNext ends the column it names (all of them when it names none), so a table the agent
    /// can't read is empty rather than the whole read failing. No reply at all is still a <see cref="TimeoutException"/>.
    /// </summary>
    public async Task<IReadOnlyList<IReadOnlyList<(uint[] Index, SnmpValue Value)>>> WalkAsync(IReadOnlyList<Oid> columns, CancellationToken ct = default)
    {
        var rows = columns.Select(_ => new List<(uint[], SnmpValue)>()).ToArray();
        var at = columns.ToArray();
        var done = new bool[columns.Count];
        var repetitions = 16;
        var bulk = Version != SnmpVersion.V1;
        for (var request = 0; request < MaxRows * 2 && done.Contains(false); request++)
        {
            var active = Enumerable.Range(0, columns.Count).Where(i => !done[i]).ToList();
            var names = active.Select(i => at[i]).ToList();
            IReadOnlyList<SnmpVarBind> reply;
            if (bulk)
            {
                var r = await SendAsync(SnmpPduType.GetBulkRequest, 0, repetitions, names, ct).ConfigureAwait(false);
                if (r.ErrorStatus == SnmpMessage.TooBig && repetitions > 1)
                {
                    repetitions /= 2; // the reply wouldn't fit a datagram: fewer rows per request
                    continue;
                }
                if (r.ErrorStatus != SnmpMessage.NoError)
                {
                    bulk = false; // some agents fail GetBulk on a table they answer GetNext for
                    continue;
                }
                reply = r.VarBinds;
                if (reply.Count == 0) break;
            }
            else
            {
                try
                {
                    reply = await GetNextAsync(names, ct).ConfigureAwait(false);
                }
                catch (SnmpErrorException ex)
                {
                    if (ex.Index >= 1 && ex.Index <= active.Count) done[active[ex.Index - 1]] = true;
                    else foreach (var i in active) done[i] = true;
                    continue;
                }
            }
            // Replies come row by row: the successors of every active column, then theirs, and so on (RFC 3416 §4.2.3).
            for (var k = 0; k < reply.Count; k++)
            {
                var col = active[k % active.Count];
                if (done[col]) continue;
                var vb = reply[k];
                if (vb.Value.IsException || vb.Name.After(columns[col]) is not { } index || vb.Name.CompareTo(at[col]) <= 0 || rows[col].Count >= MaxRows)
                {
                    done[col] = true;
                    continue;
                }
                rows[col].Add((index, vb.Value));
                at[col] = vb.Name;
            }
        }
        return rows;
    }

    private static void ThrowOnError(SnmpMessage reply)
    {
        if (reply.ErrorStatus != SnmpMessage.NoError)
            throw new SnmpErrorException(reply.ErrorStatus, $"SNMP error-status {reply.ErrorStatus} (index {reply.ErrorIndex}).", reply.ErrorIndex);
    }

    /// <summary>Sends a request and waits for its Response (same request-id), trying again on silence. Never anything but a read.</summary>
    private async Task<SnmpMessage> SendAsync(SnmpPduType type, int a, int b, IReadOnlyList<Oid> names, CancellationToken ct)
    {
        if (type is not (SnmpPduType.GetRequest or SnmpPduType.GetNextRequest or SnmpPduType.GetBulkRequest))
            throw new InvalidOperationException("Inkvolt Print only reads over SNMP.");
        var id = Interlocked.Increment(ref _requestId) & int.MaxValue;
        var pdu = new SnmpMessage(Version, community, type, id, a, b, names.Select(n => new SnmpVarBind(n, SnmpValue.Null)).ToList());
        if (Version == SnmpVersion.V3) return await SendV3Async(pdu with { Community = "" }, ct).ConfigureAwait(false);
        var request = pdu.Encode();
        for (var attempt = 0; attempt <= Retries; attempt++)
        {
            if (await transport.SendAsync(Host, request, Timeout, ct).ConfigureAwait(false) is not { } bytes) continue;
            SnmpMessage reply;
            try { reply = SnmpMessage.Decode(bytes); }
            catch (FormatException) { continue; } // not an SNMP message (garbage, or something else on the port): no answer
            // Another reply on this socket (a duplicate, or someone else's): not an answer to this request.
            if (reply.Type != SnmpPduType.Response || reply.RequestId != id || reply.Version != Version) continue;
            return reply;
        }
        throw new TimeoutException($"No SNMP reply from {Host}.");
    }
}
