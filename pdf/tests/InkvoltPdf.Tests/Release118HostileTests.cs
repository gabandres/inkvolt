using System.Diagnostics;
using System.Text.Json;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Sheets;
using MuPDFCore;
using PdfSharp.Pdf;
using Placement = InkvoltPrint.Core.Printing.Placement;

namespace InkvoltPdf.Tests;

/// <summary>
/// The pre-release hostile-input review of Inkvolt PDF 1.18: an endpoint's answer, a long recording, a page's absurd size,
/// a password that isn't text and a form of thousands of calculated fields each stay bounded and end in words.
/// </summary>
public sealed class Release118HostileTests
{
    private static T Within<T>(Func<T> work, int seconds = 20)
    {
        var task = Task.Run(work);
        Assert.True(task.Wait(TimeSpan.FromSeconds(seconds)), $"Still running after {seconds} s");
        return task.Result;
    }

    private static string Completion(IEnumerable<(string Name, string Args)> calls) => JsonSerializer.Serialize(new
    {
        choices = new[]
        {
            new { index = 0, message = new { role = "assistant", content = (string?)null, tool_calls = calls.Select((c, i) => new { id = $"c{i}", type = "function", function = new { name = c.Name, arguments = c.Args } }) } },
        },
    });

    [Fact]
    public void A_pages_argument_of_millions_of_whole_document_ranges_is_refused_at_once()
    {
        var pages = string.Concat(Enumerable.Repeat("-,", 2_000_000)); // 4M characters, under the 8 MB reply limit
        var json = Completion([("delete_pages", JsonSerializer.Serialize(new { pages })), ("go_to_page", """{"page":2}""")]);
        var plan = Within(() => AskEdit.Parse(json, 10_000));
        Assert.Equal([AskEditKind.GoToPage], plan.Steps.Select(s => s.Kind));
        Assert.Single(plan.Refused);
        Assert.Null(Within(() => AskEdit.Parse(Completion([("rotate_pages", JsonSerializer.Serialize(new { pages = new string('1', AskEdit.MaxPagesChars + 1), degrees = 90 }))]), 10)).Steps.FirstOrDefault());
    }

    [Fact]
    public void Page_ranges_cost_their_length_plus_the_page_count_for_any_caller()
    {
        var text = string.Concat(Enumerable.Repeat("-,", 2_000_000));
        Assert.True(Within(() => (PageRange.TryParse(text, 10_000, out var all, out _), all)) is (true, { Length: 10_000 } p) && p[0] == 0 && p[^1] == 9_999);
        // Overlapping, repeated and out-of-order ranges: each page once, in order.
        Assert.True(PageRange.TryParse("8-, 2-4, 3, 1-2, end, 9", 10, out var pages, out _));
        Assert.Equal([0, 1, 2, 3, 7, 8, 9], pages);
    }

    [Fact]
    public void Past_the_most_calls_read_the_rest_are_left_out_refused_ones_counted()
    {
        var json = Completion(Enumerable.Repeat(("no_such_tool", "{}"), 100_000));
        var plan = Within(() => AskEdit.Parse(json, 10));
        Assert.Empty(plan.Steps);
        Assert.Equal(AskEdit.MaxCalls + 1, plan.Refused.Count);
        Assert.Equal(Loc.Format(PdfStrings.AskEdit_TooManyCalls, AskEdit.MaxCalls), plan.Refused[^1]);
    }

    [Fact]
    public void A_recording_past_one_WAV_files_limit_stops_at_the_part_that_would_pass_it()
    {
        var part = AiAnswerSpeechTests.Wav([1, 2, 3, 4]);
        var parts = new WavParts(TimeSpan.FromMilliseconds(500)); // 8,000 samples of silence between parts
        parts.Add(part);
        parts.Add(part);
        Assert.Equal(8 + 16_000 + 8, parts.DataLength);
        Assert.Equal(parts.DataLength, WavFile.Read(parts.Join()).DataLength);

        // A pause of a day between parts is past 2 GB at the second: refused before it is kept, said in words.
        var long_ = new WavParts(TimeSpan.FromDays(1));
        long_.Add(part);
        var ex = Assert.Throws<WavTooLongException>(() => long_.Add(part));
        Assert.Equal(PdfStrings.Speech_TooLong, ex.Message);
        Assert.Equal(1, long_.Count);
        Assert.Throws<WavTooLongException>(() => WavFile.Join([part, part], TimeSpan.FromDays(1)));
    }

    [Fact]
    public void A_page_of_absurd_size_is_laid_out_bounded_and_rendered_from_the_same_part()
    {
        var huge = new PageGeometry(0, 0, 1.4e7, 7e6); // points: about 3 miles across
        var (w, h) = PrintPageSizes.Of(huge);
        Assert.Equal(SheetPrint.MaxPageSide, w, 6);
        Assert.Equal(SheetPrint.MaxPageSide / 2, h, 6);
        var poster = new PrintPlan([0], _ => PrintPageSizes.Of(huge), new Placement(24, 24, 768, 1008), new PrintSetup { Handling = PrintHandling.Poster, PosterScale = 1 });
        Assert.InRange(poster.SheetCount, 1, 1000); // at its own size: hundreds of millions of tiles

        // A part in the bounded size is that part of the page in its points.
        var whole = PrintPageSizes.Shown(huge, new Placement(0, 0, w, h));
        Assert.Equal(1.4e7, whole.Width, 3);
        Assert.Equal(7e6, whole.Height, 3);
        var tile = poster.Sheet(0).Pages[0].Source!.Value;
        Assert.Equal(tile.Width / w * 1.4e7, PrintPageSizes.Shown(huge, tile).Width, 3);

        // A Letter page is as it was: 816 × 1056 DIPs, a part of it ¾ of its DIPs in points.
        var letter = new PageGeometry(0, 0, 612, 792);
        Assert.Equal((816.0, 1056.0), PrintPageSizes.Of(letter));
        Assert.Equal(new RectD(30, 60, 300, 450), PrintPageSizes.Shown(letter, new Placement(40, 80, 400, 600)));
        Assert.Equal(new RectD(0, 0, 612, 792), PrintPageSizes.Shown(letter, null));
    }

    [Fact]
    public void A_password_with_a_lone_surrogate_is_a_wrong_password()
    {
        // Built here, not as InlineData: xUnit's case serialization turns a lone surrogate into U+FFFD.
        foreach (var password in new[] { "contrase" + (char)0xD800 + "ña", "contraseña" + (char)0xDC00 }) WrongPassword(password);
    }

    private static void WrongPassword(string password)
    {
        var data = PdfSecurity.Protect(Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
        ]), null, "contraseña", "dueño");
        // Not text, so never normalized: where .NET normalizes through NLS rather than ICU, Normalize throws on it.
        Assert.False(PdfEngine.IsText(password));
        Assert.True(PdfEngine.IsText("contraseña\U0001F511"));
        Assert.True(Assert.Throws<PasswordRequiredException>(() => PdfEngine.Open(data, InputFileTypes.PDF, password)).WrongPassword);
        Assert.True(Assert.Throws<PasswordRequiredException>(() => DocumentSession.OpenReadable(data, InputFileTypes.PDF, password)).WrongPassword);
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, "contraseña");
        Assert.Equal(1, engine.PageCount);
    }

    [Fact]
    public void The_calculation_order_of_thousands_of_fields_is_read_in_linear_time()
    {
        const int count = 40_000;
        using var doc = new PdfDocument();
        doc.AddPage();
        var acro = new PdfDictionary(doc);
        doc.Internals.AddObject(acro);
        var fields = new PdfArray(doc);
        var co = new PdfArray(doc);
        for (var i = 0; i < count; i++)
        {
            var c = new PdfDictionary(doc);
            c.Elements["/S"] = new PdfName("/JavaScript");
            c.Elements["/JS"] = new PdfString("event.value = 1;");
            var aa = new PdfDictionary(doc);
            aa.Elements["/C"] = c;
            var f = new PdfDictionary(doc);
            f.Elements["/FT"] = new PdfName("/Tx");
            f.Elements["/T"] = new PdfString($"f{i}");
            f.Elements["/AA"] = aa;
            doc.Internals.AddObject(f);
            fields.Elements.Add(f.Reference!);
            if (i % 2 == 0) co.Elements.Add(f.Reference!); // half in /CO, the other half after it
        }
        acro.Elements["/Fields"] = fields;
        acro.Elements["/CO"] = co;
        doc.Internals.Catalog.Elements["/AcroForm"] = acro.Reference!;
        using var ms = new MemoryStream();
        doc.Save(ms, false);
        var pdf = ms.ToArray();

        var clock = Stopwatch.StartNew();
        var order = Within(() => FormDesign.CalculationOrder(pdf, null), 60);
        Assert.Equal(count, order.Count);
        Assert.Equal(["f0", "f2"], order.Take(2));
        Assert.Equal("f1", order[count / 2]);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(15), $"{clock.Elapsed}");
    }
}
