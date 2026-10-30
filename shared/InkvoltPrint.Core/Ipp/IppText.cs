using System.Buffers.Binary;
using System.Globalization;
using System.Text;

namespace InkvoltPrint.Core.Ipp;

/// <summary>One value of a printer attribute: its name, RFC 8010 value tag and the value as text.</summary>
public sealed record IppValue(string Name, byte Tag, string Value);

/// <summary>
/// Readable form of a Get-Printer-Attributes response, for fixtures written from the specs: one value per line,
/// <c>&lt;attribute&gt; &lt;syntax&gt; &lt;value&gt;</c> (e.g. <c>marker-levels integer 72</c>); the same attribute on the next
/// line adds another value. <c>#</c> starts a comment line. <see cref="IppCodec.EncodeResponse"/> turns it into the wire format.
/// </summary>
public static class IppText
{
    private static readonly Dictionary<string, byte> Syntaxes = new(StringComparer.Ordinal)
    {
        ["integer"] = IppCodec.Integer,
        ["boolean"] = IppCodec.Boolean,
        ["enum"] = IppCodec.Enum,
        ["octetString"] = IppCodec.OctetString,
        ["text"] = 0x41,
        ["name"] = 0x42,
        ["keyword"] = IppCodec.Keyword,
        ["uri"] = IppCodec.Uri,
        ["uriScheme"] = 0x46,
        ["charset"] = IppCodec.Charset,
        ["naturalLanguage"] = IppCodec.NaturalLanguage,
        ["mimeMediaType"] = 0x49,
    };

    public static IReadOnlyList<IppValue> Parse(string text)
    {
        var values = new List<IppValue>();
        var number = 0;
        foreach (var raw in text.Split('\n'))
        {
            number++;
            var line = raw.TrimEnd('\r');
            if (line.Trim().Length == 0 || line.TrimStart().StartsWith('#')) continue;
            var parts = line.Trim().Split(' ', 3);
            if (parts.Length < 2 || !Syntaxes.TryGetValue(parts[1], out var tag))
                throw new FormatException($"IPP text line {number}: expected \"<attribute> <syntax> <value>\"");
            var value = parts.Length == 3 ? parts[2] : "";
            var ok = tag switch
            {
                IppCodec.Integer or IppCodec.Enum => int.TryParse(value, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out _),
                IppCodec.Boolean => value is "true" or "false",
                _ => true,
            };
            if (!ok) throw new FormatException($"IPP text line {number}: \"{value}\" is not a valid {parts[1]}");
            values.Add(new IppValue(parts[0], tag, value));
        }
        return values;
    }

    /// <summary>
    /// The other way: a Get-Printer-Attributes response's printer attributes as this text, one value per line, so a recording
    /// (<see cref="Recording.PrinterRecorder"/>) can be read and served again. Values this form can't hold are left out with a
    /// comment line naming them: collections (<c>media-col-database</c>), dateTime, resolution, rangeOfInteger, the
    /// with-language strings and out-of-band values. Line breaks inside a text value become spaces.
    /// </summary>
    public static string FromResponse(ReadOnlySpan<byte> response)
    {
        if (response.Length < 9) throw new FormatException("IPP response too short");
        var names = Syntaxes.ToDictionary(kv => kv.Value, kv => kv.Key);
        var sb = new StringBuilder();
        var skipped = new SortedSet<string>(StringComparer.Ordinal);
        var i = 8;
        byte group = 0;
        var depth = 0;
        string? last = null;
        while (i < response.Length)
        {
            var tag = response[i++];
            if (tag == 0x03) break; // end-of-attributes
            if (tag < 0x10) { group = tag; last = null; continue; }
            if (i + 2 > response.Length) throw new FormatException("IPP response truncated");
            var nameLen = BinaryPrimitives.ReadUInt16BigEndian(response[i..]); i += 2;
            if (i + nameLen + 2 > response.Length) throw new FormatException("IPP response truncated");
            var name = Encoding.UTF8.GetString(response.Slice(i, nameLen)); i += nameLen;
            var valLen = BinaryPrimitives.ReadUInt16BigEndian(response[i..]); i += 2;
            if (i + valLen > response.Length) throw new FormatException("IPP response truncated");
            var value = response.Slice(i, valLen); i += valLen;
            if (nameLen > 0 && depth == 0) last = name;
            // A collection (begCollection 0x34 … endCollection 0x37) is left out whole, members and nested collections too.
            if (tag == 0x34) { depth++; if (group == 0x04 && last is not null) skipped.Add(last); continue; }
            if (tag == 0x37) { depth = Math.Max(0, depth - 1); continue; }
            if (depth > 0 || group != 0x04 || last is null) continue;
            if (!names.TryGetValue(tag, out var syntax)) { skipped.Add(last); continue; }
            var text = tag switch
            {
                IppCodec.Integer or IppCodec.Enum when valLen == 4 => BinaryPrimitives.ReadInt32BigEndian(value).ToString(CultureInfo.InvariantCulture),
                IppCodec.Boolean when valLen == 1 => value[0] != 0 ? "true" : "false",
                IppCodec.Integer or IppCodec.Enum or IppCodec.Boolean => null,
                _ => Encoding.UTF8.GetString(value).ReplaceLineEndings(" ").Trim(),
            };
            if (text is null) { skipped.Add(last); continue; }
            sb.Append(last).Append(' ').Append(syntax).Append(' ').Append(text).Append('\n');
        }
        if (skipped.Count > 0) sb.Insert(0, $"# Not kept (no IppText form): {string.Join(", ", skipped)}\n");
        return sb.ToString();
    }
}
