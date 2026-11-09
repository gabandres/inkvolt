using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public class ExportTargetTests
{
    private const string Documents = @"C:\Users\someone\Documents";

    [Fact]
    public void AConversionGoesNextToThePdf()
    {
        var (folder, inDocuments) = ExportTarget.Folder(@"D:\work\report.pdf", Documents, _ => true);
        Assert.Equal(@"D:\work", folder);
        Assert.False(inDocuments);
    }

    [Fact]
    public void AnUnsavedPdfOrAFolderThatCantBeWrittenGoesToDocuments()
    {
        Assert.Equal((Documents, true), ExportTarget.Folder(null, Documents, _ => true));
        Assert.Equal((Documents, true), ExportTarget.Folder("", Documents, _ => true));
        var asked = new List<string>();
        Assert.Equal((Documents, true), ExportTarget.Folder(@"E:\cd\report.pdf", Documents, f => { asked.Add(f); return false; }));
        Assert.Equal([@"E:\cd"], asked); // Documents itself isn't probed: the save says if it fails
    }

    [Fact]
    public void CanWriteTriesTheFolderAndLeavesNothingBehind()
    {
        var dir = Directory.CreateTempSubdirectory("inkvolt-target-");
        try
        {
            Assert.True(ExportTarget.CanWrite(dir.FullName));
            Assert.Empty(dir.EnumerateFileSystemInfos());
            Assert.False(ExportTarget.CanWrite(Path.Combine(dir.FullName, "missing")));
            // A folder that refuses new files (the Windows folder for a user without rights is one; a test can't count on
            // that), as a path that names a file.
            var file = Path.Combine(dir.FullName, "a file");
            File.WriteAllText(file, "x");
            Assert.False(ExportTarget.CanWrite(file));
        }
        finally
        {
            dir.Delete(recursive: true);
        }
    }
}
