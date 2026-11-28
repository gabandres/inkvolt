using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>File › Share… (the Mac's Share…; <see cref="DocumentShare"/>): what is shared, and the copy for unsaved changes.</summary>
public class DocumentShareTests
{
    [Fact]
    public void ASavedFileIsSharedAsItIsAndChangesAsk()
    {
        Assert.Equal(ShareSource.SavedFile, DocumentShare.SourceFor(@"C:\Docs\a.pdf", dirty: false));
        Assert.Equal(ShareSource.AskSaveOrCopy, DocumentShare.SourceFor(@"C:\Docs\a.pdf", dirty: true));
        Assert.Equal(ShareSource.Copy, DocumentShare.SourceFor(null, dirty: true));
        Assert.Equal(ShareSource.Copy, DocumentShare.SourceFor("", dirty: false));
    }

    [Fact]
    public void TheCopysNameIsAFileNameWindowsTakes()
    {
        Assert.Equal("Contract.pdf", DocumentShare.CopyName("Contract.pdf"));
        Assert.Equal("Scan 3.pdf", DocumentShare.CopyName("Scan 3"));
        Assert.Equal("b_c.pdf", DocumentShare.CopyName(@"..\a\b?c.PDF"));
        Assert.Equal("_CON.pdf", DocumentShare.CopyName("CON"));
        Assert.Equal("Document.pdf", DocumentShare.CopyName("..."));
        Assert.True(DocumentShare.CopyName(new string('x', 5000)).Length <= BatchNames.MaxLength + 4);
    }

    [Fact]
    public void CopiesGoInFoldersOfTheirOwnAndOldOnesGo()
    {
        var temp = Path.Combine(Path.GetTempPath(), "inkvolt-share-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var now = DateTime.UtcNow;
            var first = DocumentShare.WriteCopy(temp, "a.pdf", [1, 2, 3], now);
            var second = DocumentShare.WriteCopy(temp, "a.pdf", [4], now);
            Assert.NotEqual(Path.GetDirectoryName(first), Path.GetDirectoryName(second));
            Assert.Equal([1, 2, 3], File.ReadAllBytes(first));
            Assert.Equal("a.pdf", Path.GetFileName(second));

            Directory.SetCreationTimeUtc(Path.GetDirectoryName(first)!, now - TimeSpan.FromDays(2));
            DocumentShare.Sweep(Path.Combine(temp, DocumentShare.FolderName), now);
            Assert.False(File.Exists(first));
            Assert.True(File.Exists(second));
        }
        finally
        {
            Directory.Delete(temp, true);
        }
    }
}
