using System.Text;
using System.Xml;
using System.Xml.Linq;
using System.Xml.Schema;
using InkvoltPdf.Core;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>Comments in and out (roadmap 1.4): XFDF, FDF and CSV round trips, merging, and hostile files.</summary>
public class CommentFilesTests
{
    /// <summary>Two pages with one comment of each kind Inkvolt makes, replies two deep, Unicode and line breaks.</summary>
    internal static byte[] Commented()
    {
        var pdf = TestPdf.Make(2);
        pdf = Annotations.AddNote(pdf, null, 0, 300, 80, "Check this,\nline two with \"quotes\"", "Ana Lucía", new AnnotColor(0.2, 0.6, 0.9), "note-1");
        pdf = Annotations.AddReply(pdf, null, "note-1", "Agreed ✓ — señal", "Bo", "reply-1");
        pdf = Annotations.AddReply(pdf, null, "reply-1", "Nested reply", "Ana Lucía", "reply-2");
        pdf = Annotations.AddTextMarkup(pdf, null, 0, TextMarkupKind.Highlight, [new RectD(72, 80, 200, 24), new RectD(72, 110, 150, 24)], AnnotColor.Yellow, "hl note", "Bo", "hl-1");
        pdf = Annotations.AddTextMarkup(pdf, null, 1, TextMarkupKind.StrikeOut, [new RectD(72, 120, 180, 24)], AnnotColor.Red, "", "Bo", "so-1");
        pdf = Annotations.AddInk(pdf, null, 0, [[new(100, 300), new(120, 320), new(150, 310)], [new(200, 300), new(210, 340)]],
            AnnotStyle.Pen(new AnnotColor(0, 0.5, 0), 3), "Ana Lucía", "ink-1");
        pdf = Annotations.AddShape(pdf, null, 0, ShapeKind.Rectangle, new RectD(300, 300, 120, 80),
            new AnnotStyle { Color = AnnotColor.Red, Fill = new AnnotColor(1, 1, 0.8), Width = 2, Dash = [4, 2] }, "Ana Lucía", "sq-1");
        pdf = Annotations.AddShape(pdf, null, 0, ShapeKind.Ellipse, new RectD(300, 420, 100, 60), AnnotStyle.Pen(new AnnotColor(0.5, 0, 0.5)) with { Opacity = 0.5 }, "Bo", "ci-1");
        pdf = Annotations.AddLine(pdf, null, 1, new PointD(100, 400), new PointD(300, 500), AnnotStyle.Arrow(new AnnotColor(0, 0, 1)), "Bo", "ln-1");
        pdf = Annotations.AddPolygon(pdf, null, 1, [new(350, 400), new(450, 420), new(400, 500)], true, AnnotStyle.Pen(AnnotColor.Red), "Bo", "pg-1");
        pdf = Annotations.AddPolygon(pdf, null, 1, [new(350, 600), new(450, 620), new(500, 580)], false, AnnotStyle.Pen(AnnotColor.Red) with { EndEnding = LineEnding.ClosedArrow }, "Bo", "pl-1");
        pdf = Annotations.AddFreeText(pdf, null, 1, new RectD(100, 600, 200, 60), "Callout, text", AnnotStyle.TextBox(11, AnnotColor.Red, new AnnotColor(1, 1, 0.9)),
            "Ana Lucía", [new PointD(80, 560)], "ft-1");
        pdf = RubberStamps.Put(pdf, null, 1, new RectD(350, 100, 160, 50), RubberStamps.BuiltIn[0], "Ana Lucía");
        return pdf;
    }

    private static Dictionary<string, AnnotationInfo> ById(byte[] pdf) => Annotations.Read(pdf, null).ToDictionary(a => a.Id);

    /// <summary>Every comment of <paramref name="expected"/> is in <paramref name="actual"/> with the same type, text, author,
    /// color (to XFDF's 1/255), replies and geometry; with <paramref name="style"/> the drawing style too.</summary>
    private static void AssertSameComments(byte[] expected, byte[] actual, bool style = true)
    {
        var a = ById(expected);
        var b = ById(actual);
        Assert.Equal(a.Count, b.Count);
        foreach (var (id, x) in a)
        {
            Assert.True(b.TryGetValue(id, out var y), $"{id} missing");
            Assert.Equal(x.Subtype, y!.Subtype);
            Assert.Equal(x.PageIndex, y.PageIndex);
            Assert.Equal(x.Contents.Replace("\r\n", "\n"), y.Contents.Replace("\r\n", "\n"));
            Assert.Equal(x.Author, y.Author);
            Assert.Equal(x.ReplyTo, y.ReplyTo);
            Assert.Equal(x.Hidden, y.Hidden);
            if (x.Modified is { } m) Assert.True(Math.Abs((m - y.Modified!.Value).TotalSeconds) < 1.01, $"{id} date");
            Color(x.Color, y.Color, id);
            Near(x.Rect, y.Rect, id);
            Assert.Equal(x.QuadRects.Count, y.QuadRects.Count);
            for (var i = 0; i < x.QuadRects.Count; i++) Near(x.QuadRects[i], y.QuadRects[i], id);
            Assert.Equal(x.Geometry is null, y.Geometry is null);
            if (x.Geometry is { } g)
            {
                Near(g.Box, y.Geometry!.Box, id);
                Assert.Equal(g.Paths.Count, y.Geometry.Paths.Count);
                for (var i = 0; i < g.Paths.Count; i++)
                {
                    Assert.Equal(g.Paths[i].Count, y.Geometry.Paths[i].Count);
                    for (var k = 0; k < g.Paths[i].Count; k++)
                    {
                        Assert.Equal(g.Paths[i][k].X, y.Geometry.Paths[i][k].X, 0.01);
                        Assert.Equal(g.Paths[i][k].Y, y.Geometry.Paths[i][k].Y, 0.01);
                    }
                }
                Assert.Equal(g.Callout.Count, y.Geometry.Callout.Count);
            }
            if (style && x.Style is { } s)
            {
                var t = y.Style!;
                Assert.Equal(s.Width, t.Width, 0.01);
                Assert.Equal(s.Opacity, t.Opacity, 0.01);
                Assert.Equal(s.Dash ?? [], t.Dash ?? []);
                Assert.Equal(s.StartEnding, t.StartEnding);
                Assert.Equal(s.EndEnding, t.EndEnding);
                Assert.Equal(s.FontSize, t.FontSize, 0.01);
                Assert.Equal(s.Align, t.Align);
                Color(s.Fill, t.Fill, id + " fill");
                Color(s.TextColor, t.TextColor, id + " text color");
            }
        }

        static void Near(RectD p, RectD q, string id)
        {
            Assert.True(Math.Abs(p.X - q.X) < 0.05 && Math.Abs(p.Y - q.Y) < 0.05 && Math.Abs(p.Width - q.Width) < 0.05 && Math.Abs(p.Height - q.Height) < 0.05,
                $"{id}: {p} vs {q}");
        }

        static void Color(AnnotColor? p, AnnotColor? q, string id)
        {
            Assert.Equal(p is null, q is null);
            if (p is { } c)
                Assert.True(Math.Abs(c.R - q!.Value.R) < 0.003 && Math.Abs(c.G - q.Value.G) < 0.003 && Math.Abs(c.B - q.Value.B) < 0.003, $"{id}: {c} vs {q}");
        }
    }

    [Theory]
    [InlineData(CommentFileFormat.Xfdf)]
    [InlineData(CommentFileFormat.Fdf)]
    public void RoundTripsIntoACleanCopy(CommentFileFormat format)
    {
        var source = Commented();
        var export = CommentFiles.Export(source, null, format, "source.pdf");
        Assert.Equal(13, export.Count);
        var result = CommentFiles.Import(TestPdf.Make(2), null, export.Data);
        Assert.Equal(13, result.Added);
        Assert.Empty(result.Skipped);
        Assert.Empty(result.Notes);
        AssertSameComments(source, result.Data);

        // Every imported comment has an appearance; the stamp keeps the picture it had.
        using var doc = PdfReader.Open(new MemoryStream(result.Data), PdfDocumentOpenMode.Import);
        foreach (var page in doc.Pages)
            foreach (var a in page.Annotations.Elements.Select(e => (e as PdfSharp.Pdf.Advanced.PdfReference)?.Value).OfType<PdfDictionary>())
                Assert.NotNull(a.Elements.GetDictionary("/AP")?.Elements.GetDictionary("/N"));
        Assert.Contains("APPROVED", Core2Pdf.AllText(result.Data, 1));
        Assert.Contains("Callout, text", Core2Pdf.AllText(result.Data, 1));
    }

    [Fact]
    public void CsvRoundTripKeepsTextAuthorsColorsRepliesAndPlaces()
    {
        var source = Commented();
        var export = CommentFiles.Export(source, null, CommentFileFormat.Csv);
        var rows = Csv.Read(Csv.Decode(export.Data));
        Assert.Equal(14, rows.Count);
        Assert.Equal(CommentFiles.CsvColumns, rows[0]);
        var result = CommentFiles.Import(TestPdf.Make(2), null, export.Data);
        Assert.Equal(13, result.Added);
        AssertSameComments(source, result.Data, style: false);
    }

    [Fact]
    public void ImportMergesAndSkipsWhatIsAlreadyThere()
    {
        var source = Commented();
        var xfdf = CommentFiles.Export(source, null, CommentFileFormat.Xfdf).Data;

        // Into the document it came from: nothing is added, each comment is reported.
        var again = CommentFiles.Import(source, null, xfdf);
        Assert.Equal(0, again.Added);
        Assert.Same(source, again.Data);
        Assert.Equal(13, again.Skipped.Count);
        Assert.All(again.Skipped, s => Assert.EndsWith("already in the document", s));
        Assert.Contains(again.Skipped, s => s.StartsWith("Page 1, note by Ana Lucía", StringComparison.Ordinal));

        // A copy with some of them: only the missing ones come in, replies attach to the comment already there.
        var partial = Annotations.Delete(source, null, "reply-1"); // takes reply-2 with it
        partial = Annotations.Delete(partial, null, "ink-1");
        var merged = CommentFiles.Import(partial, null, xfdf);
        Assert.Equal(3, merged.Added);
        Assert.Equal(10, merged.Skipped.Count);
        AssertSameComments(source, merged.Data);

        // Comments without ids (another app's) are matched by what they are.
        var fdf = CommentFiles.Export(WithoutIds(source), null, CommentFileFormat.Fdf).Data;
        var twice = CommentFiles.Import(WithoutIds(source), null, fdf);
        Assert.Equal(0, twice.Added);
    }

    private static byte[] WithoutIds(byte[] pdf)
    {
        using var doc = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Modify);
        foreach (var page in doc.Pages)
            foreach (var a in page.Annotations.Elements.Select(e => (e as PdfSharp.Pdf.Advanced.PdfReference)?.Value).OfType<PdfDictionary>())
                a.Elements.Remove("/NM");
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        return ms.ToArray();
    }

    [Fact]
    public void ReportsCommentsItCantPlace()
    {
        var xfdf = """
            <?xml version="1.0" encoding="UTF-8"?>
            <xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve"><annots>
            <text page="7" rect="10,10,30,30" name="far" title="Kim"><contents>On page 8</contents></text>
            <link page="0" rect="10,10,30,30" name="lnk"/>
            <fileattachment page="0" rect="10,10,30,30" name="att"/>
            <square page="0" name="norect"/>
            <text page="0" rect="10,700,30,720" name="orphan" inreplyto="nobody" replyType="reply"><contents>Reply to a missing note</contents></text>
            </annots></xfdf>
            """;
        var r = CommentFiles.Import(TestPdf.Make(1), null, Encoding.UTF8.GetBytes(xfdf));
        Assert.Equal(1, r.Added);
        Assert.Contains(r.Skipped, s => s.Contains("no page 8", StringComparison.Ordinal));
        Assert.Contains(r.Skipped, s => s.Contains("<link>", StringComparison.Ordinal));
        Assert.Contains(r.Skipped, s => s.Contains("<fileattachment>", StringComparison.Ordinal));
        Assert.Contains(r.Skipped, s => s.Contains("no position", StringComparison.Ordinal));
        Assert.Single(r.Notes);
        Assert.Null(Annotations.Read(r.Data, null).Single().ReplyTo);
    }

    // ---------------- XFDF conformance ----------------

    /// <summary>
    /// The rules of XFDF 3.0 (ISO 19444-1, Adobe's XFDF specification) for the elements and attributes Inkvolt writes,
    /// transcribed into XSD: the root and its children, the annotation elements with their required page and rect,
    /// colors as #RRGGBB, the flag words, reply types, justification, border styles, line endings, and number lists.
    /// Acrobat itself can't run here, so exports are checked against these rules and Adobe-style samples are imported.
    /// </summary>
    private const string XfdfRules = """
        <xs:schema xmlns:xs="http://www.w3.org/2001/XMLSchema" targetNamespace="http://ns.adobe.com/xfdf/" xmlns="http://ns.adobe.com/xfdf/" elementFormDefault="qualified">
          <xs:simpleType name="color"><xs:restriction base="xs:string"><xs:pattern value="#[0-9A-Fa-f]{6}"/></xs:restriction></xs:simpleType>
          <xs:simpleType name="numbers"><xs:restriction base="xs:string"><xs:pattern value="-?[0-9.]+(,-?[0-9.]+)*"/></xs:restriction></xs:simpleType>
          <xs:simpleType name="rect"><xs:restriction base="xs:string"><xs:pattern value="-?[0-9.]+,-?[0-9.]+,-?[0-9.]+,-?[0-9.]+"/></xs:restriction></xs:simpleType>
          <xs:simpleType name="point"><xs:restriction base="xs:string"><xs:pattern value="-?[0-9.]+,-?[0-9.]+"/></xs:restriction></xs:simpleType>
          <xs:simpleType name="date"><xs:restriction base="xs:string"><xs:pattern value="D:[0-9]{4}([0-9]{2}){0,5}(Z|[+\-][0-9]{2}'([0-9]{2}'?)?)?"/></xs:restriction></xs:simpleType>
          <xs:simpleType name="flags"><xs:restriction base="xs:string"><xs:pattern value="((invisible|hidden|print|nozoom|norotate|noview|readonly|locked|togglenoview|lockedcontents)(,(invisible|hidden|print|nozoom|norotate|noview|readonly|locked|togglenoview|lockedcontents))*)?"/></xs:restriction></xs:simpleType>
          <xs:simpleType name="ending"><xs:restriction base="xs:string"><xs:enumeration value="Square"/><xs:enumeration value="Circle"/><xs:enumeration value="Diamond"/><xs:enumeration value="OpenArrow"/><xs:enumeration value="ClosedArrow"/><xs:enumeration value="None"/><xs:enumeration value="Butt"/><xs:enumeration value="ROpenArrow"/><xs:enumeration value="RClosedArrow"/><xs:enumeration value="Slash"/></xs:restriction></xs:simpleType>
          <xs:simpleType name="opacity"><xs:restriction base="xs:decimal"><xs:minInclusive value="0"/><xs:maxInclusive value="1"/></xs:restriction></xs:simpleType>
          <xs:attributeGroup name="annot">
            <xs:attribute name="page" type="xs:nonNegativeInteger" use="required"/>
            <xs:attribute name="rect" type="rect" use="required"/>
            <xs:attribute name="name" type="xs:string"/>
            <xs:attribute name="title" type="xs:string"/>
            <xs:attribute name="subject" type="xs:string"/>
            <xs:attribute name="date" type="date"/>
            <xs:attribute name="creationdate" type="date"/>
            <xs:attribute name="color" type="color"/>
            <xs:attribute name="interior-color" type="color"/>
            <xs:attribute name="flags" type="flags"/>
            <xs:attribute name="opacity" type="opacity"/>
            <xs:attribute name="inreplyto" type="xs:string"/>
            <xs:attribute name="replyType"><xs:simpleType><xs:restriction base="xs:string"><xs:enumeration value="reply"/><xs:enumeration value="group"/></xs:restriction></xs:simpleType></xs:attribute>
            <xs:attribute name="intent" type="xs:string"/>
            <xs:attribute name="width" type="xs:decimal"/>
            <xs:attribute name="style"><xs:simpleType><xs:restriction base="xs:string"><xs:enumeration value="solid"/><xs:enumeration value="dash"/><xs:enumeration value="bevelled"/><xs:enumeration value="inset"/><xs:enumeration value="underline"/><xs:enumeration value="cloudy"/></xs:restriction></xs:simpleType></xs:attribute>
            <xs:attribute name="dashes" type="numbers"/>
            <xs:attribute name="intensity" type="xs:decimal"/>
            <xs:attribute name="fringe" type="numbers"/>
            <xs:attribute name="rotation" type="xs:integer"/>
            <xs:attribute name="icon" type="xs:string"/>
            <xs:attribute name="state" type="xs:string"/>
            <xs:attribute name="statemodel" type="xs:string"/>
            <xs:attribute name="justification"><xs:simpleType><xs:restriction base="xs:string"><xs:enumeration value="left"/><xs:enumeration value="centered"/><xs:enumeration value="right"/></xs:restriction></xs:simpleType></xs:attribute>
            <xs:attribute name="coords" type="numbers"/>
            <xs:attribute name="start" type="point"/>
            <xs:attribute name="end" type="point"/>
            <xs:attribute name="head" type="ending"/>
            <xs:attribute name="tail" type="ending"/>
            <xs:attribute name="callout" type="numbers"/>
            <xs:attribute name="leaderLength" type="xs:decimal"/>
            <xs:attribute name="leaderExtended" type="xs:decimal"/>
            <xs:attribute name="leader-offset" type="xs:decimal"/>
            <xs:attribute name="caption"><xs:simpleType><xs:restriction base="xs:string"><xs:enumeration value="yes"/><xs:enumeration value="no"/></xs:restriction></xs:simpleType></xs:attribute>
            <xs:attribute name="symbol" type="xs:string"/>
            <xs:attribute name="overlay-text" type="xs:string"/>
          </xs:attributeGroup>
          <xs:complexType name="annotation">
            <xs:choice minOccurs="0" maxOccurs="unbounded">
              <xs:element name="contents" type="xs:string"/>
              <xs:element name="contents-richtext"><xs:complexType><xs:sequence><xs:any namespace="http://www.w3.org/1999/xhtml" processContents="skip"/></xs:sequence></xs:complexType></xs:element>
              <xs:element name="popup"><xs:complexType><xs:anyAttribute processContents="skip"/></xs:complexType></xs:element>
              <xs:element name="defaultappearance" type="xs:string"/>
              <xs:element name="defaultstyle" type="xs:string"/>
              <xs:element name="vertices"><xs:simpleType><xs:restriction base="xs:string"><xs:pattern value="-?[0-9.]+,-?[0-9.]+(;-?[0-9.]+,-?[0-9.]+)*"/></xs:restriction></xs:simpleType></xs:element>
              <xs:element name="inklist"><xs:complexType><xs:sequence><xs:element name="gesture" maxOccurs="unbounded"><xs:simpleType><xs:restriction base="xs:string"><xs:pattern value="-?[0-9.]+,-?[0-9.]+(;-?[0-9.]+,-?[0-9.]+)*"/></xs:restriction></xs:simpleType></xs:element></xs:sequence></xs:complexType></xs:element>
              <xs:element name="appearance" type="xs:base64Binary"/>
            </xs:choice>
            <xs:attributeGroup ref="annot"/>
          </xs:complexType>
          <xs:element name="xfdf">
            <xs:complexType>
              <xs:all>
                <xs:element name="f" minOccurs="0"><xs:complexType><xs:attribute name="href" type="xs:string" use="required"/></xs:complexType></xs:element>
                <xs:element name="ids" minOccurs="0"><xs:complexType><xs:attribute name="original" type="xs:string"/><xs:attribute name="modified" type="xs:string"/></xs:complexType></xs:element>
                <xs:element name="annots" minOccurs="0">
                  <xs:complexType>
                    <xs:choice minOccurs="0" maxOccurs="unbounded">
                      <xs:element name="text" type="annotation"/><xs:element name="freetext" type="annotation"/><xs:element name="line" type="annotation"/>
                      <xs:element name="square" type="annotation"/><xs:element name="circle" type="annotation"/><xs:element name="polygon" type="annotation"/>
                      <xs:element name="polyline" type="annotation"/><xs:element name="highlight" type="annotation"/><xs:element name="underline" type="annotation"/>
                      <xs:element name="squiggly" type="annotation"/><xs:element name="strikeout" type="annotation"/><xs:element name="stamp" type="annotation"/>
                      <xs:element name="caret" type="annotation"/><xs:element name="ink" type="annotation"/><xs:element name="redact" type="annotation"/>
                    </xs:choice>
                  </xs:complexType>
                </xs:element>
              </xs:all>
              <xs:anyAttribute namespace="http://www.w3.org/XML/1998/namespace" processContents="skip"/>
            </xs:complexType>
          </xs:element>
        </xs:schema>
        """;

    [Fact]
    public void ExportedXfdfFollowsTheXfdfRules()
    {
        var xfdf = CommentFiles.Export(Commented(), null, CommentFileFormat.Xfdf, "source.pdf").Data;
        var schemas = new XmlSchemaSet();
        schemas.Add(XmlSchema.Read(new StringReader(XfdfRules), null)!);
        var errors = new List<string>();
        var settings = new XmlReaderSettings { ValidationType = ValidationType.Schema, Schemas = schemas, DtdProcessing = DtdProcessing.Prohibit };
        settings.ValidationEventHandler += (_, e) => errors.Add($"{e.Severity}: {e.Message}");
        using (var reader = XmlReader.Create(new MemoryStream(xfdf), settings))
            while (reader.Read()) { }
        Assert.Empty(errors);

        // The stamp's appearance decodes to Acrobat's DICT/STREAM tree.
        var doc = XDocument.Load(new MemoryStream(xfdf));
        XNamespace ns = "http://ns.adobe.com/xfdf/";
        var appearance = doc.Descendants(ns + "stamp").Single().Element(ns + "appearance")!.Value;
        var tree = XElement.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(appearance)));
        Assert.Equal("DICT", tree.Name.LocalName);
        Assert.Equal("AP", (string?)tree.Attribute("KEY"));
        var n = tree.Elements("STREAM").Single(e => (string?)e.Attribute("KEY") == "N");
        Assert.Contains(n.Elements("ARRAY"), e => (string?)e.Attribute("KEY") == "BBox");
        Assert.Equal("HEX", (string?)n.Element("DATA")!.Attribute("ENCODING"));
        Assert.Equal(3, doc.Descendants(ns + "text").Count());
        Assert.Equal("note-1", (string?)doc.Descendants(ns + "text").Single(e => (string?)e.Attribute("name") == "reply-1").Attribute("inreplyto"));
    }

    [Fact]
    public void ImportsAdobeStyleXfdf()
    {
        // Shaped like Acrobat's output and the XFDF specification's examples: a note with rich text and a popup, a reply,
        // a highlight, ink, a square, a free text box and a custom stamp with its appearance.
        var stampAp = Convert.ToBase64String(Encoding.UTF8.GetBytes(
            "<?xml version=\"1.0\" encoding=\"UTF-8\" ?><DICT KEY=\"AP\"><STREAM KEY=\"N\"><ARRAY KEY=\"BBox\"><FIXED VAL=\"0.0\"/><FIXED VAL=\"0.0\"/><FIXED VAL=\"120.0\"/><FIXED VAL=\"40.0\"/></ARRAY>" +
            "<INT KEY=\"Length\" VAL=\"31\"/><NAME KEY=\"Subtype\" VAL=\"Form\"/><NAME KEY=\"Type\" VAL=\"XObject\"/><DICT KEY=\"Resources\"/>" +
            "<DATA MODE=\"RAW\" ENCODING=\"HEX\">" + Convert.ToHexString(Encoding.ASCII.GetBytes("1 0 0 rg 2 2 116 36 re f q Q   ")) + "</DATA></STREAM></DICT>"));
        var xfdf = $"""
            <?xml version="1.0" encoding="UTF-8"?>
            <xfdf xmlns="http://ns.adobe.com/xfdf/" xml:space="preserve">
            <annots>
            <text color="#FFFF00" creationdate="D:20090416104010-07'00'" flags="print,nozoom,norotate" date="D:20090416104016-07'00'" name="a1b2c3d4-0001" icon="Comment" page="0" rect="300.5,700.25,320.5,720.25" subject="Sticky Note" title="jdoe">
            <contents-richtext><body xmlns="http://www.w3.org/1999/xhtml" xmlns:xfa="http://www.xfa.org/schema/xfa-data/1.0/" xfa:APIVersion="Acrobat:9.0.0" xfa:spec="2.0.2"><p>Please review this paragraph.</p><p>Second line</p></body></contents-richtext>
            <popup flags="print,nozoom,noview,norotate" open="no" page="0" rect="320,600,500,720"/>
            </text>
            <text color="#FFFF00" date="D:20090416110000-07'00'" flags="print,nozoom,norotate" name="a1b2c3d4-0002" icon="Comment" inreplyto="a1b2c3d4-0001" replyType="reply" page="0" rect="300.5,700.25,320.5,720.25" subject="Sticky Note" title="asmith"><contents>Done.</contents></text>
            <highlight color="#FFFF00" date="D:20090416104100-07'00'" flags="print" name="a1b2c3d4-0003" page="0" coords="72,650,250,650,72,630,250,630" rect="71,629,251,651" title="jdoe" opacity="0.5"><contents>Key sentence</contents></highlight>
            <ink color="#0000FF" date="D:20090416104200-07'00'" flags="print" name="a1b2c3d4-0004" page="0" rect="99,399,201,451" title="jdoe" width="2"><inklist><gesture>100,400;150,450;200,400</gesture></inklist></ink>
            <square color="#FF0000" interior-color="#FFFFCC" date="D:20090416104300-07'00'" flags="print" name="a1b2c3d4-0005" page="0" rect="300,300,400,360" title="jdoe" width="3" style="dash" dashes="3,3"/>
            <freetext date="D:20090416104400-07'00'" flags="print" name="a1b2c3d4-0006" page="0" rect="72,200,272,240" title="jdoe" justification="centered" width="1" color="#000000">
            <contents>Typed note</contents><defaultappearance>0 0 1 rg /Helv 12 Tf</defaultappearance><defaultstyle>font: Helvetica 12pt; text-align:center; color:#0000FF</defaultstyle>
            </freetext>
            <stamp date="D:20090416104500-07'00'" flags="print" name="a1b2c3d4-0007" icon="SBApproved" page="0" rect="400,100,520,140" title="jdoe" subject="Approved"><appearance>{stampAp}</appearance></stamp>
            </annots>
            <f href="Document.pdf"/>
            <ids original="A1B2C3" modified="D4E5F6"/>
            </xfdf>
            """;
        var r = CommentFiles.Import(TestPdf.Make(1), null, Encoding.UTF8.GetBytes(xfdf));
        Assert.Equal(7, r.Added);
        var c = ById(r.Data);
        Assert.Equal("Please review this paragraph.\nSecond line", c["a1b2c3d4-0001"].Contents);
        Assert.Equal("a1b2c3d4-0001", c["a1b2c3d4-0002"].ReplyTo);
        Assert.Equal("asmith", c["a1b2c3d4-0002"].Author);
        Assert.Equal(new DateTimeOffset(2009, 4, 16, 10, 40, 16, TimeSpan.FromHours(-7)), c["a1b2c3d4-0001"].Modified);
        Assert.Single(c["a1b2c3d4-0003"].QuadRects);
        Assert.Equal(0.5, c["a1b2c3d4-0003"].Opacity, 3);
        Assert.Equal(3, c["a1b2c3d4-0004"].Geometry!.Paths[0].Count);
        Assert.Equal(new[] { 3.0, 3.0 }, c["a1b2c3d4-0005"].Style!.Dash!);
        Assert.Equal(TextAlign.Center, c["a1b2c3d4-0006"].Style!.Align);
        Assert.Equal(new AnnotColor(0, 0, 1), c["a1b2c3d4-0006"].Style!.TextColor);
        Assert.Contains("Typed note", Core2Pdf.AllText(r.Data));

        // The stamp shows the picture it came with: red.
        Assert.True(Core2Pdf.Ink(r.Data, 0, new RectD(410, 792 - 135, 100, 30)) > 0.5);
    }

    // ---------------- Hostile files ----------------

    [Fact]
    public void RefusesXfdfWithADtd()
    {
        var xxe = """
            <?xml version="1.0"?>
            <!DOCTYPE xfdf [<!ENTITY secret SYSTEM "file:///c:/windows/win.ini">]>
            <xfdf xmlns="http://ns.adobe.com/xfdf/"><annots><text page="0" rect="0,0,20,20"><contents>&secret;</contents></text></annots></xfdf>
            """;
        var ex = Assert.Throws<InvalidDataException>(() => CommentFiles.Import(TestPdf.Make(1), null, Encoding.UTF8.GetBytes(xxe)));
        Assert.Contains("DTD", ex.Message);

        var laughs = "<?xml version=\"1.0\"?><!DOCTYPE lolz [<!ENTITY lol \"lol\"><!ENTITY lol2 \"&lol;&lol;&lol;&lol;&lol;&lol;&lol;&lol;\">]>" +
                     "<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots><text page=\"0\" rect=\"0,0,20,20\"><contents>&lol2;</contents></text></annots></xfdf>";
        Assert.Throws<InvalidDataException>(() => CommentFiles.Import(TestPdf.Make(1), null, Encoding.UTF8.GetBytes(laughs)));
        Assert.Throws<InvalidDataException>(() => FormDataFiles.Import(FormDataTests.Form(), null, Encoding.UTF8.GetBytes(xxe.Replace("<annots>", "<fields><field name=\"name\"><value>&secret;</value></field></fields><annots>"))));
    }

    [Fact]
    public void BringsNoScriptsOrActionsIn()
    {
        // FDF: actions on the annotation, in its appearance's resources and as a JavaScript name tree; an attachment.
        var fdf = Encoding.Latin1.GetBytes("""
            %FDF-1.2
            1 0 obj << /FDF << /Annots [2 0 R 5 0 R] /JavaScript << /Doc [(x) 6 0 R] >> /F (evil.pdf) >> >> endobj
            2 0 obj << /Type /Annot /Subtype /Square /Page 0 /Rect [10 10 100 100] /NM (evil-1) /T (Mallory) /Contents (hi)
               /A << /S /JavaScript /JS (app.alert\(1\)) >> /AA << /E << /S /Launch /F (calc.exe) >> >> /OpenAction 6 0 R
               /AP << /N 3 0 R >> /Popup << /Type /Annot /Subtype /Popup >> /IC [1 0 0] >> endobj
            3 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 90 90] /Resources << /XObject << /X1 4 0 R >> /Properties << /P1 << /S /URI /URI (http://x) >> >> >> /Length 13 >>
            stream
            0 0 1 rg 0 0 90 90 re f
            endstream endobj
            4 0 obj << /Type /XObject /Subtype /Form /BBox [0 0 1 1] /F (\\\\evil\\share\\x) /Length 0 >>
            stream

            endstream endobj
            5 0 obj << /Type /Annot /Subtype /FileAttachment /Page 0 /Rect [0 0 10 10] /FS << /Type /Filespec /EF << /F 7 0 R >> >> >> endobj
            6 0 obj << /S /JavaScript /JS (this.exportDataObject\(\)) >> endobj
            7 0 obj << /Type /EmbeddedFile /Length 3 >>
            stream
            MZ!
            endstream endobj
            trailer << /Root 1 0 R >>
            %%EOF
            """);
        var r = CommentFiles.Import(TestPdf.Make(1), null, fdf);
        Assert.Equal(1, r.Added);
        Assert.Contains(r.Skipped, s => s.Contains("file attachment", StringComparison.Ordinal));
        AssertHarmless(r.Data);

        // XFDF: a link with an action, script-looking text (stays text), a stamp appearance with an action inside.
        var badAp = Convert.ToBase64String(Encoding.UTF8.GetBytes(
            "<DICT KEY=\"AP\"><STREAM KEY=\"N\"><ARRAY KEY=\"BBox\"><INT VAL=\"0\"/><INT VAL=\"0\"/><INT VAL=\"10\"/><INT VAL=\"10\"/></ARRAY>" +
            "<DICT KEY=\"Resources\"><DICT KEY=\"A\"><NAME KEY=\"S\" VAL=\"JavaScript\"/><STRING KEY=\"JS\" VAL=\"app.alert(2)\"/></DICT></DICT>" +
            "<DATA MODE=\"RAW\" ENCODING=\"HEX\">30</DATA></STREAM></DICT>"));
        var xfdf = $"""
            <xfdf xmlns="http://ns.adobe.com/xfdf/"><annots>
            <link page="0" rect="0,0,50,50"><OnActivation><Action><Launch><File Name="calc.exe"/></Launch></Action></OnActivation></link>
            <text page="0" rect="0,0,20,20" name="t1"><contents>&lt;script&gt;app.alert(3)&lt;/script&gt;</contents></text>
            <stamp page="0" rect="50,50,60,60" name="s1"><appearance>{badAp}</appearance></stamp>
            </annots></xfdf>
            """;
        var x = CommentFiles.Import(TestPdf.Make(1), null, Encoding.UTF8.GetBytes(xfdf));
        Assert.Equal(2, x.Added);
        AssertHarmless(x.Data);
        Assert.Equal("<script>app.alert(3)</script>", ById(x.Data)["t1"].Contents);
    }

    /// <summary>No object of the document is an action, holds JavaScript, a file or external data.</summary>
    internal static void AssertHarmless(byte[] pdf)
    {
        using var doc = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Import);
        foreach (var o in doc.Internals.GetAllObjects())
        {
            if (o is not PdfDictionary d) continue;
            Assert.False(d.Elements.ContainsKey("/JS"), "/JS");
            Assert.False(d.Elements.ContainsKey("/AA"), "/AA");
            Assert.False(d.Elements.ContainsKey("/OpenAction"), "/OpenAction");
            Assert.False(d.Elements.ContainsKey("/EF"), "/EF");
            Assert.NotEqual("/JavaScript", d.Elements.GetName("/S"));
            Assert.NotEqual("/Launch", d.Elements.GetName("/S"));
            Assert.NotEqual("/URI", d.Elements.GetName("/S"));
            if (d.Elements.GetName("/Type") == "/Annot") Assert.False(d.Elements.ContainsKey("/A"), "/A on an annotation");
            if (d.Stream is not null) Assert.False(d.Elements.ContainsKey("/F"), "external stream");
        }
        Assert.DoesNotContain("app.alert(1)", Encoding.Latin1.GetString(pdf));
        Assert.DoesNotContain("calc.exe", Encoding.Latin1.GetString(pdf));
    }

    [Fact]
    public void RefusesHugeFiles()
    {
        var huge = new byte[CommentFiles.MaxFileBytes + 1];
        huge.AsSpan().Fill((byte)' ');
        huge[0] = (byte)'<';
        Assert.Contains("larger than", Assert.Throws<InvalidDataException>(() => CommentFiles.Import(TestPdf.Make(1), null, huge)).Message);

        var many = new StringBuilder("<xfdf xmlns=\"http://ns.adobe.com/xfdf/\"><annots>");
        for (var i = 0; i <= CommentFiles.MaxComments; i++) many.Append("<text page=\"0\" rect=\"0,0,1,1\"/>");
        many.Append("</annots></xfdf>");
        Assert.Contains("more than", Assert.Throws<InvalidDataException>(() => CommentFiles.Import(TestPdf.Make(1), null, Encoding.UTF8.GetBytes(many.ToString()))).Message);

        Assert.Throws<InvalidDataException>(() => FormDataFiles.ReadValues(new byte[FormDataFiles.MaxFileBytes + 1]));
        Assert.Throws<InvalidDataException>(() => FormDataFiles.ReadValues(Encoding.UTF8.GetBytes(new string('[', 10_000) + new string(']', 10_000))));
    }

    [Fact]
    public void RefusesFilesThatArentComments()
    {
        Assert.Throws<InvalidDataException>(() => CommentFiles.Import(TestPdf.Make(1), null, Encoding.UTF8.GetBytes("name,value\nx,y\n")));
        Assert.Throws<InvalidDataException>(() => CommentFiles.Import(TestPdf.Make(1), null, Encoding.UTF8.GetBytes("<html><body/></html>")));
        Assert.Throws<InvalidDataException>(() => CommentFiles.Import(TestPdf.Make(1), null, Encoding.UTF8.GetBytes("<xfdf><annots>")));
    }
}
