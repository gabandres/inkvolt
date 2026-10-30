using System.Text;
using InkvoltPdf.Core;
using PdfSharp.Pdf;

namespace InkvoltPdf.Tests;

/// <summary>
/// Files built to make a walk over their objects run forever: cycles, and objects shared so often that visiting each
/// use is exponential. Each must finish in seconds (a hang fails the test instead of blocking the run).
/// </summary>
public class HostileStructureTests
{
    private static async Task<T> Within<T>(Func<T> work, int seconds = 20) =>
        await Task.Run(work).WaitAsync(TimeSpan.FromSeconds(seconds));

    private const string Widget = "/Type /Annot /Subtype /Widget /F 4 /P 3 0 R";

    [Fact]
    public async Task ChoiceFieldWhoseParentCyclesTakesNewItems()
    {
        var form = Core2Pdf.Form(
        [
            $"<< {Widget} /FT /Tx /T (a) /Rect [72 700 250 720] /DA (/Helv 10 Tf 0 g) >>",
            $"<< {Widget} /FT /Tx /T (b) /Rect [72 670 250 690] /DA (/Helv 10 Tf 0 g) /V (old) /AA << /C 8 0 R >> >>",
            $"<< {Widget} /FT /Ch /T (c) /Rect [72 640 250 660] /DA (/Helv 10 Tf 0 g) /Parent 7 0 R >>",
        ], "/CO [6 0 R]", more: ["<< /S /JavaScript /JS (getField\\('c'\\).setItems\\(['x', 'y']\\); event.value = 'ran';) >>"]);
        var r = await Within(() => FormEditor.Fill(form, null, new Dictionary<string, string> { ["a"] = "1" }));
        using var doc = Core2Pdf.Open(r.Data);
        var c = doc.Internals.GetAllObjects().OfType<PdfDictionary>().Single(d => PdfObj.Str(d.Elements["/T"]) == "c");
        Assert.Equal(2, PdfObj.Array(c.Elements["/Opt"])?.Elements.Count);
    }

    /// <summary>Page 1 links with action 6: a chain of <paramref name="levels"/> actions, each with /Next [n n] to the next.</summary>
    private static byte[] ActionChain(int levels, string last)
    {
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /Annot /Subtype /Widget /FT /Btn /Ff 65536 /T (go) /Rect [0 0 100 100] /A 6 0 R >>",
        };
        for (var i = 0; i < levels; i++)
            objects.Add(i == levels - 1 ? last : $"<< /S /URI /URI (https://example.com/{i}) /Next [{7 + i} 0 R {7 + i} 0 R] >>");
        return Core2Pdf.Build(objects);
    }

    private static PdfDictionary Button(byte[] pdf)
    {
        using var doc = Core2Pdf.Open(pdf);
        return PdfObj.Dict(PdfObj.Array(doc.Pages[0].Elements["/Annots"])!.Elements[0])!;
    }

    [Fact]
    public async Task DeletingAPageWalksSharedActionChainsOnce()
    {
        // 2^40 paths through the chain: each action is looked at once.
        var kept = await Within(() => PageEditor.Delete(ActionChain(40, "<< /S /URI /URI (https://example.com/end) >>"), null, [1]));
        Assert.NotNull(Button(kept).Elements["/A"]);
        // The chain still counts: a jump to the deleted page at its end takes the action away.
        var dead = await Within(() => PageEditor.Delete(ActionChain(12, "<< /S /GoTo /D [4 0 R /Fit] >>"), null, [1]));
        Assert.Null(Button(dead).Elements["/A"]);
    }

    [Fact]
    public async Task DeletingAPageSurvivesAnActionThatIsItsOwnNext()
    {
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R 4 0 R] /Count 2 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [5 0 R] >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /Annot /Subtype /Link /Rect [0 0 100 100] /A 6 0 R >>",
            "<< /S /URI /URI (https://example.com) /Next [6 0 R] >>",
        ]);
        using (var doc = Core2Pdf.Open(await Within(() => PageEditor.Delete(pdf, null, [1])))) Assert.Equal(1, doc.PageCount);
        using (var doc = Core2Pdf.Open(await Within(() => PageEditor.Extract(pdf, null, [0])))) Assert.Equal(1, doc.PageCount);
    }

    /// <summary>Twelve forms, each drawing the next one six times (6^11 draws of the last); the last draws <paramref name="leaf"/>.</summary>
    private static byte[] FormChain(string leaf, string leafResources = "", string? more = null)
    {
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /F 4 0 R >> >> /Contents 16 0 R >>",
        };
        for (var i = 0; i < 12; i++)
        {
            var body = i == 11 ? leaf : string.Concat(Enumerable.Repeat("/F Do\n", 6));
            var res = i == 11 ? leafResources : $"/Resources << /XObject << /F {5 + i} 0 R >> >>";
            objects.Add(Core2Pdf.Stream(body, $"/Type /XObject /Subtype /Form /BBox [0 0 10 10] {res}"));
        }
        objects.Add(Core2Pdf.Stream("/F Do"));
        if (more is not null) objects.Add(more);
        return Core2Pdf.Build(objects);
    }

    [Fact]
    public async Task OptimizingWalksAFormDrawnManyTimesOnce()
    {
        var r = await Within(() => Optimizer.Optimize(FormChain("0 0 1 1 re f"), null));
        Assert.True(r.SizeAfter > 0);
        // An image at the end of the chain: found, at the size it is drawn.
        var image = Core2Pdf.Stream(new string('x', 3 * 20 * 20), "/Type /XObject /Subtype /Image /Width 20 /Height 20 /ColorSpace /DeviceRGB /BitsPerComponent 8");
        var pdf = FormChain("q 2 0 0 2 0 0 cm /Im Do Q", "/Resources << /XObject << /Im 17 0 R >> >>", image);
        var hits = await Within(() =>
        {
            using var doc = Core2Pdf.Open(pdf);
            var list = new List<double[]>();
            ContentImages.Scan(doc.Pages[0], (_, ctm) => list.Add(ctm));
            return list;
        });
        Assert.Equal(new[] { 2.0, 0, 0, 2, 0, 0 }, Assert.Single(hits));
    }

    [Fact]
    public async Task ShapeDetectionReadsAFormDrawnManyTimesOnce()
    {
        // A form of a 1 MB comment and one square, drawn 100,000 times.
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /F 5 0 R >> >> /Contents 4 0 R >>",
            Core2Pdf.Stream("0 0 0 RG 72 72 100 100 re S\n" + string.Concat(Enumerable.Repeat("/F Do\n", 100_000))),
            Core2Pdf.Stream("% " + new string('x', 1 << 20) + "\n0 0 1 1 re n", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
        ]);
        var shapes = await Within(() => VectorShapes.Read(pdf, null, 0));
        Assert.Single(shapes);
    }

    [Fact]
    public void FormsDrawnAgainReportEachPlaceTheirImagesShow()
    {
        // F scales by 2 and draws the image 10 units wide; G draws F twice (the second moved); the page draws G twice.
        var image = Core2Pdf.Stream(new string('x', 3 * 4 * 4), "/Type /XObject /Subtype /Image /Width 4 /Height 4 /ColorSpace /DeviceRGB /BitsPerComponent 8");
        var pdf = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /G 5 0 R /Im 6 0 R >> >> /Contents 4 0 R >>",
            Core2Pdf.Stream("/G Do q 3 0 0 3 0 0 cm /G Do Q /Im Do"),
            Core2Pdf.Stream("/F Do q 1 0 0 1 5 5 cm /F Do Q", "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Resources << /XObject << /F 7 0 R >> >>"),
            image,
            Core2Pdf.Stream("q 10 0 0 10 0 0 cm /Im Do Q", "/Type /XObject /Subtype /Form /BBox [0 0 10 10] /Matrix [2 0 0 2 0 0] /Resources << /XObject << /Im 6 0 R >> >>"),
        ]);
        using var doc = Core2Pdf.Open(pdf);
        var hits = new List<string>();
        ContentImages.Scan(doc.Pages[0], (_, ctm) => hits.Add(string.Join(' ', ctm)));
        Assert.Equal(["20 0 0 20 0 0", "20 0 0 20 5 5", "60 0 0 60 0 0", "60 0 0 60 15 15", "1 0 0 1 0 0"], hits);
    }

    [Fact]
    public async Task SanitizingWalksSharedLayerArraysOnce()
    {
        // 5 is off and named in the visibility expression of a shown annotation (not 5), whose arrays share each level
        // (4^15 paths): it stays. 6 is off and only in /Order, nested 30 deep with each level shared (2^30 paths): it goes.
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R /OCProperties << /OCGs [5 0 R 6 0 R] /D << /OFF [5 0 R 6 0 R] /Order 8 0 R >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [4 0 R] >>",
            "<< /Type /Annot /Subtype /Square /Rect [0 0 10 10] /OC 7 0 R >>",
            "<< /Type /OCG /Name (Kept) >>",
            "<< /Type /OCG /Name (Gone) >>",
            "<< /Type /OCMD /VE 38 0 R >>",
        };
        for (var i = 0; i < 30; i++) objects.Add(i == 29 ? "[5 0 R 6 0 R]" : $"[{9 + i} 0 R {9 + i} 0 R]");
        for (var i = 0; i < 16; i++) objects.Add(i == 15 ? "[/Not 5 0 R]" : "[/Or " + string.Join(' ', Enumerable.Repeat($"{39 + i} 0 R", 4)) + "]");
        var pdf = Core2Pdf.Build(objects);

        Assert.Equal(2, (await Within(() => Sanitizer.Scan(pdf, null)))[SanitizeItem.HiddenLayers]);
        var result = await Within(() => Sanitizer.Sanitize(pdf, null, new HashSet<SanitizeItem> { SanitizeItem.HiddenLayers }));
        using var doc = Core2Pdf.Open(result.Data);
        var props = PdfObj.Dict(doc.Internals.Catalog.Elements["/OCProperties"])!;
        string Names(PdfArray a) => string.Join(',', a.Elements.Select(e => PdfObj.Dict(e) is { } d ? PdfObj.Str(d.Elements["/Name"]) : "[" + Names(PdfObj.Array(e)!) + "]"));
        Assert.Equal("Kept", Names(PdfObj.Array(props.Elements["/OCGs"])!));
        var order = PdfObj.Array(PdfObj.Dict(props.Elements["/D"])!.Elements["/Order"])!;
        for (var i = 0; i < 29; i++) order = PdfObj.Array(order.Elements[0])!;
        Assert.Equal("Kept", Names(order));
    }

    [Fact]
    public async Task RedactingWalksASharedStructureTreeOnce()
    {
        // /K arrays two of the next one each, 40 deep (2^40 paths), down to a paragraph of page 1 with alternate text.
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /StructTreeRoot /K 5 0 R >>",
        };
        for (var i = 0; i < 40; i++) objects.Add(i == 39 ? "[<< /S /P /Pg 3 0 R /K 0 /Alt (Secret words) >>]" : $"[{6 + i} 0 R {6 + i} 0 R]");
        var result = await Within(() => Redaction.Apply(Core2Pdf.Build(objects), null, new Dictionary<int, IReadOnlyList<RectD>> { [0] = [new RectD(10, 10, 50, 50)] }, 36));
        using var doc = Core2Pdf.Open(result);
        Assert.DoesNotContain(doc.Internals.GetAllObjects().OfType<PdfDictionary>(), d => d.Elements.ContainsKey("/Alt"));
    }

    [Fact]
    public async Task ExportReadsASharedStructureTreeOnce()
    {
        // An array in itself (5: [5 0 R 6 0 R 6 0 R]), then arrays two of the next one each, 40 deep, down to a figure.
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R /StructTreeRoot 4 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>",
            "<< /Type /StructTreeRoot /K 5 0 R >>",
            "[5 0 R 6 0 R 6 0 R]",
        };
        for (var i = 0; i < 40; i++) objects.Add(i == 39 ? "[<< /S /Figure /Pg 3 0 R /Alt (A cat) >>]" : $"[{7 + i} 0 R {7 + i} 0 R]");
        var tags = await Within(() => ExportTags.Read(Core2Pdf.Build(objects), null));
        Assert.Equal("A cat", Assert.Single(tags.Figures).Alt);
    }
}
