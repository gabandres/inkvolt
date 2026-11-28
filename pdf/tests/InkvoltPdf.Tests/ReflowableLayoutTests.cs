using MuPDFCore;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public class ReflowableLayoutTests
{
    private static string Paragraphs(int count) => string.Concat(Enumerable.Range(0, count).Select(i =>
        $"<p>Paragraph {i}: Inkvolt reads FictionBook, shaped word by word, ﬁne and ﬂat, عربي and עברית.</p>"));

    private static byte[] Fb2(int paragraphs) =>
        System.Text.Encoding.UTF8.GetBytes("<FictionBook><body><section>" + Paragraphs(paragraphs) + "</section></body></FictionBook>");

    private static byte[] Epub(int paragraphs)
    {
        using var memory = new MemoryStream();
        using (var zip = new System.IO.Compression.ZipArchive(memory, System.IO.Compression.ZipArchiveMode.Create, leaveOpen: true))
        {
            void Add(string name, string text, bool stored = false)
            {
                var entry = zip.CreateEntry(name, stored ? System.IO.Compression.CompressionLevel.NoCompression : System.IO.Compression.CompressionLevel.Optimal);
                using var w = new StreamWriter(entry.Open());
                w.Write(text);
            }
            Add("mimetype", "application/epub+zip", stored: true);
            Add("META-INF/container.xml", """<?xml version="1.0"?><container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles><rootfile full-path="book.opf" media-type="application/oebps-package+xml"/></rootfiles></container>""");
            Add("book.opf", """<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" version="2.0"><metadata/><manifest><item id="c" href="c.xhtml" media-type="application/xhtml+xml"/></manifest><spine><itemref idref="c"/></spine></package>""");
            Add("c.xhtml", "<html xmlns=\"http://www.w3.org/1999/xhtml\"><body>" + Paragraphs(paragraphs) + "</body></html>");
        }
        return memory.ToArray();
    }

    /// <summary>
    /// The Mac's fictionBooksLaidOutOnSeveralThreadsAtOnce, on Windows: MuPDF 1.25.2 (MuPDFCore 2.0.1's too) keeps
    /// HarfBuzz's context in one global guarded only by the calling context's FreeType lock, and every engine has a context
    /// of its own. Windows is safe because MuPDFCore's CreateContext gives every context the same process-wide locks
    /// (MuPDFWrapper.cpp's global_mutex), so fz_hb_lock excludes across contexts; this guards that (a MuPDFCore that gave
    /// each context its own locks would crash here, as the Mac did). Many FB2 and EPUB books opened (laid out) and drawn
    /// on several threads at once must neither crash nor fail. INKVOLTPDF_REFLOW_ROUNDS repeats it (100: 4,800 opens).
    /// </summary>
    [Fact]
    public void FictionBooksAndEpubsLaidOutOnSeveralThreadsAtOnce()
    {
        var rounds = Environment.GetEnvironmentVariable("INKVOLTPDF_REFLOW_ROUNDS") is { Length: > 0 } r ? int.Parse(r) : 1;
        var fb2 = Fb2(300);
        var epub = Epub(300);
        var failures = 0;
        for (var round = 0; round < rounds; round++)
            Parallel.For(0, 48, new ParallelOptions { MaxDegreeOfParallelism = Math.Max(4, Environment.ProcessorCount) }, i =>
            {
                try
                {
                    using var engine = PdfEngine.Open(i % 2 == 0 ? fb2 : epub, i % 2 == 0 ? InputFileTypes.FB2 : InputFileTypes.EPUB, null);
                    if (engine.PageCount < 2) Interlocked.Increment(ref failures);
                    engine.Render(0, 0.5);
                }
                catch (Exception)
                {
                    Interlocked.Increment(ref failures);
                }
            });
        Assert.Equal(0, failures);
    }
}
