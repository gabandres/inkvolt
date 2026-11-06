using System.Diagnostics;
using System.Net;
using System.Text.Json;
using InkvoltPdf.Core;
using PdfSharp.Pdf.IO;
using Xunit;

namespace InkvoltPdf.Tests;

/// <summary>
/// Translate keeps a paragraph's bold, italic, subscript and superscript stretches (roadmap 3.1): they go to the model as
/// markup, and the reply's markup, checked, comes back as looks; markup that can't be trusted leaves the paragraph plain.
/// </summary>
public class TranslationLooksTests
{
    private const string Letters = "The quick brown fox jumps over a lazy dog, until the 0123456789 and THE QUICK BROWN FOX JUMPS OVER A LAZY DOG.!";

    private static readonly TextLook B = new(Bold: true);
    private static readonly TextLook I = new(Italic: true);
    private static readonly TextLook Sub = new(Script: TextScript.Sub);
    private static readonly TextLook Sup = new(Script: TextScript.Super);

    private static TextSpan Span(string text, string part, TextLook look)
    {
        var at = text.IndexOf(part, StringComparison.Ordinal);
        Assert.True(at >= 0, part);
        return new TextSpan(at, part.Length, look);
    }

    /// <summary>"The quick brown fox jumps over d_model and the lazy dog.": "brown" in Arial Bold (/FB), "model" smaller and lowered.</summary>
    private static byte[] BoldAndSubscript() => ContentEditPdf.Make(
        "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj /FB 12 Tf (brown) Tj /FA 12 Tf ( fox jumps over d) Tj /FA 8 Tf -2 Ts (model) Tj 0 Ts /FA 12 Tf ( and the lazy dog.) Tj ET",
        faces: true, fontText: Letters);

    private const string Source = "The quick <b>brown</b> fox jumps over d<sub>model</sub> and the lazy dog.";

    private static (TranslationPlan Plan, TranslationResult Result) Translate(byte[] pdf, Func<string, string> translate)
    {
        var plan = Translation.MakePlan(pdf, null, [0]);
        var answers = new TranslationAnswers();
        foreach (var (text, _) in plan.Texts) answers.Done[text] = translate(text);
        return (plan, Translation.Apply(plan, answers, "es"));
    }

    private static List<TextRun> Runs(byte[] pdf) => [.. ContentEditor.Read(pdf, null, 0).Runs.Where(r => r.Text.Trim().Length > 0)];

    // ---- Markup out ----

    [Fact]
    public void A_bold_word_and_a_subscript_go_to_the_model_as_markup()
    {
        var (plan, _) = Translate(BoldAndSubscript(), t => t);
        Assert.Equal(Source, Assert.Single(plan.Texts).Text);
    }

    [Fact]
    public void Looks_are_written_as_nested_tags_in_one_order()
    {
        const string text = "An x2 and a bold italic word, H2O and e=mc2.";
        var spans = new List<TextSpan>
        {
            Span(text, "bold italic", B), Span(text, "italic", new TextLook(Bold: true, Italic: true)),
            new(text.IndexOf("x2", StringComparison.Ordinal), 1, I), new(text.IndexOf("x2", StringComparison.Ordinal) + 1, 1, Sup),
            new(text.IndexOf("H2O", StringComparison.Ordinal) + 1, 1, Sub), new(text.LastIndexOf('2'), 1, new TextLook(Italic: true, Script: TextScript.Super)),
        };
        Assert.Equal("An <i>x</i><sup>2</sup> and a <b>bold <i>italic</i></b> word, H<sub>2</sub>O and e=mc<i><sup>2</sup></i>.", TranslationMarkup.Mark(text, spans));
    }

    [Theory]
    [InlineData("a < b and c")]
    [InlineData("a > b and c")]
    public void Text_with_angle_brackets_of_its_own_goes_without_markup(string text) =>
        Assert.Equal(text, TranslationMarkup.Mark(text, [new TextSpan(0, 1, B)]));

    [Fact]
    public void A_paragraph_with_too_many_looks_goes_plain_quickly()
    {
        var text = string.Join(' ', Enumerable.Repeat("word", 20_000));
        var spans = Enumerable.Range(0, 20_000).Select(i => new TextSpan(i * 5, 4, i % 2 == 0 ? B : I)).ToList();
        var clock = Stopwatch.StartNew();
        Assert.Equal(text, TranslationMarkup.Mark(text, spans));
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(1), $"{clock.Elapsed}");
    }

    [Fact]
    public void A_marked_text_asks_the_model_to_keep_its_tags_and_a_plain_one_doesnt()
    {
        var marked = TranslationText.Request(Source, "Spanish");
        Assert.Contains("<b>", marked[0].Content, StringComparison.Ordinal);
        Assert.Equal(Source, marked[1].Content);
        Assert.DoesNotContain("<b>", TranslationText.Request("The quick brown fox.", "Spanish")[0].Content, StringComparison.Ordinal);
    }

    [Fact]
    public void A_marked_paragraph_too_long_for_one_request_goes_in_plain_pieces()
    {
        var text = string.Join(' ', Enumerable.Repeat("A <b>sentence</b> of the long paragraph goes here.", 200));
        var plan = new TranslationPlan { Data = [], Pages = [], Texts = [(text, 0)] };
        var job = Assert.Single(Translation.Jobs(plan, Translation.PieceTokens(4096)));
        Assert.True(job.Pieces.Count > 1);
        Assert.Equal(text, job.Text);
        Assert.All(job.Pieces, p => Assert.DoesNotContain("<", p, StringComparison.Ordinal));
    }

    [Fact]
    public async Task A_marked_text_cut_off_by_the_models_limit_is_asked_for_in_plain_halves()
    {
        var text = string.Join(' ', Enumerable.Repeat("A <b>sentence</b> of the long paragraph goes here.", 8));
        var sent = new List<string>();
        var handler = new FakeAiHandler((_, b, _) =>
        {
            using var doc = JsonDocument.Parse(b);
            var said = doc.RootElement.GetProperty("messages").EnumerateArray().Last().GetProperty("content").GetString()!;
            sent.Add(said);
            if (said.Length > 300) return Task.FromResult(FakeAiHandler.Json(HttpStatusCode.OK, """{"choices":[{"message":{"content":"Cortado"},"finish_reason":"length"}]}"""));
            return Task.FromResult(FakeAiHandler.Sse(said));
        });
        Assert.True(AiEndpoint.TryParse("http://127.0.0.1:11434/v1", out var ep, out _));
        using var client = new AiClient(ep!, "m", null, handler, new AiTimeouts(TimeSpan.FromSeconds(2), TimeSpan.FromSeconds(5), TimeSpan.FromSeconds(1)));
        var a = await Translation.TranslateAsync([new TranslationJob(text, 0, [text])], "Spanish", (m, t, c) => client.ChatAsync(m, t, c),
            new TranslationSettings { RetryWaits = [TimeSpan.Zero], ReplyDeadline = TimeSpan.FromSeconds(45) });
        Assert.True(sent.Count > 2);
        Assert.All(sent.Skip(1), s => Assert.DoesNotContain("<", s, StringComparison.Ordinal));
        Assert.DoesNotContain("<", a.Done[text], StringComparison.Ordinal);
    }

    [Fact]
    public void A_reply_keeps_the_markup_it_was_sent_and_loses_any_other_tag()
    {
        var (text, problem) = TranslationText.CleanReply("Una <b>palabra</b> <span>y</span> <sub>otra</sub>", "A <b>word</b> and d<sub>another</sub>");
        Assert.Null(problem);
        Assert.Equal("Una <b>palabra</b> y <sub>otra</sub>", text);
    }

    // ---- Markup back ----

    private static readonly string Text = "The quick brown fox jumps over dmodel and the lazy dog.";
    private static readonly List<TextSpan> Looks = [Span(Text, "brown", B), Span(Text, "model", Sub)];

    [Fact]
    public void The_markup_a_model_keeps_comes_back_as_looks()
    {
        var (text, spans) = TranslationMarkup.Read("El zorro <b>marrón</b> salta sobre d<sub>model</sub> y el perro.", Text, Looks);
        Assert.Equal("El zorro marrón salta sobre dmodel y el perro.", text);
        Assert.Equal([Span(text, "marrón", B), Span(text, "model", Sub)], spans);
    }

    [Fact]
    public void Nested_looks_come_back_combined()
    {
        const string text = "An x2 and a bold italic word.";
        List<TextSpan> looks = [Span(text, "bold ", B), Span(text, "italic", new TextLook(Bold: true, Italic: true)), new(3, 1, I), new(4, 1, Sup)];
        var (now, spans) = TranslationMarkup.Read("Una <i>x</i><sup>2</sup> y una palabra <b>negrita <i>cursiva</i></b>.", text, looks);
        Assert.Equal("Una x2 y una palabra negrita cursiva.", now);
        Assert.Equal([new TextSpan(4, 1, I), new TextSpan(5, 1, Sup), Span(now, "negrita ", B), Span(now, "cursiva", new TextLook(Bold: true, Italic: true))], spans);
    }

    [Fact]
    public void A_tag_the_model_dropped_leaves_only_that_stretch_plain()
    {
        var (text, spans) = TranslationMarkup.Read("El zorro marrón salta sobre d<sub>model</sub> y el perro.", Text, Looks);
        Assert.Equal("El zorro marrón salta sobre dmodel y el perro.", text);
        Assert.Equal([Span(text, "model", Sub)], spans);
    }

    [Fact]
    public void An_empty_tag_and_spaces_around_tags_leave_one_space()
    {
        var (text, spans) = TranslationMarkup.Read("El zorro <b> </b> <b>marrón </b> salta.", Text, Looks);
        Assert.Equal("El zorro marrón salta.", text);
        Assert.Equal([Span(text, "marrón ", B)], spans);
    }

    [Theory]
    [InlineData("El zorro <b>marrón salta sobre dmodel y el perro.")] // never closed
    [InlineData("El zorro marrón</b> salta sobre dmodel y el perro.")] // never opened
    [InlineData("El zorro <b>marrón <sub>salta</b> sobre</sub> dmodel.")] // crossed
    [InlineData("El zorro <b><b>marrón</b></b> salta.")] // inside itself
    [InlineData("El <i>zorro</i> marrón salta.")] // invented: the source had no italic
    [InlineData("El zorro marrón salta sobre d<sup>model</sup>.")] // a subscript moved up
    [InlineData("El zorro marrón salta sobre d<sub>mo<sup>d</sup>el</sub>.")] // one inside the other
    [InlineData("<b>El zorro marrón salta sobre dmodel y el perro perezoso, hasta que el perro se cansa.</b>")] // the whole paragraph bold
    [InlineData("El zorro marrón salta sobre d<sub>model y el perro perezoso hasta</sub>.")] // a subscript far longer than it was
    [InlineData("El zorro <span>marrón</span> salta.")] // another tag
    [InlineData("El zorro <b class=x>marrón</b> salta.")] // a tag with more in it
    [InlineData("El zorro <b>marrón</b> salta <b sobre dmodel.")] // a tag cut short
    [InlineData("El zorro <B>marrón</b> salta sobre <sub>dmodel.")]
    public void Markup_that_cant_be_trusted_leaves_the_paragraph_plain_with_no_tag_text(string reply)
    {
        var (text, spans) = TranslationMarkup.Read(reply, Text, Looks);
        Assert.Empty(spans);
        Assert.DoesNotContain("<", text, StringComparison.Ordinal);
        Assert.DoesNotContain(">", text, StringComparison.Ordinal);
        Assert.DoesNotContain("sub", text, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("span", text, StringComparison.Ordinal);
        Assert.DoesNotContain("  ", text, StringComparison.Ordinal);
        Assert.Contains("zorro", text, StringComparison.Ordinal);
    }

    [Fact]
    public void Tags_in_a_reply_to_a_paragraph_sent_without_markup_never_reach_the_page()
    {
        var (text, spans) = TranslationMarkup.Read("El <b>zorro</b> <sub>marrón</sub>.", "The brown fox.", []);
        Assert.Equal("El zorro marrón.", text);
        Assert.Empty(spans);
    }

    [Fact]
    public void A_reply_to_text_with_angle_brackets_of_its_own_is_left_as_it_is()
    {
        var (text, spans) = TranslationMarkup.Read("a < b y <b>c</b>", "a < b and <b>c</b>", []);
        Assert.Equal("a < b y <b>c</b>", text);
        Assert.Empty(spans);
    }

    [Theory]
    [InlineData(0)]
    [InlineData(1)]
    [InlineData(2)]
    public void A_crafted_reply_full_of_tags_is_read_quickly_and_left_plain(int kind)
    {
        var reply = kind switch
        {
            0 => string.Concat(Enumerable.Repeat("<b>", 400_000)) + "zorro",
            1 => string.Concat(Enumerable.Repeat("<b>x</b> ", 200_000)),
            _ => string.Concat(Enumerable.Repeat("<b", 400_000)) + string.Concat(Enumerable.Repeat("</sub>", 100_000)),
        };
        var clock = Stopwatch.StartNew();
        var (text, spans) = TranslationMarkup.Read(reply, Text, Looks);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(2), $"{clock.Elapsed}");
        Assert.Empty(spans);
        Assert.DoesNotContain("<", text, StringComparison.Ordinal);
    }

    // ---- On the page ----

    [Fact]
    public void A_bold_word_and_a_subscript_keep_their_looks_in_the_pages_own_faces()
    {
        var (_, r) = Translate(BoldAndSubscript(), _ => "a <b>brown</b> fox over d<sub>model</sub> and a dog.");
        Assert.Equal(1, r.Report.Translated);
        Assert.Empty(r.Report.Fonts); // the page's own fonts have every letter
        var runs = Runs(r.Data!);
        var bold = Assert.Single(runs, q => q.Text.Contains("brown", StringComparison.Ordinal));
        Assert.True(bold.Bold, bold.FontName);
        Assert.Equal("brown", bold.Text.Trim());
        var plain = runs.First(q => q.Text.Contains("over", StringComparison.Ordinal));
        Assert.False(plain.Bold);
        var sub = Assert.Single(runs, q => q.Text.Trim() == "model");
        Assert.Equal(0.7 * plain.FontSize, sub.FontSize, 1);
        Assert.Equal(plain.Origin.Y + 0.15 * plain.FontSize, sub.Origin.Y, 1); // lower on the page
        var shown = ContentEditPdf.Text(r.Data!);
        Assert.Contains("brown", shown, StringComparison.Ordinal);
        Assert.DoesNotContain("<", shown, StringComparison.Ordinal);
    }

    [Fact]
    public void A_bold_word_and_a_subscript_keep_their_looks_when_the_translation_is_drawn_in_an_installed_font()
    {
        var (_, r) = Translate(BoldAndSubscript(), _ => "El <b>ñandú</b> salta sobre d<sub>model</sub> y el perro.");
        Assert.Equal(1, r.Report.Translated);
        Assert.Contains(r.Report.Fonts, f => f.Contains("Bold", StringComparison.Ordinal));
        var runs = Runs(r.Data!);
        Assert.All(runs, q => Assert.True(q.StandIn, q.FontName)); // one installed family, the bold word in its bold face
        var bold = Assert.Single(runs, q => q.Text.Contains("ñandú", StringComparison.Ordinal));
        var plain = runs.First(q => q.Text.Contains("salta", StringComparison.Ordinal));
        Assert.NotEqual(plain.FontName, bold.FontName); // "arialbd" beside "arial": the bold face of the installed font the rest is in
        Assert.Equal(["Arial", "Arial Bold"], r.Report.Fonts.Order());
        var sub = Assert.Single(runs, q => q.Text.Trim() == "model");
        Assert.Equal(0.7 * plain.FontSize, sub.FontSize, 1);
        Assert.Equal(plain.Origin.Y + 0.15 * plain.FontSize, sub.Origin.Y, 1);
        Assert.Contains("ñandú", ContentEditPdf.Text(r.Data!), StringComparison.Ordinal);
    }

    [Fact]
    public void A_superscript_rises_and_shrinks_on_the_page()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog 2) Tj /FA 8 Tf 4 Ts (10) Tj 0 Ts /FA 12 Tf ( until the dog.) Tj ET",
            fontText: Letters);
        var (plan, r) = Translate(pdf, _ => "THE QUICK FOX 2<sup>10</sup> AND THE DOG.");
        Assert.Equal("The quick brown fox jumps over the lazy dog 2<sup>10</sup> until the dog.", Assert.Single(plan.Texts).Text);
        var runs = Runs(r.Data!);
        var plain = runs.First(q => q.Text.Contains("FOX", StringComparison.Ordinal));
        var sup = Assert.Single(runs, q => q.Text.Trim() == "10");
        Assert.Equal(0.7 * plain.FontSize, sup.FontSize, 1);
        Assert.Equal(plain.Origin.Y - 0.35 * plain.FontSize, sup.Origin.Y, 1); // higher on the page
    }

    [Fact]
    public void A_reply_whose_markup_cant_be_trusted_is_written_plain_with_no_tag_on_the_page()
    {
        var (_, r) = Translate(BoldAndSubscript(), _ => "a <b>brown fox over d<sub>model and a dog.");
        Assert.Equal(1, r.Report.Translated);
        var runs = Runs(r.Data!);
        Assert.All(runs, q => Assert.False(q.Bold, q.Text));
        Assert.All(runs, q => Assert.Equal(12, q.FontSize, 1));
        var shown = ContentEditPdf.Text(r.Data!);
        Assert.Contains("a brown fox over dmodel and a dog.", shown.ReplaceLineEndings(" "), StringComparison.Ordinal);
        Assert.DoesNotContain("<", shown, StringComparison.Ordinal);
    }

    [Fact]
    public void An_answer_the_same_as_the_marked_text_leaves_the_paragraph_as_it_was()
    {
        var pdf = BoldAndSubscript();
        var (_, r) = Translate(pdf, t => t);
        Assert.Equal(0, r.Report.Translated);
        Assert.Equal(1, r.Report.Unchanged);
    }

    [Fact]
    public void Characters_no_font_has_are_left_out_and_the_looks_after_them_stay_on_their_words()
    {
        var (_, r) = Translate(BoldAndSubscript(), _ => "a \U0010FFFD<b>brown</b> fox \U0010FFFD over d<sub>model</sub>.");
        Assert.Equal(1, r.Report.Translated);
        var runs = Runs(r.Data!);
        Assert.Equal("brown", Assert.Single(runs, q => q.Bold).Text.Trim());
        Assert.Equal(0.7 * 12, Assert.Single(runs, q => q.Text.Trim() == "model").FontSize, 1);
    }
}
