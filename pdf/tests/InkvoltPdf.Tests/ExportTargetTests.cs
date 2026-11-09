using InkvoltPdf.Core;
using static InkvoltPdf.Core.ExportTarget;

namespace InkvoltPdf.Tests;

public class ExportTargetTests
{
    private const string Documents = @"C:\Users\someone\Documents";

    // As the app's PdfFiles.UniquePath: the name, else "name (2)", "name (3)"… for names already taken.
    private static Func<string, string, string> Unique(ISet<string> taken) => (folder, name) =>
    {
        var path = Path.Combine(folder, name);
        for (var n = 2; taken.Contains(path); n++) path = Path.Combine(folder, $"{Path.GetFileNameWithoutExtension(name)} ({n}){Path.GetExtension(name)}");
        return path;
    };

    [Fact]
    public void AConversionIsReservedNextToThePdf()
    {
        var created = new List<string>();
        var r = Reserve(@"D:\work\report.pdf", "report.docx", Documents, Unique(new HashSet<string>()), p => { created.Add(p); return CreateResult.Created; });
        Assert.Equal(new Reserved(@"D:\work\report.docx", InDocuments: false), r);
        Assert.Equal([@"D:\work\report.docx"], created);
    }

    [Fact]
    public void ANameTakenMeanwhileMovesOnToTheNextOne()
    {
        // A second conversion (a double-click) reserved report.docx between choosing the name and creating it.
        var taken = new HashSet<string>();
        var r = Reserve(@"D:\work\report.pdf", "report.docx", Documents, Unique(taken), p =>
        {
            if (taken.Add(p) && p.EndsWith("report.docx", StringComparison.Ordinal)) return CreateResult.Exists;
            return CreateResult.Created;
        });
        Assert.Equal(@"D:\work\report (2).docx", r?.Path);
    }

    [Fact]
    public void AnUnsavedPdfOrARefusedFolderGoesToDocuments()
    {
        Assert.Equal(new Reserved(Path.Combine(Documents, "Untitled.docx"), true),
            Reserve(null, "Untitled.docx", Documents, Unique(new HashSet<string>()), _ => CreateResult.Created));
        var asked = new List<string>();
        var r = Reserve(@"E:\cd\report.pdf", "report.docx", Documents, Unique(new HashSet<string>()),
            p => { asked.Add(p); return p.StartsWith(@"E:\", StringComparison.Ordinal) ? CreateResult.Refused : CreateResult.Created; });
        Assert.Equal(new Reserved(Path.Combine(Documents, "report.docx"), true), r);
        Assert.Equal([@"E:\cd\report.docx", Path.Combine(Documents, "report.docx")], asked);
    }

    [Fact]
    public void NoDocumentsFolderAndARefusedOneGiveNothing()
    {
        // GetFolderPath(MyDocuments) can be "" (a profile without it): the caller then asks where (Save As).
        Assert.Null(Reserve(@"E:\cd\report.pdf", "report.docx", "", Unique(new HashSet<string>()), _ => CreateResult.Refused));
        Assert.Null(Reserve(null, "report.docx", null, Unique(new HashSet<string>()), _ => CreateResult.Created));
        // A folder whose name can't make a path (too long, bad characters) is skipped, not thrown.
        Assert.Null(Reserve(@"E:\cd\report.pdf", "report.docx", null, (_, _) => throw new PathTooLongException(), _ => CreateResult.Created));
    }

    [Fact]
    public void TryCreateReservesTheFileAndReportsRealRefusals()
    {
        var dir = Directory.CreateTempSubdirectory("inkvolt-target-");
        try
        {
            var path = Path.Combine(dir.FullName, "report.docx");
            Assert.Equal(CreateResult.Created, TryCreate(path));
            Assert.True(File.Exists(path)); // the empty file holds the name until the export replaces it
            Assert.Equal(CreateResult.Exists, TryCreate(path));
            // A folder that isn't there, and a "folder" that is a file: the IO errors a refused folder gives.
            Assert.Equal(CreateResult.Refused, TryCreate(Path.Combine(dir.FullName, "missing", "report.docx")));
            Assert.Equal(CreateResult.Refused, TryCreate(Path.Combine(path, "report.docx")));
            // End to end: a refused PDF folder, so Documents.
            var docs = dir.CreateSubdirectory("Documents").FullName;
            var r = Reserve(Path.Combine(dir.FullName, "missing", "report.pdf"), "report.docx", docs, (f, n) => Path.Combine(f, n));
            Assert.Equal(new Reserved(Path.Combine(docs, "report.docx"), true), r);
            Assert.True(File.Exists(r!.Path));
        }
        finally
        {
            dir.Delete(recursive: true);
        }
    }

    [Fact]
    public void ADeviceIsNeverAReservedFile()
    {
        // Opening a device (NUL, a COM port behind "COM¹.docx" on Windows 10) succeeds, but nothing can replace it: the
        // export would fail after all its work. A device refuses, so the conversion goes to Documents or asks.
        Assert.Equal(CreateResult.Refused, TryCreate(@"\\.\NUL"));
    }
}
