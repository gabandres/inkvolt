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

    /// <summary>
    /// The pre-release review: old copies went only on the next Share…, which may never come. Startup sweeps them, from the
    /// temporary folder itself, and a temporary folder that isn't there or isn't a folder is no exception.
    /// </summary>
    [Fact]
    public void StartupSweepsOldCopiesAndNeverThrows()
    {
        var temp = Path.Combine(Path.GetTempPath(), "inkvolt-share-test-" + Guid.NewGuid().ToString("N"));
        try
        {
            var now = DateTime.UtcNow;
            var old = DocumentShare.WriteCopy(temp, "a.pdf", [1], now);
            var recent = DocumentShare.WriteCopy(temp, "b.pdf", [2], now);
            Directory.SetCreationTimeUtc(Path.GetDirectoryName(old)!, now - TimeSpan.FromDays(2));
            DocumentShare.SweepCopies(temp, now);
            Assert.False(File.Exists(old));
            Assert.True(File.Exists(recent));

            DocumentShare.SweepCopies(Path.Combine(temp, "not there"), now);
            File.WriteAllBytes(Path.Combine(temp, "a file"), [0]);
            Directory.CreateDirectory(Path.Combine(temp, "a file root"));
            File.WriteAllBytes(Path.Combine(temp, "a file root", DocumentShare.FolderName), [0]); // the share folder's name taken by a file
            DocumentShare.SweepCopies(Path.Combine(temp, "a file"), now);
            DocumentShare.SweepCopies(Path.Combine(temp, "a file root"), now);
            DocumentShare.SweepCopies("bad\0path", now);
        }
        finally
        {
            Directory.Delete(temp, true);
        }
    }

    /// <summary>
    /// The pre-release review: Windows' StorageFile throws ArgumentException for a path too long for it (or \\?\), which
    /// escaped the discarded Share… task, so Share… did nothing; a sheet that failed to show left its request handler
    /// subscribed. Every failure is an outcome, and the offer is withdrawn.
    /// </summary>
    [Fact]
    public async Task AFileWindowsCantOpenOrASheetThatFailsIsSaidAndWithdrawn()
    {
        var offered = 0;
        var withdrawn = 0;
        var unreadable = await ShareSheet.ShowAsync<string>(() => throw new ArgumentException("path"), _ => offered++, () => withdrawn++, () => { });
        Assert.Equal(ShareSheetOutcome.FileUnreadable, unreadable.Outcome);
        Assert.IsType<ArgumentException>(unreadable.Error);
        Assert.Equal((0, 0), (offered, withdrawn));

        var notShown = await ShareSheet.ShowAsync(() => Task.FromResult("f"), _ => offered++, () => withdrawn++,
            () => throw new System.Runtime.InteropServices.COMException("no sheet"));
        Assert.Equal(ShareSheetOutcome.Unavailable, notShown.Outcome);
        Assert.Equal((1, 1), (offered, withdrawn));

        var offerFailed = await ShareSheet.ShowAsync<string>(() => Task.FromResult("f"), _ => throw new InvalidOperationException(), () => throw new InvalidOperationException(), () => { });
        Assert.Equal(ShareSheetOutcome.Unavailable, offerFailed.Outcome); // a withdraw that fails too is still caught

        var shown = await ShareSheet.ShowAsync(() => Task.FromResult("f"), f => Assert.Equal("f", f), () => withdrawn++, () => { });
        Assert.Equal(new ShareSheetResult(ShareSheetOutcome.Shown), shown);
        Assert.Equal(1, withdrawn); // the handler removes itself when the sheet asks
    }
}
