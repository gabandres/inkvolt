using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Xml;

namespace InkvoltPrint.Core.Office;

/// <summary>
/// Package parts shared by the Office Open XML writers: Inkvolt PDF's .docx, .pptx and .xlsx exports and Inkvolt Print's scans
/// to Word (<see cref="ScanDocx"/>).
/// </summary>
internal static class OpenXmlParts
{
    private static readonly XmlWriterSettings Settings = new() { Encoding = new UTF8Encoding(false), Indent = false };

    public static void Entry(ZipArchive zip, string name, Action<XmlWriter> write)
    {
        var entry = zip.CreateEntry(name, CompressionLevel.Optimal);
        using var s = entry.Open();
        using var w = XmlWriter.Create(s, Settings);
        w.WriteStartDocument(true);
        write(w);
        w.WriteEndDocument();
    }

    /// <summary>At most the first <paramref name="max"/> characters, never splitting a surrogate pair (an emoji) in two.</summary>
    public static string Cut(string text, int max)
    {
        if (text.Length <= max) return text;
        if (max <= 0) return "";
        return char.IsHighSurrogate(text[max - 1]) ? text[..(max - 1)] : text[..max];
    }

    /// <summary>Text with the characters XML can't hold (control characters, lone surrogates) dropped; tabs and newlines kept.</summary>
    public static string Clean(string text)
    {
        StringBuilder? sb = null;
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            var ok = c is '\t' or '\n' || (c >= 0x20 && c != '￾' && c != '￿' && !char.IsSurrogate(c));
            if (char.IsHighSurrogate(c) && i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
            {
                sb?.Append(c).Append(text[i + 1]);
                i++;
                continue;
            }
            if (ok)
            {
                sb?.Append(c);
                continue;
            }
            sb ??= new StringBuilder(text, 0, i, text.Length);
            if (c == '\r') sb.Append('\n');
        }
        return sb?.ToString() ?? text;
    }

    /// <summary>A part's relationships; <paramref name="hyperlinks"/>: web addresses it links to (outside the package).</summary>
    public static void Relationships(XmlWriter w, IEnumerable<(string Id, string Type, string Target)> rels,
        IEnumerable<(string Id, string Uri)>? hyperlinks = null)
    {
        const string ns = "http://schemas.openxmlformats.org/package/2006/relationships";
        w.WriteStartElement("Relationships", ns);
        foreach (var (id, type, target) in rels)
        {
            w.WriteStartElement("Relationship", ns);
            w.WriteAttributeString("Id", id);
            w.WriteAttributeString("Type", type);
            w.WriteAttributeString("Target", target);
            w.WriteEndElement();
        }
        foreach (var (id, uri) in hyperlinks ?? [])
        {
            w.WriteStartElement("Relationship", ns);
            w.WriteAttributeString("Id", id);
            w.WriteAttributeString("Type", "http://schemas.openxmlformats.org/officeDocument/2006/relationships/hyperlink");
            w.WriteAttributeString("Target", uri);
            w.WriteAttributeString("TargetMode", "External");
            w.WriteEndElement();
        }
        w.WriteEndElement();
    }

    public static void ContentTypes(XmlWriter w, IEnumerable<(string Part, string Type)> overrides)
    {
        const string ns = "http://schemas.openxmlformats.org/package/2006/content-types";
        w.WriteStartElement("Types", ns);
        foreach (var (ext, type) in new[]
                 {
                     ("rels", "application/vnd.openxmlformats-package.relationships+xml"), ("xml", "application/xml"),
                     ("png", "image/png"), ("jpeg", "image/jpeg"),
                 })
        {
            w.WriteStartElement("Default", ns);
            w.WriteAttributeString("Extension", ext);
            w.WriteAttributeString("ContentType", type);
            w.WriteEndElement();
        }
        foreach (var (part, type) in overrides.Concat(
                 [
                     ("/docProps/core.xml", "application/vnd.openxmlformats-package.core-properties+xml"),
                     ("/docProps/app.xml", "application/vnd.openxmlformats-officedocument.extended-properties+xml"),
                 ]))
        {
            w.WriteStartElement("Override", ns);
            w.WriteAttributeString("PartName", part);
            w.WriteAttributeString("ContentType", type);
            w.WriteEndElement();
        }
        w.WriteEndElement();
    }

    public static void CoreProperties(XmlWriter w, string? title)
    {
        const string cp = "http://schemas.openxmlformats.org/package/2006/metadata/core-properties";
        const string dc = "http://purl.org/dc/elements/1.1/";
        const string dcterms = "http://purl.org/dc/terms/";
        const string xsi = "http://www.w3.org/2001/XMLSchema-instance";
        w.WriteStartElement("cp", "coreProperties", cp);
        w.WriteAttributeString("xmlns", "dc", null, dc);
        w.WriteAttributeString("xmlns", "dcterms", null, dcterms);
        w.WriteAttributeString("xmlns", "xsi", null, xsi);
        if (!string.IsNullOrWhiteSpace(title)) w.WriteElementString("dc", "title", dc, Clean(title));
        w.WriteStartElement("dcterms", "created", dcterms);
        w.WriteAttributeString("xsi", "type", xsi, "dcterms:W3CDTF");
        w.WriteString(DateTime.UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ", CultureInfo.InvariantCulture));
        w.WriteEndElement();
        w.WriteEndElement();
    }

    /// <summary>docProps/app.xml: the application that wrote the file.</summary>
    public static void AppProperties(XmlWriter w, string application)
    {
        const string ns = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties";
        w.WriteStartElement("Properties", ns);
        w.WriteElementString("Application", ns, application);
        w.WriteEndElement();
    }
}
