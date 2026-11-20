using System.Buffers.Binary;
using System.Globalization;
using System.Text;

namespace InkvoltPrint.Core.Ipp;

/// <summary>
/// One value of a printer attribute: its name, RFC 8010 value tag and the value as text. A collection's value is empty and its
/// members are in <see cref="Members"/> (each member a value of its own, the same name twice for a member with two values).
/// </summary>
public sealed record IppValue(string Name, byte Tag, string Value)
{
    /// <summary>A collection's members (RFC 8010 §3.1.6), in order; null for any other value.</summary>
    public IReadOnlyList<IppValue>? Members { get; init; }

    public bool Equals(IppValue? other) =>
        other is not null && Name == other.Name && Tag == other.Tag && Value == other.Value
        && (Members is null ? other.Members is null : other.Members is not null && Members.SequenceEqual(other.Members));

    public override int GetHashCode() => HashCode.Combine(Name, Tag, Value, Members?.Count);
}

/// <summary>
/// Readable form of a Get-Printer-Attributes response, for fixtures written from the specs: one value per line,
/// <c>&lt;attribute&gt; &lt;syntax&gt; &lt;value&gt;</c> (e.g. <c>marker-levels integer 72</c>); the same attribute on the next
/// line adds another value. <c>#</c> starts a comment line. <see cref="IppCodec.EncodeResponse"/> turns it into the wire format.
/// A collection opens with <c>&lt;attribute&gt; collection {</c>, has a member a line in the same form (another collection
/// too), and closes with <c>}</c> on a line of its own; <c>{}</c> is an empty one. A dateTime is written
/// <c>2026-11-20T09:30:15.0-04:00</c> (RFC 2579's fields: deciseconds, then the offset from UTC).
/// </summary>
public static class IppText
{
    private static readonly Dictionary<string, byte> Syntaxes = new(StringComparer.Ordinal)
    {
        ["integer"] = IppCodec.Integer,
        ["boolean"] = IppCodec.Boolean,
        ["enum"] = IppCodec.Enum,
        ["octetString"] = IppCodec.OctetString,
        ["dateTime"] = IppCodec.DateTime,
        ["text"] = 0x41,
        ["name"] = 0x42,
        ["keyword"] = IppCodec.Keyword,
        ["uri"] = IppCodec.Uri,
        ["uriScheme"] = 0x46,
        ["charset"] = IppCodec.Charset,
        ["naturalLanguage"] = IppCodec.NaturalLanguage,
        ["mimeMediaType"] = 0x49,
        ["resolution"] = IppCodec.Resolution,
        ["rangeOfInteger"] = IppCodec.RangeOfInteger,
        ["collection"] = IppCodec.BegCollection,
    };

    /// <summary><c>300dpi</c>, <c>600x300dpi</c> or <c>118dpcm</c> (as ipptool writes them).</summary>
    public static IppResolution? ParseResolution(string text)
    {
        var units = text.EndsWith("dpi", StringComparison.Ordinal) ? (byte)3 : text.EndsWith("dpcm", StringComparison.Ordinal) ? (byte)4 : (byte)0;
        if (units == 0) return null;
        var parts = text[..^(units == 3 ? 3 : 4)].Split('x');
        if (parts.Length is < 1 or > 2 || !int.TryParse(parts[0], NumberStyles.None, CultureInfo.InvariantCulture, out var x)) return null;
        var y = x;
        if (parts.Length == 2 && !int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out y)) return null;
        return new IppResolution(x, y, units);
    }

    /// <summary>A resolution as ipptool writes it: <c>300dpi</c>, or <c>600x300dpi</c> when the two differ.</summary>
    private static string ResolutionText(int x, int y, byte units) =>
        string.Create(CultureInfo.InvariantCulture, $"{x}{(x == y ? "" : $"x{y}")}{(units == 3 ? "dpi" : "dpcm")}");

    /// <summary><c>1-99</c>.</summary>
    public static IppRange? ParseRange(string text)
    {
        var dash = text.IndexOf('-', 1);
        return dash > 0 && int.TryParse(text[..dash], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var lo)
               && int.TryParse(text[(dash + 1)..], NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var hi) && lo <= hi
            ? new IppRange(lo, hi) : null;
    }

    /// <summary>
    /// <c>2026-11-20T09:30:15.0-04:00</c> → RFC 2579 DateAndTime's 11 octets, as they were: year, month, day, hour, minutes,
    /// seconds (up to 60, a leap second), deciseconds, the direction from UTC and its hours and minutes. Null for anything else.
    /// </summary>
    public static byte[]? ParseDateTime(string text)
    {
        if (text.Length != 27 || text[4] != '-' || text[7] != '-' || text[10] != 'T' || text[13] != ':' || text[16] != ':' || text[19] != '.'
            || text[21] is not ('+' or '-') || text[24] != ':') return null;
        int? year = Digits(0, 4), month = Digits(5, 2), day = Digits(8, 2), hour = Digits(11, 2), minute = Digits(14, 2), second = Digits(17, 2),
            tenth = Digits(20, 1), offsetHours = Digits(22, 2), offsetMinutes = Digits(25, 2);
        if (year is null || month is not (>= 1 and <= 12) || day is not (>= 1 and <= 31) || hour is not (<= 23) || minute is not (<= 59)
            || second is not (<= 60) || tenth is null || offsetHours is not (<= 14) || offsetMinutes is not (<= 59)) return null;
        var bytes = new byte[11];
        BinaryPrimitives.WriteUInt16BigEndian(bytes, (ushort)year.Value);
        (bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7]) = ((byte)month, (byte)day, (byte)hour, (byte)minute, (byte)second, (byte)tenth);
        (bytes[8], bytes[9], bytes[10]) = ((byte)text[21], (byte)offsetHours, (byte)offsetMinutes);
        return bytes;

        int? Digits(int at, int length) =>
            text.AsSpan(at, length) is var s && s.ContainsAnyExceptInRange('0', '9') ? null : int.Parse(s, NumberStyles.None, CultureInfo.InvariantCulture);
    }

    /// <summary>The other way: null for octets that aren't a DateAndTime this form holds as they are.</summary>
    private static string? DateTimeText(ReadOnlySpan<byte> v)
    {
        if (v.Length != 11) return null;
        var text = string.Create(CultureInfo.InvariantCulture,
            $"{BinaryPrimitives.ReadUInt16BigEndian(v):D4}-{v[2]:D2}-{v[3]:D2}T{v[4]:D2}:{v[5]:D2}:{v[6]:D2}.{v[7]:D1}{(char)v[8]}{v[9]:D2}:{v[10]:D2}");
        return ParseDateTime(text) is { } back && back.AsSpan().SequenceEqual(v) ? text : null;
    }

    public static IReadOnlyList<IppValue> Parse(string text)
    {
        var top = new List<IppValue>();
        // The collections open around the line being read: each one's value and its members so far.
        var open = new Stack<(IppValue Collection, List<IppValue> Members)>();
        var number = 0;
        foreach (var raw in text.Split('\n'))
        {
            number++;
            var line = raw.TrimEnd('\r').Trim();
            if (line.Length == 0 || line.StartsWith('#')) continue;
            if (line == "}")
            {
                if (open.Count == 0) throw new FormatException($"IPP text line {number}: \"}}\" closes no collection");
                var (done, members) = open.Pop();
                Add(done with { Members = members });
                continue;
            }
            var parts = line.Split(' ', 3);
            if (parts.Length < 2 || !Syntaxes.TryGetValue(parts[1], out var tag))
                throw new FormatException($"IPP text line {number}: expected \"<attribute> <syntax> <value>\"");
            var value = parts.Length == 3 ? parts[2] : "";
            if (tag == IppCodec.BegCollection)
            {
                if (value is not ("{" or "{}")) throw new FormatException($"IPP text line {number}: a collection starts with \"{{\"");
                if (open.Count >= IppCodec.MaxCollectionDepth) throw new FormatException($"IPP text line {number}: collections nested too deep");
                var collection = new IppValue(parts[0], tag, "");
                if (value == "{}") Add(collection with { Members = [] });
                else open.Push((collection, []));
                continue;
            }
            var ok = tag switch
            {
                IppCodec.Integer or IppCodec.Enum => int.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out _),
                IppCodec.Boolean => value is "true" or "false",
                IppCodec.Resolution => ParseResolution(value) is not null,
                IppCodec.RangeOfInteger => ParseRange(value) is not null,
                IppCodec.DateTime => ParseDateTime(value) is not null,
                _ => true,
            };
            if (!ok) throw new FormatException($"IPP text line {number}: \"{value}\" is not a valid {parts[1]}");
            Add(new IppValue(parts[0], tag, value));
        }
        if (open.Count > 0) throw new FormatException($"IPP text: the collection \"{open.Peek().Collection.Name}\" isn't closed");
        return top;

        void Add(IppValue v)
        {
            if (open.Count > 0) open.Peek().Members.Add(v);
            else top.Add(v);
        }
    }

    /// <summary>
    /// The other way: a Get-Printer-Attributes response's printer attributes as this text, one value per line, collections
    /// with their members nested, so a recording (<see cref="Recording.PrinterRecorder"/>) can be read and served again. Values
    /// this form can't hold are left out with a comment line naming their attributes: the with-language strings, out-of-band
    /// values and any other type (a collection keeps its other members). Line breaks inside a text value become spaces.
    /// </summary>
    public static string FromResponse(ReadOnlySpan<byte> response)
    {
        if (response.Length < 9) throw new FormatException("IPP response too short");
        var names = Syntaxes.ToDictionary(kv => kv.Value, kv => kv.Key);
        var sb = new StringBuilder();
        var skipped = new SortedSet<string>(StringComparer.Ordinal);
        var i = 8;
        byte group = 0;
        string? last = null;
        // Inside collections: each open one's current member name (null until its first memberAttrName) and whether it is
        // written (one in another group, or under a value with no member name, isn't, nor is anything in it).
        var open = new Stack<(string? Member, bool Written)>();
        while (i < response.Length)
        {
            var tag = response[i++];
            if (tag == 0x03) break; // end-of-attributes
            if (tag < 0x10)
            {
                if (open.Count > 0) throw new FormatException("IPP collection not closed");
                group = tag;
                last = null;
                continue;
            }
            if (i + 2 > response.Length) throw new FormatException("IPP response truncated");
            var nameLen = BinaryPrimitives.ReadUInt16BigEndian(response[i..]); i += 2;
            if (i + nameLen + 2 > response.Length) throw new FormatException("IPP response truncated");
            var name = Encoding.UTF8.GetString(response.Slice(i, nameLen)); i += nameLen;
            var valLen = BinaryPrimitives.ReadUInt16BigEndian(response[i..]); i += 2;
            if (i + valLen > response.Length) throw new FormatException("IPP response truncated");
            var value = response.Slice(i, valLen); i += valLen;
            if (nameLen > 0 && open.Count == 0) last = name;
            if (open.Count > 0 && tag == IppCodec.MemberAttrName)
            {
                var (_, written) = open.Pop();
                open.Push((Encoding.UTF8.GetString(value), written));
                continue;
            }
            if (tag == IppCodec.EndCollection)
            {
                if (open.Count == 0) throw new FormatException("IPP collection closed twice");
                if (open.Pop().Written) Line("}");
                continue;
            }
            // Written: in the printer group (the operation group is the codec's own) and in no collection left out.
            var writing = group == 0x04 && last is not null && (open.Count == 0 || open.Peek().Written);
            // The attribute's name at the top, the member's inside a collection (a value before any member name has none).
            var label = open.Count == 0 ? last : open.Peek().Member;
            if (tag == IppCodec.BegCollection)
            {
                if (open.Count >= IppCodec.MaxCollectionDepth) throw new FormatException("IPP collections nested too deep");
                if (writing && label is not null) Line($"{label} collection {{");
                else if (writing) skipped.Add($"{last} (part)");
                open.Push((null, writing && label is not null));
                continue;
            }
            if (!writing) continue;
            var text = names.TryGetValue(tag, out var syntax) ? Text(tag, value) : null;
            if (label is null || text is null)
            {
                skipped.Add(open.Count == 0 ? last! : $"{last} (part)");
                continue;
            }
            Line($"{label} {syntax} {text}");
        }
        if (open.Count > 0) throw new FormatException("IPP collection not closed");
        if (skipped.Count > 0) sb.Insert(0, $"# Not kept (no IppText form): {string.Join(", ", skipped)}\n");
        return sb.ToString();

        void Line(string text) => sb.Append(' ', 2 * open.Count).Append(text).Append('\n');
    }

    /// <summary>One value as this form writes it; null when it can't hold it as it is.</summary>
    private static string? Text(byte tag, ReadOnlySpan<byte> value) => tag switch
    {
        IppCodec.Integer or IppCodec.Enum when value.Length == 4 => BinaryPrimitives.ReadInt32BigEndian(value).ToString(CultureInfo.InvariantCulture),
        IppCodec.Boolean when value.Length == 1 => value[0] != 0 ? "true" : "false",
        IppCodec.Resolution when value.Length == 9 && value[8] is 3 or 4 => ResolutionText(
            BinaryPrimitives.ReadInt32BigEndian(value), BinaryPrimitives.ReadInt32BigEndian(value[4..]), value[8]),
        IppCodec.RangeOfInteger when value.Length == 8 => string.Create(CultureInfo.InvariantCulture,
            $"{BinaryPrimitives.ReadInt32BigEndian(value)}-{BinaryPrimitives.ReadInt32BigEndian(value[4..])}"),
        IppCodec.DateTime => DateTimeText(value),
        IppCodec.Integer or IppCodec.Enum or IppCodec.Boolean or IppCodec.Resolution or IppCodec.RangeOfInteger => null,
        // A text that reads back as it was: one line, no edge spaces, and not a lone "{" (a collection's opening) or "}".
        _ => Encoding.UTF8.GetString(value).ReplaceLineEndings(" ").Trim() is var t && t is not ("{" or "}" or "{}") ? t : null,
    };
}
