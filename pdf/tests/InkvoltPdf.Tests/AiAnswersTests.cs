using System.IO.Compression;
using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>Roadmap 4.20: the conversation kept with the document's session, and an answer saved to Word, a PDF or a comment.</summary>
public class AiAnswersTests
{
    private static readonly DateTimeOffset When = new(2026, 11, 20, 14, 30, 0, TimeSpan.Zero);

    private static AiExchange Summary() => new(AiAnswerKind.Summary, "Summarize pages 1–3", "Summarize pages 1–3",
        "## Overview\nThe lease runs **two years** [p. 2].\n\n- Rent is due monthly [p. 3]\n* Deposit: one month\n1. Sign by Friday", "llama3.2", When);

    private static AiExchange Question() => new(AiAnswerKind.Answer, "Who pays repairs?", "Who pays repairs?",
        "The landlord pays structural repairs [p. 5], the tenant minor ones.", "qwen3:8b", When);

    [Fact]
    public void TheConversation_KeepsEachAnswer_AndSendsThemAsTurns()
    {
        var c = new AiConversation();
        c.Add(Summary());
        c.Add(Question() with { Asked = "Who pays for repairs? (asked in English)" });
        Assert.Equal(2, c.Exchanges.Count);
        Assert.Equal(["Summarize pages 1–3", "Who pays for repairs? (asked in English)"], c.Turns.Select(t => t.Question));
        Assert.Equal(Question().Answer, c.Turns[1].Answer);
        for (var i = 0; i < AiConversation.MaxExchanges + 5; i++) c.Add(Question());
        Assert.Equal(AiConversation.MaxExchanges, c.Exchanges.Count);
        c.Clear();
        Assert.Empty(c.Turns);
    }

    [Fact]
    public void ADocumentSessionKeepsItsConversation()
    {
        using var session = DocumentSession.FromBytes(TestPdf.Make(1), "a.pdf");
        Assert.Empty(session.AiConversation.Exchanges);
        session.AiConversation.Add(Question());
        Assert.Same(session.AiConversation, session.AiConversation);
        Assert.Single(session.AiConversation.Exchanges);
    }

    [Fact]
    public void AComment_GoesOnTheFirstPageCited_AndSaysAnAiWroteIt()
    {
        Assert.Equal([1, 2], Summary().CitedPages(10));
        Assert.Equal(1, AiAnswerExport.CommentPage(Summary(), 10, current: 7));
        Assert.Equal(7, AiAnswerExport.CommentPage(Summary() with { Answer = "No citations." }, 10, current: 7));
        Assert.Equal(0, AiAnswerExport.CommentPage(Question(), 3, current: 0)); // [p. 5] isn't a page of a 3-page document

        var text = AiAnswerExport.CommentText(Summary());
        Assert.StartsWith("Summarize pages 1–3\n\n", text);
        Assert.Contains("The lease runs two years [p. 2].", text);
        Assert.DoesNotContain("**", text);
        Assert.Contains("• Rent is due monthly", text);
        Assert.Contains("llama3.2", text);
        Assert.Contains("may be wrong", text);
        var huge = AiAnswerExport.CommentText(Question() with { Answer = new string('x', 50_000) });
        Assert.True(huge.Length < AiAnswerExport.MaxCommentChars + 500);

        // As a sticky note in the document: the text as it is, one undo step for the app.
        var pdf = Annotations.AddNote(TestPdf.Make(2), null, 1, 560, 16, text, "Ana");
        Assert.Equal(text, Assert.Single(Annotations.Read(pdf, null)).Contents);
    }

    [Fact]
    public void Word_HasTheTitle_EachQuestionAsAHeading_TheNote_AndTheAnswersLook()
    {
        var docx = AiAnswerExport.ToDocx([Summary(), Question()], "lease.pdf");
        using var zip = new ZipArchive(new MemoryStream(docx));
        Assert.NotNull(zip.GetEntry("[Content_Types].xml"));
        using var reader = new StreamReader(zip.GetEntry("word/document.xml")!.Open());
        var xml = reader.ReadToEnd();
        Assert.Contains("AI answers about lease.pdf", xml);
        Assert.Contains("Summarize pages 1–3", xml);
        Assert.Contains("Who pays repairs?", xml);
        Assert.Contains("Heading2", xml);
        Assert.Contains("llama3.2", xml);
        Assert.Contains("qwen3:8b", xml);
        Assert.Contains("may be wrong", xml);
        Assert.Contains("[p. 2]", xml);
        Assert.Contains("<w:numPr>", xml); // the bullets are Word's own
        Assert.Contains("1. Sign by Friday", xml);
        Assert.DoesNotContain("**", xml);
        // "two years" is a bold run of its own.
        var bold = xml.IndexOf("two years", StringComparison.Ordinal);
        var run = xml.LastIndexOf("<w:r>", bold, StringComparison.Ordinal);
        Assert.Contains("<w:b />", xml[run..bold]);
        Assert.Throws<ArgumentException>(() => AiAnswerExport.ToDocx([], "x.pdf"));
    }

    [Fact]
    public void Pdf_HasTheSameText_AndFlowsOntoMorePages()
    {
        var pdf = AiAnswerExport.ToPdf([Summary(), Question() with { Answer = "Привет, Zoë: the answer in two scripts." }], "lease.pdf");
        var text = Core2Pdf.AllText(pdf, 0);
        Assert.Contains("AI answers about lease.pdf", text);
        Assert.Contains("Summarize pages 1–3", text);
        Assert.Contains("Overview", text);
        Assert.Contains("two years [p. 2]", text);
        Assert.Contains("Rent is due monthly", text);
        Assert.Contains("llama3.2", text);
        Assert.Contains("Привет, Zoë", text);
        Assert.DoesNotContain("**", text);

        var longer = AiAnswerExport.ToPdf([Question() with { Answer = string.Join("\n", Enumerable.Range(1, 200).Select(i => $"Point {i}: the landlord pays repairs.")) }], "lease.pdf");
        using var engine = PdfEngine.Open(longer, InputFileTypes.PDF, null);
        Assert.True(engine.PageCount >= 4, $"{engine.PageCount} pages");
        Assert.Contains("Point 200", engine.GetText(engine.PageCount - 1).Text);
        Assert.Throws<ArgumentException>(() => AiAnswerExport.ToPdf([], "x.pdf"));

        // **bold** is drawn bold, the rest of its line regular.
        using var first = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var spans = first.GetExportPage(0, images: false).Lines.SelectMany(l => l.Spans).ToList();
        Assert.Contains(spans, s => s.Text.Contains("two", StringComparison.Ordinal) && s.Bold);
        Assert.Contains(spans, s => s.Text.Contains("lease runs", StringComparison.Ordinal) && !s.Bold);
        Assert.Contains(spans, s => s.Text.Contains("[p. 2]", StringComparison.Ordinal) && !s.Bold);
    }
}
