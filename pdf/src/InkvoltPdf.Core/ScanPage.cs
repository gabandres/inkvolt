using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// Recognize Text's optional last step (off by default): a scanned page's content becomes its cleaned image
/// (<see cref="CleanedPageImage"/>: straightened, despeckled, the paper whitened), drawn over the whole displayed page,
/// and the page is turned upright with its /Rotate. Its comments, links and form fields stay as they were (they turn
/// with the page). Only for pages that are a scan: a page with text is never recognized, so never replaced.
/// </summary>
public static class ScanPage
{
    public static byte[] WriteBack(byte[] data, string? password, IReadOnlyDictionary<int, CleanedPageImage> pages)
    {
        if (pages.Count == 0) return data;
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, "This PDF can't be edited");
        foreach (var (index, img) in pages.OrderBy(kv => kv.Key))
        {
            if (index < 0 || index >= doc.PageCount) throw new ArgumentOutOfRangeException(nameof(pages), $"There is no page {index + 1}.");
            Replace(doc, doc.Pages[index], img);
        }
        return PdfObj.Save(doc);
    }

    private static void Replace(PdfDocument doc, PdfPage page, CleanedPageImage img)
    {
        var pixels = img.Pixels;
        if (img.Channels == 3)
        {
            pixels = new byte[img.Pixels.Length];
            for (var i = 0; i < pixels.Length; i += 3)
            {
                pixels[i] = img.Pixels[i + 2];
                pixels[i + 1] = img.Pixels[i + 1];
                pixels[i + 2] = img.Pixels[i];
            }
        }
        var image = PdfObj.AddStream(doc, pixels);
        image.Elements["/Type"] = new PdfName("/XObject");
        image.Elements["/Subtype"] = new PdfName("/Image");
        image.Elements["/Width"] = new PdfInteger(img.Width);
        image.Elements["/Height"] = new PdfInteger(img.Height);
        image.Elements["/ColorSpace"] = new PdfName(img.Channels == 3 ? "/DeviceRGB" : "/DeviceGray");
        image.Elements["/BitsPerComponent"] = new PdfInteger(8);

        // The image is upright as displayed; map its unit square onto the (rotated) crop box.
        var (dw, dh) = PdfObj.DisplaySize(page);
        var o = PdfObj.ToPdf(page, 0, dh);
        var u = PdfObj.ToPdf(page, dw, dh);
        var v = PdfObj.ToPdf(page, 0, 0);
        var ops = $"q {PdfObj.F(u.X - o.X)} {PdfObj.F(u.Y - o.Y)} {PdfObj.F(v.X - o.X)} {PdfObj.F(v.Y - o.Y)} {PdfObj.F(o.X)} {PdfObj.F(o.Y)} cm /PdScan Do Q\n";
        page.Elements["/Contents"] = PdfObj.AddStream(doc, Encoding.ASCII.GetBytes(ops)).Reference!;
        var xobjects = new PdfDictionary(doc);
        xobjects.Elements["/PdScan"] = image.Reference!;
        var resources = new PdfDictionary(doc);
        resources.Elements["/XObject"] = xobjects;
        page.Elements["/Resources"] = resources;
        page.Elements.Remove("/Thumb"); // the old scan's thumbnail
        if (img.QuarterTurns % 4 != 0) page.Rotate = (((page.Rotate + 90 * img.QuarterTurns) % 360) + 360) % 360;
    }
}
