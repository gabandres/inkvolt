using System.Text;
using InkvoltPdf.Core;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// A file an editor saved over a longer copy of itself without cutting it to its new length: the old file's last bytes (the
/// end of its xref table, its trailer and a startxref pointing into the middle of the new file) stay after the new %%EOF.
/// MuPDF repairs it as it opens it, so the pages show; PDFsharp refused it, so its form had no fields and nothing could be typed.
/// </summary>
public class StaleTailTests
{
    private const string W = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R";
    private const string Euros = "/F << /S /JavaScript /JS (AFNumber_Format\\(2, 2, 2, 0, \"\", false\\)) >> /K << /S /JavaScript /JS (AFNumber_Keystroke\\(2, 2, 2, 0, \"\", false\\)) >>";

    /// <summary>
    /// The shape of the owner's form: each field its own widget, Acrobat number formats with "1.234,56" separators, a total
    /// calculated from two amounts, DoNotScroll and DoNotSpellCheck flags, auto-sized text; an incremental update that typed
    /// a value; then the stale tail.
    /// </summary>
    private static byte[] SavedOverALongerFile()
    {
        var form = Core2Pdf.Form([
            $"<< {W} /FT /Tx /Ff 8388608 /T (900_1_Text) /Rect [106 697 348 714] /DA (/Helv 0 Tf 0 g) /V (Norte) /MK << >> >>",
            $"<< {W} /FT /Tx /Ff 4194304 /Q 2 /T (901_1_Value) /Rect [348 660 406 677] /DA (/Helv 0 Tf 0 g) /V (1591.24) /AA << {Euros} >> >>",
            $"<< {W} /FT /Tx /Ff 4194304 /Q 2 /T (901_2_Value) /Rect [348 630 406 647] /DA (/Helv 0 Tf 0 g) /AA << {Euros} >> >>",
            $"<< {W} /FT /Tx /Ff 4194304 /Q 2 /T (901_3_Total) /Rect [430 600 490 617] /DA (/Helv 0 Tf 0 g) /AA << {Euros} /C << /S /JavaScript /JS (AFSimple_Calculate\\(\"SUM\", new Array\\(\"901_1_Value\", \"901_2_Value\"\\)\\)) >> >> >>",
            $"<< {W} /FT /Btn /T (902_Check) /Rect [72 550 90 568] /V /Off /AS /Off /AP << /N << /Yes 10 0 R /Off 11 0 R >> >> >>",
        ], "/CO [8 0 R]", more: [
            Core2Pdf.Stream("q 0 g 2 2 14 14 re f Q", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
            Core2Pdf.Stream("", "/Type /XObject /Subtype /Form /BBox [0 0 18 18]"),
        ]);
        var text = Encoding.Latin1.GetString(form);
        var prev = Incremental.StartXref(form)!.Value;
        var sb = new StringBuilder(text);
        var at = sb.Length;
        sb.Append($"5 0 obj\r\n<< {W} /FT /Tx /Ff 8388608 /T (900_1_Text) /Rect [106 697 348 714] /DA (/Helv 0 Tf 0 g) /V (Sur) /MK << >> >>\r\nendobj\r\n");
        var xref = sb.Length;
        sb.Append($"xref\r\n0 1\r\n0000000000 65535 f\r\n5 1\r\n{at:D10} 00000 n\r\ntrailer\r\n<< /Size 12 /Root 1 0 R /Prev {prev} >>\r\nstartxref\r\n{xref}\r\n%%EOF\r\n");
        // The older, longer file's end: rows of its xref table, its trailer, and its startxref (now inside the rows above).
        sb.Append($" 00000 n\r\n0000000071 00000 n\r\n0000000099 00000 n\r\ntrailer\r\n<< /Size 12 /Root 1 0 R >>\r\nstartxref\r\n{xref + 40}\r\n%%EOF\r\n");
        return Encoding.Latin1.GetBytes(sb.ToString());
    }

    [Fact]
    public void AFormSavedOverALongerFileReadsFillsAndSavesClean()
    {
        var data = SavedOverALongerFile();
        Assert.Throws<PdfReaderException>(() => PdfReader.Open(new MemoryStream(data), PdfDocumentOpenMode.Import)); // what PDFsharp alone does

        var widgets = FormEditor.Read(data, null);
        Assert.Equal(["900_1_Text", "901_1_Value", "901_2_Value", "901_3_Total", "902_Check"], widgets.Select(w => w.FieldName).Order());
        Assert.Equal("Sur", widgets.Single(w => w.FieldName == "900_1_Text").Value); // the update's value, not the first revision's
        Assert.Equal("1.591,24", widgets.Single(w => w.FieldName == "901_1_Value").DisplayValue);
        Assert.All(widgets, w => Assert.False(w.ReadOnly));

        var filled = FormEditor.SetValues(data, null, new Dictionary<string, string>
        {
            ["900_1_Text"] = "Este",
            ["901_2_Value"] = "100",
            ["902_Check"] = "On",
        });
        var after = FormEditor.Read(filled, null);
        Assert.Equal("Este", after.Single(w => w.FieldName == "900_1_Text").Value);
        Assert.Equal("Yes", after.Single(w => w.FieldName == "902_Check").Value);
        var total = after.Single(w => w.FieldName == "901_3_Total");
        Assert.Equal("1691.24", total.Value);
        Assert.Equal("1.691,24", total.DisplayValue);

        // The saved file opens in any reader: no stale tail, and the values are drawn in appearance streams (/V and /AP).
        using (var doc = PdfReader.Open(new MemoryStream(filled), PdfDocumentOpenMode.Import))
            Assert.NotNull(Core2Pdf.Field(doc, "901_3_Total")!.Elements.GetDictionary("/AP")?.Elements.GetDictionary("/N"));
        var shown = Core2Pdf.AllText(Core2Pdf.WithoutNeedAppearances(filled));
        Assert.Contains("Este", shown);
        Assert.Contains("1.691,24", shown);
    }

    [Fact]
    public void AWidgetIsTheSameAfterAFillRewritesItsPageBox()
    {
        // The owner's form's A4 page is 841.90002 high; the filled file says 841.9, so every widget's distance from the top
        // moves by 0.00002. The viewer finds the field it is editing in the refreshed list by this (Tab from a field opened
        // before the refresh landed went back to the page's first field).
        var form = Core2Pdf.Build([
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R 6 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595.20001 841.90002] /Annots [5 0 R 6 0 R] /Resources << >> >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            $"<< {W} /FT /Tx /T (a) /Rect [106.456001 697.494019 348.248993 714.523010] /DA (/Helv 0 Tf 0 g) >>",
            $"<< {W} /FT /Tx /T (b) /Rect [399.476013 697.494019 558.971008 714.523010] /DA (/Helv 0 Tf 0 g) >>",
        ]);
        var before = FormEditor.Read(form, null);
        var after = FormEditor.Read(FormEditor.SetValues(form, null, new Dictionary<string, string> { ["a"] = "Sur" }), null);
        Assert.NotEqual(before[0].Rect, after[0].Rect); // what made the exact comparison miss
        Assert.True(before[0].IsSameWidget(after[0]));
        Assert.True(before[1].IsSameWidget(after[1]));
        Assert.False(before[0].IsSameWidget(after[1]));
        Assert.False(before[0].IsSameWidget(before[0] with { PageIndex = 1 }));
    }

    [Fact]
    public void OnlyAStaleTailIsCut()
    {
        var sound = Core2Pdf.Build(["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [] /Count 0 >>"]);
        Assert.Null(StaleTail.Cut(sound)); // its last startxref is good

        var stale = SavedOverALongerFile();
        var cut = StaleTail.Cut(stale)!;
        Assert.EndsWith("%%EOF\r\n", Encoding.Latin1.GetString(cut));
        Assert.True(cut.AsSpan().SequenceEqual(stale.AsSpan(0, cut.Length)));
        Assert.Equal(Encoding.Latin1.GetString(stale).IndexOf(" 00000 n\r\n0000000071", StringComparison.Ordinal), cut.Length);

        // A tail with an object in it may be a real (if broken) update: dropping it would lose edits, so it stays.
        var withObject = Encoding.Latin1.GetBytes(Encoding.Latin1.GetString(stale).Replace(" 00000 n\r\n0000000071", "9 0 obj\r\n<< >>\r\nendobj\r\n0000000071"));
        Assert.Null(StaleTail.Cut(withObject));
        // So does an object cut short (no endobj), and another cross-reference table: the repair keeps them.
        var withHeader = Encoding.Latin1.GetBytes(Encoding.Latin1.GetString(stale).Replace(" 00000 n\r\n0000000071", "9 0 obj\r\n<< /Old true\r\n0000000071"));
        Assert.Null(StaleTail.Cut(withHeader));
        var withXref = Encoding.Latin1.GetBytes(Encoding.Latin1.GetString(stale).Replace(" 00000 n\r\n0000000071", "xref\r\n0 1\r\n0000000071"));
        Assert.Null(StaleTail.Cut(withXref));
    }

    [Fact]
    public void ManyStartxrefsAreCutQuickly()
    {
        // Every startxref points at an object whose dictionary runs on for 64 KB of near misses of "stream": each one
        // checked to the end would read 64 KB, 200,000 times over (13 GB).
        var sb = new StringBuilder("%PDF-1.7\n1 0 obj\n<< /Type /Catalog ");
        for (var i = 0; i < 12_000; i++) sb.Append("strea ");
        sb.Append(">>\nendobj\n");
        for (var i = 0; i < 200_000; i++) sb.Append("startxref\n9\n%%EOF\n");
        var data = Encoding.Latin1.GetBytes(sb.ToString());
        var clock = System.Diagnostics.Stopwatch.StartNew();
        Assert.Null(StaleTail.Cut(data));
        Assert.True(clock.ElapsedMilliseconds < 500, $"{clock.ElapsedMilliseconds} ms");
    }
}
