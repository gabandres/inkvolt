using System.Text;
using PdfSharp.Pdf;
using InkvoltPrint.Core.Imaging;
using PdfSharp.Pdf.IO;
using ScanPdfWriter = InkvoltPrint.Core.Pdf.PdfWriter;

namespace InkvoltPdf.Core;

/// <summary>
/// Recognize Text's optional last step (off by default): a scanned page's content becomes its cleaned image
/// (<see cref="CleanedPageImage"/>: straightened, despeckled, the paper whitened), drawn over the whole displayed page,
/// and the page is turned upright with its /Rotate. Its comments, links and form fields stay as they were (they turn
/// with the page). Only for pages that are a scan: a page with text is never recognized, so never replaced. A page whose
/// scan was black and white (every image it draws at 1 bit) stays black and white: the cleaned page at 1 bit, as lossless
/// JBIG2, CCITT G4 or Flate (<see cref="ScanPdfWriter.OneBit"/>), not ten times the size in grey.
/// </summary>
public static class ScanPage
{
    public static byte[] WriteBack(byte[] data, string? password, IReadOnlyDictionary<int, CleanedPageImage> pages)
    {
        if (pages.Count == 0) return data;
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, PdfStrings.Doc_CantEdit);
        foreach (var (index, img) in pages.OrderBy(kv => kv.Key))
        {
            if (index < 0 || index >= doc.PageCount) throw new ArgumentOutOfRangeException(nameof(pages), Loc.Format(PdfStrings.Page_NoPageN, index + 1));
            Replace(doc, doc.Pages[index], img);
        }
        return PdfObj.Save(doc);
    }

    private static void Replace(PdfDocument doc, PdfPage page, CleanedPageImage img)
    {
        var image = new PdfDictionary(doc);
        if (img.Channels == 1 && IsOneBit(page) && OneBit(img) is { } bits)
        {
            var (coding, data) = ScanPdfWriter.OneBitData(bits, jbig2: true);
            image.CreateStream(data);
            OneBitImages.SetCoding(image, coding, bits.Width, bits.Height);
            image.Elements["/BitsPerComponent"] = new PdfInteger(1);
        }
        else
        {
            image.CreateStream(img.Deflated);
            image.Elements["/Filter"] = new PdfName("/FlateDecode");
            image.Elements["/BitsPerComponent"] = new PdfInteger(8);
        }
        doc.Internals.AddObject(image);
        image.Elements["/Type"] = new PdfName("/XObject");
        image.Elements["/Subtype"] = new PdfName("/Image");
        image.Elements["/Width"] = new PdfInteger(img.Width);
        image.Elements["/Height"] = new PdfInteger(img.Height);
        image.Elements["/ColorSpace"] = new PdfName(img.Channels == 3 ? "/DeviceRGB" : "/DeviceGray");

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

    /// <summary>The page draws images, every one of them at 1 bit (a black-and-white scan).</summary>
    internal static bool IsOneBit(PdfPage page)
    {
        var (any, all) = (false, true);
        var complete = ContentImages.Scan(page, (image, _) =>
        {
            any = true;
            all &= PdfObj.Int(image.Elements["/BitsPerComponent"]) == 1 || PdfObj.Resolve(image.Elements["/ImageMask"]) is PdfBoolean { Value: true };
        });
        return complete && any && all;
    }

    /// <summary>The cleaned grey page at 1 bit: the cleanup has whitened the paper, so the level that best parts ink from paper.</summary>
    private static BitImage? OneBit(CleanedPageImage img)
    {
        if ((long)img.Width * img.Height > BitImage.MaxPixels) return null;
        var gray = PdfObj.Inflate(img.Deflated, (long)img.Width * img.Height);
        if (gray is null || gray.Length < (long)img.Width * img.Height) return null;
        return BitImage.FromGray(gray, img.Width, img.Height, Bilevel.Threshold(gray));
    }
}
