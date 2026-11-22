using System.Text;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>What a copy of an area of a page takes: its picture (Snapshot), its words, or its words as a table's cells.</summary>
public enum AreaCopyKind { Picture, Text, Table }

/// <summary>
/// Copy Text and Copy as Table for an area boxed with Snapshot (roadmap 4.6). The area's words come from the page's text
/// (its own, or an earlier text recognition's invisible layer) when it has any there, else from reading the area's
/// picture (<see cref="Recognize"/>). <see cref="Text"/> gives them in reading order as the plain-text export lays them
/// out; <see cref="Table"/> as the Excel export finds tables (<see cref="DocLayout"/>), or, where it finds none, as rows
/// of the lines' columns, for the clipboard as tab-separated text and as HTML so a spreadsheet pastes them into cells.
/// </summary>
public static class AreaCopy
{
    /// <summary>The most pixels an area is read at (a Letter page at 300 dpi is about 8.4 million).</summary>
    private const long MaxRecognizePixels = 25_000_000;

    /// <summary>
    /// The most cells (rows × columns) a copied table holds: more is no table a person boxed but a hostile page (one
    /// character a line, each its own row and column, makes hundreds of millions), copied as text instead.
    /// </summary>
    public const int MaxCells = 100_000;

    /// <summary>
    /// The page's lines and rules cut to <paramref name="area"/> (page space): a character is kept when its middle is
    /// inside (characters are taken as evenly spread over their run), a line keeps what is left of it, pictures go.
    /// </summary>
    public static ExportPage Clip(ExportPage page, RectD area)
    {
        var lines = new List<ExportLine>();
        foreach (var line in page.Lines)
        {
            if (!Overlaps(line.Box, area)) continue;
            var spans = new List<ExportSpan>();
            foreach (var span in line.Spans)
                if (Cut(span, area, line.Reads) is { } kept) spans.Add(kept);
            if (spans.Count == 0 || spans.All(s => string.IsNullOrWhiteSpace(s.Text))) continue;
            lines.Add(ExportLine.Of(spans, line.Sideways) with { Turn = line.Turn });
        }
        var rules = page.Rules.Where(r => Overlaps(r, area)).Select(r => Intersect(r, area)).ToList();
        return page with { Lines = lines, Images = [], Rules = rules, Shapes = [] };
    }

    /// <summary>The page has text in <paramref name="area"/> (else its picture is read).</summary>
    public static bool HasText(ExportPage page, RectD area) => Clip(page, area).HasText;

    /// <summary>
    /// The clipped page's words in reading order: a paragraph a line, a table's rows with tab-separated cells, a bullet
    /// item with its bullet. Line breaks are Windows' (CR LF).
    /// </summary>
    public static string Text(ExportPage clipped)
    {
        var text = DocumentExport.PlainText([clipped]);
        var lines = text.Split("\r\n").Select(l => l.TrimEnd()).Where(l => l.Length > 0);
        return string.Join("\r\n", lines);
    }

    /// <summary>
    /// The clipped page as rows of cells: the tables <see cref="DocLayout"/> finds (as Export to Excel puts them in a sheet),
    /// with any paragraph between them a row of one cell; where it finds no table, each row of lines split into the columns
    /// their left and right edges line up in. More than <see cref="MaxCells"/> cells: no rows, and
    /// <see cref="AreaTable.TooLarge"/> (the caller copies the text instead, and says so).
    /// </summary>
    public static AreaTable Table(ExportPage clipped, CancellationToken cancel = default)
    {
        if (!clipped.HasText) return new AreaTable([]);
        var laid = DocLayout.Analyze([clipped]);
        cancel.ThrowIfCancellationRequested();
        var blocks = laid.SelectMany(p => p.Blocks).ToList();
        if (blocks.OfType<DocTable>().Any())
        {
            var rows = new List<IReadOnlyList<AreaCell>>();
            long cells = 0; // as the text pastes: a spanning cell followed by empty ones
            foreach (var block in blocks)
            {
                switch (block)
                {
                    case DocTable t:
                        foreach (var row in t.Rows)
                        {
                            cells += row.Sum(c => (long)Math.Max(1, c.ColSpan));
                            if (cells > MaxCells) break;
                            rows.Add([.. row.Select(c => new AreaCell(c.Covered ? "" : OneLine(c.Text), c.ColSpan))]); // a spanned cell left empty
                        }
                        break;
                    case DocParagraph p when !string.IsNullOrWhiteSpace(p.Text):
                        cells++;
                        rows.Add([new AreaCell(OneLine(p.Text))]);
                        break;
                }
                if (cells > MaxCells) break;
            }
            return cells > MaxCells ? new AreaTable([]) { TooLarge = true } : new AreaTable(rows);
        }
        return Columns(clipped.Lines.Where(l => !l.Sideways).ToList(), cancel);
    }

    /// <summary>
    /// The words <paramref name="recognizer"/> reads in <paramref name="area"/> of the page, drawn at 300 dpi (less for a
    /// very large area, more for a small one, so its letters are tall enough to read), in page space.
    /// </summary>
    public static IReadOnlyList<OcrWord> Recognize(PdfEngine engine, int page, RectD area, ITextRecognizer recognizer, CancellationToken cancel = default)
    {
        if (page < 0 || page >= engine.PageCount || !(area.Width >= 1 && area.Height >= 1) || !double.IsFinite(area.X) || !double.IsFinite(area.Y)) return [];
        var g = engine.GetPage(page);
        var box = Intersect(area, new RectD(0, 0, g.Width, g.Height));
        if (box.Width < 1 || box.Height < 1) return [];
        var scale = Math.Max(300 / 72.0, 40 / box.Height); // a one-line area drawn at least 40 pixels tall
        if (box.Width * box.Height * scale * scale > MaxRecognizePixels) scale = Math.Sqrt(MaxRecognizePixels / (box.Width * box.Height));
        var image = engine.Render(page, scale, box, cancel, annotations: false);
        var read = recognizer.Recognize(image.Pixels, image.Width, image.Height, 3, cancel);
        // The rendered region can start a fraction of a pixel before the box: its pixels are counted from the box's corner.
        return [.. read.Where(w => !string.IsNullOrWhiteSpace(w.Text))
            .Select(w => new OcrWord(w.Text, new RectD(box.X + w.X / scale, box.Y + w.Y / scale, w.Width / scale, w.Height / scale)))];
    }

    /// <summary>The words recognized in an area as the lines a clipped page holds (<see cref="ExportPage.LinesFromOcr"/>).</summary>
    public static ExportPage FromWords(ExportPage page, IReadOnlyList<OcrWord> words) =>
        page with { Lines = ExportPage.LinesFromOcr(words), Images = [], Shapes = [], FromOcr = true };

    /// <summary>A span cut to the characters whose middles are in the area (along the way the line reads), or null for none.</summary>
    private static ExportSpan? Cut(ExportSpan span, RectD area, int reads)
    {
        if (!Overlaps(span.Box, area) || span.Text.Length == 0) return null;
        var text = span.Text;
        var horizontal = reads is 0 or 2;
        var (start, length) = horizontal ? (span.Box.X, span.Box.Width) : (span.Box.Y, span.Box.Height);
        var (across, acrossEnd) = horizontal ? (span.Box.Y, span.Box.Bottom) : (span.Box.X, span.Box.Right);
        var (lo, hi) = horizontal ? (area.X, area.Right) : (area.Y, area.Bottom);
        var (crossLo, crossHi) = horizontal ? (area.Y, area.Bottom) : (area.X, area.Right);
        var middle = (across + acrossEnd) / 2;
        if (middle < crossLo || middle > crossHi) return null; // the line's middle is outside: a line the box only grazes
        var forward = reads is 0 or 1;
        var step = length / text.Length;
        int first = -1, last = -1;
        for (var i = 0; i < text.Length; i++)
        {
            var k = forward ? i : text.Length - 1 - i; // the i-th character along the page's axis
            var at = start + (i + 0.5) * step;
            if (at < lo || at > hi) continue;
            if (first < 0 || k < first) first = k;
            if (k > last) last = k;
        }
        if (first < 0) return null;
        if (first == 0 && last == text.Length - 1) return span;
        var (from, to) = forward ? (first, last) : (text.Length - 1 - last, text.Length - 1 - first);
        var a = start + from * step;
        var b = start + (to + 1) * step;
        var box = horizontal ? new RectD(a, span.Box.Y, b - a, span.Box.Height) : new RectD(span.Box.X, a, span.Box.Width, b - a);
        return span with { Text = text[first..(last + 1)], Box = box };
    }

    /// <summary>
    /// Lines in rows (those whose heights overlap by half), each row's lines in the columns their spans across all rows
    /// make (edges that overlap are one column); none, with <see cref="AreaTable.TooLarge"/>, past <see cref="MaxCells"/>.
    /// </summary>
    private static AreaTable Columns(List<ExportLine> lines, CancellationToken cancel)
    {
        // Columns first (the lines' left-to-right extents merged where they overlap): how wide the grid is.
        var columns = new List<(double From, double To)>();
        foreach (var (from, to) in lines.Select(l => (l.Box.X, l.Box.Right)).OrderBy(e => e.X))
            if (columns.Count > 0 && from <= columns[^1].To) columns[^1] = (columns[^1].From, Math.Max(columns[^1].To, to));
            else columns.Add((from, to));
        // Rows, top down. A row whose lowest line ends above this line's top overlaps no line after it either (they are
        // in order of their tops): it is closed, so a page of thousands of rows isn't searched line by line again.
        var rows = new List<List<ExportLine>>();
        var open = new List<(List<ExportLine> Row, double Bottom)>();
        foreach (var line in lines.OrderBy(l => l.Box.Y))
        {
            cancel.ThrowIfCancellationRequested();
            open.RemoveAll(o => o.Bottom <= line.Box.Y);
            var at = open.FindIndex(o => o.Row.Any(x => Math.Min(x.Box.Bottom, line.Box.Bottom) - Math.Max(x.Box.Y, line.Box.Y)
                                                        > 0.5 * Math.Min(x.Box.Height, line.Box.Height)));
            if (at < 0)
            {
                List<ExportLine> row = [line];
                rows.Add(row);
                open.Add((row, line.Box.Bottom));
                if ((long)rows.Count * columns.Count > MaxCells) return new AreaTable([]) { TooLarge = true };
            }
            else
            {
                open[at].Row.Add(line);
                open[at] = (open[at].Row, Math.Max(open[at].Bottom, line.Box.Bottom));
            }
        }
        var result = new List<IReadOnlyList<AreaCell>>();
        foreach (var row in rows.OrderBy(r => r.Min(l => l.Box.Y)))
        {
            cancel.ThrowIfCancellationRequested();
            var cells = new string[columns.Count];
            foreach (var line in row.OrderBy(l => l.Box.X))
            {
                var c = ColumnOf(columns, line.Box);
                if (c < 0) continue;
                var text = OneLine(line.Text);
                cells[c] = cells[c] is { Length: > 0 } was ? $"{was} {text}" : text;
            }
            result.Add([.. cells.Select(c => new AreaCell(c ?? ""))]);
        }
        return new AreaTable(result);
    }

    /// <summary>The first column <paramref name="box"/> reaches into, or -1. The columns are apart and in order, so their
    /// right edges rise: the first that ends at or after the box's left edge is the one, if it starts before its right.</summary>
    private static int ColumnOf(List<(double From, double To)> columns, RectD box)
    {
        int lo = 0, hi = columns.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (columns[mid].To < box.X) lo = mid + 1;
            else hi = mid;
        }
        return lo < columns.Count && box.Right >= columns[lo].From ? lo : -1;
    }

    private static string OneLine(string text) => string.Join(' ', text.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));

    private static bool Overlaps(RectD a, RectD b) => a.X < b.Right && b.X < a.Right && a.Y < b.Bottom && b.Y < a.Bottom;

    private static RectD Intersect(RectD a, RectD b) =>
        RectD.FromEdges(Math.Max(a.X, b.X), Math.Max(a.Y, b.Y), Math.Min(a.Right, b.Right), Math.Min(a.Bottom, b.Bottom));
}

/// <summary>A cell of a copied table: its text on one line, and how many columns it spans.</summary>
public sealed record AreaCell(string Text, int ColSpan = 1);

/// <summary>An area copied as a table (<see cref="AreaCopy.Table"/>): rows of cells, for the clipboard.</summary>
public sealed record AreaTable(IReadOnlyList<IReadOnlyList<AreaCell>> Rows)
{
    /// <summary>More than <see cref="AreaCopy.MaxCells"/> cells: none kept, the area is copied as text.</summary>
    public bool TooLarge { get; init; }

    public bool IsEmpty => Rows.All(r => r.All(c => c.Text.Length == 0));

    /// <summary>Most columns in a row (a cell counted by its span).</summary>
    public int ColumnCount => Rows.Count == 0 ? 0 : Rows.Max(r => r.Sum(c => Math.Max(1, c.ColSpan)));

    /// <summary>Tab-separated rows (a spanning cell followed by empty ones), CR LF between rows: what a spreadsheet pastes as cells.</summary>
    public string Tsv()
    {
        var sb = new StringBuilder();
        foreach (var row in Rows)
        {
            var cells = new List<string>();
            foreach (var cell in row)
            {
                cells.Add(cell.Text.Replace('\t', ' '));
                for (var k = 1; k < cell.ColSpan; k++) cells.Add("");
            }
            sb.Append(string.Join('\t', cells).TrimEnd('\t')).Append("\r\n");
        }
        return sb.ToString();
    }

    /// <summary>The rows as an HTML table (text escaped, spans kept), the fragment <see cref="ClipboardHtml.Wrap"/> takes.</summary>
    public string Html()
    {
        var sb = new StringBuilder("<table>");
        foreach (var row in Rows)
        {
            sb.Append("<tr>");
            foreach (var cell in row)
            {
                sb.Append(cell.ColSpan > 1 ? $"<td colspan=\"{cell.ColSpan}\">" : "<td>");
                sb.Append(cell.Text.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;")); // UTF-8 as it is
                sb.Append("</td>");
            }
            sb.Append("</tr>");
        }
        return sb.Append("</table>").ToString();
    }
}

/// <summary>
/// The clipboard's HTML format (CF_HTML): a header giving the byte offsets, in UTF-8, of the document and of the fragment
/// pasted, then the document. What Excel and Word read to paste a table as cells.
/// </summary>
public static class ClipboardHtml
{
    private const string Header = "Version:0.9\r\nStartHTML:{0:D10}\r\nEndHTML:{1:D10}\r\nStartFragment:{2:D10}\r\nEndFragment:{3:D10}\r\n";

    public static byte[] Wrap(string fragment)
    {
        const string before = "<html><head><meta charset=\"utf-8\"></head><body>\r\n<!--StartFragment-->";
        const string after = "<!--EndFragment-->\r\n</body></html>";
        var headerLength = Encoding.ASCII.GetByteCount(string.Format(System.Globalization.CultureInfo.InvariantCulture, Header, 0, 0, 0, 0));
        var startFragment = headerLength + Encoding.UTF8.GetByteCount(before);
        var endFragment = startFragment + Encoding.UTF8.GetByteCount(fragment);
        var endHtml = endFragment + Encoding.UTF8.GetByteCount(after);
        var text = string.Format(System.Globalization.CultureInfo.InvariantCulture, Header, headerLength, endHtml, startFragment, endFragment)
                   + before + fragment + after;
        return Encoding.UTF8.GetBytes(text);
    }
}
