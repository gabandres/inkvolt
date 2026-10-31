using System.Text;
using InkvoltPdf.Core;
using PdfSharp.Drawing;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Tests;

/// <summary>
/// A tagged PDF built by hand for the accessibility check: one page, a Document tag holding the <see cref="Elems"/>, a
/// Type 3 font (no font program to embed), XMP with a title and the PDF/UA identifier. As it is, it passes every machine
/// check; each test changes one thing. Objects: 1 catalog, 2 pages, 3 page, 4 content, 5 structure tree root, 6 Document
/// tag, 7 XMP, 8 font F1, 9 its glyph, 10… the elements, then <see cref="More"/>.
/// </summary>
internal sealed record A11yDoc
{
    public const string GoodXmp =
        "<?xpacket begin=\"\" id=\"W5M0MpCehiHzreSzNTczkc9d\"?><x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">" +
        "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\" xmlns:pdfuaid=\"http://www.aiim.org/pdfua/ns/id/\">" +
        "<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">A test</rdf:li></rdf:Alt></dc:title><pdfuaid:part>1</pdfuaid:part></rdf:Description></rdf:RDF></x:xmpmeta><?xpacket end=\"w\"?>";

    public const string Type3Font =
        "<< /Type /Font /Subtype /Type3 /FontBBox [0 0 600 700] /FontMatrix [0.001 0 0 0.001 0 0] /CharProcs << /A 9 0 R /B 9 0 R >> " +
        "/Encoding << /Type /Encoding /Differences [65 /A /B] >> /FirstChar 65 /LastChar 66 /Widths [600 600] /Resources << >> >>";

    public string Header { get; init; } = "%PDF-1.7";
    public string Catalog { get; init; } = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R";
    public bool Tagged { get; init; } = true;
    public string RootExtra { get; init; } = "";
    public string Page { get; init; } = "/Tabs /S";
    public string Resources { get; init; } = "";
    /// <summary>More fonts in the page's /Font ("/F2 11 0 R").</summary>
    public string Fonts { get; init; } = "";
    public string Content { get; init; } = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC";
    public string[] Elems { get; init; } = ["<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 >>"];
    public string DocKids { get; init; } = "10 0 R";
    public string ParentTree { get; init; } = "0 [10 0 R]";
    public string? Xmp { get; init; } = GoodXmp;
    public string Annots { get; init; } = "";
    public string Font { get; init; } = Type3Font;
    public string[] More { get; init; } = [];

    /// <summary>The object number of <see cref="More"/>[<paramref name="i"/>].</summary>
    public int MoreAt(int i) => 10 + Elems.Length + i;

    public byte[] Build()
    {
        string[] objects =
        [
            $"<< /Type /Catalog /Pages 2 0 R {(Tagged ? "/StructTreeRoot 5 0 R" : "")} {Catalog} >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /StructParents 0 /Resources << /Font << /F1 8 0 R {Fonts} >> {Resources} >> " +
            $"{(Annots.Length > 0 ? $"/Annots [{Annots}]" : "")} {Page} >>",
            Core2Pdf.Stream(Content),
            $"<< /Type /StructTreeRoot /K 6 0 R /ParentTree << /Nums [{ParentTree}] >> {RootExtra} >>",
            $"<< /Type /StructElem /S /Document /P 5 0 R /K [{DocKids}] >>",
            Xmp is null ? "<< >>" : Core2Pdf.Stream(Xmp, "/Type /Metadata /Subtype /XML"),
            Font,
            Core2Pdf.Stream("600 0 d0 0 0 600 700 re f"),
            .. Elems,
            .. More,
        ];
        // An Info dictionary with the same title: Inkvolt's saves keep XMP and Info in step.
        var data = Core2Pdf.Build([.. objects, "<< /Title (A test) >>"], $"/Info {objects.Length + 1} 0 R");
        if (Header != "%PDF-1.7") Encoding.Latin1.GetBytes(Header).CopyTo(data, 0);
        return data;
    }

    public AccessibilityReport Check() => AccessibilityCheck.Run(Build(), null);

    /// <summary>A real TrueType program (Arial "AB", subset by PDFsharp) and the widths of A and B in it.</summary>
    public static (string Program, int Length) Arial()
    {
        TestPdf.UseFonts();
        byte[] seed;
        using (var doc = new PdfDocument())
        {
            var page = doc.AddPage();
            using (var gfx = XGraphics.FromPdfPage(page))
                gfx.DrawString("AB", new XFont("Arial", 12, XFontStyleEx.Regular, new XPdfFontOptions(PdfFontEncoding.WinAnsi)), XBrushes.Black, new XPoint(72, 72));
            using var ms = new MemoryStream();
            doc.Save(ms, false);
            seed = ms.ToArray();
        }
        using var d = PdfReader.Open(new MemoryStream(seed), PdfDocumentOpenMode.Import);
        var fonts = PdfObj.Dict(PdfObj.Dict(d.Pages[0].Elements["/Resources"])!.Elements["/Font"])!;
        var font = PdfObj.Dict(fonts.Elements.Values.First())!;
        var program = PdfObj.StreamBytes(PdfObj.Dict(PdfObj.Dict(font.Elements["/FontDescriptor"])!.Elements["/FontFile2"])!);
        return (Encoding.Latin1.GetString(program), program.Length);
    }

    /// <summary>A simple TrueType font F2 (object <paramref name="at"/>, its descriptor and program after it) using the Arial program.</summary>
    public static string[] TrueType(int at, string fontExtra = "/Encoding /WinAnsiEncoding", string widths = "[667 667]", int flags = 32)
    {
        var (program, length) = Arial();
        return
        [
            $"<< /Type /Font /Subtype /TrueType /BaseFont /ABCDEF+Arial /FirstChar 65 /LastChar 66 /Widths {widths} {fontExtra} /FontDescriptor {at + 1} 0 R >>",
            $"<< /Type /FontDescriptor /FontName /ABCDEF+Arial /Flags {flags} /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 {at + 2} 0 R >>",
            Core2Pdf.Stream(program, $"/Length1 {length}"),
        ];
    }

    /// <summary>A composite (Type 0) font F2 at <paramref name="at"/>: the Arial program as a TrueType CID font, then its CID font,
    /// descriptor and program.</summary>
    public static string[] Composite(int at, string encoding = "/Identity-H", string cidExtra = "/CIDToGIDMap /Identity /W [36 [667 667]]", string descriptorExtra = "",
        string info = "<< /Registry (Adobe) /Ordering (Identity) /Supplement 0 >>")
    {
        var (program, length) = Arial();
        return
        [
            $"<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+Arial /Encoding {encoding} /DescendantFonts [{at + 1} 0 R] >>",
            $"<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+Arial /CIDSystemInfo {info} /FontDescriptor {at + 2} 0 R /DW 1000 {cidExtra} >>",
            $"<< /Type /FontDescriptor /FontName /ABCDEF+Arial /Flags 32 /FontBBox [-665 -325 2000 1006] /ItalicAngle 0 /Ascent 905 /Descent -212 /CapHeight 716 /StemV 80 /FontFile2 {at + 3} 0 R {descriptorExtra} >>",
            Core2Pdf.Stream(program, $"/Length1 {length}"),
        ];
    }
}

public class AccessibilityCheckTests
{
    private static void Fails(A11yDoc doc, string condition)
    {
        var report = doc.Check();
        Assert.False(report.Passed);
        Assert.Contains(condition, report.FailedConditions);
        foreach (var f in report.Failures.Where(f => f.Condition == condition))
        {
            Assert.False(string.IsNullOrWhiteSpace(f.Problem));
            Assert.False(string.IsNullOrWhiteSpace(f.Fix));
        }
    }

    private static void Passes(A11yDoc doc)
    {
        var report = doc.Check();
        Assert.True(report.Passed, string.Join("\n", report.Failures.Select(f => $"{f.Condition}: {f.Problem}")));
    }

    private static void DoesNotFail(A11yDoc doc, string condition) => Assert.DoesNotContain(condition, doc.Check().FailedConditions);

    private const string P = "<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 >>";

    // ───────────────────────────── the catalogue ─────────────────────────────

    [Fact]
    public void EveryMatterhornConditionIsListedAndEveryHumanOneIsInTheChecklist()
    {
        var matterhorn = AccessibilityCheck.Conditions.Where(c => !c.Id.StartsWith("UA", StringComparison.Ordinal)).ToList();
        Assert.Equal(137, matterhorn.Count);
        Assert.Equal(matterhorn.Count, matterhorn.Select(c => c.Id).Distinct().Count());
        Assert.All(AccessibilityCheck.Conditions, c => Assert.True(AccessibilityCheck.Checkpoints.ContainsKey(c.Checkpoint), c.Id));
        Assert.All(AccessibilityCheck.Conditions.Where(c => c.How == ConditionCheck.Machine), c => Assert.False(string.IsNullOrWhiteSpace(c.Fix), c.Id));
        Assert.All(AccessibilityCheck.Conditions.Where(c => c.How == ConditionCheck.NotChecked), c => Assert.False(string.IsNullOrWhiteSpace(c.Note), c.Id));
        var inChecklist = AccessibilityCheck.HumanChecks.SelectMany(h => h.Conditions).ToHashSet();
        Assert.All(AccessibilityCheck.Conditions.Where(c => c.How == ConditionCheck.Human), c => Assert.Contains(c.Id, inChecklist));
        Assert.Equal(AccessibilityCheck.HumanChecks.Count, AccessibilityCheck.HumanChecks.Select(h => h.Id).Distinct().Count());
    }

    [Fact]
    public void AGoodTaggedDocumentPassesEveryMachineCheck() => Passes(new A11yDoc());

    // ───────────────────────────── basics, metadata, dictionary ─────────────────────────────

    [Fact]
    public void AnUntaggedDocumentFails()
    {
        var report = new A11yDoc { Tagged = false, Content = "BT /F1 12 Tf 72 700 Td (AB) Tj ET 0 0 10 10 re f" }.Check();
        Assert.False(report.Tagged);
        Assert.Contains("UA 7.1", report.FailedConditions);
        var untagged = Assert.Single(report.Failures, f => f.Condition == "01-005");
        Assert.Equal(0, untagged.Page);
        Assert.Equal(2, untagged.Count);
        Assert.False(untagged.Box.IsEmpty);
    }

    [Fact]
    public void MarkInfoSuspectsHeaderAndParent()
    {
        Fails(new A11yDoc { Catalog = "/Lang (en-US) /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R" }, "UA 6.2");
        Fails(new A11yDoc { Catalog = "/Lang (en-US) /MarkInfo << /Marked true /Suspects true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R" }, "01-007");
        Fails(new A11yDoc { Header = "%PDF-2.0" }, "UA 6.1");
        Fails(new A11yDoc { Elems = ["<< /Type /StructElem /S /P /Pg 3 0 R /K 0 >>"] }, "UA 7.1-P");
    }

    [Fact]
    public void MetadataNeedsXmpThePdfUaIdentifierAndATitle()
    {
        Fails(new A11yDoc { Xmp = null, Catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >>" }, "06-001");
        Fails(new A11yDoc { Xmp = A11yDoc.GoodXmp.Replace("<pdfuaid:part>1</pdfuaid:part>", "") }, "06-002");
        Fails(new A11yDoc { Xmp = A11yDoc.GoodXmp.Replace("<pdfuaid:part>1</pdfuaid:part>", "<pdfuaid:part>2</pdfuaid:part>") }, "06-002");
        Fails(new A11yDoc { Xmp = A11yDoc.GoodXmp.Replace("<dc:title><rdf:Alt><rdf:li xml:lang=\"x-default\">A test</rdf:li></rdf:Alt></dc:title>", "") }, "06-003");
        // The identifier as an attribute of the description counts too.
        Passes(new A11yDoc { Xmp = A11yDoc.GoodXmp.Replace("<pdfuaid:part>1</pdfuaid:part>", "").Replace("rdf:about=\"\"", "rdf:about=\"\" pdfuaid:part=\"1\"") });
    }

    [Fact]
    public void TheTitleMustBeShown()
    {
        Fails(new A11yDoc { Catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /Metadata 7 0 R" }, "07-001");
        Fails(new A11yDoc { Catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle false >> /Metadata 7 0 R" }, "07-002");
    }

    // ───────────────────────────── content ─────────────────────────────

    [Fact]
    public void EveryContentItemIsTaggedOrAnArtifact()
    {
        Fails(new A11yDoc { Content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC 72 600 100 1 re f" }, "01-005");
        Passes(new A11yDoc { Content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC /Artifact BMC 72 600 100 1 re f EMC" });
        // Marked content whose id the parent tree doesn't name isn't tagged.
        Fails(new A11yDoc { ParentTree = "0 [null]" }, "01-005");
        // Clipping paths aren't content.
        Passes(new A11yDoc { Content = "0 0 612 792 re W n /P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC" });
    }

    [Fact]
    public void ArtifactsAndTaggedContentDontNest()
    {
        Fails(new A11yDoc { Content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET /Artifact BMC 0 0 5 5 re f EMC EMC" }, "01-003");
        Fails(new A11yDoc { Content = "/Artifact BMC /P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC EMC" }, "01-004");
    }

    [Fact]
    public void TaggedContentInAFormDrawnTwiceFails()
    {
        var doc = new A11yDoc
        {
            Resources = "/XObject << /Fm1 11 0 R >>",
            Content = "/Fm1 Do /Fm1 Do",
            More = [Core2Pdf.Stream("/P << /MCID 0 >> BDC BT /F1 12 Tf 10 10 Td (AB) Tj ET EMC", "/Type /XObject /Subtype /Form /BBox [0 0 100 100] /Resources << /Font << /F1 8 0 R >> >>")],
        };
        Fails(doc, "30-002");
        Passes(doc with { Content = "/Fm1 Do" });
    }

    [Fact]
    public void AReferenceXObjectFails() =>
        Fails(new A11yDoc
        {
            Resources = "/XObject << /Fm1 11 0 R >>",
            Content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET /Fm1 Do EMC",
            More = [Core2Pdf.Stream("", "/Type /XObject /Subtype /Form /BBox [0 0 1 1] /Ref << /F (other.pdf) /Page 0 >>")],
        }, "30-001");

    // ───────────────────────────── role map ─────────────────────────────

    [Fact]
    public void CustomTypesMustMapToStandardOnes()
    {
        var custom = new A11yDoc { Elems = ["<< /Type /StructElem /S /Para /P 6 0 R /Pg 3 0 R /K 0 >>"] };
        Fails(custom, "02-001");
        Passes(custom with { RootExtra = "/RoleMap << /Para /P >>" });
        Fails(custom with { RootExtra = "/RoleMap << /Para /Body /Body /Para >>" }, "02-003");
        Fails(new A11yDoc { RootExtra = "/RoleMap << /P /Span >>" }, "02-004");
        // A standard type mapped to itself is a circle, not a remapping.
        Fails(new A11yDoc { RootExtra = "/RoleMap << /P /P >>" }, "02-003");
    }

    // ───────────────────────────── language ─────────────────────────────

    private const string NoLang = "/MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R";

    [Fact]
    public void TextNeedsALanguage()
    {
        Fails(new A11yDoc { Catalog = NoLang }, "11-001");
        // ... from its tag, or from its marked content.
        DoesNotFail(new A11yDoc { Catalog = NoLang, Elems = ["<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 /Lang (de) >>"] }, "11-001");
        DoesNotFail(new A11yDoc { Catalog = NoLang, Content = "/P << /MCID 0 /Lang (fr) >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC" }, "11-001");
        Fails(new A11yDoc { Catalog = "/Lang (en_US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R" }, "UA 7.2-Lang");
    }

    [Fact]
    public void AlternateTextMetadataBookmarksCommentsAndFieldsNeedALanguage()
    {
        Fails(new A11yDoc { Catalog = NoLang, Elems = ["<< /Type /StructElem /S /Figure /P 6 0 R /Pg 3 0 R /K 0 /Alt (A cat) >>"] }, "11-002");
        Fails(new A11yDoc { Catalog = NoLang }, "11-006");
        DoesNotFail(new A11yDoc { Catalog = NoLang, Xmp = A11yDoc.GoodXmp.Replace("x-default", "en") }, "11-006");
        var outlines = new A11yDoc
        {
            Catalog = NoLang + " /Outlines 11 0 R",
            More = ["<< /Type /Outlines /First 12 0 R /Last 12 0 R /Count 1 >>", "<< /Title (One) /Parent 11 0 R /Dest [3 0 R /Fit] >>"],
        };
        Fails(outlines, "11-003");
        DoesNotFail(outlines with { Catalog = outlines.Catalog + " /Lang (en)" }, "11-003");
        var note = new A11yDoc
        {
            Catalog = NoLang,
            Annots = "12 0 R",
            Elems = [P, "<< /Type /StructElem /S /Annot /P 6 0 R /Pg 3 0 R /K << /Type /OBJR /Obj 12 0 R >> >>"],
            DocKids = "10 0 R 11 0 R",
            ParentTree = "0 [10 0 R] 1 11 0 R",
            More = ["<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /Contents (A note) /StructParent 1 >>"],
        };
        Fails(note, "11-004");
        DoesNotFail(note with { Catalog = NoLang + " /Lang (en)" }, "11-004");
        Fails(new A11yDoc
        {
            Catalog = NoLang + " /AcroForm << /Fields [12 0 R] >>",
            Annots = "12 0 R",
            Elems = [P, "<< /Type /StructElem /S /Form /P 6 0 R /Pg 3 0 R /K << /Type /OBJR /Obj 12 0 R >> >>"],
            DocKids = "10 0 R 11 0 R",
            ParentTree = "0 [10 0 R] 1 11 0 R",
            More = ["<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /TU (Your name) /Rect [100 100 200 120] /StructParent 1 >>"],
        }, "11-005");
    }

    // ───────────────────────────── tags ─────────────────────────────

    private static A11yDoc Tags(params string[] elems) => new()
    {
        Content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC",
        Elems = [P, .. elems],
        DocKids = string.Join(' ', Enumerable.Range(0, elems.Length + 1).Select(i => $"{10 + i} 0 R")),
    };

    [Fact]
    public void FiguresAndFormulasNeedAlternateText()
    {
        Fails(Tags("<< /Type /StructElem /S /Figure /P 6 0 R >>"), "13-004");
        Passes(Tags("<< /Type /StructElem /S /Figure /P 6 0 R /Alt (A cat on a mat) >>"));
        Passes(Tags("<< /Type /StructElem /S /Figure /P 6 0 R /ActualText (A) >>"));
        Fails(Tags("<< /Type /StructElem /S /Figure /P 6 0 R /Alt () >>"), "13-004");
        Fails(Tags("<< /Type /StructElem /S /Formula /P 6 0 R >>"), "17-002");
        // A custom type mapped to Figure is a figure.
        Fails(Tags("<< /Type /StructElem /S /Image /P 6 0 R >>") with { RootExtra = "/RoleMap << /Image /Figure >>" }, "13-004");
    }

    [Fact]
    public void HeadingsStartAtH1AndDontSkip()
    {
        Fails(Tags("<< /Type /StructElem /S /H2 /P 6 0 R >>"), "14-002");
        Fails(Tags("<< /Type /StructElem /S /H1 /P 6 0 R >>", "<< /Type /StructElem /S /H3 /P 6 0 R >>"), "14-003");
        Passes(Tags("<< /Type /StructElem /S /H1 /P 6 0 R >>", "<< /Type /StructElem /S /H2 /P 6 0 R >>", "<< /Type /StructElem /S /H1 /P 6 0 R >>"));
        Fails(Tags("<< /Type /StructElem /S /H /P 6 0 R >>", "<< /Type /StructElem /S /H /P 6 0 R >>"), "14-006");
        Fails(Tags("<< /Type /StructElem /S /H /P 6 0 R >>", "<< /Type /StructElem /S /H1 /P 6 0 R >>"), "14-007");
    }

    [Fact]
    public void TablesListsAndContentsFollowTheirStructure()
    {
        // 11 Table > 12 TR > 13 TH, 14 TH; 15 TR > 16 TD, 17 TD
        string[] table =
        [
            "<< /Type /StructElem /S /Table /P 6 0 R /K [12 0 R 15 0 R] >>",
            "<< /Type /StructElem /S /TR /P 11 0 R /K [13 0 R 14 0 R] >>",
            "<< /Type /StructElem /S /TH /P 12 0 R /A << /O /Table /Scope /Column >> >>",
            "<< /Type /StructElem /S /TH /P 12 0 R /A << /O /Table /Scope /Column >> >>",
            "<< /Type /StructElem /S /TR /P 11 0 R /K [16 0 R 17 0 R] >>",
            "<< /Type /StructElem /S /TD /P 15 0 R >>",
            "<< /Type /StructElem /S /TD /P 15 0 R >>",
        ];
        var good = Tags(table) with { DocKids = "10 0 R 11 0 R" };
        Passes(good);
        // A cell directly in the table, not in a row.
        Fails(good with { Elems = [P, "<< /Type /StructElem /S /Table /P 6 0 R /K [12 0 R 15 0 R 17 0 R] >>", .. table[1..4],
            "<< /Type /StructElem /S /TR /P 11 0 R /K [16 0 R] >>", table[5], "<< /Type /StructElem /S /TD /P 11 0 R >>"] },
            "09-004");
        // Rows of different widths.
        Fails(good with { Elems = [P, table[0], table[1], table[2], table[3], "<< /Type /StructElem /S /TR /P 11 0 R /K [16 0 R] >>", table[5], "<< /Type /StructElem /S /P /P 6 0 R >>"] }, "09-004");
        // Header cells without scope, data cells without Headers.
        Fails(good with { Elems = [P, table[0], table[1], "<< /Type /StructElem /S /TH /P 12 0 R >>", table[3], table[4], table[5], table[6]] }, "15-003");
        // ... unless the data cells name their headers.
        Passes(good with
        {
            Elems =
            [
                P, table[0], table[1], "<< /Type /StructElem /S /TH /P 12 0 R /ID (h1) >>", "<< /Type /StructElem /S /TH /P 12 0 R /ID (h2) >>", table[4],
                "<< /Type /StructElem /S /TD /P 15 0 R /A << /O /Table /Headers [(h1)] >> >>", "<< /Type /StructElem /S /TD /P 15 0 R /A << /O /Table /Headers [(h2)] >> >>",
            ],
        });

        Fails(Tags("<< /Type /StructElem /S /LI /P 6 0 R >>"), "09-005");
        Passes(Tags("<< /Type /StructElem /S /L /P 6 0 R /K 12 0 R >>", "<< /Type /StructElem /S /LI /P 11 0 R /K [13 0 R 14 0 R] >>",
            "<< /Type /StructElem /S /Lbl /P 12 0 R >>", "<< /Type /StructElem /S /LBody /P 12 0 R >>") with { DocKids = "10 0 R 11 0 R" });
        Fails(Tags("<< /Type /StructElem /S /L /P 6 0 R /K 12 0 R >>", "<< /Type /StructElem /S /P /P 11 0 R >>") with { DocKids = "10 0 R 11 0 R" }, "09-005");
        Fails(Tags("<< /Type /StructElem /S /TOCI /P 6 0 R >>"), "09-006");
    }

    [Fact]
    public void NotesNeedUniqueIds()
    {
        Fails(Tags("<< /Type /StructElem /S /Note /P 6 0 R >>"), "19-003");
        Fails(Tags("<< /Type /StructElem /S /Note /P 6 0 R /ID (n1) >>", "<< /Type /StructElem /S /Note /P 6 0 R /ID (n1) >>"), "19-004");
        Passes(Tags("<< /Type /StructElem /S /Note /P 6 0 R /ID (n1) >>", "<< /Type /StructElem /S /Note /P 6 0 R /ID (n2) >>"));
    }

    // ───────────────────────────── annotations ─────────────────────────────

    /// <summary>The page with one annotation (object 12), tagged in an element of type <paramref name="tag"/> (null: untagged).</summary>
    private static A11yDoc Annotated(string annot, string? tag, string page = "/Tabs /S", string catalog = "") => new()
    {
        Catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R " + catalog,
        Page = page,
        Annots = "12 0 R",
        Elems = [P, tag is null ? "<< /Type /StructElem /S /Span /P 6 0 R >>" : $"<< /Type /StructElem /S /{tag} /P 6 0 R /Pg 3 0 R /K << /Type /OBJR /Obj 12 0 R >> >>"],
        DocKids = "10 0 R 11 0 R",
        ParentTree = tag is null ? "0 [10 0 R]" : "0 [10 0 R] 1 11 0 R",
        More = [annot.Replace("/Rect", tag is null ? "/Rect" : "/StructParent 1 /Rect")],
    };

    [Fact]
    public void CommentsAreTaggedAndDescribed()
    {
        Passes(Annotated("<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /Contents (A note) >>", "Annot"));
        Fails(Annotated("<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /Contents (A note) >>", null), "28-002");
        Fails(Annotated("<< /Type /Annot /Subtype /Square /Rect [100 100 120 120] >>", "Annot"), "28-004");
        // Hidden comments, and ones outside the page, aren't read.
        Passes(Annotated("<< /Type /Annot /Subtype /Square /F 2 /Rect [100 100 120 120] >>", "Annot"));
        Passes(Annotated("<< /Type /Annot /Subtype /Square /Rect [900 900 920 920] >>", "Annot"));
        Fails(Annotated("<< /Type /Annot /Subtype /TrapNet /Rect [100 100 120 120] /Contents (x) >>", "Annot"), "28-007");
        Fails(Annotated("<< /Type /Annot /Subtype /PrinterMark /Rect [100 100 120 120] >>", "Annot"), "28-017");
    }

    [Fact]
    public void PagesWithAnnotationsFollowTheTagsTabOrder()
    {
        const string note = "<< /Type /Annot /Subtype /Text /Rect [100 100 120 120] /Contents (A note) >>";
        Fails(Annotated(note, "Annot", page: ""), "28-008");
        Fails(Annotated(note, "Annot", page: "/Tabs /R"), "28-009");
    }

    [Fact]
    public void LinksAreTaggedAndDescribed()
    {
        const string link = "<< /Type /Annot /Subtype /Link /Rect [100 100 200 120] /Contents (Our web site) /A << /S /URI /URI (https://example.org) >> >>";
        Passes(Annotated(link, "Link"));
        Fails(Annotated(link, null), "28-011");
        Fails(Annotated(link, "Annot"), "28-011");
        Fails(Annotated(link.Replace("/Contents (Our web site) ", ""), "Link"), "28-012");
    }

    [Fact]
    public void FormFieldsAreTaggedAndHaveTooltips()
    {
        const string field = "<< /Type /Annot /Subtype /Widget /FT /Tx /T (name) /TU (Your name) /Rect [100 100 200 120] >>";
        const string acro = "/AcroForm << /Fields [12 0 R] >>";
        Passes(Annotated(field, "Form", catalog: acro));
        Fails(Annotated(field, "P", catalog: acro), "28-010");
        Fails(Annotated(field.Replace("/TU (Your name) ", ""), "Form", catalog: acro), "28-005");
        // The tag's alternate text describes the field too.
        var withAlt = Annotated(field.Replace("/TU (Your name) ", ""), "Form", catalog: acro);
        Passes(withAlt with { Elems = [P, "<< /Type /StructElem /S /Form /P 6 0 R /Pg 3 0 R /Alt (Your name) /K << /Type /OBJR /Obj 12 0 R >> >>"] });
        // A Form tag holding more than its field needs a Role attribute.
        Fails(withAlt with { Elems = [P, "<< /Type /StructElem /S /Form /P 6 0 R /Pg 3 0 R /Alt (Your name) /K [0 << /Type /OBJR /Obj 12 0 R >>] >>"] }, "28-010");
    }

    [Fact]
    public void MediaClipsAndAttachedFilesAreDescribed()
    {
        const string clip = "<< /Type /Annot /Subtype /Screen /Rect [100 100 200 200] /Contents (A video) /A << /S /Rendition /R << /S /MR /C << /S /MCD /CT (video/mp4) /Alt [(en) (A video)] >> >> >> >>";
        Passes(Annotated(clip, "Annot"));
        Fails(Annotated(clip.Replace("/CT (video/mp4) ", ""), "Annot"), "28-014");
        Fails(Annotated(clip.Replace("/Alt [(en) (A video)]", "/Alt [(en) ()]"), "Annot"), "28-015");
        Fails(Annotated("<< /Type /Annot /Subtype /FileAttachment /Rect [100 100 120 120] /Contents (A file) /FS << /Type /Filespec /F (a.txt) /EF << /F 13 0 R >> >> >>", "Annot")
            with { More = ["<< /Type /Annot /Subtype /FileAttachment /StructParent 1 /Rect [100 100 120 120] /Contents (A file) /FS << /Type /Filespec /F (a.txt) /EF << /F 13 0 R >> >> >>", Core2Pdf.Stream("hello")] }, "28-016");
        var embedded = new A11yDoc
        {
            Catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R /Names << /EmbeddedFiles << /Names [(a.txt) << /Type /Filespec /F (a.txt) /EF << /F 11 0 R >> >>] >> >>",
            More = [Core2Pdf.Stream("hello")],
        };
        Fails(embedded, "21-001");
        Passes(embedded with { Catalog = embedded.Catalog.Replace("/F (a.txt) /EF", "/F (a.txt) /UF (a.txt) /EF") });
    }

    // ───────────────────────────── optional content, XFA, security ─────────────────────────────

    [Fact]
    public void LayerConfigurationsAreNamedAndManual()
    {
        const string catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R ";
        Fails(new A11yDoc { Catalog = catalog + "/OCProperties << /OCGs [] /D << /Order [] >> >>" }, "20-002");
        Fails(new A11yDoc { Catalog = catalog + "/OCProperties << /OCGs [] /D << /Name (Default) >> /Configs [<< /Order [] >>] >>" }, "20-001");
        Fails(new A11yDoc { Catalog = catalog + "/OCProperties << /OCGs [] /D << /Name (Default) /AS [] >> >>" }, "20-003");
        Passes(new A11yDoc { Catalog = catalog + "/OCProperties << /OCGs [] /D << /Name (Default) >> >>" });
    }

    [Fact]
    public void DynamicXfaFails() =>
        Fails(new A11yDoc
        {
            Catalog = "/Lang (en-US) /MarkInfo << /Marked true >> /ViewerPreferences << /DisplayDocTitle true >> /Metadata 7 0 R /AcroForm << /Fields [] /XFA [(config) 11 0 R] >>",
            More = [Core2Pdf.Stream("<config><acrobat><acrobat7><dynamicRender\n>required</dynamicRender\n></acrobat7></acrobat></config>")],
        }, "25-001");

    [Fact]
    public void ProtectionMustLetScreenReadersRead()
    {
        // Inkvolt's own protection always lets screen readers copy text (P bit 10), even with copying off.
        var good = new A11yDoc().Build();
        var locked = PdfSecurity.Protect(good, null, null, "owner", new PdfPermissions(Copy: false));
        Assert.DoesNotContain("26-002", AccessibilityCheck.Run(locked, null).FailedConditions);
        // P without bit 10 (copying for accessibility), or no P at all. (PDFsharp refuses such files when it can tell, as
        // AES-256's Perms does, so the rule is checked on its own.)
        Assert.Equal("26-002", AccessibilityCheck.PermissionsCondition(-1028 & ~512));
        Assert.Equal("26-001", AccessibilityCheck.PermissionsCondition(null));
        Assert.Null(AccessibilityCheck.PermissionsCondition(-1028));
    }


    // ───────────────────────────── fonts ─────────────────────────────

    /// <summary>The good document with its text in font F2 (objects from 11 on).</summary>
    private static A11yDoc InFont(string[] font, string text = "(AB)") => new()
    {
        Content = $"/P << /MCID 0 >> BDC BT /F2 12 Tf 72 700 Td {text} Tj ET EMC",
        Fonts = "/F2 11 0 R",
        More = font,
    };

    [Fact]
    public void FontsMustBeEmbedded()
    {
        Fails(InFont(["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]), "31-009");
        Passes(InFont(A11yDoc.TrueType(11)));
        // Text that doesn't show (render mode 3, as under OCR) needs no embedded font.
        DoesNotFail(new A11yDoc
        {
            Content = "/P << /MCID 0 >> BDC BT 3 Tr /F2 12 Tf 72 700 Td (AB) Tj ET EMC",
            Fonts = "/F2 11 0 R",
            More = ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"],
        }, "31-009");
    }

    [Fact]
    public void CharactersMapToUnicode()
    {
        Fails(new A11yDoc { Font = A11yDoc.Type3Font.Replace("[65 /A /B]", "[65 /g123 /B]") }, "31-027");
        var withToUnicode = new A11yDoc
        {
            Font = A11yDoc.Type3Font.Replace("[65 /A /B]", "[65 /g123 /B]").Replace("/Resources << >>", "/Resources << >> /ToUnicode 11 0 R"),
            More = [Core2Pdf.Stream("1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <41> <0041> <42> <0042> endbfchar")],
        };
        Passes(withToUnicode);
        Fails(withToUnicode with { More = [Core2Pdf.Stream("1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <41> <0000> <42> <0042> endbfchar")] }, "31-028");
        Fails(withToUnicode with { More = [Core2Pdf.Stream("1 begincodespacerange <00> <FF> endcodespacerange 2 beginbfchar <41> <FEFF> <42> <0042> endbfchar")] }, "31-029");
        Fails(new A11yDoc { Font = A11yDoc.Type3Font.Replace("[65 /A /B]", "[65 /.notdef /B]").Replace("/A 9 0 R", "/.notdef 9 0 R") }, "31-030");
    }

    [Fact]
    public void TrueTypeWidthsAndEncodings()
    {
        Fails(InFont(A11yDoc.TrueType(11, widths: "[500 500]")), "31-016");
        Fails(InFont(A11yDoc.TrueType(11, fontExtra: "")), "31-019");
        Fails(InFont(A11yDoc.TrueType(11, fontExtra: "/Encoding << /Differences [65 /A] >>")), "31-020");
        Fails(InFont(A11yDoc.TrueType(11, fontExtra: "/Encoding /StandardEncoding")), "31-021");
        Fails(InFont(A11yDoc.TrueType(11, fontExtra: "/Encoding << /BaseEncoding /WinAnsiEncoding /Differences [66 /notaglyphname] >>")), "31-022");
        Fails(InFont(A11yDoc.TrueType(11, flags: 4)), "31-024");

    }

    [Fact]
    public void CompositeFontsAndCMaps()
    {
        Passes(InFont(A11yDoc.Composite(11), "<0024>").WithToUnicode());
        Fails(InFont(A11yDoc.Composite(11, cidExtra: ""), "<0024>").WithToUnicode(), "31-005");
        // Glyph 0 is .notdef; a glyph past the program's end isn't in it.
        Fails(InFont(A11yDoc.Composite(11), "<0000>").WithToUnicode(), "31-030");
        Fails(InFont(A11yDoc.Composite(11), "<FFF0>").WithToUnicode(), "31-011");
        Fails(InFont(A11yDoc.Composite(11, cidExtra: "/CIDToGIDMap /Other"), "<0024>").WithToUnicode(), "31-004");
        Fails(InFont(A11yDoc.Composite(11, encoding: "/Custom-H"), "<0024>").WithToUnicode(), "31-006");
        // A standard CMap of another collection than the font's.
        Fails(InFont(A11yDoc.Composite(11, encoding: "/UniJIS-UCS2-H"), "<0024>").WithToUnicode(), "31-002");
        // An embedded CMap: its writing mode, the CMaps it uses.
        var cmap = Core2Pdf.Stream("/CIDInit /ProcSet findresource begin 12 dict begin begincmap /CMapName /Mine def /WMode 1 def 1 begincodespacerange <0000> <FFFF> endcodespacerange endcmap end end",
            "/Type /CMap /CMapName /Mine /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /WMode 0");
        var font = A11yDoc.Composite(11, encoding: "15 0 R");
        Fails(InFont([.. font, cmap], "<0024>").WithToUnicode(), "31-007");
        var uses = Core2Pdf.Stream("/WMode 0 def", "/Type /CMap /CMapName /Mine /CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) /Supplement 0 >> /UseCMap /Custom-H");
        Fails(InFont([.. font, uses], "<0024>").WithToUnicode(), "31-008");
        // A subset's CIDSet must list the glyphs the program holds.
        Fails(InFont([.. A11yDoc.Composite(11, descriptorExtra: "/CIDSet 15 0 R"), Core2Pdf.Stream("\0")], "<0024>").WithToUnicode(), "31-014");
    }

    // ───────────────────────────── the report ─────────────────────────────

    [Fact]
    public void FindingsSayWhereAndWhatFixesThem()
    {
        var report = (Tags("<< /Type /StructElem /S /Figure /P 6 0 R /Pg 3 0 R /K 1 >>") with
        {
            Content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC /Figure << /MCID 1 >> BDC q 100 0 0 50 200 300 cm 0 0 1 1 re f Q EMC",
            ParentTree = "0 [10 0 R 11 0 R]",
        }).Check();
        var figure = Assert.Single(report.Failures);
        Assert.Equal("13-004", figure.Condition);
        Assert.Equal(0, figure.Page);
        Assert.Equal("Figure", figure.Element);
        // The box is the figure's drawing, in page space (top-left origin): x 200-300, y from 792-350 to 792-300.
        Assert.InRange(figure.Box.X, 199, 201);
        Assert.InRange(figure.Box.Y, 441, 443);
        Assert.InRange(figure.Box.Width, 99, 101);
        Assert.InRange(figure.Box.Height, 49, 51);
        Assert.Contains("alternate text", figure.Fix);
        Assert.Contains("Fails 1 condition (1 problem)", report.Summary);
    }

    [Fact]
    public void TheHtmlReportIsSelfContainedAndAccessible()
    {
        var report = Tags("<< /Type /StructElem /S /Figure /P 6 0 R >>").Check();
        var html = AccessibilityReportHtml.Write(report, "a <b> & c.pdf", new DateTime(2026, 10, 27, 9, 30, 0), new HashSet<string> { "title" });
        Assert.StartsWith("<!DOCTYPE html>", html);
        Assert.Contains("<html lang=\"en\">", html);
        Assert.Contains("<title>Accessibility report: a &lt;b&gt; &amp; c.pdf</title>", html);
        Assert.DoesNotContain("<script", html, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotContain("src=", html);
        Assert.DoesNotContain("href=\"http", html);
        Assert.Contains("<th scope=\"col\">", html);
        Assert.Contains("<th scope=\"row\">13-004</th>", html);
        Assert.Contains("Checkpoint 13: Graphics", html);
        Assert.Contains("(done)", html); // the ticked title check
        Assert.Contains("(not done yet)", html);
        Assert.Contains("1 of 15 done", html);
        Assert.Contains("prefers-color-scheme: dark", html);
        // Headings in order: one h1, then h2s, h3s only under h2s.
        var levels = System.Text.RegularExpressions.Regex.Matches(html, "<h([1-6])[ >]").Select(m => int.Parse(m.Groups[1].Value)).ToList();
        Assert.Equal(1, levels[0]);
        Assert.Single(levels, 1);
        Assert.All(levels.Zip(levels.Skip(1)), p => Assert.True(p.Second <= p.First + 1));
        // Every condition is in the table, with its result.
        Assert.All(AccessibilityCheck.Conditions, c => Assert.Contains($"<th scope=\"row\">{System.Net.WebUtility.HtmlEncode(c.Id)}</th>", html));
        Assert.Contains("Fails (1 problem)", html);
    }

    [Fact]
    public void ABrokenFileIsReportedNotThrownAtRandom()
    {
        Assert.Throws<InvalidOperationException>(() => AccessibilityCheck.Run(Encoding.ASCII.GetBytes("%PDF-1.7\nnot really a pdf"), null));
    }

    // ───────────────────────────── hybrid-reference files ─────────────────────────────

    [Fact]
    public void TagsKeptInAWordStyleHybridFileAreFound()
    {
        var data = HybridFile();
        // PDFsharp alone doesn't see the structure tree root (it is in an object stream only the /XRefStm lists).
        using (var plain = PdfReader.Open(new MemoryStream(data), PdfDocumentOpenMode.Import))
            Assert.Null(PdfObj.Dict(plain.Internals.Catalog.Elements["/StructTreeRoot"]));
        using (var fixedUp = PdfReader.Open(new MemoryStream(HybridXref.Normalize(data)), PdfDocumentOpenMode.Import))
            Assert.NotNull(PdfObj.Dict(fixedUp.Internals.Catalog.Elements["/StructTreeRoot"]));
        var report = AccessibilityCheck.Run(data, null);
        Assert.True(report.Tagged);
        Assert.DoesNotContain("01-005", report.FailedConditions);
        // A file that isn't hybrid comes back as it was.
        var plainFile = new A11yDoc().Build();
        Assert.Same(plainFile, HybridXref.Normalize(plainFile));
    }

    [Fact]
    public void AHybridFilesObjectRewrittenInALaterObjectStreamIsReadFromThere()
    {
        // As wcag-table-word.pdf: a later revision rewrites a tag in an object stream of its own (Scope added to Word's TH
        // tags), and the older object stream still holds the old one.
        using var doc = PdfReader.Open(new MemoryStream(HybridXref.Normalize(RevisedHybridFile())), PdfDocumentOpenMode.Import);
        var tag = doc.Internals.GetAllObjects().OfType<PdfDictionary>().Single(d => PdfObj.Name(d.Elements["/S"]) == "P");
        Assert.Equal("Newer", PdfObj.Text(tag.Elements["/Alt"]));
        Assert.NotNull(PdfObj.Dict(doc.Internals.Catalog.Elements["/StructTreeRoot"]));
    }

    /// <summary><see cref="HybridFile"/> with tag 7 in object stream 10, then a revision that rewrites it in object stream 12.</summary>
    private static byte[] RevisedHybridFile()
    {
        var first = Encoding.Latin1.GetString(HybridFile(tagInStream: true));
        var prev = first.LastIndexOf("xref\n0 12", StringComparison.Ordinal);
        var sb = new StringBuilder(first);
        int At() => Encoding.Latin1.GetByteCount(sb.ToString());
        const string header = "7 0 ";
        var at12 = At();
        sb.Append($"12 0 obj\n{Core2Pdf.Stream(header + "<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 /Alt (Newer) >>", $"/Type /ObjStm /N 1 /First {header.Length}")}\nendobj\n");
        var at13 = At();
        byte[] rows = [2, 0, 0, 0, 12, 0, 1, (byte)(at12 >> 24), (byte)(at12 >> 16), (byte)(at12 >> 8), (byte)at12, 0];
        sb.Append($"13 0 obj\n<< /Type /XRef /Size 14 /Index [7 1 12 1] /W [1 4 1] /Root 1 0 R /Length {rows.Length} >>\nstream\n");
        sb.Append(Encoding.Latin1.GetString(rows)).Append("\nendstream\nendobj\n");
        var xref = At();
        sb.Append($"xref\n0 1\n0000000000 65535 f \n7 1\n0000000000 00000 f \ntrailer\n<< /Size 14 /Root 1 0 R /Prev {prev} /XRefStm {at13} >>\nstartxref\n{xref}\n%%EOF\n");
        return Encoding.Latin1.GetBytes(sb.ToString());
    }

    /// <summary>
    /// As Word writes them: objects 1-4 and 7-9 in a classic table; the structure tree root (5) and the Document tag (6) in
    /// object stream 10, listed only by the xref stream 11 that the trailer's /XRefStm points at.
    /// </summary>
    private static byte[] HybridFile(bool tagInStream = false)
    {
        var content = "/P << /MCID 0 >> BDC BT /F1 12 Tf 72 700 Td (AB) Tj ET EMC";
        string[] plain =
        [
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 5 0 R /MarkInfo << /Marked true >> /Lang (en) >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /StructParents 0 /Resources << /Font << /F1 8 0 R >> >> >>",
            Core2Pdf.Stream(content),
        ];
        var o5 = "<< /Type /StructTreeRoot /K 6 0 R /ParentTree << /Nums [0 [7 0 R]] >> >>";
        var o6 = "<< /Type /StructElem /S /Document /P 5 0 R /K [7 0 R] >>";
        var o7 = "<< /Type /StructElem /S /P /P 6 0 R /Pg 3 0 R /K 0 >>";
        string[] after =
        [
            o7,
            A11yDoc.Type3Font,
            Core2Pdf.Stream("600 0 d0 0 0 600 700 re f"),
        ];
        var sb = new StringBuilder("%PDF-1.5\n");
        var offsets = new Dictionary<int, int>();
        void Obj(int n, string body)
        {
            offsets[n] = Encoding.Latin1.GetByteCount(sb.ToString());
            sb.Append($"{n} 0 obj\n{body}\nendobj\n");
        }
        for (var i = 0; i < plain.Length; i++) Obj(i + 1, plain[i]);
        for (var i = tagInStream ? 1 : 0; i < after.Length; i++) Obj(7 + i, after[i]);
        var objs = o5 + "\n" + o6 + (tagInStream ? "\n" + o7 : "");
        var header = $"5 0 6 {o5.Length + 1} " + (tagInStream ? $"7 {o5.Length + o6.Length + 2} " : "");
        Obj(10, Core2Pdf.Stream(header + objs, $"/Type /ObjStm /N {(tagInStream ? 3 : 2)} /First {header.Length}"));
        // The xref stream: 5 and 6 in object stream 10 (type 2), itself and the rest as usual.
        var rows = new List<byte>();
        void Row(int type, int f2, int f3) => rows.AddRange([(byte)type, (byte)(f2 >> 24), (byte)(f2 >> 16), (byte)(f2 >> 8), (byte)f2, (byte)f3]);
        Row(2, 10, 0);
        Row(2, 10, 1);
        if (tagInStream) Row(2, 10, 2);
        var xrefStmAt = Encoding.Latin1.GetByteCount(sb.ToString());
        offsets[11] = xrefStmAt;
        sb.Append($"11 0 obj\n<< /Type /XRef /Size 12 /Index [5 {(tagInStream ? 3 : 2)}] /W [1 4 1] /Root 1 0 R /Length {rows.Count} >>\nstream\n");
        sb.Append(Encoding.Latin1.GetString([.. rows])).Append("\nendstream\nendobj\n");
        var xref = Encoding.Latin1.GetByteCount(sb.ToString());
        sb.Append("xref\n0 12\n0000000000 65535 f \n");
        for (var n = 1; n <= 11; n++) sb.Append(offsets.TryGetValue(n, out var at) && n is not (5 or 6) ? $"{at:D10} 00000 n \n" : "0000000000 00000 f \n");
        sb.Append($"trailer\n<< /Size 12 /Root 1 0 R /XRefStm {xrefStmAt} >>\nstartxref\n{xref}\n%%EOF\n");
        return Encoding.Latin1.GetBytes(sb.ToString());
    }
}

internal static class A11yDocExtensions
{
    /// <summary>A ToUnicode for the composite font F2 (an extra object at the end).</summary>
    public static A11yDoc WithToUnicode(this A11yDoc doc)
    {
        var at = doc.MoreAt(doc.More.Length);
        return doc with
        {
            More = [doc.More[0].Replace("/DescendantFonts", $"/ToUnicode {at} 0 R /DescendantFonts"), .. doc.More[1..],
                Core2Pdf.Stream("1 begincodespacerange <0000> <FFFF> endcodespacerange 1 beginbfchar <0024> <0041> endbfchar")],
        };
    }
}

/// <summary>Batch's Check Accessibility action: the report beside each file; a file that fails isn't saved.</summary>
public sealed class AccessibilityBatchTests : IDisposable
{
    private readonly string _root = Directory.CreateTempSubdirectory("inkvolt-a11y-").FullName;

    public void Dispose()
    {
        try { Directory.Delete(_root, true); } catch (IOException) { }
    }

    [Fact]
    public async Task EachFileGetsItsReportAndAFailingFileFails()
    {
        var good = Path.Combine(_root, "good.pdf");
        var bad = Path.Combine(_root, "bad.pdf");
        File.WriteAllBytes(good, new A11yDoc().Build());
        File.WriteAllBytes(bad, new A11yDoc { Elems = ["<< /Type /StructElem /S /Figure /P 6 0 R /Pg 3 0 R /K 0 >>"] }.Build());
        var outFolder = Path.Combine(_root, "out");
        var plan = new BatchPlan { Steps = [new RotateStep(90), new CheckAccessibilityStep()], OutputFolder = outFolder };

        var summary = await BatchRunner.RunAsync([new BatchFile(good), new BatchFile(bad)], plan, new BatchHost(), null, CancellationToken.None);

        var ok = summary.Items[0];
        Assert.Equal(BatchItemState.Done, ok.State);
        Assert.Contains(Path.Combine(outFolder, "good.pdf"), ok.Outputs);
        Assert.Contains(Path.Combine(outFolder, "good accessibility.html"), ok.Outputs);
        Assert.Contains("Passes the machine checks.", File.ReadAllText(Path.Combine(outFolder, "good accessibility.html")));

        var failed = summary.Items[1];
        Assert.Equal(BatchItemState.Failed, failed.State);
        Assert.StartsWith("Accessibility check: Fails 1 condition", failed.Message);
        Assert.Contains(failed.Notes, n => n.StartsWith("13-004", StringComparison.Ordinal));
        Assert.False(File.Exists(Path.Combine(outFolder, "bad.pdf"))); // a failing file isn't saved
        var report = Assert.Single(failed.Outputs);
        Assert.Equal(Path.Combine(outFolder, "bad accessibility.html"), report);
        Assert.Contains("<th scope=\"row\">13-004</th>", File.ReadAllText(report));
    }

    [Fact]
    public void ThePresetNameRoundTrips()
    {
        var json = BatchPresets.Write(new BatchPreset { Name = "Check", Steps = [new CheckAccessibilityStep()] });
        Assert.Contains("\"checkAccessibility\"", json);
        Assert.IsType<CheckAccessibilityStep>(Assert.Single(BatchPresets.Read(json).Steps));
    }
}
