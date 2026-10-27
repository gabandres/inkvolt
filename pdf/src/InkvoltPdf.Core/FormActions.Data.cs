using System.Globalization;
using System.Text;
using System.Xml;
using System.Xml.Linq;

namespace InkvoltPdf.Core;

/// <summary>
/// Form data exchange formats: FDF and XFDF (written for submits and mailForm, read for ImportData) and HTML form
/// encoding (written for submits). Field names are full names; hierarchy (a.b.c) becomes nested FDF /Kids and XFDF
/// field elements.
/// </summary>
internal static class FormData
{
    /// <param name="Values">The value (several for a multi-select list); null = the field has no value.</param>
    /// <param name="IsName">Check box / radio state: written as a PDF name in FDF.</param>
    internal sealed record Entry(string Name, IReadOnlyList<string>? Values, bool IsName);

    private sealed class Node(string part)
    {
        public string Part { get; } = part;
        public Entry? Entry { get; set; }
        public List<Node> Kids { get; } = [];
    }

    private static List<Node> Tree(IReadOnlyList<Entry> entries)
    {
        var roots = new List<Node>();
        foreach (var e in entries)
        {
            var level = roots;
            Node? node = null;
            foreach (var part in e.Name.Split('.'))
            {
                node = level.FirstOrDefault(n => n.Part == part);
                if (node is null)
                {
                    node = new Node(part);
                    level.Add(node);
                }
                level = node.Kids;
            }
            node!.Entry = e;
        }
        return roots;
    }

    // ---------------- FDF ----------------

    public static byte[] Fdf(IReadOnlyList<Entry> entries, string? file)
    {
        var sb = new StringBuilder();
        sb.Append("%FDF-1.2\n%âãÏÓ\n1 0 obj\n<< /FDF << /Fields [");
        foreach (var n in Tree(entries)) WriteNode(sb, n);
        sb.Append(']');
        if (file is not null) sb.Append(" /F ").Append(PdfString(file));
        sb.Append(" >> >>\nendobj\ntrailer\n<< /Root 1 0 R >>\n%%EOF\n");
        return Encoding.Latin1.GetBytes(sb.ToString());
    }

    private static void WriteNode(StringBuilder sb, Node n)
    {
        sb.Append("\n<< /T ").Append(PdfString(n.Part));
        if (n.Entry?.Values is { } values)
        {
            sb.Append(" /V ");
            if (values.Count == 1) sb.Append(n.Entry.IsName ? PdfName(values[0]) : PdfString(values[0]));
            else
            {
                sb.Append('[');
                foreach (var v in values) sb.Append(PdfString(v)).Append(' ');
                sb.Append(']');
            }
        }
        if (n.Kids.Count > 0)
        {
            sb.Append(" /Kids [");
            foreach (var k in n.Kids) WriteNode(sb, k);
            sb.Append(']');
        }
        sb.Append(" >>");
    }

    /// <summary>A PDF string: literal for printable ASCII, else UTF-16BE hex with a byte order mark.</summary>
    private static string PdfString(string s)
    {
        if (s.All(c => c is >= ' ' and < '\u007f' or '\n' or '\r' or '\t'))
        {
            var sb = new StringBuilder("(");
            foreach (var c in s)
                sb.Append(c switch { '(' => "\\(", ')' => "\\)", '\\' => "\\\\", '\n' => "\\n", '\r' => "\\r", '\t' => "\\t", _ => c.ToString() });
            return sb.Append(')').ToString();
        }
        return "<FEFF" + Convert.ToHexString(Encoding.BigEndianUnicode.GetBytes(s)) + ">";
    }

    private static string PdfName(string s)
    {
        var sb = new StringBuilder("/");
        foreach (var b in Encoding.UTF8.GetBytes(s))
        {
            if (b is > 0x20 and < 0x7f && "#()<>[]{}/%".IndexOf((char)b) < 0) sb.Append((char)b);
            else sb.Append('#').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    // ---------------- XFDF ----------------

    private static readonly XNamespace XfdfNs = "http://ns.adobe.com/xfdf/";

    public static byte[] Xfdf(IReadOnlyList<Entry> entries, string? file)
    {
        XElement Element(Node n)
        {
            var e = new XElement(XfdfNs + "field", new XAttribute("name", n.Part));
            foreach (var k in n.Kids) e.Add(Element(k));
            if (n.Entry?.Values is { } values)
                foreach (var v in values) e.Add(new XElement(XfdfNs + "value", v));
            return e;
        }
        var root = new XElement(XfdfNs + "xfdf", new XAttribute(XNamespace.Xml + "space", "preserve"),
            new XElement(XfdfNs + "fields", Tree(entries).Select(Element)));
        if (file is not null) root.Add(new XElement(XfdfNs + "f", new XAttribute("href", file)));
        using var ms = new MemoryStream();
        using (var w = XmlWriter.Create(ms, new XmlWriterSettings { Encoding = new UTF8Encoding(false), Indent = false }))
            new XDocument(root).Save(w);
        return ms.ToArray();
    }

    // ---------------- HTML form encoding ----------------

    public static string Html(IReadOnlyList<Entry> entries, Encoding encoding)
    {
        var sb = new StringBuilder();
        foreach (var e in entries)
            foreach (var v in e.Values ?? [""])
            {
                if (sb.Length > 0) sb.Append('&');
                sb.Append(Escape(e.Name, encoding)).Append('=').Append(Escape(v, encoding));
            }
        return sb.ToString();
    }

    private static string Escape(string s, Encoding encoding)
    {
        var sb = new StringBuilder();
        foreach (var b in encoding.GetBytes(s))
        {
            if (b is (>= (byte)'a' and <= (byte)'z') or (>= (byte)'A' and <= (byte)'Z') or (>= (byte)'0' and <= (byte)'9') || b is (byte)'-' or (byte)'_' or (byte)'.' or (byte)'~' or (byte)'*')
                sb.Append((char)b);
            else if (b == (byte)' ') sb.Append('+');
            else sb.Append('%').Append(b.ToString("X2", CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    // ---------------- Reading FDF / XFDF ----------------

    private const int MaxImportBytes = 16 * 1024 * 1024;

    /// <summary>Field values (full name → values) from FDF or XFDF data, or null if it is neither.</summary>
    public static Dictionary<string, List<string>>? Parse(byte[] data)
    {
        if (data.Length == 0 || data.Length > MaxImportBytes) return null;
        var start = data.Length >= 3 && data[0] == 0xEF && data[1] == 0xBB && data[2] == 0xBF ? 3 : 0;
        while (start < data.Length && data[start] is (byte)' ' or (byte)'\t' or (byte)'\r' or (byte)'\n') start++;
        try
        {
            if (start < data.Length && data[start] == (byte)'<') return ParseXfdf(data);
            var text = Encoding.Latin1.GetString(data);
            return text.AsSpan(start).StartsWith("%FDF") ? FdfFields(InkvoltPdf.Core.Fdf.Read(text)) : null;
        }
        catch (Exception ex) when (ex is XmlException or FormatException or InvalidOperationException or IndexOutOfRangeException or ArgumentException)
        {
            return null;
        }
    }

    private static Dictionary<string, List<string>> ParseXfdf(byte[] data)
    {
        var settings = new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null, MaxCharactersInDocument = MaxImportBytes };
        using var reader = XmlReader.Create(new MemoryStream(data), settings);
        var doc = XDocument.Load(reader);
        var result = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        void Walk(XElement e, string? parent, int depth)
        {
            if (depth > 64) return;
            foreach (var f in e.Elements().Where(x => x.Name.LocalName == "field"))
            {
                var part = (string?)f.Attribute("name") ?? "";
                var name = parent is null ? part : $"{parent}.{part}";
                var values = f.Elements().Where(x => x.Name.LocalName is "value" or "value-richtext").Select(x => x.Value).ToList();
                if (values.Count > 0) result[name] = values;
                Walk(f, name, depth + 1);
            }
        }
        foreach (var fields in doc.Descendants().Where(x => x.Name.LocalName == "fields")) Walk(fields, null, 0);
        return result;
    }

    /// <summary>An FDF file's /Fields as full name → values.</summary>
    private static Dictionary<string, List<string>> FdfFields(InkvoltPdf.Core.Fdf.Document doc)
    {
        var result = new Dictionary<string, List<string>>(StringComparer.Ordinal);
        if (doc.FdfDict() is { } fdf && doc.Resolve(fdf.GetValueOrDefault("Fields")) is List<object?> fields)
            foreach (var f in fields) Walk(f, null, 0);
        return result;

        void Walk(object? item, string? parent, int depth)
        {
            if (depth > 64 || doc.Resolve(item) is not Dictionary<string, object?> d) return;
            var part = doc.Resolve(d.GetValueOrDefault("T")) as string;
            var name = part is null ? parent : parent is null ? part : $"{parent}.{part}";
            if (name is not null && d.TryGetValue("V", out var v))
            {
                var values = doc.Resolve(v) switch
                {
                    string str => [str],
                    InkvoltPdf.Core.Fdf.Name n => [n.Value],
                    List<object?> list => list.Select(doc.Resolve).Select(x => x switch { string str => str, InkvoltPdf.Core.Fdf.Name n => n.Value, _ => null }).OfType<string>().ToList(),
                    _ => new List<string>(),
                };
                if (values.Count > 0) result[name] = values;
            }
            if (doc.Resolve(d.GetValueOrDefault("Kids")) is List<object?> kids)
                foreach (var k in kids) Walk(k, name, depth + 1);
        }
    }
}
