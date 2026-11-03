using System.Globalization;
using System.Text.RegularExpressions;

namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// A made-up SNMP agent over a fixed set of objects, answering Get, GetNext and GetBulk as RFC 1157 §4.1 and RFC 3416 §4.2
/// describe (v1: noSuchName errors; v2c: exception values; a Set is refused). Demo mode's SNMP-only printers and the tests
/// talk to it instead of the network. Requests with another community, or v2c to a v1-only agent, get no reply, like a
/// real agent.
/// </summary>
public sealed partial class SnmpAgent : ISnmpTransport
{
    private readonly List<SnmpVarBind> _objects;

    public SnmpAgent(IEnumerable<SnmpVarBind> objects, string community = SnmpClient.DefaultCommunity, bool v1Only = false)
    {
        _objects = objects.OrderBy(o => o.Name).ToList();
        Community = community;
        V1Only = v1Only;
    }

    /// <summary>
    /// An SNMPv3-only agent (<see cref="RespondV3"/>) for <paramref name="user"/> at authPriv (SHA-256, AES-128), with engine
    /// <paramref name="engineId"/>; v1 and v2c requests get no reply.
    /// </summary>
    public SnmpAgent(IEnumerable<SnmpVarBind> objects, SnmpV3User user, byte[] engineId, int engineBoots = 1, int engineTime = 1000)
        : this(objects)
    {
        V3User = user;
        EngineId = engineId;
        EngineBoots = engineBoots;
        EngineTime = engineTime;
        _keys = Usm.Keys.For(user, engineId);
    }

    public string Community { get; }
    public bool V1Only { get; }

    /// <summary>The SNMPv3 user this agent knows (one; the agent answers nothing else).</summary>
    public SnmpV3User? V3User { get; }

    private bool V3Only => V3User is not null;
    private readonly Usm.Keys? _keys;
    private long _salt = 0x5A17_0000_0000_0000;

    /// <summary>The agent's snmpEngineID (RFC 3411).</summary>
    public byte[] EngineId { get; } = [];

    /// <summary>snmpEngineBoots and snmpEngineTime (the tests move them, as a restarted or long-running agent would).</summary>
    public int EngineBoots { get; set; }
    public int EngineTime { get; set; }

    /// <summary>The v3 requests received and what each came to: "discovery", "answered" or the usmStats counter reported (tests).</summary>
    public List<string> V3Log { get; } = [];

    /// <summary>Requests received (answered or not): lets tests check what was, and wasn't, asked.</summary>
    public int Requests { get; private set; }

    /// <summary>The requests received, decoded (tests).</summary>
    public List<SnmpMessage> Received { get; } = [];

    /// <summary>
    /// Objects written as net-snmp prints them (<c>snmpwalk -On</c>): <c>.1.3.6.1.2.1.1.1.0 = STRING: "Demo laser"</c>, with
    /// INTEGER, STRING, Hex-STRING, OID, Gauge32, Counter32, Timeticks and IpAddress. Blank lines and <c>#</c> comments are skipped.
    /// </summary>
    public static IReadOnlyList<SnmpVarBind> ParseWalk(string text)
    {
        var list = new List<SnmpVarBind>();
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            var m = WalkLine().Match(line);
            if (!m.Success) throw new FormatException($"Not an snmpwalk line: {line}");
            var value = m.Groups["value"].Value.Trim();
            list.Add(new SnmpVarBind(Oid.Parse(m.Groups["oid"].Value), m.Groups["type"].Value switch
            {
                "INTEGER" => SnmpValue.Integer(long.Parse(Regex.Match(value, @"-?\d+").Value, CultureInfo.InvariantCulture)),
                "STRING" => SnmpValue.String(value.Length >= 2 && value[0] == '"' && value[^1] == '"' ? value[1..^1].Replace("\\\"", "\"") : value),
                "Hex-STRING" => SnmpValue.Octets(Convert.FromHexString(value.Replace(" ", ""))),
                "OID" => SnmpValue.Id(Oid.Parse(value)),
                "Gauge32" => SnmpValue.Unsigned(Ber.Gauge32, ulong.Parse(value, CultureInfo.InvariantCulture)),
                "Counter32" => SnmpValue.Unsigned(Ber.Counter32, ulong.Parse(value, CultureInfo.InvariantCulture)),
                "Timeticks" => SnmpValue.Unsigned(Ber.TimeTicks, ulong.Parse(Regex.Match(value, @"\d+").Value, CultureInfo.InvariantCulture)),
                "IpAddress" => SnmpValue.Address(value.Split('.').Select(byte.Parse).ToArray()),
                var t => throw new FormatException($"Unknown snmpwalk type {t}"),
            }));
        }
        return list;
    }

    /// <summary>
    /// The other way: objects written as <see cref="ParseWalk"/> reads them, in OID order, one per line, so a recording
    /// (<see cref="Recording.PrinterRecorder"/>) is served again as it was read. An OCTET STRING is a STRING when it is
    /// printable text (no control characters, no edge spaces, no NULs), else Hex-STRING. Types <see cref="ParseWalk"/> doesn't
    /// read (Counter64, Opaque, NULL, the v2c exceptions) are left out as a comment line.
    /// </summary>
    public static string FormatWalk(IEnumerable<SnmpVarBind> objects)
    {
        var sb = new System.Text.StringBuilder();
        foreach (var o in objects.DistinctBy(o => o.Name).OrderBy(o => o.Name))
        {
            var v = o.Value;
            var value = v.Tag switch
            {
                Ber.Integer => $"INTEGER: {v.Number.ToString(CultureInfo.InvariantCulture)}",
                Ber.Gauge32 => $"Gauge32: {v.Number.ToString(CultureInfo.InvariantCulture)}",
                Ber.Counter32 => $"Counter32: {v.Number.ToString(CultureInfo.InvariantCulture)}",
                Ber.TimeTicks => $"Timeticks: ({v.Number.ToString(CultureInfo.InvariantCulture)})",
                Ber.ObjectIdentifier => $"OID: .{v.ObjectId}",
                Ber.IpAddress when v.Bytes is { Length: 4 } ip => $"IpAddress: {string.Join('.', ip)}",
                Ber.OctetString => PlainText(v.Bytes ?? []) is { } text ? $"STRING: \"{text.Replace("\"", "\\\"")}\""
                    : $"Hex-STRING: {Convert.ToHexString(v.Bytes ?? [])}",
                _ => null,
            };
            sb.Append(value is null ? $"# .{o.Name} = {v} (not kept)" : $".{o.Name} = {value}").Append('\n');
        }
        return sb.ToString();

        // Text that reads back byte for byte: valid UTF-8, printable, nothing ParseWalk's trimming or quoting would change.
        static string? PlainText(byte[] bytes)
        {
            string s;
            try { s = new System.Text.UTF8Encoding(false, true).GetString(bytes); }
            catch (System.Text.DecoderFallbackException) { return null; }
            return s.Length > 0 && s.All(c => !char.IsControl(c)) && s.Trim().Length == s.Length && !s.EndsWith('\\') ? s : null;
        }
    }

    public Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult(Respond(request));
    }

    /// <summary>The reply to one request datagram; null where a real agent stays silent (garbage, wrong community or version).</summary>
    public byte[]? Respond(byte[] request)
    {
        Requests++;
        if (SnmpV3Message.IsV3(request)) return RespondV3(request);
        SnmpMessage m;
        try { m = SnmpMessage.Decode(request); }
        catch (FormatException) { return null; }
        Received.Add(m);
        if (V3Only || m.Community != Community || (V1Only && m.Version != SnmpVersion.V1)) return null;
        return Answer(m)?.Encode();
    }

    /// <summary>The reply to one request PDU (any version: the v3 path hands its decrypted PDU here); null where a real agent stays silent.</summary>
    private SnmpMessage? Answer(SnmpMessage m)
    {
        var v1 = m.Version == SnmpVersion.V1;
        return m.Type switch
        {
            SnmpPduType.GetRequest => PerObject(m, v1, name =>
                _objects.FirstOrDefault(o => o.Name.Equals(name))
                ?? new SnmpVarBind(name, _objects.Any(o => o.Name.Length == name.Length && name.IsUnder(Parent(o.Name))) ? SnmpValue.NoSuchInstance : SnmpValue.NoSuchObject)),
            SnmpPduType.GetNextRequest => PerObject(m, v1, name => Next(name) ?? new SnmpVarBind(name, SnmpValue.EndOfMibView)),
            SnmpPduType.GetBulkRequest when !v1 => Bulk(m),
            // Read-only: RFC 3416 §4.2.5 notWritable for v2c, RFC 1157 §4.1.5 readOnly for v1 (never sent by Inkvolt Print).
            SnmpPduType.SetRequest => Reply(m, v1 ? 4 : 17, 1, m.VarBinds),
            _ => null,
        };
    }

    private static Oid Parent(Oid o) => new([.. o.Arcs.Take(o.Length - 1)]);

    private SnmpVarBind? Next(Oid name)
    {
        // The first object after name in lexicographic order (binary search).
        int lo = 0, hi = _objects.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (_objects[mid].Name.CompareTo(name) <= 0) lo = mid + 1;
            else hi = mid;
        }
        return lo < _objects.Count ? _objects[lo] : null;
    }

    private static SnmpMessage PerObject(SnmpMessage m, bool v1, Func<Oid, SnmpVarBind> answer)
    {
        var bindings = m.VarBinds.Select(vb => answer(vb.Name)).ToList();
        if (v1 && bindings.FindIndex(b => b.Value.IsException) is var bad and >= 0)
            return Reply(m, SnmpMessage.NoSuchName, bad + 1, m.VarBinds); // RFC 1157 §4.1.2: the request comes back, with the index
        return Reply(m, 0, 0, bindings);
    }

    private SnmpMessage Bulk(SnmpMessage m)
    {
        var n = Math.Clamp(m.NonRepeaters, 0, m.VarBinds.Count);
        var bindings = new List<SnmpVarBind>();
        for (var i = 0; i < n; i++)
            bindings.Add(Next(m.VarBinds[i].Name) ?? new SnmpVarBind(m.VarBinds[i].Name, SnmpValue.EndOfMibView));
        var at = m.VarBinds.Skip(n).Select(vb => vb.Name).ToArray();
        for (var r = 0; r < Math.Max(0, m.MaxRepetitions) && at.Length > 0; r++)
        {
            var allEnded = true;
            for (var j = 0; j < at.Length; j++)
            {
                var next = Next(at[j]);
                bindings.Add(next ?? new SnmpVarBind(at[j], SnmpValue.EndOfMibView));
                if (next is null) continue;
                at[j] = next.Name;
                allEnded = false;
            }
            if (allEnded) break; // RFC 3416 §4.2.3: the agent may stop once every variable reached the end of its MIB
        }
        return Reply(m, 0, 0, bindings);
    }

    private static SnmpMessage Reply(SnmpMessage m, int status, int index, IReadOnlyList<SnmpVarBind> bindings) =>
        m with { Type = SnmpPduType.Response, ErrorStatus = status, ErrorIndex = index, VarBinds = bindings };

    [GeneratedRegex(@"^(?<oid>\.?\d+(\.\d+)+)\s*=\s*(?<type>[A-Za-z0-9-]+):\s*(?<value>.*)$")]
    private static partial Regex WalkLine();

    // ------------------------------------------------------------------------------------------------ SNMPv3 (RFC 3412 §7.2, RFC 3414 §3.2)

    /// <summary>
    /// A v3 request as an agent with one user at authPriv handles it: discovery (no engine ID) and an unknown engine get
    /// unknownEngineIDs with the engine's ID, boots and time; another user unknownUserNames; a lower security level
    /// unsupportedSecLevels; a wrong digest wrongDigests; a time outside 150 s of the engine's notInTimeWindows (signed); a
    /// scoped PDU that doesn't decrypt to one decryptionErrors. Reports other than notInTimeWindows go unsigned, as RFC 3414
    /// sends them. A request that reads is answered as v2c would be, signed and encrypted.
    /// </summary>
    private byte[]? RespondV3(byte[] request)
    {
        if (V3User is not { } user || _keys is not { } keys) return null; // a v1/v2c agent doesn't speak v3
        SnmpV3Message m;
        try { m = SnmpV3Message.Decode(request); }
        catch (FormatException) { return null; }
        var reportable = (m.Flags & SnmpV3Message.FlagReportable) != 0;
        if (m.EngineId.Length == 0 || !m.EngineId.AsSpan().SequenceEqual(EngineId))
            return Report(m, Usm.UnknownEngineIds, m.EngineId.Length == 0 ? "discovery" : "unknownEngineIDs");
        if (m.UserName != user.Name) return Report(m, Usm.UnknownUserNames, "unknownUserNames");
        if (!m.Authenticated || !m.Private) return Report(m, Usm.UnsupportedSecLevels, "unsupportedSecLevels");
        if (!m.Verify(request, keys.Auth)) return Report(m, Usm.WrongDigests, "wrongDigests");
        if (m.EngineBoots != EngineBoots || Math.Abs((long)m.EngineTime - EngineTime) > Usm.TimeWindow)
            return Report(m, Usm.NotInTimeWindows, "notInTimeWindows", signed: true);
        SnmpMessage pdu;
        try
        {
            if (m.Encrypted is null || m.PrivParameters.Length != Usm.SaltLength) throw new FormatException("no encrypted PDU");
            var (_, _, decrypted) = SnmpV3Message.DecodeScoped(
                Usm.AesCfb(keys.Priv, Usm.AesIv(m.EngineBoots, m.EngineTime, m.PrivParameters), m.Encrypted, encrypt: false));
            pdu = decrypted;
        }
        catch (FormatException)
        {
            return Report(m, Usm.DecryptionErrors, "decryptionErrors");
        }
        Received.Add(pdu);
        if (Answer(pdu) is not { } answer) return null;
        V3Log.Add("answered");
        return Wrap(m, answer, keys);

        byte[]? Report(SnmpV3Message to, Oid counter, string what, bool signed = false)
        {
            V3Log.Add(what);
            if (!reportable) return null;
            var requestId = to.Pdu?.RequestId ?? 0;
            var report = new SnmpMessage(SnmpVersion.V3, "", SnmpPduType.Report, requestId, 0, 0,
                [new SnmpVarBind(counter, SnmpValue.Unsigned(Ber.Counter32, 1))]);
            var reply = new SnmpV3Message
            {
                MessageId = to.MessageId, Flags = signed ? SnmpV3Message.FlagAuth : (byte)0, EngineId = EngineId, EngineBoots = EngineBoots,
                EngineTime = EngineTime, UserName = to.UserName, ContextEngineId = EngineId, Pdu = report,
            };
            return signed ? reply.Sign(keys.Auth) : reply.Encode();
        }
    }

    /// <summary>A Response, encrypted with a fresh salt and signed.</summary>
    private byte[] Wrap(SnmpV3Message to, SnmpMessage answer, Usm.Keys keys)
    {
        var salt = new byte[Usm.SaltLength];
        System.Buffers.Binary.BinaryPrimitives.WriteInt64BigEndian(salt, Interlocked.Increment(ref _salt));
        var scoped = SnmpV3Message.EncodeScoped(EngineId, "", answer);
        return new SnmpV3Message
        {
            MessageId = to.MessageId, Flags = SnmpV3Message.FlagAuth | SnmpV3Message.FlagPriv, EngineId = EngineId,
            EngineBoots = EngineBoots, EngineTime = EngineTime, UserName = to.UserName, PrivParameters = salt,
            Encrypted = Usm.AesCfb(keys.Priv, Usm.AesIv(EngineBoots, EngineTime, salt), scoped, encrypt: true),
        }.Sign(keys.Auth);
    }
}
