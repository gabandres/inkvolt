using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>What a tag block becomes: a paragraph (P), a heading (H1-H6), a list (L › LI › LBody), a table or a figure.</summary>
public enum TagBlockKind { Paragraph, Heading, List, Table, Figure }

/// <summary>Where the title Make Accessible proposes came from.</summary>
public enum TitleSource { Metadata, Heading, None }

/// <summary>A list item: where its text is on the page (as shown) and the text, for the reading order panel.</summary>
public sealed record TagListItem(IReadOnlyList<RectD> Sources, string Text);

/// <summary>A table cell: where its text and any pictures in it are on the page, its text, and how many columns it spans.</summary>
public sealed record TagCell(IReadOnlyList<RectD> Sources, string Text, int ColSpan = 1)
{
    public IReadOnlyList<RectD> Pictures { get; init; } = [];
}

/// <summary>
/// One piece of a page in reading order, as Make Accessible will tag it. Boxes are in page space as shown (points, top
/// left origin, the page's rotation applied), like <see cref="ExportPage"/>'s.
/// </summary>
public sealed record TagBlock(int Page, TagBlockKind Kind, RectD Box)
{
    /// <summary>Heading level 1-6 (<see cref="TagBlockKind.Heading"/>); levels are evened out when written (no gaps, first is H1).</summary>
    public int Level { get; init; }

    /// <summary>Where its content is on the page: text runs, or a figure's area.</summary>
    public IReadOnlyList<RectD> Sources { get; init; } = [];

    /// <summary>Its text (a figure's is empty): what the reading order panel shows.</summary>
    public string Text { get; init; } = "";

    public IReadOnlyList<TagListItem> Items { get; init; } = [];
    public IReadOnlyList<IReadOnlyList<TagCell>> Rows { get; init; } = [];

    /// <summary>The table's first row holds its column headers (TH with Scope Column).</summary>
    public bool HeaderRow { get; init; }

    /// <summary>The language of this passage when it isn't the document's (a code such as "es"); null: the document's.</summary>
    public string? Lang { get; init; }

    /// <summary>A figure's alternate text.</summary>
    public string? Alt { get; init; }

    /// <summary>A figure that only decorates: marked as an artifact, no alternate text needed.</summary>
    public bool Decorative { get; init; }
}

/// <summary>
/// What Make Accessible will write: the blocks in reading order, the running headers, footers and page numbers per page
/// (artifacts), and the title and language proposed. The reading order panel edits it before (or after) it is written.
/// </summary>
public sealed record TagPlan(IReadOnlyList<TagBlock> Blocks, IReadOnlyList<IReadOnlyList<RectD>> Running)
{
    public int Pages => Running.Count;
    public string? Title { get; init; }
    public TitleSource TitleFrom { get; init; }
    public string? Language { get; init; }

    /// <summary>The language was read from the text (none was set), so it is a guess to confirm.</summary>
    public bool LanguageGuessed { get; init; }

    /// <summary>The document already had tags (writing replaces them).</summary>
    public bool WasTagged { get; init; }

    /// <summary>Figures that still need alternate text (not decorative, no text).</summary>
    public int FiguresWithoutAlt => Blocks.Count(b => b.Kind == TagBlockKind.Figure && !b.Decorative && string.IsNullOrWhiteSpace(b.Alt));
}

/// <summary>Title, language and alternate texts written with the tags (the plan's own when these are null).</summary>
public sealed record AccessibleOptions
{
    public string? Title { get; init; }
    public string? Language { get; init; }
}

/// <summary>
/// Make Accessible: tags an untagged PDF on the PC. <see cref="Plan"/> reads the pages as Export to Word does
/// (<see cref="DocLayout"/>: headings, paragraphs, lists, tables, pictures and charts, columns, running headers and
/// footers) into a <see cref="TagPlan"/>; <see cref="Write"/> puts each piece of page content in marked content with an
/// MCID (or marks it as an artifact), builds the structure tree from the plan's order, and sets MarkInfo, the title (shown
/// in the window's title bar), the language, the tab order and the PDF/UA identifier.
/// </summary>
public static partial class AutoTag
{
    /// <summary>Reads the document into a plan. Pages that can't be read have no blocks (their content becomes artifacts).</summary>
    /// <exception cref="OperationCanceledException"/>
    public static TagPlan Plan(PdfEngine engine, byte[] data, string? password, IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default)
    {
        var pages = new List<ExportPage>(engine.PageCount);
        for (var p = 0; p < engine.PageCount; p++)
        {
            cancel.ThrowIfCancellationRequested();
            progress?.Report((p, engine.PageCount));
            try
            {
                pages.Add(engine.GetExportPage(p, images: true, cancel, boxesOnly: true));
            }
            catch (Exception ex) when (ex is MuPDFCore.MuPDFException or InvalidOperationException or ArgumentException)
            {
                var g = engine.GetPage(p);
                pages.Add(new ExportPage(g.Width, g.Height, [], [], []));
            }
        }
        var (layout, running) = DocLayout.AnalyzeForTags(pages);
        var blocks = new List<TagBlock>();
        for (var p = 0; p < layout.Pages.Count; p++) blocks.AddRange(Blocks(p, layout.Pages[p]));

        string? title = null, lang = null;
        var tagged = false;
        try
        {
            using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import);
            title = doc.Info.Title?.Trim();
            lang = PdfObj.Text(doc.Internals.Catalog.Elements["/Lang"])?.Trim();
            tagged = doc.Internals.Catalog.Elements.ContainsKey("/StructTreeRoot");
            // Tagged before (by Make Accessible or another program): figures in the same place keep their alternate text.
            if (tagged)
            {
                var alts = FigureAlts(doc);
                for (var i = 0; i < blocks.Count; i++)
                {
                    var b = blocks[i];
                    if (b.Kind != TagBlockKind.Figure) continue;
                    var match = alts.Where(a => a.Page == b.Page && Area(a.Box.Intersect(b.Box)) > 0.5 * Math.Min(Area(a.Box), Area(b.Box)))
                        .Select(a => a.Alt).FirstOrDefault();
                    if (match is not null) blocks[i] = b with { Alt = match };
                }
            }
        }
        catch (InvalidOperationException)
        {
            // Unreadable for PDFsharp: Write will say so.
        }
        var from = TitleSource.Metadata;
        if (string.IsNullOrWhiteSpace(title) || LooksLikeFileName(title))
        {
            title = blocks.FirstOrDefault(b => b.Kind == TagBlockKind.Heading)?.Text.Trim();
            from = string.IsNullOrEmpty(title) ? TitleSource.None : TitleSource.Heading;
        }
        var guessed = false;
        if (string.IsNullOrWhiteSpace(lang) || !AccessibilityCheck.IsLanguage(lang))
        {
            lang = Language.Guess(string.Join(' ', blocks.Select(b => b.Text)));
            guessed = true;
        }
        // Passages in another language than the document's, where the words say so clearly.
        if (lang is not null)
            for (var i = 0; i < blocks.Count; i++)
                if (blocks[i].Kind is TagBlockKind.Paragraph && Language.Guess(blocks[i].Text, strict: true) is { } own &&
                    !string.Equals(Primary(own), Primary(lang), StringComparison.OrdinalIgnoreCase))
                    blocks[i] = blocks[i] with { Lang = own };

        return new TagPlan(blocks, running)
        {
            Title = string.IsNullOrWhiteSpace(title) ? null : title, TitleFrom = from,
            Language = lang, LanguageGuessed = guessed, WasTagged = tagged,
        };
    }

    /// <summary>The Figure tags with alternate text and a bounding box: page, box (page space as shown) and text.</summary>
    private static List<(int Page, RectD Box, string Alt)> FigureAlts(PdfDocument doc)
    {
        var found = new List<(int, RectD, string)>();
        var pages = doc.Pages.Cast<PdfPage>().ToList();
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        void Visit(PdfItem? item, int depth)
        {
            if (depth > 64 || found.Count > 10_000) return;
            switch (PdfObj.Resolve(item))
            {
                case PdfArray a:
                    foreach (var x in a.Elements) Visit(x, depth + 1);
                    break;
                case PdfDictionary d when seen.Add(d):
                    if (PdfObj.Name(d.Elements["/S"]) == "Figure" && PdfObj.Text(d.Elements["/Alt"]) is { Length: > 0 } alt &&
                        PdfObj.PageIndexOf(doc, d.Elements["/Pg"]) is var p and >= 0 &&
                        PdfObj.Array(PdfObj.Dict(d.Elements["/A"])?.Elements["/BBox"]) is { Elements.Count: 4 } bb)
                    {
                        var page = pages[p];
                        var (x1, y1) = PdfObj.ToPage(page, PdfObj.Num(bb, 0), PdfObj.Num(bb, 1));
                        var (x2, y2) = PdfObj.ToPage(page, PdfObj.Num(bb, 2), PdfObj.Num(bb, 3));
                        found.Add((p, RectD.FromEdges(Math.Min(x1, x2), Math.Min(y1, y2), Math.Max(x1, x2), Math.Max(y1, y2)), alt));
                    }
                    Visit(d.Elements["/K"], depth + 1);
                    break;
            }
        }
        Visit(PdfObj.Dict(doc.Internals.Catalog.Elements["/StructTreeRoot"])?.Elements["/K"], 0);
        return found;
    }

    /// <summary>The document has a structure tree (tags) and says it is tagged.</summary>
    public static bool IsTagged(byte[] data, string? password)
    {
        try
        {
            using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import);
            var catalog = doc.Internals.Catalog;
            return catalog.Elements.ContainsKey("/StructTreeRoot") &&
                   PdfObj.Resolve(PdfObj.Dict(catalog.Elements["/MarkInfo"])?.Elements["/Marked"]) is PdfBoolean { Value: true };
        }
        catch (InvalidOperationException)
        {
            return false;
        }
    }

    private static string Primary(string lang) => lang.Split('-')[0];

    /// <summary>"Microsoft Word - report.docx", "untitled.pdf": a producer's placeholder, not a title.</summary>
    private static bool LooksLikeFileName(string title) =>
        title.EndsWith(".doc", StringComparison.OrdinalIgnoreCase) || title.EndsWith(".docx", StringComparison.OrdinalIgnoreCase) ||
        title.EndsWith(".pdf", StringComparison.OrdinalIgnoreCase) || title.EndsWith(".tex", StringComparison.OrdinalIgnoreCase) ||
        title.EndsWith(".dvi", StringComparison.OrdinalIgnoreCase) || title.StartsWith("Microsoft Word - ", StringComparison.OrdinalIgnoreCase) ||
        title.Equals("untitled", StringComparison.OrdinalIgnoreCase);

    /// <summary>A laid-out page's blocks as tag blocks; consecutive list paragraphs make one list.</summary>
    private static IEnumerable<TagBlock> Blocks(int page, DocPage laid)
    {
        List<DocParagraph>? list = null;
        foreach (var b in laid.Blocks.Append(null))
        {
            if (b is DocParagraph { List: not ListKind.None } item && item.HeadingLevel == 0)
            {
                (list ??= []).Add(item);
                continue;
            }
            // A numbered section title ("3.1 Encoder Stacks") in bold reads as a list item of one: it is a heading.
            if (list is [var only] && only.AllBold && only.Text.Trim().Length <= 120 && SectionDepth(only.Text) is { } depth)
            {
                yield return new TagBlock(page, TagBlockKind.Heading, Bounds(only.Sources.Count > 0 ? only.Sources : [only.Box]))
                {
                    Level = Math.Min(depth, 6), Sources = only.Sources, Text = only.Text.Trim(),
                };
                list = null;
            }
            if (list is not null)
            {
                yield return new TagBlock(page, TagBlockKind.List, list.Select(i => i.Box).Aggregate((x, y) => x.Union(y)))
                {
                    Items = [.. list.Select(i => new TagListItem(i.Sources, i.Text.Trim()))],
                    Text = string.Join("\n", list.Select(i => i.Text.Trim())),
                };
                list = null;
            }
            switch (b)
            {
                case DocParagraph p when p.Sources.Count > 0:
                {
                    // Text set sideways in a margin (an arXiv stamp, a running title) isn't a heading, however large.
                    var area = Bounds(p.Sources);
                    var heading = p.HeadingLevel > 0 && !(area.Height > 3 * area.Width && p.Text.Trim().Length > 3);
                    yield return new TagBlock(page, heading ? TagBlockKind.Heading : TagBlockKind.Paragraph, area)
                    {
                        Level = heading ? p.HeadingLevel : 0, Sources = p.Sources, Text = p.Text.Trim(),
                    };
                    break;
                }
                case DocTable t:
                    var rows = t.Rows.Select(r => (IReadOnlyList<TagCell>)[.. r.Select(c => new TagCell(
                        [.. c.Paragraphs.SelectMany(x => x.Sources)], c.Text.Trim(), c.ColSpan)
                    {
                        Pictures = [.. c.Pictures.Select(x => x.Image.PageBox ?? x.Box)],
                    })]).ToList();
                    var all = rows.SelectMany(r => r).SelectMany(c => c.Sources.Concat(c.Pictures)).ToList();
                    if (all.Count == 0) break;
                    yield return new TagBlock(page, TagBlockKind.Table, Bounds(all))
                    {
                        Rows = rows,
                        // Column headers: a first row in bold over rows that aren't.
                        HeaderRow = t.Rows.Count > 1 && t.Rows[0].All(c => c.Paragraphs.Count == 0 || c.Paragraphs.All(x => x.AllBold)) &&
                                    t.Rows[0].Any(c => c.Paragraphs.Count > 0) &&
                                    !t.Rows.Skip(1).All(r => r.All(c => c.Paragraphs.Count == 0 || c.Paragraphs.All(x => x.AllBold))),
                        Text = string.Join(" | ", rows.Take(1).SelectMany(r => r).Select(c => c.Text)),
                    };
                    break;
                case DocPicture pic:
                    var box = pic.Image.PageBox ?? pic.Box;
                    yield return new TagBlock(page, TagBlockKind.Figure, box) { Sources = [box] };
                    break;
            }
        }
    }

    /// <summary>How deep a section number at the start goes ("3" 1, "3.1" 2, "A.2.1" 3), or null when the text doesn't start with one.</summary>
    internal static int? SectionDepth(string text)
    {
        var m = System.Text.RegularExpressions.Regex.Match(text.TrimStart(), @"^(\d{1,3}|[A-Z])((\.\d{1,3})*)\.?\s+\p{L}");
        return m.Success ? 1 + m.Groups[2].Value.Count(c => c == '.') : null;
    }

    private static RectD Bounds(IEnumerable<RectD> boxes) => boxes.Aggregate((a, b) => a.Union(b));

    /// <summary>Heading levels as written: the first is H1 and none skips a level (H1 then H3 becomes H1 then H2).</summary>
    public static IReadOnlyList<TagBlock> EvenHeadings(IReadOnlyList<TagBlock> blocks)
    {
        var current = 0;
        return [.. blocks.Select(b =>
        {
            if (b.Kind != TagBlockKind.Heading) return b;
            var level = Math.Clamp(Math.Min(b.Level, current + 1), 1, 6);
            current = level;
            return level == b.Level ? b : b with { Level = level };
        })];
    }

    /// <summary>A figure as a PNG, at most <paramref name="maxSide"/> pixels on its longer side (for a vision model).</summary>
    public static byte[] FigurePng(PdfEngine engine, int page, RectD box, int maxSide = 768)
    {
        var scale = Math.Clamp(maxSide / Math.Max(1, Math.Max(box.Width, box.Height)), 0.25, 4);
        var img = engine.Render(page, scale, box);
        var rgb = new byte[img.Width * img.Height * 3];
        for (var i = 0; i < rgb.Length; i += 3)
        {
            rgb[i] = img.Pixels[i + 2];
            rgb[i + 1] = img.Pixels[i + 1];
            rgb[i + 2] = img.Pixels[i];
        }
        return PngEncoder.Encode(img.Width, img.Height, rgb, alpha: false);
    }

    /// <summary>The text of the blocks on a figure's page nearest it (a caption, the paragraph that mentions it), up to <paramref name="max"/> characters.</summary>
    public static string NearbyText(TagPlan plan, int index, int max = 1500)
    {
        if (index < 0 || index >= plan.Blocks.Count) return "";
        var fig = plan.Blocks[index];
        var near = plan.Blocks.Where(b => b.Page == fig.Page && !ReferenceEquals(b, fig) && b.Text.Length > 0)
            .OrderBy(b => Math.Max(0, Math.Max(b.Box.Y - fig.Box.Bottom, fig.Box.Y - b.Box.Bottom)))
            .Select(b => b.Text);
        var sb = new System.Text.StringBuilder();
        foreach (var t in near)
        {
            if (sb.Length + t.Length > max) break;
            sb.AppendLine(t);
        }
        return sb.ToString().Trim();
    }

    /// <summary>The plan's blocks with one moved: within its page, <paramref name="by"/> places up (negative) or down.</summary>
    public static TagPlan Move(TagPlan plan, int index, int by)
    {
        if (index < 0 || index >= plan.Blocks.Count || by == 0) return plan;
        var page = plan.Blocks[index].Page;
        var target = index;
        for (var step = Math.Abs(by); step > 0; step--)
        {
            var next = target + Math.Sign(by);
            if (next < 0 || next >= plan.Blocks.Count || plan.Blocks[next].Page != page) break;
            target = next;
        }
        if (target == index) return plan;
        var blocks = plan.Blocks.ToList();
        var b = blocks[index];
        blocks.RemoveAt(index);
        blocks.Insert(target, b);
        return plan with { Blocks = blocks };
    }

    /// <summary>The plan with block <paramref name="index"/> changed (alternate text, decorative, kind).</summary>
    public static TagPlan With(TagPlan plan, int index, Func<TagBlock, TagBlock> change)
    {
        if (index < 0 || index >= plan.Blocks.Count) return plan;
        var blocks = plan.Blocks.ToList();
        blocks[index] = change(blocks[index]);
        return plan with { Blocks = blocks };
    }
}
