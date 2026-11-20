using System.Text;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>A redacted document (<see cref="Redaction.ApplyWithText"/>). <paramref name="TextSkipped"/>: its redacted pages were left without text (the reading was cancelled).</summary>
public sealed record RedactedData(byte[] Data, bool TextSkipped)
{
    /// <summary>What is black on each redacted page (<see cref="RedactedPages.Blacked"/>).</summary>
    public IReadOnlyDictionary<int, IReadOnlyList<RectD>> Blacked { get; init; } = new Dictionary<int, IReadOnlyList<RectD>>();

    /// <summary>The words the redaction moved (<see cref="RedactedPages.Moved"/>).</summary>
    public RedactionMoves Moved { get; init; } = RedactionMoves.None;
}

/// <summary>A redacted document (<see cref="Redaction.Redact"/>) and what is black on each redacted page, page space: the
/// boxes where the lines laid out again put them, and the rest of each area as it was drawn.</summary>
public sealed record RedactedPages(byte[] Data, IReadOnlyDictionary<int, IReadOnlyList<RectD>> Blacked)
{
    /// <summary>The words kept on lines laid out again, and where they went.</summary>
    public RedactionMoves Moved { get; init; } = RedactionMoves.None;
}

/// <summary>Words a redaction moved along their lines (<see cref="RedactionLines"/>): where each was (page space) and how far it went.</summary>
public sealed class RedactionMoves(IReadOnlyDictionary<int, IReadOnlyList<(RectD Was, double Dx)>> moves)
{
    public static RedactionMoves None { get; } = new(new Dictionary<int, IReadOnlyList<(RectD, double)>>());

    public bool IsEmpty => moves.Count == 0;

    /// <summary>Where a box of text that was kept on <paramref name="page"/> is now (as it was, when its word didn't move).</summary>
    public RectD Now(int page, RectD box)
    {
        if (!moves.TryGetValue(page, out var list)) return box;
        foreach (var (was, dx) in list)
            if (was.Contains(box.CenterX, box.CenterY)) return box with { X = box.X + dx };
        return box;
    }
}

/// <summary>
/// True redaction: every page with areas to redact is rendered (with its annotations and form fields) to a bitmap,
/// the areas are painted solid black in the pixels, and the page's content is replaced by that image. Nothing from the
/// original page (text, vector art, images, annotations, form widgets, thumbnails, alternate text in the structure
/// tree) survives, so the redacted content can't be recovered or copied. Redacted pages become images: their text is
/// no longer selectable or searchable until it is recognized again (<see cref="ApplyWithText"/>). A form field an area touches is emptied on every page (its value would otherwise
/// survive in its other widgets). Tagged PDFs lose the redacted page's part of the structure tree. Other pages and the
/// document metadata are left untouched.
/// </summary>
public static class Redaction
{
    /// <param name="areasByPage">Areas to black out per page index, in page space (points, displayed page's top-left).</param>
    /// <param name="dpi">Resolution of the replacement page images.</param>
    public static byte[] Apply(byte[] data, string? password, IReadOnlyDictionary<int, IReadOnlyList<RectD>> areasByPage, double dpi = 300) =>
        Redact(data, password, areasByPage, dpi).Data;

    /// <summary>
    /// <see cref="Apply"/>, with what is black afterwards. A line an area cuts, with some of its own text left beside the
    /// box, is laid out again (<see cref="RedactionLines"/>): its words keep their order and letters but not their places,
    /// and its box takes a width rounded to whole steps, so neither the box nor the text around it gives the removed width
    /// away. The boxes then sit where the layout put them, not where the areas were: <see cref="RedactedPages.Blacked"/>
    /// says where (what the redaction check and the text laid back are told).
    /// </summary>
    public static RedactedPages Redact(byte[] data, string? password, IReadOnlyDictionary<int, IReadOnlyList<RectD>> areasByPage, double dpi = 300)
    {
        var pages = areasByPage.Where(kv => kv.Value.Any(r => !r.IsEmpty)).ToList();
        var blackedByPage = new Dictionary<int, IReadOnlyList<RectD>>();
        var movedByPage = new Dictionary<int, IReadOnlyList<(RectD, double)>>();
        if (pages.Count == 0) return new RedactedPages(data, blackedByPage);
        dpi = Math.Clamp(dpi, 36, 1200);
        data = ClearRedactedFields(data, password, pages);

        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, PdfStrings.Redact_CantEdit);
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, password);
        foreach (var (index, areas) in pages)
        {
            if (index < 0 || index >= doc.PageCount) throw new ArgumentOutOfRangeException(nameof(areasByPage), Loc.Format(PdfStrings.Redact_NoPage, index + 1));
            var scale = dpi / 72;
            var img = engine.Render(index, scale);
            var rgb = new byte[img.Width * img.Height * 3];
            for (var i = 0; i < rgb.Length; i += 3)
            {
                rgb[i] = img.Pixels[i + 2];
                rgb[i + 1] = img.Pixels[i + 1];
                rgb[i + 2] = img.Pixels[i];
            }
            var drawn = areas.Where(r => !r.IsEmpty).ToList();
            foreach (var a in drawn)
            {
                var x0 = Math.Clamp((int)Math.Floor(a.X * scale), 0, img.Width);
                var x1 = Math.Clamp((int)Math.Ceiling(a.Right * scale), 0, img.Width);
                var y0 = Math.Clamp((int)Math.Floor(a.Y * scale), 0, img.Height);
                var y1 = Math.Clamp((int)Math.Ceiling(a.Bottom * scale), 0, img.Height);
                for (var y = y0; y < y1; y++) Array.Clear(rgb, (y * img.Width + x0) * 3, (x1 - x0) * 3);
            }
            var moved = new List<(RectD, double)>();
            var laidOut = new List<RectD>();
            blackedByPage[index] = Relay(engine.GetText(index, cache: false), drawn, rgb, img.Width, img.Height, scale, moved, laidOut);
            if (moved.Count > 0) movedByPage[index] = moved;
            ReplacePage(doc, doc.Pages[index], img.Width, img.Height, rgb, laidOut);
        }
        return new RedactedPages(PdfObj.Save(doc, rewrite: true), blackedByPage) { Moved = new RedactionMoves(movedByPage) };
    }

    /// <summary>
    /// The lines the areas cut, laid out again in the page image; returns what is black: each line's boxes where they now
    /// are, and of each area what lies outside the rows laid out again. Each word moved goes in <paramref name="moved"/>.
    /// </summary>
    private static List<RectD> Relay(PageText text, List<RectD> areas, byte[] rgb, int width, int height, double scale, List<(RectD Was, double Dx)> moved,
        List<RectD> laidOut)
    {
        var blacked = new List<RectD>();
        var rows = new List<RectD>();
        foreach (var line in RedactionLines.Find(text, areas))
        {
            var placed = RedactionLines.Layout(line, width / scale);
            var (boxes, relaid) = RedactionLines.Relay(rgb, width, height, scale, line, placed);
            blacked.AddRange(boxes);
            laidOut.AddRange(boxes);
            if (relaid.IsEmpty) continue;
            rows.Add(relaid);
            for (var k = 0; k < line.Pieces.Count; k++)
                if (line.Pieces[k] is { Box: false } p && placed[k].X != p.X)
                    moved.Add((RectD.FromEdges(p.X, relaid.Y, p.Right, relaid.Bottom), placed[k].X - p.X));
        }
        foreach (var a in areas)
        {
            // The area less the rows laid out again (their columns): the strips above and below a line, or the whole area.
            var cuts = rows.Where(r => r.Right > a.X && r.X < a.Right && r.Bottom > a.Y && r.Y < a.Bottom).OrderBy(r => r.Y).ToList();
            var y = a.Y;
            foreach (var r in cuts)
            {
                if (r.Y > y) blacked.Add(RectD.FromEdges(a.X, y, a.Right, r.Y));
                y = Math.Max(y, r.Bottom);
            }
            if (a.Bottom > y) blacked.Add(RectD.FromEdges(a.X, y, a.Right, a.Bottom));
        }
        return blacked;
    }

    /// <summary>How the redacted pages are read back into text: cleaned, no suspect words (nobody reviews a redacted page's words), only the text written.</summary>
    public static readonly RecognizeOptions TextBackOptions = new(CheckWords: false);

    /// <summary>
    /// <see cref="Apply"/>, then <see cref="TextBack"/>: Apply Redactions, Redact by Pattern and Batch's Redact Patterns all
    /// redact through these two. Without a recognizer, just Apply.
    /// </summary>
    public static RedactedData ApplyWithText(byte[] data, string? password, IReadOnlyDictionary<int, IReadOnlyList<RectD>> areasByPage,
        ITextRecognizer? ocr, IProgress<(int Done, int Total)>? progress = null, CancellationToken skipText = default)
    {
        var redacted = Redact(data, password, areasByPage);
        var result = ocr is null ? new RedactedData(redacted.Data, false) : TextBack(redacted.Data, password, redacted.Blacked, ocr, progress, skipText);
        return result with { Blacked = redacted.Blacked, Moved = redacted.Moved };
    }

    /// <summary>
    /// The redacted pages of <paramref name="redacted"/>, pictures now, read by <paramref name="ocr"/> and given their text
    /// again as an invisible text layer, so they stay searchable and selectable; what a black box covers isn't kept.
    /// </summary>
    /// <param name="progress">(pages read, pages), before each page.</param>
    /// <param name="skipText">Cancelled: the pages stay without text (<see cref="RedactedData.TextSkipped"/>), the redaction is kept.</param>
    public static RedactedData TextBack(byte[] redacted, string? password, IReadOnlyDictionary<int, IReadOnlyList<RectD>> areasByPage,
        ITextRecognizer ocr, IProgress<(int Done, int Total)>? progress = null, CancellationToken skipText = default)
    {
        try
        {
            var read = new PageRecognizer(ocr, TextBackOptions).Recognize(redacted, password, [.. areasByPage.Keys.Order()], areasByPage, progress, skipText);
            return new RedactedData(read.Write(redacted, password), false);
        }
        catch (OperationCanceledException) when (skipText.IsCancellationRequested)
        {
            return new RedactedData(redacted, true);
        }
    }

    /// <summary>
    /// A form field whose widget an area covers loses its value everywhere: its widgets on other pages would otherwise
    /// keep showing it (and /V would keep it in the file). Done first, so the rendered pages already show the field empty.
    /// </summary>
    private static byte[] ClearRedactedFields(byte[] data, string? password, List<KeyValuePair<int, IReadOnlyList<RectD>>> pages)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, PdfStrings.Redact_CantEdit);
        var hit = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        foreach (var (index, areas) in pages)
        {
            if (index < 0 || index >= doc.PageCount || PdfObj.Array(doc.Pages[index].Elements["/Annots"]) is not { } annots) continue;
            var page = doc.Pages[index];
            foreach (var w in annots.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>())
            {
                if (PdfObj.NameOf(w, "/Subtype") != "/Widget" || PdfObj.Array(w.Elements["/Rect"]) is not { } r) continue;
                var rect = PdfObj.RectToPage(page, r);
                if (areas.Any(a => !a.IsEmpty && !a.Intersect(rect).IsEmpty)) hit.Add(w);
            }
        }
        return hit.Count > 0 && FormEditor.ClearFields(doc, hit) ? PdfObj.Save(doc, rewrite: true) : data;
    }

    /// <summary>Where Inkvolt PDF writes, in a redacted page's picture, the boxes of the lines it laid out again (x y w h, page space).</summary>
    private const string LaidOutKey = "/PdLaidOut";

    /// <summary>Most boxes read back from <see cref="LaidOutKey"/>.</summary>
    private const int MaxLaidOut = 1000;

    /// <summary>The boxes a redacted page's picture says were laid out with their lines (<see cref="RedactionLines"/>): the
    /// redaction check doesn't count the text beside them as giving a width away.</summary>
    internal static IEnumerable<RectD> LaidOutBoxes(PdfDictionary image)
    {
        if (PdfObj.Array(image.Elements[LaidOutKey]) is not { } a) yield break;
        for (var i = 0; i + 3 < Math.Min(a.Elements.Count, 4 * MaxLaidOut); i += 4)
            if (new RectD(PdfObj.Num(a, i), PdfObj.Num(a, i + 1), PdfObj.Num(a, i + 2), PdfObj.Num(a, i + 3)) is { IsEmpty: false } r
                && double.IsFinite(r.X + r.Y + r.Width + r.Height))
                yield return r;
    }

    private static void ReplacePage(PdfDocument doc, PdfPage page, int width, int height, byte[] rgb, List<RectD> laidOut)
    {
        var image = PdfObj.AddStream(doc, rgb);
        image.Elements["/Type"] = new PdfName("/XObject");
        image.Elements["/Subtype"] = new PdfName("/Image");
        image.Elements["/Width"] = new PdfInteger(width);
        image.Elements["/Height"] = new PdfInteger(height);
        image.Elements["/ColorSpace"] = new PdfName("/DeviceRGB");
        image.Elements["/BitsPerComponent"] = new PdfInteger(8);
        if (laidOut.Count > 0)
            image.Elements[LaidOutKey] = new PdfArray(doc, [.. laidOut.Take(MaxLaidOut).SelectMany(r => new[] { r.X, r.Y, r.Width, r.Height }).Select(v => new PdfReal(Math.Round(v, 2)))]);

        // The image is upright as displayed; map its unit square onto the (rotated) crop box.
        var (dw, dh) = PdfObj.DisplaySize(page);
        var o = PdfObj.ToPdf(page, 0, dh);
        var u = PdfObj.ToPdf(page, dw, dh);
        var v = PdfObj.ToPdf(page, 0, 0);
        var ops = $"q {PdfObj.F(u.X - o.X)} {PdfObj.F(u.Y - o.Y)} {PdfObj.F(v.X - o.X)} {PdfObj.F(v.Y - o.Y)} {PdfObj.F(o.X)} {PdfObj.F(o.Y)} cm /PdRedacted Do Q\n";
        var content = PdfObj.AddStream(doc, Encoding.ASCII.GetBytes(ops));
        page.Elements["/Contents"] = content.Reference!;
        var xobjects = new PdfDictionary(doc);
        xobjects.Elements["/PdRedacted"] = image.Reference!;
        var resources = new PdfDictionary(doc);
        resources.Elements["/XObject"] = xobjects;
        page.Elements["/Resources"] = resources;

        var removed = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance);
        var parentKeys = StructTree.ParentKeys(page).ToList();
        if (PdfObj.Array(page.Elements["/Annots"]) is { } annots)
        {
            var acro = PdfObj.Dict(doc.Internals.Catalog.Elements["/AcroForm"]);
            var widgets = false;
            foreach (var a in annots.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().ToList())
            {
                removed.Add(a);
                if (PdfObj.NameOf(a, "/Subtype") != "/Widget") continue;
                RemoveWidget(acro, a, removed);
                widgets = true;
            }
            if (acro is not null)
            {
                // Fields dropped above must not stay reachable through the calculation order (with their /V)...
                if (PdfObj.Array(acro.Elements["/CO"]) is { } co)
                    for (var i = co.Elements.Count - 1; i >= 0; i--)
                        if (PdfObj.Dict(co.Elements[i]) is { } f && removed.Contains(f)) co.Elements.RemoveAt(i);
                // ...and an XFA form keeps its own copy of every value (datasets): once a field went, AcroForm fields are
                // what remains. Comments and links alone leave the form (and its XFA) as it was.
                if (widgets) acro.Elements.Remove("/XFA");
            }
            // Annotations elsewhere pointing at removed ones (a popup's /Parent, a reply's /IRT) would keep them reachable.
            foreach (var other in doc.Pages)
                if (!ReferenceEquals(other, page) && PdfObj.Array(other.Elements["/Annots"]) is { } list)
                    foreach (var a in list.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>())
                        foreach (var key in new[] { "/Parent", "/IRT" })
                            if (PdfObj.Dict(a.Elements[key]) is { } target && removed.Contains(target)) a.Elements.Remove(key);
        }
        // What else a page can carry of its old content: thumbnail image, application data (PieceInfo), separations,
        // article beads, actions, its XMP, and PDF 2.0 associated files (/AF: e.g. the source the page was made from).
        foreach (var key in new[] { "/Annots", "/Thumb", "/PieceInfo", "/StructParents", "/Group", "/B", "/Metadata", "/SeparationInfo", "/AA", "/AF" })
            page.Elements.Remove(key);
        ScrubStructure(doc, page, removed);
        StructTree.Prune(doc, [page], parentKeys, removed.Contains);
    }

    /// <summary>Takes a widget out of the field tree, dropping fields left without widgets.</summary>
    internal static void RemoveWidget(PdfDictionary? acro, PdfDictionary node, HashSet<PdfObject> removed)
    {
        for (var guard = 0; guard < 64; guard++)
        {
            var parent = PdfObj.Dict(node.Elements["/Parent"]);
            var list = parent is null ? PdfObj.Array(acro?.Elements["/Fields"]) : PdfObj.Array(parent.Elements["/Kids"]);
            if (list is null) return;
            for (var i = list.Elements.Count - 1; i >= 0; i--)
                if (ReferenceEquals(PdfObj.Dict(list.Elements[i]), node)) list.Elements.RemoveAt(i);
            if (parent is null || list.Elements.Count > 0) return;
            node = parent;
            removed.Add(node);
        }
    }

    /// <summary>
    /// Drops what the structure tree keeps of the page: alternate/actual text (it can repeat the redacted words), and
    /// references to its annotations (OBJR, which would keep a widget and its value reachable) and to marked-content
    /// streams (MCR /Stm).
    /// </summary>
    private static void ScrubStructure(PdfDocument doc, PdfPage page, HashSet<PdfObject> removed)
    {
        // Each dictionary and array once: a tree can share them (or loop), and walking every path can take forever.
        var seen = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance);
        void Visit(PdfItem? item, bool onPage, int depth)
        {
            if (depth > 128) return;
            switch (PdfObj.Resolve(item))
            {
                case PdfArray arr when seen.Add(arr):
                    foreach (var e in arr.Elements) Visit(e, onPage, depth + 1);
                    break;
                case PdfDictionary d when seen.Add(d):
                    if (d.Elements.ContainsKey("/Pg")) onPage = ReferenceEquals(PdfObj.Resolve(d.Elements["/Pg"]), page);
                    if (onPage)
                        foreach (var key in new[] { "/Alt", "/ActualText", "/E", "/Stm", "/StmOwn" }) d.Elements.Remove(key);
                    if (PdfObj.Dict(d.Elements["/Obj"]) is { } obj && (onPage || removed.Contains(obj)))
                        d.Elements.Remove("/Obj");
                    Visit(d.Elements["/K"], onPage, depth + 1);
                    break;
            }
        }
        Visit(PdfObj.Dict(doc.Internals.Catalog.Elements["/StructTreeRoot"])?.Elements["/K"], false, 0);
    }
}
