using System.Globalization;
using System.Runtime.CompilerServices;
using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPrint.Core.Escl;

/// <summary>Renders each page of a PDF to a JPEG (Windows.Data.Pdf in the app, the engine Print a PDF uses).</summary>
public interface IPdfPageRenderer
{
    /// <summary>Every page of <paramref name="pdf"/>, in order, as a JPEG at <paramref name="dpi"/>.</summary>
    Task<IReadOnlyList<byte[]>> RenderAsync(byte[] pdf, int dpi, CancellationToken ct);
}

/// <summary>Where a scanned page came from when the scanner sent a PDF: that PDF, the page's place in it, and whether it was rendered.</summary>
public sealed record PdfOrigin(byte[] Pdf, int Page, int PageCount, bool Rendered);

/// <summary>A page about to be saved, for <see cref="ScannerPdf.KeepAsSent"/>: where it came from and whether it changed.</summary>
/// <param name="Changed">Turned, cropped, straightened, cut into photos, or given a text layer (OCR).</param>
public readonly record struct PageToSave(PdfOrigin? Origin, bool Changed);

/// <summary>
/// Scanners that send only PDF from a source (print/ROADMAP.md 1.3: some eSCL feeders offer <c>application/pdf</c> and no JPEG).
/// Their pages go to the review, OCR, presets and photos as the JPEG pages every other scanner sends: a page that is one JPEG
/// picture (a scanner's PDF nearly always is) is taken out as it is, byte for byte, so nothing is re-encoded and the page is the
/// one a JPEG scan gives; anything else (a picture in another encoding, a turned page, compressed object streams) is rendered at
/// the scan's resolution by <see cref="Renderer"/>. Each page remembers its PDF (<see cref="OriginOf"/>), so a file saved as PDF
/// with its pages as they came is the scanner's own PDF (<see cref="KeepAsSent"/>).
/// </summary>
public static partial class ScannerPdf
{
    public const string MediaType = "application/pdf";

    /// <summary>Renders the pages that aren't one JPEG picture (set by the app; null in tests and on a PC without it).</summary>
    public static IPdfPageRenderer? Renderer { get; set; }

    private static readonly ConditionalWeakTable<byte[], PdfOrigin> Origins = new();

    /// <summary>The PDF a page handed over by <see cref="PagesAsync"/> came from; null for a page that came as a JPEG.</summary>
    public static PdfOrigin? OriginOf(byte[] page) => Origins.TryGetValue(page, out var origin) ? origin : null;

    /// <summary>The scanner's PDF as JPEG pages (see the class summary).</summary>
    /// <exception cref="ScanException">Not a PDF this PC can read, or no pages.</exception>
    public static async Task<IReadOnlyList<byte[]>> PagesAsync(byte[] pdf, int dpi, CancellationToken ct = default)
    {
        var pages = JpegPages(pdf);
        var rendered = pages is null;
        if (pages is null)
        {
            if (Renderer is null)
                throw new ScanException("This scanner sent its pages as a PDF whose pictures Inkvolt Print can't take out here.");
            try
            {
                pages = await Renderer.RenderAsync(pdf, dpi, ct).ConfigureAwait(false);
            }
            catch (Exception ex) when (ex is not OperationCanceledException and not ScanException)
            {
                throw new ScanException($"The scanner's PDF couldn't be opened: {ex.Message}");
            }
        }
        if (pages.Count == 0) throw new ScanException("The scanner sent a PDF without pages.");
        for (var i = 0; i < pages.Count; i++) Origins.AddOrUpdate(pages[i], new PdfOrigin(pdf, i, pages.Count, rendered));
        return pages;
    }

    /// <summary>
    /// The scanner's own PDF, when the file is exactly it: every page from one PDF, all of them, in order, none changed. Null
    /// otherwise (the file is then made from the pages; a page taken out of the PDF goes back in as the same JPEG).
    /// </summary>
    public static byte[]? KeepAsSent(IReadOnlyList<PageToSave> pages)
    {
        if (pages.Count == 0 || pages[0].Origin is not { } first || first.PageCount != pages.Count) return null;
        for (var i = 0; i < pages.Count; i++)
            if (pages[i] is not { Changed: false, Origin: { } o } || !ReferenceEquals(o.Pdf, first.Pdf) || o.Page != i) return null;
        return first.Pdf;
    }

    /// <summary>Why a file can't be the scanner's own PDF, in words for the status line; null when it is, or none of it came as PDF.</summary>
    public static string? WhyNotAsSent(IReadOnlyList<PageToSave> pages)
    {
        if (pages.All(p => p.Origin is null) || KeepAsSent(pages) is not null) return null;
        return pages.Any(p => p.Changed) ? "Your changes (or the text layer) are in it, so it was made from the scanner's pages, pictures unchanged."
            : "Pages were added, left out, moved or split into files, so it was made from the scanner's pages, pictures unchanged.";
    }

    // ------------------------------------------------------------------------------------------------ taking pictures out

    /// <summary>
    /// Each page's JPEG, taken out as it is, when every page is one DCT-encoded picture (grey or color, no mask, not turned);
    /// null when any isn't, or the file can't be read this simply (then it is rendered).
    /// </summary>
    public static IReadOnlyList<byte[]>? JpegPages(byte[] pdf)
    {
        try
        {
            var doc = new MiniPdf(pdf);
            var pages = doc.Pages();
            if (pages is not { Count: > 0 }) return null;
            var jpegs = new List<byte[]>();
            foreach (var (_, resources, rotate) in pages)
            {
                if (rotate % 360 != 0) return null;
                var images = doc.XObjects(resources).Select(doc.Object).ToList();
                if (images.Count != 1 || images[0] is not { } image || !Is(image.Dict, "Subtype", "Image")) return null;
                if (!DctOnly().IsMatch(image.Dict) || Regex.IsMatch(image.Dict, @"/(SMask|Mask|Decode|ImageMask)\b")) return null;
                if (doc.StreamData(image) is not { Length: > 4 } jpeg || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return null;
                if (Pdf.PdfWriter.JpegInfo(jpeg).Components is not (1 or 3)) return null;
                jpegs.Add(jpeg);
            }
            return jpegs;
        }
        catch (Exception ex) when (ex is FormatException or ArgumentException or IndexOutOfRangeException or OverflowException)
        {
            return null;
        }
    }

    private static bool Is(string dict, string key, string name) => Regex.IsMatch(dict, $@"/{key}\s*/{name}\b");

    [GeneratedRegex(@"/Filter\s*(?:/DCTDecode\b|\[\s*/DCTDecode\s*\])")]
    private static partial Regex DctOnly();

    /// <summary>Just enough of a PDF to find each page's pictures: objects, the page tree, resources (inherited too), streams.</summary>
    private sealed partial class MiniPdf
    {
        private readonly byte[] _bytes;
        private readonly string _text; // Latin-1: one char per byte, so positions are byte offsets
        private readonly Dictionary<int, PdfObj> _objects = [];

        public sealed record PdfObj(int Id, string Dict, int StreamStart);

        public MiniPdf(byte[] bytes)
        {
            _bytes = bytes;
            _text = Encoding.Latin1.GetString(bytes);
            if (!_text.StartsWith("%PDF-", StringComparison.Ordinal)) throw new FormatException("Not a PDF");
            // Object by object, stepping over each stream's data, so bytes inside a picture are never taken for an object.
            var pos = 0;
            while (ObjectStart().Match(_text, pos) is { Success: true } m)
            {
                var start = m.Index + m.Length;
                var end = _text.IndexOf("endobj", start, StringComparison.Ordinal);
                var stream = StreamKeyword().Match(_text, start);
                var isStream = stream.Success && (end < 0 || stream.Index < end);
                if (end < 0 && !isStream) end = _text.Length;
                var id = int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);
                var obj = new PdfObj(id, _text[start..(isStream ? stream.Index : end)], isStream ? stream.Index + stream.Length : -1);
                _objects[id] = obj; // a later revision of an object replaces the earlier one
                if (!isStream) { pos = end; continue; }
                var data = obj.StreamStart + (Value(obj.Dict, "Length") is { } l && int.TryParse(l.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : 0);
                var after = _text.IndexOf("endstream", Math.Min(data, _text.Length), StringComparison.Ordinal);
                pos = after < 0 ? _text.Length : after;
            }
        }

        public PdfObj? Object(int id) => _objects.GetValueOrDefault(id);

        /// <summary>The pages in order, each with the resources it uses (its own or inherited) and its turn.</summary>
        public List<(PdfObj Page, string Resources, int Rotate)>? Pages()
        {
            if (RootRef().Matches(_text) is not { Count: > 0 } roots || Object(Ref(roots[^1])) is not { } catalog) return null;
            if (RefAfter(catalog.Dict, "Pages") is not { } pagesId || Object(pagesId) is not { } tree) return null;
            var pages = new List<(PdfObj, string, int)>();
            Walk(tree, "", 0, pages, depth: 0, seen: []);
            return pages;
        }

        private void Walk(PdfObj node, string resources, int rotate, List<(PdfObj, string, int)> pages, int depth, HashSet<int> seen)
        {
            if (depth > 32 || !seen.Add(node.Id)) throw new FormatException("Page tree loops");
            resources = Value(node.Dict, "Resources") ?? resources;
            rotate = Value(node.Dict, "Rotate") is { } r && int.TryParse(r, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var turn) ? turn : rotate;
            if (Is(node.Dict, "Type", "Pages"))
            {
                var kids = Value(node.Dict, "Kids") ?? throw new FormatException("Pages without kids");
                foreach (Match k in RefPattern().Matches(kids))
                    Walk(Object(Ref(k)) ?? throw new FormatException("Missing page"), resources, rotate, pages, depth + 1, seen);
            }
            else pages.Add((node, resources, rotate));
        }

        /// <summary>The object numbers of the pictures and forms a page's resources name.</summary>
        public IEnumerable<int> XObjects(string resources)
        {
            var dict = Resolve(resources);
            if (Value(dict, "XObject") is not { } xobjects) return [];
            return RefPattern().Matches(Resolve(xobjects)).Select(Ref);
        }

        public byte[]? StreamData(PdfObj obj)
        {
            if (obj.StreamStart < 0) return null;
            var start = obj.StreamStart;
            var lengthText = Value(obj.Dict, "Length");
            int length;
            if (lengthText is not null && RefPattern().Match(lengthText) is { Success: true } lr && Object(Ref(lr)) is { } lengthObj)
                length = int.Parse(lengthObj.Dict.Trim(), CultureInfo.InvariantCulture);
            else if (lengthText is not null && int.TryParse(lengthText.Trim(), NumberStyles.None, CultureInfo.InvariantCulture, out var direct))
                length = direct;
            else
            {
                var end = _text.IndexOf("endstream", start, StringComparison.Ordinal);
                if (end < 0) return null;
                length = end - start;
                while (length > 0 && _bytes[start + length - 1] is 0x0A or 0x0D) length--;
            }
            if (length < 0 || start + length > _bytes.Length) throw new FormatException("Stream runs past the file");
            return _bytes.AsSpan(start, length).ToArray();
        }

        /// <summary>An indirect reference's object's text, or the text itself.</summary>
        private string Resolve(string value) =>
            RefPattern().Match(value.Trim()) is { Success: true, Index: 0 } m && m.Length == value.Trim().Length && Object(Ref(m)) is { } o ? o.Dict : value;

        private static int Ref(Match m) => int.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture);

        private static int? RefAfter(string dict, string key) =>
            Value(dict, key) is { } v && RefPattern().Match(v) is { Success: true } m ? Ref(m) : null;

        /// <summary>A key's value in a dictionary's text: a nested dictionary or array (balanced), a reference, or one token.</summary>
        private static string? Value(string dict, string key)
        {
            var m = Regex.Match(dict, $@"/{key}(?![A-Za-z0-9])\s*");
            if (!m.Success) return null;
            var i = m.Index + m.Length;
            if (i >= dict.Length) return null;
            if (dict[i] == '[' || dict.AsSpan(i).StartsWith("<<"))
            {
                var (open, close) = dict[i] == '[' ? ("[", "]") : ("<<", ">>");
                var depth = 0;
                for (var j = i; j < dict.Length; j++)
                {
                    if (dict.AsSpan(j).StartsWith(open)) { depth++; j += open.Length - 1; }
                    else if (dict.AsSpan(j).StartsWith(close) && --depth == 0) return dict[i..(j + close.Length)];
                    else if (dict.AsSpan(j).StartsWith(close)) j += close.Length - 1;
                }
                throw new FormatException("Unbalanced dictionary");
            }
            if (RefPattern().Match(dict, i) is { Success: true } r && r.Index == i) return r.Value;
            var end = i;
            while (end < dict.Length && !char.IsWhiteSpace(dict[end]) && dict[end] is not ('/' or '>' or '[' or '<') || end == i && dict[end] == '/') end++;
            return dict[i..end];
        }

        [GeneratedRegex(@"(?<![0-9])(\d+)\s+\d+\s+obj\b")]
        private static partial Regex ObjectStart();

        [GeneratedRegex(@"(?<![a-z])stream\r?\n")]
        private static partial Regex StreamKeyword();

        [GeneratedRegex(@"/Root\s+(\d+)\s+\d+\s+R")]
        private static partial Regex RootRef();

        [GeneratedRegex(@"(\d+)\s+\d+\s+R\b")]
        private static partial Regex RefPattern();
    }
}
