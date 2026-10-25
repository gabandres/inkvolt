using System.Globalization;
using System.IO.Compression;
using System.Text;
using System.Xml;

namespace InkvoltPdf.Core;

/// <summary>
/// Writes a Word document (.docx, Office Open XML) from laid-out pages: paragraphs with their fonts, sizes, bold, italic
/// and colors; headings as Heading 1-6 (so they show in Word's navigation pane); bullets as Word bullets; tables; pictures
/// inline; each PDF page its own section (its size and orientation), so pages break where the PDF's did. Pictures are
/// stored as they are added (<see cref="AddImage"/>), so a long document's images needn't all be held in memory.
/// </summary>
internal sealed class DocxWriter : IDisposable
{
    private const string W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main";
    private const string R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string WP = "http://schemas.openxmlformats.org/drawingml/2006/wordprocessingDrawing";
    private const string A = "http://schemas.openxmlformats.org/drawingml/2006/main";
    private const string Pic = "http://schemas.openxmlformats.org/drawingml/2006/picture";
    private const string RelBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/";

    private readonly ZipArchive _zip;
    private readonly List<(string Id, string Type, string Target)> _rels = [];
    private readonly Dictionary<string, string> _byContent = [];  // SHA-256 of a picture -> its id
    private readonly Dictionary<string, string> _targets = [];    // id -> media part
    private int _media;
    private int _drawing;
    // The fonts the runs name, with what kind of font each is (for Word's font table, so a missing one is replaced well).
    private readonly Dictionary<string, (bool Serif, bool Mono)> _fonts = new(StringComparer.OrdinalIgnoreCase);
    // The share of the page's spacing the page being written keeps (less than 1 when it wouldn't fit on one Word page).
    private double _spacing = 1;
    private bool _finished;

    public DocxWriter(Stream output) => _zip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true);

    /// <summary>
    /// Stores a picture (PNG or JPEG bytes) and returns its id for <see cref="ExportImage.Ref"/>. The same picture again
    /// (a logo on every page, an icon in every row) is stored once and gets the same id.
    /// </summary>
    public string AddImage(byte[] data, string extension)
    {
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(data));
        if (_byContent.TryGetValue(hash, out var known)) return known;
        _media++;
        var ext = extension == "jpeg" ? "jpeg" : "png";
        var target = $"media/image{_media}.{ext}";
        var entry = _zip.CreateEntry("word/" + target, CompressionLevel.NoCompression); // already compressed
        using (var s = entry.Open()) s.Write(data);
        var id = $"rIdImg{_media}";
        _rels.Add((id, RelBase + "image", target));
        _targets[id] = target;
        _byContent[hash] = id;
        return id;
    }

    public void Finish(DocLayoutResult layout, string? title)
    {
        if (_finished) throw new InvalidOperationException("Already finished.");
        _finished = true;
        var pages = layout.Pages;
        var body = pages.SelectMany(p => p.Blocks.OfType<DocParagraph>()).Where(p => p.HeadingLevel == 0)
            .GroupBy(p => p.Size).MaxBy(g => g.Sum(p => p.Text.Length))?.Key ?? 11;
        _rels.Add(("rIdStyles", RelBase + "styles", "styles.xml"));
        _rels.Add(("rIdNumbering", RelBase + "numbering", "numbering.xml"));
        _rels.Add(("rIdSettings", RelBase + "settings", "settings.xml"));
        _rels.Add(("rIdFontTable", RelBase + "fontTable", "fontTable.xml"));

        var parts = new List<(string Part, string Type)>();
        var textWidth = pages.Count > 0 ? new Section(pages[0]).TextWidth : 468;
        foreach (var (running, kind, id) in new[] { (layout.Header, "header", HeaderId), (layout.Footer, "footer", FooterId) })
        {
            if (running is null) continue;
            if (Enumerable.Range(0, pages.Count).Any(i => !running.OnPages.Contains(i)))
            {
                // Pages that had none of it (a cover page) point at an empty one.
                _rels.Add((id + "None", RelBase + kind, $"{kind}2.xml"));
                Entry($"word/{kind}2.xml", w => Running(w, kind == "header" ? "hdr" : "ftr", new DocRunning([]), textWidth));
                parts.Add(($"/word/{kind}2.xml", $"application/vnd.openxmlformats-officedocument.wordprocessingml.{kind}+xml"));
            }
            _rels.Add((id, RelBase + kind, $"{kind}1.xml"));
            Entry($"word/{kind}1.xml", w => Running(w, kind == "header" ? "hdr" : "ftr", running, textWidth));
            var pictures = running.Pictures.Select(p => p.Image.Ref).OfType<string>().Distinct().ToList();
            if (pictures.Count > 0)
                Entry($"word/_rels/{kind}1.xml.rels", w => Relationships(w, pictures.Select(r => (r, RelBase + "image", _targets[r]))));
            parts.Add(($"/word/{kind}1.xml", $"application/vnd.openxmlformats-officedocument.wordprocessingml.{kind}+xml"));
        }
        Entry("word/document.xml", w => Document(w, pages, layout.Header, layout.Footer));
        Entry("word/styles.xml", w => Styles(w, body));
        Entry("word/numbering.xml", Numbering);
        Entry("word/settings.xml", Settings);
        Entry("word/fontTable.xml", FontTable);
        Entry("word/_rels/document.xml.rels", w => Relationships(w, _rels));
        Entry("_rels/.rels", w => Relationships(w,
        [
            ("rId1", RelBase + "officeDocument", "word/document.xml"),
            ("rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml"),
            ("rId3", RelBase + "extended-properties", "docProps/app.xml"),
        ]));
        Entry("docProps/core.xml", w => OpenXmlParts.CoreProperties(w, title));
        Entry("docProps/app.xml", OpenXmlParts.AppProperties);
        Entry("[Content_Types].xml", w => OpenXmlParts.ContentTypes(w,
        [
            ("/word/document.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"),
            ("/word/styles.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.styles+xml"),
            ("/word/numbering.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.numbering+xml"),
            ("/word/settings.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.settings+xml"),
            ("/word/fontTable.xml", "application/vnd.openxmlformats-officedocument.wordprocessingml.fontTable+xml"),
            .. parts,
        ]));
    }

    public void Dispose() => _zip.Dispose();

    private void Entry(string name, Action<XmlWriter> write) => OpenXmlParts.Entry(_zip, name, write);

    private static void Relationships(XmlWriter w, IEnumerable<(string Id, string Type, string Target)> rels)
    {
        w.WriteStartElement("Relationships", "http://schemas.openxmlformats.org/package/2006/relationships");
        foreach (var (id, type, target) in rels)
        {
            w.WriteStartElement("Relationship", "http://schemas.openxmlformats.org/package/2006/relationships");
            w.WriteAttributeString("Id", id);
            w.WriteAttributeString("Type", type);
            w.WriteAttributeString("Target", target);
            w.WriteEndElement();
        }
        w.WriteEndElement();
    }

    // ---- document.xml ----

    private const string HeaderId = "rIdHeader";
    private const string FooterId = "rIdFooter";

    private void Document(XmlWriter w, IReadOnlyList<DocPage> pages, DocRunning? header, DocRunning? footer)
    {
        w.WriteStartElement("w", "document", W);
        w.WriteAttributeString("xmlns", "r", null, R);
        w.WriteAttributeString("xmlns", "wp", null, WP);
        w.WriteAttributeString("xmlns", "a", null, A);
        w.WriteAttributeString("xmlns", "pic", null, Pic);
        w.WriteStartElement("body", W);
        if (pages.Count == 0) Paragraph(w, null, null, 0);
        for (var i = 0; i < pages.Count; i++)
        {
            var page = pages[i];
            var section = new Section(page)
            {
                Header = header is null ? null : header.OnPages.Contains(i) ? HeaderId : HeaderId + "None",
                Footer = footer is null ? null : footer.OnPages.Contains(i) ? FooterId : FooterId + "None",
            };
            var last = i == pages.Count - 1;
            var blocks = page.Blocks;
            _spacing = SpacingToFit(page, section);
            for (var b = 0; b < blocks.Count; b++)
            {
                // A page's last paragraph carries its section (size, margins); the last page's section closes the body.
                var carries = !last && b == blocks.Count - 1 && blocks[b] is not DocTable ? section : null;
                switch (blocks[b])
                {
                    case DocParagraph p:
                        Paragraph(w, p, carries, section.TextWidth);
                        break;
                    case DocPicture pic:
                        Picture(w, pic, page, section, carries);
                        break;
                    case DocTable t:
                        if (b > 0 && blocks[b - 1] is DocTable above)
                        {
                            // Word joins two tables with nothing between them into one: a paragraph keeps them apart,
                            // as tall as the gap the page leaves.
                            var gap = Math.Max(0, t.Box.Y - above.Box.Bottom) * _spacing;
                            w.WriteStartElement("p", W);
                            w.WriteStartElement("pPr", W);
                            w.WriteStartElement("spacing", W);
                            w.WriteAttributeString("w", "before", W, "0");
                            w.WriteAttributeString("w", "after", W, "0");
                            w.WriteAttributeString("w", "line", W, Twips(Math.Clamp(gap, 1, 200)));
                            w.WriteAttributeString("w", "lineRule", W, "exact");
                            w.WriteEndElement();
                            w.WriteEndElement();
                            w.WriteEndElement();
                        }
                        Table(w, t, section);
                        break;
                }
            }
            if (!last && (blocks.Count == 0 || blocks[^1] is DocTable)) Paragraph(w, null, section, 0);
            if (last)
            {
                if (blocks.Count == 0 || blocks[^1] is DocTable) Paragraph(w, null, null, 0); // Word wants the body to end with a paragraph
                SectionProperties(w, section);
            }
        }
        if (pages.Count == 0) SectionProperties(w, new Section(new DocPage(612, 792, default, [])));
        w.WriteEndElement();
        w.WriteEndElement();
    }

    /// <summary>Word's line height for one line of type (single spacing), as a share of the size, rounded up.</summary>
    private const double LineHeight = 1.2;

    /// <summary>
    /// How much of the page's spacing to keep so that it fits on one Word page as it did in the PDF: 1 when it fits,
    /// less when the lines (as tall as Word makes them, which is often taller than the PDF set them), tables and
    /// pictures leave less room than the page's gaps need; 1 too when they overflow the page whatever the spacing. Text
    /// that wraps differently in Word isn't known here.
    /// </summary>
    private static double SpacingToFit(DocPage page, Section section)
    {
        var available = (section.Height - section.Top - section.Bottom) * 0.97;
        double content = 0, space = 0;
        static double Lines(DocParagraph p) => p.LineCount * LineHeight * Math.Max(1, p.Size);
        for (var b = 0; b < page.Blocks.Count; b++)
        {
            switch (page.Blocks[b])
            {
                case DocParagraph p:
                    content += Lines(p);
                    space += p.SpaceBefore is null ? 6 : p.SpaceBefore.Value + (p.SpaceAfter ?? 0);
                    break;
                case DocTable t:
                    for (var r = 0; r < t.Rows.Count; r++)
                    {
                        var text = t.Rows[r].Select(c => c.Paragraphs.Sum(p => Lines(p) + (p.SpaceBefore ?? 0))).DefaultIfEmpty(0).Max();
                        content += Math.Max(text, t.RowHeights is { } h && r < h.Count ? h[r] : 0);
                    }
                    if (b > 0 && page.Blocks[b - 1] is DocTable above) space += Math.Max(0, t.Box.Y - above.Box.Bottom);
                    break;
                case DocPicture pic:
                    content += Math.Min(pic.Box.Height, section.Height - section.Top - section.Bottom);
                    break;
            }
        }
        // Fits, or can't fit whatever the spacing (columns run into one, a long table): the page's spacing stays.
        if (content + space <= available || space <= 0 || content >= available) return 1;
        return Math.Clamp((available - content) / space, 0, 1);
    }

    /// <summary>A PDF page as a Word section: its size, and margins from where its content sits (between 0.25 and 1 inch).</summary>
    private sealed class Section
    {
        public Section(DocPage page)
        {
            Width = Math.Clamp(page.Width, 72, 1584); // Word's page size limits: 1 to 22 inches
            Height = Math.Clamp(page.Height, 72, 1584);
            var c = page.Content;
            var empty = c.Width <= 0 || c.Height <= 0;
            Left = empty ? 72 : Math.Clamp(c.X, 18, 72);
            Right = empty ? 72 : Math.Clamp(page.Width - c.Right, 18, 72);
            Top = empty ? 72 : Math.Clamp(c.Y, 18, 72);
            Bottom = empty ? 72 : Math.Clamp(page.Height - c.Bottom, 18, 72);
            if (Width - Left - Right < 72) Left = Right = 18;
            if (Height - Top - Bottom < 72) Top = Bottom = 18;
            ContentLeft = empty ? Left : c.X;
        }

        public double Width { get; }
        public double Height { get; }
        public double Left { get; }
        public double Right { get; }
        public double Top { get; }
        public double Bottom { get; }
        /// <summary>Where the page's content starts on the PDF page (indents are measured from the margin, which may differ).</summary>
        public double ContentLeft { get; }
        public double TextWidth => Width - Left - Right;
        /// <summary>The header and footer parts the section shows (relationship ids), if any.</summary>
        public string? Header { get; init; }
        public string? Footer { get; init; }
    }

    private static string Twips(double pt) => Math.Round(pt * 20).ToString(CultureInfo.InvariantCulture);
    private static string Emu(double pt) => Math.Round(pt * 12700).ToString(CultureInfo.InvariantCulture);

    private static void SectionProperties(XmlWriter w, Section s)
    {
        w.WriteStartElement("sectPr", W);
        foreach (var (id, element) in new[] { (s.Header, "headerReference"), (s.Footer, "footerReference") })
        {
            if (id is null) continue;
            w.WriteStartElement(element, W);
            w.WriteAttributeString("w", "type", W, "default");
            w.WriteAttributeString("r", "id", R, id);
            w.WriteEndElement();
        }
        w.WriteStartElement("pgSz", W);
        w.WriteAttributeString("w", "w", W, Twips(s.Width));
        w.WriteAttributeString("w", "h", W, Twips(s.Height));
        if (s.Width > s.Height) w.WriteAttributeString("w", "orient", W, "landscape");
        w.WriteEndElement();
        w.WriteStartElement("pgMar", W);
        w.WriteAttributeString("w", "top", W, Twips(s.Top));
        w.WriteAttributeString("w", "right", W, Twips(s.Right));
        w.WriteAttributeString("w", "bottom", W, Twips(s.Bottom));
        w.WriteAttributeString("w", "left", W, Twips(s.Left));
        w.WriteAttributeString("w", "header", W, Twips(Math.Min(36, s.Top / 2)));
        w.WriteAttributeString("w", "footer", W, Twips(Math.Min(36, s.Bottom / 2)));
        w.WriteAttributeString("w", "gutter", W, "0");
        w.WriteEndElement();
        w.WriteEndElement();
    }

    private static void Val(XmlWriter w, string element, string value)
    {
        w.WriteStartElement(element, W);
        w.WriteAttributeString("w", "val", W, value);
        w.WriteEndElement();
    }

    /// <summary>A paragraph (null: an empty one), optionally ending a section. <paramref name="width"/>: the text width, to cap indents.</summary>
    private void Paragraph(XmlWriter w, DocParagraph? p, Section? endsSection, double width, bool inCell = false)
    {
        w.WriteStartElement("p", W);
        var style = p is null ? null : p.HeadingLevel > 0 ? $"Heading{p.HeadingLevel}" : p.List != ListKind.None ? "ListParagraph" : null;
        var hasPPr = style is not null || endsSection is not null || inCell || (p is not null && (p.Align != TextAlign.Left || p.Indent > 0
            || p.FirstLine != 0 || p.List != ListKind.None || p.Tabs.Count > 0 || p.SpaceBefore is not null));
        if (hasPPr)
        {
            w.WriteStartElement("pPr", W);
            if (style is not null) Val(w, "pStyle", style);
            if (p?.List == ListKind.Bullet)
            {
                w.WriteStartElement("numPr", W);
                Val(w, "ilvl", "0");
                Val(w, "numId", "1");
                w.WriteEndElement();
            }
            if (p is { Tabs.Count: > 0 })
            {
                // Positions from the margin (or the cell's edge), within the text width.
                w.WriteStartElement("tabs", W);
                var last = -1.0;
                foreach (var tab in p.Tabs)
                {
                    // Stops in order, none twice (one clamped to the width stands for all past it).
                    var pos = Math.Clamp(tab.Position, 0, Math.Max(0, width));
                    if (pos <= last + 0.5) continue;
                    last = pos;
                    w.WriteStartElement("tab", W);
                    w.WriteAttributeString("w", "val", W, tab.Right ? "right" : "left");
                    if (tab.Leader != '\0')
                        w.WriteAttributeString("w", "leader", W, tab.Leader switch { '_' => "underscore", '-' => "hyphen", _ => "dot" });
                    w.WriteAttributeString("w", "pos", W, Twips(pos));
                    w.WriteEndElement();
                }
                w.WriteEndElement();
            }
            if (inCell || p?.SpaceBefore is not null)
            {
                w.WriteStartElement("spacing", W);
                if (p?.SpaceBefore is { } before) w.WriteAttributeString("w", "before", W, Twips(before * _spacing));
                w.WriteAttributeString("w", "after", W, Twips(inCell ? 0 : (p?.SpaceAfter ?? 0) * _spacing));
                w.WriteEndElement();
            }
            if (p is not null && (p.Indent > 0 || p.FirstLine != 0 || p.List != ListKind.None))
            {
                var cap = Math.Max(0, width / 2);
                var left = Math.Min(p.Indent, cap);
                w.WriteStartElement("ind", W);
                if (p.List != ListKind.None)
                {
                    // The marker hangs 18 pt to the left of the text, as Word's own lists do.
                    w.WriteAttributeString("w", "left", W, Twips(left + 18));
                    w.WriteAttributeString("w", "hanging", W, Twips(18));
                }
                else
                {
                    w.WriteAttributeString("w", "left", W, Twips(left));
                    if (p.FirstLine > 0) w.WriteAttributeString("w", "firstLine", W, Twips(Math.Min(p.FirstLine, cap)));
                    else if (p.FirstLine < 0) w.WriteAttributeString("w", "hanging", W, Twips(Math.Min(-p.FirstLine, left)));
                }
                w.WriteEndElement();
            }
            // The page's spacing applies between list items too (List Paragraph's style would drop it).
            if (p?.SpaceBefore is not null && style == "ListParagraph") Val(w, "contextualSpacing", "0");
            if (p?.Align == TextAlign.Center) Val(w, "jc", "center");
            else if (p?.Align == TextAlign.Right) Val(w, "jc", "right");
            if (endsSection is not null) SectionProperties(w, endsSection);
            w.WriteEndElement();
        }
        if (p is not null)
            foreach (var run in p.Runs) Run(w, run);
        w.WriteEndElement();
    }

    private void Run(XmlWriter w, ExportSpan s)
    {
        var text = OpenXmlParts.Clean(s.Text);
        if (text.Length == 0) return;
        w.WriteStartElement("r", W);
        w.WriteStartElement("rPr", W);
        var font = OpenXmlParts.Clean(FontNames.Family(s.Font)).Trim();
        font = OpenXmlParts.Cut(font, 31); // Windows font names are at most 31 characters
        if (font.Length > 0)
        {
            _fonts.TryAdd(font, (s.Serif, s.Mono));
            w.WriteStartElement("rFonts", W);
            w.WriteAttributeString("w", "ascii", W, font);
            w.WriteAttributeString("w", "hAnsi", W, font);
            w.WriteAttributeString("w", "cs", W, font);
            w.WriteEndElement();
        }
        if (s.Bold) w.WriteElementString("b", W, null);
        if (s.Italic) w.WriteElementString("i", W, null);
        if ((s.Color & 0xFFFFFF) != 0) Val(w, "color", (s.Color & 0xFFFFFF).ToString("X6", CultureInfo.InvariantCulture));
        var half = Math.Clamp((int)Math.Round(s.Size * 2), 2, 3276).ToString(CultureInfo.InvariantCulture);
        Val(w, "sz", half);
        Val(w, "szCs", half);
        w.WriteEndElement();
        // Tabs in the text become Word tabs.
        var parts = text.Split('\t');
        for (var i = 0; i < parts.Length; i++)
        {
            if (i > 0) w.WriteElementString("tab", W, null);
            if (parts[i].Length == 0) continue;
            w.WriteStartElement("t", W);
            w.WriteAttributeString("xml", "space", null, "preserve");
            w.WriteString(parts[i]);
            w.WriteEndElement();
        }
        w.WriteEndElement();
    }

    private void Picture(XmlWriter w, DocPicture pic, DocPage page, Section section, Section? endsSection)
    {
        if (pic.Image.Ref is not { } rel) return;
        var scale = Math.Min(1, Math.Min(section.TextWidth / Math.Max(1, pic.Box.Width), (section.Height - section.Top - section.Bottom) / Math.Max(1, pic.Box.Height)));
        double cx = pic.Box.Width * scale, cy = pic.Box.Height * scale;
        w.WriteStartElement("p", W);
        var centered = page.Content.Width > 0 && Math.Abs(pic.Box.CenterX - page.Content.CenterX) <= Math.Max(6, 0.03 * page.Content.Width)
                       && pic.Box.Width < 0.9 * page.Content.Width;
        var indent = Math.Clamp(pic.Box.X - section.ContentLeft, 0, Math.Max(0, section.TextWidth - cx));
        if (centered || indent > 6 || endsSection is not null)
        {
            w.WriteStartElement("pPr", W);
            if (!centered && indent > 6)
            {
                w.WriteStartElement("ind", W);
                w.WriteAttributeString("w", "left", W, Twips(indent));
                w.WriteEndElement();
            }
            if (centered) Val(w, "jc", "center");
            if (endsSection is not null) SectionProperties(w, endsSection);
            w.WriteEndElement();
        }
        Inline(w, rel, cx, cy);
        w.WriteEndElement(); // p
    }

    /// <summary>A run holding an inline picture of <paramref name="cx"/> by <paramref name="cy"/> points.</summary>
    private void Inline(XmlWriter w, string rel, double cx, double cy)
    {
        _drawing++;
        w.WriteStartElement("r", W);
        w.WriteStartElement("drawing", W);
        w.WriteStartElement("wp", "inline", WP);
        foreach (var d in new[] { "distT", "distB", "distL", "distR" }) w.WriteAttributeString(d, "0");
        w.WriteStartElement("wp", "extent", WP);
        w.WriteAttributeString("cx", Emu(cx));
        w.WriteAttributeString("cy", Emu(cy));
        w.WriteEndElement();
        w.WriteStartElement("wp", "docPr", WP);
        w.WriteAttributeString("id", _drawing.ToString(CultureInfo.InvariantCulture));
        w.WriteAttributeString("name", $"Picture {_drawing}");
        w.WriteEndElement();
        w.WriteStartElement("wp", "cNvGraphicFramePr", WP);
        w.WriteStartElement("a", "graphicFrameLocks", A);
        w.WriteAttributeString("noChangeAspect", "1");
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteStartElement("a", "graphic", A);
        w.WriteStartElement("a", "graphicData", A);
        w.WriteAttributeString("uri", Pic);
        w.WriteStartElement("pic", "pic", Pic);
        w.WriteStartElement("pic", "nvPicPr", Pic);
        w.WriteStartElement("pic", "cNvPr", Pic);
        w.WriteAttributeString("id", _drawing.ToString(CultureInfo.InvariantCulture));
        w.WriteAttributeString("name", $"Picture {_drawing}");
        w.WriteEndElement();
        w.WriteElementString("pic", "cNvPicPr", Pic, null);
        w.WriteEndElement();
        w.WriteStartElement("pic", "blipFill", Pic);
        w.WriteStartElement("a", "blip", A);
        w.WriteAttributeString("r", "embed", R, rel);
        w.WriteEndElement();
        w.WriteStartElement("a", "stretch", A);
        w.WriteElementString("a", "fillRect", A, null);
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteStartElement("pic", "spPr", Pic);
        w.WriteStartElement("a", "xfrm", A);
        w.WriteStartElement("a", "off", A);
        w.WriteAttributeString("x", "0");
        w.WriteAttributeString("y", "0");
        w.WriteEndElement();
        w.WriteStartElement("a", "ext", A);
        w.WriteAttributeString("cx", Emu(cx));
        w.WriteAttributeString("cy", Emu(cy));
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteStartElement("a", "prstGeom", A);
        w.WriteAttributeString("prst", "rect");
        w.WriteElementString("a", "avLst", A, null);
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteEndElement(); // pic
        w.WriteEndElement(); // graphicData
        w.WriteEndElement(); // graphic
        w.WriteEndElement(); // inline
        w.WriteEndElement(); // drawing
        w.WriteEndElement(); // r
    }

    private void Table(XmlWriter w, DocTable t, Section section)
    {
        var total = t.ColumnWidths.Sum();
        var scale = total > section.TextWidth && total > 0 ? section.TextWidth / total : 1;
        var widths = t.ColumnWidths.Select(c => Math.Max(12, c * scale)).ToList();
        var indent = Math.Clamp(t.Box.X - section.ContentLeft, 0, Math.Max(0, section.TextWidth - widths.Sum()));
        w.WriteStartElement("tbl", W);
        w.WriteStartElement("tblPr", W);
        w.WriteStartElement("tblW", W);
        w.WriteAttributeString("w", "w", W, Twips(widths.Sum()));
        w.WriteAttributeString("w", "type", W, "dxa");
        w.WriteEndElement();
        if (indent > 1)
        {
            w.WriteStartElement("tblInd", W);
            w.WriteAttributeString("w", "w", W, Twips(indent));
            w.WriteAttributeString("w", "type", W, "dxa");
            w.WriteEndElement();
        }
        w.WriteStartElement("tblBorders", W);
        foreach (var side in new[] { "top", "left", "bottom", "right", "insideH", "insideV" })
        {
            w.WriteStartElement(side, W);
            w.WriteAttributeString("w", "val", W, t.Ruled ? "single" : "none");
            w.WriteAttributeString("w", "sz", W, t.Ruled ? "4" : "0");
            w.WriteAttributeString("w", "space", W, "0");
            w.WriteAttributeString("w", "color", W, "auto");
            w.WriteEndElement();
        }
        w.WriteEndElement();
        w.WriteStartElement("tblLayout", W);
        w.WriteAttributeString("w", "type", W, "fixed");
        w.WriteEndElement();
        // Narrow cell padding (Word's default is 5.4 pt a side), so tight PDF columns of numbers don't wrap digit by digit.
        w.WriteStartElement("tblCellMar", W);
        foreach (var side in new[] { "left", "right" })
        {
            w.WriteStartElement(side, W);
            w.WriteAttributeString("w", "w", W, Twips(Math.Clamp((widths.Count > 0 ? widths.Min() : 90) * 0.06, 1, 5.4)));
            w.WriteAttributeString("w", "type", W, "dxa");
            w.WriteEndElement();
        }
        w.WriteEndElement();
        w.WriteEndElement(); // tblPr
        w.WriteStartElement("tblGrid", W);
        foreach (var c in widths)
        {
            w.WriteStartElement("gridCol", W);
            w.WriteAttributeString("w", "w", W, Twips(c));
            w.WriteEndElement();
        }
        w.WriteEndElement();
        var rowIndex = 0;
        foreach (var row in t.Rows)
        {
            w.WriteStartElement("tr", W);
            if (t.RowHeights is { } heights && rowIndex < heights.Count && heights[rowIndex] > 1)
            {
                // At least as tall as on the page (a form's empty boxes keep their room to write in).
                w.WriteStartElement("trPr", W);
                w.WriteStartElement("trHeight", W);
                w.WriteAttributeString("w", "val", W, Twips(heights[rowIndex]));
                w.WriteAttributeString("w", "hRule", W, "atLeast");
                w.WriteEndElement();
                w.WriteEndElement();
            }
            rowIndex++;
            var col = 0;
            foreach (var cell in row)
            {
                var span = Math.Max(1, Math.Min(cell.ColSpan, widths.Count - col));
                var cw = widths.Skip(col).Take(span).Sum();
                col += span;
                w.WriteStartElement("tc", W);
                w.WriteStartElement("tcPr", W);
                w.WriteStartElement("tcW", W);
                w.WriteAttributeString("w", "w", W, Twips(cw));
                w.WriteAttributeString("w", "type", W, "dxa");
                w.WriteEndElement();
                if (span > 1) Val(w, "gridSpan", span.ToString(CultureInfo.InvariantCulture));
                w.WriteEndElement();
                if (cell.Paragraphs.Count == 0 && cell.Pictures.Count == 0) Paragraph(w, null, null, cw, inCell: true);
                // Text and pictures top to bottom; indents are from the cell's edge.
                foreach (var block in cell.Paragraphs.Cast<DocBlock>().Concat(cell.Pictures).OrderBy(b => b.Box.Y))
                {
                    if (block is DocParagraph p) Paragraph(w, p, null, cw, inCell: true);
                    else if (block is DocPicture { Image.Ref: { } rel } pic) CellPicture(w, pic, rel, cw);
                }
                w.WriteEndElement();
            }
            if (col == 0) // a row needs a cell
            {
                w.WriteStartElement("tc", W);
                Paragraph(w, null, null, 0, inCell: true);
                w.WriteEndElement();
            }
            w.WriteEndElement();
        }
        w.WriteEndElement();
    }

    /// <summary>A picture in a table cell: its own paragraph, centered when it sat in the middle, no wider than the cell.</summary>
    private void CellPicture(XmlWriter w, DocPicture pic, string rel, double cellWidth)
    {
        var scale = Math.Min(1, Math.Max(1, cellWidth - 10) / Math.Max(1, pic.Box.Width));
        w.WriteStartElement("p", W);
        w.WriteStartElement("pPr", W);
        w.WriteStartElement("spacing", W);
        w.WriteAttributeString("w", "after", W, "0");
        w.WriteEndElement();
        Val(w, "jc", "center");
        w.WriteEndElement();
        Inline(w, rel, pic.Box.Width * scale, pic.Box.Height * scale);
        w.WriteEndElement();
    }

    /// <summary>
    /// A header or footer part: each row one paragraph with a centered tab in the middle and a right tab at the margin,
    /// so left, middle and right parts land where they were; the page number is Word's PAGE field.
    /// </summary>
    private void Running(XmlWriter w, string root, DocRunning running, double textWidth)
    {
        w.WriteStartElement("w", root, W);
        w.WriteAttributeString("xmlns", "r", null, R);
        w.WriteAttributeString("xmlns", "wp", null, WP);
        w.WriteAttributeString("xmlns", "a", null, A);
        w.WriteAttributeString("xmlns", "pic", null, Pic);
        foreach (var (zone, image) in running.Pictures)
        {
            if (image.Ref is null) continue;
            var scale = Math.Min(1, textWidth / Math.Max(1, image.Box.Width));
            w.WriteStartElement("p", W);
            w.WriteStartElement("pPr", W);
            w.WriteStartElement("spacing", W);
            w.WriteAttributeString("w", "after", W, "0");
            w.WriteEndElement();
            if (zone != TextAlign.Left) Val(w, "jc", zone == TextAlign.Center ? "center" : "right");
            w.WriteEndElement();
            Inline(w, image.Ref, image.Box.Width * scale, image.Box.Height * scale);
            w.WriteEndElement();
        }
        if (running.Rows.Count == 0 && running.Pictures.Count == 0) w.WriteElementString("p", W, null); // an empty one
        foreach (var row in running.Rows)
        {
            w.WriteStartElement("p", W);
            w.WriteStartElement("pPr", W);
            w.WriteStartElement("tabs", W);
            foreach (var (kind, pos) in new[] { ("center", textWidth / 2), ("right", textWidth) })
            {
                w.WriteStartElement("tab", W);
                w.WriteAttributeString("w", "val", W, kind);
                w.WriteAttributeString("w", "pos", W, Twips(pos));
                w.WriteEndElement();
            }
            w.WriteEndElement();
            w.WriteStartElement("spacing", W);
            w.WriteAttributeString("w", "after", W, "0");
            w.WriteEndElement();
            w.WriteEndElement();
            var at = 0;
            var any = false;
            foreach (var (zone, span) in row.Parts)
            {
                var target = zone switch { TextAlign.Center => 1, TextAlign.Right => 2, _ => 0 };
                if (any && target <= at) Run(w, span with { Text = " " }); // another part in the same place
                any = true;
                for (; at < target; at++)
                {
                    w.WriteStartElement("r", W);
                    w.WriteElementString("tab", W, null);
                    w.WriteEndElement();
                }
                var pieces = span.Text.Split(DocLayout.PageField);
                for (var i = 0; i < pieces.Length; i++)
                {
                    if (i > 0)
                    {
                        w.WriteStartElement("fldSimple", W);
                        w.WriteAttributeString("w", "instr", W, " PAGE ");
                        Run(w, span with { Text = "1" });
                        w.WriteEndElement();
                    }
                    if (pieces[i].Length > 0) Run(w, span with { Text = pieces[i] });
                }
            }
            w.WriteEndElement();
        }
        w.WriteEndElement();
    }

    // ---- styles, numbering, settings ----

    private static void Styles(XmlWriter w, double body)
    {
        w.WriteStartElement("w", "styles", W);
        w.WriteStartElement("docDefaults", W);
        w.WriteStartElement("rPrDefault", W);
        w.WriteStartElement("rPr", W);
        w.WriteStartElement("rFonts", W);
        foreach (var a in new[] { "ascii", "hAnsi", "eastAsia", "cs" }) w.WriteAttributeString("w", a, W, "Calibri");
        w.WriteEndElement();
        var half = Math.Clamp((int)Math.Round(body * 2), 2, 3276).ToString(CultureInfo.InvariantCulture);
        Val(w, "sz", half);
        Val(w, "szCs", half);
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteStartElement("pPrDefault", W);
        w.WriteStartElement("pPr", W);
        w.WriteStartElement("spacing", W);
        w.WriteAttributeString("w", "after", W, "120");
        w.WriteAttributeString("w", "line", W, "240");
        w.WriteAttributeString("w", "lineRule", W, "auto");
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteEndElement(); // docDefaults

        Style(w, "paragraph", "Normal", "Normal", isDefault: true);
        for (var level = 1; level <= 6; level++)
        {
            var l = level;
            Style(w, "paragraph", $"Heading{l}", $"heading {l}", basedOn: "Normal", next: "Normal", priority: 9, pPr: () =>
            {
                w.WriteElementString("keepNext", W, null);
                w.WriteStartElement("spacing", W);
                w.WriteAttributeString("w", "before", W, l <= 2 ? "240" : "160");
                w.WriteAttributeString("w", "after", W, "120");
                w.WriteEndElement();
                Val(w, "outlineLvl", (l - 1).ToString(CultureInfo.InvariantCulture));
            });
        }
        Style(w, "paragraph", "ListParagraph", "List Paragraph", basedOn: "Normal", priority: 34, pPr: () =>
        {
            w.WriteStartElement("ind", W);
            w.WriteAttributeString("w", "left", W, "720");
            w.WriteEndElement();
            w.WriteElementString("contextualSpacing", W, null);
        });
        Style(w, "table", "TableNormal", "Normal Table", isDefault: true, priority: 99, tblPr: () =>
        {
            w.WriteStartElement("tblInd", W);
            w.WriteAttributeString("w", "w", W, "0");
            w.WriteAttributeString("w", "type", W, "dxa");
            w.WriteEndElement();
            w.WriteStartElement("tblCellMar", W);
            foreach (var (side, v) in new[] { ("top", "0"), ("left", "108"), ("bottom", "0"), ("right", "108") })
            {
                w.WriteStartElement(side, W);
                w.WriteAttributeString("w", "w", W, v);
                w.WriteAttributeString("w", "type", W, "dxa");
                w.WriteEndElement();
            }
            w.WriteEndElement();
        });
        w.WriteEndElement();
    }

    private static void Style(XmlWriter w, string type, string id, string name, bool isDefault = false, string? basedOn = null, string? next = null,
        int? priority = null, Action? pPr = null, Action? rPr = null, Action? tblPr = null)
    {
        w.WriteStartElement("style", W);
        w.WriteAttributeString("w", "type", W, type);
        if (isDefault) w.WriteAttributeString("w", "default", W, "1");
        w.WriteAttributeString("w", "styleId", W, id);
        Val(w, "name", name);
        if (basedOn is not null) Val(w, "basedOn", basedOn);
        if (next is not null) Val(w, "next", next);
        if (priority is { } p) Val(w, "uiPriority", p.ToString(CultureInfo.InvariantCulture));
        if (type == "paragraph") w.WriteElementString("qFormat", W, null);
        if (pPr is not null)
        {
            w.WriteStartElement("pPr", W);
            pPr();
            w.WriteEndElement();
        }
        if (rPr is not null)
        {
            w.WriteStartElement("rPr", W);
            rPr();
            w.WriteEndElement();
        }
        if (tblPr is not null)
        {
            w.WriteStartElement("tblPr", W);
            tblPr();
            w.WriteEndElement();
        }
        w.WriteEndElement();
    }

    private static void Numbering(XmlWriter w)
    {
        w.WriteStartElement("w", "numbering", W);
        w.WriteStartElement("abstractNum", W);
        w.WriteAttributeString("w", "abstractNumId", W, "0");
        Val(w, "multiLevelType", "singleLevel");
        w.WriteStartElement("lvl", W);
        w.WriteAttributeString("w", "ilvl", W, "0");
        Val(w, "start", "1");
        Val(w, "numFmt", "bullet");
        Val(w, "lvlText", "•");
        Val(w, "lvlJc", "left");
        w.WriteStartElement("pPr", W);
        w.WriteStartElement("ind", W);
        w.WriteAttributeString("w", "left", W, "360");
        w.WriteAttributeString("w", "hanging", W, "360");
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteEndElement(); // lvl
        w.WriteEndElement(); // abstractNum
        w.WriteStartElement("num", W);
        w.WriteAttributeString("w", "numId", W, "1");
        Val(w, "abstractNumId", "0");
        w.WriteEndElement();
        w.WriteEndElement();
    }

    /// <summary>
    /// The fonts the document names, each with its kind (serif, sans serif, monospaced) and a typical shape, so Word
    /// shows a PDF's own fonts it can't find (often embedded subsets) with a like font rather than any.
    /// </summary>
    private void FontTable(XmlWriter w)
    {
        w.WriteStartElement("w", "fonts", W);
        foreach (var (name, (serif, mono)) in _fonts)
        {
            w.WriteStartElement("font", W);
            w.WriteAttributeString("w", "name", W, name);
            // PANOSE of Courier New, Times New Roman and Arial.
            Val(w, "panose1", mono ? "02070309020205020404" : serif ? "02020603050405020304" : "020B0604020202020204");
            Val(w, "family", mono ? "modern" : serif ? "roman" : "swiss");
            Val(w, "pitch", mono ? "fixed" : "variable");
            w.WriteEndElement();
        }
        w.WriteEndElement();
    }

    private static void Settings(XmlWriter w)
    {
        w.WriteStartElement("w", "settings", W);
        Val(w, "defaultTabStop", "720");
        w.WriteStartElement("compat", W);
        // Word 2013+ layout, so the file doesn't open in compatibility mode.
        w.WriteStartElement("compatSetting", W);
        w.WriteAttributeString("w", "name", W, "compatibilityMode");
        w.WriteAttributeString("w", "uri", W, "http://schemas.microsoft.com/office/word");
        w.WriteAttributeString("w", "val", W, "15");
        w.WriteEndElement();
        w.WriteEndElement();
        w.WriteEndElement();
    }
}

/// <summary>Package parts shared by the .docx and .xlsx writers.</summary>
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

    public static void AppProperties(XmlWriter w)
    {
        const string ns = "http://schemas.openxmlformats.org/officeDocument/2006/extended-properties";
        w.WriteStartElement("Properties", ns);
        w.WriteElementString("Application", ns, "Inkvolt PDF");
        w.WriteEndElement();
    }
}
