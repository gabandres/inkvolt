using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Xml;
using InkvoltPrint.Core.Pdf;

namespace InkvoltPrint.Core.Office;

/// <summary>
/// One scanned page as a document holds it (roadmap 4.14): its recognized words, and the pictures that go in instead of text
/// (photos found on the glass, or the page itself when no text was read from it). JPEGs at <see cref="Dpi"/>.
/// </summary>
public sealed record ScanDocPage(IReadOnlyList<OcrWord>? Words, int Dpi, IReadOnlyList<byte[]> Pictures)
{
    /// <summary>The page's paragraphs, from its words (<see cref="PageText.Paragraphs"/>).</summary>
    public List<TextParagraph> Paragraphs() => PageText.Paragraphs(PageText.Lines(Words));
}

/// <summary>
/// A scan saved as a Word document (.docx): each page's text as paragraphs (a heading in Heading 1), its pictures inline at
/// their size (smaller to fit the page), each scanned page from a new page. Simple on purpose: no columns, tables or fonts,
/// so the text is easy to edit. The parts are written by the shared <see cref="OpenXmlParts"/>, as Inkvolt PDF's export.
/// </summary>
public static class ScanDocx
{
    private const string W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    private const string R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing";
    private const string A = "http://schemas.openxmlformats.org/drawingml/2006/main";
    private const string Pic = "http://schemas.openxmlformats.org/drawingml/2006/picture";
    private const string RelBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/";

    /// <summary>The room a picture may take (inches): a letter or A4 page inside Word's usual margins.</summary>
    public const double MaxWidth = 6.3, MaxHeight = 8.9;

    private const long Emu = 914400; // per inch

    /// <summary>At most this many paragraphs and pictures go in, whatever the pages hold.</summary>
    public const int MaxParagraphs = 100_000, MaxPictures = 2000;

    public static void Write(Stream output, IReadOnlyList<ScanDocPage> pages, string? title)
    {
        using var zip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true);
        var rels = new List<(string Id, string Type, string Target)> { ("rIdStyles", RelBase + "styles", "styles.xml") };
        // The pictures first, each stored once as it is (JPEG), with its size on the page.
        var pictures = new List<List<(string Id, long Cx, long Cy)>>();
        var count = 0;
        foreach (var page in pages)
        {
            var placed = new List<(string Id, long Cx, long Cy)>();
            foreach (var jpeg in page.Pictures)
            {
                if (count >= MaxPictures || Size(jpeg, page.Dpi) is not { } size) continue;
                count++;
                var target = $"media/image{count}.jpeg";
                var entry = zip.CreateEntry("word/" + target, CompressionLevel.NoCompression); // already compressed
                using (var s = entry.Open()) s.Write(jpeg);
                var id = $"rIdImg{count}";
                rels.Add((id, RelBase + "image", target));
                placed.Add((id, size.Cx, size.Cy));
            }
            pictures.Add(placed);
        }
        OpenXmlParts.Entry(zip, "word/document.xml", w => Document(w, pages, pictures));
        OpenXmlParts.Entry(zip, "word/styles.xml", Styles);
        OpenXmlParts.Entry(zip, "word/_rels/document.xml.rels", w => OpenXmlParts.Relationships(w, rels));
        OpenXmlParts.Entry(zip, "_rels/.rels", w => OpenXmlParts.Relationships(w,
        [
            ("rId1", RelBase + "officeDocument", "word/document.xml"),
            ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
            ("rId3", RelBase + "extended-properties", "docProps/app.xml"),
        ]));
        OpenXmlParts.Entry(zip, "docProps/core.xml", w => OpenXmlParts.CoreProperties(w, title));
        OpenXmlParts.Entry(zip, "docProps/app.xml", w => OpenXmlParts.AppProperties(w, "Inkvolt Print"));
        OpenXmlParts.Entry(zip, "[Content_Types].xml", w => OpenXmlParts.ContentTypes(w,
        [
            ("/word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"),
            ("/word/styles.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"),
        ]));
    }

    /// <summary>A picture's size in EMU: its pixels at <paramref name="dpi"/>, made smaller to fit the room; null when it isn't a JPEG.</summary>
    internal static (long Cx, long Cy)? Size(byte[] jpeg, int dpi)
    {
        int w, h;
        try { (w, h, _) = PdfWriter.JpegInfo(jpeg); }
        catch (FormatException) { return null; }
        if (w < 1 || h < 1) return null;
        var (inW, inH) = (w / (double)Math.Max(1, dpi), h / (double)Math.Max(1, dpi));
        var scale = Math.Min(1, Math.Min(MaxWidth / inW, MaxHeight / inH));
        return ((long)Math.Round(inW * scale * Emu), (long)Math.Round(inH * scale * Emu));
    }

    private static void Document(XmlWriter w, IReadOnlyList<ScanDocPage> pages, List<List<(string Id, long Cx, long Cy)>> pictures)
    {
        w.WriteStartElement("w", "document", W);
        w.WriteAttributeString("xmlns", "r", null, R);
        w.WriteAttributeString("xmlns", "wp", null, WP);
        w.WriteAttributeString("xmlns", "a", null, A);
        w.WriteAttributeString("xmlns", "pic", null, Pic);
        w.WriteStartElement("body", W);
        var paragraphs = 0;
        var drawing = 0;
        var any = false;
        for (var i = 0; i < pages.Count; i++)
        {
            var first = true;
            // A paragraph: in Heading 1 when it is a heading, and the page's first from a new page in Word (pStyle comes first in pPr).
            void Start(bool heading)
            {
                w.WriteStartElement("p", W);
                var breaks = first && any; // not before the document's first paragraph
                if (heading || breaks)
                {
                    w.WriteStartElement("pPr", W);
                    if (heading)
                    {
                        w.WriteStartElement("pStyle", W);
                        w.WriteAttributeString("val", W, "Heading1");
                        w.WriteEndElement();
                    }
                    if (breaks)
                    {
                        w.WriteStartElement("pageBreakBefore", W);
                        w.WriteEndElement();
                    }
                    w.WriteEndElement();
                }
                first = false;
                any = true;
            }
            foreach (var para in pages[i].Paragraphs())
            {
                if (++paragraphs > MaxParagraphs) break;
                Start(para.Heading);
                w.WriteStartElement("r", W);
                w.WriteStartElement("t", W);
                w.WriteAttributeString("xml", "space", null, "preserve");
                w.WriteString(OpenXmlParts.Clean(para.Text).Replace('\t', ' ').Replace('\n', ' '));
                w.WriteEndElement();
                w.WriteEndElement();
                w.WriteEndElement(); // p
            }
            foreach (var (id, cx, cy) in pictures[i])
            {
                Start(heading: false);
                w.WriteStartElement("r", W);
                Picture(w, id, cx, cy, ++drawing);
                w.WriteEndElement();
                w.WriteEndElement(); // p
            }
        }
        if (!any) { w.WriteStartElement("p", W); w.WriteEndElement(); } // Word wants a paragraph
        w.WriteEndElement(); // body
        w.WriteEndElement(); // document
    }

    private static void Picture(XmlWriter w, string id, long cx, long cy, int n)
    {
        string Number(long v) => v.ToString(CultureInfo.InvariantCulture);
        w.WriteStartElement("drawing", W);
        w.WriteStartElement("wp", "inline", WP);
        w.WriteStartElement("wp", "extent", WP);
        w.WriteAttributeString("cx", Number(cx));
        w.WriteAttributeString("cy", Number(cy));
        w.WriteEndElement();
        w.WriteStartElement("wp", "docPr", WP);
        w.WriteAttributeString("id", Number(n));
        w.WriteAttributeString("name", $"Picture {n}");
        w.WriteEndElement();
        w.WriteStartElement("a", "graphic", A);
        w.WriteStartElement("a", "graphicData", A);
        w.WriteAttributeString("uri", Pic);
        w.WriteStartElement("pic", "pic", Pic);
        w.WriteStartElement("pic", "nvPicPr", Pic);
        w.WriteStartElement("pic", "cNvPr", Pic);
        w.WriteAttributeString("id", Number(n));
        w.WriteAttributeString("name", $"Picture {n}");
        w.WriteEndElement();
        w.WriteElementString("pic", "cNvPicPr", Pic, "");
        w.WriteEndElement();
        w.WriteStartElement("pic", "blipFill", Pic);
        w.WriteStartElement("a", "blip", A);
        w.WriteAttributeString("r", "embed", R, id);
        w.WriteEndElement();
        w.WriteStartElement("a", "stretch", A);
        w.WriteElementString("a", "fillRect", A, "");
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteStartElement("pic", "spPr", Pic);
        w.WriteStartElement("a", "xfrm", A);
        w.WriteStartElement("a", "off", A);
        w.WriteAttributeString("x", "0");
        w.WriteAttributeString("y", "0");
        w.WriteEndElement();
        w.WriteStartElement("a", "ext", A);
        w.WriteAttributeString("cx", Number(cx));
        w.WriteAttributeString("cy", Number(cy));
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteStartElement("a", "prstGeom", A);
        w.WriteAttributeString("prst", "rect");
        w.WriteElementString("a", "avLst", A, "");
        w.WriteEndElement();
        w.WriteEndElement(); // spPr
        w.WriteEndElement(); // pic
        w.WriteEndElement(); // graphicData
        w.WriteEndElement(); // graphic
        w.WriteEndElement(); // inline
        w.WriteEndElement(); // drawing
    }

    private static void Styles(XmlWriter w)
    {
        w.WriteStartElement("w", "styles", W);
        void Style(string id, string name, bool isDefault, Action body)
        {
            w.WriteStartElement("style", W);
            w.WriteAttributeString("type", W, "paragraph");
            w.WriteAttributeString("styleId", W, id);
            if (isDefault) w.WriteAttributeString("default", W, "1");
            w.WriteStartElement("name", W);
            w.WriteAttributeString("val", W, name);
            w.WriteEndElement();
            body();
            w.WriteEndElement();
        }
        void Val(string element, string value)
        {
            w.WriteStartElement(element, W);
            w.WriteAttributeString("val", W, value);
            w.WriteEndElement();
        }
        Style("Normal", "Normal", true, () =>
        {
            w.WriteStartElement("pPr", W);
            w.WriteStartElement("spacing", W);
            w.WriteAttributeString("after", W, "160");
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteStartElement("rPr", W);
            Val("sz", "22");
            w.WriteEndElement();
        });
        Style("Heading1", "heading 1", false, () =>
        {
            Val("basedOn", "Normal");
            Val("next", "Normal");
            Val("qFormat", "1");
            w.WriteStartElement("pPr", W);
            w.WriteStartElement("keepNext", W);
            w.WriteEndElement();
            w.WriteStartElement("spacing", W);
            w.WriteAttributeString("before", W, "240");
            w.WriteAttributeString("after", W, "120");
            w.WriteEndElement();
            Val("outlineLvl", "0");
            w.WriteEndElement();
            w.WriteStartElement("rPr", W);
            w.WriteStartElement("b", W);
            w.WriteEndElement();
            Val("sz", "32");
            w.WriteEndElement();
        });
        w.WriteEndElement();
    }
}

/// <summary>
/// A scan saved as plain text (.txt): each page's paragraphs, a blank line between them and two between pages; UTF-8 with a
/// byte order mark and Windows line ends, so Notepad and older tools read it alike. Pages with no text add nothing.
/// </summary>
public static class ScanText
{
    public static string Text(IReadOnlyList<ScanDocPage> pages)
    {
        var sb = new StringBuilder();
        foreach (var page in pages)
        {
            var paragraphs = page.Paragraphs();
            if (paragraphs.Count == 0) continue;
            if (sb.Length > 0) sb.Append("\r\n");
            foreach (var p in paragraphs) sb.Append(p.Text.ReplaceLineEndings(" ")).Append("\r\n\r\n");
        }
        return sb.ToString().TrimEnd('\r', '\n') + (sb.Length > 0 ? "\r\n" : "");
    }

    public static void Write(Stream output, IReadOnlyList<ScanDocPage> pages)
    {
        using var writer = new StreamWriter(output, new UTF8Encoding(encoderShouldEmitUTF8Identifier: true), leaveOpen: true);
        writer.Write(Text(pages));
    }
}
