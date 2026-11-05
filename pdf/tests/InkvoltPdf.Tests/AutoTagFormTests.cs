using System.Text;
using InkvoltPdf.Core;
using MuPDFCore;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// Make Accessible (roadmap 2.4): content a page draws through a form XObject (a whole page placed as one drawing, a
/// letterhead with its text) is tagged piece by piece inside the form, each piece in its own element.
/// </summary>
public class AutoTagFormTests
{
    private const string Heading = "Annual Summary";
    private const string First = "The first paragraph tells the reader what happened over the year and why it matters.";
    private const string Second = "The second paragraph says what comes next and who to ask about it.";

    /// <summary>
    /// The heading and two paragraphs inside /Fm1 (object 5; its content <paramref name="form"/> instead); each page draws
    /// it <paramref name="draws"/> times (one page, or as many as <paramref name="pages"/>) after <paramref name="before"/>,
    /// its resources with <paramref name="resources"/> and its dictionary <paramref name="pageExtra"/>; objects
    /// <paramref name="more"/> after the pages.
    /// </summary>
    private static byte[] FormPage(int pages = 1, int draws = 1, string? form = null, string before = "", string resources = "", string pageExtra = "",
                                   IReadOnlyList<string>? more = null)
    {
        form ??= $"BT /F2 18 Tf 72 700 Td ({Heading}) Tj ET\n" +
                 $"BT /F1 11 Tf 72 660 Td ({First}) Tj ET\n" +
                 $"BT /F1 11 Tf 72 620 Td ({Second}) Tj ET";
        var page = before + string.Concat(Enumerable.Repeat("q /Fm1 Do Q\n", draws));
        var kids = string.Join(' ', Enumerable.Range(0, pages).Select(i => $"{7 + i} 0 R"));
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            $"<< /Type /Pages /Kids [{kids}] /Count {pages} >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>",
            Core2Pdf.Stream(form, "/Type /XObject /Subtype /Form /BBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >>"),
            Core2Pdf.Stream(page),
        };
        for (var i = 0; i < pages; i++)
            objects.Add($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 6 0 R /Resources << /XObject << /Fm1 5 0 R >> {resources} >> {pageExtra} >>");
        objects.AddRange(more ?? []);
        return Core2Pdf.Build(objects);
    }

    private static TagPlan Plan(byte[] pdf)
    {
        using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, null);
        return AutoTag.Plan(engine, pdf, null);
    }

    private static PdfDictionary D(PdfItem? item) => (PdfDictionary)(item is PdfReference r ? r.Value : item)!;

    /// <summary>Every structure element with its type, depth-first.</summary>
    private static List<(string Type, PdfDictionary Elem)> Elements(PdfDocument doc)
    {
        var list = new List<(string, PdfDictionary)>();
        void Visit(PdfItem? item)
        {
            switch (item is PdfReference r ? r.Value : item)
            {
                case PdfArray a:
                    foreach (var x in a.Elements) Visit(x);
                    break;
                case PdfDictionary d when d.Elements.GetName("/Type") == "/StructElem":
                    list.Add((d.Elements.GetName("/S").TrimStart('/'), d));
                    Visit(d.Elements["/K"]);
                    break;
            }
        }
        Visit(D(doc.Internals.Catalog.Elements["/StructTreeRoot"]).Elements["/K"]);
        return list;
    }

    /// <summary>An element's marked-content references to a form's stream (MCR with /Stm), as (MCID, form).</summary>
    private static List<(int Mcid, PdfDictionary Form)> FormRefs(PdfDictionary elem)
    {
        var k = elem.Elements["/K"];
        var items = (k is PdfReference r ? r.Value : k) is PdfArray a ? a.Elements.ToList() : k is null ? [] : [k];
        return [.. items.Select(i => i is PdfReference rr ? rr.Value : i).OfType<PdfDictionary>()
            .Where(d => d.Elements.GetName("/Type") == "/MCR" && d.Elements.ContainsKey("/Stm"))
            .Select(d => (d.Elements.GetInteger("/MCID"), D(d.Elements["/Stm"])))];
    }

    private static string StreamText(PdfDictionary d) => Encoding.Latin1.GetString(d.Stream.UnfilteredValue);

    [Fact]
    public void Content_inside_a_form_xobject_is_tagged_piece_by_piece()
    {
        var pdf = FormPage();
        var plan = Plan(pdf);
        Assert.Contains(plan.Blocks, b => b.Text == First);
        Assert.Contains(plan.Blocks, b => b.Text == Second);
        var tagged = AutoTag.Write(pdf, null, plan);
        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        var elements = Elements(doc);
        var h1 = Assert.Single(elements, e => e.Type == "H1").Elem;
        var ps = elements.Where(e => e.Type == "P").Select(e => e.Elem).ToList();
        Assert.Equal(2, ps.Count);

        // Each holds its own piece of the form, by MCID in the form's stream.
        var refs = new[] { h1, ps[0], ps[1] }.Select(FormRefs).ToList();
        Assert.All(refs, r => Assert.Single(r));
        var form = refs[0][0].Form;
        Assert.All(refs, r => Assert.Same(form, r[0].Form));
        Assert.Equal(3, refs.Select(r => r[0].Mcid).Distinct().Count());
        var key = form.Elements.GetInteger("/StructParents");
        Assert.True(form.Elements.ContainsKey("/StructParents"));
        var content = StreamText(form);
        foreach (var (type, r) in new[] { ("H1", refs[0]), ("P", refs[1]), ("P", refs[2]) })
            Assert.Contains($"/{type} <</MCID {r[0].Mcid}>> BDC", content);
        Assert.True(content.IndexOf(Heading, StringComparison.Ordinal) > content.IndexOf($"/H1 <</MCID {refs[0][0].Mcid}>> BDC", StringComparison.Ordinal));

        // The parent tree leads from the form's MCIDs back to the elements.
        var tree = D(D(doc.Internals.Catalog.Elements["/StructTreeRoot"]).Elements["/ParentTree"]);
        var nums = (PdfArray)D(tree).Elements["/Nums"]!;
        PdfArray? parents = null;
        for (var i = 0; i + 1 < nums.Elements.Count; i += 2)
            if (nums.Elements.GetInteger(i) == key) parents = (PdfArray)(nums.Elements[i + 1] is PdfReference pr ? pr.Value : nums.Elements[i + 1]);
        Assert.NotNull(parents);
        Assert.Same(h1, D(parents!.Elements[refs[0][0].Mcid]));
        Assert.Same(ps[1], D(parents.Elements[refs[2][0].Mcid]));

        // The page itself draws the form outside any marked content.
        var page = StreamText(D(doc.Pages[0].Elements["/Contents"]));
        Assert.DoesNotContain("BDC", page);
        var report = AccessibilityCheck.Run(tagged, null);
        Assert.True(report.Passed, string.Join("\n", report.Failures.Select(f => $"{f.Condition} p{f.Page}: {f.Problem}")));
    }

    [Fact]
    public void A_form_drawn_more_than_once_is_tagged_as_a_whole()
    {
        // Two pages drawing the same form: its stream can't hold one page's MCIDs, so each Do is tagged as before.
        var pdf = FormPage(pages: 2);
        var tagged = AutoTag.Write(pdf, null, Plan(pdf));
        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        Assert.All(Elements(doc), e => Assert.Empty(FormRefs(e.Elem)));
        var form = D(D(D(doc.Pages[0].Elements["/Resources"]).Elements["/XObject"]).Elements["/Fm1"]);
        Assert.DoesNotContain("MCID", StreamText(form));
        Assert.Contains("MCID", StreamText(D(doc.Pages[0].Elements["/Contents"])));
    }

    [Theory]
    [InlineData("annotation")] // a stamp whose appearance is the form
    [InlineData("pattern")]    // a tiling pattern that draws it
    [InlineData("type3")]      // a Type 3 glyph that draws it
    public void A_form_also_drawn_outside_the_page_content_is_tagged_as_a_whole(string where)
    {
        // Drawn once by the page and again where tags can't reach: its stream can't hold the page's MCIDs.
        var pdf = where switch
        {
            "annotation" => FormPage(pageExtra: "/Annots [8 0 R]", more: ["<< /Type /Annot /Subtype /Stamp /Rect [400 50 500 100] /Contents (Approved) /AP << /N 5 0 R >> >>"]),
            "pattern" => FormPage(resources: "/Pattern << /P1 8 0 R >>", more:
                [Core2Pdf.Stream("/Fm1 Do", "/Type /Pattern /PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 612 792] /XStep 612 /YStep 792 /Resources << /XObject << /Fm1 5 0 R >> >>")]),
            _ => FormPage(resources: "/Font << /T3 8 0 R >>", more:
                [
                    "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 612 792] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /a 9 0 R >> " +
                    "/Encoding << /Type /Encoding /Differences [65 /a] >> /FirstChar 65 /LastChar 65 /Widths [600] /Resources << /XObject << /Fm1 5 0 R >> >> >>",
                    Core2Pdf.Stream("600 0 d0 /Fm1 Do"),
                ]),
        };
        var tagged = AutoTag.Write(pdf, null, Plan(pdf));
        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        Assert.All(Elements(doc), e => Assert.Empty(FormRefs(e.Elem)));
        var form = D(D(D(doc.Pages[0].Elements["/Resources"]).Elements["/XObject"]).Elements["/Fm1"]);
        Assert.DoesNotContain("MCID", StreamText(form));
        Assert.Contains("MCID", StreamText(D(doc.Pages[0].Elements["/Contents"])));
    }

    [Fact]
    public void Text_inside_a_form_in_the_font_set_before_its_Do_is_read_in_that_font()
    {
        // The form shows its heading in the font the page set before drawing it (a form starts with the text state at its
        // Do): read in that font, the heading is the text of the link over it.
        var pdf = FormPage(
            form: $"BT 72 700 Td ({Heading}) Tj ET\nBT /F1 11 Tf 72 660 Td ({First}) Tj ET\nBT /F1 11 Tf 72 620 Td ({Second}) Tj ET",
            before: "BT /F2 18 Tf ET\n", resources: "/Font << /F2 4 0 R >>", pageExtra: "/Annots [8 0 R]",
            more: ["<< /Type /Annot /Subtype /Link /Rect [70 694 240 716] /Border [0 0 0] /A << /S /URI /URI (https://example.com/) >> >>"]);
        var tagged = AutoTag.Write(pdf, null, Plan(pdf));
        using var doc = PdfReader.Open(new MemoryStream(tagged), PdfDocumentOpenMode.Import);
        var annots = doc.Pages[0].Elements["/Annots"];
        var link = D(((PdfArray)(annots is PdfReference r ? r.Value : annots)!).Elements[0]);
        Assert.Equal(Heading, link.Elements.GetString("/Contents"));
        // The heading's link holds the heading's piece of the form.
        var h1 = Assert.Single(Elements(doc), e => e.Type == "H1").Elem;
        var inside = Assert.Single(Elements(doc), e => e.Type == "Link").Elem;
        Assert.Same(h1, D(inside.Elements["/P"]));
        Assert.Single(FormRefs(inside));
    }

    [Fact]
    public void Re_tagging_a_form_tagged_piece_by_piece_replaces_its_tags()
    {
        var pdf = FormPage();
        var once = AutoTag.Write(pdf, null, Plan(pdf));
        var twice = AutoTag.Write(once, null, Plan(once));
        using var doc = PdfReader.Open(new MemoryStream(twice), PdfDocumentOpenMode.Import);
        var elements = Elements(doc);
        Assert.Equal(2, elements.Count(e => e.Type == "P"));
        var form = D(D(D(doc.Pages[0].Elements["/Resources"]).Elements["/XObject"]).Elements["/Fm1"]);
        var content = StreamText(form);
        Assert.Equal(3, content.Split("MCID").Length - 1);
        var report = AccessibilityCheck.Run(twice, null);
        Assert.True(report.Passed, string.Join("\n", report.Failures.Select(f => $"{f.Condition} p{f.Page}: {f.Problem}")));
    }
}
