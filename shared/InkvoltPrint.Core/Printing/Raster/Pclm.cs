using System.Globalization;
using System.IO.Compression;
using System.Text;

namespace InkvoltPrint.Core.Printing.Raster;

/// <summary>
/// PCLm (<c>application/PCLm</c>, the Mopria Alliance's PCLm Technical Reference): a PDF 1.7 file with a <c>%PCLm 1.0</c>
/// comment after the header, whose pages are nothing but image strips. Each page is a Page object, then its content stream
/// (scale to points once, then each strip drawn with <c>q … cm /ImageN Do Q</c>, top strip first), then its strips: 8-bit
/// DeviceGray or DeviceRGB XObjects of <see cref="RasterJob.StripHeight"/> lines (the last one may be shorter), FlateDecode or
/// RunLengthDecode. The catalog comes first and the page tree after the last page (so pages stream out one at a time),
/// then a classic cross-reference table and trailer. No object streams, no compressed cross-reference.
/// </summary>
public sealed class PclmWriter : RasterWriter
{
    private readonly List<long> _offsets = [0]; // object number → file offset (0: the free entry)
    private readonly List<int> _pages = [];
    private long _at;

    public PclmWriter(Stream output, RasterJob job) : base(output, job)
    {
        Ascii("%PDF-1.7\n%PCLm 1.0\n");
        _offsets.Add(0); // 1: the catalog
        _offsets.Add(0); // 2: the page tree, written at the end
        Object(1, "<</Type/Catalog/Pages 2 0 R>>");
    }

    private int Strips => (Job.HeightPixels + Job.StripHeight - 1) / Job.StripHeight;

    protected override void WritePage(RasterPage page, int index)
    {
        var pageObj = _offsets.Count;
        var content = pageObj + 1;
        var firstImage = pageObj + 2;
        var strips = Strips;
        var images = new StringBuilder();
        for (var s = 0; s < strips; s++) images.Append(Invariant($"/Image{s} {firstImage + s} 0 R"));
        _pages.Add(pageObj);
        for (var k = 0; k < strips + 2; k++) _offsets.Add(0); // the page, its content, its strips
        Object(pageObj, Invariant($"<</Type/Page/Parent 2 0 R/Resources<</XObject<<{images}>>>>/MediaBox[0 0 {Num(Job.WidthPoints)} {Num(Job.HeightPoints)}]/Contents {content} 0 R>>"));

        var draw = new StringBuilder(Invariant($"{Num(72.0 / Job.Dpi)} 0 0 {Num(72.0 / Job.Dpi)} 0 0 cm\n"));
        for (var s = 0; s < strips; s++)
        {
            var h = StripLines(s);
            var y = Job.HeightPixels - s * Job.StripHeight - h; // PDF's origin is the bottom left
            draw.Append(Invariant($"q {page.Width} 0 0 {h} 0 {y} cm /Image{s} Do Q\n"));
        }
        Stream(content, "", Encoding.ASCII.GetBytes(draw.ToString()));

        var transform = Job.Transform(index);
        var line = new byte[page.BytesPerLine];
        var colorSpace = page.Color == RasterColor.Gray8 ? "/DeviceGray" : "/DeviceRGB";
        var filter = Job.RunLength ? "/RunLengthDecode" : "/FlateDecode";
        for (var s = 0; s < strips; s++)
        {
            var h = StripLines(s);
            using var raw = new MemoryStream();
            using (var packed = Job.RunLength ? (Stream)new RunLengthStream(raw) : new ZLibStream(raw, CompressionLevel.Fastest, leaveOpen: true))
                for (var y = 0; y < h; y++)
                {
                    RasterLines.Line(page, s * Job.StripHeight + y, transform, line);
                    packed.Write(line);
                }
            Stream(firstImage + s, Invariant($"/Type/XObject/Subtype/Image/Width {page.Width}/Height {h}/ColorSpace{colorSpace}/BitsPerComponent 8/Filter{filter}"), raw.ToArray());
        }
    }

    protected override void WriteEnd()
    {
        Object(2, Invariant($"<</Type/Pages/Kids[{string.Join(" ", _pages.Select(p => Invariant($"{p} 0 R")))}]/Count {_pages.Count}>>"));
        var xref = _at;
        var table = new StringBuilder(Invariant($"xref\n0 {_offsets.Count}\n0000000000 65535 f \n"));
        for (var i = 1; i < _offsets.Count; i++) table.Append(Invariant($"{_offsets[i]:D10} 00000 n \n"));
        table.Append(Invariant($"trailer\n<</Size {_offsets.Count}/Root 1 0 R>>\nstartxref\n{xref}\n%%EOF\n"));
        Ascii(table.ToString());
    }

    private int StripLines(int strip) => Math.Min(Job.StripHeight, Job.HeightPixels - strip * Job.StripHeight);

    private void Object(int number, string body)
    {
        _offsets[number] = _at;
        Ascii(Invariant($"{number} 0 obj\n{body}\nendobj\n"));
    }

    private void Stream(int number, string dictionary, byte[] data)
    {
        _offsets[number] = _at;
        Ascii(Invariant($"{number} 0 obj\n<<{dictionary}/Length {data.Length}>>\nstream\n"));
        Output.Write(data);
        _at += data.Length;
        Ascii("\nendstream\nendobj\n");
    }

    private void Ascii(string s)
    {
        var b = Encoding.ASCII.GetBytes(s);
        Output.Write(b);
        _at += b.Length;
    }

    private static string Invariant(FormattableString s) => s.ToString(CultureInfo.InvariantCulture);

    /// <summary>A PDF real: up to four decimals, no exponent, no trailing zeros.</summary>
    internal static string Num(double v) => Math.Round(v, 4).ToString("0.####", CultureInfo.InvariantCulture);
}

/// <summary>
/// PDF's RunLengthDecode (ISO 32000-1 §7.4.5) written: 0-127 is followed by that many plus one bytes as they are, 129-255
/// by one byte repeated 257 minus it times, 128 ends the data.
/// </summary>
internal sealed class RunLengthStream(Stream output) : Stream
{
    private readonly MemoryStream _pending = new();

    public override void Write(byte[] buffer, int offset, int count) => _pending.Write(buffer, offset, count);

    public override void Write(ReadOnlySpan<byte> buffer) => _pending.Write(buffer);

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            var data = _pending.GetBuffer().AsSpan(0, (int)_pending.Length);
            Encode(data, output);
            output.WriteByte(128);
        }
        base.Dispose(disposing);
    }

    internal static void Encode(ReadOnlySpan<byte> data, Stream output)
    {
        var i = 0;
        while (i < data.Length)
        {
            var run = 1;
            while (i + run < data.Length && run < 128 && data[i + run] == data[i]) run++;
            if (run >= 2)
            {
                output.WriteByte((byte)(257 - run));
                output.WriteByte(data[i]);
                i += run;
                continue;
            }
            var count = 1;
            while (i + count < data.Length && count < 128 && !(i + count + 1 < data.Length && data[i + count] == data[i + count + 1])) count++;
            output.WriteByte((byte)(count - 1));
            output.Write(data.Slice(i, count));
            i += count;
        }
    }

    public override bool CanRead => false;
    public override bool CanSeek => false;
    public override bool CanWrite => true;
    public override long Length => _pending.Length;
    public override long Position { get => _pending.Length; set => throw new NotSupportedException(); }
    public override void Flush() { }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
}
