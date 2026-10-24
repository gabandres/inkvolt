using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public class ContentEditorTests
{
    private const string Simple = "BT /FA 20 Tf 72 692 Td (Hello World) Tj ET\nBT /FA 12 Tf 72 600 Td (draft) Tj ET";

    private static TextRun Run(byte[] pdf, string text, int page = 0) =>
        ContentEditor.Read(pdf, null, page).Runs.Single(r => r.Text == text);

    // ---- Lexer ----

    [Fact]
    public void LexerReadsStringsNamesArraysAndDictionaries()
    {
        var ops = ContentLexer.Parse(Encoding.Latin1.GetBytes(
            "% a comment\n/Span <</MCID 3 /Alt (a\\)b)>> BDC (nested (parens) \\(x\\) \\101\\n) Tj <48 65 6C6> Tj /A#20B Do [(a) -120.5 (b)] TJ EMC"));
        Assert.Equal(["BDC", "Tj", "Tj", "Do", "TJ", "EMC"], ops.Select(o => o.Name));
        Assert.Equal(3, ops[0].Operands[1]["MCID"]!.Num);
        Assert.Equal("a)b", Encoding.Latin1.GetString(ops[0].Operands[1]["Alt"]!.Bytes));
        Assert.Equal("nested (parens) (x) A\n", Encoding.Latin1.GetString(ops[1].Operands[0].Bytes));
        Assert.Equal("Hel`", Encoding.Latin1.GetString(ops[2].Operands[0].Bytes)); // odd digit padded with 0
        Assert.True(ops[2].Operands[0].Hex);
        Assert.Equal("A B", ops[3].Operands[0].Name);
        Assert.Equal(-120.5, ops[4].Operands[0].Items[1].Num);
    }

    [Fact]
    public void LexerSkipsInlineImageDataEvenWhenItHoldsEI()
    {
        // 3 x 1 RGB, unfiltered: the data (9 bytes) holds " EI " itself, which only the computed length gets past.
        var data = new byte[] { 0x20, (byte)'E', (byte)'I', 0x20, 1, 2, 3, 4, 5 };
        var head = Encoding.Latin1.GetBytes("q 30 0 0 10 50 50 cm BI /W 3 /H 1 /BPC 8 /CS /RGB ID ");
        var tail = Encoding.Latin1.GetBytes("\nEI Q BT /FA 9 Tf (after) Tj ET");
        var ops = ContentLexer.Parse([.. head, .. data, .. tail]);
        Assert.Equal(["q", "cm", "BI", "Q", "BT", "Tf", "Tj", "ET"], ops.Select(o => o.Name));
        Assert.Equal(data.Length, ops[2].DataEnd - ops[2].DataStart);

        // Filtered data (length unknown): the EI followed by ordinary content ends it.
        var filtered = ContentLexer.Parse(Encoding.Latin1.GetBytes("BI /W 2 /H 2 /BPC 8 /CS /G /F /AHx ID 00ff\n00ff> EI Q"));
        Assert.Equal(["BI", "Q"], filtered.Select(o => o.Name));
    }

    [Fact]
    public void LexerSurvivesMalformedContent()
    {
        var ops = ContentLexer.Parse(Encoding.Latin1.GetBytes(") ] } >> 5 --3 Td (unterminated"));
        Assert.Contains(ops, o => o.Name == "Td" && o.N(1) == -3);
    }

    [Fact]
    public void ToUnicodeCMapRangesAndArraysAreRead()
    {
        var map = new Dictionary<int, string>();
        TextFont.ReadCMap(Encoding.Latin1.GetBytes(
            "begincmap 1 begincodespacerange <0000> <FFFF> endcodespacerange 2 beginbfchar <0003> <0020> <0010> <00660069> endbfchar " +
            "2 beginbfrange <0020> <0022> <0041> <0030> <0031> [<0078> <D83DDE00>] endbfrange endcmap"), map);
        Assert.Equal(" ", map[3]);
        Assert.Equal("fi", map[0x10]);
        Assert.Equal("C", map[0x22]);
        Assert.Equal("\U0001F600", map[0x31]);
    }

    [Fact]
    public void GlyphNamesMapToText()
    {
        Assert.Equal("é", GlyphNames.ToUnicode("eacute"));
        Assert.Equal("ffi", GlyphNames.ToUnicode("f_f_i"));
        Assert.Equal("A", GlyphNames.ToUnicode("A.sc"));
        Assert.Equal("€", GlyphNames.ToUnicode("uni20AC"));
        Assert.Equal("\U0001F600", GlyphNames.ToUnicode("u1F600"));
        Assert.Equal("Euro", GlyphNames.InEncoding("WinAnsiEncoding", 0x80));
        Assert.Equal("quoteright", GlyphNames.InEncoding("StandardEncoding", 0x27));
        Assert.Equal("eacute", GlyphNames.InEncoding("MacRomanEncoding", 0x8E));
        Assert.Equal(229, CffProgram.StandardStringCount);
    }

    // ---- Reading runs ----

    [Fact]
    public void RunsLandWhereMuPdfShowsTheirCharacters()
    {
        var seed = ContentEditPdf.Make(Simple);
        var pdf = ContentEditPdf.Make(
            "BT /FA 20 Tf 72 692 Td (Hello World) Tj ET\n" +
            "q 1.5 0 0 1.5 10 20 cm BT /FU 10 Tf 2 0 0 1 40 300 Tm 3 Tc " + ContentEditPdf.Cid(seed, "World") + " Tj ET Q\n" +
            "BT /FA 14 Tf 100 200 Td [(He) 400 (llo) -2000 (World)] TJ ET");
        var content = ContentEditor.Read(pdf, null, 0);
        Assert.Equal(["Hello World", "World", "Hello World"], content.Runs.Select(r => r.Text));
        Assert.All(content.Runs, r => Assert.Null(r.Blocked));

        using var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null);
        var text = engine.GetText(0, cache: false);
        foreach (var run in content.Runs)
        {
            // MuPDF's boxes of the run's first and last letters lie at the run's ends.
            var probe = run.Text.Replace(" ", "");
            var hits = Enumerable.Range(0, text.Text.Length).Where(i => text.Text[i] != ' ' && text.Text[i] != '\n')
                .Select(text.BoxAt).Where(b => run.Box.Inflate(1.5).Contains(b.CenterX, b.CenterY)).ToList();
            Assert.Equal(probe.Length, hits.Count);
            Assert.InRange(hits.Min(b => b.X) - run.Box.X, -1.5, 1.5);
            Assert.InRange(run.Box.Right - hits.Max(b => b.Right), -1.5, 1.5);
        }
        Assert.Equal(15, content.Runs[1].FontSize, 1); // 10 pt under a 1.5 scale
        Assert.Equal(20, content.Runs[0].FontSize, 1);
    }

    [Fact]
    public void RunsOnARotatedPageAreInPageSpace()
    {
        var pdf = ContentEditPdf.Make("BT /FA 20 Tf 72 692 Td (Hello) Tj ET", rotate: 90);
        var run = Run(pdf, "Hello");
        using var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null);
        var text = engine.GetText(0, cache: false);
        var all = Enumerable.Range(0, text.Text.Length).Select(text.BoxAt).Aggregate((a, b) => a.Union(b));
        // Along the baseline (down the page when turned) the ends match; across it MuPDF's boxes are tighter.
        Assert.InRange(Math.Abs(all.Y - run.Box.Y), 0, 1.5);
        Assert.InRange(Math.Abs(all.Bottom - run.Box.Bottom), 0, 1.5);
        Assert.True(all.X >= run.Box.X - 1 && all.Right <= run.Box.Right + 1, $"{all} vs {run.Box}");
        Assert.Equal(90, run.Angle, 1);
    }

    // ---- Editing text ----

    [Fact]
    public void TextIsReplacedInItsOwnSimpleFont()
    {
        var pdf = ContentEditPdf.Make(Simple);
        var run = Run(pdf, "Hello World");
        var check = run.Check("Hello Word");
        Assert.Empty(check.Missing);
        Assert.True(check.Width < check.OldWidth);

        var edited = ContentEditor.ReplaceText(pdf, null, run, "Hello Word");
        var text = ContentEditPdf.Text(edited);
        Assert.Contains("Hello Word", text);
        Assert.DoesNotContain("World", text);
        Assert.Contains("draft", text);
        var after = Run(edited, "Hello Word");
        Assert.Equal(run.Box.X, after.Box.X, 2);
        Assert.Equal(run.Box.Y, after.Box.Y, 2);
        Assert.Contains("72 692 Td", ContentEditPdf.Content(edited)); // the rest of the content is kept as written
    }

    [Fact]
    public void UnchangedTextReturnsTheSameBytes()
    {
        var pdf = ContentEditPdf.Make(Simple);
        Assert.Same(pdf, ContentEditor.ReplaceText(pdf, null, Run(pdf, "Hello World"), "Hello World"));
    }

    [Fact]
    public void MissingGlyphsAreRefusedByName()
    {
        var pdf = ContentEditPdf.Make(Simple);
        var run = Run(pdf, "Hello World");
        var check = run.Check("Hello Zebra");
        Assert.Equal(["Z", "b"], check.Missing);
        var ex = Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceText(pdf, null, run, "Hello Zebra"));
        Assert.Equal(["Z", "b"], ex.Missing);
        Assert.Contains("“Z”", ex.Message);
        Assert.Contains("Arial", ex.Message);
    }

    [Fact]
    public void Type0IdentityHTextIsWrittenAsGlyphIds()
    {
        var seed = ContentEditPdf.Make(Simple);
        var pdf = ContentEditPdf.Make("BT /FU 20 Tf 72 692 Td " + ContentEditPdf.Cid(seed, "Hello World") + " Tj ET");
        var run = Run(pdf, "Hello World");
        Assert.True(run.Font!.TwoByte);
        var edited = ContentEditor.ReplaceText(pdf, null, run, "Hold Wer, 2024!");
        Assert.Contains("Hold Wer, 2024!", ContentEditPdf.Text(edited));
        Assert.Contains("<", ContentEditPdf.Content(edited)); // still a hex string

        var ex = Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceText(pdf, null, run, "Hello Kim"));
        Assert.Equal(["K", "i", "m"], ex.Missing);
    }

    [Fact]
    public void KerningOutsideTheEditIsKept()
    {
        var pdf = ContentEditPdf.Make("BT /FA 20 Tf 72 692 Td [-50 (H) 120 (ello) -900 (Wor) 80 (ld) 30] TJ ET");
        var run = Run(pdf, "Hello World");
        var edited = ContentEditor.ReplaceText(pdf, null, run, "Hello Wo");
        var content = ContentEditPdf.Content(edited);
        Assert.True(content.Contains("[-50 (H) 120 (ello) -900 (Wo) 30] TJ"), content);
        Assert.Contains("Hello Wo", System.Text.RegularExpressions.Regex.Replace(ContentEditPdf.Text(edited), @"\s+", " ")); // MuPDF breaks the line at the wide gap

        // An edit in the middle drops the adjustment inside it.
        var mid = ContentEditor.ReplaceText(pdf, null, run, "Hello Wedld");
        Assert.True(ContentEditPdf.Content(mid).Contains("[-50 (H) 120 (ello) -900 (Wedld) 30] TJ"), ContentEditPdf.Content(mid));
    }

    [Fact]
    public void QuoteOperatorsKeepTheirLineMoves()
    {
        var pdf = ContentEditPdf.Make("BT /FA 12 Tf 14 TL 72 700 Td (draft) Tj (Hello) ' 2 1 (World) \" ET");
        var hello = Run(pdf, "Hello");
        var world = Run(pdf, "World");
        Assert.Equal(14, hello.Box.Y - Run(pdf, "draft").Box.Y, 1);
        var e1 = ContentEditor.ReplaceText(pdf, null, hello, "Hell");
        Assert.Contains("(Hell) '", ContentEditPdf.Content(e1));
        var e2 = ContentEditor.ReplaceText(e1, null, Run(e1, "World"), "Word");
        Assert.Contains("2 1 (Word) \"", ContentEditPdf.Content(e2));
        Assert.Equal(world.Box.Y, Run(e2, "Word").Box.Y, 1);
    }

    [Fact]
    public void ASpaceTheCMapDoesNotMapIsStillWritten()
    {
        // Words set apart by TJ gaps in a font whose ToUnicode CMap has no space: the space comes from the font's own
        // cmap (and is added to the CMap), or else becomes a gap.
        var seed = ContentEditPdf.Make(Simple);
        var pdf = ContentEditPdf.WithoutSpace(ContentEditPdf.Make("BT /FU 20 Tf 72 692 Td [" + ContentEditPdf.Cid(seed, "Hello") + " -300 " + ContentEditPdf.Cid(seed, "World") + "] TJ ET"));
        var run = Run(pdf, "Hello World");
        Assert.Empty(run.Check("Hello World draft").Missing);
        var edited = ContentEditor.ReplaceText(pdf, null, run, "Hello World draft");
        Assert.Contains("Hello World draft", ContentEditPdf.Text(edited));
        Assert.Equal("Hello World draft", Run(edited, "Hello World draft").Text);
    }

    [Fact]
    public void TextInAFormXObjectIsListedButNotEditable()
    {
        var pdf = ContentEditPdf.Make("q /Fm1 Do Q BT /FA 12 Tf 72 600 Td (draft) Tj ET", form: "BT /FA 12 Tf 72 700 Td (Hello) Tj ET");
        var content = ContentEditor.Read(pdf, null, 0);
        var inForm = content.Runs.Single(r => r.Text == "Hello");
        Assert.Contains("form XObject", inForm.Blocked);
        Assert.True(inForm.Id < 0);
        Assert.Null(content.Runs.Single(r => r.Text == "draft").Blocked);
        var ex = Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceText(pdf, null, inForm, "Hell"));
        Assert.Contains("can't be edited", ex.Message);
    }

    [Fact]
    public void SeveralContentStreamsAreReadAsOne()
    {
        // The second stream continues the text object the first began.
        var pdf = ContentEditPdf.Make("BT /FA 20 Tf", extraStreams: ["72 692 Td (Hello) Tj", "ET BT /FA 9 Tf 72 600 Td (draft) Tj ET"]);
        var run = Run(pdf, "Hello");
        var edited = ContentEditor.ReplaceText(pdf, null, run, "Hell");
        var text = ContentEditPdf.Text(edited);
        Assert.Contains("Hell", text);
        Assert.Contains("draft", text);
    }

    [Fact]
    public void AStaleRunIsRefused()
    {
        var pdf = ContentEditPdf.Make(Simple);
        var run = Run(pdf, "Hello World");
        var edited = ContentEditor.ReplaceText(pdf, null, run, "Hello Wold");
        var ex = Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceText(edited, null, run, "Hello"));
        Assert.Contains("changed", ex.Message);
    }

    [Fact]
    public void InvisibleTextAndTextWithActualTextAreNotEditable()
    {
        var pdf = ContentEditPdf.Make("q BT 3 Tr /FA 12 Tf 72 700 Td (Hello) Tj ET Q\n/Span <</ActualText (fi)>> BDC BT /FA 12 Tf 72 600 Td (draft) Tj ET EMC BT /FA 12 Tf 72 500 Td (World) Tj ET");
        Assert.Contains("invisible", Run(pdf, "Hello").Blocked);
        Assert.Contains("ActualText", Run(pdf, "draft").Blocked);
        Assert.Null(Run(pdf, "World").Blocked);
    }

    [Fact]
    public void EncryptedFilesKeepTheirProtection()
    {
        var pdf = ContentEditPdf.Make(Simple);
        using (var d = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(pdf), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Modify))
        {
            d.SecuritySettings.UserPassword = "u";
            d.SecuritySettings.OwnerPassword = "o";
            using var ms = new MemoryStream();
            d.Save(ms, false);
            pdf = ms.ToArray();
        }
        var run = ContentEditor.Read(pdf, "o", 0).Runs.Single(r => r.Text == "Hello World");
        var edited = KeptProtection.Run(null, false, () => ContentEditor.ReplaceText(pdf, "o", run, "Hello Wold"));
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(edited, MuPDFCore.InputFileTypes.PDF, null));
        using var engine = PdfEngine.Open(edited, MuPDFCore.InputFileTypes.PDF, "u");
        Assert.Contains("Hello Wold", engine.GetText(0, cache: false).Text);
    }

    [Fact]
    public void SignedFilesGetTheEditAppended()
    {
        var pdf = SignedEditTests.Signed();
        var run = ContentEditor.Read(pdf, null, 0).Runs.FirstOrDefault(r => r.Blocked is null && r.Text.Length > 3);
        Assert.NotNull(run);
        var target = run!.Text[..^1];
        if (run.Check(target).Missing.Count > 0) return;
        var (edited, report) = SignedEdits.Run(() => ContentEditor.ReplaceText(pdf, null, run, target));
        Assert.True(report.Appended);
        Assert.True(report.RemovedItemKept);
        Assert.Equal(pdf, edited.AsSpan(0, pdf.Length).ToArray());
    }

    // ---- Pictures ----

    private const string Pictures = "q 100 0 0 50 72 600 cm /Im1 Do Q\nq 40 0 0 20 300 300 cm /Im1 Do Q\nBT /FA 12 Tf 72 500 Td (draft) Tj ET";

    [Fact]
    public void PicturesAreFoundWithTheirBoxes()
    {
        var pdf = ContentEditPdf.Make(Pictures + "\nq 30 0 0 10 50 50 cm BI /W 1 /H 1 /BPC 8 /CS /G ID \u0080\nEI Q");
        var images = ContentEditor.Read(pdf, null, 0).Images;
        Assert.Equal(3, images.Count);
        Assert.Equal(new RectD(72, 792 - 650, 100, 50), images[0].Box);
        Assert.True(images[2].Inline);
        Assert.Equal(new RectD(50, 792 - 60, 30, 10), images[2].Box);
    }

    [Fact]
    public void MovingAPictureRewritesOnlyItsPlacement()
    {
        var pdf = ContentEditPdf.Make(Pictures);
        var image = ContentEditor.Read(pdf, null, 0).Images[0];
        var moved = ContentEditor.MoveImage(pdf, null, image, new RectD(200, 100, 50, 25));
        var images = ContentEditor.Read(moved, null, 0).Images;
        Assert.Equal(2, images.Count);
        AssertNear(new RectD(200, 100, 50, 25), images[0].Box);
        AssertNear(new RectD(300, 792 - 320, 40, 20), images[1].Box); // the other use of /Im1 stays
        Assert.Contains("50 0 0 25 200 667 cm", ContentEditPdf.Content(moved)); // its own cm changed, no wrapper

        // MuPDF draws it there.
        using var engine = PdfEngine.Open(moved, MuPDFCore.InputFileTypes.PDF, null);
        var shown = engine.GetExportPage(0, images: true).Images.Select(i => i.Box).ToList();
        Assert.Contains(shown, b => Math.Abs(b.X - 200) < 1 && Math.Abs(b.Y - 100) < 1 && Math.Abs(b.Width - 50) < 1);
    }

    [Fact]
    public void APictureWithoutItsOwnGroupIsWrapped()
    {
        var pdf = ContentEditPdf.Make("q 2 0 0 2 0 0 cm q 50 0 0 25 10 10 cm /Im1 Do 30 0 0 10 0 100 cm /Im1 Do Q Q", rotate: 90);
        var images = ContentEditor.Read(pdf, null, 0).Images;
        var target = new RectD(images[0].Box.X + 30, images[0].Box.Y + 40, images[0].Box.Width / 2, images[0].Box.Height / 2);
        var moved = ContentEditor.MoveImage(pdf, null, images[0], target);
        var after = ContentEditor.Read(moved, null, 0).Images;
        AssertNear(target, after[0].Box);
        AssertNear(images[1].Box, after[1].Box); // drawn after it, under the same state: unchanged
    }

    [Fact]
    public void DeletingAPictureKeepsItsOtherUses()
    {
        var pdf = ContentEditPdf.Make(Pictures);
        var image = ContentEditor.Read(pdf, null, 0).Images[0];
        var (deleted, report) = SignedEdits.Run(() => ContentEditor.DeleteImage(pdf, null, image));
        Assert.False(report.Appended);
        var images = ContentEditor.Read(deleted, null, 0).Images;
        Assert.Single(images);
        AssertNear(new RectD(300, 792 - 320, 40, 20), images[0].Box);
        Assert.Contains("draft", ContentEditPdf.Text(deleted));
    }

    [Fact]
    public void DeletingTheLastUseDropsTheResource()
    {
        var pdf = ContentEditPdf.Make("q 100 0 0 50 72 600 cm /Im1 Do Q");
        var deleted = ContentEditor.DeleteImage(pdf, null, ContentEditor.Read(pdf, null, 0).Images[0]);
        Assert.Empty(ContentEditor.Read(deleted, null, 0).Images);
        using var d = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(deleted), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        var xo = PdfObj.Dict(PdfObj.Dict(d.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!;
        Assert.False(xo.Elements.ContainsKey("/Im1"));
    }

    [Fact]
    public void InlinePicturesCanBeMovedAndDeleted()
    {
        var pdf = ContentEditPdf.Make("q 30 0 0 10 50 50 cm BI /W 1 /H 1 /BPC 8 /CS /G ID \u0080\nEI Q BT /FA 12 Tf 72 500 Td (draft) Tj ET");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        var moved = ContentEditor.MoveImage(pdf, null, image, new RectD(100, 100, 60, 20));
        AssertNear(new RectD(100, 100, 60, 20), ContentEditor.Read(moved, null, 0).Images.Single().Box);
        var deleted = ContentEditor.DeleteImage(moved, null, ContentEditor.Read(moved, null, 0).Images.Single());
        Assert.Empty(ContentEditor.Read(deleted, null, 0).Images);
        Assert.Contains("draft", ContentEditPdf.Text(deleted));
    }

    [Fact]
    public void ReplacingAPictureFitsTheNewOneInItsBox()
    {
        var pdf = ContentEditPdf.Make(Pictures);
        var image = ContentEditor.Read(pdf, null, 0).Images[0]; // 100 x 50
        var png = TestImages.Png(10, 10, (_, _) => (0, 0, 255, 255));
        var replaced = ContentEditor.ReplaceImage(pdf, null, image, png, "blue.png");
        var images = ContentEditor.Read(replaced, null, 0).Images;
        Assert.Equal(2, images.Count);
        AssertNear(new RectD(72 + 25, 792 - 650, 50, 50), images[0].Box); // square, centered
        var (r, g, b) = TestImages.PixelAt(replaced, 0, 72 + 50, 792 - 625);
        Assert.True(b > 200 && r < 60, $"{r},{g},{b}");
        var (r2, _, _) = TestImages.PixelAt(replaced, 0, 320, 792 - 310);
        Assert.True(r2 > 200); // the other use is still the red picture
    }

    [Fact]
    public void PicturesInAFormXObjectAreNotEditable()
    {
        var pdf = ContentEditPdf.Make("q /Fm1 Do Q", form: "q 100 0 0 50 72 600 cm /Im1 Do Q");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        Assert.NotNull(image.Blocked);
        Assert.Throws<ContentEditException>(() => ContentEditor.DeleteImage(pdf, null, image));
    }

    private static void AssertNear(RectD expected, RectD actual)
    {
        Assert.True(Math.Abs(expected.X - actual.X) < 0.6 && Math.Abs(expected.Y - actual.Y) < 0.6
            && Math.Abs(expected.Width - actual.Width) < 0.6 && Math.Abs(expected.Height - actual.Height) < 0.6, $"expected {expected}, got {actual}");
    }

    /// <summary>A realistic page (PDFsharp text, a table, a logo): its text and picture are found and editable. With INKVOLTPDF_SAMPLES set it is written there (edit-sample.pdf) for the app.</summary>
    [Fact]
    public void ARealisticPageIsReadAndEdited()
    {
        var pdf = ExportTestPdf.Make(logo: true);
        var content = ContentEditor.Read(pdf, null, 0);
        Assert.NotEmpty(content.Images);
        Assert.True(content.Runs.Count(r => r.Blocked is null) > 5);
        var run = content.Runs.First(r => r.Blocked is null && r.Text.Length > 4);
        var shorter = run.Text[..^1];
        Assert.Empty(run.Check(shorter).Missing);
        var edited = ContentEditor.ReplaceText(pdf, null, run, shorter);
        Assert.Contains(shorter, ContentEditPdf.Text(edited));
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is { Length: > 0 } dir)
        {
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(Path.Combine(dir, "edit-sample.pdf"), pdf);
        }
    }

    // ---- Regressions (review of the first version) ----

    [Theory]
    [InlineData("BI /W 2 /H 1 /BPC 8 /CS /G /F /AHx ID 00ff> EI Q BT /FA 12 Tf 72 500 Td (Se\u00F1or) Tj ET")] // Latin-1 in a string after it
    [InlineData("BI /W 2 /H 1 /BPC 8 /CS /G /F /AHx ID 00ff>EI Q BT /FA 12 Tf 72 500 Td (Se\u00F1or) Tj ET")]  // no space before EI
    [InlineData("BI /W 2 /H 1 /BPC 8 /CS /G /F /A85 ID !!~> EI Q BT /FA 12 Tf 72 500 Td (Se\u00F1or) Tj ET")]
    [InlineData("BI /W 2 /H 1 /BPC 8 /CS /G /F /Fl /L 6 ID \x01\x02 EI\xff EI Q BT /FA 12 Tf 72 500 Td (Se\u00F1or) Tj ET")] // stated length
    public void InlineImageDataEndsWhereItSays(string body)
    {
        var ops = ContentLexer.Parse(Encoding.Latin1.GetBytes("q 30 0 0 10 50 50 cm " + body));
        Assert.Equal(["q", "cm", "BI", "Q", "BT", "Tf", "Td", "Tj", "ET"], ops.Select(o => o.Name));
        Assert.False(ops[2].Broken);
    }

    [Fact]
    public void AnInlineImageWithoutAClearEndIsNotEditableAndNothingIsLost()
    {
        // Filtered data with binary bytes after every EI candidate: its end can't be told, so it isn't touched.
        var content = "q 30 0 0 10 50 50 cm BI /W 2 /H 1 /BPC 8 /CS /G /F /Fl ID \x01 EI\x02\x03\x04 Q BT /FA 12 Tf 72 500 Td (draft) Tj ET";
        var ops = ContentLexer.Parse(Encoding.Latin1.GetBytes(content));
        Assert.True(ops[^1].Broken);
        Assert.Equal(ops[^1].DataStart, ops[^1].End); // never stretched to the end of the stream
        var pdf = ContentEditPdf.Make("BT /FA 12 Tf 72 600 Td (Hello) Tj ET " + content);
        var page = ContentEditor.Read(pdf, null, 0);
        Assert.NotNull(page.Images.Single().Blocked);
        Assert.Throws<ContentEditException>(() => ContentEditor.DeleteImage(pdf, null, page.Images.Single()));
        var edited = ContentEditor.ReplaceText(pdf, null, page.Runs.Single(r => r.Text == "Hello"), "Hell");
        Assert.EndsWith(content, ContentEditPdf.Content(edited).TrimEnd()); // the rest of the page as it was
    }

    [Theory]
    [InlineData("q 1 0 0 1 20 10 cm 30 0 0 10 50 50 cm BI /W 1 /H 1 /BPC 8 /CS /G ID \x80\nEI Q")] // two cms
    [InlineData("q /GS1 gs 30 0 0 10 50 50 cm BI /W 1 /H 1 /BPC 8 /CS /G ID \x80\nEI Q")]           // gs before the cm
    public void AnInlineImageMovedOutsideItsOwnGroupKeepsItsData(string content)
    {
        var pdf = ContentEditPdf.Make(content + " BT /FA 12 Tf 72 500 Td (draft) Tj ET");
        var image = ContentEditor.Read(pdf, null, 0).Images.Single();
        var moved = ContentEditor.MoveImage(pdf, null, image, new RectD(200, 100, 60, 20));
        var after = ContentEditor.Read(moved, null, 0).Images.Single();
        AssertNear(new RectD(200, 100, 60, 20), after.Box);
        Assert.True(after.Inline);
        Assert.Contains("ID \x80\nEI", ContentEditPdf.Content(moved));
        var (r, g, b) = TestImages.PixelAt(moved, 0, 230, 110);
        Assert.True(r > 100 && r < 160 && r == g && g == b, $"{r},{g},{b}"); // the gray pixel, drawn there
    }

    [Fact]
    public void AContentStreamThatCantBeReadIsKept()
    {
        var pdf = ContentEditPdf.Make("BT /FA 20 Tf 72 692 Td (Hello) Tj ET", extraStreams: ["BT /FA 9 Tf 72 600 Td (draft) Tj ET"], damagedPart: true);
        var edited = ContentEditor.ReplaceText(pdf, null, Run(pdf, "Hello"), "Hell");
        using var d = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(edited), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import);
        var parts = PdfObj.Array(d.Pages[0].Elements["/Contents"])!;
        Assert.Equal(3, parts.Elements.Count); // only the edited stream was replaced
        Assert.Equal(12, PdfObj.Dict(parts.Elements[2])!.Stream!.Value.Length);
        Assert.Contains("draft", ContentEditPdf.Text(edited));

        // An operator split across streams needs them rewritten as one: refused rather than dropping the damaged one.
        var split = ContentEditPdf.Make("BT /FA 20 Tf 72 692 Td (Hello)", extraStreams: ["Tj ET"], damagedPart: true);
        var ex = Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceText(split, null, Run(split, "Hello"), "Hell"));
        Assert.Contains("damaged", ex.Message);
    }

    [Fact]
    public void APictureAFormBorrowsStaysInThePageResources()
    {
        var pdf = ContentEditPdf.Make("q 100 0 0 50 72 600 cm /Im1 Do Q q /Fm1 Do Q", form: "q 40 0 0 20 300 300 cm /Im1 Do Q", formInherits: true);
        var image = ContentEditor.Read(pdf, null, 0).Images.First(i => i.Blocked is null);
        var deleted = ContentEditor.DeleteImage(pdf, null, image);
        using (var d = PdfSharp.Pdf.IO.PdfReader.Open(new MemoryStream(deleted), PdfSharp.Pdf.IO.PdfDocumentOpenMode.Import))
        {
            var xo = PdfObj.Dict(PdfObj.Dict(d.Pages[0].Elements["/Resources"])!.Elements["/XObject"])!;
            Assert.True(xo.Elements.ContainsKey("/Im1"));
        }
        var (r, _, _) = TestImages.PixelAt(deleted, 0, 320, 792 - 310);
        Assert.True(r > 200); // the form still draws the red picture
    }
}
