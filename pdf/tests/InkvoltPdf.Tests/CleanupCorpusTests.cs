using System.Security.Cryptography;
using InkvoltPdf.OcrCorpus;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Tests;

/// <summary>
/// Inkvolt Print's cleanup corpus (roadmap 2.3; its word error rate needs Windows' recognizer: <c>ocr-corpus cleanup</c>): the
/// pages are the same each time, the filters that should fire do, and the Cyrillic and Japanese pages can be made on a PC without
/// those OCR languages.
/// </summary>
public class CleanupCorpusTests
{
    private static CleanupFile File(string name) => CleanupCorpus.Files.Single(f => f.Name == name);

    [Theory]
    [InlineData("en-skewed-lid")]
    [InlineData("en-faded")]
    public void TheSamePageComesOutTwice(string name)
    {
        var (a, b) = (CleanupCorpus.ScanPage(File(name), 0), CleanupCorpus.ScanPage(File(name), 0));
        Assert.Equal(SHA256.HashData(a.Pixels), SHA256.HashData(b.Pixels));
        Assert.Equal(a.Words, b.Words);
    }

    [Fact]
    public void TheSkewedSheetIsCroppedAtItsEdgeOnBothPages()
    {
        var file = File("en-skewed-lid");
        for (var page = 0; page < file.Pages; page++)
        {
            var (px, w, h, _, _) = CleanupCorpus.ScanPage(file, page);
            var (_, cw, ch) = CleanupCorpus.Cleaned(px, w, h, 1, PageFilters.CropToPaper);
            Assert.InRange(cw, 2550 - 40, 2550 + 60); // the sheet is 2550 wide on a glass 300 wider
            Assert.InRange(ch, 3300 - 40, 3300 + 60);
        }
    }

    [Theory]
    [InlineData("en-halftoned", PageFilters.Descreen)]
    [InlineData("en-faded", PageFilters.RestoreColors)]
    [InlineData("en-grey", PageFilters.Whiten)]
    public void TheFilterEachFileIsMadeForFires(string name, PageFilters filter)
    {
        var file = File(name);
        var (px, w, h, channels, _) = CleanupCorpus.ScanPage(file, 0);
        var today = CleanupCorpus.Today(px, w, h, channels);
        Assert.Equal(filter, PageCleanup.Apply(today.Pixels, today.Width, today.Height, channels, CleanupCorpus.Dpi, filter).Done);
    }

    [Theory]
    [InlineData("ru-grey-skewed", "и")]
    [InlineData("ja-faded", "")]
    public void NonLatinPagesAreMade(string name, string word)
    {
        var (px, w, h, words) = CleanupCorpus.CleanPage(File(name), 0);
        Assert.Equal(w * h, px.Length);
        Assert.NotEmpty(words);
        if (word.Length > 0) Assert.Contains(words, x => x.Length > 1);
        Assert.Contains(px, v => v < 128); // the text was drawn: a font for its letters exists here
    }
}
