using System.Text;
using InkvoltPdf.Core;
using MuPDFCore;
using MuPDFCore.StructuredText;

// export <in.pdf> <out.docx>   Export to Word as the app does, plus <out>.txt (the plain-text export) beside it.
// glyphs <in.pdf> <out.txt>    What MuPDF reads, line by line: text lines, vector boxes, and every glyph's box on lines
//                              holding loose accents or leader dots (how the S-73-S form's problems were found).
switch (args)
{
    case ["export", var pdf, var docx]:
    {
        using var engine = PdfEngine.Open(File.ReadAllBytes(pdf), InputFileTypes.PDF, null);
        var pages = Enumerable.Range(0, engine.PageCount).Select(i => engine.GetExportPage(i, true)).ToList();
        using (var fs = File.Create(docx)) DocumentExport.WriteDocx(fs, pages, Path.GetFileNameWithoutExtension(pdf));
        File.WriteAllText(Path.ChangeExtension(docx, ".txt"), DocumentExport.PlainText(pages));
        Console.WriteLine($"{Path.GetFileName(pdf)}: {pages.Count} page(s) -> {docx}");
        return 0;
    }
    case ["glyphs", var pdf, var txt]:
        File.WriteAllText(txt, Glyphs(pdf));
        return 0;
    default:
        Console.Error.WriteLine("usage: ExportCorpus export <in.pdf> <out.docx> | glyphs <in.pdf> <out.txt>");
        return 2;
}

static string Glyphs(string pdf)
{
    const string Loose = "´ˆˇ˙˛˜¨`"; // spacing accents and the "ogonek" leader dot
    using var ctx = new MuPDFContext();
    using var doc = new MuPDFDocument(ctx, pdf);
    var sb = new StringBuilder();
    for (var p = 0; p < doc.Pages.Count; p++)
    {
        using var st = doc.GetStructuredTextPage(p, true, StructuredTextFlags.CollectVectors);
        sb.AppendLine($"=== page {p + 1}");
        foreach (var block in st)
        {
            if (block is MuPDFVectorStructuredTextBlock vb)
            {
                sb.AppendLine($"V {vb.BoundingBox.X0:F1},{vb.BoundingBox.Y0:F1}-{vb.BoundingBox.X1:F1},{vb.BoundingBox.Y1:F1} stroked={vb.Stroked}");
                continue;
            }
            if (block is not MuPDFTextStructuredTextBlock tb) continue;
            foreach (var line in tb)
            {
                var chars = line.ToList();
                var text = string.Concat(chars.Select(c => c.Character));
                if (!text.Any(c => Loose.Contains(c)))
                {
                    sb.AppendLine("T " + text);
                    continue;
                }
                sb.AppendLine("G " + string.Join(" ", chars.Select(c =>
                    $"{(c.Character == " " ? "_" : c.Character)}[{c.BoundingQuad.LowerLeft.X:F1}-{c.BoundingQuad.LowerRight.X:F1},{c.BoundingQuad.UpperLeft.Y:F1}-{c.BoundingQuad.LowerLeft.Y:F1} {c.Size:F1}pt]")));
            }
        }
    }
    return sb.ToString();
}
