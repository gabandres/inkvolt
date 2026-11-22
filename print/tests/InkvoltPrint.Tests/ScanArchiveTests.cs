using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using InkvoltPrint.Core.Pdf;
using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.Tests;

/// <summary>
/// Roadmap 4.18: a scan preset's PDF/A-2b and its password (AES-256, revision 6), written by <see cref="PdfWriter"/>. Inkvolt PDF's
/// tests read the same files with its PDF/A check, PDFsharp and MuPDF (PrintScanArchiveTests); these check the file's parts.
/// </summary>
public class ScanArchiveTests
{
    private static readonly byte[] Jpeg = TestJpeg.Build(width: 850, height: 1100, dnlHeight: null);

    private static string Write(PdfWriteOptions? options, string title = "Scan", byte[]? jpeg = null)
    {
        using var ms = new MemoryStream();
        PdfWriter.Write(ms, [new PdfPage(jpeg ?? Jpeg, 100, [new OcrWord("Hello", 10, 10, 50, 12)])], title, options);
        return Encoding.Latin1.GetString(ms.ToArray());
    }

    [Fact]
    public void APlainScanIsWrittenAsBefore()
    {
        var pdf = Write(null);
        Assert.StartsWith("%PDF-1.4\n", pdf);
        Assert.DoesNotContain("/ID", pdf);
        Assert.DoesNotContain("/Encrypt", pdf);
        Assert.DoesNotContain("/Metadata", pdf);
    }

    [Fact]
    public void APdfAScanHasItsIntentMetadataAndId()
    {
        var created = new DateTime(2026, 11, 22, 14, 30, 5, DateTimeKind.Utc);
        var pdf = Write(new PdfWriteOptions { PdfA = true, Now = created }, "Q3 <report> & \"notes\"");
        Assert.Contains("/OutputIntents [<< /Type /OutputIntent /S /GTS_PDFA1", pdf);
        Assert.Matches(@"/ID \[<[0-9A-F]{32}> <[0-9A-F]{32}>\]", pdf);
        Assert.Contains("/CreationDate (D:20261122143005Z)", pdf);
        var xmp = Regex.Match(pdf, @"<\?xpacket begin.*?<\?xpacket end=""w""\?>", RegexOptions.Singleline).Value;
        Assert.Contains("<pdfaid:part>2</pdfaid:part>", xmp);
        Assert.Contains("<pdfaid:conformance>B</pdfaid:conformance>", xmp);
        Assert.Contains("<xmp:CreateDate>2026-11-22T14:30:05Z</xmp:CreateDate>", xmp);
        Assert.Contains("<pdf:Producer>Inkvolt Print</pdf:Producer>", xmp);
        Assert.Contains("Q3 &lt;report&gt; &amp; \"notes\"", xmp); // escaped, the same title as the Info dictionary's
        Assert.DoesNotContain("/Encrypt", pdf);
    }

    [Fact]
    public void DatesAreGregorianWhateverTheRegionalCalendar()
    {
        var before = System.Globalization.CultureInfo.CurrentCulture;
        try
        {
            System.Globalization.CultureInfo.CurrentCulture = new System.Globalization.CultureInfo("th-TH"); // the Thai Buddhist calendar: 2569
            var created = new DateTime(2026, 11, 22, 14, 30, 5, DateTimeKind.Utc);
            var pdf = Write(new PdfWriteOptions { PdfA = true, Now = created });
            Assert.Contains("/CreationDate (D:20261122143005Z)", pdf);
            Assert.Contains("<xmp:CreateDate>2026-11-22T14:30:05Z</xmp:CreateDate>", pdf);
            Assert.DoesNotContain("2569", pdf);
        }
        finally
        {
            System.Globalization.CultureInfo.CurrentCulture = before;
        }
    }

    [Fact]
    public void ThePdfAProfileIsSrgbNamedForInkvoltPrint()
    {
        var p = IccProfiles.SrgbForPrint();
        Assert.Equal("acsp", Encoding.ASCII.GetString(p, 36, 4));
        Assert.Equal("RGB ", Encoding.ASCII.GetString(p, 16, 4));
        Assert.Contains("Inkvolt Print", Encoding.ASCII.GetString(p));
        Assert.Contains("Inkvolt PDF", Encoding.ASCII.GetString(IccProfiles.Srgb())); // Inkvolt PDF's own, unchanged
    }

    [Fact]
    public void PdfAAndAPasswordNeverGoTogether() =>
        Assert.Throws<ArgumentException>(() => Write(new PdfWriteOptions { PdfA = true, Password = "x" }));

    [Fact]
    public void ACmykPictureIsRefusedForPdfA() =>
        Assert.Throws<ArgumentException>(() => Write(new PdfWriteOptions { PdfA = true }, jpeg: TestJpeg.Build(100, 100, null, components: 4)));

    [Fact]
    public void AProtectedScanHidesItsTextAndTitle()
    {
        var pdf = Write(new PdfWriteOptions { Password = "secret" }, "Payroll March");
        Assert.StartsWith("%PDF-1.7\n", pdf);
        Assert.Contains("/Filter /Standard /V 5 /R 6 /Length 256", pdf);
        Assert.Contains("/CFM /AESV3", pdf);
        Assert.Contains("/Extensions << /ADBE << /BaseVersion /1.7 /ExtensionLevel 8 >> >>", pdf);
        Assert.DoesNotContain("Payroll", pdf);
        Assert.DoesNotContain("Inkvolt Print", pdf); // the producer string is encrypted too
        Assert.DoesNotContain("/Im0 Do", pdf); // content streams are encrypted
        Assert.DoesNotContain("(Adobe)", pdf); // and the font's strings
        Assert.Matches(@"/ID \[<[0-9A-F]{32}>", pdf);
    }

    [Fact]
    public void TheUserKeyChecksThePasswordAndUnwrapsTheFileKeyThatDecryptsTheTitle()
    {
        var pdf = Write(new PdfWriteOptions { Password = "Contraseña" }, "Payroll March");
        var u = Hex(pdf, "U");
        var ue = Hex(pdf, "UE");
        var pw = PdfEncryption.PasswordBytes("Contraseña");
        // Algorithm 2.A: the password's hash with the validation salt is the first 32 bytes of /U.
        Assert.Equal(u[..32], PdfEncryption.Hash(pw, u.AsSpan(32, 8), []));
        Assert.NotEqual(u[..32], PdfEncryption.Hash(PdfEncryption.PasswordBytes("wrong"), u.AsSpan(32, 8), []));
        using var aes = Aes.Create();
        aes.Key = PdfEncryption.Hash(pw, u.AsSpan(40, 8), []);
        var fileKey = aes.DecryptCbc(ue, new byte[16], PaddingMode.None);
        // /Perms decrypts with the file key to the permissions and "adb".
        aes.Key = fileKey;
        var perms = aes.DecryptEcb(Hex(pdf, "Perms"), PaddingMode.None);
        Assert.Equal("Tadb", Encoding.ASCII.GetString(perms, 8, 4));
        Assert.Equal(-4, BitConverter.ToInt32(perms, 0));
        // The Info dictionary's title: IV, then AES-256-CBC.
        var info = Regex.Match(pdf, @"3 0 obj\n<< /Producer <([0-9A-F]+)> /Title <([0-9A-F]+)>").Groups;
        var title = Convert.FromHexString(info[2].Value);
        var plain = aes.DecryptCbc(title.AsSpan(16), title.AsSpan(0, 16), PaddingMode.PKCS7);
        Assert.Equal("Payroll March", Encoding.BigEndianUnicode.GetString(plain, 2, plain.Length - 2));
    }

    [Fact]
    public void TheOwnerKeyIsBuiltOnTheUserKey()
    {
        var pdf = Write(new PdfWriteOptions { Password = "pw" });
        var (u, o) = (Hex(pdf, "U"), Hex(pdf, "O"));
        Assert.Equal(48, o.Length);
        Assert.Equal(o[..32], PdfEncryption.Hash(PdfEncryption.PasswordBytes("pw"), o.AsSpan(32, 8), u));
    }

    [Fact]
    public void EachFileGetsItsOwnKey() =>
        Assert.NotEqual(Hex(Write(new PdfWriteOptions { Password = "pw" }), "UE"), Hex(Write(new PdfWriteOptions { Password = "pw" }), "UE"));

    [Fact]
    public void StringsInsideABodyAreEncryptedWhereverTheyAre()
    {
        var crypt = PdfEncryption.Create("pw");
        var body = crypt.EncryptStrings(@"<< /A (a \(nested (b)\) c\051) /B <48 49> /C [(x) /N 3] >>");
        Assert.Matches(@"^<< /A <[0-9A-F]{96}> /B <[0-9A-F]{64}> /C \[<[0-9A-F]{64}> /N 3\] >>$", body);
    }

    [Fact]
    public void APasswordIsNormalizedAndCutAtACharacter()
    {
        Assert.Equal(PdfEncryption.PasswordBytes("ﬁle"), PdfEncryption.PasswordBytes("file")); // NFKC: the ligature is two letters
        var cut = PdfEncryption.PasswordBytes(new string('é', 100)); // 200 bytes of UTF-8
        Assert.Equal(126, cut.Length);
        Assert.Equal(new string('é', 63), Encoding.UTF8.GetString(cut));
        Assert.False(PdfEncryption.Usable(""));
        Assert.False(PdfEncryption.Usable(null));
    }

    [Fact]
    public void ANewPasswordIsTypedTwice()
    {
        Assert.Equal(NewPasswordProblem.Empty, PdfEncryption.CheckNew("", ""));
        Assert.Equal(NewPasswordProblem.Mismatch, PdfEncryption.CheckNew("abc", "abd"));
        Assert.Null(PdfEncryption.CheckNew("abc", "abc"));
    }

    // ---- The preset's options ----

    [Fact]
    public void PdfAAndAPasswordExcludeEachOtherInTheEditor()
    {
        var p = new ScanPreset { FileType = PresetFileType.SearchablePdf };
        var archived = ScanPresets.WithPdfA(p, true);
        Assert.True(ScanPresets.SavesPdfA(archived));
        var locked = ScanPresets.WithPassword(archived, true);
        Assert.False(locked.PdfA);
        Assert.True(ScanPresets.SavesWithPassword(locked));
        Assert.False(ScanPresets.WithPdfA(locked, true).Password);
        // Both on (a hand-edited file): the password wins, and PDF/A isn't claimed.
        Assert.False(ScanPresets.SavesPdfA(p with { PdfA = true, Password = true }));
    }

    [Fact]
    public void OnlyAPdfGetsPdfAOrAPassword()
    {
        foreach (var type in new[] { PresetFileType.Jpeg, PresetFileType.Word, PresetFileType.Text })
        {
            Assert.False(ScanPresets.SavesPdfA(new ScanPreset { FileType = type, PdfA = true }));
            Assert.False(ScanPresets.SavesWithPassword(new ScanPreset { FileType = type, Password = true }));
        }
        Assert.True(ScanPresets.SavesPdfA(new ScanPreset { FileType = PresetFileType.Pdf, PdfA = true }));
    }

    [Fact]
    public void WriteOptionsFollowThePreset()
    {
        Assert.Null(ScanPresets.WriteOptions(new ScanPreset(), null));
        Assert.True(ScanPresets.WriteOptions(new ScanPreset { PdfA = true }, null)!.PdfA);
        Assert.Equal("pw", ScanPresets.WriteOptions(new ScanPreset { Password = true }, "pw")!.Password);
        Assert.Throws<ArgumentException>(() => ScanPresets.WriteOptions(new ScanPreset { Password = true }, "")); // never saved open
        Assert.Throws<ArgumentException>(() => ScanPresets.WriteOptions(new ScanPreset { Password = true, PdfA = true }, null));
        Assert.Null(ScanPresets.WriteOptions(new ScanPreset { Password = true, FileType = PresetFileType.Jpeg }, null)); // not a PDF: nothing to protect
    }

    [Fact]
    public void ASavedPasswordGoesWithItsPresetOrItsOption()
    {
        ScanPreset P(string id, bool pw) => new() { Id = id, Name = id, Password = pw };
        var before = new[] { P("a", true), P("b", true), P("c", true), P("d", false) };
        var after = new[] { P("a", true), P("b", false), P("d", true) }; // c deleted, b turned off
        Assert.Equal(["b", "c"], ScanPresets.PasswordsToForget(before, after));
    }

    [Fact]
    public void TheSummarySaysPdfAOrPassword()
    {
        Assert.Contains("PDF/A", ScanPresetText.Summary(new ScanPreset { Name = "x", PdfA = true }));
        Assert.Contains(Core.CoreStrings.Preset_PasswordShort, ScanPresetText.Summary(new ScanPreset { Name = "x", Password = true }));
        Assert.DoesNotContain("PDF/A", ScanPresetText.Summary(new ScanPreset { Name = "x" }));
    }

    [Fact]
    public void TheNewOptionsSurviveAStoreAndRead()
    {
        var json = System.Text.Json.JsonSerializer.Serialize(new ScanPreset { Id = "a", Name = "A", PdfA = true });
        Assert.True(System.Text.Json.JsonSerializer.Deserialize<ScanPreset>(json)!.PdfA);
        Assert.False(System.Text.Json.JsonSerializer.Deserialize<ScanPreset>("{\"Id\":\"a\",\"Name\":\"A\"}")!.Password);
    }

    private static byte[] Hex(string pdf, string key) => Convert.FromHexString(Regex.Match(pdf, $@"/{key} <([0-9A-F]+)>").Groups[1].Value);
}
