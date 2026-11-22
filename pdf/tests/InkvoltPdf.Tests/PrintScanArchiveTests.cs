using InkvoltPdf.Core;
using MuPDFCore;
using ScanPage = InkvoltPrint.Core.Pdf.PdfPage;
using ScanPdfWriter = InkvoltPrint.Core.Pdf.PdfWriter;
using ScanWord = InkvoltPrint.Core.Pdf.OcrWord;
using WriteOptions = InkvoltPrint.Core.Pdf.PdfWriteOptions;

namespace InkvoltPdf.Tests;

/// <summary>
/// Roadmap 4.18 of Inkvolt Print: a scan preset's PDF/A-2b and password-protected PDFs, written by the shared core's scan writer,
/// read by Inkvolt PDF's own PDF/A check, security reading (PDFsharp) and engine (MuPDF).
/// </summary>
public class PrintScanArchiveTests
{
    private const string Password = "Secret 2026";

    /// <summary>A password beyond ASCII: PDFsharp reads it (MuPDFCore hands MuPDF a password in the ANSI code page, not UTF-8).</summary>
    private const string Spanish = "Contraseña 2026";

    private static byte[] Pdf(WriteOptions? options, string title = "Invoice (March) Ñ")
    {
        using var ms = new MemoryStream();
        ScanPdfWriter.Write(ms, [new ScanPage(ScanPdfTests.Jpeg, 4, [new ScanWord("Archived", 2, 2, 20, 2)]), new ScanPage(ScanPdfTests.Jpeg, 4)], title, options);
        return ms.ToArray();
    }

    [Fact]
    public void APdfAScanPassesInkvoltPdfsCheck()
    {
        var problems = PdfA.Validate(Pdf(new WriteOptions { PdfA = true }));
        Assert.True(problems.Count == 0, string.Join("; ", problems));
    }

    [Fact]
    public void APlainScanIsNotPdfA() => Assert.NotEmpty(PdfA.Validate(Pdf(null)));

    [Fact]
    public void APdfAScanKeepsItsTextLayer()
    {
        using var engine = PdfEngine.Open(Pdf(new WriteOptions { PdfA = true }), InputFileTypes.PDF, null);
        Assert.Equal(2, engine.PageCount);
        Assert.Single(engine.GetText(0).Find("Archived", matchCase: true, wholeWord: false));
    }

    [Fact]
    public void AProtectedScanIsAes256AndOpensWithItsPasswordOnly()
    {
        var data = Pdf(new WriteOptions { Password = Password });
        var info = PdfSecurity.ReadSecurity(data, Password);
        Assert.Equal(EncryptionMethod.Aes256, info.Method);
        Assert.Equal(6, info.Revision);
        Assert.True(info.RequiresOpenPassword);
        Assert.True(info.Permissions.IsUnrestricted);
        Assert.Throws<PasswordRequiredException>(() => PdfSecurity.ReadSecurity(data, null));
        Assert.Throws<PasswordRequiredException>(() => PdfSecurity.ReadSecurity(data, "wrong"));
        Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(data, InputFileTypes.PDF, null).Dispose());
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, Password);
        Assert.Equal(2, engine.PageCount);
        Assert.Single(engine.GetText(0).Find("Archived", matchCase: true, wholeWord: false));
    }

    [Fact]
    public void AProtectedScanDrawsAsThePlainOne()
    {
        using var plain = PdfEngine.Open(Pdf(null), InputFileTypes.PDF, null);
        using var locked = PdfEngine.Open(Pdf(new WriteOptions { Password = Password }), InputFileTypes.PDF, Password);
        Assert.Equal(plain.Render(0, 0.5).Pixels, locked.Render(0, 0.5).Pixels);
    }

    [Fact]
    public void APasswordBeyondAsciiOpensIt()
    {
        var data = Pdf(new WriteOptions { Password = Spanish });
        Assert.Equal(EncryptionMethod.Aes256, PdfSecurity.ReadSecurity(data, Spanish).Method);
        Assert.Throws<PasswordRequiredException>(() => PdfSecurity.ReadSecurity(data, "Contrasena 2026"));
    }

    [Fact]
    public void InkvoltPdfRemovesTheProtectionWithThePassword()
    {
        var open = PdfSecurity.Unprotect(Pdf(new WriteOptions { Password = Password }), Password);
        Assert.Equal(EncryptionMethod.None, PdfSecurity.ReadSecurity(open, null).Method);
    }
}
