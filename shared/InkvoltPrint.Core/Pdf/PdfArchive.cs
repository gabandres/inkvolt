using System.Globalization;
using System.Text;
using System.Xml.Linq;

namespace InkvoltPrint.Core.Pdf;

/// <summary>
/// How <see cref="PdfWriter.Write"/> writes a scan: as before (null), for archiving (<see cref="PdfA"/>: PDF/A-2b), or with a
/// password (<see cref="Password"/>: AES-256). PDF/A forbids encryption, so the two never go together.
/// </summary>
public sealed record PdfWriteOptions
{
    /// <summary>PDF/A-2b (ISO 19005-2, level B): an sRGB output intent, XMP metadata that says so, a file identifier.</summary>
    public bool PdfA { get; init; }

    /// <summary>The password that opens the file (<see cref="PdfEncryption"/>), or null.</summary>
    public string? Password { get; init; }

    /// <summary>The creation date written (now when null); the same instant in the Info dictionary and the XMP packet.</summary>
    public DateTime? Now { get; init; }
}

/// <summary>PDF/A-2b's metadata for a scan (<see cref="PdfWriter"/>).</summary>
public static class PdfArchive
{
    private static readonly XNamespace Rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";
    private static readonly XNamespace Dc = "http://purl.org/dc/elements/1.1/";
    private static readonly XNamespace Pdf = "http://ns.adobe.com/pdf/1.3/";
    private static readonly XNamespace XmpNs = "http://ns.adobe.com/xap/1.0/";
    private static readonly XNamespace PdfAId = "http://www.aiim.org/pdfa/ns/id/";
    private static readonly XNamespace Meta = "adobe:ns:meta/";

    /// <summary>
    /// The XMP packet (UTF-8, uncompressed as PDF/A asks): the title, producer and creation date the Info dictionary holds
    /// (ISO 19005-2, 6.6.2.3: the same values), and pdfaid:part 2, conformance B. XML-escaped by construction.
    /// </summary>
    public static byte[] Xmp(string title, string producer, DateTime createdUtc)
    {
        var date = createdUtc.ToUniversalTime().ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", CultureInfo.InvariantCulture);
        var description = new XElement(Rdf + "Description", new XAttribute(Rdf + "about", ""),
            new XAttribute(XNamespace.Xmlns + "dc", Dc), new XAttribute(XNamespace.Xmlns + "pdf", Pdf),
            new XAttribute(XNamespace.Xmlns + "xmp", XmpNs), new XAttribute(XNamespace.Xmlns + "pdfaid", PdfAId),
            new XElement(Dc + "title", new XElement(Rdf + "Alt", new XElement(Rdf + "li", new XAttribute(XNamespace.Xml + "lang", "x-default"), OcrText.Clean(title)))),
            new XElement(Pdf + "Producer", producer),
            new XElement(XmpNs + "CreateDate", date),
            new XElement(PdfAId + "part", "2"),
            new XElement(PdfAId + "conformance", "B"));
        var root = new XElement(Meta + "xmpmeta", new XAttribute(XNamespace.Xmlns + "x", Meta),
            new XElement(Rdf + "RDF", new XAttribute(XNamespace.Xmlns + "rdf", Rdf), description));
        var text = "<?xpacket begin=\"﻿\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?>\n" + root.ToString(SaveOptions.DisableFormatting) + "\n<?xpacket end=\"w\"?>";
        return new UTF8Encoding(false).GetBytes(text);
    }
}
