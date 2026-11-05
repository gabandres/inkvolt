using System.Globalization;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

public static partial class AutoTag
{
    /// <summary>
    /// A laid-out page's blocks as tag blocks. Consecutive list paragraphs make one list (deeper indents nest); two or more
    /// lines ending in page numbers after dot leaders make a table of contents; a short line that is mostly math (math
    /// fonts, or symbols centered or numbered "(1)") is a formula; small numbered text at the foot of the page, with no body
    /// text under it, is a footnote; "Figure 2:" or "Table 1." next to a figure or table is its caption. A table must look
    /// like one (<see cref="PlausibleTable"/>); one that doesn't (a chart's labels) is a figure when it is mostly numbers,
    /// else its text as paragraphs.
    /// </summary>
    private static List<TagBlock> Blocks(int page, DocPage laid, double body, double height)
    {
        var result = new List<TagBlock>();
        var fromTables = new List<TagBlock>();
        var src = laid.Blocks;
        List<DocParagraph>? list = null;
        void FlushList()
        {
            if (list is null) return;
            // A numbered section title ("3.1 Encoder Stacks") in bold reads as a list item of one: it is a heading.
            if (list is [var only] && only.AllBold && only.Text.Trim().Length <= 120 && SectionDepth(only.Text) is { } depth)
                result.Add(new TagBlock(page, TagBlockKind.Heading, Bounds(only.Sources.Count > 0 ? only.Sources : [only.Box]))
                {
                    Level = Math.Min(depth, 6), Sources = only.Sources, Text = only.Text.Trim(),
                });
            else result.Add(ListBlock(page, list));
            list = null;
        }
        for (var i = 0; i < src.Count; i++)
        {
            var b = src[i];
            if (b is DocParagraph first && TocEntry(first) && i + 1 < src.Count && src[i + 1] is DocParagraph second && TocEntry(second))
            {
                FlushList();
                var entries = new List<DocParagraph>();
                for (; i < src.Count && src[i] is DocParagraph e && TocEntry(e); i++) entries.Add(e);
                i--;
                result.Add(ContentsBlock(page, entries));
                continue;
            }
            if (b is DocParagraph { List: not ListKind.None } item && item.HeadingLevel == 0)
            {
                (list ??= []).Add(item);
                continue;
            }
            FlushList();
            switch (b)
            {
                case DocParagraph p when p.Sources.Count > 0:
                    result.Add(ParagraphBlock(page, p, body, height, src.Skip(i + 1)));
                    break;
                case DocTable t:
                    var made = TableBlocks(page, t).ToList();
                    result.AddRange(made);
                    fromTables.AddRange(made.Where(x => x.Kind == TagBlockKind.Figure));
                    break;
                case DocPicture pic:
                    var box = pic.Image.PageBox ?? pic.Box;
                    result.Add(new TagBlock(page, TagBlockKind.Figure, box) { Sources = [box] });
                    break;
            }
        }
        FlushList();
        MergeChartFigures(result, fromTables);
        FigureLabels(result);
        Captions(result);
        return result;
    }

    private static TagBlock ParagraphBlock(int page, DocParagraph p, double body, double height, IEnumerable<DocBlock> after)
    {
        // Text set sideways in a margin (an arXiv stamp, a running title) isn't a heading, however large.
        var area = Bounds(p.Sources);
        var text = p.Text.Trim();
        if (p.HeadingLevel > 0 && !(area.Height > 3 * area.Width && text.Length > 3))
            return new TagBlock(page, TagBlockKind.Heading, area) { Level = p.HeadingLevel, Sources = p.Sources, Text = text };
        if (IsFormula(p)) return new TagBlock(page, TagBlockKind.Formula, area) { Sources = p.Sources, Text = text, Alt = text };
        // A footnote: smaller than the body, low on the page, starting with its number or mark, and no body text under it
        // in its column.
        var note = p.Size > 0 && p.Size <= 0.9 * body && area.Y >= 0.55 * height && NoteStart(text) &&
                   !after.OfType<DocParagraph>().Any(q => q.Size > 0.9 * body && q.Sources.Count > 0 && Bounds(q.Sources) is var qa &&
                                                         qa.Y > area.Y && qa.X < area.Right && qa.Right > area.X);
        return new TagBlock(page, note ? TagBlockKind.Note : TagBlockKind.Paragraph, area) { Sources = p.Sources, Text = text };
    }

    /// <summary>A list's items, nested by how far each one is indented (a deeper item goes in the list of the item before).</summary>
    private static TagBlock ListBlock(int page, List<DocParagraph> items)
    {
        var levels = Levels(items.Select(i => (i.Sources.Count > 0 ? i.Sources[0] : i.Box).X).ToList());
        return new TagBlock(page, TagBlockKind.List, items.Select(i => i.Sources.Count > 0 ? Bounds(i.Sources) : i.Box).Aggregate((x, y) => x.Union(y)))
        {
            Items = [.. items.Select((i, k) => new TagListItem(i.Sources, i.Text.Trim()) { Level = levels[k] })],
            Text = string.Join("\n", items.Select(i => i.Text.Trim())),
        };
    }

    private static TagBlock ContentsBlock(int page, List<DocParagraph> entries)
    {
        var levels = Levels(entries.Select(e => (e.Sources.Count > 0 ? e.Sources[0] : e.Box).X).ToList());
        var texts = entries.Select(e => Spaces().Replace(Unleader(e.Text), " ").Trim()).ToList();
        return new TagBlock(page, TagBlockKind.Contents, entries.Select(e => e.Sources.Count > 0 ? Bounds(e.Sources) : e.Box).Aggregate((x, y) => x.Union(y)))
        {
            Items = [.. entries.Select((e, k) => new TagListItem(e.Sources, texts[k]) { Level = levels[k] })],
            Text = string.Join("\n", texts),
        };
    }

    /// <summary>
    /// Nesting levels from left edges: each distinct indent (6 points apart or more) is a level, the leftmost 0; an item is
    /// never more than one level deeper than the one before it (the first is at 0).
    /// </summary>
    internal static int[] Levels(IReadOnlyList<double> lefts)
    {
        var steps = new List<double>();
        foreach (var x in lefts.Order())
            if (steps.Count == 0 || x - steps[^1] >= 6) steps.Add(x);
        var levels = new int[lefts.Count];
        for (var k = 0; k < lefts.Count; k++)
        {
            var level = steps.FindLastIndex(s => s <= lefts[k] + 0.5);
            levels[k] = Math.Max(0, Math.Min(level, k == 0 ? 0 : levels[k - 1] + 1));
        }
        return levels;
    }

    /// <summary>A contents entry: one or two lines ending in a page number after dot leaders (or dots in the text).</summary>
    internal static bool TocEntry(DocParagraph p)
    {
        // Leaders the layout found are tabs (or leader marks) in the text, or a wide stretch it read as spaces before the
        // number (dots drawn one by one).
        var text = p.Text.Trim();
        var leader = text.Any(ExportGlyphs.IsLeader) || p.Tabs.Any(t => t.Leader != '\0') && text.Contains('\t') ||
                     WideGapNumber().IsMatch(text) && p.Sources.Count >= 3 && p.Sources.Skip(1).SkipLast(1).Any(s => s.Width >= 40);
        text = Unleader(text);
        if (text.Length is < 3 or > 200 || p.LineCount > 2 || !PageNumberEnd().IsMatch(text)) return false;
        return leader || DotsBeforeNumber().IsMatch(text);
    }

    /// <summary>The text with the layout's leader marks as tabs.</summary>
    private static string Unleader(string text) => string.Concat(text.Select(c => ExportGlyphs.IsLeader(c) ? '\t' : c)).Trim();

    /// <summary>
    /// Display math: a short paragraph mostly in math fonts (TeX's CMMI, CMSY, CMEX, the AMS fonts, Cambria Math…), or one
    /// with math symbols and a relation that is centered or numbered "(1)", with hardly any words.
    /// </summary>
    internal static bool IsFormula(DocParagraph p)
    {
        var text = p.Text.Trim();
        if (text.Length is 0 or > 300 || p.LineCount > 4) return false;
        int chars = 0, math = 0, symbols = 0, words = 0;
        foreach (var r in p.Runs)
        {
            var mathFont = MathFont().IsMatch(r.Font);
            if (!mathFont) words += Word().Matches(r.Text).Count;
            foreach (var c in r.Text)
            {
                if (char.IsWhiteSpace(c)) continue;
                chars++;
                if (mathFont) math++;
                if (char.GetUnicodeCategory(c) == UnicodeCategory.MathSymbol || c is >= 'Ͱ' and <= 'Ͽ' or >= '∀' and <= '⋿') symbols++;
            }
        }
        if (chars == 0 || words > 2) return false;
        if (math >= 0.3 * chars && math + symbols >= 3) return true;
        return symbols >= 2 && text.Any(c => c is '=' or '<' or '>' or '≤' or '≥' or '≈' or '≠' or '∈' or '→' or '∝') &&
               (EquationNumber().IsMatch(text) || p.Align == TextAlign.Center);
    }

    /// <summary>
    /// A table looks like one: in at least half its rows (two at least) two or more cells hold something, at least two
    /// columns hold something in two rows or more, and a third of its cells or more aren't empty. A chart's gridlines with
    /// labels at a few of their crossings don't.
    /// </summary>
    internal static bool PlausibleTable(DocTable t)
    {
        if (t.Rows.Count < 2) return true;
        var columns = t.Rows.Max(r => r.Sum(c => Math.Max(1, c.ColSpan)));
        if (columns < 2) return true;
        var used = new int[columns];
        int cells = 0, filled = 0, rowsWithTwo = 0;
        foreach (var row in t.Rows)
        {
            var col = 0;
            var n = 0;
            foreach (var cell in row)
            {
                cells++;
                if (!Empty(cell))
                {
                    filled++;
                    n++;
                    if (col < columns) used[col]++;
                }
                col += Math.Max(1, cell.ColSpan);
            }
            if (n >= 2) rowsWithTwo++;
        }
        return rowsWithTwo >= Math.Max(2, (t.Rows.Count + 1) / 2) && used.Count(u => u >= 2) >= 2 && filled >= 0.34 * cells;
    }

    private static bool Empty(DocCell c) => string.IsNullOrWhiteSpace(c.Text) && c.Pictures.Count == 0;
    private static bool Bold(DocCell c) => c.Paragraphs.Count > 0 && c.Paragraphs.All(x => x.AllBold);
    private static bool Number(DocCell c) => !string.IsNullOrWhiteSpace(c.Text) && ExportLine.NumberLike(c.Text);

    /// <summary>Most rows (four in five) hold only numbers after their first cell.</summary>
    private static bool NumbersAfterFirst(IReadOnlyList<IReadOnlyList<DocCell>> rows) =>
        rows.Count > 0 && rows.Count(r => r.Skip(1).Any(c => !Empty(c)) && r.Skip(1).Where(c => !Empty(c)).All(Number)) >= Math.Ceiling(0.8 * rows.Count);

    /// <summary>
    /// A table with each cell that spans rows holding what was drawn in the cells it covers (text centered in a tall
    /// cell often sits in a row below its first), those left empty. A span stops at row <paramref name="cut"/> (the end
    /// of the header rows: a column header never spans into the data), and what it covered below that is a cell of its
    /// own, spanning what is left. 0: no cut.
    /// </summary>
    private static DocTable WithRowSpans(DocTable t, int cut = 0)
    {
        if (!t.Rows.Any(r => r.Any(c => c.RowSpan > 1))) return t;
        var rows = t.Rows.Select(r => r.ToList()).ToList();
        for (var r = 0; r < rows.Count; r++)
        {
            var col = 0;
            for (var k = 0; k < rows[r].Count; k++)
            {
                var cell = rows[r][k];
                if (cell.RowSpan > 1 && !cell.Covered)
                {
                    var whole = Math.Min(cell.RowSpan, rows.Count - r);
                    var span = cut > r && r + whole > cut ? cut - r : whole;
                    var paragraphs = cell.Paragraphs.ToList();
                    var pictures = cell.Pictures.ToList();
                    var d = 1;
                    for (; d < span; d++)
                    {
                        var below = CellAtColumn(rows[r + d], col);
                        if (below < 0 || !rows[r + d][below].Covered) break;
                        paragraphs.AddRange(rows[r + d][below].Paragraphs);
                        pictures.AddRange(rows[r + d][below].Pictures);
                        rows[r + d][below] = rows[r + d][below] with { Paragraphs = [], Pictures = [] };
                    }
                    rows[r][k] = cell with { Paragraphs = paragraphs, Pictures = pictures, RowSpan = d };
                    // Below the cut (or where a covered cell is missing): the next row's cell starts what is left.
                    if (d < whole && CellAtColumn(rows[r + d], col) is >= 0 and var rest && rows[r + d][rest].Covered)
                        rows[r + d][rest] = rows[r + d][rest] with { Covered = false, RowSpan = whole - d };
                }
                col += Math.Max(1, cell.ColSpan);
            }
        }
        return t with { Rows = [.. rows.Select(r => (IReadOnlyList<DocCell>)r)] };
    }

    /// <summary>
    /// A table without its rows that are all covered by the cells above (no rule between them anywhere, only a stub
    /// that gave the grid its line): each such row's content goes to the cell covering it, that cell spans one row less,
    /// so no row of the table is left without a cell of its own.
    /// </summary>
    private static DocTable WithoutCoveredRows(DocTable t)
    {
        if (!t.Rows.Any(r => r.Count > 0 && r.All(c => c.Covered))) return t;
        var rows = t.Rows.Select(r => r.ToList()).ToList();
        for (var r = 1; r < rows.Count;)
        {
            if (rows[r].Count == 0 || !rows[r].All(c => c.Covered))
            {
                r++;
                continue;
            }
            var col = 0;
            foreach (var cell in rows[r])
            {
                // The cell covering it: the first one above at that column that isn't covered.
                for (var up = r - 1; up >= 0; up--)
                {
                    if (CellAtColumn(rows[up], col) is not (>= 0 and var k)) break;
                    if (rows[up][k].Covered) continue;
                    var top = rows[up][k];
                    rows[up][k] = top with
                    {
                        Paragraphs = [.. top.Paragraphs, .. cell.Paragraphs], Pictures = [.. top.Pictures, .. cell.Pictures],
                        RowSpan = Math.Max(1, top.RowSpan - 1),
                    };
                    break;
                }
                col += Math.Max(1, cell.ColSpan);
            }
            rows.RemoveAt(r);
        }
        return t with { Rows = [.. rows.Select(r => (IReadOnlyList<DocCell>)r)] };
    }

    /// <summary>The index of the cell of a row that starts at column <paramref name="col"/>, or -1.</summary>
    private static int CellAtColumn(IReadOnlyList<DocCell> row, int col)
    {
        var at = 0;
        for (var k = 0; k < row.Count; k++)
        {
            if (at == col) return k;
            at += Math.Max(1, row[k].ColSpan);
        }
        return -1;
    }

    /// <summary>A table's cells as tagged: where each one's content is, its text, its spans.</summary>
    private static List<IReadOnlyList<TagCell>> TagCells(DocTable t) =>
        [.. t.Rows.Select(r => (IReadOnlyList<TagCell>)[.. r.Select(c => new TagCell(
            [.. c.Paragraphs.SelectMany(x => x.Sources)], c.Text.Trim(), c.ColSpan)
        {
            Pictures = [.. c.Pictures.Select(x => x.Image.PageBox ?? x.Box)],
            RowSpan = c.RowSpan,
            Covered = c.Covered,
        })])];

    private static IEnumerable<TagBlock> TableBlocks(int page, DocTable t)
    {
        var unmerged = WithoutCoveredRows(t);
        // Column headers, told row by row as drawn (each cell with what is drawn in it, before a cell spanning rows
        // takes what it covers): a first row in bold over rows that aren't, or a row of words over rows of numbers.
        var u = unmerged.Rows;
        var body = u.Skip(1).ToList();
        var boldTop = u.Count > 1 && u[0].All(c => c.Paragraphs.Count == 0 || Bold(c)) && u[0].Any(c => c.Paragraphs.Count > 0) &&
                      !body.All(r => r.All(c => c.Paragraphs.Count == 0 || Bold(c)));
        var wordsTop = u.Count > 1 && u[0].Count(c => !Empty(c)) >= 2 && !u[0].Any(Number) && NumbersAfterFirst(body);
        var headerRows = boldTop || wordsTop ? 1 : 0;
        // A header spanning columns over the headers under it ("2025" over "Q1 Q2"): both rows are headers.
        if (headerRows == 1 && u.Count > 3 && u[0].Any(c => c.ColSpan > 1) && u[1].Any(c => !Empty(c)) && !u[1].Any(Number) &&
            (u[1].All(c => Empty(c) || Bold(c)) || wordsTop && NumbersAfterFirst(u.Skip(2).ToList())))
            headerRows = 2;
        // A column header spans no further than the header rows: the spans are cut there.
        t = WithRowSpans(unmerged, cut: headerRows);
        var rows = TagCells(t);
        var all = rows.SelectMany(r => r).SelectMany(c => c.Sources.Concat(c.Pictures)).ToList();
        if (all.Count == 0) yield break;
        var box = Bounds(all);
        if (!PlausibleTable(t))
        {
            // A chart's labels (mostly numbers) are part of the chart: a figure (with their text, a row a line). Text that
            // happened to line up: paragraphs.
            var filled = t.Rows.SelectMany(r => r).Where(c => !Empty(c)).ToList();
            if (filled.Count(Number) * 2 >= filled.Count)
                yield return new TagBlock(page, TagBlockKind.Figure, box) { Sources = [box], Text = RowsText(rows) };
            else
                foreach (var cell in rows.SelectMany(r => r).Where(c => c.Sources.Count > 0))
                    yield return new TagBlock(page, TagBlockKind.Paragraph, Bounds(cell.Sources)) { Sources = cell.Sources, Text = cell.Text };
            yield break;
        }
        // Row headers: each row's first cell in bold when the rest aren't, or words in front of numbers. The first
        // column is each row's first cell (a covered one too: the row header above it heads that row).
        var data = t.Rows.Skip(headerRows).ToList();
        var heads = data.Where(r => r.Count == 0 || !r[0].Covered).ToList();
        var headerColumn = data.Count >= 2 && heads.Count >= 1 && heads.All(r => r.Count >= 2 && !Empty(r[0])) &&
                           (heads.All(r => Bold(r[0])) && !data.All(r => r.Skip(1).All(c => Empty(c) || Bold(c))) ||
                            heads.All(r => !Number(r[0])) && NumbersAfterFirst(data));
        yield return new TagBlock(page, TagBlockKind.Table, box)
        {
            Rows = rows, HeaderRows = headerRows, HeaderColumn = headerColumn,
            Text = string.Join(" | ", rows.Take(1).SelectMany(r => r).Select(c => c.Text)),
        };
    }

    /// <summary>A figure made from a chart's labels joins the picture or drawing it overlaps (one figure for the chart).</summary>
    private static void MergeChartFigures(List<TagBlock> blocks, List<TagBlock> fromTables)
    {
        foreach (var chart in fromTables)
        {
            var at = blocks.IndexOf(chart);
            var other = blocks.FindIndex(b => b.Kind == TagBlockKind.Figure && !ReferenceEquals(b, chart) &&
                                              Area(b.Box.Intersect(chart.Box)) > 0.3 * Math.Min(Area(b.Box), Area(chart.Box)));
            if (at < 0 || other < 0) continue;
            var union = blocks[other].Box.Union(chart.Box);
            blocks[other] = blocks[other] with { Box = union, Sources = [union], Text = Lines(blocks[other].Text, chart.Text) };
            blocks.RemoveAt(at);
        }
    }

    /// <summary>
    /// Short text inside a figure (a diagram's labels, an axis title; a few words just outside its edge too, never a
    /// caption) is part of the figure: its content goes in the Figure, whose box grows to hold it, and its text is the
    /// figure's (what the figure reads if made text; labels in reading order, a line each).
    /// </summary>
    private static void FigureLabels(List<TagBlock> blocks)
    {
        for (var i = blocks.Count - 1; i >= 0; i--)
        {
            var b = blocks[i];
            if (b.Kind != TagBlockKind.Paragraph || b.Text.Length > 200 || CaptionStart().IsMatch(b.Text)) continue;
            var margin = b.Text.Length <= 20 ? 24 : b.Text.Length <= 40 ? 12 : 2;
            var f = blocks.FindIndex(x => x.Kind == TagBlockKind.Figure && x.Page == b.Page && Area(x.Box.Inflate(margin).Intersect(b.Box)) >= 0.75 * Area(b.Box));
            if (f < 0) continue;
            var union = blocks[f].Box.Union(b.Box);
            blocks[f] = blocks[f] with { Box = union, Sources = [union], Text = Lines(b.Text, blocks[f].Text) };
            blocks.RemoveAt(i);
        }
    }

    /// <summary>Two texts a line apart (either may be empty).</summary>
    private static string Lines(string a, string b) => a.Length == 0 ? b : b.Length == 0 ? a : a + "\n" + b;

    /// <summary>A table's cells' text: a row a line, cells apart by a space.</summary>
    private static string RowsText(IReadOnlyList<IReadOnlyList<TagCell>> rows) =>
        string.Join("\n", rows.Select(r => string.Join(" ", r.Select(c => c.Text).Where(x => x.Length > 0))));

    /// <summary>"Figure 2:", "Table 1." and the like right before or after a figure or table (near it, overlapping it across): its caption.</summary>
    private static void Captions(List<TagBlock> blocks)
    {
        for (var i = 0; i < blocks.Count; i++)
        {
            var b = blocks[i];
            if (b.Kind != TagBlockKind.Paragraph || b.Text.Length > 600 || !CaptionStart().IsMatch(b.Text)) continue;
            bool Near(int k) => k >= 0 && k < blocks.Count && blocks[k] is { Kind: TagBlockKind.Figure or TagBlockKind.Table } x &&
                                Math.Max(x.Box.Y - b.Box.Bottom, b.Box.Y - x.Box.Bottom) <= 48 && x.Box.X < b.Box.Right && b.Box.X < x.Box.Right;
            if (Near(i - 1) || Near(i + 1)) blocks[i] = b with { Kind = TagBlockKind.Caption };
        }
    }

    [GeneratedRegex(@"(?:\t|[.·…_ ]{3,}|\s)\s*(\d{1,4}|[ivxlcdm]{1,6})$")]
    private static partial Regex PageNumberEnd();

    [GeneratedRegex(@"\S\s{2,}(\d{1,4}|[ivxlcdm]{1,6})$")]
    private static partial Regex WideGapNumber();

    [GeneratedRegex(@"\S\s*[.·…]{3,}\s*(\d{1,4}|[ivxlcdm]{1,6})$")]
    private static partial Regex DotsBeforeNumber();

    /// <summary>A footnote's start: its number (raised against the text, or one or two digits and a space) or mark, then a word, not a size ("3x3").</summary>
    [GeneratedRegex(@"^(?:\d{1,3}(?![x×]\d)(?=\S)|\d{1,2}\s|[*∗†‡§¶‖]{1,3})\s*\p{L}")]
    private static partial Regex NoteMarker();

    /// <summary>Text that starts like a footnote and says something (two words or more).</summary>
    internal static bool NoteStart(string text) => NoteMarker().IsMatch(text) && Word().Matches(text).Count >= 2;

    [GeneratedRegex(@"\(\s*\d{1,3}[a-z]?\s*\)$")]
    private static partial Regex EquationNumber();

    [GeneratedRegex(@"\p{L}{4,}")]
    private static partial Regex Word();

    [GeneratedRegex(@"\s+")]
    private static partial Regex Spaces();

    [GeneratedRegex(@"(^|\+)(CMMI|CMSY|CMEX|CMBSY|MSAM|MSBM|EUFM|EURM|EUSM|RSFS|LMMath|STIXMath|STIXTwoMath|XITSMath|LatinModernMath)|CambriaMath|Cambria Math|-Math\b", RegexOptions.IgnoreCase)]
    private static partial Regex MathFont();

    [GeneratedRegex(@"^(Figure|Fig\.?|Table|Tab\.|Chart|Graph|Exhibit|Listing|Scheme|Diagram|Abbildung|Abb\.|Tabelle|Tabla|Cuadro|Figura|Gráfico|Gráfica|Tableau|Graphique|Tabella|Afbeelding|Tabel)\s*(\d+(\.\d+)*|[IVXLC]+|[A-Z])([.:\-–—)]|\s|$)", RegexOptions.IgnoreCase)]
    private static partial Regex CaptionStart();
}
