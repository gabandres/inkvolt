using System.Text;
using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// Huge files (roadmap 3.6): a big PDF opens in place and is read only when asked for; a large render runs in strips on
/// several threads. The tests open small files in place (DocumentSession.Open's threshold argument).
/// </summary>
public sealed class InPlaceTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "inkvolt-inplace-" + Guid.NewGuid().ToString("N"));

    public InPlaceTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        GC.Collect();
        GC.WaitForPendingFinalizers();
        try
        {
            Directory.Delete(_dir, recursive: true);
        }
        catch (IOException)
        {
        }
    }

    private string Write(string name, byte[] data)
    {
        var path = Path.Combine(_dir, name);
        File.WriteAllBytes(path, data);
        return path;
    }

    private static DocumentSession OpenInPlace(string path) => DocumentSession.Open(path, null, inPlaceBytes: 1);

    [Fact]
    public void ABigFileOpensInPlaceAndIsReadOnlyWhenAskedFor()
    {
        var bytes = TestPdf.Make(3);
        var path = Write("a.pdf", bytes);
        using var session = OpenInPlace(path);
        Assert.True(session.IsInPlace);
        Assert.Equal(3, session.Engine.PageCount);
        Assert.Contains(session.Engine.Render(0, 0.5).Pixels, b => b < 64);
        Assert.Contains("fox", session.Engine.GetText(1).Text);
        Assert.False(session.HasEncryption);
        var key = session.ContentKey;
        Assert.True(session.IsInPlace); // none of that read the file's bytes

        Assert.Equal(bytes, session.Data);
        Assert.False(session.IsInPlace);
        Assert.Same(key, session.ContentKey); // still the same content

        using var small = DocumentSession.Open(path); // the real threshold: read whole
        Assert.False(small.IsInPlace);
        Assert.Same(small.Data, small.ContentKey);
    }

    [Fact]
    public void TheFileCantBeReplacedWhileReadInPlaceAndIsLetGoByAnEdit()
    {
        var path = Write("b.pdf", TestPdf.Make(2, "alpha"));
        var other = Write("other.pdf", TestPdf.Make(2, "omega"));
        using var session = OpenInPlace(path);
        Assert.ThrowsAny<Exception>(() => File.Move(other, path, overwrite: true)); // how editors save: write a copy, swap it in

        var original = File.ReadAllBytes(path);
        session.Commit(TestPdf.Make(2, "beta"), "Edit");
        Assert.False(session.IsInPlace);
        session.SaveAs(path); // MuPDF no longer holds it
        using (var saved = DocumentSession.Open(path)) Assert.Contains("beta", saved.Engine.GetText(0).Text);

        session.Undo(); // the undo step kept the bytes read before the edit
        Assert.Equal(original, session.Data);
        Assert.Contains("alpha", session.Engine.GetText(0).Text);
    }

    [Fact]
    public async Task SavingOverItsOwnFileUnchangedWritesNothingAndElsewhereCopiesIt()
    {
        var bytes = TestPdf.Make(2);
        var path = Write("c.pdf", bytes);
        var stamp = File.GetLastWriteTimeUtc(path);
        using var session = OpenInPlace(path);
        session.SaveAs(path);
        Assert.Equal(stamp, File.GetLastWriteTimeUtc(path));
        Assert.False(session.IsDirty);

        var copy = Path.Combine(_dir, "copy.pdf");
        await session.SaveAsAsync(copy);
        Assert.Equal(bytes, File.ReadAllBytes(copy));
        Assert.True(session.IsInPlace); // copied file to file, not through memory
        Assert.Equal(copy, session.FilePath);
    }

    [Fact]
    public void AFileChangedOnDiskBeforeItsBytesAreReadSaysSo()
    {
        var path = Write("d.pdf", TestPdf.Make(2));
        using var session = OpenInPlace(path);
        // Another program writes over it in place (MuPDF's handle lets it write, not replace).
        using (var f = new FileStream(path, FileMode.Open, FileAccess.Write, FileShare.ReadWrite))
        {
            f.Seek(0, SeekOrigin.End);
            f.Write("%%junk\n"u8);
        }
        Assert.True(session.HasChangedOnDisk());
        var ex = Assert.Throws<IOException>(() => session.Data);
        Assert.Contains("changed on disk", ex.Message);
        Assert.Throws<IOException>(() => session.SaveAs(Path.Combine(_dir, "elsewhere.pdf")));
    }

    [Fact]
    public void ReloadingABigFileOpensItInPlaceAgain()
    {
        var path = Write("e.pdf", TestPdf.Make(2));
        using var session = OpenInPlace(path);
        session.Commit(TestPdf.Make(2, "beta"), "Edit");
        session.ReloadFromDisk();
        Assert.True(session.IsInPlace);
        Assert.False(session.IsDirty);
        Assert.Contains("alpha", session.Engine.GetText(0).Text);
    }

    [Fact]
    public void MayContainSaysWhetherAReaderCouldFindAnything()
    {
        var plain = Write("plain.pdf", TestPdf.Make(2));
        var noted = Write("noted.pdf", Annotations.AddNote(TestPdf.Make(2), null, 0, 50, 50, "Hi", "Me"));
        using (var session = OpenInPlace(plain))
        {
            Assert.False(session.MayContain("/Annots"));
            Assert.False(session.MayContain("/OCProperties"));
            Assert.Empty(Annotations.Read(session.Data, null)); // what a skipped reader would have found
        }
        using (var session = OpenInPlace(noted))
        {
            Assert.True(session.MayContain("/Annots"));
            Assert.NotEmpty(Annotations.Read(session.Data, null));
        }
        using (var session = DocumentSession.FromBytes(TestPdf.Make(1), "x.pdf"))
            Assert.True(session.MayContain("/Annots")); // not in place: always read
    }

    [Fact]
    public void CompressedObjectsMayHideAnyNameButTheTrailers()
    {
        var path = Write("objstm.pdf", Encoding.ASCII.GetBytes("%PDF-1.7\n1 0 obj << /Type /ObjStm /N 0 /First 0 /Length 0 >> stream\n\nendstream endobj\n"));
        var names = PdfNames.Scan(path, DocumentSession.ScannedNames);
        Assert.Equal(["/ObjStm"], names);
    }

    [Fact]
    public void TheNameScanFindsANameAcrossAChunkBoundary()
    {
        foreach (var at in new[] { (1 << 20) - 9, (1 << 20) - 3, (1 << 20) - 1, 1 << 20, (1 << 20) + 2 })
        {
            var bytes = new byte[(1 << 20) + 64];
            Array.Fill(bytes, (byte)'x');
            "/Annots"u8.CopyTo(bytes.AsSpan(at));
            "/Title"u8.CopyTo(bytes.AsSpan(bytes.Length - 6)); // at the very end
            var names = PdfNames.Scan(Write($"chunk{at}.bin", bytes), DocumentSession.ScannedNames);
            Assert.Equal(["/Annots", "/Title"], names.Order());
        }
    }

    /// <summary>The engine's render of a page with strips turned off, and with them (over 200,000 pixels).</summary>
    private static (RenderedImage One, RenderedImage Strips) RenderBoth(byte[] data, double scale, RectD? area)
    {
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var strips = engine.Render(0, scale, area);
        Assert.True((long)strips.Width * strips.Height >= PdfEngine.StripMinPixels);
        var keep = PdfEngine.StripMinPixels;
        try
        {
            PdfEngine.StripMinPixels = long.MaxValue;
            return (engine.Render(0, scale, area), strips);
        }
        finally
        {
            PdfEngine.StripMinPixels = keep;
        }
    }

    [Fact]
    public void TextRendersInStripsExactlyAsInOnePiece()
    {
        var (one, strips) = RenderBoth(TestPdf.Make(1), 2, null);
        Assert.True(one.Pixels.AsSpan().SequenceEqual(strips.Pixels));
    }

    [Theory]
    [InlineData(1.2, false)]
    [InlineData(2.37, false)]
    [InlineData(3.1, true)]
    public void ShapesRenderInStripsAsInOnePieceButForTheirEdgesAntialiasing(double scale, bool region)
    {
        // Shapes crossing a strip's top are clipped there, and MuPDF steps the clipped edge from the clip line: its
        // anti-aliased edge pixels come out a few levels apart. Nothing moves, no seam shows.
        var (one, strips) = RenderBoth(Core1TestPdf.Heavy(300), scale, region ? new RectD(33.3, 101.7, 401.1, 517.9) : null);
        Assert.Equal((one.Width, one.Height), (strips.Width, strips.Height));
        var diffs = one.Pixels.Zip(strips.Pixels, (a, b) => Math.Abs(a - b)).ToArray();
        Assert.True(diffs.Count(d => d > 0) < diffs.Length / 30, $"{diffs.Count(d => d > 0)} of {diffs.Length} bytes differ");
        Assert.True(diffs.Max() <= 16, $"a byte differs by {diffs.Max()}");
    }

    [Fact]
    public void TheEnginesOnePieceRenderIsMuPdfsOwn()
    {
        var data = Core1TestPdf.Heavy(300);
        var (one, _) = RenderBoth(data, 1.2, null);
        using var ctx = new MuPDFContext();
        var doc = new MuPDFDocument(ctx, data, InputFileTypes.PDF);
        try
        {
            Assert.True(doc.Render(0, 1.2, PixelFormats.BGR, includeAnnotations: true).AsSpan().SequenceEqual(one.Pixels));
        }
        finally
        {
            PdfEngine.DisposeDocument(doc);
        }
    }

    [Fact]
    public void ACancelledStripRenderStops()
    {
        using var engine = PdfEngine.Open(Core1TestPdf.Heavy(300), InputFileTypes.PDF, null);
        using var cts = new CancellationTokenSource();
        cts.Cancel();
        Assert.Throws<OperationCanceledException>(() => engine.Render(0, 3, cancel: cts.Token));
        Assert.Equal(1836, engine.Render(0, 3).Width, 1.0); // and the next one renders
    }
}

