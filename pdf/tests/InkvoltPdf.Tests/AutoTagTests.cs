using System.Text;
using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// Make Accessible (<see cref="AutoTag"/>): an untagged PDF tagged from its layout, each tag kind, the marked content in
/// the page streams, title, language and tab order, reading-order edits, alternate text, and PDF/A-2a.
/// </summary>
public class AutoTagTests
{
    private static TagPlan Plan(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return AutoTag.Plan(engine, pdf, null);
    }

    private static TagPlan WithAlt(TagPlan plan, string alt = "A colored gradient")
    {
        for (var i = 0; i < plan.Blocks.Count; i++)
            if (plan.Blocks[i].Kind == TagBlockKind.Figure) plan = AutoTag.With(plan, i, b => b with { Alt = alt });
        return plan;
    }

    /// <summary>The structure tree as "Type" lines, depth-first, each indented by its depth; MCIDs as numbers.</summary>
    private static List<(string Type, int Depth, PdfDictionary Elem)> Tree(PdfDocument doc)
    {
        var list = new List<(string, int, PdfDictionary)>();
        void Visit(PdfItem? item, int depth)
        {
            switch (item is PdfReference r ? r.Value : item)
            {
                case PdfArray a:
                    foreach (var x in a.Elements) Visit(x, depth);
                    break;
                case PdfDictionary d when d.Elements.GetName("/Type") == "/StructElem":
                    list.Add((d.Elements.GetName("/S").TrimStart('/'), depth, d));
                    Visit(d.Elements["/K"], depth + 1);
                    break;
            }
        }
        var root = (PdfDictionary)((PdfReference)doc.Internals.Catalog.Elements["/StructTreeRoot"]!).Value;
        Visit(root.Elements["/K"], 0);
        return list;
    }

    private static string Content(PdfPage page)
    {
        var c = page.Elements["/Contents"];
        var d = (PdfDictionary)(c is PdfReference r ? r.Value : c)!;
        return Encoding.Latin1.GetString(d.Stream.UnfilteredValue);
    }

    [Fact]
    public void Plan_finds_headings_paragraphs_list_table_figure_and_running_header()
    {
        var plan = Plan(ExportTestPdf.Make(logo: true));
        var page1 = plan.Blocks.Where(b => b.Page == 0).ToList();
        Assert.Equal(TagBlockKind.Heading, page1[0].Kind);
        Assert.Equal("Quarterly Report", page1[0].Text);
        Assert.Contains(page1, b => b.Kind == TagBlockKind.Heading && b.Text == "Summary");
        Assert.Contains(page1, b => b.Kind == TagBlockKind.Paragraph && b.Text.StartsWith("Inkvolt keeps every page", StringComparison.Ordinal));
        var list = Assert.Single(page1, b => b.Kind == TagBlockKind.List);
        Assert.Equal(3, list.Items.Count);
        var table = Assert.Single(page1, b => b.Kind == TagBlockKind.Table);
        Assert.Equal(4, table.Rows.Count);
        Assert.True(table.HeaderRow);
        Assert.Single(page1, b => b.Kind == TagBlockKind.Figure);
        // The logo at the top of both pages is a running header: an artifact on each page.
        Assert.All(plan.Running, r => Assert.NotEmpty(r));
        Assert.Equal("Quarterly Report", plan.Title);
        Assert.Equal(TitleSource.Heading, plan.TitleFrom);
        Assert.Equal("en", plan.Language);
        Assert.True(plan.LanguageGuessed);
        Assert.False(plan.WasTagged);
        Assert.Equal(1, plan.FiguresWithoutAlt);
    }

    [Fact]
    public void Tags_each_kind_with_its_structure()
    {
        var pdf = ExportTestPdf.Make(logo: true);
        var tagged = AutoTag.Write(pdf, null, WithAlt(Plan(pdf)));
        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        var tree = Tree(doc);
        Assert.Equal("Document", tree[0].Type);
        Assert.Equal("H1", tree[1].Type);
        Assert.Contains(tree, t => t.Type == "H2");
        Assert.Contains(tree, t => t.Type == "P");
        Assert.Equal(1, tree.Count(t => t.Type == "L"));
        Assert.Equal(3, tree.Count(t => t.Type == "LI"));
        Assert.Equal(3, tree.Count(t => t.Type == "LBody"));
        Assert.Equal(1, tree.Count(t => t.Type == "Table"));
        Assert.Equal(4, tree.Count(t => t.Type == "TR"));
        var th = tree.Where(t => t.Type == "TH").ToList();
        Assert.Equal(3, th.Count);
        Assert.All(th, t => Assert.Equal("/Column", ((PdfDictionary)t.Elem.Elements["/A"]!).Elements.GetName("/Scope")));
        Assert.Equal(9, tree.Count(t => t.Type == "TD"));
        var figure = Assert.Single(tree, t => t.Type == "Figure").Elem;
        Assert.Equal("A colored gradient", figure.Elements.GetString("/Alt"));
        var bbox = (PdfArray)((PdfDictionary)figure.Elements["/A"]!).Elements["/BBox"]!;
        Assert.Equal(4, bbox.Elements.Count);
        // Page 1: x 72-232, 120 high (PDF space: y from the bottom).
        Assert.InRange(bbox.Elements.GetReal(0), 70, 74);
        Assert.InRange(bbox.Elements.GetReal(2), 230, 234);
        // Every element points at its parent.
        Assert.All(tree.Skip(1), t => Assert.True(t.Elem.Elements.ContainsKey("/P")));
    }

    [Fact]
    public void Untagged_file_passes_the_machine_checks_once_figures_have_alt_text()
    {
        var pdf = ExportTestPdf.Make(logo: true);
        Assert.False(AccessibilityCheck.Run(pdf, null).Passed);

        var plan = Plan(pdf);
        var withoutAlt = AccessibilityCheck.Run(AutoTag.Write(pdf, null, plan), null);
        Assert.Equal(["13-004"], withoutAlt.FailedConditions);

        var report = AccessibilityCheck.Run(AutoTag.Write(pdf, null, WithAlt(plan)), null);
        Assert.True(report.Passed, string.Join("\n", report.Failures.Select(f => $"{f.Condition} p{f.Page}: {f.Problem}")));
    }

    [Fact]
    public void Content_is_marked_with_mcids_the_parent_tree_resolves_and_running_content_is_an_artifact()
    {
        var pdf = ExportTestPdf.Make(logo: true);
        var tagged = AutoTag.Write(pdf, null, WithAlt(Plan(pdf)));
        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        var page = doc.Pages[0];
        var text = Content(page);
        var mcids = System.Text.RegularExpressions.Regex.Matches(text, @"/(\w+) <</MCID (\d+)>> BDC").Select(m => int.Parse(m.Groups[2].Value)).ToList();
        Assert.NotEmpty(mcids);
        Assert.Equal(Enumerable.Range(0, mcids.Count), mcids); // numbered in order, each once
        Assert.Contains("/Artifact <</Type /Pagination>> BDC", text); // the logo
        Assert.Contains("/Artifact BMC", text); // the table's rules
        Assert.Equal(System.Text.RegularExpressions.Regex.Matches(text, @"\bBDC\b|\bBMC\b").Count, System.Text.RegularExpressions.Regex.Matches(text, @"\bEMC\b").Count);

        var key = page.Elements.GetInteger("/StructParents");
        var root = (PdfDictionary)((PdfReference)doc.Internals.Catalog.Elements["/StructTreeRoot"]!).Value;
        var nums = ((PdfDictionary)((PdfReference)root.Elements["/ParentTree"]!).Value).Elements.GetArray("/Nums")!;
        PdfArray? entry = null;
        for (var i = 0; i < nums.Elements.Count; i += 2)
            if (((PdfInteger)nums.Elements[i]).Value == key) entry = (PdfArray)nums.Elements[i + 1];
        Assert.NotNull(entry);
        Assert.Equal(mcids.Count, entry.Elements.Count);
        // MCID 0 is the title, in the H1 element.
        var first = (PdfDictionary)((PdfReference)entry.Elements[0]).Value;
        Assert.Equal("/H1", first.Elements.GetName("/S"));
    }

    [Fact]
    public void Sets_title_language_tab_order_display_title_and_the_pdfua_identifier()
    {
        var pdf = ExportTestPdf.Make();
        var tagged = AutoTag.Write(pdf, null, Plan(pdf), new AccessibleOptions { Title = "Q3 report", Language = "en-US" });
        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        var catalog = doc.Internals.Catalog;
        Assert.Equal("Q3 report", doc.Info.Title);
        Assert.Equal("en-US", catalog.Elements.GetString("/Lang"));
        Assert.True(((PdfDictionary)catalog.Elements["/MarkInfo"]!).Elements.GetBoolean("/Marked"));
        Assert.True(((PdfDictionary)catalog.Elements["/ViewerPreferences"]!).Elements.GetBoolean("/DisplayDocTitle"));
        Assert.All(doc.Pages.Cast<PdfPage>(), p => Assert.Equal("/S", p.Elements.GetName("/Tabs")));
        var xmp = Encoding.UTF8.GetString(((PdfDictionary)((PdfReference)catalog.Elements["/Metadata"]!).Value).Stream.UnfilteredValue);
        Assert.Contains("<pdfuaid:part>1</pdfuaid:part>", xmp);
        Assert.Contains("Q3 report", xmp); // dc:title
    }

    [Fact]
    public void Headings_are_evened_out_first_is_h1_and_none_skipped()
    {
        TagBlock H(int level) => new(0, TagBlockKind.Heading, default) { Level = level };
        var even = AutoTag.EvenHeadings([H(2), H(4), new TagBlock(0, TagBlockKind.Paragraph, default), H(3), H(1), H(3)]);
        Assert.Equal([1, 2, 0, 3, 1, 2], even.Select(b => b.Level));
    }

    [Theory]
    [InlineData("3 Model Architecture", 1)]
    [InlineData("3.1 Encoder and Decoder Stacks", 2)]
    [InlineData("3.2.1. Scaled Dot-Product Attention", 3)]
    [InlineData("A.1 Proofs", 2)]
    [InlineData("2023 was a good year", null)]
    [InlineData("Introduction", null)]
    public void Section_numbers_give_heading_depth(string text, int? depth) => Assert.Equal(depth, AutoTag.SectionDepth(text));

    [Fact]
    public void Reading_order_edit_moves_a_block_within_its_page_and_the_tree_follows()
    {
        var pdf = ExportTestPdf.Make();
        var plan = Plan(pdf);
        var tableAt = plan.Blocks.ToList().FindIndex(b => b.Kind == TagBlockKind.Table);
        var moved = AutoTag.Move(plan, tableAt, -100); // to the top of page 1
        Assert.Equal(TagBlockKind.Table, moved.Blocks[0].Kind);
        Assert.Equal(plan.Blocks.Count, moved.Blocks.Count);
        // It never leaves its page.
        var lastOnPage1 = moved.Blocks.ToList().FindLastIndex(b => b.Page == 0);
        Assert.Equal(1, AutoTag.Move(moved, lastOnPage1 + 1, -1).Blocks[lastOnPage1 + 1].Page);

        var tagged = AutoTag.Write(pdf, null, WithAlt(moved));
        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        var tree = Tree(doc);
        Assert.Equal("Table", tree.First(t => t.Depth == 1).Type);
        Assert.True(AccessibilityCheck.Run(tagged, null).Passed);
    }

    [Fact]
    public void Decorative_figure_is_an_artifact_and_needs_no_alt_text()
    {
        var pdf = ExportTestPdf.Make();
        var plan = Plan(pdf);
        var fig = plan.Blocks.ToList().FindIndex(b => b.Kind == TagBlockKind.Figure);
        plan = AutoTag.With(plan, fig, b => b with { Decorative = true });
        Assert.Equal(0, plan.FiguresWithoutAlt);
        var tagged = AutoTag.Write(pdf, null, plan);
        using (var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import))
            Assert.DoesNotContain(Tree(doc), t => t.Type == "Figure");
        Assert.True(AccessibilityCheck.Run(tagged, null).Passed);
    }

    [Fact]
    public void Alt_text_round_trips_and_tagging_again_replaces_the_tags()
    {
        var pdf = ExportTestPdf.Make();
        var once = AutoTag.Write(pdf, null, WithAlt(Plan(pdf), "Chart of sales"));
        var again = Plan(once);
        Assert.True(again.WasTagged);
        Assert.Equal("Chart of sales", Assert.Single(again.Blocks, b => b.Kind == TagBlockKind.Figure).Alt);

        var twice = AutoTag.Write(once, null, again);
        using var doc = PdfReader.Open(new MemoryStream(twice), PdfDocumentOpenMode.Import);
        var text = Content(doc.Pages[0]);
        var mcids = System.Text.RegularExpressions.Regex.Matches(text, @"MCID (\d+)").Select(m => m.Groups[1].Value).ToList();
        Assert.Equal(mcids.Distinct().Count(), mcids.Count); // the old ones are gone
        Assert.Single(Tree(doc), t => t.Type == "Document");
        Assert.True(AccessibilityCheck.Run(twice, null).Passed);
    }

    [Fact]
    public void Link_gets_a_link_tag_with_its_annotation_and_a_description()
    {
        var pdf = ExportTestPdf.Make();
        // A link over "Summary" (baseline 120, 16 pt) to a web address.
        using (var doc = PdfReader.Open(new MemoryStream(pdf), PdfDocumentOpenMode.Modify))
        {
            var page = doc.Pages[0];
            var link = new PdfDictionary(doc);
            link.Elements["/Type"] = new PdfName("/Annot");
            link.Elements["/Subtype"] = new PdfName("/Link");
            link.Elements["/Rect"] = new PdfArray(doc, new PdfReal(70), new PdfReal(792 - 124), new PdfReal(150), new PdfReal(792 - 104));
            var action = new PdfDictionary(doc);
            action.Elements["/S"] = new PdfName("/URI");
            action.Elements["/URI"] = new PdfString("https://example.com/");
            link.Elements["/A"] = action;
            doc.Internals.AddObject(link);
            page.Elements["/Annots"] = new PdfArray(doc, link.Reference!);
            using var ms = new MemoryStream();
            doc.Save(ms, false);
            pdf = ms.ToArray();
        }
        var tagged = AutoTag.Write(pdf, null, WithAlt(Plan(pdf)));
        using var read = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        var tree = Tree(read);
        var linkElem = Assert.Single(tree, t => t.Type == "Link");
        Assert.Equal("H2", tree.Last(t => tree.IndexOf(t) < tree.IndexOf(linkElem) && t.Depth == linkElem.Depth - 1).Type);
        var annot = (PdfDictionary)((PdfReference)((PdfArray)read.Pages[0].Elements["/Annots"]!).Elements[0]).Value;
        Assert.True(annot.Elements.ContainsKey("/StructParent"));
        Assert.Equal("Summary", annot.Elements.GetString("/Contents"));
        var report = AccessibilityCheck.Run(tagged, null);
        Assert.True(report.Passed, string.Join("\n", report.Failures.Select(f => $"{f.Condition}: {f.Problem}")));
    }

    [Fact]
    public void Save_as_pdfa_2a_keeps_the_tags_and_says_conformance_a_and_pdfua()
    {
        var pdf = ExportTestPdf.Make();
        Assert.Throws<PdfAException>(() => PdfA.Convert(pdf, null, conformance: PdfAConformance.A)); // not tagged
        var tagged = AutoTag.Write(pdf, null, WithAlt(Plan(pdf)), new AccessibleOptions { Title = "Report", Language = "en" });
        var result = PdfA.Convert(tagged, null, conformance: PdfAConformance.A);
        Assert.Empty(PdfA.Validate(result.Data, PdfAConformance.A));
        using var doc = PdfReader.Open(new MemoryStream(result.Data), PdfDocumentOpenMode.Import);
        var xmp = Encoding.UTF8.GetString(((PdfDictionary)((PdfReference)doc.Internals.Catalog.Elements["/Metadata"]!).Value).Stream.UnfilteredValue);
        Assert.Contains("<pdfaid:conformance>A</pdfaid:conformance>", xmp);
        Assert.Contains("<pdfuaid:part>1</pdfuaid:part>", xmp);
        Assert.Contains("pdfaSchema:prefix>pdfuaid<", xmp); // the extension schema PDF/A asks for
        Assert.True(doc.Internals.Catalog.Elements.ContainsKey("/StructTreeRoot"));
        Assert.True(AccessibilityCheck.Run(result.Data, null).Passed);
    }
}

/// <summary>Make Accessible in Batch and presets, and alternate text from the user's own vision model (the request).</summary>
public sealed class AutoTagBatchTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-autotag-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    [Fact]
    public async Task Batch_tags_each_file_saves_pdfa_2a_and_says_what_needs_alt_text()
    {
        var input = Path.Combine(_root, "report.pdf");
        File.WriteAllBytes(input, ExportTestPdf.Make());
        var outFolder = Path.Combine(_root, "out");
        var plan = new BatchPlan { Steps = [new MakeAccessibleStep(), new SaveAsPdfAStep { Conformance = PdfAConformance.A }], OutputFolder = outFolder };
        Assert.Null(plan.Validate(ocrAvailable: false));

        var summary = await BatchRunner.RunAsync([new BatchFile(input)], plan, new BatchHost(), null, CancellationToken.None);

        var item = Assert.Single(summary.Items);
        Assert.Equal(BatchItemState.Done, item.State);
        Assert.Contains(item.Notes, n => n.StartsWith("Tagged:", StringComparison.Ordinal) && n.Contains("title \"Quarterly Report\"") && n.Contains("language en"));
        Assert.Contains(item.Notes, n => n.StartsWith("1 picture needs alternate text", StringComparison.Ordinal));
        Assert.Contains(item.Notes, n => n.StartsWith("PDF/A-2a", StringComparison.Ordinal));
        var result = File.ReadAllBytes(Path.Combine(outFolder, "report.pdf"));
        Assert.Empty(PdfA.Validate(result, PdfAConformance.A));
        Assert.Equal(["13-004"], AccessibilityCheck.Run(result, null).FailedConditions); // only the alternate text is left
    }

    [Fact]
    public void Presets_keep_make_accessible_and_the_pdfa_level()
    {
        var json = BatchPresets.Write(new BatchPreset
        {
            Name = "Accessible archive",
            Steps = [new MakeAccessibleStep { Language = "es-PR" }, new SaveAsPdfAStep { Conformance = PdfAConformance.A }],
        });
        Assert.Contains("\"makeAccessible\"", json);
        var steps = BatchPresets.Read(json).Steps;
        Assert.Equal("es-PR", Assert.IsType<MakeAccessibleStep>(steps[0]).Language);
        Assert.Equal(PdfAConformance.A, Assert.IsType<SaveAsPdfAStep>(steps[1]).Conformance);
        Assert.Equal(PdfAConformance.B, Assert.IsType<SaveAsPdfAStep>(BatchPresets.Read(BatchPresets.Write(new BatchPreset { Name = "B", Steps = [new SaveAsPdfAStep()] })).Steps[0]).Conformance);
    }

    [Fact]
    public void Alt_text_request_carries_the_picture_and_the_answer_is_cleaned()
    {
        var pdf = ExportTestPdf.Make();
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        var plan = AutoTag.Plan(engine, pdf, null);
        var fig = plan.Blocks.ToList().FindIndex(b => b.Kind == TagBlockKind.Figure);
        var png = AutoTag.FigurePng(engine, 0, plan.Blocks[fig].Box);
        Assert.Equal(0x89, png[0]); // a PNG
        Assert.Contains("Figure 1. A picture.", AutoTag.NearbyText(plan, fig));

        var messages = AiPrompts.AltText(png, AutoTag.NearbyText(plan, fig), "en", 0);
        var json = AiProtocol.ChatRequestJson("llava", messages);
        Assert.Contains("\"type\":\"image_url\"", json);
        Assert.Contains("data:image/png;base64,", json);
        Assert.Contains("Figure 1. A picture.", json);
        Assert.Contains("[a picture: PNG,", AiPrompts.Preview([messages]));
        // A request without pictures is written as before.
        Assert.Contains("\"content\":\"hi\"", AiProtocol.ChatRequestJson("m", [AiMessage.User("hi")]));

        Assert.Equal("A bar chart of sales by quarter", AiPrompts.CleanAltText("Alt text: \"A bar chart of sales by quarter\"\n"));
        var longer = AiPrompts.CleanAltText(string.Join(' ', Enumerable.Repeat("word", 100)));
        Assert.True(longer.Length <= 251 && longer.EndsWith('…'));
    }
}
