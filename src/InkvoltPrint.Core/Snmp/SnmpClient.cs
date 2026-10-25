using System.Security.Cryptography;

namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// A read-only SNMPv1/v2c manager for one agent: Get, GetNext and (v2c) GetBulk, and table walks built on them. It has no
/// way to send a Set. Each request waits <see cref="Timeout"/> and is sent again <see cref="Retries"/> times (UDP may drop
/// it); no reply at all is a <see cref="TimeoutException"/> (the printer is off or has no agent), a reply that isn't SNMP a
/// <see cref="FormatException"/>, an error the client can't work around a <see cref="SnmpErrorException"/>.
/// </summary>
public sealed class SnmpClient(ISnmpTransport transport, string host, SnmpVersion version, string community = SnmpClient.DefaultCommunity)
{
    /// <summary>The read community nearly every printer ships with.</summary>
    public const string DefaultCommunity = "public";

    public string Host { get; } = host;
    public SnmpVersion Version { get; } = version;
    public TimeSpan Timeout { get; init; } = TimeSpan.FromSeconds(1.5);
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
        if (Version == SnmpVersion.V1) throw new InvalidOperationException("GetBulk is SNMPv2 only.");
        var reply = await SendAsync(SnmpPduType.GetBulkRequest, nonRepeaters, maxRepetitions, names, ct).ConfigureAwait(false);
        ThrowOnError(reply);
        return reply.VarBinds;
    }

    /// <summary>
    /// Walks table columns side by side (GetBulk on v2c, GetNext on v1): for each prefix in <paramref name="columns"/>, every
    /// object under it, as (arcs after the prefix, value), in order. A column ends when the agent moves past it, reports the
    /// end of its MIB, or doesn't move forward (a broken agent never loops the walk).
    /// </summary>
    public async Task<IReadOnlyList<IReadOnlyList<(uint[] Index, SnmpValue Value)>>> WalkAsync(IReadOnlyList<Oid> columns, CancellationToken ct = default)
    {
        var rows = columns.Select(_ => new List<(uint[], SnmpValue)>()).ToArray();
        var at = columns.ToArray();
        var done = new bool[columns.Count];
        var repetitions = 16;
        for (var request = 0; request < MaxRows * 2 && done.Contains(false); request++)
        {
            var active = Enumerable.Range(0, columns.Count).Where(i => !done[i]).ToList();
            var names = active.Select(i => at[i]).ToList();
            IReadOnlyList<SnmpVarBind> reply;
            if (Version == SnmpVersion.V2c)
            {
                var r = await SendAsync(SnmpPduType.GetBulkRequest, 0, repetitions, names, ct).ConfigureAwait(false);
                if (r.ErrorStatus == SnmpMessage.TooBig && repetitions > 1)
                {
                    repetitions /= 2; // the reply wouldn't fit a datagram: fewer rows per request
                    continue;
                }
                ThrowOnError(r);
                reply = r.VarBinds;
                if (reply.Count == 0) break;
            }
            else
            {
                reply = await GetNextAsync(names, ct).ConfigureAwait(false);
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
            throw new SnmpErrorException(reply.ErrorStatus, $"SNMP error-status {reply.ErrorStatus} (index {reply.ErrorIndex}).");
    }

    /// <summary>Sends a request and waits for its Response (same request-id), trying again on silence. Never anything but a read.</summary>
    private async Task<SnmpMessage> SendAsync(SnmpPduType type, int a, int b, IReadOnlyList<Oid> names, CancellationToken ct)
    {
        if (type is not (SnmpPduType.GetRequest or SnmpPduType.GetNextRequest or SnmpPduType.GetBulkRequest))
            throw new InvalidOperationException("Inkvolt Print only reads over SNMP.");
        var id = Interlocked.Increment(ref _requestId) & int.MaxValue;
        var request = new SnmpMessage(Version, community, type, id, a, b, names.Select(n => new SnmpVarBind(n, SnmpValue.Null)).ToList()).Encode();
        for (var attempt = 0; attempt <= Retries; attempt++)
        {
            if (await transport.SendAsync(Host, request, Timeout, ct).ConfigureAwait(false) is not { } bytes) continue;
            var reply = SnmpMessage.Decode(bytes);
            // Another reply on this socket (a duplicate, or someone else's): not an answer to this request.
            if (reply.Type != SnmpPduType.Response || reply.RequestId != id || reply.Version != Version) continue;
            return reply;
        }
        throw new TimeoutException($"No SNMP reply from {Host}.");
    }
}
