using InkvoltPrint.Core.Printing;

namespace InkvoltPrint.Tests;

/// <summary>
/// Print the clipboard (roadmap 4.13): what's on it decides where it goes (<see cref="ClipboardPrint.Choose"/>), and text is laid out
/// on pages (<see cref="ClipboardPrint.Pages"/>), bounded as input from another app.
/// </summary>
public class ClipboardPrintTests
{
    private static ClipboardPlan Choose(string? text = null, (int, int)? picture = null, params string[] files) =>
        ClipboardPrint.Choose(new ClipboardContent(text, picture, files));

    [Fact]
    public void Files_from_File_Explorer_go_as_they_are()
    {
        var one = Choose(files: @"C:\a.pdf");
        Assert.Equal(ClipboardWhat.Pdf, one.What);
        Assert.Equal([@"C:\a.pdf"], one.Files);
        Assert.Equal(ClipboardWhat.Pictures, Choose(files: [@"C:\a.JPG", @"C:\b.png"]).What);
        var batch = Choose(files: [@"C:\a.pdf", @"C:\b.png", @"C:\notes.docx"]);
        Assert.Equal(ClipboardWhat.Batch, batch.What);
        Assert.Equal([@"C:\a.pdf", @"C:\b.png"], batch.Files); // the rest left out
        Assert.Equal(ClipboardWhat.NotPrintable, Choose("some text", files: @"C:\notes.docx").What); // files win over text
        Assert.Equal(ClipboardWhat.TooBig, Choose(files: [.. Enumerable.Range(0, 101).Select(i => $@"C:\{i}.pdf")]).What);
    }

    [Fact]
    public void Text_beside_a_picture_wins_unless_it_is_only_an_address()
    {
        Assert.Equal(ClipboardWhat.Text, Choose("Quarterly totals\t1200\t1300", (800, 200)).What); // Excel puts a picture too
        Assert.Equal(ClipboardWhat.Picture, Choose("https://example.com/cat.jpg", (800, 600)).What); // a browser's copied picture
        Assert.Equal(ClipboardWhat.Picture, Choose(null, (800, 600)).What);
        Assert.Equal(ClipboardWhat.Picture, Choose("   ", (800, 600)).What);
        Assert.Equal(ClipboardWhat.Text, Choose("hello").What);
        Assert.Equal(ClipboardWhat.Nothing, Choose(" \r\n ").What);
        Assert.Equal(ClipboardWhat.Nothing, Choose(null, (0, 10)).What);
    }

    [Fact]
    public void Too_much_is_said_not_printed()
    {
        Assert.Equal(ClipboardWhat.TooBig, Choose(null, (20_000, 20_000)).What);
        Assert.Equal(ClipboardWhat.TooBig, Choose(new string('x', ClipboardPrint.MaxChars + 1)).What);
    }

    [Fact]
    public void Letter_and_A4_hold_about_ninety_columns_and_fifty_seven_lines()
    {
        var letter = ClipboardPrint.Layout(8.5, 11);
        Assert.Equal((91, 57), (letter.Columns, letter.Lines));
        var a4 = ClipboardPrint.Layout(8.27, 11.69);
        Assert.Equal(88, a4.Columns);
        Assert.Equal(61, a4.Lines);
        // Narrow paper still holds 40 characters a line (smaller type); a size that isn't one falls back to Letter.
        Assert.True(ClipboardPrint.Layout(4, 6).Columns >= 40);
        Assert.Equal(letter, ClipboardPrint.Layout(double.NaN, 11));
        Assert.Equal(letter, ClipboardPrint.Layout(1e9, 11));
    }

    [Fact]
    public void Lines_wrap_at_a_space_and_long_words_are_cut()
    {
        Assert.Equal(["the quick", "brown fox"], ClipboardPrint.Wrap("the quick brown fox", 10));
        Assert.Equal(["abcdefghij", "klm"], ClipboardPrint.Wrap("abcdefghijklm", 10));
        Assert.Equal([""], ClipboardPrint.Wrap("", 10));
        // A wide character takes two columns.
        Assert.Equal(["日本語日本", "語"], ClipboardPrint.Wrap("日本語日本語", 10));
    }

    [Fact]
    public void Tabs_line_ends_and_control_characters()
    {
        Assert.Equal("a       b", ClipboardPrint.Expand("a\tb"));
        Assert.Equal("abcdefgh        c", ClipboardPrint.Expand("abcdefgh\tc"));
        Assert.Equal("ab", ClipboardPrint.Expand("a\u0007b\u0000"));
        Assert.Equal("a😀", ClipboardPrint.Expand("a😀"));
        Assert.Equal("ab", ClipboardPrint.Expand("a\ud800b")); // a lone surrogate
        var pages = ClipboardPrint.Pages("one\r\ntwo\rthree\nfour", 20, 10, out var cut);
        Assert.Equal(["one", "two", "three", "four"], Assert.Single(pages));
        Assert.False(cut);
    }

    [Fact]
    public void Pages_fill_then_break_and_a_form_feed_starts_a_new_one()
    {
        var text = string.Join("\n", Enumerable.Range(1, 25).Select(i => $"line {i}"));
        var pages = ClipboardPrint.Pages(text, 40, 10, out _);
        Assert.Equal([10, 10, 5], pages.Select(p => p.Count));
        Assert.Equal("line 11", pages[1][0]);
        var fed = ClipboardPrint.Pages("first\fsecond", 40, 10, out _);
        Assert.Equal(2, fed.Count);
        // Nothing blank at the end.
        Assert.Single(ClipboardPrint.Pages("only\n\n\n\f\n\n", 40, 2, out _));
        Assert.Empty(ClipboardPrint.Pages("\n\n\n", 40, 2, out _));
    }

    [Fact]
    public void Blank_lines_past_the_page_limit_lose_nothing_and_text_past_the_character_limit_is_still_laid_out()
    {
        var full = string.Join("\n", Enumerable.Range(0, ClipboardPrint.MaxPages * 3).Select(i => "x")) + "\n\n\n\n\n";
        Assert.Equal(ClipboardPrint.MaxPages, ClipboardPrint.Pages(full, 40, 3, out var cut).Count);
        Assert.False(cut);
        var longText = "a b c\n" + new string('z', ClipboardPrint.MaxChars);
        var pages = ClipboardPrint.Pages(longText, 5000, 5000, out cut);
        Assert.NotEmpty(pages);
        Assert.Equal("a b c", pages[0][0]);
        Assert.True(cut);
    }

    [Fact]
    public void Past_the_page_limit_the_rest_is_left_out_and_said()
    {
        var text = string.Join("\n", Enumerable.Range(0, (ClipboardPrint.MaxPages + 5) * 3).Select(i => "x"));
        var pages = ClipboardPrint.Pages(text, 40, 3, out var cut);
        Assert.Equal(ClipboardPrint.MaxPages, pages.Count);
        Assert.True(cut);
        // One very long line alone can't pass it either.
        Assert.Equal(ClipboardPrint.MaxPages, ClipboardPrint.Pages(new string('y', 1_000_000), 10, 10, out cut).Count);
        Assert.True(cut);
    }

    [Fact]
    public void The_name_has_the_date_and_time()
    {
        Assert.Equal("Clipboard 2026-11-22 0130", ClipboardPrint.Name(new DateTime(2026, 11, 22, 1, 30, 0), "Clipboard"));
    }
}
