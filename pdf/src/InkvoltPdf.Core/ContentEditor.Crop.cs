using System.Text;
using MuPDFCore;
using PdfSharp.Pdf;

namespace InkvoltPdf.Core;

/// <summary>
/// Crop Picture (Edit Text &amp; Images, roadmap 2.1): a picture cut down to part of itself for real. The part kept is
/// drawn by MuPDF from the picture as the page has it (any filter, color space, decode array or mask), at the picture's
/// own pixels, and stored as a new picture (Flate, RGB, with a soft mask when it had one) placed where that part was; the
/// old picture leaves the page, so the pixels cut off are no longer in the file (a signed file's earlier revision keeps
/// them, as any removal there).
/// </summary>
public static partial class ContentEditor
{
    /// <summary>The most pixels a crop writes (the part kept): a hostile picture's size is bounded before it is drawn.</summary>
    private const long MaxCropPixels = 50_000_000;

    /// <summary>
    /// Crops a picture to <paramref name="crop"/> (page space; held to the whole picture, and out to whole pixels of it):
    /// the part kept becomes the picture and the rest is gone from the file. Upright pictures and quarter turns only; a
    /// stencil (one color painted through the picture) or a picture masked by color isn't cropped.
    /// </summary>
    /// <exception cref="ContentEditException">The crop can't be made (why, as a sentence).</exception>
    public static byte[] CropImage(byte[] data, string? password, PageImage image, RectD crop)
    {
        if (image.Turned) throw new ContentEditException(PdfStrings.Edit_CropTurned);
        if (!double.IsFinite(crop.X + crop.Y + crop.Width + crop.Height)) throw new ContentEditException(PdfStrings.Edit_PictureTooSmall);
        return EditImage(data, password, image, (doc, page, found, op, ctm, ops, content) =>
        {
            var whole = found.Uncropped ?? found.Box;
            var c = crop.Intersect(whole);
            if (c.Width < 1 || c.Height < 1) throw new ContentEditException(PdfStrings.Edit_PictureTooSmall);
            var toUnit = PageToUser(page).Times(ctm.Invert() ?? throw new ContentEditException(PdfStrings.Edit_PictureSquashed));
            var (ax, ay) = toUnit.Apply(c.X, c.Y);
            var (bx, by) = toUnit.Apply(c.Right, c.Bottom);
            double x0 = Math.Clamp(Math.Min(ax, bx), 0, 1), x1 = Math.Clamp(Math.Max(ax, bx), 0, 1);
            double y0 = Math.Clamp(Math.Min(ay, by), 0, 1), y1 = Math.Clamp(Math.Max(ay, by), 0, 1);
            var at = ops.IndexOf(op);
            var source = CropSource(page, op) ?? throw new ContentEditException(PdfStrings.Edit_CropFailed);
            // Out to whole pixels: image space has its first row at the top (y = 1).
            var (w, h) = (source.Width, source.Height);
            int cx0 = (int)Math.Floor(x0 * w + 1e-6), cx1 = (int)Math.Ceiling(x1 * w - 1e-6);
            int ry0 = (int)Math.Floor((1 - y1) * h + 1e-6), ry1 = (int)Math.Ceiling((1 - y0) * h - 1e-6);
            (cx0, cx1, ry0, ry1) = (Math.Clamp(cx0, 0, w), Math.Clamp(cx1, 0, w), Math.Clamp(ry0, 0, h), Math.Clamp(ry1, 0, h));
            int cw = cx1 - cx0, ch = ry1 - ry0;
            if (cw < 1 || ch < 1) throw new ContentEditException(PdfStrings.Edit_PictureTooSmall);
            var placed = Placed(ops, at);
            if (cw == w && ch == h)
            {
                // All of it: only a clip of the picture's own (inside its q … Q) goes; one drawn outside such a group
                // clips what follows it too, so it stays.
                return placed is { Clip: >= 0 } p0 ? [(ops[p0.Clip].Start, ops[p0.Clip + 2].End, "")] : [];
            }
            if (source.Stencil) throw new ContentEditException(PdfStrings.Edit_CropStencil);
            if (source.OddTransparency) throw new ContentEditException(PdfStrings.Edit_CropTransparency);
            // MuPDF decodes the whole picture to draw a part of it: the picture's own size is bounded too.
            if ((long)cw * ch > MaxCropPixels || (long)w * h > PdfEngine.MaxPixels) throw new ContentEditException(PdfStrings.Edit_CropTooLarge);
            var (rgb, alpha) = RenderCrop(data, password, found.PageIndex, source, Slice(op, content), cx0, ry0, cw, ch);
            var picture = ImageImport.ImageStream(doc, cw, ch, rgb, "/DeviceRGB");
            if (alpha is not null) picture.Elements["/SMask"] = ImageImport.ImageStream(doc, cw, ch, alpha, "/DeviceGray").Reference!;
            if (source.Interpolate) picture.Elements["/Interpolate"] = new PdfBoolean(true);
            // What else the picture said of itself: the layer it is in, its rendering intent, its alternate text.
            if (source.Dict is { } old)
                foreach (var key in new[] { "/OC", "/Intent", "/Alt" }) // not /Alternates: those are the whole picture again
                    if (old.Elements[key] is { } v) picture.Elements[key] = v;
            var name = AddXObject(doc, page, picture);
            // The new picture's unit square onto the part of the old one's it shows.
            var s = new Mat((double)cw / w, 0, 0, (double)ch / h, (double)cx0 / w, (double)(h - ry1) / h);
            SignedEdits.NoteRemoval();
            if (placed is { } pl)
            {
                var cm = pl.Cm >= 0 ? ops[pl.Cm] : null;
                var m = cm is null ? s : s.Times(new Mat(cm.N(0), cm.N(1), cm.N(2), cm.N(3), cm.N(4), cm.N(5)));
                return [(ops[pl.Q].Start, ops[pl.End].End, $"q {m.Write()} cm /{name} Do Q")];
            }
            // Drawn without a q … Q of its own: only the drawing is replaced; a clip before it (which may clip what follows
            // too) stays.
            return [(op.Start, op.End, $"q {s.Write()} cm /{name} Do Q")];
        }, dropName: true);
    }

    /// <summary>
    /// What a crop needs of a picture: its pixel size (1 to 65,535 each way), its resource name (null: an inline image),
    /// its masks' names in the copy it is drawn from, whether it is a stencil or masked by color, or keeps its transparency
    /// where a crop can't (inside JPEG 2000 data, /SMaskInData; colors blended with a matte color, a soft mask's /Matte).
    /// Null when it can't be read.
    /// </summary>
    private sealed record CropPicture(int Width, int Height, string? Name, bool Stencil, bool SoftMask, bool MaskImage, bool Interpolate)
    {
        public bool OddTransparency { get; init; }
        /// <summary>The image XObject (null: an inline image).</summary>
        public PdfDictionary? Dict { get; init; }
    }

    private static CropPicture? CropSource(PdfPage page, COp op)
    {
        static bool Size(double w, double h) => w is >= 1 and <= 65535 && h is >= 1 and <= 65535 && w == Math.Floor(w) && h == Math.Floor(h);
        if (op.Name == "BI")
        {
            if (op.Operands.Count == 0 || op.Operands[0].Kind != CKind.Dict) return null;
            var d = op.Operands[0];
            var w = (d["W"] ?? d["Width"]) is { Kind: CKind.Number } wn ? wn.Num : 0;
            var h = (d["H"] ?? d["Height"]) is { Kind: CKind.Number } hn ? hn.Num : 0;
            if (!Size(w, h)) return null;
            var stencil = (d["IM"] ?? d["ImageMask"]) is { Kind: CKind.Bool, Name: "true" };
            var interpolate = (d["I"] ?? d["Interpolate"]) is { Kind: CKind.Bool, Name: "true" };
            return new CropPicture((int)w, (int)h, null, stencil, false, false, interpolate);
        }
        var image = PdfObj.Dict(PdfObj.Dict(PdfObj.Dict(page.Elements["/Resources"])?.Elements["/XObject"])?.Elements["/" + op.Operands[0].Name]);
        if (image is null) return null;
        double iw = PdfObj.Num(image.Elements["/Width"]), ih = PdfObj.Num(image.Elements["/Height"]);
        if (!Size(iw, ih)) return null;
        var mask = PdfObj.Resolve(image.Elements["/Mask"]);
        var smask = PdfObj.Dict(image.Elements["/SMask"]);
        var odd = PdfObj.Num(image.Elements["/SMaskInData"]) != 0 || smask?.Elements["/Matte"] is not null;
        return new CropPicture((int)iw, (int)ih, op.Operands[0].Name,
            PdfObj.Resolve(image.Elements["/ImageMask"]) is PdfBoolean { Value: true } || mask is PdfArray, // a color key: stencil-like, not kept
            smask is not null, PdfObj.Dict(mask) is not null,
            PdfObj.Resolve(image.Elements["/Interpolate"]) is PdfBoolean { Value: true }) { OddTransparency = odd, Dict = image };
    }

    /// <summary>
    /// The part kept, drawn by MuPDF from a copy of the document whose page shows only it, pixel for pixel: its colors
    /// (on their own, masks taken off) as RGB, and its mask (a soft mask's gray, a stencil mask's coverage) as alpha.
    /// </summary>
    private static (byte[] Rgb, byte[]? Alpha) RenderCrop(byte[] data, string? password, int pageIndex, CropPicture source, string drawn,
        int cx0, int ry0, int cw, int ch)
    {
        // The picture's unit square on a cw x ch page, its part (cx0, ry0) at the page's top left (PDF space: y up).
        var place = $"{source.Width} 0 0 {source.Height} {-cx0} {-(source.Height - ry0 - ch)} cm";
        var colors = Draw($"q {place} {drawn} Q", null, false);
        byte[]? alpha = null;
        if (source.SoftMask || source.MaskImage)
        {
            var gray = Draw($"q {place} /InkCropMask Do Q", source.SoftMask ? "/SMask" : "/Mask", true);
            alpha = new byte[cw * ch];
            // A soft mask's gray is its alpha; a stencil mask paints black where the picture shows.
            for (var i = 0; i < alpha.Length; i++) alpha[i] = source.SoftMask ? gray[3 * i] : (byte)(255 - gray[3 * i]);
        }
        return (colors, alpha);

        byte[] Draw(string content, string? maskKey, bool mask)
        {
            try
            {
                byte[] pdf;
                using (var copy = PdfObj.Open(data, password, PdfSharp.Pdf.IO.PdfDocumentOpenMode.Modify, PdfStrings.Doc_CantEdit))
                {
                    var page = PageOf(copy, pageIndex);
                    foreach (var key in new[] { "/CropBox", "/BleedBox", "/TrimBox", "/ArtBox", "/Rotate", "/Annots", "/UserUnit", "/Group" })
                        page.Elements.Remove(key);
                    page.Elements["/MediaBox"] = new PdfArray(copy, new PdfInteger(0), new PdfInteger(0), new PdfInteger(cw), new PdfInteger(ch));
                    var res = PdfObj.Dict(page.Elements["/Resources"]);
                    var xo = PdfObj.Dict(res?.Elements["/XObject"]);
                    if (source.Name is { } name && PdfObj.Dict(xo?.Elements["/" + name]) is { } image)
                    {
                        if (mask && maskKey is not null && image.Elements[maskKey] is { } m)
                        {
                            // The mask drawn on its own, as the picture: under a name of its own in a copy of the resources.
                            var xo2 = new PdfDictionary(copy);
                            foreach (var k in xo!.Elements.Keys) xo2.Elements[k] = xo.Elements[k];
                            xo2.Elements["/InkCropMask"] = m;
                            var res2 = res!.Clone();
                            res2.Elements["/XObject"] = xo2;
                            page.Elements["/Resources"] = res2;
                        }
                        else
                        {
                            // Its colors on their own: its masks off (in this copy only).
                            image.Elements.Remove("/SMask");
                            image.Elements.Remove("/Mask");
                        }
                    }
                    page.Elements["/Contents"] = PdfObj.AddStream(copy, Encoding.Latin1.GetBytes(content)).Reference!;
                    using var ms = new MemoryStream();
                    copy.Save(ms, false);
                    pdf = ms.ToArray();
                }
                using var engine = PdfEngine.Open(pdf, InputFileTypes.PDF, password);
                var img = engine.Render(pageIndex, 1, annotations: false);
                // MuPDF's pixels are BGR; the page is cw x ch points, so as many pixels (a pixel short at an edge is white).
                var rgb = new byte[cw * ch * 3];
                Array.Fill(rgb, (byte)255);
                for (var y = 0; y < Math.Min(ch, img.Height); y++)
                    for (var x = 0; x < Math.Min(cw, img.Width); x++)
                    {
                        var from = y * img.Stride + 3 * x;
                        var to = 3 * (y * cw + x);
                        rgb[to] = img.Pixels[from + 2];
                        rgb[to + 1] = img.Pixels[from + 1];
                        rgb[to + 2] = img.Pixels[from];
                    }
                return rgb;
            }
            catch (Exception ex) when (ex is InvalidOperationException or MuPDFException or ArgumentException)
            {
                throw new ContentEditException(PdfStrings.Edit_CropFailed);
            }
        }
    }
}
