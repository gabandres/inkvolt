using System.Net;
using System.Text;
using System.Text.RegularExpressions;
using DocumentFormat.OpenXml;
using DocumentFormat.OpenXml.Packaging;
using DocumentFormat.OpenXml.Validation;
using InkvoltPdf.Core;
using MuPDFCore;
using MuPDFCore.StructuredText;

// export <in.pdf> <out.docx>   Export to Word as the app does, plus <out>.txt, .pptx and .html (the other exports) beside it.
// pptx <file.pptx>             The Open XML SDK's validator on it: "slides shapes errors", then the first errors.
// html <file.html> <file.txt>  Active content (none allowed), and whether the text reads in the plain-text export's order.
// glyphs <in.pdf> <out.txt>    What MuPDF reads, line by line: text lines, vector boxes, and every glyph's box on lines
//                              holding loose accents or leader dots (how the S-73-S form's problems were found).
switch (args)
{
    case ["export", var pdf, var docx]:
    {
        using var engine = PdfEngine.Open(File.ReadAllBytes(pdf), InputFileTypes.PDF, null);
        var options = new ExportOptions { Title = Path.GetFileNameWithoutExtension(pdf) };
        var report = DocumentExport.ExportToFile(engine, ExportFormat.Word, docx, options);
        DocumentExport.ExportToFile(engine, ExportFormat.Text, Path.ChangeExtension(docx, ".txt"), options);
        var withSource = options with { Source = File.ReadAllBytes(pdf) };
        DocumentExport.ExportToFile(engine, ExportFormat.PowerPoint, Path.ChangeExtension(docx, ".pptx"), withSource);
        DocumentExport.ExportToFile(engine, ExportFormat.Html, Path.ChangeExtension(docx, ".html"), withSource);
        Console.WriteLine($"{Path.GetFileName(pdf)}: {report.Pages} page(s) -> {docx}");
        return 0;
    }
    case ["pptx", var file]:
    {
        using var doc = PresentationDocument.Open(file, false);
        var errors = new OpenXmlValidator(FileFormatVersions.Microsoft365).Validate(doc).ToList();
        var slides = doc.PresentationPart!.SlideParts.ToList();
        // What PowerPoint counts as a slide's shapes: the tree's children but its own two.
        var shapes = slides.Sum(s => s.Slide.CommonSlideData!.ShapeTree!.ChildElements.Count - 2);
        Console.WriteLine($"{slides.Count} {shapes} {errors.Count}");
        foreach (var e in errors.Take(5)) Console.WriteLine($"{e.Part?.Uri} {e.Path?.XPath}: {e.Description}");
        return errors.Count == 0 ? 0 : 1;
    }
    case ["html", var file, var txt]:
    {
        var html = File.ReadAllText(file);
        var active = Regex.Matches(html, @"<(script|iframe|object|embed|link|base|form|svg|math|video|audio|source|a)|\son\w+\s*=|\s(href|srcset)\s*=|\ssrc=""(?!data:image/(png|jpeg);base64,)", RegexOptions.IgnoreCase).Count;
        // Lines of the plain-text export found, each after the one before: reading order, as a screen reader meets it.
        var main = html[html.IndexOf("<main>", StringComparison.Ordinal)..html.IndexOf("</main>", StringComparison.Ordinal)];
        var text = Words(Regex.Replace(Regex.Replace(main, "</?(strong|em|code)>", ""), "<[^>]+>", " "), true);
        var lines = File.ReadAllLines(txt).Select(l => Words(l.TrimStart('﻿'), false)).Where(l => l.Length >= 20).ToList();
        var (at, found, inOrder) = (0, 0, 0);
        foreach (var whole in lines)
        {
            // A numbered item's number is the list's in HTML, not in its text.
            var line = text.Contains(whole, StringComparison.Ordinal) || !whole.Contains(' ') ? whole : whole[(whole.IndexOf(' ') + 1)..];
            // Near the line before: a line that also appears much later (a repeated row) mustn't lose the place.
            var i = text.IndexOf(line, at, Math.Min(text.Length - at, 6000), StringComparison.Ordinal);
            if (i >= 0) { found++; inOrder++; at = i; }
            else if (text.Contains(line, StringComparison.Ordinal)) found++;
        }
        Console.WriteLine($"active={active} lines={lines.Count} found={found} inOrder={inOrder}");
        return active == 0 ? 0 : 1;
    }
    case ["glyphs", var pdf, var txt]:
        File.WriteAllText(txt, Glyphs(pdf));
        return 0;
    default:
        Console.Error.WriteLine("usage: ExportCorpus export <in.pdf> <out.docx> | pptx <file.pptx> | html <file.html> <file.txt> | glyphs <in.pdf> <out.txt>");
        return 2;
}

// Letters and digits only, one space between words (HTML takes list markers and tabs apart; only the words are compared).
static string Words(string s, bool decode)
{
    if (decode) s = WebUtility.HtmlDecode(s);
    return string.Join(' ', Regex.Split(s, @"[^\p{L}\p{N}]+").Where(w => w.Length > 0));
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
