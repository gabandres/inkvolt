namespace InkvoltPdf.Core;

/// <summary>A run of text in one look: font family as the PDF names it, size in points, bold, italic, color (0xRRGGBB).</summary>
public sealed record ExportSpan(string Text, string Font, double Size, bool Bold, bool Italic, uint Color, RectD Box)
{
    /// <summary>Same look as <paramref name="other"/> (text and position aside).</summary>
    public bool SameLook(ExportSpan other) =>
        Font == other.Font && Math.Abs(Size - other.Size) < 0.25 && Bold == other.Bold && Italic == other.Italic && Color == other.Color;
}

/// <summary>A line of text on a page (page space: points, top-left of the displayed page). Sideways: not left-to-right.</summary>
public sealed record ExportLine(IReadOnlyList<ExportSpan> Spans, RectD Box, bool Sideways = false)
{
    public string Text => string.Concat(Spans.Select(s => s.Text));

    /// <summary>The size most of the line's characters have.</summary>
    public double Size => Spans.Count == 0 ? 0 : Spans.GroupBy(s => Math.Round(s.Size * 2) / 2).MaxBy(g => g.Sum(s => s.Text.Length))!.Key;

    public static ExportLine Of(IReadOnlyList<ExportSpan> spans, bool sideways = false)
    {
        var box = spans[0].Box;
        foreach (var s in spans.Skip(1)) box = box.Union(s.Box);
        return new ExportLine(spans, box, sideways);
    }
}

/// <summary>
/// A picture on a page: encoded bytes (PNG or JPEG, see <see cref="Extension"/>) and where it is drawn. <see cref="Ref"/>:
/// the name a writer gave it once stored (its bytes are then dropped).
/// </summary>
public sealed record ExportImage(byte[] Data, string Extension, int PixelWidth, int PixelHeight, RectD Box, string? Ref = null);

/// <summary>
/// What an export reads from one page: its text lines, pictures and the thin lines and box outlines it draws (for ruled
/// tables). <see cref="FromOcr"/>: the text came from recognizing a scanned page.
/// </summary>
public sealed record ExportPage(double Width, double Height, IReadOnlyList<ExportLine> Lines, IReadOnlyList<ExportImage> Images,
    IReadOnlyList<RectD> Rules, bool FromOcr = false)
{
    public bool HasText => Lines.Any(l => l.Spans.Any(s => s.Text.Any(c => !char.IsWhiteSpace(c))));

    /// <summary>The same page without its pictures (Excel and plain text don't use them).</summary>
    public ExportPage WithoutImages() => Images.Count == 0 ? this : this with { Images = [] };

    /// <summary>
    /// A scanned page's recognized words as text lines: words side by side at the same height form a line, split where a
    /// gap is wider than a few letters (columns, table cells). Sizes are estimated from the word heights.
    /// </summary>
    public static IReadOnlyList<ExportLine> LinesFromOcr(IEnumerable<OcrWord> words)
    {
        var rows = new List<List<OcrWord>>();
        foreach (var w in words.Where(w => !string.IsNullOrWhiteSpace(w.Text) && w.Rect.Height > 0).OrderBy(w => w.Rect.Y))
        {
            List<OcrWord>? best = null;
            var bestOverlap = 0.0;
            foreach (var row in rows)
            {
                double top = row.Min(r => r.Rect.Y), bottom = row.Max(r => r.Rect.Bottom);
                var overlap = Math.Min(bottom, w.Rect.Bottom) - Math.Max(top, w.Rect.Y);
                var h = Math.Min(bottom - top, w.Rect.Height);
                if (overlap < 0.5 * h || overlap <= bestOverlap) continue;
                if (row.Any(r => r.Rect.X < w.Rect.Right && w.Rect.X < r.Rect.Right)) continue; // a word below or above, not beside
                best = row;
                bestOverlap = overlap;
            }
            if (best is null) rows.Add([w]);
            else best.Add(w);
        }

        var lines = new List<ExportLine>();
        foreach (var row in rows.OrderBy(r => r.Min(w => w.Rect.Y)))
        {
            row.Sort((a, b) => a.Rect.X.CompareTo(b.Rect.X));
            var height = row.Max(r => r.Rect.Height);
            // Word boxes run from ascenders to descenders, about 0.85 of the font size.
            var size = Math.Max(4, Math.Round(height / 0.85 * 2) / 2);
            var part = new List<OcrWord>();
            void Flush()
            {
                if (part.Count == 0) return;
                var spans = new List<ExportSpan>();
                for (var i = 0; i < part.Count; i++)
                    spans.Add(new ExportSpan(i == part.Count - 1 ? part[i].Text : part[i].Text + " ", "", size, false, false, 0, part[i].Rect));
                lines.Add(ExportLine.Of(spans));
                part.Clear();
            }
            foreach (var w in row)
            {
                if (part.Count > 0 && w.Rect.X - part[^1].Rect.Right > 1.5 * height) Flush();
                part.Add(w);
            }
            Flush();
        }
        return lines;
    }
}
