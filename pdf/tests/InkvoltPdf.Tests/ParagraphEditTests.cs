using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using InkvoltPdf.Core;
using Xunit.Abstractions;

namespace InkvoltPdf.Tests;

/// <summary>
/// Edit Text &amp; Images, paragraphs (roadmap 2.1, first part): a page's lines grouped into paragraphs with their
/// alignment and line step, and a paragraph's text replaced, rewrapped in its box in its own embedded font.
/// </summary>
public class ParagraphEditTests(ITestOutputHelper output)
{
    /// <summary>What the test fonts hold: no "@", "#" or "€".</summary>
    private const string Chars = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 .,;:!?'-";

    private const double Size = 11, Step = 14, Width = 300, Left = 72, Top = 700; // PDF user space (y up)

    private const string Body = "The quick brown fox jumps over the lazy dog while five boxing wizards jump quickly and a sphinx of black " +
                                "quartz judges my vow of silence on a calm and quiet evening by the river";

    private const string Twenty = "Then seven tired hikers walked along the narrow path toward the old stone bridge before the rain came at last";

    private static string N(double v) => v.ToString("0.###", CultureInfo.InvariantCulture);

    private static TextRun? _probe;

    /// <summary>The width of text in /FA at <see cref="Size"/> (points), as the editor measures it.</summary>
    private static double Measure(string text)
    {
        _probe ??= ContentEditor.Read(ContentEditPdf.Make($"BT /FA {N(Size)} Tf 72 700 Td (a) Tj ET", fontText: Chars), null, 0).Runs.Single();
        return _probe.Check(text).Width;
    }

    /// <summary>Greedy word wrap at <paramref name="width"/>, as a typesetter does.</summary>
    private static List<string> Wrap(string text, double width, double firstIndent = 0)
    {
        var lines = new List<string>();
        var cur = "";
        foreach (var word in text.Split(' '))
        {
            var room = width - (lines.Count == 0 ? firstIndent : 0);
            if (cur.Length > 0 && Measure(cur + " " + word) > room)
            {
                lines.Add(cur);
                cur = word;
            }
            else cur = cur.Length == 0 ? word : cur + " " + word;
        }
        lines.Add(cur);
        return lines;
    }

    /// <summary>
    /// A page: a heading, <see cref="Body"/> as a paragraph aligned as asked, and a line of text <paramref name="gap"/>
    /// points under the paragraph's last baseline. Left text is written the way many generators do: one text object,
    /// T* from line to line, the next block placed relative to it (Td), so the edit has to leave the text position right.
    /// </summary>
    private static (byte[] Pdf, List<string> Lines) Page(ParagraphAlign align, double gap = 60, string body = Body, double indent = 0)
    {
        var lines = Wrap(body, Width, indent);
        var sb = new StringBuilder($"BT /FA 16 Tf 72 740 Td (A Heading Here) Tj ET\n");
        var lastY = Top - (lines.Count - 1) * Step;
        if (align == ParagraphAlign.Left)
        {
            sb.Append($"BT /FA {N(Size)} Tf {N(Step)} TL {N(Left + indent)} {N(Top)} Td ({lines[0]}) Tj {N(-indent)} 0 Td");
            foreach (var l in lines.Skip(1)) sb.Append($" T* ({l}) Tj");
            sb.Append($" 0 {N(-gap)} Td (Next block starts here) Tj ET\n");
        }
        else
        {
            for (var i = 0; i < lines.Count; i++)
            {
                var w = Measure(lines[i]);
                var y = Top - i * Step;
                var x = align switch
                {
                    ParagraphAlign.Right => Left + Width - w,
                    ParagraphAlign.Center => Left + (Width - w) / 2,
                    _ => Left,
                };
                var spaces = lines[i].Count(c => c == ' ');
                var tw = align == ParagraphAlign.Justified && i < lines.Count - 1 && spaces > 0 ? (Width - w) / spaces : 0;
                sb.Append($"BT /FA {N(Size)} Tf {N(tw)} Tw {N(x)} {N(y)} Td ({lines[i]}) Tj ET\n");
            }
            sb.Append($"BT /FA {N(Size)} Tf 0 Tw {N(Left)} {N(lastY - gap)} Td (Next block starts here) Tj ET\n");
        }
        return (ContentEditPdf.Make(sb.ToString(), fontText: Chars), lines);
    }

    private static TextParagraph Body0(byte[] pdf, string start = "The quick") =>
        ContentEditor.Read(pdf, null, 0).Paragraphs.Single(p => p.Text.StartsWith(start, StringComparison.Ordinal));

    /// <summary>Text with its white space made single spaces and ligatures spelled out (MuPDF reads "ﬁ" as "fi").</summary>
    private static string Words(string s) => Regex.Replace(s.Normalize(NormalizationForm.FormKC), @"\s+", " ").Trim();

    // ---- Grouping ----

    [Theory]
    [InlineData(ParagraphAlign.Left)]
    [InlineData(ParagraphAlign.Right)]
    [InlineData(ParagraphAlign.Center)]
    [InlineData(ParagraphAlign.Justified)]
    public void LinesGroupIntoAParagraphWithItsAlignmentAndLineStep(ParagraphAlign align)
    {
        var (pdf, lines) = Page(align);
        Assert.True(lines.Count >= 3);
        var content = ContentEditor.Read(pdf, null, 0);
        var p = Body0(pdf);
        Assert.Null(p.Blocked);
        Assert.Equal(Body, p.Text);
        Assert.Equal(lines.Count, p.Lines.Count);
        Assert.Equal(align, p.Align);
        Assert.InRange(p.LineStep, Step - 0.1, Step + 0.1);
        Assert.InRange(p.Box.X, Left - 1, Left + Width);
        Assert.InRange(p.Box.Right, Left, Left + Width + 1);
        // The heading and the block below are paragraphs of their own; the block below is what the paragraph would grow into.
        Assert.Equal(3, content.Paragraphs.Count);
        var next = content.Runs.Single(r => r.Text == "Next block starts here");
        Assert.Equal(next.Box, p.Below);
        // A click anywhere on the paragraph's text, or between its lines, finds it.
        Assert.Equal(p.Text, content.ParagraphAt(p.Lines[1].X + 5, p.Lines[1].Y + 3)!.Text);
        Assert.Equal(p.Text, content.ParagraphAt(p.Lines[0].X + 2, (p.Lines[0].Bottom + p.Lines[1].Y) / 2)!.Text);
    }

    [Fact]
    public void AFirstLineIndentIsKeptAndLinesThatEndShortSplitParagraphs()
    {
        // Two left-aligned paragraphs at one line step: the first's last line ends short, the second starts flush.
        var first = Wrap(Body, Width, 24);
        var second = Wrap(Twenty, Width);
        var sb = new StringBuilder($"BT /FA {N(Size)} Tf {N(Step)} TL 96 {N(Top)} Td ({first[0]}) Tj -24 0 Td");
        foreach (var l in first.Skip(1).Concat(second)) sb.Append($" T* ({l}) Tj");
        sb.Append(" ET");
        var pdf = ContentEditPdf.Make(sb.ToString(), fontText: Chars);
        var paras = ContentEditor.Read(pdf, null, 0).Paragraphs;
        Assert.Equal([Body, Twenty], paras.Select(p => p.Text));
        Assert.InRange(paras[0].FirstIndent, 23.5, 24.5);
        Assert.Equal(ParagraphAlign.Left, paras[0].Align);
        Assert.Equal(0, paras[1].FirstIndent);

        // Rewritten, the indent stays.
        var edited = ContentEditor.ReplaceParagraph(pdf, null, paras[0], "Short new text for the first paragraph that still wraps onto a second line at this width");
        var again = ContentEditor.Read(edited, null, 0).Paragraphs.First();
        Assert.InRange(again.FirstIndent, 23.5, 24.5);
        Assert.InRange(again.Lines[0].X, 95.5, 96.5);
    }

    [Fact]
    public void TextOfOtherSizesOrFontsIsNotJoined()
    {
        var pdf = ContentEditPdf.Make(
            $"BT /FA 11 Tf 72 700 Td (One line of body text here) Tj ET\nBT /FA 9 Tf 72 686 Td (smaller text under it) Tj ET\n" +
            $"BT /FU 11 Tf 72 672 Td {ContentEditPdf.Cid(ContentEditPdf.Make("", fontText: Chars), "other font text")} Tj ET", fontText: Chars);
        Assert.Equal(3, ContentEditor.Read(pdf, null, 0).Paragraphs.Count);
    }

    // ---- Rewriting ----

    [Theory]
    [InlineData(ParagraphAlign.Left)]
    [InlineData(ParagraphAlign.Right)]
    [InlineData(ParagraphAlign.Center)]
    [InlineData(ParagraphAlign.Justified)]
    public void TwentyWordsAddedReflowInOrderAndNothingOverlapsTheNextBlock(ParagraphAlign align)
    {
        var (pdf, lines) = Page(align, gap: 120);
        var before = ContentEditor.Read(pdf, null, 0);
        var p = Body0(pdf);
        var next = before.Runs.Single(r => r.Text == "Next block starts here");
        var heading = before.Runs.Single(r => r.Text == "A Heading Here");
        var text = Body + " " + Twenty;
        Assert.Equal(20, Twenty.Split(' ').Length);

        var check = p.Check(text);
        Assert.Empty(check.Missing);
        Assert.Null(check.Overlaps);
        Assert.True(check.LineCount > lines.Count);
        Assert.True(check.Box.Bottom < next.Box.Y);

        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text);
        // Read back by MuPDF in order, the words all there; the old text gone.
        var extracted = Words(ContentEditPdf.Text(edited));
        Assert.Contains(Words(text), extracted);
        Assert.Single(Regex.Matches(extracted, "quick brown"));

        var after = ContentEditor.Read(edited, null, 0);
        var q = Body0(edited);
        Assert.Equal(text, q.Text);
        Assert.Equal(align, q.Align);
        Assert.Equal(check.LineCount, q.Lines.Count);
        Assert.InRange(q.LineStep, Step - 0.1, Step + 0.1);
        Assert.InRange(q.Box.X, p.Box.X - 1, p.Box.Right);
        Assert.True(q.Box.Right <= p.Box.Right + 0.5, $"{q.Box.Right} > {p.Box.Right}");
        // What follows stays where it was (in the left case it is placed relative to the paragraph's text).
        var next2 = after.Runs.Single(r => r.Text == "Next block starts here");
        Assert.Equal(next.Box.X, next2.Box.X, 2);
        Assert.Equal(next.Box.Y, next2.Box.Y, 2);
        Assert.Equal(heading.Box, after.Runs.Single(r => r.Text == "A Heading Here").Box);
        Assert.All(q.Lines, l => Assert.True(l.Bottom < next2.Box.Y));
        Assert.All(Core2Pdf.Lines(edited).Where(l => l.Text.Contains("Next block")), l => Assert.Equal("Next block starts here", l.Text.Trim()));
        if (align == ParagraphAlign.Center)
            Assert.All(q.Lines, l => Assert.Equal(p.Box.CenterX, l.CenterX, 1));
        if (align == ParagraphAlign.Right)
            Assert.All(q.Lines, l => Assert.Equal(p.Box.Right, l.Right, 1));
    }

    [Fact]
    public void ShorterTextShrinksTheParagraph()
    {
        var (pdf, _) = Page(ParagraphAlign.Justified);
        var p = Body0(pdf);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, "The quick end.");
        var q = Body0(edited);
        Assert.Single(q.Lines);
        Assert.Equal("The quick end.", q.Text);
        Assert.Equal(p.Lines[0].X, q.Lines[0].X, 1); // the last (only) line of justified text starts left
    }

    [Fact]
    public void ALineBreakStartsANewLine()
    {
        var (pdf, _) = Page(ParagraphAlign.Left);
        var p = Body0(pdf);
        var check = p.Check("First line\r\nsecond line");
        Assert.Equal(2, check.LineCount);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, "First line\nsecond line");
        Assert.Contains("First line\nsecond line", ContentEditPdf.Text(edited).Replace("\r", ""));
    }

    [Fact]
    public void RunningIntoTheBlockBelowIsReportedBeforeAnythingIsWritten()
    {
        var (pdf, _) = Page(ParagraphAlign.Left, gap: 28);
        var p = Body0(pdf);
        var text = Body + " " + Twenty + " " + Twenty; // three lines more, where there is room for one
        var check = p.Check(text);
        Assert.NotNull(check.Overlaps);
        Assert.Equal(p.Below, check.Overlaps);
        var ex = Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceParagraph(pdf, null, p, text));
        Assert.NotNull(ex.Overlaps);
        Assert.Contains("run into what follows", ex.Message);

        // Confirmed, it is written anyway (the caller warned).
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text, allowOverlap: true);
        Assert.Contains(Words(Twenty), Words(ContentEditPdf.Text(edited)));
        // A shorter text that fits doesn't warn.
        Assert.Null(p.Check(Body[..40]).Overlaps);
    }

    [Fact]
    public void CharactersTheEmbeddedFontLacksAreRefusedByName()
    {
        var (pdf, _) = Page(ParagraphAlign.Justified);
        var p = Body0(pdf);
        var text = Body + " mail me @ home #1";
        Assert.Equal(["@", "#"], p.Check(text).Missing);
        var ex = Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceParagraph(pdf, null, p, text));
        Assert.Equal(["@", "#"], ex.Missing);
        Assert.Contains("“@”", ex.Message);
    }

    [Fact]
    public void NewCharactersTheFontHasButThePdfDidntUseCopyAsTyped()
    {
        // The subset holds "Z" and "q", but the page's text never used them before.
        var (pdf, _) = Page(ParagraphAlign.Left, body: "Some plain words in a line that wraps around to the next one at this width of the box here");
        var p = Body0(pdf, "Some plain");
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, "Zebra quietly zigzags past the quay, then quits.");
        Assert.Contains("Zebra quietly zigzags past the quay, then quits.", Words(ContentEditPdf.Text(edited)));
    }

    [Fact]
    public void ATwoByteFontParagraphReflowsToo()
    {
        var seed = ContentEditPdf.Make("", fontText: Chars);
        var lines = Wrap(Body, Width);
        var sb = new StringBuilder($"BT /FU {N(Size)} Tf {N(Step)} TL 72 {N(Top)} Td {ContentEditPdf.Cid(seed, lines[0])} Tj");
        foreach (var l in lines.Skip(1)) sb.Append($" T* {ContentEditPdf.Cid(seed, l)} Tj");
        sb.Append(" ET");
        var pdf = ContentEditPdf.Make(sb.ToString(), fontText: Chars);
        var p = Body0(pdf);
        Assert.Null(p.Blocked);
        Assert.Equal(Body, p.Text);
        var text = Body + " " + Twenty;
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, text);
        Assert.Contains(Words(text), Words(ContentEditPdf.Text(edited)));
        Assert.Equal(text, Body0(edited).Text);
    }

    [Fact]
    public void AParagraphMixingFontsIsBlocked()
    {
        var fu = ContentEditPdf.Cid(ContentEditPdf.Make("", fontText: Chars), " bold words");
        var lines = Wrap(Body, Width);
        var pdf = ContentEditPdf.Make(
            $"BT /FA 11 Tf 14 TL 72 700 Td ({lines[0]}) Tj T* ({lines[1]}) Tj /FU 11 Tf {fu} Tj /FA 11 Tf T* ({lines[2]}) Tj ET", fontText: Chars);
        var p = ContentEditor.Read(pdf, null, 0).Paragraphs.Single(q => q.Lines.Count > 1);
        Assert.NotNull(p.Blocked);
        Assert.Throws<ContentEditException>(() => ContentEditor.ReplaceParagraph(pdf, null, p, "anything"));
    }

    [Fact]
    public void SignedFilesGetTheParagraphEditAppended()
    {
        const string placeholder = "[0 0000000000 0000000000 0000000000]";
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /Rect [72 750 272 780] /V 5 0 R /P 3 0 R /F 4 >>",
            $"<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange {placeholder} /Contents <{new string('0', IncrSignatureTests.ContentsHexLength)}> >>",
            Core2Pdf.Stream("BT /F1 12 Tf 14 TL 72 700 Td (This agreement is made between the two parties named) Tj T* " +
                            "(below, who agree to the terms set out in the pages that) Tj T* (follow this one.) Tj ET"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        };
        var pdf = IncrSignatureTests.Sign(Core2Pdf.Build(objects), placeholder);
        var p = ContentEditor.Read(pdf, null, 0).Paragraphs.Single();
        Assert.Equal(3, p.Lines.Count);
        Assert.Null(p.Blocked);
        var text = p.Text.Replace("two parties", "three parties", StringComparison.Ordinal);
        var (edited, report) = SignedEdits.Run(() => ContentEditor.ReplaceParagraph(pdf, null, p, text));
        Assert.True(report.Appended);
        Assert.True(report.RemovedItemKept);
        Assert.Equal(pdf, edited.AsSpan(0, pdf.Length).ToArray());
        Assert.Contains("three parties", Words(ContentEditPdf.Text(edited)));
    }

    /// <summary>
    /// One page with a paragraph of each alignment, the last with a line right under it (to see the overlap warning).
    /// With INKVOLTPDF_SAMPLES set it is written there (paragraph-sample.pdf) for the app.
    /// </summary>
    [Fact]
    public void ASamplePageHoldsOneParagraphOfEachAlignment()
    {
        var sb = new StringBuilder("BT /FA 16 Tf 72 750 Td (Paragraph Sample) Tj ET\n");
        var top = 720.0;
        foreach (var align in new[] { ParagraphAlign.Left, ParagraphAlign.Justified, ParagraphAlign.Center, ParagraphAlign.Right })
        {
            var lines = Wrap(Body, Width);
            for (var i = 0; i < lines.Count; i++)
            {
                var w = Measure(lines[i]);
                var spaces = lines[i].Count(c => c == ' ');
                var tw = align == ParagraphAlign.Justified && i < lines.Count - 1 ? (Width - w) / spaces : 0;
                var x = align switch { ParagraphAlign.Right => Left + Width - w, ParagraphAlign.Center => Left + (Width - w) / 2, _ => Left };
                sb.Append($"BT /FA {N(Size)} Tf {N(tw)} Tw {N(x)} {N(top - i * Step)} Td ({lines[i]}) Tj ET\n");
            }
            top -= lines.Count * Step + 30;
        }
        sb.Append($"BT /FA {N(Size)} Tf 0 Tw 72 {N(top + 20)} Td (A line right under the last paragraph) Tj ET\n");
        var pdf = ContentEditPdf.Make(sb.ToString(), fontText: Chars);
        var paras = ContentEditor.Read(pdf, null, 0).Paragraphs.Where(p => p.Lines.Count > 1).ToList();
        Assert.Equal([ParagraphAlign.Left, ParagraphAlign.Justified, ParagraphAlign.Center, ParagraphAlign.Right], paras.Select(p => p.Align));
        Assert.NotNull(paras[^1].Check(Body + " " + Twenty).Overlaps);
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_SAMPLES") is { Length: > 0 } dir)
        {
            Directory.CreateDirectory(dir);
            File.WriteAllBytes(Path.Combine(dir, "paragraph-sample.pdf"), pdf);
        }
    }

    [Fact]
    public void TheEditIsOneSaveAndTheOldTextIsGoneFromTheContent()
    {
        var (pdf, lines) = Page(ParagraphAlign.Center);
        var p = Body0(pdf);
        var edited = ContentEditor.ReplaceParagraph(pdf, null, p, "Centered and short now, on two lines when it wraps at the width of the old box here");
        var content = ContentEditPdf.Content(edited);
        Assert.All(lines, l => Assert.DoesNotContain($"({l})", content));
        var q = Body0(edited, "Centered");
        Assert.Same(edited, ContentEditor.ReplaceParagraph(edited, null, q, q.Text));
    }

    /// <summary>
    /// The roadmap's test on real files, run only with INKVOLTPDF_CORPUS set to a folder of PDFs (the export corpus's
    /// .cache): on each of the first pages, the longest editable paragraph gets 20 of its own words added; they must
    /// re-extract in order, and the new lines must not overlap anything else on the page unless the check said so.
    /// Results are written to the test output, nothing to disk.
    /// </summary>
    [Fact]
    public void CorpusParagraphsTakeTwentyMoreWords()
    {
        if (Environment.GetEnvironmentVariable("INKVOLTPDF_CORPUS") is not { Length: > 0 } dir || !Directory.Exists(dir)) return;
        var failures = new List<string>();
        foreach (var file in Directory.GetFiles(dir, "*.pdf").Order())
        {
            var pdf = File.ReadAllBytes(file);
            var name = Path.GetFileName(file);
            int pages;
            using (var engine = PdfEngine.Open(pdf, MuPDFCore.InputFileTypes.PDF, null)) pages = engine.PageCount;
            for (var page = 0; page < Math.Min(3, pages); page++)
            {
                PageContent content;
                try
                {
                    content = ContentEditor.Read(pdf, null, page);
                }
                catch (Exception ex) when (ex is InvalidOperationException or ArgumentException)
                {
                    output.WriteLine($"{name} p{page + 1}: unreadable ({ex.Message})");
                    continue;
                }
                var all = content.Paragraphs.Count;
                var multi = content.Paragraphs.Count(q => q.Lines.Count > 1);
                var editable = content.Paragraphs.Where(q => q.Blocked is null && q.Lines.Count > 1).ToList();
                var p = editable.MaxBy(q => q.Lines.Count);
                if (p is null)
                {
                    output.WriteLine($"{name} p{page + 1}: {all} paragraphs, {multi} of several lines, none editable " +
                                     $"({string.Join("; ", content.Paragraphs.Where(q => q.Lines.Count > 1).Select(q => q.Blocked).Distinct().Take(3))})");
                    continue;
                }
                var words = p.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries);
                var added = string.Join(' ', Enumerable.Range(0, 20).Select(i => words[i % words.Length]));
                var text = p.Text + " " + added;
                var check = p.Check(text);
                var line = $"{name} p{page + 1}: {all} paragraphs, {multi} of several lines, {editable.Count} editable; " +
                           $"longest {p.Lines.Count} lines {p.Align} {p.FontSize:0.#} pt → {check.LineCount} lines";
                if (check.Missing.Count > 0)
                {
                    output.WriteLine($"{line}; refused, font lacks {string.Join(" ", check.Missing.Take(5))}");
                    continue;
                }
                byte[] edited;
                try
                {
                    edited = ContentEditor.ReplaceParagraph(pdf, null, p, text, allowOverlap: true);
                }
                catch (ContentEditException ex)
                {
                    failures.Add($"{line}: {ex.Message}");
                    continue;
                }
                using (var engine = PdfEngine.Open(edited, MuPDFCore.InputFileTypes.PDF, null))
                {
                    var got = Words(engine.GetText(page, cache: false).Text);
                    if (!got.Contains(Words(added), StringComparison.Ordinal)) failures.Add($"{line}: the added words don't re-extract in order");
                }
                var after = ContentEditor.Read(edited, null, page);
                var others = after.Runs.Where(r => r.Text.Trim().Length > 0 && !r.Box.IsEmpty).Select(r => r.Box).ToList();
                // The new lines: runs inside the new box that weren't on the page before.
                var before = content.Runs.Select(r => (r.Text, Math.Round(r.Box.X), Math.Round(r.Box.Y))).ToHashSet();
                var fresh = after.Runs.Where(r => !before.Contains((r.Text, Math.Round(r.Box.X), Math.Round(r.Box.Y))) && check.Box.Inflate(1).Contains(r.Box.X, r.Box.Y)).ToList();
                var hits = fresh.Count(f => after.Runs.Any(o => !fresh.Contains(o) && o.Text.Trim().Length > 0 && o.Box.Intersect(f.Box) is { IsEmpty: false } x && x.Width * x.Height > 4));
                output.WriteLine($"{line}; overlap {(check.Overlaps is null ? "none reported" : "reported")}, {hits} new line(s) touching other text");
                if (check.Overlaps is null && hits > 0) failures.Add($"{line}: new lines overlap other text, unreported");
            }
        }
        foreach (var f in failures) output.WriteLine("FAIL " + f);
        Assert.Empty(failures);
    }
}
