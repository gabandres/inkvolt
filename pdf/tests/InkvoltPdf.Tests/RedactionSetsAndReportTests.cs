using System.Text;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>Saved pattern sets (a tampered file is refused, never half used), masked values, the CSV report, the Pro split.</summary>
[Collection("Pro")]
public sealed class RedactionSetsAndReportTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-redact-sets-").FullName;

    public void Dispose()
    {
        Pro.Enforced = false;
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    private static RedactionPatternOptions Sample => new()
    {
        Patterns = new HashSet<RedactionPattern> { RedactionPattern.Email, RedactionPattern.ZipCode },
        Phrases = ["Acme Corp", "Zoë Núñez"],
        WholeWord = false,
        MatchCase = true,
        Expression = @"CASE-\d{4}",
    };

    // ───────────── saved sets ─────────────

    [Fact]
    public void ASetRoundTripsOnThePc()
    {
        var path = RedactionPatternSets.Save(new RedactionPatternSet("Legal team", Sample), _root);
        Assert.Equal("Legal team.json", Path.GetFileName(path));
        var back = RedactionPatternSets.Load(path);
        Assert.Equal("Legal team", back.Name);
        Assert.Equal("Legal team", back.Options.SetName);
        Assert.True(back.Options.Patterns.SetEquals(Sample.Patterns));
        Assert.Equal(Sample.Phrases, back.Options.Phrases);
        Assert.False(back.Options.WholeWord);
        Assert.True(back.Options.MatchCase);
        Assert.Equal(Sample.Expression, back.Options.Expression);

        var (sets, problems) = RedactionPatternSets.List(_root);
        Assert.Equal("Legal team", Assert.Single(sets).Name);
        Assert.Empty(problems);
        Assert.DoesNotContain(Directory.GetFiles(_root), f => f.EndsWith(".tmp", StringComparison.Ordinal));

        RedactionPatternSets.Delete("Legal team", _root);
        Assert.Empty(RedactionPatternSets.List(_root).Sets);
    }

    [Theory]
    [InlineData(@"..\..\evil")]
    [InlineData("a/b:c*d?")]
    [InlineData("CON")]
    [InlineData("nul")]
    [InlineData("LPT1")]
    [InlineData("COM¹")]
    [InlineData("lpt³")]
    [InlineData("CONIN$")]
    [InlineData("com0")]
    [InlineData("...")]
    public void ASetsNameNeverEscapesItsFolderOrNamesADevice(string name)
    {
        var file = RedactionPatternSets.FileName(name);
        Assert.Equal(file, Path.GetFileName(file));
        Assert.DoesNotContain("..", file[..^5]);
        Assert.False(InkvoltPrint.Core.DeviceNames.IsReserved(file));
        var stem = Path.GetFileNameWithoutExtension(file);
        Assert.False(stem.ToUpperInvariant() is "CON" or "NUL" or "LPT1" or "...");
        var path = RedactionPatternSets.Save(new RedactionPatternSet(name, Sample), _root);
        Assert.Equal(Path.GetFullPath(_root), Path.GetDirectoryName(Path.GetFullPath(path)));
    }

    [Fact]
    public void TwoNamesDontLandOnOneFile() =>
        Assert.NotEqual(RedactionPatternSets.FileName("a/b"), RedactionPatternSets.FileName("a:b"));

    public static TheoryData<string, string> Tampered => new()
    {
        { "not json at all {", "isn't valid JSON" },
        { "[1, 2, 3]", "isn't a set" },
        { "{}", "\"format\" is missing" },
        { """{"format":"something else","version":1,"name":"x"}""", "isn't a set of redaction patterns" },
        { """{"format":"Inkvolt PDF redaction patterns","version":99,"name":"x"}""", "newer version" },
        { """{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":["email","launchMissiles"]}""", "doesn't know" },
        { """{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":"email"}""", "should be a list" },
        { """{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","phrases":[1]}""", "should list text" },
        { """{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":["email"],"wholeWord":"yes"}""", "true or false" },
        { """{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":["email"],"expression":"("}""", "mistake" },
        { """{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","kinds":["email"],"expression":"x*"}""", "empty text" },
        { """{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x"}""", "nothing to look for" },
        { """{"format":"Inkvolt PDF redaction patterns","version":1,"name":"  ","kinds":["email"]}""", "no name" },
    };

    [Theory]
    [MemberData(nameof(Tampered))]
    public void ATamperedSetIsRefusedWhole(string json, string why)
    {
        var path = Path.Combine(_root, "tampered.json");
        File.WriteAllText(path, json);
        var ex = Assert.Throws<RedactionPatternSetException>(() => RedactionPatternSets.Load(path));
        Assert.Contains(why, ex.Message);
        var (sets, problems) = RedactionPatternSets.List(_root);
        Assert.Empty(sets);
        Assert.Contains(why, Assert.Single(problems));
    }

    [Fact]
    public void AnOversizedOrOverDeepOrOverLongSetIsRefused()
    {
        var big = Path.Combine(_root, "big.json");
        File.WriteAllBytes(big, new byte[RedactionPatternSets.MaxBytes + 1]);
        Assert.Contains("too large", Assert.Throws<RedactionPatternSetException>(() => RedactionPatternSets.Load(big)).Message);
        File.Delete(big);

        var deep = new string('[', 5000) + new string(']', 5000);
        Assert.Throws<RedactionPatternSetException>(() => RedactionPatternSets.Read(deep, "deep.json"));

        string Set(string extra) => $$"""{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x",{{extra}}}""";
        Assert.Contains("too long", Assert.Throws<RedactionPatternSetException>(() =>
            RedactionPatternSets.Read(Set($"\"expression\":\"{new string('a', RedactionPatterns.MaxExpressionLength + 1)}\""), "x.json")).Message);
        Assert.Contains("too long", Assert.Throws<RedactionPatternSetException>(() =>
            RedactionPatternSets.Read(Set($"\"phrases\":[\"{new string('a', RedactionPatterns.MaxPhraseLength + 1)}\"]"), "x.json")).Message);
        var many = string.Join(',', Enumerable.Repeat("\"a\"", RedactionPatterns.MaxPhrases + 1));
        Assert.Contains("too many", Assert.Throws<RedactionPatternSetException>(() => RedactionPatternSets.Read(Set($"\"phrases\":[{many}]"), "x.json")).Message);
    }

    [Fact]
    public void ACatastrophicPatternInASavedSetCanLoadButEndsInAnErrorWhenRun()
    {
        var set = RedactionPatternSets.Read("""{"format":"Inkvolt PDF redaction patterns","version":1,"name":"x","expression":"(x+x+)+y"}""", "x.json");
        var text = new PageText([[.. new string('x', 40).Select(c => (c.ToString(), new RectD(0, 0, 1, 1)))]]);
        Assert.Throws<TimeoutException>(() => RedactionPatterns.Find(text, 0, set.Options with { Patterns = new HashSet<RedactionPattern>() }));
    }

    [Fact]
    public void AControlCharacterInASetsNameIsntShown()
    {
        var set = RedactionPatternSets.Read("""{"format":"Inkvolt PDF redaction patterns","version":1,"name":"Le‮gal\u0007","kinds":["email"]}""", "x.json");
        Assert.Equal("Legal", set.Name);
    }

    [Fact]
    public void AnUnsavedSetWithAProblemIsntWritten()
    {
        Assert.Throws<RedactionPatternSetException>(() => RedactionPatternSets.Save(new RedactionPatternSet("x", new RedactionPatternOptions { Expression = "(" }), _root));
        Assert.Throws<RedactionPatternSetException>(() => RedactionPatternSets.Save(new RedactionPatternSet("  ", Sample), _root));
        Assert.Throws<RedactionPatternSetException>(() => RedactionPatternSets.Save(new RedactionPatternSet("x", new RedactionPatternOptions { Patterns = new HashSet<RedactionPattern>() }), _root));
        Assert.Empty(Directory.GetFiles(_root));
    }

    // ───────────── masks ─────────────

    [Theory]
    [InlineData(RedactionPattern.SocialSecurity, "123-45-6789", "***-**-**89")]
    [InlineData(RedactionPattern.SocialSecurity, "123456789", "***-**-**89")]
    [InlineData(RedactionPattern.PaymentCard, "4111 1111 1111 1111", "**** **** **** **11")]
    [InlineData(RedactionPattern.PaymentCard, "3782 822463 10005", "**** **** **** **05")]
    [InlineData(RedactionPattern.Phone, "(555) 201-3434", "***-***-**34")]
    [InlineData(RedactionPattern.Phone, "+49 30 1234", "***")] // too short to keep anything
    [InlineData(RedactionPattern.Iban, "DE89 3704 0044 0532 0130 00", "**** **** **00")]
    [InlineData(RedactionPattern.Email, "jane.doe@example.com", "***@***")]
    [InlineData(RedactionPattern.Date, "October 27, 2026", "**/**/****")]
    [InlineData(RedactionPattern.ZipCode, "90210", "***")]
    [InlineData(RedactionPattern.IpAddress, "192.168.1.10", "***.***")]
    [InlineData(RedactionPattern.Phrase, "Bob", "***")]
    [InlineData(RedactionPattern.Phrase, "Quillfeather Holdings 123456789", "***")]
    [InlineData(RedactionPattern.Expression, "CASE-0412", "***")]
    public void AMaskGivesLittleAway(RedactionPattern kind, string value, string mask) => Assert.Equal(mask, RedactionReport.Mask(kind, value));

    [Fact]
    public void AMaskDoesntKeepTheLengthOfAFreeFormValue() =>
        Assert.Equal(RedactionReport.Mask(RedactionPattern.Phrase, "Al"), RedactionReport.Mask(RedactionPattern.Phrase, "Maximiliano Fernandez de la Cruz"));

    // ───────────── the CSV ─────────────

    private static RedactionFileReport File1(string name, RedactionPattern kind = RedactionPattern.SocialSecurity, string value = "123-45-6789") =>
        new(name, [new RedactionRemoval(2, kind, RedactionReport.Mask(kind, value), RedactionOutcome.Removed)], [new RedactionLook(4, RedactionLookReason.ScanReadByOcr, [])], null);

    [Theory]
    [InlineData("=cmd|' /C calc'!A0.pdf")]
    [InlineData("+1+1.pdf")]
    [InlineData("-2+3.pdf")]
    [InlineData("@SUM(A1).pdf")]
    [InlineData(" =spaced.pdf")]
    [InlineData("\t=tabbed.pdf")]
    [InlineData("\r\n=newline.pdf")]
    [InlineData("＝wide.pdf")]
    [InlineData("|pipe.pdf")]
    public void ACellCantRunAsAFormula(string fileName)
    {
        var csv = Encoding.UTF8.GetString(new RedactionReport([File1(fileName)]).ToCsv());
        foreach (var row in Csv.Read(csv).Skip(1))
            foreach (var cell in row)
            {
                var t = cell.TrimStart();
                Assert.False(t.Length > 0 && t[0] is '=' or '+' or '-' or '@' or '|' or '＝' or '\t', $"Cell starts a formula: {cell}");
                Assert.DoesNotContain('\n', cell);
            }
    }

    [Fact]
    public void TheSharedCsvGuardsADashToo()
    {
        Assert.Equal("\"\t-2+3\"", Csv.Quote("-2+3"));
        Assert.Equal("-2.5", Csv.Quote("-2.5")); // a plain number stays one
        Assert.Equal("-2+3", Csv.Read(Csv.Quote("-2+3") + ",x")[0][0]);
    }

    [Fact]
    public void TheReportHasEveryPartAndNoValueOrPhraseOrPattern()
    {
        var run = new RedactionMatch(0, RedactionPattern.Phrase, 0, 9, "Secret Co", [new RectD(0, 0, 1, 1)]) { Normalized = "Secret Co" };
        var regex = new RedactionMatch(0, RedactionPattern.Expression, 0, 9, "CASE-0412", [new RectD(0, 0, 1, 1)]) { Normalized = "CASE-0412" };
        var report = new RedactionReport(
        [
            new RedactionFileReport("a.pdf", [RedactionReport.Row(run, RedactionOutcome.Removed), RedactionReport.Row(regex, RedactionOutcome.Kept)], [new RedactionLook(4, RedactionLookReason.ScanReadByOcr, [new RectD(1, 1, 2, 2)])], null),
            new RedactionFileReport("b.pdf", [], [], "Read back after redacting: 1 match is still there"),
        ]);
        var csv = Encoding.UTF8.GetString(report.ToCsv());
        Assert.DoesNotContain("Secret", csv);
        Assert.DoesNotContain("CASE-", csv);
        Assert.DoesNotContain(@"\d", csv);
        var rows = Csv.Read(csv);
        Assert.Contains(rows, r => r.SequenceEqual(new[] { "a.pdf", "1", "Your words and phrases", "***", "Removed" }));
        Assert.Contains(rows, r => r.SequenceEqual(new[] { "a.pdf", "1", "Your pattern", "***", "Kept by you" }));
        Assert.Contains(rows, r => r[0] == "a.pdf" && r[1] == "5" && r[4] == "Look by hand" && r[2].Contains("1 place has ink"));
        Assert.Contains(rows, r => r[0] == "b.pdf" && r[4].StartsWith("Failed: Read back", StringComparison.Ordinal));
        Assert.True(report.HasFailures);
        Assert.True(report.HasLooks);
    }

    [Fact]
    public void ALookNeverCallsAPageClean()
    {
        foreach (var reason in Enum.GetValues<RedactionLookReason>())
        {
            var text = new RedactionLook(0, reason, []).Text;
            Assert.DoesNotContain("clean", text, StringComparison.OrdinalIgnoreCase);
            Assert.DoesNotContain("nothing found", text, StringComparison.OrdinalIgnoreCase);
        }
    }

    // ───────────── Free and Pro ─────────────

    [Fact]
    public void BatchRedactionIsProAndPlainPatternSearchIsnt()
    {
        var plan = new BatchPlan { Steps = [new RedactPatternsStep(new RedactionPatternOptions())], OutputFolder = _root };
        Pro.Store = new InkvoltPrint.Core.Suite.MemoryProStore();
        Assert.Null(plan.Validate(false)); // the gate is off

        Pro.Enforced = true;
        Assert.False(Pro.Allows(ProFeature.PatternRedaction));
        Assert.Equal(Pro.Locked(ProFeature.PatternRedaction), plan.Validate(false));
        // The built-in kinds on one document stay free: nothing in Core locks them.
        Assert.Single(RedactionPatterns.Find(new PageText([[.. "123-45-6789".Select(c => (c.ToString(), new RectD(0, 0, 1, 1)))]]), 0, new RedactionPatternOptions()));
    }
}
