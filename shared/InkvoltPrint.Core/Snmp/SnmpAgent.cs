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

    public string Community { get; }
    public bool V1Only { get; }

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

    public Task<byte[]?> SendAsync(string host, byte[] request, TimeSpan timeout, CancellationToken ct)
    {
        ct.ThrowIfCancellationRequested();
        return Task.FromResult(Respond(request));
    }

    /// <summary>The reply to one request datagram; null where a real agent stays silent (garbage, wrong community or version).</summary>
    public byte[]? Respond(byte[] request)
    {
        Requests++;
        SnmpMessage m;
        try { m = SnmpMessage.Decode(request); }
        catch (FormatException) { return null; }
        Received.Add(m);
        if (m.Community != Community || (V1Only && m.Version != SnmpVersion.V1)) return null;
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

    private static byte[] PerObject(SnmpMessage m, bool v1, Func<Oid, SnmpVarBind> answer)
    {
        var bindings = m.VarBinds.Select(vb => answer(vb.Name)).ToList();
        if (v1 && bindings.FindIndex(b => b.Value.IsException) is var bad and >= 0)
            return Reply(m, SnmpMessage.NoSuchName, bad + 1, m.VarBinds); // RFC 1157 §4.1.2: the request comes back, with the index
        return Reply(m, 0, 0, bindings);
    }

    private byte[] Bulk(SnmpMessage m)
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

    private static byte[] Reply(SnmpMessage m, int status, int index, IReadOnlyList<SnmpVarBind> bindings) =>
        (m with { Type = SnmpPduType.Response, ErrorStatus = status, ErrorIndex = index, VarBinds = bindings }).Encode();

    [GeneratedRegex(@"^(?<oid>\.?\d+(\.\d+)+)\s*=\s*(?<type>[A-Za-z0-9-]+):\s*(?<value>.*)$")]
    private static partial Regex WalkLine();
}
