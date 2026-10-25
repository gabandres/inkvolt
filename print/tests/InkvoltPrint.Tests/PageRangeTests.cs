using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

public class PageRangeTests
{
    [Theory]
    [InlineData("", 5, new[] { 1, 2, 3, 4, 5 })]
    [InlineData("  ", 3, new[] { 1, 2, 3 })]
    [InlineData("2", 5, new[] { 2 })]
    [InlineData("1-3, 5", 5, new[] { 1, 2, 3, 5 })]
    [InlineData("4-", 6, new[] { 4, 5, 6 })]
    [InlineData("-2", 6, new[] { 1, 2 })]
    [InlineData("3-1", 5, new[] { 1, 2, 3 })]
    [InlineData("2,2,1", 5, new[] { 1, 2 })]
    [InlineData("1–3", 5, new[] { 1, 2, 3 })] // en dash, as pasted from Word
    public void Parses(string text, int pageCount, int[] expected)
    {
        Assert.True(PageRange.TryParse(text, pageCount, out var pages, out _));
        Assert.Equal(expected, pages);
    }

    [Theory]
    [InlineData("0", 5, "Pages start at 1")]
    [InlineData("7", 5, "This document has 5 pages")]
    [InlineData("2-9", 5, "This document has 5 pages")]
    [InlineData("a", 5, "Use page numbers like 1-3, 5")]
    [InlineData("1--2", 5, "Use page numbers like 1-3, 5")]
    public void Rejects(string text, int pageCount, string error)
    {
        Assert.False(PageRange.TryParse(text, pageCount, out _, out var message));
        Assert.Equal(error, message);
    }
}
