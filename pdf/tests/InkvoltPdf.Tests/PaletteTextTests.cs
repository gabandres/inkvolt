using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

public class PaletteTextTests
{
    [Fact]
    public void WithoutADocumentSaysWhyAndWhatToDo()
    {
        var text = PaletteText.NoMatch(" sign ", hasDocument: false);
        Assert.StartsWith("Nothing matches “sign” with no document open.", text);
        Assert.Contains("Open a file", text);
    }

    [Fact]
    public void WithADocumentSuggestsOtherWordsOrAPage()
    {
        var text = PaletteText.NoMatch("sgin", hasDocument: true);
        Assert.Equal("Nothing matches “sgin”. Try another word, or type a page number to go there.", text);
    }

    [Fact]
    public void LongQueriesAreShortened()
    {
        var text = PaletteText.NoMatch(new string('x', 80), hasDocument: true);
        Assert.Contains(new string('x', 40) + "…", text);
        Assert.DoesNotContain(new string('x', 41), text);
    }
}
