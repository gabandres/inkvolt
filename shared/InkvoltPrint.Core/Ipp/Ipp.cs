using System.Buffers.Binary;
using System.Text;

namespace InkvoltPrint.Core.Ipp;

/// <summary>Minimal IPP encoding (RFC 8010): enough for Get-Printer-Attributes and Identify-Printer.</summary>
public static class IppCodec
{
    public const ushort GetPrinterAttributes = 0x000B;

    /// <summary>PWG 5100.13 §4.1 (IPP Job and Printer Extensions, Set 3): the printer shows where it is (lights, sound, panel).</summary>
    public const ushort IdentifyPrinter = 0x003C;

    /// <summary>RFC 8011 operation ids: Print-Job, Cancel-Job, Get-Job-Attributes, Get-Jobs.</summary>
    public const ushort PrintJob = 0x0002, CancelJob = 0x0008, GetJobAttributes = 0x0009, GetJobs = 0x000A;

    internal const byte OperationTag = 0x01, JobTag = 0x02, EndTag = 0x03, PrinterTag = 0x04;
    internal const byte Integer = 0x21, Boolean = 0x22, Enum = 0x23, OctetString = 0x30;
    internal const byte Charset = 0x47, NaturalLanguage = 0x48, Uri = 0x45, Keyword = 0x44, Name = 0x42;
    internal const byte DateTime = 0x31, Resolution = 0x32, RangeOfInteger = 0x33, BegCollection = 0x34, EndCollection = 0x37;
    internal const byte Text = 0x41, MimeMediaType = 0x49, MemberAttrName = 0x4A;

    public static byte[] EncodeGetPrinterAttributes(string printerUri, IEnumerable<string> requested, int requestId = 1)
    {
        using var ms = new MemoryStream();
        Span<byte> head = stackalloc byte[8];
        head[0] = 1; head[1] = 1;
        BinaryPrimitives.WriteUInt16BigEndian(head[2..], GetPrinterAttributes);
        BinaryPrimitives.WriteInt32BigEndian(head[4..], requestId);
        ms.Write(head);
        ms.WriteByte(OperationTag);
        WriteAttr(ms, Charset, "attributes-charset", "utf-8");
        WriteAttr(ms, NaturalLanguage, "attributes-natural-language", "en");
        WriteAttr(ms, Uri, "printer-uri", printerUri);
        var first = true;
        foreach (var r in requested)
        {
            WriteAttr(ms, Keyword, first ? "requested-attributes" : "", r);
            first = false;
        }
        ms.WriteByte(EndTag);
        return ms.ToArray();
    }

    /// <summary>
    /// An Identify-Printer request (PWG 5100.13 §4.1.1): the operation attributes in the order the spec lists them,
    /// <c>requesting-user-name</c> when given (SHOULD) and <c>identify-actions</c> when any are chosen (the printer's
    /// <c>identify-actions-default</c> otherwise). Sent as IPP/2.0: JPS3 extends IPP/2.0, which IPP Everywhere printers support.
    /// </summary>
    public static byte[] EncodeIdentifyPrinter(string printerUri, string? userName, IEnumerable<string> actions, int requestId = 1)
    {
        using var ms = new MemoryStream();
        Span<byte> head = stackalloc byte[8];
        head[0] = 2; head[1] = 0;
        BinaryPrimitives.WriteUInt16BigEndian(head[2..], IdentifyPrinter);
        BinaryPrimitives.WriteInt32BigEndian(head[4..], requestId);
        ms.Write(head);
        ms.WriteByte(OperationTag);
        WriteAttr(ms, Charset, "attributes-charset", "utf-8");
        WriteAttr(ms, NaturalLanguage, "attributes-natural-language", "en");
        WriteAttr(ms, Uri, "printer-uri", printerUri);
        if (!string.IsNullOrEmpty(userName)) WriteAttr(ms, Name, "requesting-user-name", userName);
        var first = true;
        foreach (var a in actions)
        {
            WriteAttr(ms, Keyword, first ? "identify-actions" : "", a);
            first = false;
        }
        ms.WriteByte(EndTag);
        return ms.ToArray();
    }

    /// <summary>
    /// Decodes the printer-attributes group (or <paramref name="group"/>: 0x02 for a job's). Values: string, int, bool,
    /// <see cref="IppCollection"/>, <see cref="IppResolution"/>, <see cref="IppRange"/>, <see cref="DateTimeOffset"/>, or
    /// byte[] for other types. Several groups with the same tag (Get-Jobs' jobs) are merged; <see cref="DecodeGroups"/> keeps them apart.
    /// </summary>
    public static IppResponse Decode(ReadOnlySpan<byte> b, byte group = PrinterTag)
    {
        var (status, groups) = DecodeGroups(b);
        var attrs = new Dictionary<string, List<object>>(StringComparer.Ordinal);
        foreach (var (tag, g) in groups)
            if (tag == group)
                foreach (var (name, values) in g)
                    if (attrs.TryGetValue(name, out var list)) list.AddRange(values);
                    else attrs[name] = values;
        return new IppResponse(status, attrs);
    }

    /// <summary>Most collections nested in one another (media-col-database's media-size is two deep).</summary>
    public const int MaxCollectionDepth = 8;

    /// <summary>
    /// Every attribute group of a response in order (tag and attributes), collections included (RFC 8010 §3.1.6:
    /// begCollection, memberAttrName and its value, endCollection). A truncated reply, a collection nested deeper than
    /// <see cref="MaxCollectionDepth"/> or one left open is a <see cref="FormatException"/>, never an index out of range.
    /// </summary>
    public static (ushort Status, IReadOnlyList<(byte Tag, Dictionary<string, List<object>> Attributes)> Groups) DecodeGroups(ReadOnlySpan<byte> b)
    {
        if (b.Length < 9) throw new FormatException("IPP response too short");
        var status = BinaryPrimitives.ReadUInt16BigEndian(b[2..]);
        var groups = new List<(byte, Dictionary<string, List<object>>)>();
        Dictionary<string, List<object>>? attrs = null;
        var i = 8;
        string? last = null;
        var open = new Stack<(IppCollection Collection, string? Member)>();
        while (i < b.Length)
        {
            var tag = b[i++];
            if (tag == EndTag) break;
            if (tag < 0x10)
            {
                if (open.Count > 0) throw new FormatException("IPP collection not closed");
                attrs = new Dictionary<string, List<object>>(StringComparer.Ordinal);
                groups.Add((tag, attrs));
                last = null;
                continue;
            }
            // A truncated or corrupt reply must surface as FormatException, never IndexOutOfRange.
            if (i + 2 > b.Length) throw new FormatException("IPP response truncated");
            var nameLen = BinaryPrimitives.ReadUInt16BigEndian(b[i..]); i += 2;
            if (i + nameLen + 2 > b.Length) throw new FormatException("IPP response truncated");
            var name = Encoding.UTF8.GetString(b.Slice(i, nameLen)); i += nameLen;
            var valLen = BinaryPrimitives.ReadUInt16BigEndian(b[i..]); i += 2;
            if (i + valLen > b.Length) throw new FormatException("IPP response truncated");
            var val = b.Slice(i, valLen); i += valLen;
            if (open.Count == 0 && nameLen > 0) last = name;
            if (open.Count > 0 && tag == MemberAttrName)
            {
                var (c, _) = open.Pop();
                open.Push((c, Encoding.UTF8.GetString(val)));
                continue;
            }
            if (tag == EndCollection)
            {
                if (open.Count == 0) throw new FormatException("IPP collection closed twice");
                var (done, _) = open.Pop();
                Add(done);
                continue;
            }
            if (tag == BegCollection)
            {
                if (open.Count >= MaxCollectionDepth) throw new FormatException("IPP collections nested too deep");
                open.Push((new IppCollection(), null));
                continue;
            }
            Add(tag switch
            {
                Integer or Enum when valLen == 4 => BinaryPrimitives.ReadInt32BigEndian(val),
                Boolean when valLen == 1 => val[0] != 0,
                >= 0x40 and <= 0x4F => Encoding.UTF8.GetString(val),
                // printer-alert (PWG 5100.9) is an octetString of US-ASCII "code=…;severity=…" text.
                OctetString => Encoding.UTF8.GetString(val),
                Resolution when valLen == 9 => new IppResolution(BinaryPrimitives.ReadInt32BigEndian(val), BinaryPrimitives.ReadInt32BigEndian(val[4..]), val[8]),
                RangeOfInteger when valLen == 8 => new IppRange(BinaryPrimitives.ReadInt32BigEndian(val), BinaryPrimitives.ReadInt32BigEndian(val[4..])),
                DateTime when valLen == 11 && ReadDateTime(val) is { } when => when,
                _ => val.ToArray(),
            });
        }
        if (open.Count > 0) throw new FormatException("IPP collection not closed");
        return (status, groups);

        void Add(object value)
        {
            if (open.Count > 0)
            {
                var (parent, member) = open.Peek();
                if (member is not null) parent.Add(member, value);
                return;
            }
            if (last is null || attrs is null) return;
            if (!attrs.TryGetValue(last, out var list)) attrs[last] = list = [];
            list.Add(value);
        }
    }

    /// <summary>RFC 2579 DateAndTime (RFC 8010 §3.9): year, month, day, hour, minutes, seconds, deciseconds, UTC direction, hours, minutes.</summary>
    private static DateTimeOffset? ReadDateTime(ReadOnlySpan<byte> v)
    {
        int year = BinaryPrimitives.ReadUInt16BigEndian(v), month = v[2], day = v[3], hour = v[4], minute = v[5], second = v[6];
        if (year is < 1970 or > 9999 || month is < 1 or > 12 || day < 1 || day > System.DateTime.DaysInMonth(year, month)
            || hour > 23 || minute > 59 || second > 60 || v[9] > 14 || v[10] > 59 || v[8] is not ((byte)'+' or (byte)'-')) return null;
        var offset = TimeSpan.FromMinutes((v[9] * 60 + v[10]) * (v[8] == '-' ? -1 : 1));
        return new DateTimeOffset(year, month, day, hour, minute, Math.Min(second, 59), offset);
    }

    /// <summary>Operation id and request id of an IPP request (for <see cref="Net.FixtureHandler"/>).</summary>
    public static (ushort Operation, int RequestId) ReadRequestHeader(ReadOnlySpan<byte> b) =>
        b.Length < 8 ? throw new FormatException("IPP request too short")
            : (BinaryPrimitives.ReadUInt16BigEndian(b[2..]), BinaryPrimitives.ReadInt32BigEndian(b[4..]));

    /// <summary>
    /// A Get-Printer-Attributes response carrying <paramref name="printerAttributes"/> (consecutive values with the same
    /// name form one multi-valued attribute). Demo mode and tests serve printers written in <see cref="IppText"/> with it.
    /// </summary>
    public static byte[] EncodeResponse(ushort status, int requestId, IEnumerable<IppValue> printerAttributes) =>
        EncodeResponse(status, requestId, printerAttributes, PrinterTag);

    /// <summary>The same with the attributes in another group: <see cref="JobTag"/> for a job's (Print-Job, Get-Job-Attributes).</summary>
    public static byte[] EncodeResponse(ushort status, int requestId, IEnumerable<IppValue> printerAttributes, byte group)
    {
        using var ms = new MemoryStream();
        Span<byte> head = stackalloc byte[8];
        head[0] = 1; head[1] = 1;
        BinaryPrimitives.WriteUInt16BigEndian(head[2..], status);
        BinaryPrimitives.WriteInt32BigEndian(head[4..], requestId);
        ms.Write(head);
        ms.WriteByte(OperationTag);
        WriteAttr(ms, Charset, "attributes-charset", "utf-8");
        WriteAttr(ms, NaturalLanguage, "attributes-natural-language", "en");
        ms.WriteByte(group);
        string? previous = null;
        foreach (var a in printerAttributes)
        {
            var name = a.Name == previous ? "" : a.Name;
            previous = a.Name;
            WriteAttr(ms, a.Tag, name, a.Tag switch
            {
                Integer or Enum => Int32(int.Parse(a.Value, System.Globalization.CultureInfo.InvariantCulture)),
                Boolean => [a.Value == "true" ? (byte)1 : (byte)0],
                Resolution when IppText.ParseResolution(a.Value) is { } r => [.. Int32(r.X), .. Int32(r.Y), r.Units],
                RangeOfInteger when IppText.ParseRange(a.Value) is { } r => [.. Int32(r.Lower), .. Int32(r.Upper)],
                _ => Encoding.UTF8.GetBytes(a.Value),
            });
        }
        ms.WriteByte(EndTag);
        return ms.ToArray();
    }

    private static byte[] Int32(int v)
    {
        var b = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(b, v);
        return b;
    }

    private static void WriteAttr(Stream s, byte tag, string name, string value) => WriteAttr(s, tag, name, Encoding.UTF8.GetBytes(value));

    private static void WriteAttr(Stream s, byte tag, string name, byte[] v)
    {
        var n = Encoding.UTF8.GetBytes(name);
        Span<byte> len = stackalloc byte[2];
        s.WriteByte(tag);
        BinaryPrimitives.WriteUInt16BigEndian(len, (ushort)n.Length); s.Write(len); s.Write(n);
        BinaryPrimitives.WriteUInt16BigEndian(len, (ushort)v.Length); s.Write(len); s.Write(v);
    }
}

public sealed record IppResponse(ushort StatusCode, IReadOnlyDictionary<string, List<object>> Attributes)
{
    public bool Ok => StatusCode < 0x0100;
    public string? Str(string name) => Attributes.TryGetValue(name, out var v) ? v.FirstOrDefault() as string : null;
    public int? Int(string name) => Attributes.TryGetValue(name, out var v) && v.FirstOrDefault() is int i ? i : null;
    public IEnumerable<string> Strs(string name) => Attributes.TryGetValue(name, out var v) ? v.OfType<string>() : [];
    public IEnumerable<int> Ints(string name) => Attributes.TryGetValue(name, out var v) ? v.OfType<int>() : [];
    public IEnumerable<IppCollection> Collections(string name) => Attributes.TryGetValue(name, out var v) ? v.OfType<IppCollection>() : [];
    public IEnumerable<IppResolution> Resolutions(string name) => Attributes.TryGetValue(name, out var v) ? v.OfType<IppResolution>() : [];
    public IppRange? Range(string name) => Attributes.TryGetValue(name, out var v) && v.FirstOrDefault() is IppRange r ? r : null;
}

/// <summary>A collection value (RFC 8010 §3.1.6): its members by name, each with one or more values (as <see cref="IppResponse"/>'s).</summary>
public sealed class IppCollection
{
    /// <summary>Most members kept in one collection: a real one has a dozen.</summary>
    public const int MaxMembers = 256;

    private readonly Dictionary<string, List<object>> _members = new(StringComparer.Ordinal);

    public IReadOnlyDictionary<string, List<object>> Members => _members;

    internal void Add(string member, object value)
    {
        if (!_members.TryGetValue(member, out var list))
        {
            if (_members.Count >= MaxMembers) return;
            _members[member] = list = [];
        }
        if (list.Count < MaxMembers) list.Add(value);
    }

    public string? Str(string name) => _members.TryGetValue(name, out var v) ? v.FirstOrDefault() as string : null;
    public int? Int(string name) => _members.TryGetValue(name, out var v) && v.FirstOrDefault() is int i ? i : null;
    public IppCollection? Collection(string name) => _members.TryGetValue(name, out var v) ? v.FirstOrDefault() as IppCollection : null;
    public bool Has(string name) => _members.ContainsKey(name);
}

/// <summary>A resolution value: cross feed, feed, units (3 dots per inch, 4 per centimetre).</summary>
public readonly record struct IppResolution(int X, int Y, byte Units)
{
    /// <summary>Dots per inch across, null for another unit or a value that isn't one.</summary>
    public int? Dpi => Units == 3 && X == Y && X is > 0 and <= 4800 ? X : Units == 4 && X == Y && X is > 0 and <= 1900 ? (int)Math.Round(X * 2.54) : null;
}

/// <summary>A rangeOfInteger value.</summary>
public readonly record struct IppRange(int Lower, int Upper);

