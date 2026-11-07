using InkvoltPdf.Core;

namespace InkvoltPdf.Tests;

/// <summary>What a few kilobytes name, filling a form must not multiply: one dictionary of faces shared by every widget.</summary>
public class HostileFormFillTests
{
    private const string Widget = "/Type /Annot /Subtype /Widget /F 4";

    [Fact]
    public async Task OneDictionaryOfFacesOnEveryWidgetIsNotMultiplied()
    {
        // 1,500 check box widgets share an appearance with a missing on face and 3,000 other faces: drawn again, each widget
        // copied them all (4.5 million entries, 100 MB written) and looked inside each.
        const int widgets = 1500, faces = 3000;
        const int firstKid = 9;
        var kids = string.Join(' ', Enumerable.Range(firstKid, widgets).Select(i => $"{i} 0 R"));
        var names = string.Join(' ', Enumerable.Range(0, faces).Select(i => $"/F{i} 7 0 R"));
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R >> >> >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots [{kids}] >>",
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
            $"<< /FT /Btn /T (c) /V /Off /Kids [{kids}] >>",
            "<< /N 8 0 R >>",
            Core2Pdf.Stream("0 0 m 1 1 l S", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
            $"<< /On 900000 0 R {names} >>",
        };
        for (var w = 0; w < widgets; w++) objects.Add($"<< {Widget} /Parent 5 0 R /Rect [10 10 30 30] /AP 6 0 R /AS /Off /MK << /CA (4) >> >>");
        var form = Core2Pdf.Build(objects);

        var filled = await Task.Run(() => FormEditor.Fill(form, null, new Dictionary<string, string> { ["c"] = "On" }).Data)
            .WaitAsync(Timing.Limit(TimeSpan.FromSeconds(120)));

        Assert.InRange(filled.Length, 0, 8L * form.Length + (2 << 20));
    }

    [Fact]
    public void OneWidgetListOnEveryPageIsNotMultiplied()
    {
        // 2,000 pages x 2,000 widgets: 4 million places (hundreds of MB of records) from a file of 300 KB.
        const int pages = 2000, widgets = 2000;
        var refs = string.Join(' ', Enumerable.Range(4 + pages, widgets).Select(i => $"{i} 0 R"));
        var kids = string.Join(' ', Enumerable.Range(4, pages).Select(i => $"{i} 0 R"));
        var objects = new List<string> { "<< /Type /Catalog /Pages 2 0 R >>", $"<< /Type /Pages /Kids [{kids}] /Count {pages} >>", $"[{refs}]" };
        for (var p = 0; p < pages; p++) objects.Add("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Annots 3 0 R >>");
        for (var w = 0; w < widgets; w++) objects.Add($"<< {Widget} /FT /Tx /T (f{w}) /Rect [10 10 50 30] >>");
        var pdf = Core2Pdf.Build(objects);
        Assert.ThrowsAny<InvalidOperationException>(() => FormEditor.Read(pdf, null));
    }

    [Fact]
    public void AnOnFaceMissingKeepsTheFacesThatDraw()
    {
        // The real case: a state dictionary whose on face is missing keeps its off look.
        var form = Core2Pdf.Form(
        [
            $"<< {Widget} /FT /Btn /T (c) /V /Off /AS /Off /Rect [10 10 30 30] /AP << /N << /On 99 0 R /Off 6 0 R >> >> /MK << /CA (4) >> >>",
            Core2Pdf.Stream("0 0 m 1 1 l S", "/Type /XObject /Subtype /Form /BBox [0 0 10 10]"),
        ]);
        var filled = FormEditor.Fill(form, null, new Dictionary<string, string> { ["c"] = "On" }).Data;
        Assert.NotEqual("Off", FormEditor.Read(filled, null).Single(w => w.FieldName == "c").Value);
    }
}
