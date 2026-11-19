using System.Buffers.Binary;
using System.Text;

namespace InkvoltPrint.Core.Ipp;

/// <summary>
/// An IPP request (RFC 8010 §3.1) written attribute by attribute: the header, the operation group with
/// <c>attributes-charset</c>, <c>attributes-natural-language</c> and <c>printer-uri</c> first (RFC 8011 §4.1.4 wants
/// them in that order), then whatever the operation takes, a job group when one is opened, and end-of-attributes.
/// Collections are written as RFC 8010 §3.1.6 has them (begCollection, memberAttrName and its value, endCollection).
/// IPP/2.0, which IPP Everywhere printers support.
/// </summary>
public sealed class IppRequest
{
    private readonly MemoryStream _ms = new();

    public IppRequest(ushort operation, int requestId, string printerUri)
    {
        Span<byte> head = stackalloc byte[8];
        head[0] = 2; head[1] = 0;
        BinaryPrimitives.WriteUInt16BigEndian(head[2..], operation);
        BinaryPrimitives.WriteInt32BigEndian(head[4..], requestId);
        _ms.Write(head);
        _ms.WriteByte(IppCodec.OperationTag);
        Value(IppCodec.Charset, "attributes-charset", "utf-8");
        Value(IppCodec.NaturalLanguage, "attributes-natural-language", "en");
        Value(IppCodec.Uri, "printer-uri", printerUri);
    }

    /// <summary>Starts the job attributes group (Print-Job's job template attributes).</summary>
    public IppRequest JobGroup()
    {
        _ms.WriteByte(IppCodec.JobTag);
        return this;
    }

    public IppRequest Integer(string name, int value) => Value(IppCodec.Integer, name, Int32(value));
    public IppRequest Enum(string name, int value) => Value(IppCodec.Enum, name, Int32(value));
    public IppRequest Keyword(string name, string value) => Value(IppCodec.Keyword, name, value);
    public IppRequest Name(string name, string value) => Value(IppCodec.Name, name, Shorten(value));
    public IppRequest MimeMediaType(string name, string value) => Value(IppCodec.MimeMediaType, name, value);

    /// <summary>A 1setOf keyword (the first value carries the name, the others an empty one).</summary>
    public IppRequest Keywords(string name, IEnumerable<string> values)
    {
        var first = true;
        foreach (var v in values)
        {
            Value(IppCodec.Keyword, first ? name : "", v);
            first = false;
        }
        return this;
    }

    /// <summary>A collection attribute; <paramref name="members"/> writes its members.</summary>
    public IppRequest Collection(string name, Action<IppCollectionWriter> members)
    {
        Value(IppCodec.BegCollection, name, []);
        members(new IppCollectionWriter(this));
        Value(IppCodec.EndCollection, "", []);
        return this;
    }

    /// <summary>The finished request (end-of-attributes written). The document, if any, follows these bytes.</summary>
    public byte[] ToArray()
    {
        _ms.WriteByte(IppCodec.EndTag);
        return _ms.ToArray();
    }

    /// <summary>A name value is at most 255 octets (RFC 8011 §5.1.3): longer file names are cut on a character boundary.</summary>
    internal static string Shorten(string value)
    {
        if (Encoding.UTF8.GetByteCount(value) <= 255) return value;
        var cut = value;
        while (Encoding.UTF8.GetByteCount(cut) > 255) cut = cut[..^1];
        if (cut.Length > 0 && char.IsHighSurrogate(cut[^1])) cut = cut[..^1];
        return cut;
    }

    internal IppRequest Value(byte tag, string name, string value) => Value(tag, name, Encoding.UTF8.GetBytes(value));

    internal IppRequest Value(byte tag, string name, byte[] value)
    {
        var n = Encoding.UTF8.GetBytes(name);
        if (n.Length > ushort.MaxValue || value.Length > ushort.MaxValue) throw new ArgumentException("IPP value too long", nameof(value));
        Span<byte> len = stackalloc byte[2];
        _ms.WriteByte(tag);
        BinaryPrimitives.WriteUInt16BigEndian(len, (ushort)n.Length); _ms.Write(len); _ms.Write(n);
        BinaryPrimitives.WriteUInt16BigEndian(len, (ushort)value.Length); _ms.Write(len); _ms.Write(value);
        return this;
    }

    internal static byte[] Int32(int v)
    {
        var b = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(b, v);
        return b;
    }
}

/// <summary>Writes one collection's members: each is a memberAttrName, then its value with an empty name.</summary>
public sealed class IppCollectionWriter
{
    private readonly IppRequest _request;

    internal IppCollectionWriter(IppRequest request) => _request = request;

    public IppCollectionWriter Integer(string member, int value) => Member(member, IppCodec.Integer, IppRequest.Int32(value));
    public IppCollectionWriter Keyword(string member, string value) => Member(member, IppCodec.Keyword, Encoding.UTF8.GetBytes(value));

    public IppCollectionWriter Collection(string member, Action<IppCollectionWriter> members)
    {
        Member(member, IppCodec.BegCollection, []);
        members(this);
        _request.Value(IppCodec.EndCollection, "", []);
        return this;
    }

    private IppCollectionWriter Member(string member, byte tag, byte[] value)
    {
        _request.Value(IppCodec.MemberAttrName, "", member);
        _request.Value(tag, "", value);
        return this;
    }
}
