using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Find &amp; Replace across the document (roadmap 4.2): matches found in the paragraphs Edit Text &amp; Images edits, and
/// replaced through its paragraph editing in one pass (one undo step, one incremental update for a signed file), each
/// replacement that can't be made as asked listed with what was done instead.
/// </summary>
public class TextReplaceTests(Xunit.Abstractions.ITestOutputHelper output)
{
    /// <summary>What <see cref="ContentEditPdf"/>'s fonts hold: no "@", "#" or "€".</summary>
    private const string Chars = "abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 .,;:!?'-";

    private static string Page(params string[][] paragraphs)
    {
        var sb = new System.Text.StringBuilder();
        var y = 700;
        foreach (var lines in paragraphs)
        {
            sb.Append($"BT /F1 12 Tf 15 TL 72 {y} Td ({lines[0]}) Tj");
            foreach (var l in lines.Skip(1)) sb.Append($" T* ({l}) Tj");
            sb.Append(" ET\n");
            y -= 15 * lines.Length + 60;
        }
        return sb.ToString();
    }

    /// <summary>Pages of Helvetica paragraphs (each page a list of paragraphs, each a list of lines).</summary>
    private static byte[] Doc(params string[][][] pages)
    {
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            $"<< /Type /Pages /Kids [{string.Join(' ', pages.Select((_, i) => $"{4 + 2 * i} 0 R"))}] /Count {pages.Length} >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        };
        for (var i = 0; i < pages.Length; i++)
        {
            objects.Add($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {5 + 2 * i} 0 R /Resources << /Font << /F1 3 0 R >> >> >>");
            objects.Add(Core2Pdf.Stream(Page(pages[i])));
        }
        return Core2Pdf.Build(objects);
    }

    private static readonly byte[] Invoices = Doc(
        [
            ["The invoice total is due on Friday. Send the", "invoice to the office before the deadline."],
            ["A second paragraph mentions the Invoice once,", "and invoices should not match whole words."],
        ],
        [["Page two has an invoice too, and the office."]]);

    private static string Text(byte[] pdf, int page = 0) =>
        string.Join(" | ", ContentEditor.Read(pdf, null, page).Paragraphs.Select(p => p.Text));

    [Fact]
    public void CaseAndWholeWordsAreAsAsked()
    {
        const string text = "Invoice, invoice and invoices; reinvoice INVOICE.";
        Assert.Equal(5, TextReplace.FindIn(text, new("invoice")).Count);
        Assert.Equal([9, 21, 33], TextReplace.FindIn(text, new("invoice", MatchCase: true)).Select(h => h.Start));
        Assert.Equal([0, 9, 41], TextReplace.FindIn(text, new("invoice", WholeWord: true)).Select(h => h.Start));
        Assert.Equal([(0, 7), (9, 7), (41, 7)], TextReplace.FindIn(text, new("Invoice", WholeWord: true)));
        Assert.Equal([(5, 2)], TextReplace.FindIn("aaa a, b", new(", ", WholeWord: true))); // punctuation at its edges needs no word break
        Assert.Equal([(0, 2), (2, 2)], TextReplace.FindIn("aaaa", new("aa"))); // no overlaps
    }

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    public void NothingIsFoundForNothing(string? find)
    {
        Assert.Empty(TextReplace.FindIn("text", new(find ?? "")));
        Assert.Empty(TextReplace.Find(Invoices, null, new(find ?? "")).Matches);
    }

    [Fact]
    public void AnOverlongQueryFindsNothing() =>
        Assert.Empty(TextReplace.FindIn(new string('a', 2000), new(new string('a', TextReplace.MaxQuery + 1))));

    [Fact]
    public void MatchesComeWithTheirPageAndTheWordsAround()
    {
        var found = TextReplace.Find(Invoices, null, new("invoice", WholeWord: true));
        Assert.False(found.CutShort);
        Assert.Equal(4, found.Matches.Count);
        Assert.Equal(2, found.Pages);
        Assert.Equal([0, 0, 0, 1], found.Matches.Select(m => m.PageIndex));
        var first = found.Matches[0];
        Assert.Equal(("The ", "invoice"), (first.Before, first.Found));
        Assert.StartsWith(" total is due on Friday.", first.After);
        Assert.EndsWith("…", first.After);
        Assert.Equal("Invoice", found.Matches[2].Found);
        Assert.Null(first.Blocked);
    }

    [Fact]
    public void APhraseWrappedAcrossLinesIsFound()
    {
        var found = TextReplace.Find(Invoices, null, new("send the invoice"));
        Assert.Equal("Send the invoice", Assert.Single(found.Matches).Found);
    }

    [Fact]
    public void AListOfMatchesStopsAndSaysSo()
    {
        // Three pages of 45 lines of 45 words: 6,075 matches, more than are listed.
        var line = string.Join(" ", Enumerable.Repeat("a", 45));
        string[][] page = [[.. Enumerable.Repeat(line, 45)]];
        var found = TextReplace.Find(Doc(page, page, page), null, new("a", WholeWord: true));
        Assert.True(found.CutShort);
        Assert.Equal(TextReplace.MaxMatches, found.Matches.Count);
    }

    [Fact]
    public void ReplaceAllRewritesEveryParagraphInOnePass()
    {
        var found = TextReplace.Find(Invoices, null, new("invoice", WholeWord: true));
        var result = TextReplace.Replace(Invoices, null, found.Matches, "bill");
        Assert.Equal(4, result.Replaced);
        Assert.Empty(result.Notes);
        Assert.Equal("The bill total is due on Friday. Send the bill to the office before the deadline. | " +
                     "A second paragraph mentions the bill once, and invoices should not match whole words.", Text(result.Data));
        Assert.Equal("Page two has an bill too, and the office.", Text(result.Data, 1));
        Assert.Empty(TextReplace.Find(result.Data, null, new("invoice", WholeWord: true)).Matches);
    }

    [Fact]
    public void ReplaceChangesOnlyTheMatchesGiven()
    {
        var found = TextReplace.Find(Invoices, null, new("office"));
        var result = TextReplace.Replace(Invoices, null, [found.Matches[1]], "desk");
        Assert.Equal(1, result.Replaced);
        Assert.Contains("invoice to the office before", Text(result.Data));
        Assert.Equal("Page two has an invoice too, and the desk.", Text(result.Data, 1));
    }

    [Fact]
    public void NothingReplacedGivesTheSameBytesBack()
    {
        var result = TextReplace.Replace(Invoices, null, [], "x");
        Assert.Same(Invoices, result.Data);
    }

    [Fact]
    public void ReplacingWithTheSameTextChangesAndCountsNothing()
    {
        var found = TextReplace.Find(Invoices, null, new("Invoice"));
        var result = TextReplace.Replace(Invoices, null, found.Matches.Where(m => m.Found == "Invoice").ToList(), "Invoice");
        Assert.Equal(0, result.Replaced);
        Assert.Empty(result.Notes);
        Assert.Same(Invoices, result.Data);
    }

    [Fact]
    public void AfterReplaceTheNextMatchIsPastTheInsertedText()
    {
        // "cat" → "cats": found again, the replaced match still holds "cat"; the next is the one after it.
        var pdf = Doc([["A cat sat by the cat door, and a third cat slept."]], [["One more cat."]]);
        var before = TextReplace.Find(pdf, null, new("cat")).Matches;
        var replaced = before[0];
        var after = TextReplace.Find(TextReplace.Replace(pdf, null, [replaced], "cats").Data, null, new("cat")).Matches;
        Assert.Equal(before.Count, after.Count);
        var next = TextReplace.NextAfter(after, replaced, "cats".Length);
        Assert.Equal(1, next);
        Assert.StartsWith(" door", after[next].After);
        // The last one replaced: nothing after it, and no going round to the start.
        Assert.Equal(-1, TextReplace.NextAfter(after, after[^1] with { Length = 3 }, "cats".Length));
    }

    [Fact]
    public void AMatchKeepsItsKeyAcrossAReplaceBeforeIt()
    {
        var replaced = new ReplaceMatch(1, 2, 10, 3, "cat", "", "");
        Assert.Equal(new ReplaceKey(1, 2, 21), new ReplaceKey(1, 2, 20).After(replaced, inserted: 4)); // later in its paragraph: moves
        Assert.Equal(new ReplaceKey(1, 2, 4), new ReplaceKey(1, 2, 4).After(replaced, 4)); // before it: stays
        Assert.Equal(new ReplaceKey(1, 3, 20), new ReplaceKey(1, 3, 20).After(replaced, 4)); // another paragraph: stays
        Assert.Equal(new ReplaceKey(2, 2, 20), new ReplaceKey(2, 2, 20).After(replaced, 4));
        Assert.Null(new ReplaceKey(1, 2, 10).After(replaced, 4)); // the one replaced
    }

    [Fact]
    public void MatchesOfAnOlderVersionAreListedAsChanged()
    {
        var found = TextReplace.Find(Invoices, null, new("office"));
        var edited = TextReplace.Replace(Invoices, null, [found.Matches[1]], "desk").Data;
        var result = TextReplace.Replace(edited, null, found.Matches, "room");
        Assert.Equal(1, result.Replaced); // page 1's paragraph still reads as found
        var note = Assert.Single(result.Notes);
        Assert.Equal((ReplaceNoteKind.Changed, 1), (note.Kind, note.Match.PageIndex));
        Assert.Equal(1, result.Left);
    }

    [Fact]
    public void ALongerParagraphThatWouldRunIntoWhatFollowsIsLeftAndListed()
    {
        var pdf = Doc([["A short paragraph here, wrapped in a box", "of two lines."], ["Next block starts right below."]]);
        // The paragraphs are 60 points apart: a replacement ten lines long would reach the next one.
        var found = TextReplace.Find(pdf, null, new("here"));
        var result = TextReplace.Replace(pdf, null, found.Matches, string.Join(" ", Enumerable.Repeat("many more words in this long replacement", 12)));
        Assert.True(0 == result.Replaced, Text(result.Data));
        Assert.Equal(ReplaceNoteKind.WouldOverlap, Assert.Single(result.Notes).Kind);
        Assert.Same(pdf, result.Data);
    }

    [Fact]
    public void TextOnOneLineDoesntWrapAndSaysHowMuchWiderItIs()
    {
        var pdf = Doc([["A heading"], ["Next block starts right below."]]);
        var result = TextReplace.Replace(pdf, null, TextReplace.Find(pdf, null, new("heading")).Matches, "much longer heading");
        Assert.Equal(1, result.Replaced);
        var note = Assert.Single(result.Notes);
        Assert.Equal(ReplaceNoteKind.Wider, note.Kind);
        Assert.True(note.Made);
        Assert.InRange(note.Wider, 50, 120);
        Assert.Equal("A much longer heading | Next block starts right below.", Text(result.Data));
    }

    [Fact]
    public void CharactersTheFontLacksAreDrawnFromAnInstalledFontAndListed()
    {
        var pdf = ContentEditPdf.Make("BT /FA 12 Tf 15 TL 72 700 Td (Write to the office today and keep a copy for later.) Tj ET", fontText: Chars);
        var found = TextReplace.Find(pdf, null, new("office"));
        var result = TextReplace.Replace(pdf, null, found.Matches, "office @ home #2");
        Assert.Equal(1, result.Replaced);
        var note = Assert.Single(result.Notes, n => n.Kind != ReplaceNoteKind.Wider); // one line: it is wider too
        Assert.Equal(ReplaceNoteKind.StandIn, note.Kind);
        Assert.True(note.Made);
        Assert.Equal(["@", "#"], note.Chars);
        Assert.NotEmpty(note.Fonts);
        Assert.Contains("office @ home #2 today", Text(result.Data));
    }

    [Fact]
    public void CharactersNoFontHasAreListedAndTheTextStays()
    {
        var pdf = ContentEditPdf.Make("BT /FA 12 Tf 15 TL 72 700 Td (Write to the office today.) Tj ET", fontText: Chars);
        var found = TextReplace.Find(pdf, null, new("office"));
        var result = TextReplace.Replace(pdf, null, found.Matches, "office \U0010FFFD");
        Assert.Equal(0, result.Replaced);
        var note = Assert.Single(result.Notes);
        Assert.Equal(ReplaceNoteKind.Missing, note.Kind);
        Assert.False(note.Made);
        Assert.Equal(["\U0010FFFD"], note.Chars);
        Assert.Same(pdf, result.Data);
    }

    [Fact]
    public void ASignedFileGetsTheReplacementsAppendedOnce()
    {
        const string placeholder = "[0 0000000000 0000000000 0000000000]";
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [4 0 R] /SigFlags 3 >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] /Contents 6 0 R /Resources << /Font << /F1 7 0 R >> >> >>",
            "<< /Type /Annot /Subtype /Widget /FT /Sig /T (Approval) /Rect [72 750 272 780] /V 5 0 R /P 3 0 R /F 4 >>",
            $"<< /Type /Sig /Filter /Adobe.PPKLite /SubFilter /adbe.pkcs7.detached /ByteRange {placeholder} /Contents <{new string('0', IncrSignatureTests.ContentsHexLength)}> >>",
            Core2Pdf.Stream(Page(["This agreement is made between the two parties named", "below, who agree to the terms."], ["The two parties sign below."])),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        };
        var pdf = IncrSignatureTests.Sign(Core2Pdf.Build(objects), placeholder);
        var found = TextReplace.Find(pdf, null, new("two parties"));
        Assert.Equal(2, found.Matches.Count);
        var (edited, report) = SignedEdits.Run(() => TextReplace.Replace(pdf, null, found.Matches, "three parties").Data);
        Assert.True(report.Appended);
        Assert.Equal(pdf, edited.AsSpan(0, pdf.Length).ToArray());
        Assert.Equal(1, CountOf(edited, "%%EOF") - CountOf(pdf, "%%EOF")); // one update for both paragraphs
        Assert.Equal(2, TextReplace.Find(edited, null, new("three parties")).Matches.Count);
    }

    private static int CountOf(byte[] data, string s)
    {
        var text = System.Text.Encoding.Latin1.GetString(data);
        var n = 0;
        for (var i = text.IndexOf(s, StringComparison.Ordinal); i >= 0; i = text.IndexOf(s, i + 1, StringComparison.Ordinal)) n++;
        return n;
    }

    [Fact]
    public async Task ReplaceAllIsOneUndoStep()
    {
        using var session = DocumentSession.FromBytes(Invoices, "t.pdf");
        var found = TextReplace.Find(session.Data, null, new("invoice"));
        var result = await session.EditAsync(new EditRequest("Replace All", (d, pw) => TextReplace.Replace(d, pw, found.Matches, "bill").Data), new NoPrompts());
        Assert.Equal(EditOutcome.Done, result.Outcome);
        Assert.Empty(TextReplace.Find(session.Data, null, new("invoice")).Matches);
        session.Undo();
        Assert.Null(session.UndoStepId);
        Assert.Equal(found.Matches.Count, TextReplace.Find(session.Data, null, new("invoice")).Matches.Count);
    }

    /// <summary>
    /// The pdf.js half (opt-in with INKVOLTPDF_PDFJS, as <c>ParagraphEditTests.EditedParagraphsReadTheSameInPdfJs</c>): after
    /// Replace All, pdf.js reads each rewritten paragraph's words in order, the replacements and a stand-in character included.
    /// </summary>
    [Fact]
    public void ReplacedTextReadsTheSameInPdfJs()
    {
        var (node, skipped) = PdfJs.Ready();
        if (node is null)
        {
            if (skipped is not null) output.WriteLine(skipped);
            return;
        }
        var failures = new List<string>();
        var standIn = ContentEditPdf.Make("BT /FA 12 Tf 15 TL 72 700 Td (Write to the office today and keep a copy) Tj T* (of the office letter for later.) Tj ET", fontText: Chars);
        foreach (var (name, pdf, find, with) in new[] { ("Helvetica", Invoices, "invoice", "purchase bill"), ("stand-ins", standIn, "office", "office @ home #2") })
        {
            var result = TextReplace.Replace(pdf, null, TextReplace.Find(pdf, null, new(find, WholeWord: true)).Matches, with);
            for (var page = 0; page < (name == "Helvetica" ? 2 : 1); page++)
                foreach (var p in ContentEditor.Read(result.Data, null, page).Paragraphs)
                {
                    var got = Words(PdfJs.Text(node, result.Data, page));
                    var miss = PdfJs.FirstMiss(Words(p.Text), got);
                    output.WriteLine($"{name} p{page + 1}: '{p.Text}' {(miss is null ? "read in order" : "DIFFERS: " + miss)}");
                    if (miss is not null) failures.Add($"{name} p{page + 1}: {miss}");
                }
        }
        Assert.Empty(failures);
    }

    private static string Words(string s) => System.Text.RegularExpressions.Regex.Replace(s.Normalize(System.Text.NormalizationForm.FormKC), @"\s+", " ").Trim();

    private sealed class NoPrompts : IEditPrompts
    {
        public bool ConfirmSignedEdit() => true;
        public OpenPasswordAnswer? AskOpenPassword(byte[] data) => null;
        public string? AskOwnerPassword(bool wrong) => null;
        public bool ConfirmSignatureRewrite(string label, int signatures, string reason) => false;
        public bool ConfirmBreakingEdit(string label, IReadOnlyList<SignatureInfo> broken) => false;
    }
}
