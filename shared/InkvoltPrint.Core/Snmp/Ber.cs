using System.Buffers.Binary;

namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// The part of BER (ITU-T X.690) that SNMP uses (RFC 1157 §4, RFC 3417 §8): one-byte tags, definite lengths, INTEGER,
/// OCTET STRING, NULL, OBJECT IDENTIFIER, SEQUENCE and the SNMP application types. Encoding is the shortest form (as DER,
/// which every agent accepts); decoding takes any definite length and rejects everything else (indefinite lengths,
/// multi-byte tags, values running past their container) with a <see cref="FormatException"/>: replies come from the network.
/// </summary>
internal static class Ber
{
    public const byte Integer = 0x02, OctetString = 0x04, Null = 0x05, ObjectIdentifier = 0x06, Sequence = 0x30;

    /// <summary>RFC 2578 §7.1 application types (RFC 3416 §3): IpAddress, Counter32, Gauge32/Unsigned32, TimeTicks, Opaque, Counter64.</summary>
    public const byte IpAddress = 0x40, Counter32 = 0x41, Gauge32 = 0x42, TimeTicks = 0x43, Opaque = 0x44, Counter64 = 0x46;

    /// <summary>RFC 3416 §3 VarBind exceptions in SNMPv2 responses: context-specific, primitive, empty.</summary>
    public const byte NoSuchObject = 0x80, NoSuchInstance = 0x81, EndOfMibView = 0x82;

    // ------------------------------------------------------------------------------------------------------------ encode

    /// <summary>Tag, length, content (X.690 §8.1).</summary>
    public static byte[] Tlv(byte tag, ReadOnlySpan<byte> content)
    {
        var length = Length(content.Length);
        var result = new byte[1 + length.Length + content.Length];
        result[0] = tag;
        length.CopyTo(result, 1);
        content.CopyTo(result.AsSpan(1 + length.Length));
        return result;
    }

    /// <summary>A constructed value: its parts one after the other.</summary>
    public static byte[] Constructed(byte tag, params byte[][] parts) => Tlv(tag, parts.SelectMany(p => p).ToArray());

    /// <summary>X.690 §8.1.3: short form below 128, else 0x80 + the number of length bytes, then the length big-endian.</summary>
    public static byte[] Length(int length)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(length);
        if (length < 0x80) return [(byte)length];
        Span<byte> b = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(b, length);
        var skip = 0;
        while (b[skip] == 0) skip++;
        return [(byte)(0x80 | (4 - skip)), .. b[skip..]];
    }

    /// <summary>X.690 §8.3: two's complement, big-endian, in as few bytes as keep the sign.</summary>
    public static byte[] IntegerContent(long value)
    {
        Span<byte> b = stackalloc byte[8];
        BinaryPrimitives.WriteInt64BigEndian(b, value);
        var i = 0;
        while (i < 7 && ((b[i] == 0x00 && (b[i + 1] & 0x80) == 0) || (b[i] == 0xFF && (b[i + 1] & 0x80) != 0))) i++;
        return b[i..].ToArray();
    }

    /// <summary>An unsigned value (Counter32, Gauge32, TimeTicks, Counter64) is a non-negative INTEGER: a leading zero when the top bit is set.</summary>
    public static byte[] UnsignedContent(ulong value)
    {
        Span<byte> b = stackalloc byte[9];
        BinaryPrimitives.WriteUInt64BigEndian(b[1..], value);
        var i = 0;
        while (i < 8 && b[i] == 0 && (b[i + 1] & 0x80) == 0) i++;
        return b[i..].ToArray();
    }

    public static byte[] Integer32(long value) => Tlv(Integer, IntegerContent(value));

    public static byte[] Octets(ReadOnlySpan<byte> value) => Tlv(OctetString, value);

    /// <summary>X.690 §8.19: the first two arcs as one subidentifier (40 × first + second), each subidentifier in base 128, high bit on all but its last byte.</summary>
    public static byte[] ObjectId(Oid oid)
    {
        var content = new List<byte>();
        AddSubidentifier(content, 40UL * oid.Arcs[0] + oid.Arcs[1]);
        for (var i = 2; i < oid.Length; i++) AddSubidentifier(content, oid.Arcs[i]);
        return Tlv(ObjectIdentifier, content.ToArray());
    }

    private static void AddSubidentifier(List<byte> to, ulong value)
    {
        Span<byte> groups = stackalloc byte[10];
        var n = 0;
        do
        {
            groups[n++] = (byte)(value & 0x7F);
            value >>= 7;
        } while (value != 0);
        for (var i = n - 1; i >= 0; i--) to.Add((byte)(groups[i] | (i > 0 ? 0x80 : 0)));
    }

    // ------------------------------------------------------------------------------------------------------------ decode

    /// <summary>Reads TLVs one after the other from part of a buffer.</summary>
    internal sealed class Reader(byte[] data, int start, int end)
    {
        private int _pos = start;

        public Reader(byte[] data) : this(data, 0, data.Length)
        {
        }

        public bool HasMore => _pos < end;

        /// <summary>The next TLV: its tag and where its content is. Moves past it.</summary>
        public (byte Tag, int Start, int Length) Next()
        {
            if (_pos >= end) throw new FormatException("BER: value expected, end of data.");
            var tag = data[_pos++];
            if ((tag & 0x1F) == 0x1F) throw new FormatException("BER: multi-byte tags aren't used by SNMP.");
            if (_pos >= end) throw new FormatException("BER: length missing.");
            int length = data[_pos++];
            if (length == 0x80) throw new FormatException("BER: indefinite lengths aren't allowed in SNMP.");
            if (length > 0x80)
            {
                var count = length & 0x7F;
                if (count > 4 || _pos + count > end) throw new FormatException("BER: length too long.");
                long l = 0;
                for (var i = 0; i < count; i++) l = (l << 8) | data[_pos++];
                if (l > int.MaxValue) throw new FormatException("BER: length too long.");
                length = (int)l;
            }
            if (length > end - _pos) throw new FormatException("BER: value runs past its container.");
            var contentStart = _pos;
            _pos += length;
            return (tag, contentStart, length);
        }

        /// <summary>The next TLV, which must have <paramref name="tag"/>: its content as a reader.</summary>
        public Reader Enter(byte tag)
        {
            var (t, s, l) = Next();
            if (t != tag) throw new FormatException($"BER: tag 0x{tag:X2} expected, 0x{t:X2} found.");
            return new Reader(data, s, s + l);
        }

        public long ReadInteger()
        {
            var (t, s, l) = Next();
            if (t != Integer) throw new FormatException($"BER: INTEGER expected, tag 0x{t:X2} found.");
            return SignedValue(data.AsSpan(s, l));
        }

        public byte[] ReadOctets()
        {
            var (t, s, l) = Next();
            if (t != OctetString) throw new FormatException($"BER: OCTET STRING expected, tag 0x{t:X2} found.");
            return data.AsSpan(s, l).ToArray();
        }

        public Oid ReadObjectId()
        {
            var (t, s, l) = Next();
            if (t != ObjectIdentifier) throw new FormatException($"BER: OBJECT IDENTIFIER expected, tag 0x{t:X2} found.");
            return ObjectIdValue(data.AsSpan(s, l));
        }

        public ReadOnlySpan<byte> Content(int start, int length) => data.AsSpan(start, length);
    }

    /// <summary>An INTEGER's content: 1 to 8 bytes, two's complement.</summary>
    public static long SignedValue(ReadOnlySpan<byte> content)
    {
        if (content.Length is 0 or > 8) throw new FormatException("BER: INTEGER of 1 to 8 bytes expected.");
        long v = (sbyte)content[0];
        for (var i = 1; i < content.Length; i++) v = (v << 8) | content[i];
        return v;
    }

    /// <summary>An unsigned type's content: up to 8 value bytes, plus a leading zero byte when the top bit is set.</summary>
    public static ulong UnsignedValue(ReadOnlySpan<byte> content)
    {
        if (content.Length == 9 && content[0] == 0) content = content[1..];
        if (content.Length is 0 or > 8) throw new FormatException("BER: unsigned value of 1 to 8 bytes expected.");
        // A top bit set without the leading zero is a negative INTEGER in strict BER, but some agents send a Counter32 that way:
        // read as unsigned, as other managers do.
        ulong v = 0;
        foreach (var b in content) v = (v << 8) | b;
        return v;
    }

    public static Oid ObjectIdValue(ReadOnlySpan<byte> content)
    {
        if (content.Length == 0) throw new FormatException("BER: empty OBJECT IDENTIFIER.");
        var subs = new List<ulong>();
        ulong v = 0;
        var bytes = 0;
        foreach (var b in content)
        {
            if (bytes == 0 && b == 0x80) throw new FormatException("BER: OBJECT IDENTIFIER subidentifier with a leading 0x80.");
            v = (v << 7) | (uint)(b & 0x7F);
            if (++bytes > 5) throw new FormatException("BER: OBJECT IDENTIFIER arc too large.");
            if ((b & 0x80) != 0) continue;
            subs.Add(v);
            v = 0;
            bytes = 0;
        }
        if (bytes != 0) throw new FormatException("BER: OBJECT IDENTIFIER ends inside a subidentifier.");
        var first = subs[0];
        var arcs = new List<uint>(subs.Count + 1);
        if (first < 40) arcs.AddRange([0, (uint)first]);
        else if (first < 80) arcs.AddRange([1, (uint)(first - 40)]);
        else arcs.AddRange([2, first - 80 <= uint.MaxValue ? (uint)(first - 80) : throw new FormatException("BER: OBJECT IDENTIFIER arc too large.")]);
        foreach (var s in subs.Skip(1)) arcs.Add(s <= uint.MaxValue ? (uint)s : throw new FormatException("BER: OBJECT IDENTIFIER arc too large."));
        try { return new Oid([.. arcs]); }
        catch (ArgumentException ex) { throw new FormatException("BER: " + ex.Message, ex); }
    }
}
