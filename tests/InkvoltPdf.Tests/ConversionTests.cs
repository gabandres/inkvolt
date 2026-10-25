using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public class ConversionTests
{
    [Theory]
    [InlineData(@"C:\a\letter.docx", OfficeApp.Word)]
    [InlineData(@"C:\a\OLD.DOC", OfficeApp.Word)]
    [InlineData(@"C:\a\notes.rtf", OfficeApp.Word)]
    [InlineData(@"C:\a\notes.odt", OfficeApp.Word)]
    [InlineData(@"C:\a\budget.xlsx", OfficeApp.Excel)]
    [InlineData(@"C:\a\budget.xlsm", OfficeApp.Excel)]
    [InlineData(@"C:\a\deck.pptx", OfficeApp.PowerPoint)]
    [InlineData(@"C:\a\show.ppsx", OfficeApp.PowerPoint)]
    public void OfficeFilesGoToTheirApp(string path, OfficeApp app) => Assert.Equal(app, OfficeFiles.AppFor(path));

    [Theory]
    [InlineData(@"C:\a\file.pdf")]
    [InlineData(@"C:\a\page.html")]
    [InlineData(@"C:\a\data.csv")]
    [InlineData(@"C:\a\docx")]
    public void OtherFilesHaveNoOfficeApp(string path) => Assert.Null(OfficeFiles.AppFor(path));

    [Fact]
    public void EncryptedOfficeFilesAreToldApart()
    {
        // An Office Open XML file is a ZIP; protected with a password it becomes an OLE compound file.
        byte[] cfb = [0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1, 0, 0];
        byte[] zip = [(byte)'P', (byte)'K', 3, 4, 0, 0];
        Assert.True(OfficeFiles.IsEncryptedOpenXml(cfb, "a.docx"));
        Assert.True(OfficeFiles.IsEncryptedOpenXml(cfb, "a.XLSX"));
        Assert.False(OfficeFiles.IsEncryptedOpenXml(zip, "a.docx"));
        Assert.False(OfficeFiles.IsEncryptedOpenXml(cfb, "a.doc")); // the old binary formats are always compound files
        Assert.False(OfficeFiles.IsEncryptedOpenXml([1, 2], "a.pptx"));
    }

    [Fact]
    public void OpenFilterListsEveryExtension()
    {
        foreach (var ext in OfficeFiles.Extensions(OfficeApp.Word).Concat(OfficeFiles.Extensions(OfficeApp.Excel)).Concat(OfficeFiles.Extensions(OfficeApp.PowerPoint)))
            Assert.Contains("*" + ext, OfficeFiles.FilterPattern([OfficeApp.Word, OfficeApp.Excel, OfficeApp.PowerPoint]));
        Assert.DoesNotContain("*.pptx", OfficeFiles.FilterPattern([OfficeApp.Word]));
        Assert.Equal("", OfficeFiles.FilterPattern([]));
    }

    [Theory]
    [InlineData("example.com", "https://example.com/")]
    [InlineData("  https://example.com/a?b=1#c ", "https://example.com/a?b=1#c")]
    [InlineData("http://192.0.2.10:8080/status", "http://192.0.2.10:8080/status")]
    [InlineData("www.example.org/path page", "https://www.example.org/path%20page")]
    public void WebAddressesAreNormalized(string typed, string expected)
    {
        Assert.True(WebFiles.TryParseAddress(typed, out var uri, out var error), error);
        Assert.Equal(expected, uri!.AbsoluteUri);
    }

    [Theory]
    [InlineData("")]
    [InlineData("javascript:alert(1)")]
    [InlineData("file:///C:/Windows/win.ini")]
    [InlineData("ftp://example.com/x")]
    [InlineData("data:text/html,hi")]
    [InlineData("not a host")]
    [InlineData("https://")]
    public void OnlyWebAddressesAreTaken(string typed)
    {
        Assert.False(WebFiles.TryParseAddress(typed, out var uri, out var error));
        Assert.Null(uri);
        Assert.False(string.IsNullOrWhiteSpace(error));
    }

    [Fact]
    public void WebFilesAreHtmlAndMht()
    {
        Assert.True(WebFiles.IsWebFile(@"C:\a\page.html"));
        Assert.True(WebFiles.IsWebFile(@"C:\a\page.HTM"));
        Assert.True(WebFiles.IsWebFile(@"C:\a\saved.mht"));
        Assert.True(WebFiles.IsWebFile(@"C:\a\saved.mhtml"));
        Assert.False(WebFiles.IsWebFile(@"C:\a\page.pdf"));
    }

    [Fact]
    public void PrintOptionsBecomeInches()
    {
        var letter = new WebPdfOptions();
        Assert.Equal((8.5, 11.0), letter.PageInches);
        Assert.Equal(0.4, letter.MarginInches, 3);
        var a4 = new WebPdfOptions { Paper = WebPaper.A4, Landscape = true, Margins = WebMargins.None };
        Assert.Equal(11.69, a4.PageInches.Width, 2);
        Assert.Equal(8.27, a4.PageInches.Height, 2);
        Assert.Equal(0, a4.MarginInches);
        Assert.Equal(1, new WebPdfOptions { Margins = WebMargins.Wide }.MarginInches);
        Assert.Equal((8.5, 14.0), new WebPdfOptions { Paper = WebPaper.Legal }.PageInches);
    }

    [Theory]
    [InlineData("https://example.com/", "example.com.pdf")]
    [InlineData("https://www.example.com/news/2026/story.html?id=3", "www.example.com - story.pdf")]
    [InlineData("https://example.com/docs/", "example.com - docs.pdf")]
    [InlineData("http://192.0.2.10:8080/a:b", "192.0.2.10 - a_b.pdf")]
    public void WebPagesGetAFileName(string address, string name) => Assert.Equal(name, WebFiles.PdfName(new Uri(address)));

    [Fact]
    public void TheMarkOfTheWebIsRead()
    {
        Assert.Equal(3, OfficeFiles.ZoneId("[ZoneTransfer]\r\nZoneId=3\r\nReferrerUrl=https://example.com/\r\n"));
        Assert.Equal(4, OfficeFiles.ZoneId("[ZoneTransfer]\nzoneid = 4"));
        Assert.Null(OfficeFiles.ZoneId("[ZoneTransfer]\r\nHostUrl=about:internet"));
        Assert.Null(OfficeFiles.ZoneId(""));
    }

    [Fact]
    public void ConvertedFilesKeepTheirName() => Assert.Equal("Quarterly report.pdf", OfficeFiles.PdfName(@"C:\a\Quarterly report.docx"));
}
