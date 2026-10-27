using System.Globalization;
using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// Summarize Comments (Review › Summarize Comments…, Batch): a new PDF with each page that has comments beside its
/// comments, on landscape Letter sheets. The page sits at the left, scaled to fit, drawn as it prints with its comments
/// flattened onto it; the comments are listed at the right in page order, each with its type, author, date and text,
/// replies indented under it. Every comment has a number, shown in a disc at its place on the page and at its entry in
/// the list, and a line connects the two. A list too long for one sheet flows onto continuation sheets that show the
/// page again with the numbers of the comments listed there.
/// </summary>
public static class CommentSummary
{
    private const double SheetW = 792, SheetH = 612, Margin = 36, Gutter = 30, HeaderH = 26;
    private const double TextSize = 9.5, MetaSize = 7.5, Leading = 1.25, Disc = 7, EntryGap = 9, ReplyIndent = 14;
    private const double ListX = Margin + (SheetW - 2 * Margin - Gutter) / 2 + Gutter, ListW = SheetW - Margin - ListX, TextX = ListX + 2 * Disc + 6;

    /// <summary>One comment as the summary lists it.</summary>
    /// <param name="Number">Its number (replies carry their comment's).</param>
    /// <param name="Depth">0 for a comment, 1 and more for replies.</param>
    public sealed record Entry(int Number, int Depth, AnnotationInfo Comment);

    /// <summary>The comments of each page in the order the summary lists them, numbered from 1 through the document.</summary>
    public static IReadOnlyList<(int Page, IReadOnlyList<Entry> Entries)> Plan(IReadOnlyList<AnnotationInfo> comments)
    {
        var listed = comments.Where(c => !c.IsInkvoltPdfStamp && c.Kind != AnnotationKind.Redact).ToList();
        var ids = listed.Select(c => c.Id).ToHashSet(StringComparer.Ordinal);
        var replies = listed.Where(c => c.ReplyTo is { } to && ids.Contains(to) && to != c.Id).GroupBy(c => c.ReplyTo!).ToDictionary(g => g.Key, g => g.OrderBy(c => c.Modified).ToList());
        var number = 0;
        var result = new List<(int, IReadOnlyList<Entry>)>();
        foreach (var page in listed.Where(c => c.ReplyTo is not { } to || !ids.Contains(to) || to == c.Id).GroupBy(c => c.PageIndex).OrderBy(g => g.Key))
        {
            var entries = new List<Entry>();
            foreach (var top in page.OrderBy(c => Math.Round(c.Rect.Y / 4)).ThenBy(c => c.Rect.X))
            {
                number++;
                entries.Add(new Entry(number, 0, top));
                var seen = new HashSet<string>(StringComparer.Ordinal) { top.Id };
                void Add(string id, int depth)
                {
                    if (depth > 16 || !replies.TryGetValue(id, out var list)) return;
                    foreach (var r in list)
                        if (seen.Add(r.Id))
                        {
                            entries.Add(new Entry(number, depth, r));
                            Add(r.Id, depth + 1);
                        }
                }
                Add(top.Id, 1);
            }
            result.Add((page.Key, entries));
        }
        return result;
    }

    /// <exception cref="InvalidOperationException">The document has no comments.</exception>
    public static byte[] Make(byte[] data, string? password, string title, CultureInfo? culture = null)
    {
        culture ??= CultureInfo.CurrentCulture;
        var plan = Plan(Annotations.Read(data, password));
        if (plan.Count == 0) throw new InvalidOperationException("This PDF has no comments to summarize.");

        // The pages as they print, comments included (drawn into them), so the summary shows what the reviewers marked.
        var flat = SignedEdits.Run(() => Flattener.Flatten(data, password, new FlattenOptions { Annotations = true, FormFields = true }), allowRewrite: true).Data;
        using var src = PdfObj.Open(flat, password, PdfDocumentOpenMode.Import, "This PDF's pages can't be read");
        using var doc = new PdfDocument();
        doc.Info.Title = $"Comments on {title}";
        doc.Info.Creator = "Inkvolt PDF";

        var texts = new List<string> { doc.Info.Title };
        foreach (var (_, entries) in plan)
            foreach (var e in entries) texts.AddRange([Meta(e, culture), e.Comment.Contents]);
        var regular = new TextPainter(StdFont.Helvetica, texts);
        var bold = new TextPainter(new StdFont(StdFamily.Helvetica, true, false), texts) { CidPrefix = "/PdB" };
        var sheets = new List<PdfDictionary>();

        foreach (var (pageIndex, entries) in plan)
        {
            var (form, w, h) = PageForm(doc, src, pageIndex);
            var scale = Math.Min((ListX - Gutter - Margin) / w, (SheetH - 2 * Margin - HeaderH) / h);
            double ox = Margin, oy = SheetH - Margin - HeaderH - h * scale;
            (double X, double Y) OnSheet(double px, double py) =>
                (ox + Math.Clamp(px, 0, w) * scale, oy + (h - Math.Clamp(py, 0, h)) * scale);

            var lines = Layout(entries, regular, culture);
            var at = 0;
            var continued = false;
            while (at < lines.Count)
            {
                // Lines that fit this sheet (an entry's header never ends a sheet).
                var top = SheetH - Margin - HeaderH;
                var y = top;
                var end = at;
                while (end < lines.Count && y - lines[end].Height >= Margin)
                {
                    y -= lines[end].Height;
                    end++;
                }
                if (end > at + 1 && lines[end - 1].Kind == LineKind.Meta && end < lines.Count) end--;
                if (end == at) end = at + 1;

                var ops = new StringBuilder();
                ops.Append(CultureInfo.InvariantCulture, $"q {F(scale)} 0 0 {F(scale)} {F(ox)} {F(oy)} cm /Pg Do Q\n");
                ops.Append(CultureInfo.InvariantCulture, $"q 0.6 G 0.5 w {F(ox)} {F(oy)} {F(w * scale)} {F(h * scale)} re S Q\n");
                bold.Draw($"Page {pageIndex + 1}{(continued ? " (continued)" : "")}", Margin, SheetH - Margin - 12, 12);
                AppendText(ops, bold, "/F2", Black);
                regular.Draw(doc.Info.Title, ListX, SheetH - Margin - 12, MetaSize + 1);
                AppendText(ops, regular, "/F1", Gray);

                // The list, then the discs and the lines joining them (drawn under the discs).
                var markers = new List<(Entry Entry, double Y)>();
                y = top;
                for (var k = at; k < end; k++)
                {
                    var line = lines[k];
                    y -= line.Height;
                    var x = TextX + line.Entry.Depth * ReplyIndent;
                    if (line.Kind == LineKind.Meta)
                    {
                        (line.Entry.Depth == 0 ? bold : regular).Draw(line.Text, x, y + 2, MetaSize);
                        if (line.Entry.Depth == 0) markers.Add((line.Entry, y + 2 + MetaSize * 0.35));
                    }
                    else regular.Draw(line.Text, x, y + 2, TextSize);
                }
                AppendText(ops, regular, "/F1", Black);
                AppendText(ops, bold, "/F2", Gray);

                foreach (var (entry, my) in markers)
                {
                    var c = entry.Comment;
                    var (px, py) = OnSheet(c.Rect.X, c.Rect.Y);
                    var color = Rgb(c.Color);
                    ops.Append(CultureInfo.InvariantCulture, $"q {color} RG 0.6 w [2 1.5] 0 d {F(px)} {F(py)} m {F(ListX + Disc)} {F(my)} l S Q\n");
                    foreach (var (cx, cy) in new[] { (px, py), (ListX + Disc, my) })
                    {
                        ops.Append(CultureInfo.InvariantCulture, $"q {color} rg 0.3 G 0.5 w ");
                        Circle(ops, cx, cy, Disc);
                        ops.Append(" B Q\n");
                        var label = entry.Number.ToString(CultureInfo.InvariantCulture);
                        var size = label.Length > 2 ? 6.5 : 8;
                        bold.Draw(label, cx - bold.Measure(label) * size / 2, cy - size * 0.35, size);
                    }
                    AppendText(ops, bold, "/F2", Light(c.Color) ? Black : White);
                }

                sheets.Add(Sheet(doc, ops.ToString(), form));
                at = end;
                continued = true;
            }
        }

        // One font dictionary for every sheet, each font subset to the glyphs of all of them.
        var fonts = new PdfDictionary(doc);
        foreach (var (painter, name) in new[] { (regular, "/F1"), (bold, "/F2") })
            if (PdfObj.Dict(painter.Resources(doc, name).Elements["/Font"]) is { } f)
                foreach (var key in f.Elements.Keys.ToList())
                    fonts.Elements[key == "/F1" || key == "/F2" ? name : key] = f.Elements[key];
        doc.Internals.AddObject(fonts);
        foreach (var res in sheets) res.Elements["/Font"] = fonts.Reference!;
        return PdfObj.Save(doc);
    }

    private enum LineKind { Meta, Text }

    private sealed record Line(LineKind Kind, string Text, Entry Entry, double Height);

    /// <summary>The list as lines: each entry's "Type · author · date" line, then its text wrapped to the column.</summary>
    private static List<Line> Layout(IReadOnlyList<Entry> entries, TextPainter painter, CultureInfo culture)
    {
        var lines = new List<Line>();
        foreach (var e in entries)
        {
            var width = ListW - (TextX - ListX) - e.Depth * ReplyIndent;
            var gap = e.Depth == 0 && lines.Count > 0 ? EntryGap : 3;
            lines.Add(new Line(LineKind.Meta, Meta(e, culture), e, MetaSize * Leading + gap));
            var text = e.Comment.Contents.Trim();
            if (text.Length == 0) continue;
            foreach (var l in painter.Wrap(text.Length > 20_000 ? text[..20_000] + "…" : text, width, TextSize))
                lines.Add(new Line(LineKind.Text, l, e, TextSize * Leading));
        }
        return lines;
    }

    private static string Meta(Entry e, CultureInfo culture)
    {
        var c = e.Comment;
        var kind = e.Depth > 0 ? "Reply" : Capital(CommentFiles.KindName(c.Subtype));
        var parts = new List<string> { kind };
        if (!string.IsNullOrWhiteSpace(c.Author)) parts.Add(c.Author.Trim());
        if (c.Modified is { } m) parts.Add(m.ToLocalTime().ToString("g", culture));
        return string.Join("  ·  ", parts);

        static string Capital(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];
    }

    /// <summary>The page as a form XObject in the summary's document, in displayed-page coordinates (rotation and crop
    /// applied), and its displayed size.</summary>
    private static (PdfDictionary Form, double W, double H) PageForm(PdfDocument doc, PdfDocument src, int pageIndex)
    {
        var page = doc.AddPage(src.Pages[pageIndex]);
        var (w, h) = PdfObj.DisplaySize(page);
        var (x1, y1, x2, y2) = PdfObj.VisibleBox(page);
        var m = PageMarks.DisplayMatrix(page); // displayed → user space; the form needs the inverse
        var det = m[0] * m[3] - m[1] * m[2];
        double[] inv = Math.Abs(det) < 1e-12 ? [1, 0, 0, 1, -x1, -y1] :
        [
            m[3] / det, -m[1] / det, -m[2] / det, m[0] / det,
            (m[2] * m[5] - m[3] * m[4]) / det, (m[1] * m[4] - m[0] * m[5]) / det,
        ];
        var resources = PdfObj.Dict(page.Elements["/Resources"]) ?? new PdfDictionary(doc);
        var form = PdfObj.FormXObject(doc, ContentEditor.ContentBytes(page), x1, y1, x2, y2, resources, PdfObj.Reals(doc, inv));
        if (PdfObj.Dict(page.Elements["/Group"]) is { } group) form.Elements["/Group"] = group;
        doc.Pages.Remove(page);
        return (form, w, h);
    }

    private static PdfDictionary Sheet(PdfDocument doc, string ops, PdfDictionary form)
    {
        var sheet = doc.AddPage();
        sheet.MediaBox = new PdfRectangle(new PdfSharp.Drawing.XRect(0, 0, SheetW, SheetH));
        var resources = new PdfDictionary(doc);
        var xobjects = new PdfDictionary(doc);
        xobjects.Elements["/Pg"] = form.Reference!;
        resources.Elements["/XObject"] = xobjects;
        sheet.Elements["/Resources"] = resources;
        sheet.Elements["/Contents"] = PdfObj.AddStream(doc, Encoding.Latin1.GetBytes(ops)).Reference!;
        return resources;
    }

    private static readonly PdfColorValue Black = new([0, 0, 0]), Gray = new([0.4, 0.4, 0.4]), White = new([1, 1, 1]);

    private static void AppendText(StringBuilder ops, TextPainter painter, string font, PdfColorValue color) =>
        ops.Append(Encoding.Latin1.GetString(painter.Ops(font, color)));

    private static string Rgb(AnnotColor? c) => c is { } v ? $"{F(v.R)} {F(v.G)} {F(v.B)}" : "0.35 0.45 0.75";

    private static bool Light(AnnotColor? c) => c is { } v && 0.299 * v.R + 0.587 * v.G + 0.114 * v.B > 0.6;

    private static string F(double v) => PdfObj.F(v);

    private static void Circle(StringBuilder ops, double cx, double cy, double r)
    {
        const double k = 0.5523;
        ops.Append(CultureInfo.InvariantCulture,
            $"{F(cx + r)} {F(cy)} m {F(cx + r)} {F(cy + r * k)} {F(cx + r * k)} {F(cy + r)} {F(cx)} {F(cy + r)} c " +
            $"{F(cx - r * k)} {F(cy + r)} {F(cx - r)} {F(cy + r * k)} {F(cx - r)} {F(cy)} c " +
            $"{F(cx - r)} {F(cy - r * k)} {F(cx - r * k)} {F(cy - r)} {F(cx)} {F(cy - r)} c " +
            $"{F(cx + r * k)} {F(cy - r)} {F(cx + r)} {F(cy - r * k)} {F(cx + r)} {F(cy)} c h");
    }
}
