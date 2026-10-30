using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// What a tag block becomes: a paragraph (P), a heading (H1-H6), a list (L › LI › LBody, nested lists inside an item's
/// LBody), a table, a figure, a figure's or table's caption (Caption: inside the table it belongs to), a footnote (Note,
/// with an ID), a table of contents (TOC › TOCI) or display math (Formula, with alternate text).
/// </summary>
public enum TagBlockKind { Paragraph, Heading, List, Table, Figure, Caption, Note, Contents, Formula }

/// <summary>Where the title Make Accessible proposes came from.</summary>
public enum TitleSource { Metadata, Heading, None }

/// <summary>A list item (or contents entry): where its text is on the page (as shown) and the text, for the reading order panel.</summary>
public sealed record TagListItem(IReadOnlyList<RectD> Sources, string Text)
{
    /// <summary>How deep it is nested: 0 for the list's own items, 1 for a list inside one of them, and so on.</summary>
    public int Level { get; init; }
}

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

    /// <summary>How many rows at the top hold column headers (TH with Scope Column): two when a header spans columns over the headers under it.</summary>
    public int HeaderRows { get; init; }

    /// <summary>The table has column headers (<see cref="HeaderRows"/> above 0).</summary>
    public bool HeaderRow => HeaderRows > 0;

    /// <summary>Each row's first cell is its row header (TH with Scope Row).</summary>
    public bool HeaderColumn { get; init; }

    /// <summary>The language of this passage when it isn't the document's (a code such as "es"); null: the document's.</summary>
    public string? Lang { get; init; }

    /// <summary>A figure's or formula's alternate text (a formula's is its text until someone writes another).</summary>
    public string? Alt { get; init; }

    /// <summary>A figure that only decorates: marked as an artifact, no alternate text needed.</summary>
    public bool Decorative { get; init; }

    /// <summary>
    /// The page it is read with when that isn't its own (a sidebar continuing an article from the page before): its
    /// content stays on <see cref="Page"/>, the structure reads it among that page's pieces. Null: its own page.
    /// </summary>
    public int? ReadWith { get; init; }
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
        var body = DocLayout.BodySize(pages);
        var blocks = new List<TagBlock>();
        for (var p = 0; p < layout.Pages.Count; p++) blocks.AddRange(Blocks(p, layout.Pages[p], body, pages[p].Height));

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
                    var match = alts.Where(a => a.Page == b.Page && a.Box is { } box && Area(box.Intersect(b.Box)) > 0.5 * Math.Min(Area(box), Area(b.Box)))
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

    /// <summary>
    /// The Figure tags with alternate text: page, box (page space as shown; null when the tag gives none) and text. A
    /// page given on a tag holds for what's inside it, a role map's own names for figures count, and the attributes may be
    /// one dictionary or a list.
    /// </summary>
    internal static List<(int Page, RectD? Box, string Alt)> FigureAlts(PdfDocument doc)
    {
        var found = new List<(int, RectD?, string)>();
        var pages = doc.Pages.Cast<PdfPage>().ToList();
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        var root = PdfObj.Dict(doc.Internals.Catalog.Elements["/StructTreeRoot"]);
        var roles = PdfObj.Dict(root?.Elements["/RoleMap"]);
        bool IsFigure(string? name)
        {
            for (var i = 0; i < 8 && name is not null; i++)
            {
                if (name == "Figure") return true;
                name = PdfObj.Name(roles?.Elements["/" + name]);
            }
            return false;
        }
        PdfArray? BoxOf(PdfDictionary d)
        {
            var attributes = PdfObj.Resolve(d.Elements["/A"]);
            IEnumerable<PdfItem> list = attributes is PdfArray many ? many.Elements : attributes is null ? [] : [attributes];
            return list.Select(a => PdfObj.Array(PdfObj.Dict(a)?.Elements["/BBox"])).FirstOrDefault(b => b is { Elements.Count: 4 });
        }
        void Visit(PdfItem? item, int depth, int inherited)
        {
            if (depth > 64 || found.Count > 10_000) return;
            switch (PdfObj.Resolve(item))
            {
                case PdfArray a:
                    foreach (var x in a.Elements) Visit(x, depth + 1, inherited);
                    break;
                case PdfDictionary d when seen.Add(d):
                    var own = d.Elements.ContainsKey("/Pg") ? PdfObj.PageIndexOf(doc, d.Elements["/Pg"]) : -1;
                    var p = own >= 0 ? own : inherited;
                    if (IsFigure(PdfObj.Name(d.Elements["/S"])) && PdfObj.Text(d.Elements["/Alt"]) is { Length: > 0 } alt && p >= 0)
                    {
                        RectD? box = null;
                        if (BoxOf(d) is { } bb)
                        {
                            var page = pages[p];
                            var (x1, y1) = PdfObj.ToPage(page, PdfObj.Num(bb, 0), PdfObj.Num(bb, 1));
                            var (x2, y2) = PdfObj.ToPage(page, PdfObj.Num(bb, 2), PdfObj.Num(bb, 3));
                            box = RectD.FromEdges(Math.Min(x1, x2), Math.Min(y1, y2), Math.Max(x1, x2), Math.Max(y1, y2));
                        }
                        found.Add((p, box, alt));
                    }
                    Visit(d.Elements["/K"], depth + 1, p);
                    break;
            }
        }
        Visit(root?.Elements["/K"], 0, -1);
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

    /// <summary>The page a block is read with: its own, or the one it was moved to (<see cref="TagBlock.ReadWith"/>).</summary>
    public static int ReadingPage(TagBlock b) => b.ReadWith ?? b.Page;

    /// <summary>
    /// The plan with one block read with the page before (<paramref name="by"/> -1: after that page's last piece) or after
    /// (1: before its first piece); back on its own page it is its own page's piece again. The plan unchanged when there is
    /// no such page.
    /// </summary>
    public static TagPlan MoveToPage(TagPlan plan, int index, int by)
    {
        if (index < 0 || index >= plan.Blocks.Count || by is not (-1 or 1)) return plan;
        var b = plan.Blocks[index];
        var page = ReadingPage(b) + by;
        if (page < 0 || page >= plan.Pages) return plan;
        var blocks = plan.Blocks.ToList();
        blocks.RemoveAt(index);
        var moved = b with { ReadWith = page == b.Page ? null : page };
        // Pieces are kept in page order of their reading page: after the last one read with a page before or on it, or
        // before the first one read with a page after it.
        var at = by < 0 ? blocks.FindLastIndex(x => ReadingPage(x) <= page) + 1 : blocks.FindIndex(x => ReadingPage(x) >= page);
        blocks.Insert(at < 0 ? blocks.Count : at, moved);
        return plan with { Blocks = blocks };
    }

    /// <summary>The plan's blocks with one moved among those read with its page, <paramref name="by"/> places up (negative) or down.</summary>
    public static TagPlan Move(TagPlan plan, int index, int by)
    {
        if (index < 0 || index >= plan.Blocks.Count || by == 0) return plan;
        var page = ReadingPage(plan.Blocks[index]);
        var target = index;
        for (var step = Math.Abs(by); step > 0; step--)
        {
            var next = target + Math.Sign(by);
            if (next < 0 || next >= plan.Blocks.Count || ReadingPage(plan.Blocks[next]) != page) break;
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
