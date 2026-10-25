using System.Globalization;
using System.Text;

namespace InkvoltPrint.Core.Snmp;

/// <summary>SNMP message versions Inkvolt Print speaks: v1 (RFC 1157) and community-based v2c (RFC 1901). Never v3.</summary>
public enum SnmpVersion { V1 = 0, V2c = 1 }

/// <summary>PDU tags (RFC 1157 §4.1, RFC 3416 §3). Inkvolt Print sends only Get, GetNext and GetBulk: never Set.</summary>
public enum SnmpPduType : byte
{
    GetRequest = 0xA0,
    GetNextRequest = 0xA1,
    Response = 0xA2,
    SetRequest = 0xA3,
    GetBulkRequest = 0xA5,
    InformRequest = 0xA6,
    TrapV2 = 0xA7,
    Report = 0xA8,
}

/// <summary>One value in a variable binding: a number, octets, an OID, NULL or (SNMPv2) an exception.</summary>
public sealed class SnmpValue
{
    private SnmpValue(byte tag, long number = 0, byte[]? bytes = null, Oid? oid = null)
    {
        Tag = tag;
        Number = number;
        Bytes = bytes;
        ObjectId = oid;
    }

    /// <summary>The BER tag (<see cref="Ber"/>: INTEGER 0x02, OCTET STRING 0x04, Gauge32 0x42…).</summary>
    public byte Tag { get; }

    /// <summary>INTEGER, Counter32, Gauge32, TimeTicks, Counter64 (a Counter64 above 2^63 wraps; nothing here reads one).</summary>
    public long Number { get; }

    /// <summary>OCTET STRING, IpAddress, Opaque.</summary>
    public byte[]? Bytes { get; }

    public Oid? ObjectId { get; }

    public bool IsNumber => Tag is Ber.Integer or Ber.Counter32 or Ber.Gauge32 or Ber.TimeTicks or Ber.Counter64;

    /// <summary>noSuchObject, noSuchInstance or endOfMibView (SNMPv2), or the placeholder for a v1 noSuchName.</summary>
    public bool IsException => Tag is Ber.NoSuchObject or Ber.NoSuchInstance or Ber.EndOfMibView;

    public static SnmpValue Null { get; } = new(Ber.Null);
    public static SnmpValue NoSuchObject { get; } = new(Ber.NoSuchObject);
    public static SnmpValue NoSuchInstance { get; } = new(Ber.NoSuchInstance);
    public static SnmpValue EndOfMibView { get; } = new(Ber.EndOfMibView);

    public static SnmpValue Integer(long value) => new(Ber.Integer, value);
    public static SnmpValue Octets(byte[] value) => new(Ber.OctetString, bytes: (byte[])value.Clone());
    public static SnmpValue String(string value) => new(Ber.OctetString, bytes: Encoding.UTF8.GetBytes(value));
    public static SnmpValue Id(Oid value) => new(Ber.ObjectIdentifier, oid: value);
    public static SnmpValue Unsigned(byte tag, ulong value) =>
        tag is Ber.Counter32 or Ber.Gauge32 or Ber.TimeTicks or Ber.Counter64 ? new(tag, unchecked((long)value)) : throw new ArgumentException("Not an unsigned type.", nameof(tag));
    public static SnmpValue Address(byte[] ipv4) => ipv4.Length == 4 ? new(Ber.IpAddress, bytes: (byte[])ipv4.Clone()) : throw new ArgumentException("IpAddress is 4 bytes.", nameof(ipv4));

    /// <summary>The number when it fits an <see cref="int"/>; null for other types.</summary>
    public int? Int => IsNumber && Number is >= int.MinValue and <= int.MaxValue ? (int)Number : null;

    /// <summary>
    /// An OCTET STRING as text: UTF-8 when it is valid UTF-8, else Latin-1 (older printers); NULs and surrounding spaces
    /// trimmed (some printers pad descriptions with NULs). Null for other types and for empty text.
    /// </summary>
    public string? Text
    {
        get
        {
            if (Tag != Ber.OctetString || Bytes is null) return null;
            string s;
            try { s = new UTF8Encoding(false, true).GetString(Bytes); }
            catch (DecoderFallbackException) { s = Encoding.Latin1.GetString(Bytes); }
            var nul = s.IndexOf('\0');
            if (nul >= 0) s = s[..nul];
            s = new string(s.Where(c => !char.IsControl(c) || c is '\n').ToArray()).Trim();
            return s.Length == 0 ? null : s;
        }
    }

    internal byte[] Encode() => Tag switch
    {
        Ber.Integer => Ber.Tlv(Tag, Ber.IntegerContent(Number)),
        Ber.Counter32 or Ber.Gauge32 or Ber.TimeTicks or Ber.Counter64 => Ber.Tlv(Tag, Ber.UnsignedContent(unchecked((ulong)Number))),
        Ber.OctetString or Ber.IpAddress or Ber.Opaque => Ber.Tlv(Tag, Bytes),
        Ber.ObjectIdentifier => Ber.ObjectId(ObjectId!),
        _ => [Tag, 0x00], // NULL and the SNMPv2 exceptions carry no content
    };

    internal static SnmpValue Decode(byte tag, ReadOnlySpan<byte> content) => tag switch
    {
        Ber.Integer => new(tag, Ber.SignedValue(content)),
        Ber.Counter32 or Ber.Gauge32 or Ber.TimeTicks or Ber.Counter64 => new(tag, unchecked((long)Ber.UnsignedValue(content))),
        Ber.OctetString or Ber.IpAddress or Ber.Opaque => new(tag, bytes: content.ToArray()),
        Ber.ObjectIdentifier => new(tag, oid: Ber.ObjectIdValue(content)),
        Ber.Null or Ber.NoSuchObject or Ber.NoSuchInstance or Ber.EndOfMibView when content.Length == 0 => tag switch
        {
            Ber.NoSuchObject => NoSuchObject,
            Ber.NoSuchInstance => NoSuchInstance,
            Ber.EndOfMibView => EndOfMibView,
            _ => Null,
        },
        _ => throw new FormatException($"SNMP: unknown value type 0x{tag:X2}."),
    };

    /// <summary>As net-snmp prints values ("INTEGER: 3", "STRING: \"Ready\""), for the developer CLI and logs.</summary>
    public override string ToString() => Tag switch
    {
        Ber.Integer => $"INTEGER: {Number}",
        Ber.Counter32 => $"Counter32: {Number}",
        Ber.Gauge32 => $"Gauge32: {Number}",
        Ber.TimeTicks => $"Timeticks: ({Number})",
        Ber.Counter64 => $"Counter64: {Number}",
        Ber.OctetString => Text is { } t && t.All(c => !char.IsControl(c)) ? $"STRING: \"{t}\"" : $"Hex-STRING: {Convert.ToHexString(Bytes ?? [])}",
        Ber.IpAddress => $"IpAddress: {string.Join('.', Bytes!)}",
        Ber.ObjectIdentifier => $"OID: .{ObjectId}",
        Ber.NoSuchObject => "No Such Object",
        Ber.NoSuchInstance => "No Such Instance",
        Ber.EndOfMibView => "End of MIB",
        Ber.Null => "NULL",
        _ => $"0x{Tag:X2}: {Convert.ToHexString(Bytes ?? [])}",
    };

    public override bool Equals(object? obj) =>
        obj is SnmpValue v && v.Tag == Tag && v.Number == Number && Equals(v.ObjectId, ObjectId)
        && (v.Bytes ?? []).AsSpan().SequenceEqual(Bytes ?? []);

    public override int GetHashCode() => HashCode.Combine(Tag, Number, ObjectId, Bytes?.Length);
}

/// <summary>A variable binding: an object's name and its value (NULL in requests).</summary>
public sealed record SnmpVarBind(Oid Name, SnmpValue Value)
{
    public override string ToString() => $".{Name} = {Value}";
}

/// <summary>
/// An SNMPv1/v2c message (RFC 1157 §4, RFC 1901 §3): version, community, and one PDU. A GetBulk PDU (RFC 3416 §3) has the
/// same shape, with non-repeaters in place of error-status and max-repetitions in place of error-index.
/// </summary>
public sealed record SnmpMessage(
    SnmpVersion Version,
    string Community,
    SnmpPduType Type,
    int RequestId,
    int ErrorStatus,
    int ErrorIndex,
    IReadOnlyList<SnmpVarBind> VarBinds)
{
    /// <summary>RFC 3416 §3 error-status values the client tells apart.</summary>
    public const int NoError = 0, TooBig = 1, NoSuchName = 2, GenErr = 5;

    public int NonRepeaters => ErrorStatus;
    public int MaxRepetitions => ErrorIndex;

    public byte[] Encode()
    {
        var bindings = VarBinds.Select(vb => Ber.Constructed(Ber.Sequence, Ber.ObjectId(vb.Name), vb.Value.Encode())).ToArray();
        var pdu = Ber.Constructed((byte)Type, Ber.Integer32(RequestId), Ber.Integer32(ErrorStatus), Ber.Integer32(ErrorIndex),
            Ber.Constructed(Ber.Sequence, bindings));
        return Ber.Constructed(Ber.Sequence, Ber.Integer32((int)Version), Ber.Octets(Encoding.UTF8.GetBytes(Community)), pdu);
    }

    /// <summary>A message from the network. <see cref="FormatException"/> for anything that isn't a v1/v2c message.</summary>
    public static SnmpMessage Decode(byte[] data)
    {
        var message = new Ber.Reader(data).Enter(Ber.Sequence);
        var version = message.ReadInteger() switch
        {
            0 => SnmpVersion.V1,
            1 => SnmpVersion.V2c,
            var v => throw new FormatException($"SNMP: version {v.ToString(CultureInfo.InvariantCulture)} isn't v1 or v2c."),
        };
        var community = Encoding.UTF8.GetString(message.ReadOctets());
        var (tag, start, length) = message.Next();
        if (!Enum.IsDefined((SnmpPduType)tag)) throw new FormatException($"SNMP: PDU type 0x{tag:X2} isn't handled.");
        var pdu = new Ber.Reader(data, start, start + length);
        var requestId = Int32(pdu.ReadInteger());
        var errorStatus = Int32(pdu.ReadInteger());
        var errorIndex = Int32(pdu.ReadInteger());
        var list = pdu.Enter(Ber.Sequence);
        var bindings = new List<SnmpVarBind>();
        while (list.HasMore)
        {
            var vb = list.Enter(Ber.Sequence);
            var name = vb.ReadObjectId();
            var (vt, vs, vl) = vb.Next();
            bindings.Add(new SnmpVarBind(name, SnmpValue.Decode(vt, vb.Content(vs, vl))));
            if (vb.HasMore) throw new FormatException("SNMP: extra data in a variable binding.");
        }
        return new SnmpMessage(version, community, (SnmpPduType)tag, requestId, errorStatus, errorIndex, bindings);
    }

    private static int Int32(long v) => v is >= int.MinValue and <= int.MaxValue ? (int)v : throw new FormatException("SNMP: value out of range.");
}

/// <summary>The agent answered with an error-status (RFC 3416 §3) the client can't work around, or with an unexpected PDU.</summary>
public sealed class SnmpErrorException(int status, string message) : Exception(message)
{
    public int Status { get; } = status;
}
