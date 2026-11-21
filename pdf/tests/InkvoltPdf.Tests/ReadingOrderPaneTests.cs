using InkvoltPdf.Core;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// The reading order panel's rules (<see cref="ReadingOrderPane"/>; <c>DocumentTab.ReadingOrder</c> only shows them): the
/// list and boxes of a page, the summary, moves within and to another page, a drop, the kind list, alternate text and
/// decorative pictures, and which edits are Pro. The names are the Mac's <c>ReadingOrderTests</c> where they apply.
/// </summary>
public class ReadingOrderPaneTests
{
    private static TagPlan Plan()
    {
        var pdf = ExportTestPdf.Make();
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return AutoTag.Plan(engine, pdf, null);
    }

    [Fact]
    public void The_list_shows_the_pages_pieces_numbered_and_the_boxes_every_page()
    {
        var plan = Plan();
        var s = ReadingOrderPane.State(plan, page: 0, selected: 0, stale: false, written: false);
        var onFirst = plan.Blocks.Count(b => b.Page == 0);
        Assert.Equal(onFirst, s.Items.Count);
        Assert.Equal(Enumerable.Range(1, onFirst), s.Items.Select(i => i.Number));
        Assert.Equal("Heading 1", s.Items[0].Kind);
        Assert.Equal(plan.Blocks.Count, s.Boxes.Count);
        Assert.True(s.Boxes[0].Selected && !s.Boxes[1].Selected);
        Assert.Contains(s.Boxes, b => b.NeedsAlt);
        Assert.StartsWith($"{onFirst} pieces on page 1, in the order a screen reader reads them. 1 picture needs alternate text.", s.Summary, StringComparison.Ordinal);
        Assert.EndsWith("Apply changes to tag the document this way.", s.Summary, StringComparison.Ordinal);
        Assert.True(s.CanApply && s.Editable && !s.CanMoveToPageBefore && s.CanMoveToPageAfter);
        // The page is kept within the document; written: nothing to apply.
        var last = ReadingOrderPane.State(plan, page: 99, selected: null, stale: false, written: true);
        Assert.All(last.Items, i => Assert.Equal(plan.Pages - 1, AutoTag.ReadingPage(i.Block)));
        Assert.EndsWith("The document is tagged this way.", last.Summary, StringComparison.Ordinal);
        Assert.True(!last.CanApply && last.CanMoveToPageBefore && !last.CanMoveToPageAfter);
        Assert.DoesNotContain(last.Boxes, b => b.Selected);
    }

    [Fact]
    public void Each_kind_is_said_in_words()
    {
        var plan = Plan();
        var kinds = ReadingOrderPane.State(plan, 0, null, stale: false, written: true).Items.Select(i => i.Kind).ToList();
        Assert.Contains("Heading 2", kinds);
        Assert.Contains("List (3 items)", kinds);
        Assert.Contains(kinds, k => k.StartsWith("Table (4 rows, column headers", StringComparison.Ordinal));
        Assert.Contains("Picture: needs alternate text", kinds);
        var fig = plan.Blocks.First(b => b.Kind == TagBlockKind.Figure) with { Decorative = true };
        Assert.Equal("Picture (decorative)", new ReadingOrderItem(0, 1, fig).Kind);
        Assert.False(new ReadingOrderItem(0, 1, fig).NeedsAlt);
        var item = new ReadingOrderItem(0, 3, fig with { Decorative = false, Alt = "Sales by quarter" });
        Assert.Equal("Picture", item.Kind);
        Assert.Equal("3. Picture. Sales by quarter", item.Spoken);
        // The rest, from blocks made for the purpose.
        var box = new RectD(0, 0, 10, 10);
        Assert.Equal("Paragraph (es)", new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.Paragraph, box) { Lang = "es", Text = "a\nb" }).Kind);
        Assert.Equal("a b", new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.Paragraph, box) { Text = "a\nb" }).Preview);
        Assert.Equal("Caption", new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.Caption, box)).Kind);
        Assert.Equal("Footnote", new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.Note, box)).Kind);
        Assert.Equal("Formula", new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.Formula, box) { Text = "x²" }).Kind);
        Assert.Equal("x²", new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.Formula, box) { Text = "x²" }).Preview);
        TagListItem Entry(int level) => new([], "entry") { Level = level };
        Assert.Equal("List (1 item, nested)", new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.List, box) { Items = [Entry(1)] }).Kind);
        Assert.Equal("Table of contents (2 entries)", new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.Contents, box) { Items = [Entry(0), Entry(0)] }).Kind);
        Assert.Equal("Table (1 row, row headers)", new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.Table, box) { Rows = [[]], HeaderColumn = true }).Kind);
        Assert.Equal("Table (2 rows)", new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.Table, box) { Rows = [[], []] }).Kind);
        var longText = new string('w', 300);
        Assert.Equal(1 + 2 + "Paragraph".Length + 2 + 120, new ReadingOrderItem(0, 1, new TagBlock(0, TagBlockKind.Paragraph, box) { Text = longText }).Spoken.Length);
    }

    [Fact]
    public void A_piece_read_with_another_page_is_listed_there_and_its_box_stays()
    {
        var plan = Plan();
        var at = plan.Blocks.ToList().FindIndex(b => b.Page == 1);
        var moved = ReadingOrderPane.MovedToPage(plan, at, -1);
        Assert.NotNull(moved);
        Assert.Equal(0, moved.Value.Page);
        var first = ReadingOrderPane.State(moved.Value.Plan, 0, moved.Value.Index, stale: false, written: false);
        Assert.Equal(moved.Value.Index, first.Items[^1].Index);
        Assert.EndsWith(" · from page 2", first.Items[^1].Kind, StringComparison.Ordinal);
        Assert.Equal(1, first.Boxes.Single(b => b.Selected).Page); // where its content is
        var second = ReadingOrderPane.State(moved.Value.Plan, 1, null, stale: false, written: false);
        Assert.Contains("1 piece here is read with another page.", second.Summary, StringComparison.Ordinal);
        Assert.Null(ReadingOrderPane.MovedToPage(moved.Value.Plan, moved.Value.Index, -1)); // no page before the first
        Assert.Null(ReadingOrderPane.MovedToPage(plan, -1, 1));
        Assert.Equal(at, ReadingOrderPane.FirstPiece(plan, 1));
        Assert.Null(ReadingOrderPane.FirstPiece(plan, 9));
        Assert.Equal("Read with page 1, place 4", ReadingOrderPane.ReadWith(0, 4));
    }

    [Fact]
    public void A_drop_moves_within_the_page_only()
    {
        var plan = Plan();
        var last = plan.Blocks.ToList().FindLastIndex(b => b.Page == 0);
        Assert.Equal(plan.Blocks[last], ReadingOrderPane.Dropped(plan, last, onto: 0).Blocks[0]);
        Assert.Equal(plan.Blocks[0], ReadingOrderPane.Dropped(plan, 0, onto: last + 1).Blocks[last]); // stops at its page's last place
    }

    /// <summary>Windows': Alt+Up/Down moves a piece a place within its page and keeps it selected where it went.</summary>
    [Fact]
    public void A_move_keeps_the_piece_selected_and_stops_at_its_page()
    {
        var plan = Plan();
        var down = ReadingOrderPane.Moved(plan, 0, 1);
        Assert.NotNull(down);
        Assert.Equal(1, down.Value.Index);
        Assert.Same(plan.Blocks[0], down.Value.Plan.Blocks[1]);
        Assert.Null(ReadingOrderPane.Moved(plan, 0, -1)); // already first
        var last = plan.Blocks.ToList().FindLastIndex(b => b.Page == 0);
        Assert.Null(ReadingOrderPane.Moved(plan, last, 1)); // the next piece is read with another page
        Assert.Equal(last - 2, ReadingOrderPane.Moved(plan, last, -2)?.Index);
        Assert.Equal("Moved to place 2", ReadingOrderPane.MovedTo(2));
    }

    /// <summary>Windows': Page Up/Down in the list shows the page before or after, while there is one.</summary>
    [Fact]
    public void Page_up_and_down_show_the_page_before_or_after()
    {
        var plan = Plan();
        Assert.Equal(1, ReadingOrderPane.PageShown(plan, 0, 1));
        Assert.Null(ReadingOrderPane.PageShown(plan, 0, -1));
        Assert.Null(ReadingOrderPane.PageShown(plan, plan.Pages - 1, 1));
        Assert.Equal(0, ReadingOrderPane.PageShown(plan, 1, -1));
        Assert.Equal("Page 2: 1 piece", ReadingOrderPane.PagePieces(1, 1));
        Assert.Equal("Page 1: 7 pieces", ReadingOrderPane.PagePieces(7, 0));
    }

    [Fact]
    public void A_stale_plan_says_so_and_offers_nothing()
    {
        var s = ReadingOrderPane.State(Plan(), 0, 0, stale: true, written: false);
        Assert.StartsWith("The document changed since this reading order was made.", s.Summary, StringComparison.Ordinal);
        Assert.True(s.Boxes.Count == 0 && !s.Editable && !s.CanApply && !s.CanMoveToPageAfter && !s.CanMoveToPageBefore);
        Assert.NotEmpty(s.Items); // still listed, to look at
    }

    /// <summary>The Kind list: what each piece can be made, a heading at each level, the entry showing what it is now, and what is announced after a change.</summary>
    [Fact]
    public void The_kind_list_offers_what_a_piece_can_be_made()
    {
        var plan = Plan();
        var p = plan.Blocks.First(b => b.Kind == TagBlockKind.Paragraph);
        var kinds = ReadingOrderPane.Kinds(p);
        Assert.Equal(["Paragraph", "Heading 1", "Heading 2", "Heading 3", "Heading 4", "Heading 5", "Heading 6", "Caption", "Footnote", "Formula", "Picture"],
            kinds.Select(k => k.Label));
        Assert.Equal("Paragraph", kinds[ReadingOrderPane.CurrentKind(p, kinds)!.Value].Label);
        var list = plan.Blocks.First(b => b.Kind == TagBlockKind.List);
        var listKinds = ReadingOrderPane.Kinds(list);
        Assert.Contains("Table of contents", listKinds.Select(k => k.Label));
        Assert.Equal("List", listKinds[ReadingOrderPane.CurrentKind(list, listKinds)!.Value].Label);
        var table = plan.Blocks.First(b => b.Kind == TagBlockKind.Table);
        Assert.Contains("Table", ReadingOrderPane.Kinds(table).Select(k => k.Label));
        var heading = p with { Kind = TagBlockKind.Heading, Level = 3 };
        var hk = ReadingOrderPane.Kinds(heading);
        Assert.Equal("Heading 3", hk[ReadingOrderPane.CurrentKind(heading, hk)!.Value].Label);
        Assert.Null(ReadingOrderPane.CurrentKind(table, kinds)); // not among a paragraph's kinds
        Assert.Equal("Piece 4 is now: Heading 2", ReadingOrderPane.KindChanged(4, "Heading 2"));
        // A choice in the list makes the piece that kind; the one it is already changes nothing.
        var at = plan.Blocks.ToList().IndexOf(p);
        var made = ReadingOrderPane.WithKind(plan, at, kinds[2]);
        Assert.Equal((TagBlockKind.Heading, 2), (made.Blocks[at].Kind, made.Blocks[at].Level));
        Assert.Same(plan, ReadingOrderPane.WithKind(plan, at, kinds[0]));
    }

    /// <summary>Windows' piece editor: the kind list for any piece, the alternate text for a picture or a formula.</summary>
    [Fact]
    public void The_selected_piece_shows_its_kind_and_a_pictures_or_formulas_alternate_text()
    {
        var plan = Plan();
        var s = ReadingOrderPane.State(plan, 0, null, stale: false, written: false);
        var paragraph = ReadingOrderPane.Piece(s.Items.First(i => i.Block.Kind == TagBlockKind.Paragraph));
        Assert.Equal("Paragraph", paragraph.Kinds[paragraph.CurrentKind!.Value].Label);
        Assert.False(paragraph.HasAlt);
        var figure = s.Items.First(i => i.Block.Kind == TagBlockKind.Figure);
        var picture = ReadingOrderPane.Piece(figure);
        Assert.True(picture.HasAlt && picture.AltEditable && picture.OffersDecorative && !picture.Decorative && !picture.IsFormula);
        Assert.Equal("", picture.AltText);
        Assert.Equal($"Alternate text for picture {figure.Number}", picture.AltLabel);
        var decorative = ReadingOrderPane.Piece(new ReadingOrderItem(figure.Index, figure.Number, figure.Block with { Decorative = true }));
        Assert.True(decorative.Decorative && !decorative.AltEditable);
        var formula = ReadingOrderPane.Piece(new ReadingOrderItem(0, 2, new TagBlock(0, TagBlockKind.Formula, new RectD(0, 0, 9, 9)) { Text = "E = mc²" }));
        Assert.True(formula.HasAlt && formula.IsFormula && formula.AltEditable && !formula.OffersDecorative);
        Assert.Equal("E = mc²", formula.AltText); // its text, until someone writes another
        Assert.Equal("How formula 2 is read", formula.AltLabel);
    }

    [Fact]
    public void Alternate_text_and_decorative_go_to_pictures_and_formulas_only()
    {
        var plan = Plan();
        var fig = plan.Blocks.ToList().FindIndex(b => b.Kind == TagBlockKind.Figure);
        var para = plan.Blocks.ToList().FindIndex(b => b.Kind == TagBlockKind.Paragraph);
        var withAlt = ReadingOrderPane.WithAlt(plan, fig, "Sales by quarter");
        Assert.Equal("Sales by quarter", withAlt.Blocks[fig].Alt);
        Assert.Equal(0, withAlt.FiguresWithoutAlt);
        Assert.Same(plan, ReadingOrderPane.WithAlt(plan, para, "text"));
        Assert.Same(plan, ReadingOrderPane.WithAlt(plan, 999, "text"));
        var decorative = ReadingOrderPane.WithDecorative(plan, fig, true);
        Assert.True(decorative.Blocks[fig].Decorative);
        Assert.StartsWith("Every picture has alternate text or is decorative.", ReadingOrderPane.State(decorative, 0, null, false, false).Summary.Split(". ", 2)[1], StringComparison.Ordinal);
        Assert.Same(plan, ReadingOrderPane.WithDecorative(plan, para, true));
    }

    /// <summary>Windows': the panel's fixes are Inkvolt Pro; a picture's alternate text and decorative stay free.</summary>
    [Fact]
    public void Fixing_the_order_is_pro_and_alternate_text_is_free()
    {
        Assert.All([ReadingOrderEdit.Move, ReadingOrderEdit.MoveToPage, ReadingOrderEdit.Drop, ReadingOrderEdit.Kind, ReadingOrderEdit.Apply],
            e => Assert.True(ReadingOrderPane.IsFix(e)));
        Assert.False(ReadingOrderPane.IsFix(ReadingOrderEdit.AltText));
        Assert.False(ReadingOrderPane.IsFix(ReadingOrderEdit.Decorative));
    }
}
