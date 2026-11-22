using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;

namespace InkvoltPdf.Core;

/// <summary>How Resize Pages fits a page's content on its new paper.</summary>
public enum ResizeFit
{
    /// <summary>Scaled up or down to fill the new size as far as it can without being cut, centred.</summary>
    Scale,
    /// <summary>Kept at its size and centred, the rest of the paper left as margins; shrunk only when it wouldn't fit.</summary>
    Margins,
}

/// <summary>
/// Resize Pages: each page on paper of one size (Letter, A4, a size typed), its content scaled to fit or centred with
/// margins added. A page keeps the way it is turned: a page that shows landscape gets the paper sideways. The visible
/// area becomes the page; what lay outside it (a crop) is clipped, and comments and fields move and scale with the content.
/// </summary>
public static partial class PageEditor
{
    /// <summary>The smallest and largest paper side accepted, in points (1 inch; 200 inches, PDF's own limit).</summary>
    public const double MinPaper = 72, MaxPaper = 14_400;

    /// <param name="width">The paper's width in points, upright (the shorter side for portrait paper).</param>
    /// <param name="height">The paper's height in points.</param>
    /// <exception cref="ArgumentOutOfRangeException">A side isn't a number between <see cref="MinPaper"/> and <see cref="MaxPaper"/>.</exception>
    public static byte[] Resize(byte[] data, string? password, IReadOnlyCollection<int> pages, double width, double height, ResizeFit fit)
    {
        if (!double.IsFinite(width) || !double.IsFinite(height) || width < MinPaper || height < MinPaper || width > MaxPaper || height > MaxPaper)
            throw new ArgumentOutOfRangeException(nameof(width), Loc.Format(PdfStrings.Page_ResizeSize, MinPaper / 72, MaxPaper / 72));
        return Edit(data, password, doc =>
        {
            var moved = new Dictionary<PdfObjectID, (double S, double E, double F)>();
            foreach (var i in pages.Distinct())
            {
                if (i < 0 || i >= doc.PageCount) continue;
                // A size no page can have (±1e308 makes the scale nothing and the place NaN, or PDFsharp's own sums NaN):
                // refused, nothing resized.
                PdfPage page;
                try
                {
                    page = doc.Pages[i];
                }
                catch (ArithmeticException)
                {
                    throw new InvalidOperationException(Loc.Format(PdfStrings.Page_ResizeBadBox, i + 1));
                }
                if (!IsUsableBox(PdfObj.VisibleBox(page))) throw new InvalidOperationException(Loc.Format(PdfStrings.Page_ResizeBadBox, i + 1));
                if (ResizePage(doc, page, width, height, fit) is { } t)
                    moved[page.ReferenceNotNull.ObjectID] = t;
            }
            if (moved.Count > 0)
                ForEachDestination(doc, (dest, page) =>
                {
                    if (moved.TryGetValue(page, out var t)) MoveDestination(dest, t.S, t.E, t.F);
                });
        });
    }

    /// <summary>
    /// A destination on a resized page, its place moved as the content was: /XYZ's left and top, /FitH's and /FitBH's top,
    /// /FitV's and /FitBV's left, /FitR's rectangle (a null stays null: "as it was"). /XYZ's zoom stays.
    /// </summary>
    internal static void MoveDestination(PdfArray dest, double s, double e, double f)
    {
        void Set(int i, double scale, double offset)
        {
            if (i >= dest.Elements.Count) return;
            var v = PdfObj.Resolve(dest.Elements[i]);
            if (v is PdfInteger or PdfReal or PdfLongInteger && double.IsFinite(PdfObj.Num(v))) dest.Elements[i] = new PdfReal(PdfObj.Num(v) * scale + offset);
        }
        switch (PdfObj.Name(dest.Elements[1]))
        {
            case "XYZ":
                Set(2, s, e);
                Set(3, s, f);
                break;
            case "FitH" or "FitBH":
                Set(2, s, f);
                break;
            case "FitV" or "FitBV":
                Set(2, s, e);
                break;
            case "FitR":
                Set(2, s, e);
                Set(3, s, f);
                Set(4, s, e);
                Set(5, s, f);
                break;
        }
    }

    /// <summary>The farthest a page box's corner is taken to be from the origin (points): about 140 miles, far past any paper.</summary>
    internal const double MaxBoxCoordinate = 10_000_000;

    /// <summary>A page box Resize Pages can work from: its corners numbers within <see cref="MaxBoxCoordinate"/>.</summary>
    internal static bool IsUsableBox((double X1, double Y1, double X2, double Y2) box) =>
        new[] { box.X1, box.Y1, box.X2, box.Y2 }.All(v => double.IsFinite(v) && Math.Abs(v) <= MaxBoxCoordinate);

    /// <summary>The transform that puts the page's visible box on the new paper: scale s, then move by (e, f); null when it is already so.</summary>
    internal static (double S, double E, double F, double W, double H)? ResizeTransform((double X1, double Y1, double X2, double Y2) box, int rotate, double width, double height, ResizeFit fit)
    {
        double w = box.X2 - box.X1, h = box.Y2 - box.Y1;
        if (!(w >= 1 && h >= 1) || !IsUsableBox(box)) return null;
        var sideways = ((rotate % 360) + 360) % 360 is 90 or 270;
        var (shownW, shownH) = sideways ? (h, w) : (w, h);
        double small = Math.Min(width, height), large = Math.Max(width, height);
        var (paperW, paperH) = shownW > shownH ? (large, small) : (small, large); // as the page shows
        var (tw, th) = sideways ? (paperH, paperW) : (paperW, paperH); // in the page's own (unturned) space
        var s = Math.Min(tw / w, th / h);
        if (fit == ResizeFit.Margins) s = Math.Min(1, s);
        double e = (tw - w * s) / 2 - box.X1 * s, f = (th - h * s) / 2 - box.Y1 * s;
        if (Math.Abs(s - 1) < 1e-6 && Math.Abs(e) < 0.01 && Math.Abs(f) < 0.01 && Math.Abs(w - tw) < 0.01 && Math.Abs(h - th) < 0.01) return null;
        return (s, e, f, tw, th);
    }

    /// <returns>How its content was scaled and moved, or null when the page was left as it was.</returns>
    private static (double S, double E, double F)? ResizePage(PdfDocument doc, PdfPage page, double width, double height, ResizeFit fit)
    {
        var box = PdfObj.VisibleBox(page);
        if (ResizeTransform(box, page.Rotate, width, height, fit) is not { } t) return null;
        var (s, e, f, tw, th) = t;

        // The content, scaled and moved, clipped to what showed before.
        var F = PdfObj.F;
        var contents = new PdfArray(doc);
        contents.Elements.Add(PdfObj.AddStream(doc, Encoding.ASCII.GetBytes(
            $"q {F(s)} 0 0 {F(s)} {F(e)} {F(f)} cm {F(box.X1)} {F(box.Y1)} {F(box.X2 - box.X1)} {F(box.Y2 - box.Y1)} re W n\n")).Reference!);
        var existing = page.Elements["/Contents"];
        if (PdfObj.Array(existing) is { } arr) foreach (var c in arr.Elements) contents.Elements.Add(c);
        else if (existing is PdfReference) contents.Elements.Add(existing);
        contents.Elements.Add(PdfObj.AddStream(doc, "\nQ\n"u8.ToArray()).Reference!);
        page.Elements["/Contents"] = contents;

        (double, double) Map(double x, double y) => (x * s + e, y * s + f);
        page.Elements["/MediaBox"] = PdfObj.Reals(doc, 0, 0, tw, th);
        page.Elements.Remove("/CropBox");
        foreach (var key in new[] { "/TrimBox", "/BleedBox", "/ArtBox" })
        {
            if (PdfObj.Array(page.Elements[key]) is not { Elements.Count: 4 } b) continue;
            var (ax, ay) = Map(PdfObj.Num(b, 0), PdfObj.Num(b, 1));
            var (bx, by) = Map(PdfObj.Num(b, 2), PdfObj.Num(b, 3));
            double x1 = Math.Max(0, Math.Min(ax, bx)), y1 = Math.Max(0, Math.Min(ay, by)), x2 = Math.Min(tw, Math.Max(ax, bx)), y2 = Math.Min(th, Math.Max(ay, by));
            if (x2 - x1 < 1 || y2 - y1 < 1) page.Elements.Remove(key);
            else page.Elements[key] = PdfObj.Reals(doc, x1, y1, x2, y2);
        }

        // Comments, links and fields: where they are and the points they are drawn through. An appearance fills its
        // /Rect, so it scales with it.
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        foreach (var item in PdfObj.Array(page.Elements["/Annots"])?.Elements ?? Enumerable.Empty<PdfItem>())
        {
            if (PdfObj.Dict(item) is not { } annot || !seen.Add(annot)) continue;
            MovePoints(annot, "/Rect");
            MovePoints(annot, "/QuadPoints");
            MovePoints(annot, "/Vertices");
            MovePoints(annot, "/L");
            MovePoints(annot, "/CL");
            if (PdfObj.Array(annot.Elements["/InkList"]) is { } ink)
                foreach (var path in ink.Elements) if (PdfObj.Array(path) is { } p) MoveArray(p);
            if (PdfObj.Array(annot.Elements["/RD"]) is { Elements.Count: 4 } rd)
                annot.Elements["/RD"] = PdfObj.Reals(doc, [.. Enumerable.Range(0, 4).Select(k => PdfObj.Num(rd, k) * s)]);
            if (PdfObj.Dict(annot.Elements["/Popup"]) is { } popup && seen.Add(popup)) MovePoints(popup, "/Rect");
        }
        return (s, e, f);

        void MovePoints(PdfDictionary d, string key)
        {
            if (PdfObj.Array(d.Elements[key]) is { } a) MoveArray(a);
        }
        void MoveArray(PdfArray a)
        {
            var values = new double[a.Elements.Count & ~1];
            for (var k = 0; k < values.Length; k += 2) (values[k], values[k + 1]) = Map(PdfObj.Num(a, k), PdfObj.Num(a, k + 1));
            if (!values.All(double.IsFinite)) return; // a point no page has (±1e308): left as it was, never written as NaN
            a.Elements.Clear();
            foreach (var v in values) a.Elements.Add(new PdfReal(v));
        }
    }
}
