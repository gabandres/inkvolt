using System.Buffers.Binary;
using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPrint.Core.Pdf;

/// <summary>A recognised word, in image pixel coordinates (origin top-left).</summary>
public readonly record struct OcrWord(string Text, double X, double Y, double Width, double Height);

/// <summary>
/// One scanned page: a JPEG plus optional OCR words for an invisible, searchable text layer; or, made with
/// <see cref="BlackAndWhite"/>, a 1-bit image (<see cref="Bits"/>) in place of the JPEG, for a small file.
/// </summary>
public sealed record PdfPage(byte[] Jpeg, int Dpi, IReadOnlyList<OcrWord>? Words = null)
{
    /// <summary>The page in black and white; when set, it is the page's image and <see cref="Jpeg"/> is unused.</summary>
    public BitImage? Bits { get; init; }

    /// <summary>The black-and-white page may be written as lossless JBIG2 when that is smallest (Inkvolt PDF's scans; <see cref="PdfWriter.OneBit"/>).</summary>
    public bool Jbig2 { get; init; }

    /// <summary>A black-and-white page: written as CCITT G4, or as 1-bit Flate when that is smaller (<see cref="PdfWriter.OneBit"/>).</summary>
    public static PdfPage BlackAndWhite(BitImage bits, int dpi, IReadOnlyList<OcrWord>? words = null) => new([], dpi, words) { Bits = bits };
}

/// <summary>How a black-and-white image's samples are stored (<see cref="PdfWriter.OneBitData"/>).</summary>
public enum OneBitCoding { CcittG4, Jbig2, Flate }

/// <summary>
/// Minimal PDF 1.4 writer: JPEG pages embedded as-is (DCTDecode, no re-encode), black-and-white pages at 1 bit
/// (<see cref="OneBit"/>), plus an invisible text layer (render mode 3)
/// so the PDF is searchable and selectable in any script: a CID font with a /ToUnicode map (<see cref="OcrFont"/>), the words
/// as hex strings of its codes, so nothing a word holds can reach the file's syntax.
/// </summary>
public static class PdfWriter
{
    private static readonly Encoding Latin1 = Encoding.Latin1;

    /// <summary>Text scaling (Tz, percent) is kept within what readers accept, whatever box a recognizer gives.</summary>
    private const double MinScale = 1, MaxScale = 1000;

    /// <summary>The smallest font size written, in points: at "0.###" a smaller one would read as 0.</summary>
    private const double MinSize = 0.01;

    /// <param name="options">PDF/A-2b or a password (<see cref="PdfWriteOptions"/>); null writes the plain file as before.</param>
    /// <exception cref="ArgumentException">PDF/A and a password together (PDF/A forbids encryption), or a CMYK page in a PDF/A file.</exception>
    public static void Write(Stream output, IReadOnlyList<PdfPage> pages, string? title = null, PdfWriteOptions? options = null)
    {
        if (pages.Count == 0) throw new ArgumentException("No pages", nameof(pages));
        var archive = options?.PdfA == true;
        var crypt = options?.Password is { } password ? PdfEncryption.Create(password) : null;
        if (archive && crypt is not null) throw new ArgumentException("PDF/A files can't be encrypted.", nameof(options));
        // PDF/A's sRGB output intent allows DeviceRGB and DeviceGray, never DeviceCMYK (ISO 19005-2, 6.2.4.3). Scans are never CMYK.
        if (archive && pages.Any(p => p.Bits is null && JpegInfo(p.Jpeg).Components == 4))
            throw new ArgumentException("A CMYK picture can't go into this PDF/A file.", nameof(pages));
        var w = new ObjWriter(output);
        var font = new OcrFont();
        // AES-256 (AESV3) is PDF 2.0's, Adobe's extension level 8 of PDF 1.7.
        w.Raw(crypt is null ? "%PDF-1.4\n%\xE2\xE3\xCF\xD3\n" : "%PDF-1.7\n%\xE2\xE3\xCF\xD3\n");

        // Fixed ids: 1 catalog, 2 pages, 3 info; then 3 objects per page, then the font's when any page has text (6), then
        // PDF/A's metadata and profile, or the encryption dictionary.
        const int infoId = 3;
        var pageIds = Enumerable.Range(0, pages.Count).Select(i => 4 + i * 3).ToList();
        var fontId = 4 + pages.Count * 3;
        var (metadataId, profileId, encryptId) = (fontId + 6, fontId + 7, fontId + 6);
        var created = (options?.Now ?? DateTime.UtcNow).ToUniversalTime();
        var shownTitle = title ?? "Scan";

        var catalog = "<< /Type /Catalog /Pages 2 0 R";
        if (archive)
            catalog += $" /Metadata {metadataId} 0 R /OutputIntents [<< /Type /OutputIntent /S /GTS_PDFA1 /OutputConditionIdentifier (sRGB IEC61966-2.1) " +
                       $"/Info (sRGB IEC61966-2.1) /DestOutputProfile {profileId} 0 R >>]";
        if (crypt is not null) catalog += " /Extensions << /ADBE << /BaseVersion /1.7 /ExtensionLevel 8 >> >>";
        // From here every object but the encryption dictionary has its strings and streams encrypted.
        w.Encryption = crypt;
        w.Obj(1, catalog + " >>");
        w.Obj(2, $"<< /Type /Pages /Count {pages.Count} /Kids [{string.Join(' ', pageIds.Select(id => $"{id} 0 R"))}] >>");
        w.Obj(infoId, $"<< /Producer (Inkvolt Print) /Title {TextString(shownTitle)} /CreationDate (D:{created:yyyyMMddHHmmss}Z) >>");

        // The black-and-white pages' coding, several at a time (each tries two or three codings).
        var oneBits = new (string Filter, byte[] Data)[pages.Count];
        Parallel.For(0, pages.Count, new ParallelOptions { MaxDegreeOfParallelism = Math.Clamp(Environment.ProcessorCount / 2, 1, 4) }, p =>
        {
            if (pages[p].Bits is { } bits) oneBits[p] = OneBit(bits, pages[p].Jbig2);
        });

        for (var p = 0; p < pages.Count; p++)
        {
            var page = pages[p];
            var (pxW, pxH, comps) = page.Bits is { } bits ? (bits.Width, bits.Height, 1) : JpegInfo(page.Jpeg);
            var scale = 72.0 / page.Dpi;
            double ptW = pxW * scale, ptH = pxH * scale;
            int pageId = pageIds[p], imgId = pageId + 1, contentId = pageId + 2;

            var content = new StringBuilder();
            content.Append(CultureInfo.InvariantCulture, $"q {F(ptW)} 0 0 {F(ptH)} 0 0 cm /Im0 Do Q\n");
            var layer = page.Words is { Count: > 0 } words ? TextLayer(words, font, scale, ptH) : "";
            content.Append(layer);
            var contentBytes = Latin1.GetBytes(content.ToString());

            w.Obj(pageId, $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {F(ptW)} {F(ptH)}] " +
                          $"/Resources << /XObject << /Im0 {imgId} 0 R >>{(layer.Length > 0 ? $" /Font << /F1 {fontId} 0 R >>" : "")} >> /Contents {contentId} 0 R >>");
            if (page.Bits is not null)
            {
                var (filter, data) = oneBits[p];
                w.Stream(imgId, $"<< /Type /XObject /Subtype /Image /Width {pxW} /Height {pxH} /ColorSpace /DeviceGray " +
                                $"/BitsPerComponent 1 {filter} /Length {data.Length} >>", data);
            }
            else
            {
                var cs = comps switch { 1 => "/DeviceGray", 4 => "/DeviceCMYK", _ => "/DeviceRGB" };
                w.Stream(imgId, $"<< /Type /XObject /Subtype /Image /Width {pxW} /Height {pxH} /ColorSpace {cs} " +
                                $"/BitsPerComponent 8 /Filter /DCTDecode /Length {page.Jpeg.Length} >>", page.Jpeg);
            }
            w.Stream(contentId, $"<< /Length {contentBytes.Length} >>", contentBytes);
        }
        if (!font.IsEmpty) font.Write(w.Obj, w.Stream, fontId, fontId + 1);
        if (archive)
        {
            var xmp = PdfArchive.Xmp(shownTitle, "Inkvolt Print", created);
            w.Stream(metadataId, $"<< /Type /Metadata /Subtype /XML /Length {xmp.Length} >>", xmp);
            var icc = IccProfiles.SrgbForPrint();
            w.Stream(profileId, $"<< /N 3 /Length {icc.Length} >>", icc);
        }
        w.Encryption = null;
        if (crypt is not null) w.Obj(encryptId, crypt.Dictionary());

        w.Finish(rootId: 1, infoId: infoId, encryptId: crypt is null ? null : encryptId, withId: archive || crypt is not null);
    }

    /// <summary>
    /// A black-and-white image's stream for a /DeviceGray image at 1 bit: the filter entries (with their parameters) and the
    /// data, CCITT G4 (<see cref="CcittG4"/>) or Flate of the rows (0 black), whichever is smaller. G4 wins on text; Flate
    /// can on a page of fine, even patterns (a halftone), where G4's runs are short. With <paramref name="jbig2"/>, lossless
    /// JBIG2 (<see cref="Jbig2Generic"/>) too, a quarter or so smaller than G4 on text.
    /// </summary>
    public static (string Filter, byte[] Data) OneBit(BitImage image, bool jbig2 = false, CancellationToken cancel = default)
    {
        var (coding, data) = OneBitData(image, jbig2, cancel);
        return coding switch
        {
            OneBitCoding.CcittG4 => ($"/Filter /CCITTFaxDecode /DecodeParms << /K -1 /Columns {image.Width} /Rows {image.Height} >>", data),
            OneBitCoding.Jbig2 => ("/Filter /JBIG2Decode", data),
            _ => ("/Filter /FlateDecode", data),
        };
    }

    /// <summary>
    /// <see cref="OneBit"/>'s choice and data. Each decodes to the same samples: 0 where the image is black (a set bit), as
    /// /DeviceGray reads 1 bit.
    /// </summary>
    public static (OneBitCoding Coding, byte[] Data) OneBitData(BitImage image, bool jbig2 = false, CancellationToken cancel = default)
    {
        var best = (OneBitCoding.CcittG4, CcittG4.Encode(image, cancel));
        if (jbig2 && Jbig2Generic.Encode(image, cancel) is var j && j.Length < best.Item2.Length) best = (OneBitCoding.Jbig2, j);
        cancel.ThrowIfCancellationRequested();
        byte[] flate;
        using (var ms = new MemoryStream())
        {
            using (var z = new System.IO.Compression.ZLibStream(ms, System.IO.Compression.CompressionLevel.Optimal, leaveOpen: true))
                z.Write(image.Inverted());
            flate = ms.ToArray();
        }
        return flate.Length < best.Item2.Length ? (OneBitCoding.Flate, flate) : best;
    }

    /// <summary>
    /// A page's words as invisible text; empty when none can be written. Each is stretched to fill its box in its own text
    /// matrix. A space goes in the gap to the next word of a line, so a phrase across words is found; Chinese and Japanese words on a line, which take none, are stretched up to the next one so that no
    /// reader sees a gap to turn into a space.
    /// </summary>
    private static string TextLayer(IReadOnlyList<OcrWord> words, OcrFont font, double scale, double pageHeight)
    {
        var usable = new List<(OcrWord Box, string Text, List<string> Clusters)>();
        foreach (var word in words)
        {
            if (!double.IsFinite(word.X) || !double.IsFinite(word.Y) || !double.IsFinite(word.Width) || !double.IsFinite(word.Height) || word.Height <= 0) continue;
            var text = OcrText.Clean(word.Text ?? "");
            if (text.Length > 0) usable.Add((word, text, OcrText.Clusters(text)));
        }
        var content = new StringBuilder();
        for (var i = 0; i < usable.Count; i++)
        {
            var (box, text, clusters) = usable[i];
            var next = i + 1 < usable.Count ? usable[i + 1] : default;
            var sameLine = next.Text is not null && SameLine(box, next.Box);
            var unspaced = sameLine && OcrText.IsUnspaced(text) && OcrText.IsUnspaced(next.Text!);
            var width = box.Width;
            if (unspaced && next.Box.X - box.X - box.Width is var gap && gap > 0 && gap < box.Height) width += gap;

            var size = Math.Max(MinSize, box.Height * scale);
            var baseline = pageHeight - (box.Y + box.Height) * scale + size * 0.2; // baseline about 20% above the box's bottom
            var right = box.X + box.Width;
            // Right to left, the word before lies to the right: the space between them goes in one string with this word, on
            // its right end, which is read as its first character. pdf.js drops a space shown by itself or leading a string.
            if (i > 0 && usable[i - 1] is var before && SameLine(box, before.Box) && !(OcrText.IsUnspaced(text) && OcrText.IsUnspaced(before.Text))
                && before.Box.X - right is var gapRight and > 0 && gapRight < 2 * Math.Max(box.Height, before.Box.Height))
            {
                clusters = [.. clusters, " "];
                width += gapRight;
            }
            Show(content, font, clusters, box.X * scale, baseline, size, width * scale);
            if (!sameLine || unspaced || next.Box.X + next.Box.Width <= box.X) continue;
            var gap2 = next.Box.X - right;
            // Boxes that touch or overlap a little are still two words: their space gets almost no width.
            if (gap2 > -box.Height / 2 && gap2 < 2 * Math.Max(box.Height, next.Box.Height))
                Show(content, font, [" "], right * scale, baseline, size, Math.Max(gap2, box.Height / 100) * scale);
        }
        return content.Length == 0 ? "" : $"BT 3 Tr\n{content}ET\n";
    }

    private static void Show(StringBuilder content, OcrFont font, IEnumerable<string> clusters, double x, double baseline, double size, double width)
    {
        var codes = font.Encode(clusters, out var count);
        if (count == 0) return;
        var natural = OcrFont.Width / 1000.0 * size * count;
        var tz = Math.Clamp(width > 0 ? 100 * width / natural : 100, MinScale, MaxScale);
        content.Append(CultureInfo.InvariantCulture, $"/F1 {F(size)} Tf {F(tz)} Tz 1 0 0 1 {F(x)} {F(baseline)} Tm <{codes}> Tj\n");
    }

    /// <summary>Whether two boxes overlap by more than half the shorter's height.</summary>
    private static bool SameLine(OcrWord a, OcrWord b) =>
        Math.Min(a.Y + a.Height, b.Y + b.Height) - Math.Max(a.Y, b.Y) > 0.5 * Math.Min(a.Height, b.Height);

    /// <summary>A text string for the Info dictionary, in UTF-16 with its byte order mark, hex-encoded.</summary>
    private static string TextString(string text) => $"<FEFF{Convert.ToHexString(Encoding.BigEndianUnicode.GetBytes(OcrText.Clean(text)))}>";

    /// <summary>
    /// One page of vector drawing (a printable sheet): <paramref name="content"/> is the page's content stream, in points from
    /// the bottom-left, with Helvetica (WinAnsi) as /F1.
    /// </summary>
    internal static void WriteDrawing(Stream output, double widthPt, double heightPt, string content, string title)
    {
        var w = new ObjWriter(output);
        w.Raw("%PDF-1.4\n%\xE2\xE3\xCF\xD3\n");
        var bytes = Latin1.GetBytes(content);
        w.Obj(1, "<< /Type /Catalog /Pages 2 0 R >>");
        w.Obj(2, "<< /Type /Pages /Count 1 /Kids [5 0 R] >>");
        w.Obj(3, "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
        w.Obj(4, $"<< /Producer (Inkvolt Print) /Title ({Escape(title)}) /CreationDate (D:{DateTime.UtcNow:yyyyMMddHHmmss}Z) >>");
        w.Obj(5, $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {F(widthPt)} {F(heightPt)}] /Resources << /Font << /F1 3 0 R >> >> /Contents 6 0 R >>");
        w.Stream(6, $"<< /Length {bytes.Length} >>", bytes);
        w.Finish(rootId: 1, infoId: 4);
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

    internal static string F(double d) => d.ToString("0.###", CultureInfo.InvariantCulture);

    internal static string Escape(string s)
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

        /// <summary>While set, each object's strings and each stream's data are encrypted as written.</summary>
        public PdfEncryption? Encryption { get; set; }

        public void Raw(string text) => Bytes(Latin1.GetBytes(text));

        public void Obj(int id, string body)
        {
            _offsets.Add((id, _pos));
            Raw($"{id} 0 obj\n{Encryption?.EncryptStrings(body) ?? body}\nendobj\n");
        }

        public void Stream(int id, string dict, byte[] data)
        {
            _offsets.Add((id, _pos));
            if (Encryption is { } crypt)
            {
                var plain = data.Length;
                data = crypt.Encrypt(data);
                dict = crypt.EncryptStrings(Regex.Replace(dict, $@"/Length {plain}(?!\d)", $"/Length {data.Length}"));
            }
            Raw($"{id} 0 obj\n{dict}\nstream\n");
            Bytes(data);
            Raw("\nendstream\nendobj\n");
        }

        /// <param name="encryptId">The encryption dictionary's object, when the file has a password.</param>
        /// <param name="withId">Writes the file identifier PDF/A and encryption ask for (a new random one).</param>
        public void Finish(int rootId, int infoId, int? encryptId = null, bool withId = false)
        {
            var max = _offsets.Max(o => o.Id);
            var byId = _offsets.ToDictionary(o => o.Id, o => o.Offset);
            var xref = _pos;
            var sb = new StringBuilder();
            sb.Append($"xref\n0 {max + 1}\n0000000000 65535 f \n");
            for (var i = 1; i <= max; i++)
                sb.Append(byId.TryGetValue(i, out var off) ? $"{off:D10} 00000 n \n" : "0000000000 65535 f \n");
            var extra = encryptId is { } e ? $" /Encrypt {e} 0 R" : "";
            if (withId)
            {
                var id = Convert.ToHexString(System.Security.Cryptography.RandomNumberGenerator.GetBytes(16));
                extra += $" /ID [<{id}> <{id}>]";
            }
            sb.Append($"trailer\n<< /Size {max + 1} /Root {rootId} 0 R /Info {infoId} 0 R{extra} >>\nstartxref\n{xref}\n%%EOF\n");
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
