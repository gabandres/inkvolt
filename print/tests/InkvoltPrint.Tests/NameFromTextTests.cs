using System.Globalization;
using InkvoltPrint.Core.Escl;
using InkvoltPrint.Core.Pdf;
using InkvoltPrint.Core.Presets;

namespace InkvoltPrint.Tests;

/// <summary>Naming a scan's file from its first page's text (roadmap 4.11): the lines, a date, the heading, a number, and the template.</summary>
public class NameFromTextTests
{
    private static readonly CultureInfo Us = CultureInfo.GetCultureInfo("en-US"), Mx = CultureInfo.GetCultureInfo("es-MX");

    /// <summary>Words as a recognizer gives them: each line's words left to right, <paramref name="height"/> pixels tall, a line every 1.6 heights.</summary>
    private static List<OcrWord> Words(params (string Text, double Height)[] lines)
    {
        var words = new List<OcrWord>();
        var y = 100.0;
        foreach (var (text, height) in lines)
        {
            var x = 120.0;
            foreach (var word in text.Split(' '))
            {
                words.Add(new OcrWord(word, x, y + (word.Length % 3), word.Length * height * 0.55, height)); // a little uneven, as recognized
                x += (word.Length + 1) * height * 0.55;
            }
            y += height * 1.6;
        }
        return words;
    }

    [Fact]
    public void Words_go_back_into_their_lines_in_reading_order()
    {
        var words = Words(("Maple Street Hardware", 60), ("Invoice INV-20931", 30), ("Garden hose 50 ft", 30));
        words.Reverse(); // in any order
        var lines = PageText.Lines(words);
        Assert.Equal(["Maple Street Hardware", "Invoice INV-20931", "Garden hose 50 ft"], lines.Select(l => l.Text));
        Assert.Equal(60, lines[0].Height);
        Assert.Empty(PageText.Lines(null));
        Assert.Empty(PageText.Lines([new OcrWord(" ", 0, 0, 1, 1), new OcrWord("nan", double.NaN, 0, 1, 1), new OcrWord("flat", 0, 0, 1, 0)]));
    }

    [Fact]
    public void An_invoice_gives_its_date_heading_and_number()
    {
        var found = TextFinds.Find(Words(("Maple Street Hardware", 60), ("Invoice INV-20931", 30), ("Date: March 4, 2026", 30), ("Garden hose 50 ft 2 12.50", 30)), Us);
        Assert.Equal(new DateTime(2026, 3, 4), found.Date);
        Assert.Equal("Maple Street Hardware", found.Title);
        Assert.Equal("INV-20931", found.Number);
    }

    [Theory]
    [InlineData("Issued 2026-03-04", "en-US", "2026-03-04")]
    [InlineData("3/4/2026", "en-US", "2026-03-04")]
    [InlineData("3/4/2026", "es-MX", "2026-04-03")]
    [InlineData("25/12/2025", "en-US", "2025-12-25")] // the day is over 12: day first whatever the culture
    [InlineData("12.25.25", "es-MX", "2025-12-25")]
    [InlineData("4 March 2026", "en-US", "2026-03-04")]
    [InlineData("Sept. 30th, 2026", "en-US", "2026-09-30")]
    [InlineData("Fecha: 4 de marzo de 2026", "es-MX", "2026-03-04")]
    [InlineData("Monterrey, 15 ene 2027", "en-US", "2027-01-15")]
    public void Dates_are_read_as_written(string line, string culture, string expected)
    {
        var found = TextFinds.Find(Words((line, 30)), CultureInfo.GetCultureInfo(culture));
        Assert.Equal(DateTime.ParseExact(expected, "yyyy-MM-dd", CultureInfo.InvariantCulture), found.Date);
    }

    [Theory]
    [InlineData("31/02/2026")]
    [InlineData("13/13/2026")]
    [InlineData("Call 555-0142 today")]
    [InlineData("Order 2026 of 3000")]
    [InlineData("Version 1.2.3")]
    public void What_isnt_a_date_isnt_taken_for_one(string line) => Assert.Null(TextFinds.Find(Words((line, 30)), Us).Date);

    [Fact]
    public void A_line_that_says_date_comes_first()
    {
        var found = TextFinds.Find(Words(("Shipped 1/2/2026", 30), ("Invoice date: 1/9/2026", 30)), Us);
        Assert.Equal(new DateTime(2026, 1, 9), found.Date);
    }

    [Theory]
    [InlineData("Order #1042", "1042")]
    [InlineData("Receipt No. A-77813", "A-77813")]
    [InlineData("Factura Nº 0045/2026", "0045/2026")]
    [InlineData("Ref: PO-55120", "PO-55120")]
    [InlineData("Thanks! Your code is ABC-12345", "ABC-12345")]
    public void Numbers_are_found_by_their_label_or_their_shape(string line, string expected) =>
        Assert.Equal(expected, TextFinds.Find(Words(("Header text", 30), (line, 30)), Us).Number);

    [Fact]
    public void No_number_no_heading_no_date_on_a_page_that_doesnt_say()
    {
        var found = TextFinds.Find(Words(("the quick brown fox", 30), ("jumps over no one", 30)), Us);
        Assert.Null(found.Number);
        Assert.Null(found.Date);
        Assert.Equal("the quick brown fox", found.Title); // no heading: the first line
        Assert.Equal(FoundInText.None, TextFinds.Find((IReadOnlyList<OcrWord>?)null, Us));
    }

    [Fact]
    public void A_punch_hole_read_as_a_letter_isnt_part_of_the_heading()
    {
        var words = Words(("Maple Street Hardware", 60), ("Invoice INV-20931", 30));
        words.Add(new OcrWord("O", 10, 100, 30, 60)); // the hole, left of the heading by more than its height
        Assert.Equal("Maple Street Hardware", TextFinds.Find(words, Us).Title);
        Assert.Equal("A Tale of Two Cities", TextFinds.Find(Words(("A Tale of Two Cities", 60), ("Chapter one", 30)), Us).Title); // a word, not a stray
    }

    [Fact]
    public void A_long_heading_is_cut_at_a_word()
    {
        const string heading = "Annual report on the state of the community garden and its many volunteers and friends";
        var title = TextFinds.Find(Words((heading, 30)), Us).Title!;
        Assert.InRange(title.Length, TextFinds.MaxTitle / 2, TextFinds.MaxTitle);
        Assert.StartsWith(title, heading);
        Assert.Equal(' ', heading[title.Length]); // a whole word last
    }

    // ---- The template ----

    private static NameContext Context(FoundInText? found) =>
        new(new DateTime(2026, 11, 22, 9, 30, 0), "Bills", "Office", 7, 2, CultureInfo.InvariantCulture, found);

    [Fact]
    public void The_text_tokens_fill_the_name()
    {
        var found = new FoundInText(new DateTime(2026, 3, 4), "Maple Street Hardware", "INV-20931");
        Assert.Equal("2026-03-04 Maple Street Hardware INV-20931",
            FileNameTemplate.FileName("{text-date} {text-title} {text-number}", Context(found)));
        Assert.Equal("2026-03 Bills", FileNameTemplate.FileName("{text-date:yyyy-MM} {preset}", Context(found)));
        Assert.Equal("Receipts\\2026", FileNameTemplate.Subfolder("Receipts\\{text-date:yyyy}", Context(found)));
        Assert.Equal("Order 0045-2026", FileNameTemplate.FileName("Order {text-number}", Context(found with { Number = "0045/2026" }))); // made safe
    }

    [Fact]
    public void What_the_page_doesnt_say_leaves_no_gap()
    {
        Assert.Equal("Maple - 2026-11-22", FileNameTemplate.FileName("{text-title} - {text-number} - {date}", Context(new FoundInText(null, "Maple", null))));
        Assert.Equal("Bills 7", FileNameTemplate.FileName("{text-date} {preset}  {n}", Context(null)));
        Assert.Equal(CoreStringsFallback(), FileNameTemplate.FileName("{text-title}", Context(FoundInText.None)));
        // Without a text token, a name is as typed.
        Assert.Equal("Bills  7", FileNameTemplate.FileName("{preset}  {n}", Context(null)));
    }

    private static string CoreStringsFallback() => FileNameTemplate.Sanitize("");

    [Fact]
    public void Templates_with_text_tokens_are_fine_and_read_the_page()
    {
        Assert.Null(FileNameTemplate.Problem("{text-date:yyyy-MM-dd} {text-title} {text-number}"));
        Assert.NotNull(FileNameTemplate.Problem("{text-title:upper}"));
        Assert.NotNull(FileNameTemplate.Problem("{text-heading}"));
        Assert.True(FileNameTemplate.ReadsText("Scan {TEXT-DATE}"));
        Assert.False(FileNameTemplate.ReadsText("{preset} {date} {{text-date}}")); // braces doubled: literal text
    }

    [Fact]
    public void A_preset_named_from_its_text_reads_the_text()
    {
        var caps = new ScannerCapabilities("2.6", "Test", null, new InputCaps(0, 2550, 0, 3508, ["RGB24", "Grayscale8"], ["image/jpeg"], [300], ["Document"]), null, false);
        var pdf = new ScanPreset { Id = "p", Name = "Bills", FileType = PresetFileType.Pdf, FileName = "{text-date} {text-title}" };
        Assert.True(PresetPlan.For(pdf, caps, null, ocrAvailable: true, metric: false).Ocr);
        Assert.False(PresetPlan.For(pdf with { FileName = "{preset} {date}" }, caps, null, ocrAvailable: true, metric: false).Ocr);
        var noOcr = PresetPlan.For(pdf, caps, null, ocrAvailable: false, metric: false);
        Assert.False(noOcr.Ocr);
        Assert.Single(noOcr.Notes);
        Assert.True(PresetPlan.For(pdf with { FileName = "{preset}", Subfolder = "{text-date:yyyy}" }, caps, null, ocrAvailable: true, metric: false).Ocr);
    }
}
