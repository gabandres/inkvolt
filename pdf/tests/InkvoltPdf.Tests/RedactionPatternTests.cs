using System.Diagnostics;
using System.Text;
using MuPDFCore;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public sealed class RedactionPatternTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-redact-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    /// <summary>A page's text layer from lines of text: each character a 6 x 12 box, lines 14 points apart.</summary>
    private static PageText Page(params string[] lines) =>
        new([.. lines.Select((line, l) => line.Select((c, i) => (c.ToString(), new RectD(10 + 6 * i, 20 + 14 * l, 6, 12))).ToList())]);

    /// <summary>What one kind finds in a line (or lines) of text.</summary>
    private static List<string> Found(RedactionPattern pattern, params string[] lines) =>
        [.. RedactionPatterns.Find(Page(lines), 0, new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern> { pattern } }).Select(m => m.Text)];

    private static void Finds(RedactionPattern pattern, string text, string expected) => Assert.Equal([expected], Found(pattern, $"Value: {text} here."));

    private static void FindsNothing(RedactionPattern pattern, string text) => Assert.Empty(Found(pattern, $"Value: {text} here."));

    // ───────────── built-in kinds ─────────────

    [Theory]
    [InlineData("123-45-6789")]
    [InlineData("123 45 6789")]
    [InlineData("123456789")]
    [InlineData("078-05-1120")]
    public void SocialSecurityNumbers(string ssn) => Finds(RedactionPattern.SocialSecurity, ssn, ssn);

    [Theory]
    [InlineData("000-12-3456")] // area 000
    [InlineData("666-12-3456")] // area 666
    [InlineData("912-34-5678")] // area 9xx
    [InlineData("123-00-4567")] // group 00
    [InlineData("123-45-0000")] // serial 0000
    [InlineData("123-45 6789")] // separators differ
    [InlineData("1234-56-7890")]
    [InlineData("123-45-67890")]
    [InlineData("12345678")]
    [InlineData("A123-45-6789")]
    public void SocialSecurityNearMisses(string text) => FindsNothing(RedactionPattern.SocialSecurity, text);

    [Theory]
    [InlineData("(555) 201-3434")]
    [InlineData("(555)201-3434")]
    [InlineData("555-201-3434")]
    [InlineData("555.201.3434")]
    [InlineData("555 201 3434")]
    [InlineData("+1 555 201 3434")]
    [InlineData("+1 (555) 201-3434")]
    [InlineData("1-800-555-0199")]
    [InlineData("+15552013434")]
    [InlineData("+44 20 7946 0958")]
    [InlineData("+44 (0)20 7946 0958")]
    [InlineData("+49 30 1234567")]
    [InlineData("+33 1 23 45 67 89")]
    public void PhoneNumbers(string phone) => Finds(RedactionPattern.Phone, phone, phone);

    [Theory]
    [InlineData("555-201-343")]
    [InlineData("155-201-3434")] // no area code starts with 1
    [InlineData("555-101-3434")] // nor an exchange
    [InlineData("5552013434")] // ten digits run together, no +1: too likely another number
    [InlineData("+44 12")] // too short
    [InlineData("+44 1234 5678 9012 3456")] // more than 15 digits
    [InlineData("4111 1111 1111 1111")]
    [InlineData("2026-10-27")]
    public void PhoneNearMisses(string text) => FindsNothing(RedactionPattern.Phone, text);

    [Theory]
    [InlineData("jane.doe+tag@mail.example.co.uk")]
    [InlineData("a@b.io")]
    [InlineData("José.Núñez@correo.es")]
    public void EmailAddresses(string email) => Finds(RedactionPattern.Email, email, email);

    [Theory]
    [InlineData("jane@")]
    [InlineData("@example.com")]
    [InlineData("jane@example")]
    [InlineData("jane..doe@example.com")]
    [InlineData(".jane@example.com")]
    public void EmailNearMisses(string text) => FindsNothing(RedactionPattern.Email, text);

    [Fact]
    public void AnEmailEndsBeforeTheSentencesFullStop() =>
        Assert.Equal(["jane@example.com"], Found(RedactionPattern.Email, "Write to jane@example.com."));

    [Theory]
    [InlineData("4111 1111 1111 1111")]
    [InlineData("4111-1111-1111-1111")]
    [InlineData("4111111111111111")]
    [InlineData("3782 822463 10005")] // American Express, 4-6-5
    [InlineData("5555 5555 5555 4444")]
    [InlineData("6011 0009 9013 9424")]
    [InlineData("4222222222222")] // 13 digits
    public void PaymentCards(string card) => Finds(RedactionPattern.PaymentCard, card, card);

    [Theory]
    [InlineData("4111 1111 1111 1112")] // Luhn fails
    [InlineData("4111 1111-1111 1111")] // separators differ
    [InlineData("1234 5678 9012 3452")] // no card network starts with 1 (though Luhn passes)
    [InlineData("4111 1111 1111")] // 12 digits
    [InlineData("41111111111111111111")] // 20 digits
    [InlineData("4 1 1 1 1 1 1 1 1 1 1 1 1 1 1 1")]
    public void PaymentCardNearMisses(string text) => FindsNothing(RedactionPattern.PaymentCard, text);

    [Fact]
    public void ACardFollowedByAnotherNumberStillCounts() =>
        Assert.Equal(["4111 1111 1111 1111"], Found(RedactionPattern.PaymentCard, "Card 4111 1111 1111 1111 2026 expires"));

    [Theory]
    [InlineData("2026-10-27")]
    [InlineData("2026/10/27")]
    [InlineData("10/27/2026")]
    [InlineData("10/27/26")]
    [InlineData("27.10.2026")]
    [InlineData("27/10/2026")]
    [InlineData("2/29/2024")] // a leap day
    [InlineData("October 27, 2026")]
    [InlineData("Oct 27 2026")]
    [InlineData("Sept. 3, 2026")]
    [InlineData("27 Oct 2026")]
    [InlineData("27th of October 2026")]
    [InlineData("1st January 2027")]
    public void Dates(string date) => Finds(RedactionPattern.Date, date, date);

    [Theory]
    [InlineData("2026-02-30")]
    [InlineData("2/29/2026")] // not a leap year
    [InlineData("13/13/2026")]
    [InlineData("31.04.2026")]
    [InlineData("27.10.26")] // two-digit years only with slashes
    [InlineData("1.2.3")]
    [InlineData("February 30, 2026")]
    [InlineData("Octopus 27, 2026")]
    [InlineData("10/27/2026/5")]
    public void DateNearMisses(string text) => FindsNothing(RedactionPattern.Date, text);

    [Fact]
    public void ZipCodesOnlyWhenChosen()
    {
        Assert.DoesNotContain(RedactionPattern.ZipCode, RedactionPatterns.Defaults);
        Assert.Empty(RedactionPatterns.Find(Page("Beverly Hills, CA 90210"), 0, new RedactionPatternOptions()));
        Assert.Equal(["90210", "90210-1234"], Found(RedactionPattern.ZipCode, "CA 90210 or 90210-1234"));
        Assert.Empty(Found(RedactionPattern.ZipCode, "00000, 902101, 9021, 90210-12"));
    }

    [Theory]
    [InlineData("DE89 3704 0044 0532 0130 00")]
    [InlineData("DE89370400440532013000")]
    [InlineData("GB82 WEST 1234 5698 7654 32")]
    [InlineData("GB82WEST12345698765432")]
    [InlineData("FR14 2004 1010 0505 0001 3M02 606")]
    public void Ibans(string iban) => Finds(RedactionPattern.Iban, iban, iban);

    [Theory]
    [InlineData("DE89 3704 0044 0532 0130 01")] // check digits wrong
    [InlineData("DE88 3704 0044 0532 0130 00")]
    [InlineData("GB82 WEST 1234")] // too short
    public void IbanNearMisses(string text) => FindsNothing(RedactionPattern.Iban, text);

    [Fact]
    public void AnIbanFollowedByACurrencyStillCounts() =>
        Assert.Equal(["DE89 3704 0044 0532 0130 00"], Found(RedactionPattern.Iban, "Pay to DE89 3704 0044 0532 0130 00 EUR"));

    [Theory]
    [InlineData("192.168.1.10")]
    [InlineData("10.0.0.1")]
    [InlineData("255.255.255.255")]
    [InlineData("2001:db8::1")]
    [InlineData("fe80::1ff:fe23:4567:890a")]
    [InlineData("2001:0db8:85a3:0000:0000:8a2e:0370:7334")]
    public void IpAddresses(string ip) => Finds(RedactionPattern.IpAddress, ip, ip);

    [Theory]
    [InlineData("256.1.1.1")]
    [InlineData("1.2.3")]
    [InlineData("192.168.1.10.5")]
    [InlineData("10:30:45")] // a time
    [InlineData("::")]
    public void IpNearMisses(string text) => FindsNothing(RedactionPattern.IpAddress, text);

    [Fact]
    public void CheckedNumbersWinOverLooserKinds()
    {
        // With every kind on, a card number is only a card number (not a phone number, ZIP code or date), and an SSN only an SSN.
        var all = new RedactionPatternOptions { Patterns = RedactionPatterns.BuiltIn.ToHashSet() };
        var matches = RedactionPatterns.Find(Page("Card 4111 1111 1111 1111, SSN 123-45-6789, call 555-201-3434 on 10/27/2026."), 0, all);
        Assert.Equal(
            [(RedactionPattern.PaymentCard, "4111 1111 1111 1111"), (RedactionPattern.SocialSecurity, "123-45-6789"), (RedactionPattern.Phone, "555-201-3434"), (RedactionPattern.Date, "10/27/2026")],
            matches.Select(m => (m.Pattern, m.Text)));
        Assert.Equal("US Social Security numbers: 1, Phone numbers: 1, Payment card numbers: 1, Dates: 1", RedactionPatterns.Summary(matches)); // in the order offered
    }

    // ───────────── line breaks ─────────────

    [Fact]
    public void MatchesRunOntoTheNextLine()
    {
        var text = Page("SSN 123-45-", "6789 and phone (555) 201", "3434, born October", "27, 2026; card 4111 1111", "1111 1111 ok");
        var matches = RedactionPatterns.Find(text, 0, new RedactionPatternOptions());
        Assert.Equal(
            [(RedactionPattern.SocialSecurity, "123-45-\n6789"), (RedactionPattern.Phone, "(555) 201\n3434"), (RedactionPattern.Date, "October\n27, 2026"),
                (RedactionPattern.PaymentCard, "4111 1111\n1111 1111")],
            matches.Select(m => (m.Pattern, m.Text)));
        Assert.All(matches, m => Assert.Equal(2, m.Rects.Count)); // one box per line
        var ssn = matches[0].Rects;
        Assert.Equal(20, ssn[0].Y, 3);
        Assert.Equal(34, ssn[1].Y, 3);
        Assert.Equal(10 + 6 * 4, ssn[0].X, 3); // starts at "123"
        Assert.Equal(10 + 6 * 4, ssn[1].Right, 3); // ends after "6789"
    }

    // ───────────── the user's phrases and pattern ─────────────

    [Fact]
    public void PhrasesMatchWholeWordsAndCaseAsAsked()
    {
        var text = Page("Acme Corp and ACME", "corporation; acmeville; Confi-", "dential");
        List<string> Phrases(bool wholeWord, bool matchCase, params string[] phrases) =>
            [.. RedactionPatterns.Find(text, 0, new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern>(), Phrases = phrases, WholeWord = wholeWord, MatchCase = matchCase })
                .Select(m => m.Text)];

        Assert.Equal(["Acme", "ACME"], Phrases(true, false, "acme"));
        Assert.Equal(["Acme", "ACME", "acme"], Phrases(false, false, "acme"));
        Assert.Equal(["Acme"], Phrases(true, true, "Acme"));
        Assert.Equal(["ACME\ncorporation"], Phrases(true, false, "acme corporation")); // across a line break
        Assert.Equal(["Confi-\ndential"], Phrases(true, false, "Confidential")); // hyphenated across a line
        Assert.Equal(["Acme"], Phrases(true, true, "Acme", "  ", "Acme")); // blanks and repeats ignored
        Assert.True(new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern>(), Phrases = [" "] }.IsEmpty);
    }

    [Fact]
    public void TheUsersExpression()
    {
        var text = Page("Files CASE-0412 and case-0001,", "not CASE-12.");
        List<RedactionMatch> Run(bool matchCase) =>
            RedactionPatterns.Find(text, 0, new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern>(), Expression = @"CASE-\d{4}", MatchCase = matchCase });
        Assert.Equal(["CASE-0412", "case-0001"], Run(false).Select(m => m.Text));
        Assert.Equal(["CASE-0412"], Run(true).Select(m => m.Text));
        Assert.All(Run(false), m => Assert.Equal(RedactionPattern.Expression, m.Pattern));

        // Line breaks read as spaces.
        var broken = RedactionPatterns.Find(Page("Account", "No. 77"), 0, new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern>(), Expression = @"Account No\. \d+" });
        Assert.Equal(["Account\nNo. 77"], broken.Select(m => m.Text));
    }

    [Fact]
    public void ABadExpressionIsReportedInPlainWords()
    {
        Assert.Null(RedactionPatterns.ValidateExpression(null));
        Assert.Null(RedactionPatterns.ValidateExpression(@"\bCASE-\d+"));
        Assert.Contains("near character", RedactionPatterns.ValidateExpression("CASE-("));
        Assert.Contains("near character", RedactionPatterns.ValidateExpression("[a-"));
        Assert.Contains("empty text", RedactionPatterns.ValidateExpression("x*"));
        Assert.Throws<ArgumentException>(() => RedactionPatterns.Find(Page("text"), 0, new RedactionPatternOptions { Expression = "(" }));
    }

    [Fact]
    public void APathologicalExpressionTimesOutCleanly()
    {
        var text = Page(new string('x', 40), "and more " + new string('x', 40));
        var options = new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern>(), Expression = "(x+x+)+y" };
        var clock = Stopwatch.StartNew();
        var ex = Assert.Throws<TimeoutException>(() => RedactionPatterns.Find(text, 4, options));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(15), $"took {clock.Elapsed}");
        Assert.Contains("page 5", ex.Message);
        Assert.IsType<System.Text.RegularExpressions.RegexMatchTimeoutException>(ex.InnerException);
    }

    // ───────────── documents ─────────────

    /// <summary>A PDF with the given lines of Helvetica text on each page.</summary>
    private static byte[] Pdf(params string[][] pages)
    {
        var n = pages.Length;
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            $"<< /Type /Pages /Kids [{string.Join(' ', Enumerable.Range(3, n).Select(i => $"{i} 0 R"))}] /Count {n} >>",
        };
        var font = 3 + 2 * n;
        for (var p = 0; p < n; p++)
            objects.Add($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {3 + n + p} 0 R /Resources << /Font << /F1 {font} 0 R >> >> >>");
        foreach (var lines in pages)
        {
            var content = new StringBuilder();
            for (var l = 0; l < lines.Length; l++)
                content.Append($"BT /F1 14 Tf 72 {700 - 24 * l} Td ({lines[l].Replace(@"\", @"\\").Replace("(", @"\(").Replace(")", @"\)")}) Tj ET\n");
            objects.Add(Core2Pdf.Stream(content.ToString()));
        }
        objects.Add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
        return Core2Pdf.Build(objects);
    }

    private static string Text(byte[] pdf, int page)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return engine.GetText(page).Text;
    }

    [Fact]
    public void OnlyTheChosenPagesAreSearched()
    {
        var data = Pdf(["Mail one@example.com"], ["Mail two@example.com"], ["Mail three@example.com"]);
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var progress = new List<(int, int)>();
        var all = RedactionPatterns.Find(engine, new RedactionPatternOptions(), new SyncProgress(progress));
        Assert.Equal([(0, "one@example.com"), (1, "two@example.com"), (2, "three@example.com")], all.Select(m => (m.Page, m.Text)));
        Assert.Equal([(1, 3), (2, 3), (3, 3)], progress);

        var some = RedactionPatterns.Find(engine, new RedactionPatternOptions { Pages = [2, 1, 2, 9] });
        Assert.Equal([1, 2], some.Select(m => m.Page));

        Assert.True(PageRange.TryParse("2", engine.PageCount, out var pages, out _));
        Assert.Equal(["two@example.com"], RedactionPatterns.Find(engine, new RedactionPatternOptions { Pages = pages }).Select(m => m.Text));
    }

    [Fact]
    public void RedactingRemovesTheMatchesForGoodAndLeavesTheRest()
    {
        var data = Pdf(
            ["Public heading", "Contact jane.doe@example.com today", "SSN 123-45-", "6789 on file"],
            ["Second page stays: no numbers here"]);
        Assert.Contains("jane.doe@example.com", Text(data, 0));
        RectD heading;
        using (var engine = PdfEngine.Open(data, InputFileTypes.PDF, null))
        {
            var t = engine.GetText(0);
            var (s, e) = t.Find("Public heading", true, false).Single();
            heading = t.GetRects(s, e).Single();
        }

        var (redacted, matches) = RedactionPatterns.Redact(data, null, new RedactionPatternOptions());
        Assert.Equal([RedactionPattern.Email, RedactionPattern.SocialSecurity], matches.Select(m => m.Pattern));
        Assert.Equal(3, matches.Sum(m => m.Rects.Count)); // the SSN runs over two lines

        var after = Text(redacted, 0);
        foreach (var secret in new[] { "jane.doe", "example.com", "123-45", "6789" })
            Assert.DoesNotContain(secret, after);
        Assert.Equal("Second page stays: no numbers here", Text(redacted, 1)); // a page without matches keeps its text
        foreach (var m in matches)
            foreach (var r in m.Rects)
                Assert.True(Core2Pdf.Ink(redacted, 0, r.Inflate(-1)) > 0.95, $"{m.Pattern} blacked out");
        Assert.True(Core2Pdf.Ink(redacted, 0, heading) > 0.05, "the heading still shows");
        Assert.True(Core2Pdf.Ink(redacted, 0, heading) < 0.6, "and isn't blacked out");

        // Nothing found: the file is left as it was.
        var (same, none) = RedactionPatterns.Redact(data, null, new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern> { RedactionPattern.Iban } });
        Assert.Empty(none);
        Assert.Same(data, same);
    }

    [Fact]
    public async Task BatchRedactsPatternsInEveryFile()
    {
        var a = Path.Combine(_root, "a.pdf");
        var b = Path.Combine(_root, "b.pdf");
        File.WriteAllBytes(a, Pdf(["Card 4111 1111 1111 1111 and mail a@b.io"], ["Kept text"]));
        File.WriteAllBytes(b, Pdf(["Nothing private"]));
        var step = new RedactPatternsStep(new RedactionPatternOptions());
        var plan = new BatchPlan { Steps = [step], OutputFolder = Path.Combine(_root, "out") };
        Assert.Null(plan.Validate(ocrAvailable: false));
        Assert.True(plan.RendersPages);

        var summary = await BatchRunner.RunAsync([new BatchFile(a), new BatchFile(b)], plan, new BatchHost(), null, default);
        Assert.All(summary.Items, i => Assert.Equal(BatchItemState.Done, i.State));
        var first = File.ReadAllBytes(summary.Items[0].Outputs.Single());
        Assert.DoesNotContain("4111", Text(first, 0));
        Assert.DoesNotContain("a@b.io", Text(first, 0));
        Assert.Equal("Kept text", Text(first, 1));
        Assert.Contains("Redacted 2 matches on 1 page (Email addresses: 1, Payment card numbers: 1)", summary.Items[0].Notes);
        Assert.Contains("Redact patterns: nothing found, left as it was", summary.Items[1].Notes);
        Assert.Equal("Nothing private", Text(File.ReadAllBytes(summary.Items[1].Outputs.Single()), 0));

        Assert.NotNull((plan with { Steps = [new RedactPatternsStep(new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern>() })] }).Validate(false));
        Assert.Contains("near character", (plan with { Steps = [new RedactPatternsStep(new RedactionPatternOptions { Expression = "(" })] }).Validate(false));
    }

    /// <summary>Reports as they come (Progress&lt;T&gt; would post them later).</summary>
    private sealed class SyncProgress(List<(int, int)> list) : IProgress<(int Done, int Total)>
    {
        public void Report((int Done, int Total) value) => list.Add(value);
    }
}
