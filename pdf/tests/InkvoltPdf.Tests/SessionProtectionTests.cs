using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// A session's protection as the commands see it (Remove Protection, Sign), and reloading a file whose protection the
/// session changed or that another program protected.
/// </summary>
public sealed class SessionProtectionTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), $"inkvoltpdf-protection-{Guid.NewGuid():N}");

    public SessionProtectionTests() => Directory.CreateDirectory(_dir);

    public void Dispose()
    {
        if (Directory.Exists(_dir)) Directory.Delete(_dir, recursive: true);
    }

    private string Write(byte[] data, string name = "doc.pdf")
    {
        var path = Path.Combine(_dir, name);
        File.WriteAllBytes(path, data);
        return path;
    }

    private static readonly PdfPermissions NoCopying = new(PrintPermission.HighResolution, false, true, true, true, true);

    [Fact]
    public void A_restriction_only_pdf_has_encryption_though_it_opens_without_a_password()
    {
        var pdf = PdfSecurity.Protect(TestPdf.Make(1), null, null, "owner", NoCopying);
        using var s = DocumentSession.FromBytes(pdf, "restricted.pdf");
        Assert.False(s.Engine.IsEncrypted); // MuPDF: no open password needed, so "not encrypted"
        Assert.True(s.HasEncryption);
    }

    [Fact]
    public void Open_password_protected_and_plain_pdfs()
    {
        using (var s = DocumentSession.FromBytes(PdfSecurity.Protect(TestPdf.Make(1), null, "open", "owner"), "locked.pdf", "open"))
            Assert.True(s.HasEncryption);
        using (var s = DocumentSession.FromBytes(TestPdf.Make(1), "plain.pdf"))
            Assert.False(s.HasEncryption);
    }

    [Fact]
    public void Removing_the_protection_clears_it_and_undo_brings_it_back()
    {
        var pdf = PdfSecurity.Protect(TestPdf.Make(1), null, null, "owner", NoCopying);
        using var s = DocumentSession.FromBytes(pdf, "restricted.pdf", "owner");
        s.Commit(PdfSecurity.Unprotect(s.Data, s.Password), "Remove password protection", null, null);
        Assert.False(s.HasEncryption);
        s.Undo();
        Assert.True(s.HasEncryption);
    }

    [Fact]
    public async Task Reload_after_removing_the_protection_opens_the_protected_file_with_its_password()
    {
        var path = Write(PdfSecurity.Protect(TestPdf.Make(2), null, "open", "owner"));
        using var s = DocumentSession.Open(path, "open");
        s.Commit(PdfSecurity.Unprotect(s.Data, "owner"), "Remove password protection", null, null);
        Assert.Null(s.Password);

        Assert.True(await s.ReloadFromDiskAsync());
        Assert.False(s.IsDirty);
        Assert.True(s.HasEncryption);
        Assert.Equal("open", s.Password);
        Assert.Equal("open", s.OpenPassword);
        Assert.Equal(2, s.Engine.PageCount);
    }

    [Fact]
    public async Task Reload_after_saving_without_protection_needs_no_password()
    {
        var path = Write(PdfSecurity.Protect(TestPdf.Make(1), null, "open", "owner"));
        using var s = DocumentSession.Open(path, "open");
        s.Commit(PdfSecurity.Unprotect(s.Data, "owner"), "Remove password protection", null, null);
        await s.SaveAsAsync(path);

        Assert.True(await s.ReloadFromDiskAsync());
        Assert.Null(s.Password);
        Assert.False(s.HasEncryption);
    }

    [Fact]
    public async Task A_file_protected_by_another_program_needs_its_password_to_reload()
    {
        var path = Write(TestPdf.Make(1));
        using var s = DocumentSession.Open(path);
        File.WriteAllBytes(path, PdfSecurity.Protect(TestPdf.Make(3), null, "theirs", "owner"));

        var ex = await Assert.ThrowsAsync<PasswordRequiredException>(() => s.ReloadFromDiskAsync());
        Assert.False(ex.WrongPassword);
        await Assert.ThrowsAsync<PasswordRequiredException>(() => s.ReloadFromDiskAsync(password: "wrong"));
        Assert.Equal(1, s.Engine.PageCount); // nothing changed

        Assert.True(await s.ReloadFromDiskAsync(password: "theirs"));
        Assert.Equal(3, s.Engine.PageCount);
        Assert.Equal("theirs", s.Password);
        Assert.Equal("theirs", s.OpenPassword);
    }
}
