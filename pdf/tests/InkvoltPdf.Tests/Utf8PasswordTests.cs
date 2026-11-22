using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// An AES-256 (revision 6) file's password is UTF-8, and MuPDFCore passes passwords in the ANSI code page: a password
/// with ñ was refused. PdfEngine now passes it to MuPDF as UTF-8; a wrong password is still refused.
/// </summary>
public sealed class Utf8PasswordTests : IDisposable
{
    private readonly string _dir = Directory.CreateTempSubdirectory("inkvolt-utf8pw-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_dir, true); } catch (IOException) { }
    }

    private static byte[] Locked() => PdfSecurity.Protect(Core2Pdf.Build(
    [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >>",
        Core2Pdf.Stream("BT /F1 14 Tf 72 700 Td (Secret plans) Tj ET"),
        "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
    ]), null, "contraseña", "dueño");

    [Fact]
    public void An_AES_256_file_opens_with_a_password_that_has_an_ñ()
    {
        var data = Locked();
        Assert.Equal(EncryptionMethod.Aes256, PdfSecurity.ReadSecurity(data, "contraseña").Method);
        Assert.True(PdfSecurity.IsOpenPassword(data, "contraseña")); // the user password, told from the owner's
        Assert.False(PdfSecurity.IsOpenPassword(data, "dueño"));
        using (var engine = PdfEngine.Open(data, InputFileTypes.PDF, "contraseña"))
        {
            Assert.True(engine.IsEncrypted);
            Assert.Contains("Secret plans", engine.GetText(0).Text);
        }
        var path = Path.Combine(_dir, "locked.pdf");
        File.WriteAllBytes(path, data);
        using (var engine = PdfEngine.OpenFile(path, InputFileTypes.PDF, "dueño"))
            Assert.Contains("Secret plans", engine.GetText(0).Text);
    }

    [Fact]
    public void A_wrong_password_is_still_refused()
    {
        var data = Locked();
        Assert.True(Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(data, InputFileTypes.PDF, "contrasena")).WrongPassword);
        Assert.True(Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(data, InputFileTypes.PDF, "contraseñas")).WrongPassword);
        Assert.False(Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(data, InputFileTypes.PDF, null)).WrongPassword);
    }
}
