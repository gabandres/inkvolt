using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// The copy PDFsharp reads of a file whose updates each name /Encrypt (it can't read three such trailers): only the older
/// sections' trailers and cross-reference stream dictionaries, found by following the cross-reference chain, lose their
/// /Encrypt; nothing else in the file changes, and nothing is copied for a file this isn't.
/// </summary>
public class NewestEncryptTests
{
    private static string Text(byte[] data) => Encoding.Latin1.GetString(data);

    /// <summary>
    /// A base file (classic table) and two updates, each trailer naming /Encrypt 4 0 R. An object of the base holds the
    /// same words in its stream data and in a string; the first update is a cross-reference stream when asked.
    /// </summary>
    private static byte[] ThreeSections(bool xrefStream)
    {
        var data = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [] /Count 0 >>",
            Core2Pdf.Stream("/Encrypt 4 0 R is just text here", "/Note (/Encrypt 4 0 R)"),
            "<< /Filter /Standard /V 1 /R 2 >>",
        ], "/Encrypt 4 0 R ");
        data = Update(data, 2, "<< /Type /Pages /Kids [] /Count 0 /Note (/Encrypt 4 0 R) >>", xrefStream);
        return Update(data, 2, "<< /Type /Pages /Kids [] /Count 0 >>", false);
    }

    /// <param name="selfPrev">The section's /Prev names the section itself (a cycle).</param>
    private static byte[] Update(byte[] file, int num, string body, bool xrefStream, bool selfPrev = false)
    {
        var tail = Incremental.Tail(file)!;
        var at = file.Length;
        var obj = $"{num} 0 obj\n{body}\nendobj\n";
        var xrefAt = at + obj.Length;
        string section;
        if (xrefStream)
        {
            var self = tail.Size;
            section = $"{self} 0 obj\n<< /Type /XRef /Size {self + 1} /Index [{num} 1] /W [1 4 2] /Root 1 0 R /Encrypt 4 0 R /Prev {tail.StartXref} /Length 7 >>\nstream\n" +
                      Encoding.Latin1.GetString([1, (byte)(at >> 24), (byte)(at >> 16), (byte)(at >> 8), (byte)at, 0, 0]) + "\nendstream\nendobj\n";
        }
        else
            section = $"xref\n{num} 1\n{at:D10} 00000 n \ntrailer\n<< /Size {tail.Size} /Root 1 0 R /Encrypt 4 0 R /Prev {(selfPrev ? xrefAt : tail.StartXref)} >>\n";
        return [.. file, .. Encoding.Latin1.GetBytes(obj + section + $"startxref\n{xrefAt}\n%%EOF\n")];
    }

    [Theory]
    [InlineData(false)]
    [InlineData(true)]
    public void OnlyTheOlderSectionsLoseTheirEncrypt(bool xrefStream)
    {
        var data = ThreeSections(xrefStream);
        var copy = PdfRepair.NewestEncryptOnly(data)!;
        Assert.Equal(data.Length, copy.Length);
        var (before, after) = (Text(data), Text(copy));
        // Every difference is spaces where an older section's /Encrypt was.
        var changed = Enumerable.Range(0, data.Length).Where(i => data[i] != copy[i]).ToList();
        Assert.All(changed, i => Assert.Equal(' ', after[i]));
        Assert.Equal(2 * "/Encrypt40R".Length, changed.Count); // its spaces were spaces already
        // The newest trailer keeps it; the object's stream data and strings are untouched.
        var newest = before.LastIndexOf("trailer", StringComparison.Ordinal);
        Assert.Equal(before[newest..], after[newest..]);
        Assert.Contains("stream\n/Encrypt 4 0 R is just text here", after);
        Assert.Equal(before.Split("(/Encrypt 4 0 R)").Length, after.Split("(/Encrypt 4 0 R)").Length);
    }

    [Fact]
    public void AFileThisIsntIsNotCopied()
    {
        // No /Encrypt; one section naming it; two sections of which only the newest names it.
        Assert.Null(PdfRepair.NewestEncryptOnly(Core2Pdf.Build(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>"])));
        var one = Core2Pdf.Build(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>", "<< /Filter /Standard >>"], "/Encrypt 3 0 R ");
        Assert.Null(PdfRepair.NewestEncryptOnly(one));
        var plainBase = Core2Pdf.Build(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>",
            Core2Pdf.Stream("/Encrypt 4 0 R in data"), "<< /Filter /Standard >>"]);
        Assert.Null(PdfRepair.NewestEncryptOnly(Update(plainBase, 2, "<< /Type /Pages /Kids [] /Count 0 >>", false)));
    }

    [Fact]
    public void AChainLongerThanTheLimitIsNotFollowed()
    {
        // The newest section names /Encrypt, the next 1,100 don't, the oldest does: each section read counts, named or not.
        var data = Core2Pdf.Build(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>", "<< /Filter /Standard >>"], "/Encrypt 3 0 R ");
        var text = new StringBuilder(Text(data));
        var prev = Incremental.Tail(data)!.StartXref;
        for (var i = 0; i < 1100; i++)
        {
            var at = text.Length;
            text.Append($"2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\nxref\n2 1\n{at:D10} 00000 n \ntrailer\n<< /Size 4 /Root 1 0 R /Prev {prev} >>\n");
            prev = at + "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n".Length;
            text.Append($"startxref\n{prev}\n%%EOF\n");
        }
        var file = Encoding.Latin1.GetBytes(text.ToString());
        Assert.Null(PdfRepair.NewestEncryptOnly(Update(file, 2, "<< /Type /Pages /Kids [] /Count 0 >>", false)));
    }

    [Fact]
    public void ACycleInTheChainEnds()
    {
        // The newest trailer's /Prev points at itself: one section, nothing to blank, and the walk ends.
        var data = Core2Pdf.Build(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>", "<< /Filter /Standard >>"], "/Encrypt 3 0 R ");
        var cyclic = Update(data, 2, "<< /Type /Pages /Kids [] /Count 0 >>", false, selfPrev: true);
        Assert.Null(PdfRepair.NewestEncryptOnly(cyclic));
    }
}
