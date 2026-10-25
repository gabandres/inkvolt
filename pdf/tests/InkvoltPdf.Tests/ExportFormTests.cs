using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Validation;
using DocumentFormat.OpenXml.Wordprocessing;
using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>
/// Export fixes found on a typeset form (TeX-style accents, dot leaders in a font that names its dot "ogonek", labels
/// under fill-in lines, boxed tables drawn with a 1 pt frame, item numbers at the top of each page).
/// </summary>
public class ExportFormTests
{
    private static readonly ExportSpan Look = new("", "Serif", 7.5, false, false, 0, default);

    /// <summary>Glyphs of <paramref name="text"/> from x, each <paramref name="advance"/> wide, top at y (size 7.5, box 7.5 tall).</summary>
    private static List<ExportGlyph> Glyphs(string text, double x, double y, double advance = 3.5)
    {
        var list = new List<ExportGlyph>();
        foreach (var c in text)
        {
            list.Add(new ExportGlyph(c.ToString(), new RectD(x, y, advance, 7.5), Look));
            x += advance;
        }
        return list;
    }

    private static ExportGlyph Accent(char accent, double x, double y) => new(accent.ToString(), new RectD(x, y, 0.1, 7.5), Look);

    private static string Text(List<ExportGlyph> line) => string.Concat(line.Select(g => g.Text));

    private static ExportLine Line(string text, double x, double y, double size = 7.5)
    {
        var box = new RectD(x, y, text.Length * size * 0.5, size);
        return ExportLine.Of([new ExportSpan(text, "Serif", size, false, false, 0, box)]);
    }

    [Fact]
    public void An_accent_set_over_its_letter_joins_it_and_the_space_MuPDF_saw_before_it_goes()
    {
        // "Direcci" " " "´" "on": the accent has no width and sits over the "o", which starts where the "i" ended
        // (the space is the kern back, read as a gap).
        var line = Glyphs("Direcci", 100, 100);
        var iEnd = line[^1].Rect.Right;
        line.Add(new ExportGlyph(" ", new RectD(iEnd, 100, 1.6, 7.5), Look));
        line.Add(Accent('´', iEnd + 1.6, 96.5));
        line.AddRange(Glyphs("on", iEnd - 0.1, 100));
        Assert.Equal("Dirección", Text(Assert.Single(ExportGlyphs.Compose([line]))));

        // "en" " " "´" "areas": a real space between the words stays.
        var words = Glyphs("en", 100, 100);
        var nEnd = words[^1].Rect.Right;
        words.Add(new ExportGlyph(" ", new RectD(nEnd, 100, 2.5, 7.5), Look));
        words.Add(Accent('´', nEnd + 4, 96.5));
        words.AddRange(Glyphs("areas", nEnd + 2.3, 100));
        Assert.Equal("en áreas", Text(ExportGlyphs.Compose([words])[0]));

        // A dotless i takes the accent as i; a tilde makes ñ.
        var dia = Glyphs("D", 100, 100);
        dia.Add(Accent('´', 104.5, 96.5));
        dia.AddRange(Glyphs("ıa", 103.5, 100));
        var ano = Glyphs("A", 120, 100);
        ano.Add(Accent('˜', 125.5, 96.5));
        ano.AddRange(Glyphs("no", 123.5, 100));
        // A circumflex or caron (letters to .NET) goes onto its letter, not onto itself.
        var fete = Glyphs("f", 140, 100);
        fete.Add(Accent('ˆ', 145.3, 96.5));
        fete.AddRange(Glyphs("ete", 143.5, 100));
        var composed = ExportGlyphs.Compose([dia, ano, fete]);
        Assert.Equal(["Día", "Año", "fête"], composed.Select(Text));

        // An accent with a width of its own (TeX's \accent) over its letter joins it; one standing between two letters
        // ("don´t") doesn't.
        var wide = Glyphs("caf", 100, 140);
        wide.Add(new ExportGlyph("´", new RectD(110.5, 137, 3.75, 7.5), Look));
        wide.AddRange(Glyphs("e", 110.5, 140));
        Assert.Equal("café", Text(ExportGlyphs.Compose([wide])[0]));
        var apostrophe = Glyphs("don", 100, 160);
        apostrophe.Add(new ExportGlyph("´", new RectD(110.5, 160, 2.5, 7.5), Look));
        apostrophe.AddRange(Glyphs("t", 113, 160));
        Assert.Equal("don´t", Text(ExportGlyphs.Compose([apostrophe])[0]));
    }

    [Fact]
    public void A_capitals_accent_read_as_a_line_of_its_own_goes_onto_its_letter()
    {
        // MuPDF splits "PREDICACIÓN" into "PREDICACI", the accent raised by most of the size alone, and "ON".
        var before = Glyphs("PREDICACI", 100, 100, 6);
        var accent = new List<ExportGlyph> { Accent('´', before[^1].Rect.Right + 3, 100 - 0.85 * 7.5) };
        var after = Glyphs("ON", before[^1].Rect.Right, 100, 6);
        var composed = ExportGlyphs.Compose([before, accent, after]);
        Assert.Equal(["PREDICACI", "", "ÓN"], composed.Select(Text));
    }

    [Fact]
    public void Runs_of_dots_or_a_repeated_accent_become_one_leader_and_short_runs_stay_text()
    {
        var label = Glyphs("Name: ", 100, 100);
        var x = label[^1].Rect.Right;
        // The form's font names its leader dot "ogonek": 40 of them.
        label.AddRange(Enumerable.Range(0, 40).Select(i => new ExportGlyph("˛", new RectD(x + i * 2, 104, 2, 1), Look)));
        var line = Assert.Single(ExportGlyphs.Compose([label]));
        Assert.Equal("Name: " + ExportGlyphs.DotLeader, Text(line));
        Assert.Equal(x + 80, line[^1].Rect.Right, 3); // the leader spans the run

        // An ellipsis in a sentence ("say . . . . then", dots and spaces 0.25 em each) or dots between letters stay text;
        // a long run of dots is a leader.
        var ellipsis = Glyphs("say . . . . then", 100, 120, 1.9);
        Assert.Equal("say . . . . then", Text(ExportGlyphs.Compose([ellipsis])[0]));
        Assert.Equal("wait....then", Text(ExportGlyphs.Compose([Glyphs("wait....then", 100, 120)])[0]));
        var toc = Glyphs("Introduction . . . . . . . . . . . . 5", 100, 120);
        Assert.Equal("Introduction " + ExportGlyphs.DotLeader + " 5", Text(ExportGlyphs.Compose([toc])[0]));
        // A rule typed in a monospaced font is text.
        var mono = Glyphs("+----------+", 100, 140).Select(g => g with { Look = g.Look with { Mono = true } }).ToList();
        Assert.Equal("+----------+", Text(ExportGlyphs.Compose([mono])[0]));
        Assert.Equal("Sign ___", Text(ExportGlyphs.Compose([Glyphs("Sign ___", 100, 140)])[0]));
        Assert.Equal("Sign " + ExportGlyphs.LineLeader, Text(ExportGlyphs.Compose([Glyphs("Sign ______", 100, 140)])[0]));
    }

    [Fact]
    public void A_lone_accent_that_draws_two_bars_is_an_equals_sign()
    {
        // 8 px per point, size 7.5: two 30 px bars 3 px thick, 8 px apart, as "=" draws.
        const int w = 40, h = 60;
        var alpha = new byte[w * h];
        foreach (var top in new[] { 24, 35 })
            for (var y = top; y < top + 3; y++)
            for (var x = 5; x < 35; x++) alpha[y * w + x] = 255;
        Assert.Equal("=", ExportGlyphs.DrawnAs(alpha, w, h, 8, 7.5));

        // A diaeresis in a wide font: two dots side by side on the same rows, not a bar.
        var dots = new byte[w * h];
        for (var y = 10; y < 14; y++)
        foreach (var x0 in new[] { 6, 28 })
            for (var x = x0; x < x0 + 6; x++) dots[y * w + x] = 255;
        Assert.Null(ExportGlyphs.DrawnAs(dots, w, h, 8, 7.5));

        // A dot accent: a small blob.
        var dot = new byte[w * h];
        for (var y = 10; y < 16; y++)
        for (var x = 17; x < 23; x++) dot[y * w + x] = 255;
        Assert.Null(ExportGlyphs.DrawnAs(dot, w, h, 8, 7.5));

        var line = Glyphs("M ", 100, 100);
        line.Add(new ExportGlyph("˙", new RectD(107, 100, 5, 7.5), Look));
        line.AddRange(Glyphs(" Morning", 112, 100));
        Assert.True(ExportGlyphs.IsLoneAccent(line, 2));
        Assert.False(ExportGlyphs.IsLoneAccent(Glyphs("a˙b", 100, 100), 1));
    }

    [Fact]
    public void A_frame_bounded_with_room_for_mitered_corners_is_taken_in_to_meet_its_rules()
    {
        // The frame drawn at 54..558 x 377..512, bounded 11 pt wider all round; rules inside run from frame to frame.
        var paths = new List<(RectD, bool)>
        {
            (RectD.FromEdges(43, 366, 569, 523), true),
            (RectD.FromEdges(54, 397, 558, 397.6), true),
            (RectD.FromEdges(54, 465, 558, 465.6), true),
            (RectD.FromEdges(155, 465, 155.6, 512), true),
            (RectD.FromEdges(256, 465, 256.6, 512), true),
        };
        var rules = DocLayout.RulesFromPaths(paths);
        var verticals = rules.Where(r => r.Width < 1 && r.Height > 100).Select(r => Math.Round(r.X)).Order().ToList();
        Assert.Equal([54.0, 558.0], verticals);
        Assert.Contains(rules, r => Math.Abs(r.Y - 377) < 0.5 && r.Height == 0);

        // One line inset in a box (a signature line) leaves the box as drawn.
        var boxed = DocLayout.RulesFromPaths([(RectD.FromEdges(100, 100, 300, 160), true), (RectD.FromEdges(110, 140, 290, 140.5), true)]);
        Assert.Contains(boxed, r => r.Width == 0 && Math.Abs(r.X - 100) < 0.01);

        // A frame and rules only, crossing in a grid with a few labels in it: a form's boxes, not a chart.
        var labels = new List<ExportLine> { Line("Monday", 70, 470), Line("Tuesday", 170, 470), Line("Days you can serve:", 200, 380) };
        var more = paths.Concat(Enumerable.Range(0, 8).Select(i => (new RectD(357 + i * 25, 465, 0.6, 47), true))).ToList();
        Assert.Empty(DocLayout.FigureRegions(more, labels, 612, 792));

        // A line chart: gridlines and a data line (a stroked polyline running through the grid) is still a figure.
        var chart = new List<(RectD, bool)>();
        for (var k = 0; k <= 5; k++)
        {
            chart.Add((new RectD(100, 400 + k * 30, 300, 0.5), true));
            chart.Add((new RectD(100 + k * 60, 400, 0.5, 150), true));
        }
        chart.Add((RectD.FromEdges(112, 418, 377, 532), true));
        Assert.Single(DocLayout.FigureRegions(chart, [Line("2020", 100, 556), Line("2025", 380, 556)], 612, 792));
    }

    [Fact]
    public void Labels_side_by_side_are_one_paragraph_with_tab_stops_and_a_leader_is_a_dotted_tab()
    {
        var lines = new List<ExportLine>
        {
            ExportLine.Of(
            [
                new ExportSpan("1. Name: ", "Serif", 7.5, false, false, 0, new RectD(58, 100, 50, 7.5)),
                new ExportSpan(ExportGlyphs.DotLeader.ToString(), "Serif", 8.5, false, false, 0, RectD.FromEdges(110, 104, 558, 105)),
            ]),
            Line("(Last name)", 178, 110, 6), Line("(First name)", 317, 110, 6), Line("(Middle name)", 461, 110, 6),
            Line("Signature follows here.", 58, 200, 7.5),
        };
        var page = DocLayout.Analyze([new ExportPage(612, 792, lines, [], [])]).Single();
        var paras = page.Blocks.OfType<DocParagraph>().ToList();
        Assert.Equal(3, paras.Count);

        var name = paras[0];
        Assert.Equal("1. Name: \t", name.Text);
        var leader = Assert.Single(name.Tabs);
        Assert.True(leader.Right);
        Assert.Equal('.', leader.Leader);
        Assert.Equal(558 - 58, leader.Position, 1);

        var labels = paras[1];
        Assert.Equal("(Last name)\t(First name)\t(Middle name)", labels.Text);
        Assert.Equal([317 - 58.0, 461 - 58.0], labels.Tabs.Select(t => Math.Round(t.Position, 1)));
        Assert.Equal(178 - 58, labels.Indent, 1);
        Assert.True(paras[2].SpaceBefore > 60); // the gap down to the next line is kept

        using var ms = new MemoryStream();
        DocumentExport.WriteDocx(ms, [new ExportPage(612, 792, lines, [], [])], "Form");
        using var doc = WordprocessingDocument.Open(new MemoryStream(ms.ToArray()), false);
        Assert.Empty(new OpenXmlValidator(FileFormatVersions.Office2013).Validate(doc));
        var body = doc.MainDocumentPart!.Document.Body!.Elements<Paragraph>().ToList();
        var stop = Assert.Single(body[0].ParagraphProperties!.Tabs!.Elements<TabStop>());
        Assert.Equal(TabStopLeaderCharValues.Dot, stop.Leader!.Value);
        Assert.Equal(TabStopValues.Right, stop.Val!.Value);
        Assert.Equal(2, body[1].Descendants<TabChar>().Count());
        Assert.NotNull(doc.MainDocumentPart.FontTablePart);
    }

    [Fact]
    public void A_rule_with_text_after_it_ends_where_the_text_starts_and_line_spacing_is_not_paragraph_spacing()
    {
        var row = ExportLine.Of(
        [
            new ExportSpan("Signature ", "Serif", 9, false, false, 0, new RectD(58, 100, 45, 9)),
            new ExportSpan(ExportGlyphs.LineLeader.ToString(), "Serif", 9, false, false, 0, RectD.FromEdges(103, 100, 300, 109)),
            new ExportSpan(" Date ", "Serif", 9, false, false, 0, new RectD(300, 100, 30, 9)),
            new ExportSpan(ExportGlyphs.LineLeader.ToString(), "Serif", 9, false, false, 0, RectD.FromEdges(330, 100, 500, 109)),
        ]);
        // Then a paragraph set at 1.5 lines (12 pt type, 18 pt apart), and one more after it, 18 pt down again.
        var lines = new List<ExportLine> { row };
        var text = "Spaced text that runs over three lines of the page in a paragraph";
        for (var k = 0; k < 3; k++) lines.Add(Line(text, 58, 200 + k * 18, 12));
        lines.Add(Line("1. The next one", 58, 254, 12));
        var paras = DocLayout.Analyze([new ExportPage(612, 792, lines, [], [])]).Single().Blocks.OfType<DocParagraph>().ToList();
        Assert.Equal([(false, 300 - 58.0, '_'), (true, 500 - 58.0, '_')], paras[0].Tabs.Select(t => (t.Right, t.Position, t.Leader)));
        Assert.Equal(18, paras[1].LinePitch, 3);
        Assert.InRange(paras[2].SpaceBefore!.Value, 0, 5); // 18 pt from the last line's top: one line, no gap
    }

    [Fact]
    public void Two_prose_columns_on_one_row_are_not_joined_with_tabs()
    {
        var left = "Left column text runs on here as a paragraph";
        var right = "Right column text runs on here as another one";
        var lines = new List<ExportLine>();
        for (var k = 0; k < 4; k++)
        {
            lines.Add(Line(left, 72, 100 + k * 10, 8));
            lines.Add(Line(right, 330, 100 + k * 10, 8));
        }
        var page = DocLayout.Analyze([new ExportPage(612, 792, lines, [], [])]).Single();
        Assert.All(page.Blocks.OfType<DocParagraph>(), p => Assert.DoesNotContain('\t', p.Text));
    }

    [Fact]
    public void An_item_number_at_the_top_of_each_page_beside_its_text_is_not_a_running_header()
    {
        var pages = Enumerable.Range(0, 2).Select(n => new ExportPage(612, 792,
        [
            Line("1.", 58, 62), Line(n == 0 ? "Name: the first item of the form" : "Is the applicant a willing helper?", 72, 62),
            Line("More text further down the page", 58, 300),
            Line("S-73 9/19", 54, 762),
        ], [], [])).ToList();
        var result = DocLayout.AnalyzeDocument(pages);
        Assert.Null(result.Header);
        Assert.Equal("S-73 9/19", Assert.Single(Assert.Single(result.Footer!.Rows).Parts).Span.Text);
        Assert.All(result.Pages, p => Assert.StartsWith("1. ", p.Blocks.OfType<DocParagraph>().First().Text));
    }

    [Fact]
    public void Text_in_two_cells_set_close_together_stays_in_its_cells_and_boxed_tables_stay_apart()
    {
        // A ruled header row: "Overseer" in two neighboring cells, 8 pt apart (closer than a column gap).
        var rules = new List<RectD>();
        foreach (var y in new[] { 100.0, 130, 160 }) rules.Add(new RectD(54, y, 300, 0));
        foreach (var x in new[] { 54.0, 154, 254, 354 }) rules.Add(new RectD(x, 100, 0, 60));
        var lines = new List<ExportLine> { Line("Overseer", 100, 110), Line("Overseer", 162, 110), Line("Notes", 270, 110) };
        // A second boxed table right under it.
        foreach (var y in new[] { 180.0, 200, 220 }) rules.Add(new RectD(54, y, 300, 0));
        foreach (var x in new[] { 54.0, 204, 354 }) rules.Add(new RectD(x, 180, 0, 40));
        lines.Add(Line("Saturday", 70, 185));
        lines.Add(Line("Sunday", 220, 185));
        var pageIn = new ExportPage(612, 792, lines, [], rules);
        var page = DocLayout.Analyze([pageIn]).Single();
        var tables = page.Blocks.OfType<DocTable>().ToList();
        Assert.Equal(2, tables.Count);
        Assert.Equal(["Overseer", "Overseer", "Notes"], tables[0].Rows[0].Select(c => c.Text));
        Assert.Equal([30.0, 30.0], tables[0].RowHeights!);

        using var ms = new MemoryStream();
        DocumentExport.WriteDocx(ms, [pageIn], "Tables");
        using var doc = WordprocessingDocument.Open(new MemoryStream(ms.ToArray()), false);
        Assert.Empty(new OpenXmlValidator(FileFormatVersions.Office2013).Validate(doc));
        var body = doc.MainDocumentPart!.Document.Body!;
        var first = body.Elements<Table>().First();
        Assert.IsType<Paragraph>(first.NextSibling()); // Word would join two tables that touch
        Assert.Equal(2, body.Elements<Table>().Count());
        Assert.Equal(600u, first.Elements<TableRow>().First().TableRowProperties!.GetFirstChild<TableRowHeight>()!.Val!.Value);
    }
}
