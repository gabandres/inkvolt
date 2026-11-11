using InkvoltPdf.Core;
using static InkvoltPdf.Core.ConvertCommand;

namespace InkvoltPdf.Tests;

/// <summary>
/// Explorer's "Convert to Word with Inkvolt PDF" (<c>--convert-to word &lt;files…&gt;</c>): what the command line asks for, how it
/// reaches a running copy, the names it writes and where its result shows.
/// </summary>
public class ConvertCommandTests
{
    private static Request Parse(params string[] args)
    {
        Assert.True(TryParse(args, out var request, out var error), $"refused: {error}");
        return request!;
    }

    private static ParseError Refused(params string[] args)
    {
        Assert.False(TryParse(args, out var request, out var error));
        Assert.Null(request);
        return error;
    }

    [Fact]
    public void ExplorersVerbIsAConvertCommand()
    {
        Assert.True(IsCommand(["--convert-to", "word", @"C:\a.pdf"]));
        Assert.True(IsCommand(["--CONVERT-TO=word", @"C:\a.pdf"]));
        Assert.False(IsCommand([@"C:\a.pdf"]));
        Assert.False(IsCommand([]));
        Assert.False(IsCommand(["--batch", "--convert-to", "word"]));
        Assert.False(IsCommand(["--convert-tones"]));
    }

    [Fact]
    public void TheFormatAndFilesAreRead()
    {
        var r = Parse("--convert-to", "word", @"C:\Users\me\report.pdf");
        Assert.Equal(ExportFormat.Word, r.Format);
        Assert.Equal([@"C:\Users\me\report.pdf"], r.Files);
        Assert.Equal((0, 0), (r.OverLimit, r.Refused));
    }

    [Theory]
    [InlineData("word", ExportFormat.Word)]
    [InlineData("DOCX", ExportFormat.Word)]
    [InlineData("excel", ExportFormat.Excel)]
    [InlineData("xlsx", ExportFormat.Excel)]
    [InlineData("powerpoint", ExportFormat.PowerPoint)]
    [InlineData("pptx", ExportFormat.PowerPoint)]
    [InlineData("text", ExportFormat.Text)]
    [InlineData("txt", ExportFormat.Text)]
    [InlineData("html", ExportFormat.Html)]
    public void EachExportFormatHasANameOnTheCommandLine(string name, ExportFormat format)
    {
        Assert.Equal(format, Parse("--convert-to", name, @"C:\a.pdf").Format);
        Assert.Equal(format, Parse($"--convert-to={name}", @"C:\a.pdf").Format);
    }

    [Fact]
    public void AWrongCommandSaysWhatIsWrong()
    {
        Assert.Equal(ParseError.NoFormat, Refused("--convert-to"));
        Assert.Equal(ParseError.NoFormat, Refused("--convert-to="));
        Assert.Equal(ParseError.UnknownFormat, Refused("--convert-to", "pdf", @"C:\a.pdf"));
        Assert.Equal(ParseError.UnknownFormat, Refused("--convert-to", @"C:\a.pdf"));
        Assert.Equal(ParseError.NoFiles, Refused("--convert-to", "word"));
        Assert.Equal(ParseError.NoFiles, Refused("--convert-to", "word", "", "   "));
        Assert.Equal(ParseError.NotACommand, Refused(@"C:\a.pdf"));
    }

    [Fact]
    public void ManyFilesAreKeptInOrderOnceEach()
    {
        var r = Parse("--convert-to", "word", @"C:\b.pdf", @"C:\a.pdf", @"c:\B.PDF", @"C:\c.pdf");
        Assert.Equal([@"C:\b.pdf", @"C:\a.pdf", @"C:\c.pdf"], r.Files);
    }

    [Fact]
    public void FilesPastTheLimitAreDroppedAndCounted()
    {
        var files = Enumerable.Range(0, MaxFiles + 7).Select(i => $@"C:\in\{i}.pdf");
        var r = Parse(["--convert-to", "word", .. files]);
        Assert.Equal(MaxFiles, r.Files.Count);
        Assert.Equal((7, 0), (r.OverLimit, r.Refused));
        Assert.Equal(@"C:\in\0.pdf", r.Files[0]);
    }

    [Fact]
    public void RelativePathsBecomeFullOnes()
    {
        var r = Parse("--convert-to", "word", "report.pdf", @"..\x\other.pdf");
        Assert.Equal(Path.GetFullPath("report.pdf"), r.Files[0]);
        Assert.Equal(Path.GetFullPath(@"..\x\other.pdf"), r.Files[1]);
    }

    [Theory]
    [InlineData(@"\\server\share\Reports\Q3 ""final"".pdf")] // a quote no Windows name holds: kept, it then isn't found
    [InlineData(@"\\server\share\Reports\Q3.pdf")]
    [InlineData(@"\\?\C:\very\long\report.pdf")]
    [InlineData(@"\\?\UNC\server\share\report.pdf")]
    [InlineData(@"C:\work\CON.pdf")]
    [InlineData(@"C:\work\-- not an option.pdf")]
    public void HostilePathsAreTakenAsFilesNeverAsMore(string path)
    {
        var r = Parse("--convert-to", "word", path);
        Assert.Single(r.Files);
        Assert.EndsWith(Path.GetFileName(path), r.Files[0], StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(@"\\.\pipe\inkvolt")] // a read that never ends would hold the queue for good
    [InlineData(@"\\.\COM1")]
    [InlineData(@"//./pipe/inkvolt")]
    [InlineData(@"\\?\GLOBALROOT\Device\Null")]
    [InlineData(@"\\?\Volume{12345678-1234-1234-1234-123456789abc}\x.pdf")]
    [InlineData(@"\??\C:\x.pdf")]
    public void ADevicePathIsRefusedNotRead(string path)
    {
        var r = Parse("--convert-to", "word", path, @"C:\d.pdf");
        Assert.Equal([@"C:\d.pdf"], r.Files);
        Assert.Equal(1, r.Refused);
    }

    [Fact]
    public void LeftOutCountsStopAtTheirLimitInsteadOfOverflowing()
    {
        var most = $"--convert-to=word:{MaxLeftOut}:{MaxLeftOut}";
        var flood = Enumerable.Range(0, 5000).Select(_ => Parse(most, @"C:\a.pdf")).ToList();
        var merged = Merge(flood).Single();
        Assert.Equal((MaxLeftOut, MaxLeftOut), (merged.OverLimit, merged.Refused));
        Assert.Equal(MaxLeftOut, AddLeftOut(int.MaxValue, int.MaxValue));
        Assert.Equal(ParseError.UnknownFormat, Refused($"--convert-to=word:{MaxLeftOut + 1}:0", @"C:\a.pdf"));
    }

    [Fact]
    public void ALongPathIsKept()
    {
        var deep = @"C:\" + string.Join('\\', Enumerable.Repeat(new string('d', 120), 4)) + @"\report.pdf"; // over 260
        Assert.True(deep.Length > 260);
        Assert.Equal(deep, Parse("--convert-to", "word", deep).Files[0]);
    }

    [Fact]
    public void AnArgumentWithAControlCharacterIsDropped()
    {
        // Forwarding puts one argument per line: a line break inside one would make two files out of it.
        var r = Parse("--convert-to", "word", "C:\\a.pdf\nC:\\b.pdf", "C:\\c\0.pdf", @"C:\d.pdf");
        Assert.Equal([@"C:\d.pdf"], r.Files);
        Assert.Equal((0, 2), (r.OverLimit, r.Refused)); // refused, not over the limit: said apart
        Assert.Equal(ParseError.NoFiles, Refused("--convert-to", "word", "C:\\a.pdf\r"));
    }

    [Fact]
    public void ForwardedArgumentsReadBackTheSameRequest()
    {
        // The running copy gets one argument per line, each made absolute by the launch (SingleInstance.Absolute): the
        // format is one argument with the switch, so it is never taken for a relative path.
        var first = Parse("--convert-to", "word", @"C:\a.pdf", @"\\server\share\b.pdf");
        var forwarded = ToArguments(first);
        Assert.Equal("--convert-to=word", forwarded[0]);
        Assert.All(forwarded.Skip(1), a => Assert.True(Path.IsPathFullyQualified(a)));
        var lines = string.Join('\n', forwarded).Split('\n', StringSplitOptions.RemoveEmptyEntries);
        var again = Parse(lines);
        Assert.Equal(first.Format, again.Format);
        Assert.Equal(first.Files, again.Files);
    }

    [Theory]
    [InlineData(@"C:\work\report.pdf", ExportFormat.Word, "report.docx")]
    [InlineData(@"C:\work\Q3.final.PDF", ExportFormat.Word, "Q3.final.docx")]
    [InlineData(@"C:\work\report.pdf", ExportFormat.Excel, "report.xlsx")]
    [InlineData(@"C:\work\CON.pdf", ExportFormat.Word, "_CON.docx")] // a device name (Windows 10) is never made
    [InlineData(@"C:\work\nul.pdf", ExportFormat.Text, "_nul.txt")]
    [InlineData(@"C:\work\.pdf", ExportFormat.Word, "Untitled.docx")]
    [InlineData(@"C:\work\ends with dots...pdf", ExportFormat.Word, "ends with dots.docx")]
    public void TheOutputIsNamedAfterThePdf(string pdf, ExportFormat format, string expected) =>
        Assert.Equal(expected, OutputName(pdf, format));

    [Fact]
    public void TheOutputIsReservedNextToThePdfNeverOverAFile()
    {
        var folder = Directory.CreateTempSubdirectory("inkvolt-convert-");
        try
        {
            var pdf = Path.Combine(folder.FullName, "report.pdf");
            File.WriteAllText(pdf, "%PDF-1.7");
            File.WriteAllText(Path.Combine(folder.FullName, "report.docx"), "the user's own file");
            var first = ExportTarget.Reserve(pdf, OutputName(pdf, ExportFormat.Word), null, Unique);
            var second = ExportTarget.Reserve(pdf, OutputName(pdf, ExportFormat.Word), null, Unique);
            Assert.Equal(Path.Combine(folder.FullName, "report (2).docx"), first?.Path);
            Assert.Equal(Path.Combine(folder.FullName, "report (3).docx"), second?.Path);
            Assert.Equal("the user's own file", File.ReadAllText(Path.Combine(folder.FullName, "report.docx")));
        }
        finally
        {
            folder.Delete(recursive: true);
        }
    }

    [Fact]
    public void ADeviceNamedPdfGetsAFileOfItsOwn()
    {
        var folder = Directory.CreateTempSubdirectory("inkvolt-convert-");
        try
        {
            var pdf = Path.Combine(folder.FullName, "CON.pdf");
            var r = ExportTarget.Reserve(pdf, OutputName(pdf, ExportFormat.Word), null, Unique);
            Assert.Equal(Path.Combine(folder.FullName, "_CON.docx"), r?.Path);
            Assert.True(File.Exists(r!.Path));
        }
        finally
        {
            folder.Delete(recursive: true);
        }
    }

    // As the app's PdfFiles.UniquePath for names that fit: the name, else "name (2)"… for names taken on disk.
    private static string Unique(string folder, string name)
    {
        var path = Path.Combine(folder, name);
        for (var n = 2; File.Exists(path); n++) path = Path.Combine(folder, $"{Path.GetFileNameWithoutExtension(name)} ({n}){Path.GetExtension(name)}");
        return path;
    }

    [Theory]
    // The in-app one-click's notice when the window is up and this is the only conversion; the small window otherwise.
    [InlineData(true, false, false, 1, true)]
    [InlineData(true, false, false, 2, false)] // several files: a list says what became of each
    [InlineData(true, true, false, 1, false)] // the list is open: it gets this one too
    [InlineData(true, false, true, 1, false)] // one runs already (Explorer starts one launch per file)
    [InlineData(false, false, false, 1, false)] // the app isn't open: the small window
    public void TheResultShowsAsANoticeOnlyInTheOpenWindowForOneFile(bool windowReady, bool listOpen, bool busy, int files, bool notice) =>
        Assert.Equal(notice, ShowsNotice(windowReady, listOpen, busy, files));
}
