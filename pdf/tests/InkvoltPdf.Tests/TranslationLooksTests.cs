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
        Assert.Equal([Source], plan.Marked);
        Assert.True(Assert.Single(Translation.Jobs(plan, Translation.PieceTokens(4096))).Marked);
    }

    [Fact]
    public void A_paragraphs_own_tags_are_not_taken_for_markup()
    {
        const string own = "Write <b> before a bold word and </b> after it.";
        Assert.DoesNotContain("<sup>", TranslationText.Request(own, "Spanish")[0].Content, StringComparison.Ordinal);
        var text = string.Join(' ', Enumerable.Repeat(own, 200));
        var plan = new TranslationPlan { Data = [], Pages = [], Texts = [(text, 0)] };
        var job = Assert.Single(Translation.Jobs(plan, Translation.PieceTokens(4096)));
        Assert.False(job.Marked);
        Assert.True(job.Pieces.Count > 1);
        Assert.All(job.Pieces, p => Assert.Contains("<b>", p, StringComparison.Ordinal));
        Assert.All(Translation.Requests([job], "Spanish"), r => Assert.DoesNotContain("<sup>", r[0].Content, StringComparison.Ordinal));
    }

    [Fact]
    public void A_hyphen_joined_at_a_line_end_leaves_the_bold_stretch_before_it_its_own_letters()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over a lazy dog and the quick fox is ) Tj /FB 12 Tf (respon-) Tj ET " +
            "BT /FA 12 Tf 1 0 0 1 72 686 Tm (sible for the lazy dog and the brown fox.) Tj ET",
            faces: true, fontText: Letters + "-");
        Assert.Equal("The quick brown fox jumps over a lazy dog and the quick fox is <b>respon</b>sible for the lazy dog and the brown fox.",
            Assert.Single(Translation.MakePlan(pdf, null, [0]).Texts).Text);
    }

    [Fact]
    public void Two_superscripts_with_a_letter_between_stay_two_stretches()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over a) Tj /FA 8 Tf 4 Ts (2) Tj 0 Ts /FA 12 Tf (b) Tj /FA 8 Tf 4 Ts (3) Tj 0 Ts /FA 12 Tf ( and the lazy dog.) Tj ET",
            fontText: Letters);
        Assert.Contains("over a<sup>2</sup>b<sup>3</sup> and", Assert.Single(Translation.MakePlan(pdf, null, [0]).Texts).Text, StringComparison.Ordinal);
    }

    [Fact]
    public void Two_bold_words_with_a_plain_letter_between_leave_it_plain()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj /FB 12 Tf (Bold) Tj /FA 12 Tf (x) Tj /FB 12 Tf (Face) Tj /FA 12 Tf ( fox jumps over the lazy dog.) Tj ET",
            faces: true, fontText: Letters);
        Assert.Contains("<b>Bold</b>x<b>Face</b>", Assert.Single(Translation.MakePlan(pdf, null, [0]).Texts).Text, StringComparison.Ordinal);
    }

    [Fact]
    public void Small_words_beside_a_big_raised_name_are_not_taken_for_subscripts()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The man named ) Tj /FA 16 Tf 3 Ts (Bartholomew-Fitzwilliam) Tj 0 Ts /FA 12 Tf ( was born in a) Tj ( small town by) Tj ( the sea.) Tj ET",
            fontText: Letters + "-");
        var text = Assert.Single(Translation.MakePlan(pdf, null, [0]).Texts).Text;
        Assert.DoesNotContain("<", text, StringComparison.Ordinal);
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

    [Fact]
    public void Every_look_at_once_nests_five_deep_and_comes_back()
    {
        const string text = "A word in all of them.";
        var all = new TextLook(Color: 0xFF0000, Bold: true, Italic: true, Script: TextScript.Super, Underline: true);
        List<TextSpan> spans = [Span(text, "word", all)];
        const string marked = "A <b><i><u><span><sup>word</sup></span></u></i></b> in all of them.";
        Assert.Equal(marked, TranslationMarkup.Mark(text, spans));
        var (now, looks) = TranslationMarkup.Read("Una <b><i><u><span><sup>palabra</sup></span></u></i></b> en todas.", text, spans);
        var look = Assert.Single(looks);
        Assert.Equal("palabra", now.Substring(look.Start, look.Length));
        Assert.Equal((true, true, true, TextScript.Super, 0xFF0000), (look.Look.Bold, look.Look.Italic, look.Look.Underline, look.Look.Script, look.Look.Color));
    }

    [Theory]
    [InlineData("a < b and c")] // "< b" would be taken for a piece of a tag
    [InlineData("x <html> and c")]
    [InlineData("x<y and c")]
    [InlineData("a sub> and c")]
    public void Text_with_angle_brackets_that_could_be_read_as_tags_goes_without_markup(string text) =>
        Assert.Equal(text, TranslationMarkup.Mark(text, [new TextSpan(0, 1, B)]));

    [Theory]
    [InlineData("x > y and c", "<b>x</b> > y and c")]
    [InlineData("p < 0.05 and c", "<b>p</b> < 0.05 and c")]
    [InlineData("x -> y and c", "<b>x</b> -> y and c")]
    public void Text_with_angle_brackets_that_read_only_as_text_keeps_its_markup(string text, string marked)
    {
        Assert.Equal(marked, TranslationMarkup.Mark(text, [new TextSpan(0, 1, B)]));
        var answer = marked.Replace("and", "y", StringComparison.Ordinal);
        var (now, spans) = TranslationMarkup.Read(answer, text, [new TextSpan(0, 1, B)]);
        Assert.Equal(text.Replace("and", "y", StringComparison.Ordinal), now);
        Assert.Equal([new TextSpan(0, 1, B)], spans);
    }

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
        var marked = TranslationText.Request(Source, "Spanish", marked: true);
        Assert.Contains("<b>", marked[0].Content, StringComparison.Ordinal);
        Assert.Equal(Source, marked[1].Content);
        Assert.DoesNotContain("<b>", TranslationText.Request("The quick brown fox.", "Spanish")[0].Content, StringComparison.Ordinal);
    }

    [Theory]
    [InlineData("The <b>quick</b> fox.", "<b> (bold)")]
    [InlineData("The <span>red</span> fox and <b>d<sub>model</sub></b>.", "<b> (bold), <span> (another font or color) and <sub> (subscript)")]
    [InlineData("A <font>blue</font>, a <span>red</span> and an <u>underlined</u> word.", "<u> (underlined) and <span>, <font> (each another font or color)")]
    public void A_marked_texts_request_names_only_the_tags_it_has(string text, string named)
    {
        // A real model told of a <font> it wasn't sent wrote <font color="#0000FF"> around a bold label.
        Assert.Equal(named, TranslationMarkup.TagsNamed(text));
        var system = TranslationText.Request(text, "French", marked: true)[0].Content;
        Assert.Contains(named + ":", system, StringComparison.Ordinal);
        foreach (var other in new[] { "<i>", "<mark>", "<sup>" }) Assert.DoesNotContain(other, system, StringComparison.Ordinal);
    }

    [Fact]
    public void A_marked_paragraph_too_long_for_one_request_goes_in_marked_pieces_each_closing_its_tags()
    {
        var text = string.Join(' ', Enumerable.Repeat("A <b>sentence of the long paragraph</b> goes here.", 200));
        var plan = new TranslationPlan { Data = [], Pages = [], Texts = [(text, 0)], Marked = new HashSet<string> { text } };
        var job = Assert.Single(Translation.Jobs(plan, Translation.PieceTokens(4096)));
        Assert.True(job.Pieces.Count > 1);
        Assert.True(job.Marked);
        Assert.Equal(text, job.Text);
        Assert.All(job.Pieces, p => Assert.Equal(p.Split("<b>").Length, p.Split("</b>").Length));
        Assert.Equal(TranslationMarkup.Plain(text), TranslationMarkup.Plain(string.Join(' ', job.Pieces)));
        Assert.All(Translation.Requests([job], "Spanish"), r => Assert.Contains("<b> (bold)", r[0].Content, StringComparison.Ordinal));
    }

    [Fact]
    public void A_marked_paragraphs_pieces_answered_with_their_tags_give_the_whole_its_looks()
    {
        // Every tenth sentence bold, one bold stretch long enough that a piece may end inside it.
        var plain = string.Join(' ', Enumerable.Range(0, 200).Select(i => $"Sentence {i} of the long paragraph goes on and on here."));
        var spans = Enumerable.Range(0, 200).Where(i => i % 10 == 0)
            .Select(i => Span(plain, $"Sentence {i} of the long paragraph goes on and on here.", B)).ToList();
        var text = TranslationMarkup.Mark(plain, spans);
        Assert.NotEqual(plain, text);
        var job = Translation.Jobs(new TranslationPlan { Data = [], Pages = [], Texts = [(text, 0)], Marked = new HashSet<string> { text } }, 200)[0];
        Assert.True(job.Pieces.Count > 3);
        Assert.True(job.Marked);
        var answer = string.Join(' ', job.Pieces.Select(p => p.Replace("goes on", "sigue", StringComparison.Ordinal)));
        var (now, looks) = TranslationMarkup.Read(answer, plain, spans);
        Assert.Equal(plain.Replace("goes on", "sigue", StringComparison.Ordinal), now);
        Assert.Equal(20, looks.Count(l => now.Substring(l.Start, l.Length).StartsWith("Sentence", StringComparison.Ordinal)));
        Assert.All(looks, l => Assert.Equal(B, l.Look));
    }

    [Fact]
    public void A_stretch_cut_by_many_piece_seams_is_one_stretch_again_when_the_answers_are_joined()
    {
        // Sentences 10 to 159 bold: one stretch, cut at each piece's end. Joined as they are, the answer would have far
        // more bold stretches than the paragraph had and be read plain.
        var plain = string.Join(' ', Enumerable.Range(0, 200).Select(i => $"Sentence {i} of the long paragraph goes on and on here."));
        var start = plain.IndexOf("Sentence 10 ", StringComparison.Ordinal);
        var end = plain.IndexOf("Sentence 160 ", StringComparison.Ordinal) - 1;
        List<TextSpan> spans = [new(start, end - start, B)];
        var text = TranslationMarkup.Mark(plain, spans);
        var pieces = TranslationMarkup.Pieces(text, 200)!;
        Assert.True(pieces.Count(p => p.Contains("</b>", StringComparison.Ordinal)) > 4);
        var (now, looks) = TranslationMarkup.Read(TranslationMarkup.Join(pieces), plain, spans);
        Assert.Equal(plain, now);
        Assert.Equal([new TextSpan(start, end - start, B)], looks);
        // A seam joins only tags that close and open the same looks in order.
        Assert.Equal("<b>a</b> <i>b</i>", TranslationMarkup.Join(["<b>a</b>", "<i>b</i>"]));
        Assert.Equal("<b><i>a b</i></b>", TranslationMarkup.Join(["<b><i>a</i></b>", "<b><i>b</i></b>"]));
    }

    [Fact]
    public async Task A_marked_text_cut_off_by_the_models_limit_is_asked_for_in_marked_halves()
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
        var a = await Translation.TranslateAsync([new TranslationJob(text, 0, [text], Marked: true)], "Spanish", (m, t, c) => client.ChatAsync(m, t, c),
            new TranslationSettings { RetryWaits = [TimeSpan.Zero], ReplyDeadline = TimeSpan.FromSeconds(45) });
        Assert.True(sent.Count > 2);
        // Each half carries its tags, closed in it, and the halves' answers joined are the whole's markup.
        Assert.All(sent.Skip(1), s => Assert.Equal(s.Split("<b>").Length, s.Split("</b>").Length));
        Assert.All(sent.Skip(1), s => Assert.Contains("<b>sentence</b>", s, StringComparison.Ordinal));
        Assert.Equal(text, a.Done[text]);
    }

    [Fact]
    public async Task A_marked_text_cut_off_where_no_half_can_close_its_tags_is_asked_for_in_plain_halves()
    {
        // No space anywhere, and as many words as make the half end inside a tag.
        var text = Enumerable.Range(25, 40).Select(n => string.Concat(Enumerable.Repeat("Word<b>bold</b>", n)))
            .First(t => TranslationMarkup.Pieces(t, Math.Max(20, AiText.EstimateTokens(t) / 2)) is null);
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
        var a = await Translation.TranslateAsync([new TranslationJob(text, 0, [text], Marked: true)], "Spanish", (m, t, c) => client.ChatAsync(m, t, c),
            new TranslationSettings { RetryWaits = [TimeSpan.Zero], ReplyDeadline = TimeSpan.FromSeconds(45) });
        Assert.True(sent.Count > 2);
        Assert.All(sent.Skip(1), s => Assert.DoesNotContain("<", s, StringComparison.Ordinal));
        Assert.DoesNotContain("<", a.Done[text], StringComparison.Ordinal);
    }

    [Fact]
    public void A_reply_keeps_the_markup_it_was_sent_and_loses_any_other_tag()
    {
        var (text, problem) = TranslationText.CleanReply("Una <b>palabra</b> <span>y</span> <sub>otra</sub>", "A <b>word</b> and d<sub>another</sub>", marked: true);
        Assert.Null(problem);
        Assert.Equal("Una <b>palabra</b> y <sub>otra</sub>", text);
    }

    [Theory]
    [InlineData("∗ †", false)]
    [InlineData("<b></b><sup>∗ †</sup>", true)]
    public void A_reply_whose_words_are_all_gone_is_not_used(string reply, bool marked)
    {
        var source = marked ? "<b>Aidan N. Gomez</b><sup>∗ †</sup>" : "Aidan N. Gomez ∗ †";
        var (text, problem) = TranslationText.CleanReply(reply, source, marked);
        Assert.Null(text);
        Assert.NotNull(problem);
    }

    [Theory]
    [InlineData("<bold>Información adicional</bold><i>(si aplica)</i>", "<b>Información adicional</b><i>(si aplica)</i>")] // a real model's, Spanish
    [InlineData("<strong>Información</strong> <em>adicional</em>", "<b>Información</b> <i>adicional</i>")]
    [InlineData("Información <em>adicional</em> <sup>2</sup>", "Información <i>adicional</i> 2")] // no <sup> was sent
    public void A_models_own_names_for_bold_and_italic_are_read_as_ours(string reply, string cleaned)
    {
        var (text, problem) = TranslationText.CleanReply(reply, "<b>Additional Information </b><i>(if applicable)</i>", marked: true);
        Assert.Null(problem);
        Assert.Equal(cleaned, text);
    }

    [Theory]
    [InlineData("<Aidan N. Gomez></sup>∗ †", "<b>Aidan N. Gomez</b><sup>∗ †</sup>", "Aidan N. Gomez∗ †")] // a real model's bold name in brackets
    [InlineData("<Décodage :> Le décodeur est composé.", "<b>Decoder:</b> The decoder is composed.", "Décodage : Le décodeur est composé.")]
    [InlineData("<Décodage :> Le décodeur est composé.", "Decoder: The decoder is composed.", "Décodage : Le décodeur est composé.")] // sent without markup
    [InlineData("Voir <Annexe A>, page 3.", "See <b>Annex</b> A, page 3.", "Voir Annexe A, page 3.")] // no space before its comma
    [InlineData("Voir<Annexe A>page 3.", "See <b>Annex</b> A, page 3.", "Voir Annexe A page 3.")] // a space from the letters beside it
    [InlineData("<font color=\"#0000FF\">Informations</font> <bold>en plus</bold><br/>", "<b>More</b> information", "Informations en plus")] // tag-shaped: only the tags go
    public void Words_a_model_put_in_angle_brackets_stay_and_only_tags_go(string reply, string source, string written)
    {
        var marked = source.Contains("<b>", StringComparison.Ordinal);
        var (text, problem) = TranslationText.CleanReply(reply, source, marked);
        Assert.Null(problem);
        var plain = marked ? TranslationMarkup.Plain(source) : source;
        var spans = marked ? new List<TextSpan> { new(0, plain.IndexOf(' ', StringComparison.Ordinal), B) } : [];
        Assert.Equal(written, TranslationMarkup.Read(text!, plain, spans).Text);
    }

    [Fact]
    public void A_quoted_paragraph_all_in_italic_keeps_its_quotes()
    {
        var (text, problem) = TranslationText.CleanReply("\"<i>Hola, amigo mío</i>\"", "<i>\"Hello, my friend\"</i>", marked: true);
        Assert.Null(problem);
        Assert.Equal("\"<i>Hola, amigo mío</i>\"", text);
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

    [Theory]
    [InlineData("El <b>negrita/b> palabra.", "El negrita palabra.")]
    [InlineData("El zorro x /sub> y el perro.", "El zorro x y el perro.")]
    [InlineData("El zorro word i> next.", "El zorro word next.")]
    [InlineData("El zorro <b>marrón</b> salta sobre d<sub>model/SUB > y el perro.", "El zorro marrón salta sobre dmodel y el perro.")]
    [InlineData("El zorro < sup>marrón</b salta.", "El zorro marrón salta.")]
    public void Every_broken_piece_of_our_tags_is_taken_out(string reply, string plain)
    {
        var (text, spans) = TranslationMarkup.Read(reply, Text, Looks);
        Assert.Equal(plain, text);
        Assert.Empty(spans);
    }

    [Fact]
    public void An_arrow_or_a_comparison_in_a_reply_stays_as_text_and_the_looks_are_kept()
    {
        var (text, spans) = TranslationMarkup.Read("El zorro -> <b>marrón</b> salta sobre d<sub>model</sub> y x < y >= 2.", Text, Looks);
        Assert.Equal("El zorro -> marrón salta sobre dmodel y x < y >= 2.", text);
        Assert.Equal([Span(text, "marrón", B), Span(text, "model", Sub)], spans);
    }

    [Theory]
    [InlineData("i > 0")]
    [InlineData("b >= a")]
    [InlineData("i>0 y sub>2")]
    public void A_comparison_after_a_lone_b_or_i_stays_as_text_and_the_looks_are_kept(string comparison)
    {
        var (text, spans) = TranslationMarkup.Read($"El zorro <b>marrón</b> salta sobre d<sub>model</sub> si {comparison}.", Text, Looks);
        Assert.Equal($"El zorro marrón salta sobre dmodel si {comparison}.", text);
        Assert.Equal([Span(text, "marrón", B), Span(text, "model", Sub)], spans);
    }

    [Fact]
    public void An_arrow_in_a_reply_whose_markup_cant_be_trusted_stays_as_text()
    {
        var (text, spans) = TranslationMarkup.Read("El zorro -> <b>marrón salta <span>sobre</span> a <= b.", Text, Looks);
        Assert.Equal("El zorro -> marrón salta sobre a <= b.", text);
        Assert.Empty(spans);
    }

    [Theory]
    [InlineData("El zorro <script>marrón</script> salta.")]
    [InlineData("El zorro <!-- marrón --> salta.")]
    [InlineData("El zorro <b>marrón</b> <a href=x>salta</a>.")]
    public void Another_tag_beside_bare_brackets_still_never_reaches_the_page(string reply)
    {
        var (text, spans) = TranslationMarkup.Read(reply, Text, Looks);
        Assert.Empty(spans);
        Assert.DoesNotContain("<", text, StringComparison.Ordinal);
        Assert.DoesNotContain(">", text, StringComparison.Ordinal);
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
        // This thread's processor time, not the wall's: under the full run's load a linear read took 5 s of the wall
        // (0.2 s alone). Quadratic, it would take hours of processor time.
        var clock = new ThreadClock.Stopwatch();
        clock.Start();
        var (text, spans) = TranslationMarkup.Read(reply, Text, Looks);
        Assert.True(clock.Elapsed < Timing.Limit(TimeSpan.FromSeconds(2)), $"{clock.Elapsed}");
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
        // The page's own subscript: 8 points of 12, 2 points down.
        var sub = Assert.Single(runs, q => q.Text.Trim() == "model");
        Assert.Equal(8.0 / 12 * plain.FontSize, sub.FontSize, 1);
        Assert.Equal(plain.Origin.Y + 2.0 / 12 * plain.FontSize, sub.Origin.Y, 1); // lower on the page
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
        Assert.Equal(8.0 / 12 * plain.FontSize, sub.FontSize, 1);
        Assert.Equal(plain.Origin.Y + 2.0 / 12 * plain.FontSize, sub.Origin.Y, 1);
        Assert.Contains("ñandú", ContentEditPdf.Text(r.Data!), StringComparison.Ordinal);
    }

    [Theory]
    [InlineData(8, 4)]
    [InlineData(6, 5)]
    [InlineData(9, 2)]
    public void A_superscript_rises_and_shrinks_on_the_page_as_much_as_it_did(double size, double rise)
    {
        var pdf = ContentEditPdf.Make(
            $"BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog 2) Tj /FA {size} Tf {rise} Ts (10) Tj 0 Ts /FA 12 Tf ( until the dog.) Tj ET",
            fontText: Letters);
        var (plan, r) = Translate(pdf, _ => "THE QUICK FOX 2<sup>10</sup> AND THE DOG.");
        Assert.Equal("The quick brown fox jumps over the lazy dog 2<sup>10</sup> until the dog.", Assert.Single(plan.Texts).Text);
        var runs = Runs(r.Data!);
        var plain = runs.First(q => q.Text.Contains("FOX", StringComparison.Ordinal));
        var sup = Assert.Single(runs, q => q.Text.Trim() == "10");
        Assert.Equal(size / 12 * plain.FontSize, sup.FontSize, 1);
        Assert.Equal(plain.Origin.Y - rise / 12 * plain.FontSize, sup.Origin.Y, 1); // higher on the page
    }

    [Fact]
    public void A_scripts_rise_is_kept_in_the_ems_the_copy_draws_it_in()
    {
        // The paragraph's size (its first run's, 12) isn't its line's (most of it, 10): a rise of 3 points is kept as 0.25
        // of the paragraph's em, which the copy draws it in, so it is 3 points again (not 0.3 em, 3.6 points).
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 400 Tm (A) Tj /FA 10 Tf ( quick brown fox jumps over the lazy dog 2) Tj /FA 7 Tf 3 Ts (10) Tj 0 Ts /FA 10 Tf ( until the dog.) Tj ET",
            fontText: Letters);
        var (plan, r) = Translate(pdf, _ => "THE QUICK FOX 2<sup>10</sup> AND THE DOG.");
        Assert.Contains("<sup>10</sup>", Assert.Single(plan.Texts).Text, StringComparison.Ordinal);
        var runs = Runs(r.Data!);
        var plain = runs.First(q => q.Text.Contains("FOX", StringComparison.Ordinal));
        var sup = Assert.Single(runs, q => q.Text.Trim() == "10");
        Assert.Equal(10, plain.FontSize, 1); // not shrunk
        Assert.Equal(3, plain.Origin.Y - sup.Origin.Y, 1);
    }

    [Fact]
    public void A_footnote_mark_and_an_exponent_in_one_paragraph_keep_their_own_sizes_and_rises()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 400 Tm (The quick brown fox jumps over the dog) Tj /FA 6 Tf 5 Ts (1) Tj 0 Ts /FA 12 Tf ( and 2) Tj " +
            "/FA 9 Tf 3 Ts (10) Tj 0 Ts /FA 12 Tf ( until the dog.) Tj ET",
            fontText: Letters);
        var (plan, r) = Translate(pdf, _ => "THE FOX OVER THE DOG<sup>1</sup> AND 2<sup>10</sup> UNTIL THE DOG.");
        Assert.Contains("dog<sup>1</sup> and 2<sup>10</sup>", Assert.Single(plan.Texts).Text, StringComparison.Ordinal);
        var runs = Runs(r.Data!);
        var plain = runs.First(q => q.Text.Contains("FOX", StringComparison.Ordinal));
        var mark = Assert.Single(runs, q => q.Text.Trim() == "1");
        var exponent = Assert.Single(runs, q => q.Text.Trim() == "10");
        Assert.Equal(6.0 / 12 * plain.FontSize, mark.FontSize, 1);
        Assert.Equal(9.0 / 12 * plain.FontSize, exponent.FontSize, 1);
        Assert.Equal(5.0 / 12 * plain.FontSize, plain.Origin.Y - mark.Origin.Y, 1);
        Assert.Equal(3.0 / 12 * plain.FontSize, plain.Origin.Y - exponent.Origin.Y, 1);
    }

    [Fact]
    public void A_line_starting_with_a_symbol_goes_on_the_sentence_above()
    {
        // CMSY's "=" or "−" opening a line inside a sentence, set on the line with no gap: not an item of its own.
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog and the quick fox x) Tj ET " +
            "BT /FA 12 Tf 1 0 0 1 64.99 686 Tm (=) Tj (y for the lazy dog and the brown fox jumps over it.) Tj ET",
            fontText: Letters + "=");
        Assert.Single(Translation.MakePlan(pdf, null, [0]).Texts);
    }

    [Fact]
    public void A_crafted_rise_far_off_the_line_is_not_taken_for_its_superscript()
    {
        // 1,000 points up: text of its own somewhere else, left as it is; the line is translated without it.
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 400 Tm (The quick brown fox jumps over the lazy dog 2) Tj /FA 8 Tf 300 Ts (10) Tj 0 Ts /FA 12 Tf ( until the dog.) Tj ET",
            fontText: Letters);
        var (plan, r) = Translate(pdf, _ => "THE QUICK FOX AND THE DOG.");
        Assert.DoesNotContain(plan.Texts, t => t.Text.Contains('<', StringComparison.Ordinal));
        Assert.Equal(1, r.Report.Translated);
        Assert.Single(Runs(r.Data!), q => q.Text.Trim() == "10");
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

    [Theory]
    [InlineData("The quick brown fox jumps over dmodel and the lazy dog.")] // sent in plain pieces, or every tag dropped
    [InlineData("The quick brown fox jumps over d<sub>model</sub> and the lazy dog.")] // one tag dropped
    public void An_answer_the_same_as_the_paragraphs_text_without_its_markup_leaves_it_as_it_was(string answer)
    {
        var (_, r) = Translate(BoldAndSubscript(), _ => answer);
        Assert.Equal(0, r.Report.Translated);
        Assert.Equal(1, r.Report.Unchanged);
        Assert.Equal(0, r.Report.NotTranslated);
        Assert.Empty(r.Report.Flags);
    }

    [Fact]
    public void A_subscript_an_edit_drew_reads_back_as_one_and_stays_one_when_edited_again()
    {
        var (_, r) = Translate(BoldAndSubscript(), _ => "a fox over d<sub>model</sub> and a dog.");
        Assert.Equal(1, r.Report.Translated);
        var q = Assert.Single(ContentEditor.Read(r.Data!, null, 0).Paragraphs, p => p.Text.Contains("dog", StringComparison.Ordinal));
        Assert.Equal("a fox over dmodel and a dog.", q.Text);
        // Its tag keeps the page's own rise (2 points of 12 down), so an edit draws it there again.
        Assert.Equal([Span(q.Text, "model", new TextLook(Script: TextScript.Sub, Rise: -0.17))], q.Spans);

        var edited = ContentEditor.ReplaceParagraph(r.Data!, null, q, "the fox over dmodel and a dog.");
        var runs = Runs(edited);
        var plain = runs.First(x => x.Text.Contains("dog", StringComparison.Ordinal));
        var sub = Assert.Single(runs, x => x.Text.Trim() == "model");
        Assert.Equal(0.7 * plain.FontSize, sub.FontSize, 1);
        Assert.Equal(plain.Origin.Y + 2.0 / 12 * plain.FontSize, sub.Origin.Y, 1);
    }

    [Fact]
    public void A_scripts_rise_in_a_crafted_tag_is_held_to_what_a_scripts_can_be()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 400 Tm (The quick fox over d) Tj /InkvoltLook << /Script /Sub /Rise -100000 >> BDC /FA 8 Tf -2 Ts (model) Tj EMC 0 Ts /FA 12 Tf ( and the dog.) Tj ET",
            fontText: Letters);
        var q = Assert.Single(ContentEditor.Read(pdf, null, 0).Paragraphs);
        Assert.Equal(-0.6, Assert.Single(q.Spans).Look.Rise);
    }

    [Fact]
    public void A_superscript_widens_the_step_to_its_line_by_as_much_as_it_reaches_past_the_line()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog.) Tj 0 -14 Td (The quick brown fox jumps over the lazy dog.) Tj ET",
            fontText: Letters);
        var p = Assert.Single(ContentEditor.Read(pdf, null, 0).Paragraphs);
        var high = new TextLook(Script: TextScript.Super, Rise: 0.6);
        const string text = "The quick brown fox jumps over the lazy dog. A y2 fox.";
        var plain = ContentEditor.LayOut(p, p.Runs, text, [], fit: 1);
        var raised = ContentEditor.LayOut(p, p.Runs, text, [new TextSpan(text.LastIndexOf('2'), 1, high)], fit: 1);
        Assert.Equal(2, plain.Lines.Count);
        Assert.Equal(2, raised.Lines.Count);
        var step = plain.Lines[1].Origin.Y - plain.Lines[0].Origin.Y;
        var room = step - p.Ascent - p.Descent; // the leading between the two lines' own ink
        var top = 0.6 * p.FontSize + ContentEditor.ScriptScale * p.Ascent; // the superscript's top above its baseline
        Assert.True(top - p.Ascent > room, $"{top - p.Ascent} {room}");
        Assert.Equal(step + (top - p.Ascent - room), raised.Lines[1].Origin.Y - raised.Lines[0].Origin.Y, 2);
        // A superscript within the line's height changes nothing; one reaching into the leading, only past it.
        var within = ContentEditor.LayOut(p, p.Runs, text, [new TextSpan(text.LastIndexOf('2'), 1, new TextLook(Script: TextScript.Super, Rise: 0.12))], fit: 1);
        Assert.Equal(step, within.Lines[1].Origin.Y - within.Lines[0].Origin.Y, 2);
        foreach (var rise in new[] { 0.3, ContentEditor.SuperRise, 0.45 })
        {
            var reach = rise * p.FontSize + ContentEditor.ScriptScale * p.Ascent - p.Ascent;
            var low = ContentEditor.LayOut(p, p.Runs, text, [new TextSpan(text.LastIndexOf('2'), 1, new TextLook(Script: TextScript.Super, Rise: rise))], fit: 1);
            Assert.Equal(step + Math.Max(0, reach - room), low.Lines[1].Origin.Y - low.Lines[0].Origin.Y, 2);
        }
    }

    [Fact]
    public void A_superscript_on_the_first_line_and_a_subscript_on_the_last_are_inside_the_checked_box()
    {
        var pdf = ContentEditPdf.Make("BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog.) Tj ET", fontText: Letters);
        var p = Assert.Single(ContentEditor.Read(pdf, null, 0).Paragraphs);
        const string text = "x2 and H2";
        var layout = ContentEditor.LayOut(p, p.Runs, text, [new TextSpan(1, 1, Sup), new TextSpan(8, 1, Sub)], fit: 1);
        var (origin, _) = Assert.Single(layout.Lines);
        var box = layout.Check.Box;
        Assert.True(box.Y <= origin.Y - ContentEditor.SuperRise * p.FontSize - ContentEditor.ScriptScale * p.Ascent + 0.01, $"{box.Y} {origin.Y}");
        Assert.True(box.Bottom >= origin.Y - ContentEditor.SubRise * p.FontSize + ContentEditor.ScriptScale * p.Descent - 0.01, $"{box.Bottom} {origin.Y}");
    }

    [Fact]
    public void Characters_no_font_has_are_left_out_and_the_looks_after_them_stay_on_their_words()
    {
        var (_, r) = Translate(BoldAndSubscript(), _ => "a \U0010FFFD<b>brown</b> fox \U0010FFFD over d<sub>model</sub>.");
        Assert.Equal(1, r.Report.Translated);
        var runs = Runs(r.Data!);
        Assert.Equal("brown", Assert.Single(runs, q => q.Bold).Text.Trim());
        Assert.Equal(8, Assert.Single(runs, q => q.Text.Trim() == "model").FontSize, 1);
    }

    // ---- Looks a bold, italic or script tag doesn't say ----

    /// <summary>The PDF with /FT's font named <paramref name="name"/> (its /BaseFont and its descriptor's /FontName).</summary>
    private static byte[] WithTimesNamed(byte[] pdf, string name)
    {
        using var d = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Modify);
        var fonts = PdfObj.Dict(PdfObj.Dict(d.Pages[0].Elements["/Resources"])!.Elements["/Font"])!;
        var font = PdfObj.Dict(fonts.Elements["/FT"])!;
        font.Elements["/BaseFont"] = new PdfSharp.Pdf.PdfName("/" + name);
        if (PdfObj.Dict(font.Elements["/FontDescriptor"]) is { } fd) fd.Elements["/FontName"] = new PdfSharp.Pdf.PdfName("/" + name);
        using var ms = new MemoryStream();
        d.Save(ms, false);
        return ms.ToArray();
    }

    [Fact]
    public void Arabic_for_a_paragraph_in_Calibri_is_drawn_in_a_font_MuPDF_reads_in_order()
    {
        // Calibri's Arabic lowers letters it joins; MuPDF read such lines on NIST p. 1 backwards. The closest font whose letters stay on the line is taken.
        if (SystemFonts.Get("calibri.ttf") is null) return;
        var pdf = WithTimesNamed(ContentEditPdf.Make("BT /FT 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the dog) Tj ET", faces: true, fontText: Letters), "Calibri");
        const string ar = "القسم المُطبّق للهندسة الأمنية (مختبر التكنولوجيا المعلوماتية)";
        var (_, r) = Translate(pdf, _ => ar);
        Assert.Equal(1, r.Report.Translated);
        static string Solid(string s) => new([.. s.Where(c => !char.IsWhiteSpace(c))]);
        Assert.Contains(Solid(ar), Solid(ContentEditPdf.Text(r.Data!)), StringComparison.Ordinal);
    }

    [Fact]
    public void A_regular_word_in_a_bold_paragraph_goes_with_the_bold_around_it_and_comes_back_regular()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FB 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over ) Tj /FA 12 Tf (the) Tj /FB 12 Tf ( lazy dog and the quick fox.) Tj ET",
            faces: true, fontText: Letters);
        var (plan, r) = Translate(pdf, _ => "<b>El zorro salta sobre </b>el<b> perro y el zorro.</b>");
        Assert.Equal("<b>The quick brown fox jumps over </b>the<b> lazy dog and the quick fox.</b>", Assert.Single(plan.Texts).Text);
        Assert.Equal(1, r.Report.Translated);
        var runs = Runs(r.Data!);
        Assert.Equal("el", Assert.Single(runs, q => !q.Bold).Text.Trim());
        Assert.All(runs.Where(q => q.Text.Contains("zorro", StringComparison.Ordinal)), q => Assert.True(q.Bold, q.Text));
    }

    [Theory]
    [InlineData("El zorro salta sobre el perro y el zorro.")] // every tag dropped: as the paragraph is, bold
    [InlineData("El zorro salta sobre el perro y <b>el zorro</b>.")] // most of its bold dropped: can't be trusted
    public void A_bold_paragraph_whose_reply_lost_its_bold_stays_bold(string answer)
    {
        var pdf = ContentEditPdf.Make(
            "BT /FB 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over ) Tj /FA 12 Tf (the) Tj /FB 12 Tf ( lazy dog and the quick fox.) Tj ET",
            faces: true, fontText: Letters);
        var (_, r) = Translate(pdf, _ => answer);
        Assert.Equal(1, r.Report.Translated);
        Assert.All(Runs(r.Data!), q => Assert.True(q.Bold, q.Text));
    }

    [Fact]
    public void A_word_in_a_font_of_another_class_keeps_it()
    {
        // A name in Times among Arial: no bold or italic says so.
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox named ) Tj /FT 12 Tf (Newton) Tj /FA 12 Tf ( jumps over the lazy dog.) Tj ET",
            faces: true, fontText: Letters + "N");
        var (plan, r) = Translate(pdf, _ => "El zorro llamado <span>Newton</span> salta sobre el perro.");
        Assert.Equal("The quick brown fox named <span>Newton</span> jumps over the lazy dog.", Assert.Single(plan.Texts).Text);
        var runs = Runs(r.Data!);
        var name = Assert.Single(runs, q => q.Text.Contains("Newton", StringComparison.Ordinal));
        Assert.Contains("Times", name.FontName, StringComparison.OrdinalIgnoreCase);
        Assert.Equal("Newton", name.Text.Trim());
        Assert.All(runs.Where(q => q != name), q => Assert.DoesNotContain("Times", q.FontName, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void A_word_in_another_color_keeps_it()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox is ) Tj 1 0 0 rg (red) Tj 0 g ( and jumps over the lazy dog.) Tj ET",
            fontText: Letters);
        var (plan, r) = Translate(pdf, _ => "El zorro es <span>rojo</span> y salta sobre el perro.");
        Assert.Equal("The quick brown fox is <span>red</span> and jumps over the lazy dog.", Assert.Single(plan.Texts).Text);
        var runs = Runs(r.Data!);
        var red = Assert.Single(runs, q => q.Color == 0xFF0000);
        Assert.Equal("rojo", red.Text.Trim());
        Assert.All(runs.Where(q => q != red), q => Assert.Equal(0, q.Color));
    }

    // ---- Plain underlines ----

    private const string UnderlinedLine = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj (brown fox) Tj ( jumps over the lazy dog.) Tj ET";

    /// <summary>The line above with a rule drawn as <paramref name="rule"/> places it: (left, right) of "brown fox", page points; its operators.</summary>
    private static byte[] WithRule(Func<double, double, string> rule)
    {
        var words = Assert.Single(Runs(ContentEditPdf.Make(UnderlinedLine, fontText: Letters)), q => q.Text == "brown fox").Box;
        return ContentEditPdf.Make(UnderlinedLine + " " + rule(words.X, words.Right), fontText: Letters);
    }

    /// <summary>"brown fox" underlined 2 points below the baseline, 0.8 thick, in red.</summary>
    private static byte[] Underlined() => WithRule((l, r) => $"1 0 0 rg {l:0.###} 697.2 {r - l:0.###} 0.8 re f 0 g");

    /// <summary>Each rectangle the page's content fills: x, y (PDF space), width, height.</summary>
    private static List<(double X, double Y, double W, double H)> Filled(byte[] pdf) =>
        [.. System.Text.RegularExpressions.Regex.Matches(ContentEditPdf.Content(pdf), @"(-?[\d.]+) (-?[\d.]+) (-?[\d.]+) (-?[\d.]+) re\s+f")
            .Select(m => (double.Parse(m.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture), double.Parse(m.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture),
                double.Parse(m.Groups[3].Value, System.Globalization.CultureInfo.InvariantCulture), double.Parse(m.Groups[4].Value, System.Globalization.CultureInfo.InvariantCulture)))];

    [Fact]
    public void An_underline_drawn_under_some_words_goes_to_the_model_as_markup()
    {
        var (plan, _) = Translate(Underlined(), t => t);
        Assert.Equal("The quick <u>brown fox</u> jumps over the lazy dog.", Assert.Single(plan.Texts).Text);
    }

    [Fact]
    public void An_underline_is_drawn_again_under_the_words_the_answer_underlines_and_the_old_one_goes()
    {
        var (_, r) = Translate(Underlined(), _ => "El zorro <u>marron rapido</u> salta sobre el perro.");
        Assert.Equal(1, r.Report.Translated);
        var words = Assert.Single(Runs(r.Data!), q => q.Text.Contains("marron", StringComparison.Ordinal));
        Assert.Equal("marron rapido", words.Text.Trim());
        var (x, y, w, h) = Assert.Single(Filled(r.Data!)); // the old rule's operator paints nothing now
        Assert.Equal(words.Box.X, x, 0.5);
        Assert.Equal(words.Box.Right, x + w, 1.0);
        Assert.Equal(0.8, h, 0.01);
        Assert.Equal(792 - words.Origin.Y - 2, y + h, 0.05); // 2 points below the baseline, as it was
        Assert.Contains("1 0 0 rg", ContentEditPdf.Content(r.Data!)[^80..], StringComparison.Ordinal); // in its red
        Assert.DoesNotContain("<u>", ContentEditPdf.Text(r.Data!), StringComparison.Ordinal);
    }

    [Fact]
    public void An_underline_the_answer_dropped_is_taken_off_and_not_drawn_again()
    {
        var (_, r) = Translate(Underlined(), _ => "El zorro marron rapido salta sobre el perro.");
        Assert.Equal(1, r.Report.Translated);
        Assert.Empty(Filled(r.Data!));
    }

    [Theory]
    [InlineData("strike")] // through the words
    [InlineData("field")] // a line running on past the words, to be written on
    [InlineData("rule")] // a table's rule, much wider than the words over it
    [InlineData("thick")] // a band, not a line
    public void A_rule_that_isnt_an_underline_is_no_look_and_stays(string kind)
    {
        var pdf = WithRule((l, r) => kind switch
        {
            "strike" => $"{l:0.###} 703 {r - l:0.###} 0.8 re f",
            "field" => $"{l:0.###} 697.2 {r - l + 400:0.###} 0.8 re f",
            "rule" => $"40 697.2 520 0.8 re f",
            _ => $"{l:0.###} 690 {r - l:0.###} 8 re f",
        });
        var (plan, r) = Translate(pdf, _ => "El zorro <u>marron rapido</u> salta sobre el perro.");
        Assert.DoesNotContain("<u>", Assert.Single(plan.Texts).Text, StringComparison.Ordinal);
        Assert.Single(Filled(r.Data!)); // as it was
    }

    [Fact]
    public void A_links_underline_is_the_links_not_a_plain_one()
    {
        var pdf = Underlined();
        var words = Assert.Single(Runs(pdf), q => q.Text == "brown fox").Box;
        using (var d = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Modify))
        {
            var link = new PdfSharp.Pdf.PdfDictionary(d);
            link.Elements["/Type"] = new PdfSharp.Pdf.PdfName("/Annot");
            link.Elements["/Subtype"] = new PdfSharp.Pdf.PdfName("/Link");
            link.Elements["/Rect"] = PdfObj.Reals(d, words.X, 792 - words.Bottom - 3, words.Right, 792 - words.Y);
            d.Internals.AddObject(link);
            var annots = new PdfSharp.Pdf.PdfArray(d);
            annots.Elements.Add(link.Reference!);
            d.Pages[0].Elements["/Annots"] = annots;
            using var ms = new MemoryStream();
            d.Save(ms, false);
            pdf = ms.ToArray();
        }
        var (plan, _) = Translate(pdf, t => t);
        Assert.Equal("The quick brown fox jumps over the lazy dog.", Assert.Single(plan.Texts).Text);
    }

    [Fact]
    public void Two_other_looks_are_marked_apart_and_each_comes_back_as_its_own()
    {
        const string text = "A red word and a blue one.";
        List<TextSpan> spans = [Span(text, "red", new TextLook(Color: 0xFF0000)), Span(text, "blue", new TextLook(Color: 0x0000FF)), Span(text, "one", new TextLook(Color: 0x0000FF, Bold: true))];
        Assert.Equal("A <span>red</span> word and a <font>blue</font> <b><font>one</font></b>.", TranslationMarkup.Mark(text, spans)); // "one" is blue too
        var (now, looks) = TranslationMarkup.Read("Una palabra <span>roja</span> y una <font>azul</font>.", text, spans);
        Assert.Equal([Span(now, "roja", new TextLook(Color: 0xFF0000)), Span(now, "azul", new TextLook(Color: 0x0000FF))], looks);
    }

    [Fact]
    public void Three_other_looks_are_marked_and_a_fourth_keeps_only_its_bold()
    {
        const string text = "A red, a green, a blue and a gray word.";
        List<TextSpan> spans =
        [
            Span(text, "red", new TextLook(Color: 0xFF0000)), Span(text, "green", new TextLook(Font: "Courier New")),
            Span(text, "blue", new TextLook(Color: 0x0000FF)), Span(text, "gray", new TextLook(Color: 0x808080, Bold: true)),
        ];
        Assert.Equal("A <span>red</span>, a <font>green</font>, a <mark>blue</mark> and a <b>gray</b> word.", TranslationMarkup.Mark(text, spans));
        var (now, looks) = TranslationMarkup.Read("Un <mark>azul</mark>, un <span>rojo</span> y un <font>verde</font>.", text, spans);
        Assert.Equal([Span(now, "azul", new TextLook(Color: 0x0000FF)), Span(now, "rojo", new TextLook(Color: 0xFF0000)), Span(now, "verde", new TextLook(Font: "Courier New"))], looks);
    }

    [Theory]
    [InlineData("Una <span>roja <font>y</font></span> azul.")] // one other look inside another
    [InlineData("Una <font>roja</font> y <font>azul</font> y <font>gris</font> y <font>verde</font>.")] // far more than it had
    [InlineData("Una <mark>roja</mark>.")] // one it didn't have
    public void Other_looks_a_reply_garbles_leave_it_plain(string reply)
    {
        const string text = "A red word and a blue one.";
        List<TextSpan> spans = [Span(text, "red", new TextLook(Color: 0xFF0000)), Span(text, "blue", new TextLook(Color: 0x0000FF))];
        var (now, looks) = TranslationMarkup.Read(reply, text, spans);
        Assert.Empty(looks);
        Assert.DoesNotContain("<", now, StringComparison.Ordinal);
    }

    [Fact]
    public void A_bold_word_a_red_word_and_a_word_in_another_font_keep_all_three_looks_on_the_page()
    {
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick ) Tj /FB 12 Tf (brown) Tj /FA 12 Tf ( fox is ) Tj 1 0 0 rg (red) Tj 0 g ( and named ) Tj /FT 12 Tf (Newton) Tj /FA 12 Tf ( over the lazy dog.) Tj ET",
            faces: true, fontText: Letters + "N");
        var (plan, r) = Translate(pdf, _ => "El <b>zorro</b> es <span>rojo</span> y se llama <font>Newton</font> sobre el perro.");
        Assert.Equal("The quick <b>brown</b> fox is <span>red</span> and named <font>Newton</font> over the lazy dog.", Assert.Single(plan.Texts).Text);
        var runs = Runs(r.Data!);
        Assert.True(Assert.Single(runs, q => q.Text.Contains("zorro", StringComparison.Ordinal)).Bold);
        Assert.Equal("rojo", Assert.Single(runs, q => q.Color == 0xFF0000).Text.Trim());
        var name = Assert.Single(runs, q => q.Text.Contains("Newton", StringComparison.Ordinal));
        Assert.Contains("Times", name.FontName, StringComparison.OrdinalIgnoreCase);
        Assert.Equal(0, name.Color);
        Assert.All(runs.Where(q => q != name), q => Assert.DoesNotContain("Times", q.FontName, StringComparison.OrdinalIgnoreCase));
    }

    [Fact]
    public void A_paragraph_with_more_than_64_looks_keeps_its_scripts()
    {
        var text = string.Join(' ', Enumerable.Repeat("word", 80)) + " x2 and H2O";
        var spans = Enumerable.Range(0, 80).Select(i => new TextSpan(i * 5, 4, B)).ToList();
        spans.Add(new TextSpan(text.IndexOf("x2", StringComparison.Ordinal) + 1, 1, Sup));
        spans.Add(new TextSpan(text.IndexOf("H2O", StringComparison.Ordinal) + 1, 1, Sub));
        var marked = TranslationMarkup.Mark(text, spans);
        Assert.EndsWith("x<sup>2</sup> and H<sub>2</sub>O", marked, StringComparison.Ordinal);
        Assert.DoesNotContain("<b>", marked, StringComparison.Ordinal);
        var (_, looks) = TranslationMarkup.Read(marked.Replace("and", "y", StringComparison.Ordinal), text, spans);
        Assert.Equal([TextScript.Super, TextScript.Sub], looks.Select(l => l.Look.Script!.Value));
    }

    [Fact]
    public void A_longer_script_on_a_band_of_its_own_joins_the_line_it_sits_on()
    {
        const string line = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog) Tj ET";
        var right = Assert.Single(ContentEditor.Read(ContentEditPdf.Make(line, fontText: Letters + "[]-"), null, 0).Paragraphs).Box.Right;
        var pdf = ContentEditPdf.Make(
            line + $" BT /FA 8 Tf 1 0 0 1 {right + 0.5:0.##} 704 Tm ([12-15]) Tj ET",
            fontText: Letters + "[]-");
        var (plan, r) = Translate(pdf, _ => "El zorro salta sobre el perro<sup>[12-15]</sup>");
        Assert.Equal("The quick brown fox jumps over the lazy dog<sup>[12-15]</sup>", Assert.Single(plan.Texts).Text);
        var runs = Runs(r.Data!);
        var mark = Assert.Single(runs, q => q.Text.Trim() == "[12-15]");
        var plain = runs.First(q => q.Text.Contains("perro", StringComparison.Ordinal));
        Assert.Equal(8, mark.FontSize, 1);
        Assert.True(mark.Origin.Y < plain.Origin.Y - 2, $"{mark.Origin.Y} {plain.Origin.Y}");
    }

    [Theory]
    [InlineData("The quick brown fox jumps over the lazy dog")]
    [InlineData("The lazy dog")] // a line shorter than its script
    public void A_script_longer_than_twelve_characters_joins_the_line_it_sits_on_whole(string words)
    {
        const string script = "[3, 7, 12, 18-24, 31, 40]";
        var line = $"BT /FA 12 Tf 1 0 0 1 72 700 Tm ({words}) Tj ET";
        var right = Assert.Single(ContentEditor.Read(ContentEditPdf.Make(line, fontText: Letters + "[]-"), null, 0).Paragraphs).Box.Right;
        var pdf = ContentEditPdf.Make(line + $" BT /FA 7 Tf 1 0 0 1 {right + 0.5:0.##} 704.5 Tm ({script}) Tj ET", fontText: Letters + "[]-");
        var (plan, r) = Translate(pdf, _ => $"El perro <sup>{script}</sup>");
        Assert.Equal($"{words}<sup>{script}</sup>", Assert.Single(plan.Texts).Text);
        var runs = Runs(r.Data!);
        var mark = Assert.Single(runs, q => q.Text.Contains("[3", StringComparison.Ordinal));
        Assert.Equal(script, mark.Text.Trim()); // whole
        Assert.Equal(7, mark.FontSize, 1);
        var plain = runs.First(q => q.Text.Contains("perro", StringComparison.Ordinal));
        Assert.True(mark.Origin.Y < plain.Origin.Y - 3, $"{mark.Origin.Y} {plain.Origin.Y}");
    }

    [Fact]
    public void A_line_hosting_a_long_script_is_not_also_joined_to_another_line_as_one()
    {
        // A big line, a smaller one raised after its end, and a long script raised after that one: the middle line hosts the
        // script and could itself be the big line's script; joined both ways, its words would be sent and written twice.
        const string big = "BT /FA 20 Tf 1 0 0 1 72 700 Tm (THE QUICK BROWN FOX) Tj ET";
        var right = Assert.Single(ContentEditor.Read(ContentEditPdf.Make(big, fontText: Letters + "[]-"), null, 0).Paragraphs).Box.Right;
        var middle = $"BT /FA 12 Tf 1 0 0 1 {right + 2:0.##} 706 Tm (The lazy dog) Tj ET";
        var middleRight = ContentEditor.Read(ContentEditPdf.Make(big + " " + middle, fontText: Letters + "[]-"), null, 0).Runs.Single(r => r.Text == "The lazy dog").Box.Right;
        var pdf = ContentEditPdf.Make(big + " " + middle + $" BT /FA 7 Tf 1 0 0 1 {middleRight + 0.5:0.##} 710 Tm ([3, 7, 12, 18-24, 31, 40]) Tj ET", fontText: Letters + "[]-");
        var all = string.Concat(Translation.MakePlan(pdf, null, [0]).Texts.Select(t => t.Text));
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(all, "lazy dog"));
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(all, @"\[3, 7"));
    }

    [Fact]
    public void Thousands_of_rules_under_a_crowded_baseline_are_looked_at_quickly()
    {
        // 4,000 thin rectangles, each under 20,000 runs on one baseline: the look for underlines gives up, it doesn't compare them all.
        var content = new System.Text.StringBuilder("BT /FA 1 Tf 1 0 0 1 10 700 Tm ");
        for (var i = 0; i < 20_000; i++) content.Append("(ab) Tj ");
        content.Append("ET 0 g ");
        for (var i = 0; i < 4_000; i++) content.Append(System.FormattableString.Invariant($"{10 + i * 0.1} 699.8 5 0.1 re f "));
        var pdf = ContentEditPdf.Make(content.ToString(), fontText: Letters);
        using var doc = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Import);
        var clock = Stopwatch.StartNew();
        ContentEditor.ReadRaw(doc.Pages[0], 0, default);
        Assert.True(clock.Elapsed < TimeSpan.FromSeconds(10), $"{clock.Elapsed}");
    }

    [Fact]
    public void A_rule_under_two_paragraphs_stays_under_the_one_not_written()
    {
        // "The quick brown fox" and, a column's gap on, "jumps over the dog", one rule under both; only the first is translated.
        const string line = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox) Tj 1 0 0 1 200 700 Tm (jumps over the dog) Tj ET";
        var runs = Runs(ContentEditPdf.Make(line, fontText: Letters));
        var second = Assert.Single(runs, q => q.Text.StartsWith("jumps", StringComparison.Ordinal)).Box;
        var pdf = ContentEditPdf.Make(line + System.FormattableString.Invariant($" 0 0 1 rg 72 697.2 {second.Right - 72:0.###} 0.8 re f 0 g"), fontText: Letters);
        var (plan, r) = Translate(pdf, t => t.Contains("quick", StringComparison.Ordinal) ? "<u>El zorro marron rapido</u>" : t);
        Assert.Equal(2, plan.Texts.Count);
        Assert.All(plan.Texts, t => Assert.StartsWith("<u>", t.Text, StringComparison.Ordinal));
        Assert.Equal(1, r.Report.Translated);
        var rules = Filled(r.Data!);
        Assert.Equal(2, rules.Count); // the one under the translation and what is left of the old one
        Assert.Contains(rules, q => Math.Abs(q.X - second.X) < 1 && Math.Abs(q.X + q.W - second.Right) < 1 && Math.Abs(q.Y - 697.2) < 0.01);
        var words = Assert.Single(Runs(r.Data!), q => q.Text.Contains("marron", StringComparison.Ordinal));
        Assert.Contains(rules, q => Math.Abs(q.X - words.Box.X) < 1);
    }

    [Fact]
    public void Long_small_text_over_a_lines_words_is_not_taken_for_its_script()
    {
        // Smaller and raised, but across the line's words: a note set beside it, not a script.
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog) Tj ET BT /FA 7 Tf 1 0 0 1 120 704.5 Tm (until the 0123456789 and the dog) Tj ET",
            fontText: Letters);
        Assert.DoesNotContain(Translation.MakePlan(pdf, null, [0]).Texts, t => t.Text.Contains("<sup>", StringComparison.Ordinal));
    }

    [Fact]
    public void A_mark_on_a_longer_script_on_a_band_of_its_own_is_read_once()
    {
        const string line = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog) Tj ET";
        var right = Assert.Single(ContentEditor.Read(ContentEditPdf.Make(line, fontText: Letters + "[]-*"), null, 0).Paragraphs).Box.Right;
        var pdf = ContentEditPdf.Make(
            line + $" BT /FA 8 Tf 1 0 0 1 {right + 0.5:0.##} 704 Tm ([12-15]) Tj ET BT /FA 6 Tf 1 0 0 1 {right + 26:0.##} 707 Tm (*) Tj ET",
            fontText: Letters + "[]-*");
        var all = string.Concat(Translation.MakePlan(pdf, null, [0]).Texts.Select(t => t.Text));
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(all, @"\[12-15\]"));
        Assert.Single(System.Text.RegularExpressions.Regex.Matches(all, @"brown fox"));
    }

    [Fact]
    public void Two_footnotes_each_starting_with_its_number_are_two_paragraphs()
    {
        // attn's "†Work performed while at Google Brain." over "‡Work performed while at Google Research.": a real
        // model's copy wrote both as one, the second mark left in the middle of the new lines.
        var pdf = ContentEditPdf.Make(
            "BT /FA 6 Tf 1 0 0 1 72 103 Tm (1) Tj /FA 9 Tf (The quick brown fox jumps over the lazy dog.) Tj ET " +
            "BT /FA 6 Tf 1 0 0 1 72 92 Tm (2) Tj /FA 9 Tf (The lazy dog jumps over the quick brown fox.) Tj ET",
            fontText: Letters);
        var texts = Translation.MakePlan(pdf, null, [0]).Texts.Select(t => t.Text).ToList();
        Assert.Equal(["The quick brown fox jumps over the lazy dog.", "The lazy dog jumps over the quick brown fox."], texts);
    }

    [Fact]
    public void Two_footnotes_each_after_its_raised_mark_are_two_paragraphs()
    {
        // As attn's: each mark smaller, raised on a band of its own, just before its line.
        var pdf = ContentEditPdf.Make(
            "BT /FA 6 Tf 1 0 0 1 72 106.8 Tm (1) Tj ET BT /FA 9 Tf 1 0 0 1 76 103 Tm (The quick brown fox jumps over the lazy dog.) Tj ET " +
            "BT /FA 6 Tf 1 0 0 1 72 95.8 Tm (2) Tj ET BT /FA 9 Tf 1 0 0 1 76 92 Tm (The lazy dog jumps over the quick brown fox.) Tj ET",
            fontText: Letters);
        var (plan, r) = Translate(pdf, t => t.Replace("The", "EL", StringComparison.Ordinal));
        Assert.Equal(["The quick brown fox jumps over the lazy dog.", "The lazy dog jumps over the quick brown fox."], plan.Texts.Select(t => t.Text));
        Assert.Equal(2, r.Report.Translated);
        Assert.All(Runs(r.Data!).Where(q => q.Text.Trim() is "1" or "2"), q => Assert.Equal(6, q.FontSize, 1)); // the marks stay
    }

    [Fact]
    public void A_new_line_is_not_written_in_a_line_end_hyphens_own_tagged_piece()
    {
        // census-p60 p. 7: each line-end hyphen is a tagged piece of its own whose /ActualText is a soft hyphen, and a new
        // line written in it read as "­" in MuPDF.
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm /P <</MCID 1>> BDC (The quick brown fox jumps over the lazy dog and the quick fox is respon) Tj EMC " +
            "/Span <</MCID 2>> BDC (-) Tj EMC ET BT /FA 12 Tf 1 0 0 1 72 686 Tm /P <</MCID 3>> BDC (sible for the lazy dog and the brown fox.) Tj EMC ET",
            fontText: Letters + "-");
        var (_, r) = Translate(pdf, _ => "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG AND THE QUICK FOX IS THE ONE FOR THE LAZY DOG AND THE BROWN FOX.");
        Assert.Equal(1, r.Report.Translated);
        var content = ContentEditPdf.Content(r.Data!);
        var at = content.IndexOf("/MCID 2", StringComparison.Ordinal);
        var piece = content[at..content.IndexOf("EMC", at, StringComparison.Ordinal)];
        Assert.DoesNotContain(" Tm", piece, StringComparison.Ordinal);
    }

    [Fact]
    public void A_new_line_goes_after_a_band_painted_between_a_lines_word_and_its_hyphen()
    {
        // Something painted over the line after its words and before its hyphen: what the line draws last still takes it.
        const string first = "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog and the quick fox is respon) Tj ET";
        var right = Assert.Single(ContentEditor.Read(ContentEditPdf.Make(first, fontText: Letters + "-"), null, 0).Paragraphs).Box.Right;
        var pdf = ContentEditPdf.Make(
            first + $" 1 1 0.9 rg 60 696 500 14 re f 0 g BT /FA 12 Tf 1 0 0 1 {right:0.##} 700 Tm (-) Tj ET " +
            "BT /FA 12 Tf 1 0 0 1 72 686 Tm (sible for the lazy dog and the brown fox.) Tj ET",
            fontText: Letters + "-");
        var (_, r) = Translate(pdf, _ => "THE QUICK BROWN FOX JUMPS OVER THE LAZY DOG AND THE QUICK FOX IS THE ONE FOR THE LAZY DOG AND THE BROWN FOX.");
        Assert.Equal(1, r.Report.Translated);
        // No new text (a TJ with a string in it) before the band; a removed run's own TJ only moves the text position.
        var content = ContentEditPdf.Content(r.Data!);
        Assert.DoesNotMatch(@"\[[^\]]*[(<]", content[..content.IndexOf("re f", StringComparison.Ordinal)]);
        Assert.Matches(@"\[[^\]]*[(<]", content[content.IndexOf("re f", StringComparison.Ordinal)..]);
    }

    [Fact]
    public void A_line_of_small_text_beside_a_line_is_not_taken_for_its_script()
    {
        // Longer than a mark and hardly smaller than the line it sits on: not a script.
        var pdf = ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick brown fox jumps over the lazy dog) Tj ET BT /FA 11 Tf 1 0 0 1 150 703 Tm (jumps over) Tj ET",
            fontText: Letters);
        Assert.DoesNotContain(Translation.MakePlan(pdf, null, [0]).Texts, t => t.Text.Contains("<sup>", StringComparison.Ordinal));
    }

    [Theory]
    [InlineData("NimbusRomNo9L-Medi", true, false)]
    [InlineData("ABCDEF+NimbusRomNo9L-MediItal", true, true)]
    [InlineData("NimbusRomNo9L-ReguItal", false, true)]
    [InlineData("NimbusRomNo9L-Regu", false, false)]
    [InlineData("MinionPro-It", false, true)]
    [InlineData("MinionPro-BoldIt", true, true)]
    [InlineData("ABCDEF+CMMI10", false, true)]
    [InlineData("CMTI12", false, true)]
    [InlineData("CMBX10", true, false)]
    [InlineData("CMR10", false, false)]
    [InlineData("CMSY10", false, false)]
    [InlineData("Gotham-Medium", false, false)]
    [InlineData("Digital-Regular", false, false)]
    [InlineData("Seven-Digital", false, false)]
    [InlineData("Trajan-Capital", false, false)]
    [InlineData("Space-Orbital", false, false)]
    [InlineData("Wild-Bandit", false, false)]
    [InlineData("Garamond-SemiBoldItal", true, true)]
    public void Font_names_that_say_bold_or_italic(string name, bool bold, bool italic)
    {
        Assert.Equal(bold, FontNames.LooksBold(name));
        Assert.Equal(italic, FontNames.LooksItalic(name));
    }

    [Fact]
    public void A_math_italic_letter_goes_as_italic()
    {
        // LaTeX's "d" of "d_model" in CMMI beside the text's roman.
        var pdf = WithTimesNamed(ContentEditPdf.Make(
            "BT /FA 12 Tf 1 0 0 1 72 700 Tm (The quick fox jumps over ) Tj /FT 12 Tf (d) Tj /FA 12 Tf ( and the lazy dog.) Tj ET",
            faces: true, fontText: Letters), "ABCDEF+CMMI10");
        Assert.Contains("over <i>d</i> and", Assert.Single(Translation.MakePlan(pdf, null, [0]).Texts).Text, StringComparison.Ordinal);
    }

    [Fact]
    public void A_title_in_NimbusRomNo9L_Medi_is_written_in_a_bold_installed_font()
    {
        // The section titles of LaTeX papers set in Times: the subset lacks the translation's letters.
        var pdf = WithTimesNamed(ContentEditPdf.Make("BT /FT 12 Tf 1 0 0 1 72 700 Tm (The Quick Brown Fox) Tj ET", faces: true, fontText: Letters), "NimbusRomNo9L-Medi");
        var (_, r) = Translate(pdf, _ => "El ñandú marrón");
        Assert.Equal(1, r.Report.Translated);
        Assert.Equal(["Times New Roman Bold"], r.Report.Fonts);
        Assert.All(Runs(r.Data!), q => Assert.Equal("timesbd", q.FontName));
    }
}
