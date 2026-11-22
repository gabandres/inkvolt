using InkvoltPrint.Core.Imaging;
using InkvoltPrint.Core.Pdf;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>
/// Black-and-white pictures made smaller (roadmap 4.8), for Reduce File Size and Recognize Text's cleaned pages. A picture
/// already at 1 bit (a black-and-white scan, a stencil) is coded again, losslessly, as JBIG2's generic region, CCITT G4 or
/// Flate, whichever is smallest, only when that is smaller than it is now, and only after the new coding is drawn back the
/// same pixel for pixel. A grey picture that is a scan of text (<see cref="LooksBlackAndWhite"/>) becomes 1 bit only when
/// the user asks for black and white: that is the one loss, the thresholding (<see cref="Bilevel"/>); never JBIG2's symbol
/// matching, which can put one digit in place of another.
/// </summary>
public static class OneBitImages
{
    /// <summary>A picture this large is left as it is (its drawing alone would take over a gigabyte).</summary>
    private const long MaxPixels = 120_000_000;

    /// <summary>The smallest grey picture taken for a scanned page: about a third of a letter page at 150 dpi.</summary>
    internal const long MinScanPixels = 700_000;

    /// <summary>The smallest 1-bit picture coded again, in bytes as stored.</summary>
    private const int MinRecodedBytes = 4096;

    /// <summary>The image stream's filter entries for <paramref name="coding"/> (any older parameters removed).</summary>
    public static void SetCoding(PdfDictionary image, OneBitCoding coding, int width, int height)
    {
        image.Elements.Remove("/DecodeParms");
        switch (coding)
        {
            case OneBitCoding.CcittG4:
                image.Elements["/Filter"] = new PdfName("/CCITTFaxDecode");
                var parms = new PdfDictionary();
                parms.Elements["/K"] = new PdfInteger(-1);
                parms.Elements["/Columns"] = new PdfInteger(width);
                parms.Elements["/Rows"] = new PdfInteger(height);
                image.Elements["/DecodeParms"] = parms;
                break;
            case OneBitCoding.Jbig2:
                image.Elements["/Filter"] = new PdfName("/JBIG2Decode");
                break;
            default:
                image.Elements["/Filter"] = new PdfName("/FlateDecode");
                break;
        }
    }

    /// <summary>
    /// A 1-bit picture coded again in the smallest of the three when that saves anything; its colours, decode array and
    /// mask stay as they are, only how its samples are packed changes. Null when it isn't 1 bit, is too large, is JBIG2
    /// already (perhaps with shared symbols) or encrypted on its own, can't be drawn, or nothing would be saved; else the
    /// change, made by the caller on the document's thread (the work before it reads only, several pictures at once).
    /// </summary>
    /// <param name="draw">Draws a one-image page (the picture's dictionary entries and stream) at one pixel a sample, as RGB.</param>
    internal static Action? Recode(PdfDictionary image, Func<string, byte[], int, int, byte[]?> draw, CancellationToken cancel = default)
    {
        // A small picture (an icon, a rule) has little to save and costs two drawings: left as it is.
        if (image.Stream is not { } stream || stream.Value.Length < MinRecodedBytes) return null;
        var bpc = PdfObj.Int(image.Elements["/BitsPerComponent"]);
        var stencil = PdfObj.Resolve(image.Elements["/ImageMask"]) is PdfBoolean { Value: true };
        if (bpc != 1 && !(stencil && bpc is null)) return null;
        // One sample a pixel only: a 1-bit RGB or CMYK picture has three or four, which a grey drawing would mix up.
        if (!stencil && !OneComponent(image.Elements["/ColorSpace"])) return null;
        int w = PdfObj.Int(image.Elements["/Width"]) ?? 0, h = PdfObj.Int(image.Elements["/Height"]) ?? 0;
        if (w <= 0 || h <= 0 || (long)w * h > MaxPixels || (long)w * h > BitImage.MaxPixels) return null;
        if (Filters(image) is not { } filters || filters.Any(f => f is "JBIG2Decode" or "JPXDecode" or "DCTDecode" or "Crypt")) return null;

        // The samples as they are (whatever the colours, the decode array or the stencil make of them): drawn as grey at 1 bit.
        if (Samples(image, w, h, draw) is not { } bits) return null;
        cancel.ThrowIfCancellationRequested();
        var (coding, data) = PdfWriter.OneBitData(bits, jbig2: true, cancel);
        if (data.Length >= stream.Value.Length) return null;
        var probe = new PdfDictionary();
        SetCoding(probe, coding, w, h);
        if (Samples(probe, w, h, draw, data) is not { } back || !back.Bits.AsSpan().SequenceEqual(bits.Bits)) return null; // proves it

        return () =>
        {
            stream.Value = data;
            image.Elements["/Length"] = new PdfInteger(data.Length);
            SetCoding(image, coding, w, h);
        };
    }

    /// <summary>
    /// A grey or colour picture of a scanned page of text made black and white (<see cref="Bilevel.FromScan"/>) and coded as
    /// <see cref="Recode"/> codes, when it <see cref="LooksBlackAndWhite"/> and that is smaller. Only on the user's request.
    /// Null, or the change to make (as <see cref="Recode"/>'s).
    /// </summary>
    /// <param name="source">The picture's dictionary entries to draw it on its own (8 bits, a device colour space).</param>
    /// <param name="dpi">The resolution it is shown at, for the cleanup's speck size.</param>
    internal static Action? Threshold(PdfDictionary image, string source, int dpi, Func<string, byte[], int, int, byte[]?> draw, CancellationToken cancel = default)
    {
        if (image.Stream is not { } stream || image.Elements.ContainsKey("/SMask") || image.Elements.ContainsKey("/Mask")) return null;
        int w = PdfObj.Int(image.Elements["/Width"]) ?? 0, h = PdfObj.Int(image.Elements["/Height"]) ?? 0;
        if ((long)w * h < MinScanPixels || (long)w * h > MaxPixels || (long)w * h > BitImage.MaxPixels) return null;
        if (draw(source, stream.Value, w, h) is not { } rgb || rgb.Length < (long)w * h * 3) return null;
        cancel.ThrowIfCancellationRequested();
        if (Gray(rgb, w, h) is not { } gray || !LooksBlackAndWhite(gray, w, h)) return null;
        var bits = Bilevel.FromScan(gray, w, h, Math.Clamp(dpi, 50, 2400), cancel);
        var (coding, data) = PdfWriter.OneBitData(bits, jbig2: true, cancel);
        if (data.Length >= stream.Value.Length) return null;

        return () =>
        {
            stream.Value = data;
            image.Elements["/Length"] = new PdfInteger(data.Length);
            image.Elements["/BitsPerComponent"] = new PdfInteger(1);
            image.Elements["/ColorSpace"] = new PdfName("/DeviceGray");
            image.Elements.Remove("/Decode");
            image.Elements.Remove("/Intent");
            SetCoding(image, coding, w, h);
        };
    }

    /// <summary>
    /// The grey pixels are ink on paper: two clear groups (Otsu's split) far apart, few pixels between them (a scan's soft
    /// letter edges, not a photo's or a drawing's shades). A grey page of text passes; a photo, a gradient, a page on
    /// strongly tinted paper doesn't. Judged on the page smoothed as <see cref="Bilevel.FromScan"/> smooths it, so a
    /// scanner's noise doesn't count as shades.
    /// </summary>
    /// <param name="gray">Rows of <paramref name="width"/> bytes, 0 black.</param>
    public static bool LooksBlackAndWhite(byte[] gray, int width, int height)
    {
        if (width < 1 || height < 1 || gray.Length < (long)width * height) return false;
        var smooth = Smooth.Median3(gray, width, height);
        var histogram = new long[256];
        foreach (var v in smooth) histogram[v]++;
        long total = smooth.Length, sumAll = 0;
        for (var v = 0; v < 256; v++) sumAll += v * histogram[v];
        long below = 0, sumBelow = 0, bestBelow = 0, bestSumBelow = 0;
        double best = -1;
        for (var t = 0; t < 255; t++)
        {
            below += histogram[t];
            sumBelow += t * histogram[t];
            var above = total - below;
            if (below == 0 || above == 0) continue;
            var d = sumBelow / (double)below - (sumAll - sumBelow) / (double)above;
            var between = below * (double)above * d * d;
            if (between > best) (best, bestBelow, bestSumBelow) = (between, below, sumBelow);
        }
        if (best < 0) return true; // one shade: a blank page
        var ink = bestSumBelow / (double)bestBelow;
        var paper = (sumAll - bestSumBelow) / (double)(total - bestBelow);
        if (paper - ink < 100 || paper < 150 || bestBelow > total / 2) return false;
        // Between a quarter and three quarters of the way from ink to paper: edges of letters, or a picture's shades.
        int low = (int)Math.Ceiling(ink + (paper - ink) / 4), high = (int)Math.Floor(paper - (paper - ink) / 4);
        long between2 = 0;
        for (var v = Math.Max(0, low); v <= Math.Min(255, high); v++) between2 += histogram[v];
        return between2 <= total * 0.05;
    }

    /// <summary>The RGB pixels as grey, or null when more than a few are coloured (a colour picture isn't a black-and-white scan).</summary>
    private static byte[]? Gray(byte[] rgb, int w, int h)
    {
        var n = (long)w * h;
        var gray = new byte[n];
        long colored = 0;
        for (long i = 0; i < n; i++)
        {
            int r = rgb[3 * i], g = rgb[3 * i + 1], b = rgb[3 * i + 2];
            if (Math.Max(r, Math.Max(g, b)) - Math.Min(r, Math.Min(g, b)) > 48) colored++;
            gray[i] = (byte)((r * 299 + g * 587 + b * 114 + 500) / 1000);
        }
        return colored > n / 200 ? null : gray;
    }

    /// <summary>
    /// The picture's samples as a <see cref="BitImage"/> (a 0 sample black, a set bit), drawn by MuPDF through the
    /// picture's own filters as plain 1-bit grey; <paramref name="data"/> in place of its stream when given.
    /// </summary>
    private static BitImage? Samples(PdfDictionary image, int w, int h, Func<string, byte[], int, int, byte[]?> draw, byte[]? data = null)
    {
        var dict = $"/Type /XObject /Subtype /Image /Width {w} /Height {h} /BitsPerComponent 1 /ColorSpace /DeviceGray";
        foreach (var key in new[] { "/Filter", "/DecodeParms" })
        {
            if (image.Elements[key] is not { } v) continue;
            if (Optimizer.Plain(v, 0) is not { } text) return null;
            dict += $" {key} {text}";
        }
        if (draw(dict, data ?? image.Stream!.Value, w, h) is not { } rgb || rgb.Length < (long)w * h * 3) return null;
        var gray = new byte[(long)w * h];
        for (long i = 0; i < gray.Length; i++) gray[i] = rgb[3 * i + 1];
        return BitImage.FromGray(gray, w, h, 128);
    }

    /// <summary>A colour space of one component a pixel: DeviceGray, CalGray, ICC-based with /N 1, Indexed or Separation.</summary>
    internal static bool OneComponent(PdfItem? item) => PdfObj.Resolve(item) switch
    {
        PdfName n => n.Value is "/DeviceGray" or "/G",
        PdfArray a when a.Elements.Count > 0 && PdfObj.Name(a.Elements[0]) is { } family => family switch
        {
            "CalGray" or "Indexed" or "I" or "Separation" => true,
            "ICCBased" => a.Elements.Count > 1 && PdfObj.Dict(a.Elements[1]) is { } icc && PdfObj.Int(icc.Elements["/N"]) == 1,
            _ => false,
        },
        _ => false,
    };

    private static List<string>? Filters(PdfDictionary d) => PdfObj.Resolve(d.Elements["/Filter"]) switch
    {
        null => [],
        PdfName n => [n.Value.TrimStart('/')],
        PdfArray a when a.Elements.All(e => PdfObj.Resolve(e) is PdfName) => [.. a.Elements.Select(e => PdfObj.Name(e)!)],
        _ => null,
    };
}
