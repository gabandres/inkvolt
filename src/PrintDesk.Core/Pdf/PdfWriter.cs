using System.Buffers.Binary;
using System.Globalization;
using System.Text;

namespace PrintDesk.Core.Pdf;

/// <summary>A recognised word, in image pixel coordinates (origin top-left).</summary>
public readonly record struct OcrWord(string Text, double X, double Y, double Width, double Height);

/// <summary>One scanned page: a JPEG plus optional OCR words for an invisible, searchable text layer.</summary>
public sealed record PdfPage(byte[] Jpeg, int Dpi, IReadOnlyList<OcrWord>? Words = null);

/// <summary>
/// Minimal PDF 1.4 writer: JPEG pages embedded as-is (DCTDecode, no re-encode) plus an invisible text layer
/// (render mode 3) so the PDF is searchable and selectable. Text is WinAnsi; other scripts degrade to '?'.
/// </summary>
public static class PdfWriter
{
    private static readonly Encoding Latin1 = Encoding.Latin1;

    public static void Write(Stream output, IReadOnlyList<PdfPage> pages, string? title = null)
    {
        if (pages.Count == 0) throw new ArgumentException("No pages", nameof(pages));
        var w = new ObjWriter(output);
        w.Raw("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");

        // Fixed ids: 1 catalog, 2 pages, 3 font, 4 info; then 3 objects per page.
        const int fontId = 3, infoId = 4;
        var pageIds = Enumerable.Range(0, pages.Count).Select(i => 5 + i * 3).ToList();

        w.Obj(1, "<< /Type /Catalog /Pages 2 0 R >>");
        w.Obj(2, $"<< /Type /Pages /Count {pages.Count} /Kids [{string.Join(' ', pageIds.Select(id => $"{id} 0 R"))}] >>");
        w.Obj(fontId, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
        w.Obj(infoId, $"<< /Producer (PrintDesk) /Title ({Escape(title ?? "Scan")}) /CreationDate (D:{DateTime.UtcNow:yyyyMMddHHmmss}Z) >>");

        for (var p = 0; p < pages.Count; p++)
        {
            var page = pages[p];
            var (pxW, pxH, comps) = JpegInfo(page.Jpeg);
            var scale = 72.0 / page.Dpi;
            double ptW = pxW * scale, ptH = pxH * scale;
            int pageId = pageIds[p], imgId = pageId + 1, contentId = pageId + 2;

            var content = new StringBuilder();
            content.Append(CultureInfo.InvariantCulture, $"q {F(ptW)} 0 0 {F(ptH)} 0 0 cm /Im0 Do Q\n");
            if (page.Words is { Count: > 0 } words)
            {
                content.Append("BT 3 Tr\n");
                foreach (var word in words)
                {
                    if (string.IsNullOrWhiteSpace(word.Text) || word.Height <= 0) continue;
                    var size = word.Height * scale;
                    var natural = 0.5 * size * word.Text.Length; // Helvetica averages ~0.5 em per glyph
                    var tz = natural > 0 ? 100 * word.Width * scale / natural : 100;
                    var x = word.X * scale;
                    var y = ptH - (word.Y + word.Height) * scale + size * 0.2; // baseline ≈ 20% above box bottom
                    content.Append(CultureInfo.InvariantCulture,
                        $"/F1 {F(size)} Tf {F(tz)} Tz 1 0 0 1 {F(x)} {F(y)} Tm ({Escape(word.Text)}) Tj\n");
                }
                content.Append("ET\n");
            }
            var contentBytes = Latin1.GetBytes(content.ToString());

            w.Obj(pageId, $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {F(ptW)} {F(ptH)}] " +
                          $"/Resources << /XObject << /Im0 {imgId} 0 R >> /Font << /F1 {fontId} 0 R >> >> /Contents {contentId} 0 R >>");
            var cs = comps switch { 1 => "/DeviceGray", 4 => "/DeviceCMYK", _ => "/DeviceRGB" };
            w.Stream(imgId, $"<< /Type /XObject /Subtype /Image /Width {pxW} /Height {pxH} /ColorSpace {cs} " +
                            $"/BitsPerComponent 8 /Filter /DCTDecode /Length {page.Jpeg.Length} >>", page.Jpeg);
            w.Stream(contentId, $"<< /Length {contentBytes.Length} >>", contentBytes);
        }

        w.Finish(rootId: 1, infoId: infoId);
    }

    /// <summary>Pixel size and component count from the JPEG SOF header.</summary>
    public static (int Width, int Height, int Components) JpegInfo(ReadOnlySpan<byte> jpeg)
    {
        var off = Escl.JpegFix.FindSofHeightOffset(jpeg);
        if (off < 0) throw new FormatException("Not a baseline/progressive JPEG");
        var h = BinaryPrimitives.ReadUInt16BigEndian(jpeg[off..]);
        var wpx = BinaryPrimitives.ReadUInt16BigEndian(jpeg[(off + 2)..]);
        var comps = jpeg[off + 4];
        if (h == 0 || wpx == 0) throw new FormatException("JPEG has no height (unterminated ADF page)");
        return (wpx, h, comps);
    }

    private static string F(double d) => d.ToString("0.###", CultureInfo.InvariantCulture);

    private static string Escape(string s)
    {
        var sb = new StringBuilder(s.Length);
        foreach (var c in s)
        {
            var ch = c <= 0xFF ? c : MapToWinAnsi(c);
            if (ch is '(' or ')' or '\\') sb.Append('\\');
            sb.Append(ch < ' ' ? ' ' : ch);
        }
        return sb.ToString();
    }

    private static char MapToWinAnsi(char c) => c switch
    {
        '‘' or '’' => '\'',
        '“' or '”' => '"',
        '–' or '—' => '-',
        '…' => '.',
        _ => '?',
    };

    private sealed class ObjWriter(Stream s)
    {
        private readonly List<(int Id, long Offset)> _offsets = [];
        private long _pos;

        public void Raw(string text) => Bytes(Latin1.GetBytes(text));

        public void Obj(int id, string body)
        {
            _offsets.Add((id, _pos));
            Raw($"{id} 0 obj\n{body}\nendobj\n");
        }

        public void Stream(int id, string dict, byte[] data)
        {
            _offsets.Add((id, _pos));
            Raw($"{id} 0 obj\n{dict}\nstream\n");
            Bytes(data);
            Raw("\nendstream\nendobj\n");
        }

        public void Finish(int rootId, int infoId)
        {
            var max = _offsets.Max(o => o.Id);
            var byId = _offsets.ToDictionary(o => o.Id, o => o.Offset);
            var xref = _pos;
            var sb = new StringBuilder();
            sb.Append($"xref\n0 {max + 1}\n0000000000 65535 f \n");
            for (var i = 1; i <= max; i++)
                sb.Append(byId.TryGetValue(i, out var off) ? $"{off:D10} 00000 n \n" : "0000000000 65535 f \n");
            sb.Append($"trailer\n<< /Size {max + 1} /Root {rootId} 0 R /Info {infoId} 0 R >>\nstartxref\n{xref}\n%%EOF\n");
            Raw(sb.ToString());
            s.Flush();
        }

        private void Bytes(ReadOnlySpan<byte> b)
        {
            s.Write(b);
            _pos += b.Length;
        }
    }
}
