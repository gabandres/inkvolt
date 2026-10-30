using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Xml;

namespace InkvoltPdf.Core;

/// <summary>
/// Writes a PowerPoint presentation (.pptx, Office Open XML) from laid-out pages, one slide per page: each paragraph an
/// editable text box where the page has it (a list one box with real bullets), the page's first top heading the slide's
/// title, tables as tables, pictures as pictures, simple shapes as shapes. A slide's order is its reading order, shapes and
/// pictures that lie under something first. A presentation has one slide size: the size most pages have. Pages of another
/// size are shrunk to fit it, type included, and centered. Pictures are stored as they are added (<see cref="AddImage"/>),
/// so a long document's images needn't all be held in memory.
/// </summary>
internal sealed class PptxWriter : IDisposable
{
    private const string P = "http://schemas.openxmlformats.org/presentationml/2006/main";
    private const string A = "http://schemas.openxmlformats.org/drawingml/2006/main";
    private const string R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string RelBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/";
    private const string ContentBase = "application/vnd.openxmlformats-officedocument.presentationml.";

    // What PowerPoint allows for a slide: 1 to 56 inches.
    private const double MinSlide = 72, MaxSlide = 4032;

    private readonly ZipArchive _zip;
    private readonly Dictionary<string, string> _byContent = [];  // SHA-256 of a picture -> its id
    private readonly Dictionary<string, string> _targets = [];    // id -> media part
    private int _media;
    private bool _finished;

    public PptxWriter(Stream output) => _zip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true);

    /// <summary>
    /// Stores a picture (PNG or JPEG bytes) and returns its id for <see cref="ExportImage.Ref"/>. The same picture again (a
    /// logo on every page) is stored once and gets the same id.
    /// </summary>
    public string AddImage(byte[] data, string extension)
    {
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(data));
        if (_byContent.TryGetValue(hash, out var known)) return known;
        _media++;
        var target = $"../media/image{_media}.{(extension == "jpeg" ? "jpeg" : "png")}";
        var entry = _zip.CreateEntry($"ppt/media/image{_media}.{(extension == "jpeg" ? "jpeg" : "png")}", CompressionLevel.NoCompression); // already compressed
        using (var s = entry.Open()) s.Write(data);
        var id = $"rIdImg{_media}";
        _targets[id] = target;
        _byContent[hash] = id;
        return id;
    }

    public void Finish(IReadOnlyList<SlidePage> slides, string? title, string? language)
    {
        if (_finished) throw new InvalidOperationException("Already finished.");
        _finished = true;
        var lang = AccessibilityCheck.IsLanguage(language) ? language : null;
        var (width, height) = SlideSize(slides);
        var parts = new List<(string Part, string Type)>
        {
            ("/ppt/presentation.xml", ContentBase + "presentation.main+xml"),
            ("/ppt/slideMasters/slideMaster1.xml", ContentBase + "slideMaster+xml"),
            ("/ppt/slideLayouts/slideLayout1.xml", ContentBase + "slideLayout+xml"),
            ("/ppt/slideLayouts/slideLayout2.xml", ContentBase + "slideLayout+xml"),
            ("/ppt/theme/theme1.xml", "application/vnd.openxmlformats-officedocument.theme+xml"),
        };
        for (var i = 0; i < slides.Count; i++)
        {
            var slide = new SlideXml(slides[i], width, height, lang);
            Entry($"ppt/slides/slide{i + 1}.xml", slide.Write);
            Entry($"ppt/slides/_rels/slide{i + 1}.xml.rels", w => OpenXmlParts.Relationships(w,
            [
                ("rIdLayout", RelBase + "slideLayout", $"../slideLayouts/slideLayout{(slide.HasTitle ? 1 : 2)}.xml"),
                .. slide.Pictures.Distinct().Select(id => (id, RelBase + "image", _targets[id])),
            ]));
            parts.Add(($"/ppt/slides/slide{i + 1}.xml", ContentBase + "slide+xml"));
        }
        Entry("ppt/presentation.xml", w => Presentation(w, slides.Count, width, height));
        Entry("ppt/_rels/presentation.xml.rels", w => OpenXmlParts.Relationships(w,
        [
            ("rIdMaster", RelBase + "slideMaster", "slideMasters/slideMaster1.xml"),
            ("rIdTheme", RelBase + "theme", "theme/theme1.xml"),
            .. Enumerable.Range(1, slides.Count).Select(i => ($"rIdSlide{i}", RelBase + "slide", $"slides/slide{i}.xml")),
        ]));
        Raw("ppt/theme/theme1.xml", Theme);
        Raw("ppt/slideMasters/slideMaster1.xml", Master(width, height));
        Entry("ppt/slideMasters/_rels/slideMaster1.xml.rels", w => OpenXmlParts.Relationships(w,
        [
            ("rId1", RelBase + "slideLayout", "../slideLayouts/slideLayout1.xml"),
            ("rId2", RelBase + "slideLayout", "../slideLayouts/slideLayout2.xml"),
            ("rId3", RelBase + "theme", "../theme/theme1.xml"),
        ]));
        Raw("ppt/slideLayouts/slideLayout1.xml", Layout("titleOnly", "Title Only", TitleSp("<p:spPr/>")));
        Raw("ppt/slideLayouts/slideLayout2.xml", Layout("blank", "Blank", ""));
        for (var i = 1; i <= 2; i++)
            Entry($"ppt/slideLayouts/_rels/slideLayout{i}.xml.rels", w => OpenXmlParts.Relationships(w, [("rId1", RelBase + "slideMaster", "../slideMasters/slideMaster1.xml")]));
        Entry("_rels/.rels", w => OpenXmlParts.Relationships(w,
        [
            ("rId1", RelBase + "officeDocument", "ppt/presentation.xml"),
            ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
            ("rId3", RelBase + "extended-properties", "docProps/app.xml"),
        ]));
        Entry("docProps/core.xml", w => OpenXmlParts.CoreProperties(w, title));
        Entry("docProps/app.xml", OpenXmlParts.AppProperties);
        Entry("[Content_Types].xml", w => OpenXmlParts.ContentTypes(w, parts));
    }

    public void Dispose() => _zip.Dispose();

    private void Entry(string name, Action<XmlWriter> write) => OpenXmlParts.Entry(_zip, name, write);

    private void Raw(string name, string xml)
    {
        var entry = _zip.CreateEntry(name, CompressionLevel.Optimal);
        using var s = entry.Open();
        s.Write(new UTF8Encoding(false).GetBytes(xml));
    }

    /// <summary>The size most pages have (the first such, when tied), within what PowerPoint allows.</summary>
    private static (double Width, double Height) SlideSize(IReadOnlyList<SlidePage> slides)
    {
        if (slides.Count == 0) return (612, 792);
        var common = slides.Select((s, i) => (Size: (W: Math.Round(s.Layout.Width), H: Math.Round(s.Layout.Height)), s.Layout, Index: i))
            .GroupBy(x => x.Size).OrderByDescending(g => g.Count()).ThenBy(g => g.Min(x => x.Index)).First().First().Layout;
        var fit = Math.Min(1, MaxSlide / Math.Max(common.Width, common.Height));
        return (Math.Clamp(common.Width * fit, MinSlide, MaxSlide), Math.Clamp(common.Height * fit, MinSlide, MaxSlide));
    }

    private static string Emu(double pt) => Math.Round(pt * 12700).ToString(CultureInfo.InvariantCulture);

    private static void Presentation(XmlWriter w, int slides, double width, double height)
    {
        w.WriteStartElement("p", "presentation", P);
        w.WriteAttributeString("xmlns", "a", null, A);
        w.WriteAttributeString("xmlns", "r", null, R);
        w.WriteStartElement("sldMasterIdLst", P);
        w.WriteStartElement("sldMasterId", P);
        w.WriteAttributeString("id", "2147483648");
        w.WriteAttributeString("r", "id", R, "rIdMaster");
        w.WriteEndElement();
        w.WriteEndElement();
        if (slides > 0)
        {
            w.WriteStartElement("sldIdLst", P);
            for (var i = 1; i <= slides; i++)
            {
                w.WriteStartElement("sldId", P);
                w.WriteAttributeString("id", (255 + i).ToString(CultureInfo.InvariantCulture));
                w.WriteAttributeString("r", "id", R, $"rIdSlide{i}");
                w.WriteEndElement();
            }
            w.WriteEndElement();
        }
        w.WriteStartElement("sldSz", P);
        w.WriteAttributeString("cx", Emu(width));
        w.WriteAttributeString("cy", Emu(height));
        w.WriteEndElement();
        w.WriteStartElement("notesSz", P);
        w.WriteAttributeString("cx", "6858000");
        w.WriteAttributeString("cy", "9144000");
        w.WriteEndElement();
        w.WriteEndElement();
    }

    // ---- one slide ----

    /// <summary>One slide's XML, and which pictures it uses.</summary>
    private sealed class SlideXml(SlidePage page, double slideWidth, double slideHeight, string? lang)
    {
        private readonly double _scale = Math.Min(1, Math.Min(slideWidth / Math.Max(1, page.Layout.Width), slideHeight / Math.Max(1, page.Layout.Height)));
        private readonly DocParagraph? _title = TitleOf(page);
        private int _id = 1;

        public List<string> Pictures { get; } = [];
        public bool HasTitle => _title is not null;

        private double Dx => (slideWidth - page.Layout.Width * _scale) / 2;
        private double Dy => (slideHeight - page.Layout.Height * _scale) / 2;

        /// <summary>The first of the page's top headings, a running head never.</summary>
        private static DocParagraph? TitleOf(SlidePage page)
        {
            var headings = page.Layout.Blocks.OfType<DocParagraph>()
                .Where(p => p.HeadingLevel > 0 && p.List == ListKind.None && p.Box.Height > 0 && p.Text.Any(c => !char.IsWhiteSpace(c))
                            && !page.Running.Any(r => r.Contains(p.Box.CenterX, p.Box.CenterY))).ToList();
            return headings.Count == 0 ? null : headings.First(h => h.HeadingLevel == headings.Min(x => x.HeadingLevel));
        }

        public void Write(XmlWriter w)
        {
            w.WriteStartElement("p", "sld", P);
            w.WriteAttributeString("xmlns", "a", null, A);
            w.WriteAttributeString("xmlns", "r", null, R);
            w.WriteStartElement("cSld", P);
            w.WriteStartElement("spTree", P);
            w.WriteStartElement("nvGrpSpPr", P);
            CNvPr(w, "");
            w.WriteElementString("cNvGrpSpPr", P, null);
            w.WriteElementString("nvPr", P, null);
            w.WriteEndElement();
            w.WriteElementString("grpSpPr", P, null);
            Content(w);
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteStartElement("clrMapOvr", P);
            w.WriteElementString("masterClrMapping", A, null);
            w.WriteEndElement();
            w.WriteEndElement();
        }

        /// <summary>A slide's order is both what lies over what and the reading order: what must lie under something comes first.</summary>
        private void Content(XmlWriter w)
        {
            // Sideways text has no height in the flow: here it is a turned box of its own, where the page has it.
            var blocks = page.Layout.Blocks.Where(b => b.Box.Height > 0).ToList();
            var words = blocks.Where(b => b is DocParagraph or DocTable).Select(b => b.Box).ToList();
            var ruled = blocks.OfType<DocTable>().Where(t => t.Ruled).Select(t => t.Box.Inflate(2)).ToList();
            bool InTable(ExportShape s) => s.Fill is null && ruled.Any(t => t.Contains(s.Box.CenterX, s.Box.CenterY));
            var shapes = page.Source.Shapes.Where(s => !InTable(s)).ToList();
            var outlines = shapes.Where(s => s.Fill is null).ToList();
            bool Under(DocPicture p) => words.Concat(outlines.Select(o => o.Box)).Any(b => !b.Intersect(p.Box).IsEmpty);

            foreach (var s in shapes.Where(s => s.Fill is not null)) Shape(w, s);
            var under = blocks.OfType<DocPicture>().Where(Under).ToHashSet();
            foreach (var p in under) Picture(w, p.Image, p.Box);
            foreach (var s in outlines) Shape(w, s);
            for (var b = 0; b < blocks.Count; b++)
            {
                switch (blocks[b])
                {
                    case DocParagraph { List: not ListKind.None }:
                    {
                        var items = new List<DocParagraph>();
                        while (b < blocks.Count && blocks[b] is DocParagraph { List: not ListKind.None } item)
                        {
                            items.Add(item);
                            b++;
                        }
                        b--;
                        TextBox(w, items);
                        break;
                    }
                    case DocParagraph p:
                        if (p.Text.Any(c => !char.IsWhiteSpace(c))) TextBox(w, [p]);
                        break;
                    case DocTable t:
                        Table(w, t);
                        foreach (var cell in t.Rows.SelectMany(r => r))
                        foreach (var pic in cell.Pictures) Picture(w, pic.Image, pic.Box);
                        break;
                    case DocPicture pic when !under.Contains(pic):
                        Picture(w, pic.Image, pic.Box);
                        break;
                }
            }
            foreach (var line in page.Source.Lines.Where(l => l.Sideways && l.Text.Any(c => !char.IsWhiteSpace(c)))) Turned(w, line);
        }

        private string X(double x) => Emu(x * _scale + Dx);
        private string Y(double y) => Emu(y * _scale + Dy);
        private string Len(double d) => Emu(Math.Max(0, d) * _scale);

        private void CNvPr(XmlWriter w, string name, string? description = null)
        {
            w.WriteStartElement("cNvPr", P);
            w.WriteAttributeString("id", (_id++).ToString(CultureInfo.InvariantCulture));
            w.WriteAttributeString("name", name.Length == 0 ? "" : $"{name} {_id - 1}");
            if (!string.IsNullOrWhiteSpace(description)) w.WriteAttributeString("descr", OpenXmlParts.Clean(description).Replace('\t', ' '));
            w.WriteEndElement();
        }

        /// <summary>An a:xfrm or p:xfrm. <paramref name="box"/>: where it is on the page, unturned.</summary>
        private void Xfrm(XmlWriter w, RectD box, string ns = A, int quarterTurns = 0)
        {
            w.WriteStartElement("xfrm", ns);
            if (quarterTurns != 0) w.WriteAttributeString("rot", (quarterTurns * 5400000).ToString(CultureInfo.InvariantCulture));
            w.WriteStartElement("off", A);
            w.WriteAttributeString("x", X(box.X));
            w.WriteAttributeString("y", Y(box.Y));
            w.WriteEndElement();
            w.WriteStartElement("ext", A);
            w.WriteAttributeString("cx", Len(box.Width));
            w.WriteAttributeString("cy", Len(box.Height));
            w.WriteEndElement();
            w.WriteEndElement();
        }

        private static void Geometry(XmlWriter w, string preset)
        {
            w.WriteStartElement("prstGeom", A);
            w.WriteAttributeString("prst", preset);
            w.WriteElementString("avLst", A, null);
            w.WriteEndElement();
        }

        private static void SolidFill(XmlWriter w, uint color)
        {
            w.WriteStartElement("solidFill", A);
            w.WriteStartElement("srgbClr", A);
            w.WriteAttributeString("val", (color & 0xFFFFFF).ToString("X6", CultureInfo.InvariantCulture));
            w.WriteEndElement();
            w.WriteEndElement();
        }

        private void Ln(XmlWriter w, uint color, double width)
        {
            w.WriteStartElement("ln", A);
            w.WriteAttributeString("w", Emu(Math.Max(0.25, width * _scale)));
            SolidFill(w, color);
            w.WriteEndElement();
        }

        // ---- shapes and pictures ----

        private void Shape(XmlWriter w, ExportShape s)
        {
            if (s.Kind == ExportShapeKind.Line)
            {
                // Along the middle of a rule, as wide as it is thick.
                var horizontal = s.Box.Width >= s.Box.Height;
                var line = horizontal ? new RectD(s.Box.X, s.Box.CenterY, s.Box.Width, 0) : new RectD(s.Box.CenterX, s.Box.Y, 0, s.Box.Height);
                w.WriteStartElement("cxnSp", P);
                w.WriteStartElement("nvCxnSpPr", P);
                CNvPr(w, "Line");
                w.WriteElementString("cNvCxnSpPr", P, null);
                w.WriteElementString("nvPr", P, null);
                w.WriteEndElement();
                w.WriteStartElement("spPr", P);
                Xfrm(w, line);
                Geometry(w, "line");
                Ln(w, s.Stroke ?? 0, s.StrokeWidth);
                w.WriteEndElement();
                w.WriteEndElement();
                return;
            }
            w.WriteStartElement("sp", P);
            w.WriteStartElement("nvSpPr", P);
            CNvPr(w, s.Kind == ExportShapeKind.Ellipse ? "Ellipse" : "Rectangle");
            w.WriteElementString("cNvSpPr", P, null);
            w.WriteElementString("nvPr", P, null);
            w.WriteEndElement();
            w.WriteStartElement("spPr", P);
            Xfrm(w, s.Box);
            Geometry(w, s.Kind == ExportShapeKind.Ellipse ? "ellipse" : "rect");
            if (s.Fill is { } fill) SolidFill(w, fill);
            else w.WriteElementString("noFill", A, null);
            w.WriteStartElement("ln", A);
            if (s.Stroke is { } stroke)
            {
                w.WriteAttributeString("w", Emu(Math.Max(0.25, s.StrokeWidth * _scale)));
                SolidFill(w, stroke);
            }
            else w.WriteElementString("noFill", A, null);
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteEndElement();
        }

        private void Picture(XmlWriter w, ExportImage image, RectD box)
        {
            if (image.Ref is not { } rel) return;
            Pictures.Add(rel);
            w.WriteStartElement("pic", P);
            w.WriteStartElement("nvPicPr", P);
            CNvPr(w, "Picture", image.Alt);
            w.WriteStartElement("cNvPicPr", P);
            w.WriteStartElement("picLocks", A);
            w.WriteAttributeString("noChangeAspect", "1");
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteElementString("nvPr", P, null);
            w.WriteEndElement();
            w.WriteStartElement("blipFill", P);
            w.WriteStartElement("blip", A);
            w.WriteAttributeString("r", "embed", R, rel);
            w.WriteEndElement();
            w.WriteStartElement("stretch", A);
            w.WriteElementString("fillRect", A, null);
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteStartElement("spPr", P);
            // On a page turned upright a picture keeps its pixels: turned back here, it stands as the page shows it.
            var turn = ((4 - image.Turn) % 4 + 4) % 4;
            Xfrm(w, turn % 2 == 1 ? new RectD(box.CenterX - box.Height / 2, box.CenterY - box.Width / 2, box.Height, box.Width) : box, A, turn);
            Geometry(w, "rect");
            w.WriteEndElement();
            w.WriteEndElement();
        }

        // ---- text ----

        private void TextBox(XmlWriter w, IReadOnlyList<DocParagraph> paragraphs)
        {
            var isTitle = _title is not null && paragraphs.Count == 1 && ReferenceEquals(paragraphs[0], _title);
            var box = paragraphs.Skip(1).Aggregate(paragraphs[0].Box, (b, p) => b.Union(p.Box));
            // One line stays one line whatever font PowerPoint has. Longer ones wrap: a little room for a font that runs wider.
            var oneLine = paragraphs.All(p => p.LineCount <= 1 && !p.Text.Contains('\n'));
            if (!oneLine) box = new RectD(box.X, box.Y, box.Width + paragraphs.Max(p => p.Size) / 2, box.Height);
            OpenSp(w, isTitle ? "Title" : "Text", isTitle, box, oneLine);
            for (var i = 0; i < paragraphs.Count; i++)
                Paragraph(w, paragraphs[i], i == 0 ? 0 : Math.Max(0, paragraphs[i].Box.Y - paragraphs[i - 1].Box.Bottom), paragraphs[i].Box.X - box.X);
            CloseSp(w);
        }

        private void OpenSp(XmlWriter w, string name, bool isTitle, RectD box, bool oneLine, int quarterTurns = 0)
        {
            w.WriteStartElement("sp", P);
            w.WriteStartElement("nvSpPr", P);
            CNvPr(w, name);
            w.WriteStartElement("cNvSpPr", P);
            if (isTitle)
            {
                w.WriteStartElement("spLocks", A);
                w.WriteAttributeString("noGrp", "1");
                w.WriteEndElement();
            }
            else w.WriteAttributeString("txBox", "1");
            w.WriteEndElement();
            w.WriteStartElement("nvPr", P);
            if (isTitle)
            {
                w.WriteStartElement("ph", P);
                w.WriteAttributeString("type", "title");
                w.WriteEndElement();
            }
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteStartElement("spPr", P);
            Xfrm(w, box, A, quarterTurns);
            Geometry(w, "rect");
            w.WriteElementString("noFill", A, null);
            w.WriteEndElement();
            w.WriteStartElement("txBody", P);
            w.WriteStartElement("bodyPr", A);
            w.WriteAttributeString("wrap", oneLine ? "none" : "square");
            foreach (var inset in new[] { "lIns", "tIns", "rIns", "bIns" }) w.WriteAttributeString(inset, "0");
            w.WriteAttributeString("rtlCol", "0");
            w.WriteAttributeString("anchor", "t");
            w.WriteElementString("noAutofit", A, null);
            w.WriteEndElement();
            w.WriteElementString("lstStyle", A, null);
        }

        private static void CloseSp(XmlWriter w)
        {
            w.WriteEndElement();
            w.WriteEndElement();
        }

        /// <summary>A line reading sideways: its box, unturned about its center, is as long as the line.</summary>
        private void Turned(XmlWriter w, ExportLine line)
        {
            var b = line.Box;
            var turn = line.Reads;
            var box = turn % 2 == 1 ? new RectD(b.CenterX - b.Height / 2, b.CenterY - b.Width / 2, b.Height, b.Width) : b;
            OpenSp(w, "Text", false, box, oneLine: true, turn);
            w.WriteStartElement("p", A);
            foreach (var s in line.Spans) Run(w, s);
            w.WriteEndElement();
            CloseSp(w);
        }

        /// <param name="left">How far the paragraph sits from the box's left edge.</param>
        private void Paragraph(XmlWriter w, DocParagraph p, double spaceBefore, double left, bool inCell = false)
        {
            w.WriteStartElement("p", A);
            w.WriteStartElement("pPr", A);
            // The marker hangs 18 pt to the left of the text, as the Word export's lists do.
            var hang = p.List != ListKind.None ? 18 : p.FirstLine < 0 ? -p.FirstLine : 0;
            var first = p.List != ListKind.None ? -18 : p.FirstLine;
            var margin = Math.Max(0, left) + hang;
            if (margin > 0) w.WriteAttributeString("marL", Emu(margin * _scale));
            if (Math.Abs(first) > 0.01) w.WriteAttributeString("indent", Math.Round(first * _scale * 12700).ToString(CultureInfo.InvariantCulture));
            w.WriteAttributeString("algn", p.Align switch { TextAlign.Center => "ctr", TextAlign.Right => "r", _ => "l" });
            if (p.LineCount > 1 && p.LinePitch > 0)
            {
                w.WriteStartElement("lnSpc", A);
                SpcPts(w, p.LinePitch * _scale);
                w.WriteEndElement();
            }
            w.WriteStartElement("spcBef", A);
            SpcPts(w, spaceBefore * _scale);
            w.WriteEndElement();
            if (p.List == ListKind.Bullet)
            {
                w.WriteStartElement("buFont", A);
                w.WriteAttributeString("typeface", "Arial");
                w.WriteEndElement();
                w.WriteStartElement("buChar", A);
                w.WriteAttributeString("char", "•");
                w.WriteEndElement();
            }
            else w.WriteElementString("buNone", A, null);
            if (p.Tabs.Count > 0 && !inCell) Tabs(w, p);
            w.WriteEndElement();
            foreach (var s in p.Runs) Run(w, s);
            w.WriteEndElement();
        }

        /// <summary>Tab stops, measured from the box. PowerPoint's tabs have no leaders: the dots of a contents page aren't shown.</summary>
        private void Tabs(XmlWriter w, DocParagraph p)
        {
            var from = p.Indent + Math.Min(0, p.FirstLine);
            var stops = p.Tabs.Select(t => (Pos: t.Position - from, t.Right)).Where(t => t.Pos > 0).Take(32).ToList();
            if (stops.Count == 0) return;
            w.WriteStartElement("tabLst", A);
            foreach (var (pos, right) in stops)
            {
                w.WriteStartElement("tab", A);
                w.WriteAttributeString("pos", Emu(pos * _scale));
                w.WriteAttributeString("algn", right ? "r" : "l");
                w.WriteEndElement();
            }
            w.WriteEndElement();
        }

        private static void SpcPts(XmlWriter w, double pt)
        {
            w.WriteStartElement("spcPts", A);
            w.WriteAttributeString("val", Math.Clamp((int)Math.Round(pt * 100), 0, 158400).ToString(CultureInfo.InvariantCulture));
            w.WriteEndElement();
        }

        private void Run(XmlWriter w, ExportSpan s)
        {
            var text = OpenXmlParts.Clean(s.Text);
            if (text.Length == 0) return;
            var parts = text.Split('\n');
            for (var i = 0; i < parts.Length; i++)
            {
                if (i > 0)
                {
                    w.WriteStartElement("br", A);
                    RunProperties(w, s);
                    w.WriteEndElement();
                }
                if (parts[i].Length == 0) continue;
                w.WriteStartElement("r", A);
                RunProperties(w, s);
                w.WriteElementString("t", A, parts[i]);
                w.WriteEndElement();
            }
        }

        private void RunProperties(XmlWriter w, ExportSpan s)
        {
            w.WriteStartElement("rPr", A);
            if (lang is not null) w.WriteAttributeString("lang", lang);
            w.WriteAttributeString("sz", Hundredths(s.Size));
            w.WriteAttributeString("b", s.Bold ? "1" : "0");
            w.WriteAttributeString("i", s.Italic ? "1" : "0");
            SolidFill(w, s.Color);
            var font = OpenXmlParts.Cut(OpenXmlParts.Clean(FontNames.Family(s.Font)).Replace('\t', ' ').Replace('\n', ' ').Trim(), 31);
            if (font.Length > 0)
            {
                foreach (var kind in new[] { "latin", "cs" })
                {
                    w.WriteStartElement(kind, A);
                    w.WriteAttributeString("typeface", font);
                    w.WriteEndElement();
                }
            }
            w.WriteEndElement();
        }

        private string Hundredths(double size) => Math.Clamp((int)Math.Round(size * _scale * 100), 100, 400000).ToString(CultureInfo.InvariantCulture);

        // ---- tables ----

        private void Table(XmlWriter w, DocTable t)
        {
            var columns = Math.Max(t.ColumnWidths.Count, t.Rows.Select(r => r.Sum(c => Math.Max(1, c.ColSpan))).DefaultIfEmpty(0).Max());
            if (columns == 0 || t.Rows.Count == 0) return;
            var widths = Enumerable.Range(0, columns).Select(i => i < t.ColumnWidths.Count ? Math.Max(1, t.ColumnWidths[i]) : 36.0).ToList();
            var heights = Enumerable.Range(0, t.Rows.Count).Select(r => t.RowHeights is { } h && r < h.Count ? Math.Max(1, h[r]) : Math.Max(1, t.Box.Height / t.Rows.Count)).ToList();
            w.WriteStartElement("graphicFrame", P);
            w.WriteStartElement("nvGraphicFramePr", P);
            CNvPr(w, "Table");
            w.WriteStartElement("cNvGraphicFramePr", P);
            w.WriteStartElement("graphicFrameLocks", A);
            w.WriteAttributeString("noGrp", "1");
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteElementString("nvPr", P, null);
            w.WriteEndElement();
            Xfrm(w, new RectD(t.Box.X, t.Box.Y, widths.Sum(), heights.Sum()), P);
            w.WriteStartElement("graphic", A);
            w.WriteStartElement("graphicData", A);
            w.WriteAttributeString("uri", "http://schemas.openxmlformats.org/drawingml/2006/table");
            w.WriteStartElement("tbl", A);
            w.WriteElementString("tblPr", A, null);
            w.WriteStartElement("tblGrid", A);
            foreach (var width in widths)
            {
                w.WriteStartElement("gridCol", A);
                w.WriteAttributeString("w", Len(width));
                w.WriteEndElement();
            }
            w.WriteEndElement();
            for (var r = 0; r < t.Rows.Count; r++)
            {
                w.WriteStartElement("tr", A);
                w.WriteAttributeString("h", Len(heights[r]));
                var at = 0;
                foreach (var cell in t.Rows[r])
                {
                    if (at >= columns) break;
                    var span = Math.Min(Math.Max(1, cell.ColSpan), columns - at);
                    Cell(w, cell, span, t.Ruled);
                    for (var k = 1; k < span; k++) Cell(w, null, -1, t.Ruled);
                    at += span;
                }
                for (; at < columns; at++) Cell(w, null, 1, t.Ruled);
                w.WriteEndElement();
            }
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteEndElement();
        }

        /// <param name="span">Columns it spans; -1: a column another cell spans over.</param>
        private void Cell(XmlWriter w, DocCell? cell, int span, bool ruled)
        {
            w.WriteStartElement("tc", A);
            if (span > 1) w.WriteAttributeString("gridSpan", span.ToString(CultureInfo.InvariantCulture));
            if (span < 0) w.WriteAttributeString("hMerge", "1");
            w.WriteStartElement("txBody", A);
            w.WriteElementString("bodyPr", A, null);
            w.WriteElementString("lstStyle", A, null);
            var paragraphs = cell?.Paragraphs.Where(p => p.Text.Length > 0).ToList() ?? [];
            if (paragraphs.Count == 0)
            {
                // Small, or an empty cell's default 18 pt would make its row taller.
                w.WriteStartElement("p", A);
                w.WriteStartElement("endParaRPr", A);
                w.WriteAttributeString("sz", "600");
                w.WriteEndElement();
                w.WriteEndElement();
            }
            foreach (var p in paragraphs) Paragraph(w, p, 0, 0, inCell: true);
            w.WriteEndElement();
            w.WriteStartElement("tcPr", A);
            foreach (var margin in new[] { "marL", "marR" }) w.WriteAttributeString(margin, Emu(2 * _scale));
            foreach (var margin in new[] { "marT", "marB" }) w.WriteAttributeString(margin, Emu(1 * _scale));
            if (ruled)
                foreach (var side in new[] { "lnL", "lnR", "lnT", "lnB" })
                {
                    w.WriteStartElement(side, A);
                    w.WriteAttributeString("w", Emu(Math.Max(0.25, 0.75 * _scale)));
                    SolidFill(w, 0);
                    w.WriteEndElement();
                }
            w.WriteElementString("noFill", A, null);
            w.WriteEndElement();
            w.WriteEndElement();
        }
    }

    // ---- the parts that are always the same ----

    private const string Ns = $"xmlns:a=\"{A}\" xmlns:r=\"{R}\" xmlns:p=\"{P}\"";
    private const string Header = "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>\n";
    private const string TreeStart = "<p:spTree><p:nvGrpSpPr><p:cNvPr id=\"1\" name=\"\"/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/>";

    private static string TitleSp(string shapeProperties) =>
        "<p:sp><p:nvSpPr><p:cNvPr id=\"2\" name=\"Title 1\"/><p:cNvSpPr><a:spLocks noGrp=\"1\"/></p:cNvSpPr><p:nvPr><p:ph type=\"title\"/></p:nvPr></p:nvSpPr>" +
        shapeProperties + "<p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:rPr lang=\"en-US\"/><a:t>Title</a:t></a:r></a:p></p:txBody></p:sp>";

    private static string Layout(string type, string name, string shapes) =>
        $"{Header}<p:sldLayout {Ns} type=\"{type}\" preserve=\"1\"><p:cSld name=\"{name}\">{TreeStart}{shapes}</p:spTree></p:cSld>" +
        "<p:clrMapOvr><a:masterClrMapping/></p:clrMapOvr></p:sldLayout>";

    private static string Master(double width, double height)
    {
        const string level = "<a:lvl1pPr marL=\"0\" indent=\"0\" algn=\"l\"><a:buNone/><a:defRPr sz=\"1800\"><a:solidFill><a:schemeClr val=\"tx1\"/></a:solidFill><a:latin typeface=\"+mn-lt\"/></a:defRPr></a:lvl1pPr>";
        var titleBox = $"<p:spPr><a:xfrm><a:off x=\"0\" y=\"0\"/><a:ext cx=\"{Emu(width)}\" cy=\"{Emu(Math.Min(72, height))}\"/></a:xfrm><a:prstGeom prst=\"rect\"><a:avLst/></a:prstGeom></p:spPr>";
        return $"{Header}<p:sldMaster {Ns}><p:cSld><p:bg><p:bgRef idx=\"1001\"><a:schemeClr val=\"bg1\"/></p:bgRef></p:bg>{TreeStart}{TitleSp(titleBox)}</p:spTree></p:cSld>" +
               "<p:clrMap bg1=\"lt1\" tx1=\"dk1\" bg2=\"lt2\" tx2=\"dk2\" accent1=\"accent1\" accent2=\"accent2\" accent3=\"accent3\" accent4=\"accent4\" accent5=\"accent5\" accent6=\"accent6\" hlink=\"hlink\" folHlink=\"folHlink\"/>" +
               "<p:sldLayoutIdLst><p:sldLayoutId id=\"2147483649\" r:id=\"rId1\"/><p:sldLayoutId id=\"2147483650\" r:id=\"rId2\"/></p:sldLayoutIdLst>" +
               $"<p:txStyles><p:titleStyle>{level}</p:titleStyle><p:bodyStyle>{level}</p:bodyStyle><p:otherStyle>{level}</p:otherStyle></p:txStyles></p:sldMaster>";
    }

    private static readonly string Theme = BuildTheme();

    private static string BuildTheme()
    {
        static string Color(string name, string rgb) => $"<a:{name}><a:srgbClr val=\"{rgb}\"/></a:{name}>";
        const string fill = "<a:solidFill><a:schemeClr val=\"phClr\"/></a:solidFill>";
        var line = $"<a:ln w=\"9525\">{fill}</a:ln>";
        const string effect = "<a:effectStyle><a:effectLst/></a:effectStyle>";
        const string font = "<a:latin typeface=\"Arial\"/><a:ea typeface=\"\"/><a:cs typeface=\"\"/>";
        return $"{Header}<a:theme xmlns:a=\"{A}\" name=\"Inkvolt\"><a:themeElements><a:clrScheme name=\"Inkvolt\">" +
               Color("dk1", "000000") + Color("lt1", "FFFFFF") + Color("dk2", "44546A") + Color("lt2", "E7E6E6") +
               Color("accent1", "4472C4") + Color("accent2", "ED7D31") + Color("accent3", "A5A5A5") + Color("accent4", "FFC000") +
               Color("accent5", "5B9BD5") + Color("accent6", "70AD47") + Color("hlink", "0563C1") + Color("folHlink", "954F72") +
               $"</a:clrScheme><a:fontScheme name=\"Inkvolt\"><a:majorFont>{font}</a:majorFont><a:minorFont>{font}</a:minorFont></a:fontScheme>" +
               $"<a:fmtScheme name=\"Inkvolt\"><a:fillStyleLst>{fill}{fill}{fill}</a:fillStyleLst><a:lnStyleLst>{line}{line}{line}</a:lnStyleLst>" +
               $"<a:effectStyleLst>{effect}{effect}{effect}</a:effectStyleLst><a:bgFillStyleLst>{fill}{fill}{fill}</a:bgFillStyleLst></a:fmtScheme></a:themeElements></a:theme>";
    }
}
