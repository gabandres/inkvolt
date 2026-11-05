using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// In a check process: the masks of a page's pictures (an image's /SMask, and a /Mask that is a picture of its own),
/// which MuPDF draws but its structured text doesn't list, so the check can't reach them through MuPDF's own view. The
/// document is read through PDFsharp for this alone, and only to decode more: each mask of more than the check's size
/// is handed to MuPDF on a page of its own and decoded at its full size there; what PDFsharp doesn't find is still
/// drawn in the check as before. Read once a document, when a page with pictures is first checked; a document of over
/// <see cref="MaxBytes"/>, or one PDFsharp can't read, has none found.
/// </summary>
internal sealed class PageMasks
{
    /// <summary>The largest document read for its masks (PDFsharp holds all of it, in a process of 2 GB).</summary>
    public const long MaxBytes = 64L << 20;

    /// <summary>Objects looked at for one page at most (a page whose comments reach every other page, say).</summary>
    private const int MaxObjects = 20_000;

    private readonly PdfDocument? _doc;

    private PageMasks(PdfDocument? doc) => _doc = doc;

    /// <summary>The document's masks, from its bytes (null: too large, or none to be had).</summary>
    public static PageMasks Read(byte[]? bytes, int pages)
    {
        if (bytes is null || bytes.Length > MaxBytes) return new PageMasks(null);
        try
        {
            var doc = PdfObj.Read(new MemoryStream(bytes, writable: false), null, PdfDocumentOpenMode.Import);
            return new PageMasks(doc.PageCount == pages ? doc : null);
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            return new PageMasks(null);
        }
    }

    /// <summary>
    /// Each mask on <paramref name="page"/> of more than <paramref name="abovePixels"/>, as a one-picture PDF for MuPDF
    /// to decode (<see cref="Optimizer.OneImagePage"/>): the mask's own stored bytes and filters.
    /// </summary>
    public IEnumerable<(byte[] Pdf, long Pixels)> Large(int page, long abovePixels)
    {
        if (_doc is null || page < 0 || page >= _doc.PageCount) yield break;
        var seen = new HashSet<PdfObject>(ReferenceEqualityComparer.Instance);
        var masks = new List<PdfDictionary>();
        var left = new Stack<PdfItem>();
        PdfDictionary pageDict = _doc.Pages[page];
        left.Push(pageDict);
        // Resources the page inherits from the page tree (the walk doesn't go up through /Parent).
        var parent = PdfObj.Dict(pageDict.Elements["/Parent"]);
        for (var up = 0; parent is not null && up < 64; up++, parent = PdfObj.Dict(parent.Elements["/Parent"]))
            if (parent.Elements["/Resources"] is { } inherited) left.Push(inherited);
        while (left.Count > 0 && seen.Count < MaxObjects)
        {
            switch (PdfObj.Resolve(left.Pop()))
            {
                case PdfArray a when seen.Add(a):
                    foreach (var e in a.Elements) left.Push(e);
                    break;
                case PdfDictionary d when seen.Add(d):
                    if (seen.Count > 1 && PdfObj.NameOf(d, "/Type") is "/Page" or "/Pages") break; // another page, the tree
                    if (PdfObj.NameOf(d, "/Subtype") == "/Image" || d.Elements.ContainsKey("/Width"))
                        foreach (var key in new[] { "/SMask", "/Mask" })
                            if (PdfObj.Dict(d.Elements[key]) is { Stream: not null } mask) masks.Add(mask);
                    foreach (var key in d.Elements.Keys)
                        if (key != "/Parent" && key != "/P") left.Push(d.Elements[key]!);
                    break;
            }
        }
        foreach (var mask in masks.Distinct(ReferenceEqualityComparer.Instance).Cast<PdfDictionary>())
        {
            long w = PdfObj.Int(mask.Elements["/Width"]) ?? 0, h = PdfObj.Int(mask.Elements["/Height"]) ?? 0;
            if (w <= 0 || h <= 0 || w * h <= abovePixels || Picture(mask, w, h) is not { } dict) continue;
            yield return (Optimizer.OneImagePage(dict, mask.Stream!.Value, 1, 1), w * h);
        }
    }

    /// <summary>The mask's dictionary as a picture of its own: gray, or a stencil; null when a value can't be written out.</summary>
    private static string? Picture(PdfDictionary mask, long w, long h)
    {
        var stencil = PdfObj.Resolve(mask.Elements["/ImageMask"]) is PdfBoolean { Value: true };
        var bits = stencil ? 1 : PdfObj.Int(mask.Elements["/BitsPerComponent"]) ?? 8;
        var sb = new StringBuilder($"/Type /XObject /Subtype /Image /Width {w} /Height {h} /BitsPerComponent {bits}");
        sb.Append(stencil ? " /ImageMask true" : " /ColorSpace /DeviceGray");
        foreach (var key in new[] { "/Filter", "/DecodeParms", "/Decode" })
        {
            if (mask.Elements[key] is not { } v) continue;
            if (Optimizer.Plain(v, 0) is not { } text) return null;
            sb.Append($" {key} {text}");
        }
        return sb.ToString();
    }
}
