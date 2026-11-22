using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>What an AI assistant's answer answered: a summary, a question about the document, an explanation of a passage.</summary>
public enum AiAnswerKind { Summary, Answer, Explanation }

/// <summary>One answer of the AI assistant with what it answered.</summary>
/// <param name="Shown">What the pane showed as asked ("Summarize pages 1–3", the question, "Explain: …"), in the interface's language.</param>
/// <param name="Asked">What a later question sends as this turn of the conversation (the prompts are English).</param>
/// <param name="Model">The model that answered.</param>
public sealed record AiExchange(AiAnswerKind Kind, string Shown, string Asked, string Answer, string Model, DateTimeOffset When)
{
    /// <summary>The pages the answer cites ([p. N]), 0-based, each once, in the order cited.</summary>
    public IReadOnlyList<int> CitedPages(int pageCount) => [.. AiText.Citations(Answer, pageCount).Select(c => c.Page).Distinct()];
}

/// <summary>
/// The AI assistant's conversation about one document, kept with its session (<see cref="DocumentSession.AiConversation"/>)
/// until the user clears it or closes the document: what Save AI Answer saves, and what a follow-up question sends
/// again (<see cref="Turns"/>). Nothing of it is written anywhere unless the user saves it.
/// </summary>
public sealed class AiConversation
{
    /// <summary>The most answers kept: the oldest go first.</summary>
    public const int MaxExchanges = 500;

    private readonly List<AiExchange> _exchanges = [];

    public IReadOnlyList<AiExchange> Exchanges => _exchanges;

    public void Add(AiExchange exchange)
    {
        _exchanges.Add(exchange);
        if (_exchanges.Count > MaxExchanges) _exchanges.RemoveAt(0);
    }

    public void Clear() => _exchanges.Clear();

    /// <summary>The earlier questions and answers as a follow-up sends them.</summary>
    public IReadOnlyList<AiTurn> Turns => [.. _exchanges.Select(e => new AiTurn(e.Asked, e.Answer))];
}

/// <summary>
/// Save an AI answer (roadmap 4.20): one answer or the whole conversation as a Word document (<see cref="DocxWriter"/>) or
/// a PDF, or one answer as a comment on the page it cites. Each says it was made by an AI model and may be wrong, names
/// the model, keeps the answer's headings, bullets, bold and page citations, and holds nothing of the document but the answer.
/// </summary>
public static partial class AiAnswerExport
{
    /// <summary>The longest answer a comment carries (a note isn't a document): the rest is cut with "…".</summary>
    public const int MaxCommentChars = 20_000;

    /// <summary>The page a comment goes on: the first the answer cites, else <paramref name="current"/>.</summary>
    public static int CommentPage(AiExchange e, int pageCount, int current) =>
        e.CitedPages(pageCount) is [var first, ..] ? first : Math.Clamp(current, 0, Math.Max(0, pageCount - 1));

    /// <summary>A comment's text: what was asked, the answer (plain, its Markdown marks gone), and that an AI model wrote it.</summary>
    public static string CommentText(AiExchange e)
    {
        var answer = string.Join("\n", Blocks(e.Answer).Select(b => b.Kind switch
        {
            BlockKind.Bullet => "• " + Plain(b.Text),
            BlockKind.Blank => "",
            _ => Plain(b.Text),
        })).Trim();
        if (answer.Length > MaxCommentChars) answer = answer[..MaxCommentChars].TrimEnd() + "…";
        return $"{e.Shown}\n\n{answer}\n\n{Note(e)}";
    }

    /// <summary>"Written by an AI model (llama3.2) on …; it may be wrong."</summary>
    public static string Note(AiExchange e) => Loc.Format(PdfStrings.Ai_SavedNote, e.Model, e.When.ToLocalTime().ToString("g", CultureInfo.CurrentCulture));

    /// <summary>The answers as a Word document: a title, then each as a heading (what was asked), the note, and the answer.</summary>
    public static byte[] ToDocx(IReadOnlyList<AiExchange> exchanges, string documentName)
    {
        if (exchanges.Count == 0) throw new ArgumentException(PdfStrings.Ai_NothingToSave, nameof(exchanges));
        var title = Loc.Format(PdfStrings.Ai_SavedTitle, documentName);
        var blocks = new List<DocBlock>();
        var y = 72.0;
        DocParagraph Para(IReadOnlyList<ExportSpan> runs, int heading = 0, ListKind list = ListKind.None, double before = 6, double after = 6)
        {
            var size = runs.Count > 0 ? runs[0].Size : 11;
            var p = new DocParagraph(runs, new RectD(72, y, 468, size * 1.3))
            {
                Size = size, HeadingLevel = heading, List = list, SpaceBefore = before, SpaceAfter = after,
            };
            y += size * 1.3 + before + after;
            return p;
        }
        ExportSpan Span(string text, double size = 11, bool bold = false, bool italic = false, uint color = 0) =>
            new(text, "Calibri", size, bold, italic, color, default);

        blocks.Add(Para([Span(title, 18, bold: true)], heading: 1, before: 0));
        foreach (var e in exchanges)
        {
            blocks.Add(Para([Span(e.Shown, 13, bold: true)], heading: 2, before: 14));
            blocks.Add(Para([Span(Note(e), 9, italic: true, color: 0x595959)], before: 0));
            foreach (var b in Blocks(e.Answer))
            {
                if (b.Kind == BlockKind.Blank) continue;
                var runs = b.Kind == BlockKind.Heading ? [Span(b.Text, 11, bold: true)] : Runs(b.Text).Select(r => Span(r.Text, bold: r.Bold)).ToList();
                if (runs.Count == 0) continue;
                blocks.Add(Para(runs, list: b.Kind == BlockKind.Bullet ? ListKind.Bullet : b.Kind == BlockKind.Numbered ? ListKind.Marker : ListKind.None, before: 2, after: 4));
            }
        }
        var layout = new DocLayoutResult([new DocPage(612, 792, new RectD(72, 72, 468, Math.Max(72, y - 72)), blocks)], null, null);
        using var ms = new MemoryStream();
        using (var writer = new DocxWriter(ms)) writer.Finish(layout, title);
        return ms.ToArray();
    }

    private const double PageW = 612, PageH = 792, Margin = 72, Width = PageW - 2 * Margin;

    /// <summary>The answers as a PDF of Letter pages: the same as <see cref="ToDocx"/>, the text wrapped and flowing onto as many pages as it needs.</summary>
    public static byte[] ToPdf(IReadOnlyList<AiExchange> exchanges, string documentName)
    {
        if (exchanges.Count == 0) throw new ArgumentException(PdfStrings.Ai_NothingToSave, nameof(exchanges));
        var title = Loc.Format(PdfStrings.Ai_SavedTitle, documentName);
        // What is drawn, as lines: (text, size, bold, gray, indent, space before).
        var lines = new List<(string Text, double Size, bool Bold, bool Gray, double Indent, double Before)>();
        var all = new List<string> { title };
        foreach (var e in exchanges) all.AddRange([e.Shown, Note(e), e.Answer]);
        var regular = new TextPainter(StdFont.Helvetica, all);
        var bold = new TextPainter(new StdFont(StdFamily.Helvetica, true, false), all) { CidPrefix = "/PdB" };
        void Wrap(string text, double size, bool isBold, bool gray, double indent, double before, string first = "")
        {
            var painter = isBold ? bold : regular;
            var wrapped = painter.Wrap(text, Width - indent, size);
            for (var i = 0; i < wrapped.Count; i++)
                lines.Add(((i == 0 ? first : "") + wrapped[i], size, isBold, gray, indent - (i == 0 && first.Length > 0 ? 12 : 0), i == 0 ? before : 0));
        }
        Wrap(title, 18, true, false, 0, 0);
        foreach (var e in exchanges)
        {
            Wrap(e.Shown, 13, true, false, 0, 16);
            Wrap(Note(e), 9, false, true, 0, 2);
            foreach (var b in Blocks(e.Answer))
            {
                var text = Plain(b.Text);
                switch (b.Kind)
                {
                    case BlockKind.Blank: continue;
                    case BlockKind.Heading: Wrap(text, 11, true, false, 0, 8); break;
                    case BlockKind.Bullet: Wrap(text, 11, false, false, 12, 3, "•  "); break;
                    default: Wrap(text, 11, false, false, b.Kind == BlockKind.Numbered ? 12 : 0, 5); break;
                }
            }
        }

        using var doc = new PdfDocument();
        doc.Info.Title = title;
        doc.Info.Creator = "Inkvolt PDF";
        var pages = new List<(PdfPage Page, StringBuilder Ops)>();
        StringBuilder? ops = null;
        var y = 0.0;
        void Flush()
        {
            if (ops is null) return;
            ops.Append(Encoding.Latin1.GetString(regular.Ops("/F1", Black)));
            ops.Append(Encoding.Latin1.GetString(bold.Ops("/F2", Black)));
        }
        foreach (var (text, size, isBold, gray, indent, before) in lines)
        {
            var height = size * 1.3;
            if (ops is null || y - before - height < Margin)
            {
                Flush();
                var page = doc.AddPage();
                page.Width = PdfSharp.Drawing.XUnit.FromPoint(PageW);
                page.Height = PdfSharp.Drawing.XUnit.FromPoint(PageH);
                ops = new StringBuilder();
                pages.Add((page, ops));
                y = PageH - Margin;
            }
            else y -= before;
            y -= height;
            if (gray)
            {
                // Gray text goes out at once in its color; the rest waits for the page's black.
                ops.Append(Encoding.Latin1.GetString(regular.Ops("/F1", Black)));
                ops.Append(Encoding.Latin1.GetString(bold.Ops("/F2", Black)));
                regular.Draw(text, Margin + indent, y + size * 0.25, size);
                ops.Append(Encoding.Latin1.GetString(regular.Ops("/F1", Gray)));
            }
            else (isBold ? bold : regular).Draw(text, Margin + indent, y + size * 0.25, size);
        }
        Flush();

        // One font dictionary for every page, each font subset to every page's glyphs (as Summarize Comments does).
        var fonts = new PdfDictionary(doc);
        foreach (var (painter, name) in new[] { (regular, "/F1"), (bold, "/F2") })
            if (PdfObj.Dict(painter.Resources(doc, name).Elements["/Font"]) is { } f)
                foreach (var key in f.Elements.Keys.ToList())
                    fonts.Elements[key == "/F1" || key == "/F2" ? name : key] = f.Elements[key];
        doc.Internals.AddObject(fonts);
        foreach (var (page, pageOps) in pages)
        {
            var resources = new PdfDictionary(doc);
            resources.Elements["/Font"] = fonts.Reference!;
            page.Elements["/Resources"] = resources;
            page.Elements["/Contents"] = PdfObj.AddStream(doc, Encoding.Latin1.GetBytes(pageOps.ToString())).Reference!;
        }
        return PdfObj.Save(doc);
    }

    private static readonly PdfColorValue Black = new([0, 0, 0]), Gray = new([0.35, 0.35, 0.35]);

    internal enum BlockKind { Text, Heading, Bullet, Numbered, Blank }

    /// <summary>An answer's lines as the pane shows them: headings ("## …"), bullets ("- …", "* …", "• …"), numbered items, text, blank lines.</summary>
    internal static List<(BlockKind Kind, string Text)> Blocks(string answer)
    {
        var list = new List<(BlockKind, string)>();
        foreach (var raw in AiText.WithoutThinking(answer, out _).Replace("\r\n", "\n").Split('\n'))
        {
            var line = raw.TrimEnd();
            if (line.Trim().Length == 0) list.Add((BlockKind.Blank, ""));
            else if (Heading().Match(line) is { Success: true } h) list.Add((BlockKind.Heading, Plain(h.Groups[1].Value)));
            else if (Bullet().Match(line) is { Success: true } b) list.Add((BlockKind.Bullet, b.Groups[1].Value));
            else if (Numbered().IsMatch(line)) list.Add((BlockKind.Numbered, line.Trim()));
            else list.Add((BlockKind.Text, line.Trim()));
        }
        return list;
    }

    /// <summary>A line without its **bold** marks.</summary>
    private static string Plain(string line) => string.Concat(Runs(line).Select(r => r.Text));

    /// <summary>A line's **bold** spans (an unclosed ** stays as text).</summary>
    internal static List<(string Text, bool Bold)> Runs(string line)
    {
        var parts = line.Split("**");
        var runs = new List<(string, bool)>();
        for (var i = 0; i < parts.Length; i++)
        {
            var isBold = i % 2 == 1 && i < parts.Length - 1;
            var text = isBold || i % 2 == 0 ? parts[i] : "**" + parts[i];
            if (text.Length > 0) runs.Add((text, isBold));
        }
        return runs;
    }

    [GeneratedRegex(@"^\s{0,3}#{1,6}\s+(.*)$")]
    private static partial Regex Heading();

    [GeneratedRegex(@"^\s*(?:[-*+]|•)\s+(.*)$")]
    private static partial Regex Bullet();

    [GeneratedRegex(@"^\s*\d{1,3}[.)]\s+")]
    private static partial Regex Numbered();
}
