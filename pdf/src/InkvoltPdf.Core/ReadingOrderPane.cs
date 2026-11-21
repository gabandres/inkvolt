namespace InkvoltPdf.Core;

/// <summary>One piece of a page in the reading order panel: its number, what it is, the start of its text.</summary>
public sealed class ReadingOrderItem(int index, int number, TagBlock block)
{
    /// <summary>The block's index in the plan.</summary>
    public int Index { get; } = index;
    public TagBlock Block { get; } = block;

    /// <summary>Its place among the pieces read with its page.</summary>
    public int Number { get; } = number;

    public bool NeedsAlt => Block.Kind == TagBlockKind.Figure && !Block.Decorative && string.IsNullOrWhiteSpace(Block.Alt);

    public string Kind => Block.Kind switch
    {
        TagBlockKind.Heading => Loc.Format(PdfStrings.ReadingOrder_Heading, Block.Level),
        TagBlockKind.List => Block.Items.Any(i => i.Level > 0)
            ? Loc.Plural(Block.Items.Count, PdfStrings.ReadingOrder_ListNested_One, PdfStrings.ReadingOrder_ListNested_Many)
            : Loc.Plural(Block.Items.Count, PdfStrings.ReadingOrder_List_One, PdfStrings.ReadingOrder_List_Many),
        TagBlockKind.Table => Loc.Plural(Block.Rows.Count, PdfStrings.ReadingOrder_Table_One, PdfStrings.ReadingOrder_Table_Many,
            (Block.HeaderRow, Block.HeaderColumn) switch
            {
                (true, true) => PdfStrings.ReadingOrder_TableBothHeaders,
                (true, false) => PdfStrings.ReadingOrder_TableColumnHeaders,
                (false, true) => PdfStrings.ReadingOrder_TableRowHeaders,
                _ => "",
            }),
        TagBlockKind.Caption => PdfStrings.ReadingOrder_Caption,
        TagBlockKind.Note => PdfStrings.ReadingOrder_Footnote,
        TagBlockKind.Contents => Loc.Plural(Block.Items.Count, PdfStrings.ReadingOrder_Contents_One, PdfStrings.ReadingOrder_Contents_Many),
        TagBlockKind.Formula => PdfStrings.ReadingOrder_Formula,
        TagBlockKind.Figure when Block.Decorative => PdfStrings.ReadingOrder_PictureDecorative,
        TagBlockKind.Figure => NeedsAlt ? PdfStrings.ReadingOrder_PictureNeedsAlt : PdfStrings.ReadingOrder_Picture,
        _ => Block.Lang is { } lang ? Loc.Format(PdfStrings.ReadingOrder_ParagraphLang, lang) : PdfStrings.ReadingOrder_Paragraph,
    } + (Block.ReadWith is null ? "" : Loc.Format(PdfStrings.ReadingOrder_FromPage, Block.Page + 1));

    public string Preview => Block.Kind is TagBlockKind.Figure or TagBlockKind.Formula ? Block.Alt ?? Block.Text : Block.Text.Replace('\n', ' ');

    /// <summary>What a screen reader says for the item.</summary>
    public string Spoken => $"{Number}. {Kind}. {(Preview.Length > 120 ? Preview[..120] : Preview)}";
}

/// <summary>A kind the selected piece can be made, as the panel's Kind list shows it.</summary>
public sealed record PieceKind(TagBlockKind Kind, int Level, string Label);

/// <summary>A numbered box of the reading order panel: where a piece is, its place in its page's order, and how it shows.</summary>
public readonly record struct ReadingOrderBox(int Page, RectD Box, int Number, bool Selected, bool NeedsAlt);

/// <summary>What the reading order panel shows for a plan on a page (<see cref="ReadingOrderPane.State"/>).</summary>
public sealed record ReadingOrderState
{
    /// <summary>The pieces read with this page, in order.</summary>
    public IReadOnlyList<ReadingOrderItem> Items { get; init; } = [];

    /// <summary>The boxes on every page (none when the document changed since the plan was made).</summary>
    public IReadOnlyList<ReadingOrderBox> Boxes { get; init; } = [];

    public string Summary { get; init; } = "";

    /// <summary>The list, the piece's kind and its alternate text can be changed (the plan is for the document as it is).</summary>
    public bool Editable { get; init; }

    public bool CanMoveToPageBefore { get; init; }
    public bool CanMoveToPageAfter { get; init; }
    public bool CanApply { get; init; }
}

/// <summary>
/// What the panel shows for the selected piece: the kinds it can be made and the one it is, and for a picture or a formula
/// its alternate text (a formula's is what a screen reader says for it: its text to begin with).
/// </summary>
public sealed record ReadingOrderPiece(IReadOnlyList<PieceKind> Kinds, int? CurrentKind)
{
    /// <summary>A picture or a formula: the alternate text shows.</summary>
    public bool HasAlt { get; init; }

    public bool IsFormula { get; init; }
    public string AltText { get; init; } = "";

    /// <summary>The alternate text can be typed (a decorative picture has none).</summary>
    public bool AltEditable { get; init; }

    public bool Decorative { get; init; }

    /// <summary>The label over the alternate text ("Alternate text for picture 3", "How formula 2 is read").</summary>
    public string AltLabel { get; init; } = "";

    /// <summary>Decorative and Suggest with AI show for a picture only.</summary>
    public bool OffersDecorative => HasAlt && !IsFormula;
}

/// <summary>An edit the reading order panel makes to the plan.</summary>
public enum ReadingOrderEdit { Move, MoveToPage, Drop, Kind, AltText, Decorative, Apply }

/// <summary>
/// The reading order panel's rules and words (Review › Reading Order and Alt Text over a <see cref="TagPlan"/>), so
/// <c>DocumentTab.ReadingOrder</c> only shows them. The Mac's <c>ReadingOrder</c> (PdfCore) is the spec; where Windows did
/// more (where the selection goes after a move, the piece editor, the words announced, which edits are Pro), it is kept
/// and said so below. Make Accessible's window (title, language, what was found) stays in <c>AccessibleActions</c>.
/// Named for the pane here: Core's <see cref="ReadingOrder"/> is the order of fields and links on a page.
/// </summary>
public static class ReadingOrderPane
{
    /// <summary>
    /// The list for <paramref name="page"/>, the boxes on every page, the summary and what can be done.
    /// <paramref name="selected"/>: the block's index in the plan; <paramref name="stale"/>: the document changed since
    /// the plan was made; <paramref name="written"/>: the plan is in the document as it is now.
    /// </summary>
    public static ReadingOrderState State(TagPlan plan, int page, int? selected, bool stale, bool written)
    {
        page = Math.Clamp(page, 0, Math.Max(0, plan.Pages - 1));
        var items = new List<ReadingOrderItem>();
        var boxes = new List<ReadingOrderBox>();
        var numbers = new Dictionary<int, int>();
        var readElsewhere = 0;
        var blocks = AutoTag.EvenHeadings(plan.Blocks); // heading levels as they are written
        for (var i = 0; i < blocks.Count; i++)
        {
            // Numbered among the pieces read with its page (a piece moved to another page is numbered there; its box
            // stays where its content is).
            var b = blocks[i];
            var reading = AutoTag.ReadingPage(b);
            var n = numbers[reading] = numbers.GetValueOrDefault(reading) + 1;
            var item = new ReadingOrderItem(i, n, b);
            if (reading == page) items.Add(item);
            else if (b.Page == page) readElsewhere++;
            if (!stale) boxes.Add(new ReadingOrderBox(b.Page, b.Box, n, i == selected, item.NeedsAlt));
        }
        var missing = plan.FiguresWithoutAlt;
        var summary = stale
            ? PdfStrings.ReadingOrder_Stale
            : string.Join(" ", new[]
            {
                Loc.Plural(items.Count, PdfStrings.ReadingOrder_Summary_One, PdfStrings.ReadingOrder_Summary_Many, page + 1),
                readElsewhere == 0 ? null : Loc.Plural(readElsewhere, PdfStrings.ReadingOrder_ReadElsewhere_One, PdfStrings.ReadingOrder_ReadElsewhere_Many),
                missing == 0 ? PdfStrings.ReadingOrder_AllAlt : Loc.Plural(missing, PdfStrings.ReadingOrder_MissingAlt_One, PdfStrings.ReadingOrder_MissingAlt_Many),
                written ? PdfStrings.ReadingOrder_Tagged : PdfStrings.ReadingOrder_ApplyToTag,
            }.OfType<string>());
        return new ReadingOrderState
        {
            Items = items,
            Boxes = boxes,
            Summary = summary,
            Editable = !stale,
            CanMoveToPageBefore = !stale && page > 0,
            CanMoveToPageAfter = !stale && page < plan.Pages - 1,
            CanApply = !stale && !written,
        };
    }

    /// <summary>The first piece read with <paramref name="page"/>, or null.</summary>
    public static int? FirstPiece(TagPlan plan, int page)
    {
        for (var i = 0; i < plan.Blocks.Count; i++)
            if (AutoTag.ReadingPage(plan.Blocks[i]) == page) return i;
        return null;
    }

    /// <summary>
    /// The page Page Up (-1) or Page Down (1) in the list shows from <paramref name="current"/>, or null when there is none
    /// (a Windows rule; the Mac turns its pages itself).
    /// </summary>
    public static int? PageShown(TagPlan plan, int current, int by)
    {
        var page = current + by;
        return page < 0 || page >= plan.Pages || page == current ? null : page;
    }

    /// <summary>
    /// The plan with piece <paramref name="index"/> moved <paramref name="by"/> places among those read with its page
    /// (Alt+Up/Down) and its new index, to keep it selected (Windows'); null when it can't move that way.
    /// </summary>
    public static (TagPlan Plan, int Index)? Moved(TagPlan plan, int index, int by)
    {
        var moved = AutoTag.Move(plan, index, by);
        if (ReferenceEquals(moved, plan)) return null;
        var block = plan.Blocks[index];
        for (var i = 0; i < moved.Blocks.Count; i++)
            if (ReferenceEquals(moved.Blocks[i], block)) return (moved, i);
        return null;
    }

    /// <summary>
    /// The plan with piece <paramref name="index"/> read with the page before (-1) or after (1), the piece's new index and
    /// that page; null when there is no such page.
    /// </summary>
    public static (TagPlan Plan, int Index, int Page)? MovedToPage(TagPlan plan, int index, int by)
    {
        if (index < 0 || index >= plan.Blocks.Count) return null;
        var moved = AutoTag.MoveToPage(plan, index, by);
        if (ReferenceEquals(moved, plan)) return null;
        var was = plan.Blocks[index];
        for (var i = 0; i < moved.Blocks.Count; i++)
        {
            var b = moved.Blocks[i];
            if (b.Box == was.Box && b.Page == was.Page && b.Kind == was.Kind) return (moved, i, AutoTag.ReadingPage(b));
        }
        return null;
    }

    /// <summary>The plan with the piece at <paramref name="from"/> dropped on the piece at <paramref name="onto"/> (a drag in the list, within a page).</summary>
    public static TagPlan Dropped(TagPlan plan, int from, int onto) => AutoTag.Move(plan, from, onto - from);

    /// <summary>The plan with a picture's or formula's alternate text typed; unchanged for another kind.</summary>
    public static TagPlan WithAlt(TagPlan plan, int index, string text) =>
        index >= 0 && index < plan.Blocks.Count && plan.Blocks[index].Kind is TagBlockKind.Figure or TagBlockKind.Formula
            ? AutoTag.With(plan, index, b => b with { Alt = text })
            : plan;

    /// <summary>The plan with a picture marked decorative or not; unchanged for another kind.</summary>
    public static TagPlan WithDecorative(TagPlan plan, int index, bool decorative) =>
        index >= 0 && index < plan.Blocks.Count && plan.Blocks[index].Kind == TagBlockKind.Figure
            ? AutoTag.With(plan, index, b => b with { Decorative = decorative })
            : plan;

    /// <summary>
    /// Whether an edit is one of the panel's fixes, which are Inkvolt Pro (<see cref="ProFeature.ReadingOrder"/>): moving a
    /// piece, changing its kind, applying the tags. Looking at the order and a picture's alternate text stay free (a
    /// Windows rule; the Mac has no Pro).
    /// </summary>
    public static bool IsFix(ReadingOrderEdit edit) => edit is not (ReadingOrderEdit.AltText or ReadingOrderEdit.Decorative);

    // ---- a piece's kind ----

    /// <summary>The kinds a piece can be made (<see cref="AutoTag.KindsFor"/>), a heading at each level, as the Kind list shows them.</summary>
    public static IReadOnlyList<PieceKind> Kinds(TagBlock b)
    {
        var list = new List<PieceKind>();
        foreach (var k in AutoTag.KindsFor(b))
        {
            if (k == TagBlockKind.Heading)
            {
                for (var level = 1; level <= 6; level++) list.Add(new PieceKind(k, level, Loc.Format(PdfStrings.ReadingOrder_Heading, level)));
                continue;
            }
            list.Add(new PieceKind(k, 0, k switch
            {
                TagBlockKind.List => PdfStrings.ReadingOrder_KindList,
                TagBlockKind.Contents => PdfStrings.ReadingOrder_KindContents,
                TagBlockKind.Table => PdfStrings.ReadingOrder_KindTable,
                TagBlockKind.Caption => PdfStrings.ReadingOrder_Caption,
                TagBlockKind.Note => PdfStrings.ReadingOrder_Footnote,
                TagBlockKind.Formula => PdfStrings.ReadingOrder_Formula,
                TagBlockKind.Figure => PdfStrings.ReadingOrder_Picture,
                _ => PdfStrings.ReadingOrder_Paragraph,
            }));
        }
        return list;
    }

    /// <summary>The entry of <paramref name="kinds"/> that says what the piece is now, or null.</summary>
    public static int? CurrentKind(TagBlock b, IReadOnlyList<PieceKind> kinds)
    {
        for (var i = 0; i < kinds.Count; i++)
            if (kinds[i].Kind == b.Kind && (b.Kind != TagBlockKind.Heading || kinds[i].Level == Math.Clamp(b.Level, 1, 6))) return i;
        return null;
    }

    /// <summary>The plan with piece <paramref name="index"/> made <paramref name="kind"/>; the same plan when nothing changes.</summary>
    public static TagPlan WithKind(TagPlan plan, int index, PieceKind kind) => AutoTag.WithKind(plan, index, kind.Kind, Math.Max(1, kind.Level));

    /// <summary>What the panel shows for the selected piece (Windows' piece editor; the Mac lays its own out).</summary>
    public static ReadingOrderPiece Piece(ReadingOrderItem item)
    {
        var b = item.Block;
        var kinds = Kinds(b);
        var piece = new ReadingOrderPiece(kinds, CurrentKind(b, kinds));
        if (b.Kind is not (TagBlockKind.Figure or TagBlockKind.Formula)) return piece;
        var formula = b.Kind == TagBlockKind.Formula;
        return piece with
        {
            HasAlt = true,
            IsFormula = formula,
            AltText = b.Alt ?? (formula ? b.Text : ""),
            AltEditable = !b.Decorative,
            Decorative = b.Decorative,
            AltLabel = Loc.Format(formula ? PdfStrings.ReadingOrder_FormulaRead : PdfStrings.ReadingOrder_AltFor, item.Number),
        };
    }

    // ---- what is announced ----

    /// <summary>Once a piece was made another kind.</summary>
    public static string KindChanged(int number, string label) => Loc.Format(PdfStrings.ReadingOrder_KindChanged, number, label);

    /// <summary>Once a piece moved within its page (Windows').</summary>
    public static string MovedTo(int? number) => Loc.Format(PdfStrings.ReadingOrder_MovedTo, number);

    /// <summary>Once a piece is read with another page (Windows'; <paramref name="page"/> from 0).</summary>
    public static string ReadWith(int page, int? number) => Loc.Format(PdfStrings.ReadingOrder_ReadWith, page + 1, number);

    /// <summary>Once the list shows another page (Windows'; <paramref name="page"/> from 0).</summary>
    public static string PagePieces(int count, int page) =>
        Loc.Plural(count, PdfStrings.ReadingOrder_PagePieces_One, PdfStrings.ReadingOrder_PagePieces_Many, page + 1);
}
