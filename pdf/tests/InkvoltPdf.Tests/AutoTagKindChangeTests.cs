using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// Make Accessible (roadmap 2.4): the reading order panel changes a piece's kind (<see cref="AutoTag.WithKind"/>): a
/// paragraph the layout took for body text made a heading, a list made one paragraph, text that belongs to a chart made
/// part of its picture, and the kinds each piece can be made.
/// </summary>
public class AutoTagKindChangeTests
{
    private static TagPlan Plan(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return AutoTag.Plan(engine, pdf, null);
    }

    private static TagPlan WithAlt(TagPlan plan)
    {
        for (var i = 0; i < plan.Blocks.Count; i++)
            if (plan.Blocks[i].Kind == TagBlockKind.Figure) plan = AutoTag.With(plan, i, b => b with { Alt = "A colored gradient" });
        return plan;
    }

    /// <summary>The structure element types, depth-first, with how many content items (MCIDs) each holds directly.</summary>
    private static List<(string Type, int Mcids)> Tree(byte[] pdf)
    {
        using var doc = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Import);
        var list = new List<(string, int)>();
        void Visit(PdfItem? item)
        {
            switch (item is PdfReference r ? r.Value : item)
            {
                case PdfArray a:
                    foreach (var x in a.Elements) Visit(x);
                    break;
                case PdfDictionary d when d.Elements.GetName("/Type") == "/StructElem":
                    var k = d.Elements["/K"];
                    var kids = (k is PdfReference kr ? kr.Value : k) is PdfArray ka ? ka.Elements.ToList() : k is null ? [] : [k];
                    list.Add((d.Elements.GetName("/S").TrimStart('/'), kids.Count(x => x is PdfInteger)));
                    Visit(k);
                    break;
            }
        }
        var root = (PdfDictionary)((PdfReference)doc.Internals.Catalog.Elements["/StructTreeRoot"]!).Value;
        Visit(root.Elements["/K"]);
        return list;
    }

    private static int IndexOf(TagPlan plan, Func<TagBlock, bool> match) => plan.Blocks.Select((b, i) => (b, i)).First(x => match(x.b)).i;

    [Fact]
    public void A_paragraph_made_a_heading_is_written_as_one_at_its_level()
    {
        var pdf = ExportTestPdf.Make(logo: true);
        var plan = WithAlt(Plan(pdf));
        var i = IndexOf(plan, b => b.Kind == TagBlockKind.Paragraph && b.Text.StartsWith("A second paragraph", StringComparison.Ordinal));
        var before = Tree(AutoTag.Write(pdf, null, plan));
        var changed = AutoTag.WithKind(plan, i, TagBlockKind.Heading, level: 2);
        Assert.Equal(TagBlockKind.Heading, changed.Blocks[i].Kind);
        Assert.Equal(2, changed.Blocks[i].Level);
        Assert.Equal(plan.Blocks[i].Text, changed.Blocks[i].Text);
        Assert.Equal(plan.Blocks[i].Sources, changed.Blocks[i].Sources);
        var after = Tree(AutoTag.Write(pdf, null, changed));
        Assert.Equal(before.Count(t => t.Type == "P") - 1, after.Count(t => t.Type == "P"));
        Assert.Equal(before.Count(t => t.Type == "H2") + 1, after.Count(t => t.Type == "H2"));
        Assert.All(after.Where(t => t.Type == "H2"), t => Assert.True(t.Mcids > 0));
        Assert.True(AccessibilityCheck.Run(AutoTag.Write(pdf, null, changed), null).Passed);
        // Its level changes in place; the same kind and level again changes nothing.
        Assert.Equal(3, AutoTag.WithKind(changed, i, TagBlockKind.Heading, level: 3).Blocks[i].Level);
        Assert.Same(changed, AutoTag.WithKind(changed, i, TagBlockKind.Heading, level: 2));
    }

    [Fact]
    public void A_list_made_a_paragraph_holds_all_its_entries()
    {
        var pdf = ExportTestPdf.Make(logo: true);
        var plan = WithAlt(Plan(pdf));
        var i = IndexOf(plan, b => b.Kind == TagBlockKind.List);
        var list = plan.Blocks[i];
        Assert.Contains(TagBlockKind.Contents, AutoTag.KindsFor(list));
        var changed = AutoTag.WithKind(plan, i, TagBlockKind.Paragraph);
        var p = changed.Blocks[i];
        Assert.Empty(p.Items);
        Assert.Equal(string.Join("\n", list.Items.Select(x => x.Text)), p.Text);
        Assert.Equal(list.Items.Sum(x => x.Sources.Count) + list.Sources.Count, p.Sources.Count);
        var tagged = AutoTag.Write(pdf, null, changed);
        var tree = Tree(tagged);
        Assert.DoesNotContain(tree, t => t.Type is "L" or "LI" or "LBody");
        Assert.True(AccessibilityCheck.Run(tagged, null).Passed);
        // A paragraph can't be made a list or a table: their entries and cells aren't known.
        Assert.Same(changed, AutoTag.WithKind(changed, i, TagBlockKind.List));
        Assert.Same(changed, AutoTag.WithKind(changed, i, TagBlockKind.Table));
        Assert.DoesNotContain(TagBlockKind.List, AutoTag.KindsFor(p));
        Assert.DoesNotContain(TagBlockKind.Table, AutoTag.KindsFor(p));
    }

    [Fact]
    public void Text_made_a_picture_needs_alternate_text_and_is_tagged_as_one()
    {
        var pdf = ExportTestPdf.Make(logo: true);
        var plan = WithAlt(Plan(pdf));
        var i = IndexOf(plan, b => b.Kind == TagBlockKind.Paragraph && b.Text.StartsWith("A second paragraph", StringComparison.Ordinal));
        var changed = AutoTag.WithKind(plan, i, TagBlockKind.Figure);
        var f = changed.Blocks[i];
        Assert.Equal(TagBlockKind.Figure, f.Kind);
        Assert.Equal([f.Box], f.Sources);
        Assert.Equal(plan.FiguresWithoutAlt + 1, changed.FiguresWithoutAlt);
        var unnamed = AutoTag.Write(pdf, null, changed);
        Assert.Contains("13-004", AccessibilityCheck.Run(unnamed, null).FailedConditions);
        var named = AutoTag.With(changed, i, b => b with { Alt = "A note about the page" });
        var tagged = AutoTag.Write(pdf, null, named);
        var tree = Tree(tagged);
        Assert.Equal(Tree(AutoTag.Write(pdf, null, plan)).Count(t => t.Type == "Figure") + 1, tree.Count(t => t.Type == "Figure"));
        Assert.All(tree.Where(t => t.Type == "Figure"), t => Assert.True(t.Mcids > 0));
        Assert.True(AccessibilityCheck.Run(tagged, null).Passed);

        // And back: a paragraph again, its area its source, its text what the panel had.
        var back = AutoTag.WithKind(named, i, TagBlockKind.Paragraph);
        Assert.Equal(TagBlockKind.Paragraph, back.Blocks[i].Kind);
        Assert.Null(back.Blocks[i].Alt);
        Assert.True(AccessibilityCheck.Run(AutoTag.Write(pdf, null, back), null).Passed);
    }

    [Fact]
    public void A_picture_made_text_takes_the_text_drawn_in_it()
    {
        // The orchard's picture holds its labels ("North orchard" on it, "Hill" beside it): made a paragraph, they are its text.
        var pdf = AutoTagKindsTests.Make();
        var plan = Plan(pdf);
        var i = IndexOf(plan, b => b.Kind == TagBlockKind.Figure);
        var p = AutoTag.WithKind(plan, i, TagBlockKind.Paragraph).Blocks[i];
        Assert.Equal("North orchard\nHill", p.Text);
        Assert.Equal([plan.Blocks[i].Box], p.Sources);
    }

    [Fact]
    public void A_table_made_a_paragraph_reads_its_rows_in_order()
    {
        var pdf = ExportTestPdf.Make(logo: true);
        var plan = WithAlt(Plan(pdf));
        var i = IndexOf(plan, b => b.Kind == TagBlockKind.Table);
        var table = plan.Blocks[i];
        var changed = AutoTag.WithKind(plan, i, TagBlockKind.Paragraph);
        var p = changed.Blocks[i];
        Assert.Empty(p.Rows);
        Assert.Equal(0, p.HeaderRows);
        Assert.StartsWith(string.Join(" ", table.Rows[0].Select(c => c.Text).Where(t => t.Length > 0)), p.Text);
        var tagged = AutoTag.Write(pdf, null, changed);
        Assert.DoesNotContain(Tree(tagged), t => t.Type is "Table" or "TR" or "TH" or "TD");
        Assert.True(AccessibilityCheck.Run(tagged, null).Passed);
    }
}
