using System.Globalization;
using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// A recognized word and its box in page space (points, top-left origin of the displayed, rotated and cropped page). The
/// box is the word's own, level box, turned <paramref name="Angle"/> degrees clockwise about its centre (a word on a
/// skewed scan runs at the scan's skew). <paramref name="Suspect"/>: why it is a suspect word, if it is one.
/// </summary>
public sealed record OcrWord(string Text, RectD Rect, double Angle = 0, SuspectReasons Suspect = SuspectReasons.None);

/// <summary>A page's Inkvolt text layer as read back: its words, and the language they were recognized in (when known).</summary>
public sealed record OcrLayer(List<OcrWord> Words, string? Language);

/// <summary>
/// Invisible text over scanned pages (an OCR text layer): the page looks the same, but its words can be selected,
/// copied and searched. Each word is written with text render mode 3 (no paint), stretched along its box and turned
/// with it, in a content stream of its own placed before the page's content (so the existing content's graphics state,
/// balanced or not, can't leak into it), with an embedded subset Unicode font whose /ToUnicode returns the words as
/// recognized. The layer starts with comment lines (<see cref="Marker"/> and the language, then one per word: its suspect reasons, box,
/// angle and text as UTF-8 hex), so its words can be read back (<see cref="Words"/>), reviewed and corrected: a corrected
/// layer replaces the old one in place.
/// </summary>
public static class TextLayer
{
    /// <summary>The first line of an Inkvolt text layer (a content-stream comment; viewers skip it).</summary>
    public const string Marker = "%InkvoltOCR 1";

    /// <param name="wordsByPage">Words per page index, in reading order. A page that already has an Inkvolt text layer gets
    /// it replaced.</param>
    /// <param name="language">The language they were recognized in (a BCP-47 tag), kept with them for their review.</param>
    public static byte[] AddInvisibleText(byte[] data, string? password, IReadOnlyDictionary<int, IReadOnlyList<OcrWord>> wordsByPage, string? language = null)
    {
        var pages = wordsByPage.Where(kv => kv.Value.Any(Usable)).OrderBy(kv => kv.Key).ToList();
        if (pages.Count == 0) return data;
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, "This PDF can't be edited");
        foreach (var (index, words) in pages)
        {
            if (index < 0 || index >= doc.PageCount) throw new ArgumentOutOfRangeException(nameof(wordsByPage), $"There is no page {index + 1}.");
            SetLayer(doc, doc.Pages[index], words, language);
        }
        return PdfObj.Save(doc);
    }

    /// <summary>The words of each page's Inkvolt text layer (pages without one, or with one made before 2.2, aren't listed).</summary>
    public static Dictionary<int, OcrLayer> Words(byte[] data, string? password)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import);
        var result = new Dictionary<int, OcrLayer>();
        for (var i = 0; i < doc.PageCount; i++)
            if (FindLayer(doc.Pages[i]) is { } layer && ParseWords(layer.Text) is { Count: > 0 } words) result[i] = new OcrLayer(words, LanguageOf(layer.Text));
        return result;
    }

    /// <summary>
    /// Word <paramref name="index"/> of a page's text layer becomes <paramref name="text"/> (a correction) and stops being a
    /// suspect word; the layer is written again, so search finds the new text.
    /// </summary>
    public static byte[] Correct(byte[] data, string? password, int page, int index, string text)
    {
        if (string.IsNullOrWhiteSpace(text)) throw new ArgumentException("A word can't be empty.", nameof(text));
        return Change(data, password, page, index, w => w with { Text = text.Trim(), Suspect = SuspectReasons.None });
    }

    /// <summary>Word <paramref name="index"/> is right as recognized: it stops being a suspect word.</summary>
    public static byte[] Keep(byte[] data, string? password, int page, int index) =>
        Change(data, password, page, index, w => w with { Suspect = SuspectReasons.None });

    /// <summary>Whether MuPDF finds any text on the page (a page that already has text needs no OCR).</summary>
    public static bool HasText(PdfEngine engine, int page) => engine.GetText(page).Text.Any(c => !char.IsWhiteSpace(c));

    private static byte[] Change(byte[] data, string? password, int page, int index, Func<OcrWord, OcrWord> change)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, "This PDF can't be edited");
        if (page < 0 || page >= doc.PageCount || FindLayer(doc.Pages[page]) is not { } layer || ParseWords(layer.Text) is not { } words)
            throw new InvalidOperationException("This page has no recognized text to correct.");
        if (index < 0 || index >= words.Count) throw new ArgumentOutOfRangeException(nameof(index));
        words[index] = change(words[index]);
        SetLayer(doc, doc.Pages[page], words, LanguageOf(layer.Text));
        return PdfObj.Save(doc);
    }

    private static bool Usable(OcrWord w) =>
        !string.IsNullOrWhiteSpace(w.Text) && !w.Rect.IsEmpty && double.IsFinite(w.Rect.Width) && double.IsFinite(w.Rect.Height) && double.IsFinite(w.Angle);

    /// <summary>The page's Inkvolt text layer: its place in /Contents and its text.</summary>
    private static (int Index, string Text)? FindLayer(PdfPage page)
    {
        var contents = PdfObj.Resolve(page.Elements["/Contents"]) is PdfArray a ? a.Elements.ToList() : page.Elements["/Contents"] is { } one ? [one] : [];
        var marker = Encoding.ASCII.GetBytes(Marker);
        for (var i = 0; i < contents.Count; i++)
            if (PdfObj.Dict(contents[i]) is { Stream: not null } d && PdfObj.StreamBytes(d) is var bytes && bytes.AsSpan().StartsWith(marker))
                return (i, Encoding.ASCII.GetString(bytes));
        return null;
    }

    /// <summary>The language on the layer's first line, if it has one.</summary>
    private static string? LanguageOf(string layer)
    {
        var first = layer.AsSpan(0, Math.Max(0, layer.IndexOf('\n') is var n and >= 0 ? n : layer.Length)).Trim();
        return first.Length > Marker.Length ? first[Marker.Length..].Trim().ToString() : null;
    }

    /// <summary>The words kept in a layer's comment lines, in order; null when they can't be read.</summary>
    private static List<OcrWord>? ParseWords(string layer)
    {
        var words = new List<OcrWord>();
        foreach (var raw in layer.Split('\n'))
        {
            if (!raw.StartsWith("%w ", StringComparison.Ordinal)) continue;
            var f = raw.TrimEnd('\r').Split(' ');
            if (f.Length != 8) return null;
            try
            {
                double N(int i) => double.Parse(f[i], CultureInfo.InvariantCulture);
                words.Add(new OcrWord(Encoding.UTF8.GetString(Convert.FromHexString(f[7])), new RectD(N(2), N(3), N(4), N(5)), N(6),
                    (SuspectReasons)int.Parse(f[1], CultureInfo.InvariantCulture)));
            }
            catch (FormatException)
            {
                return null;
            }
        }
        return words;
    }

    /// <summary>Writes the page's text layer: in place of its Inkvolt layer when it has one, else before its content.</summary>
    private static void SetLayer(PdfDocument doc, PdfPage page, IReadOnlyList<OcrWord> all, string? language)
    {
        var existing = FindLayer(page);
        var fonts = FontDictionary(doc, page);
        if (existing is { } old)
            foreach (var key in fonts.Elements.Keys.Where(k => k.StartsWith("/PdOcr", StringComparison.Ordinal) && old.Text.Contains(k + " ", StringComparison.Ordinal)).ToList())
                fonts.Elements.Remove(key);
        var prefix = "/PdOcr";
        for (var n = 1; fonts.Elements.Keys.Any(k => k.StartsWith(prefix, StringComparison.Ordinal)); n++) prefix = $"/PdOcr{n}_";
        var writer = new CidFontWriter(prefix);
        var primary = SystemFonts.Get("arial.ttf") ?? SystemFonts.Get("segoeui.ttf")
            ?? throw new InvalidOperationException("No font is available for the text layer.");

        var words = all.Where(Usable).ToList();
        var ops = new StringBuilder(Marker);
        if (language is { Length: > 0 } && language.All(c => char.IsAsciiLetterOrDigit(c) || c == '-')) ops.Append(' ').Append(language);
        ops.Append('\n');
        foreach (var w in words)
            ops.Append(CultureInfo.InvariantCulture,
                $"%w {(int)w.Suspect} {PdfObj.F(w.Rect.X)} {PdfObj.F(w.Rect.Y)} {PdfObj.F(w.Rect.Width)} {PdfObj.F(w.Rect.Height)} {PdfObj.F(w.Angle)} {Convert.ToHexString(Encoding.UTF8.GetBytes(w.Text.Trim()))}\n");
        ops.Append("q BT 3 Tr 0 Tc 0 Tw 0 Ts\n");
        var space = TextShaper.Shape(" ", primary);
        for (var i = 0; i < words.Count; i++)
        {
            var w = words[i];
            var line = TextShaper.Shape(w.Text.Trim(), primary, visualOrder: true);
            if (line.Glyphs.Count == 0 || line.Width <= 0) continue;
            var font = line.Glyphs[0].Font;
            var size = w.Rect.Height / Math.Max(0.1, font.Ascent - font.Descent);
            var baseline = w.Rect.Bottom + font.Descent * size;
            Place(ops, page, w, w.Rect.X, baseline, w.Rect.Width / (line.Width * size));
            writer.Emit(ops, line, size);
            ops.Append('\n');

            // An explicit space, stretched over the gap, to the next word on the same line (not across columns), measured
            // along the line: the next word's box as seen from this word's turned frame.
            if (i + 1 < words.Count && space.Width > 0 && Math.Abs(words[i + 1].Angle - w.Angle) < 1)
            {
                var next = InFrameOf(w, words[i + 1]);
                var overlap = Math.Min(w.Rect.Bottom, next.Bottom) - Math.Max(w.Rect.Y, next.Y);
                var gap = next.X - w.Rect.Right;
                if (overlap > 0.5 * Math.Min(w.Rect.Height, next.Height) && gap > 0.01 && gap < 2 * Math.Max(w.Rect.Height, next.Height))
                {
                    Place(ops, page, w, w.Rect.Right, baseline, gap / (space.Width * size));
                    writer.Emit(ops, space, size);
                    ops.Append('\n');
                }
            }
        }
        ops.Append("ET Q\n");

        foreach (var (name, f) in writer.BuildFonts(doc).Elements) fonts.Elements[name] = f;
        var stream = PdfObj.AddStream(doc, Encoding.ASCII.GetBytes(ops.ToString())).Reference!;
        if (existing is { } replace)
        {
            if (PdfObj.Resolve(page.Elements["/Contents"]) is PdfArray list) list.Elements[replace.Index] = stream;
            else page.Elements["/Contents"] = stream;
            return;
        }
        // The layer goes first, in the page's initial graphics state: whatever the existing content does to the state
        // (a scaling cm left in an unbalanced q, or a stray Q that pops more than it pushed) can't reach it, and as the
        // text is invisible, painting order doesn't matter. The existing content is wrapped in q…Q so what follows it
        // (another tool's additions) starts clean too.
        var contents = new PdfArray(doc);
        contents.Elements.Add(stream);
        contents.Elements.Add(PdfObj.AddStream(doc, "q\n"u8.ToArray(), compress: false).Reference!);
        switch (page.Elements["/Contents"])
        {
            case PdfReference { Value: PdfArray content }:
                foreach (var e in content.Elements) contents.Elements.Add(e);
                break;
            case PdfArray content:
                foreach (var e in content.Elements) contents.Elements.Add(e);
                break;
            case PdfReference r:
                contents.Elements.Add(r);
                break;
        }
        contents.Elements.Add(PdfObj.AddStream(doc, "\nQ\n"u8.ToArray(), compress: false).Reference!);
        page.Elements["/Contents"] = contents;
    }

    /// <summary><paramref name="other"/>'s box as seen from <paramref name="w"/>'s frame (turned back by its angle about its centre).</summary>
    private static RectD InFrameOf(OcrWord w, OcrWord other)
    {
        if (w.Angle == 0) return other.Rect;
        var (sin, cos) = Math.SinCos(-w.Angle * Math.PI / 180);
        var (dx, dy) = (other.Rect.CenterX - w.Rect.CenterX, other.Rect.CenterY - w.Rect.CenterY);
        var (cx, cy) = (w.Rect.CenterX + dx * cos - dy * sin, w.Rect.CenterY + dx * sin + dy * cos);
        return new RectD(cx - other.Rect.Width / 2, cy - other.Rect.Height / 2, other.Rect.Width, other.Rect.Height);
    }

    /// <summary>
    /// Sets the text matrix so text runs along word <paramref name="w"/> (left to right in its own frame, turned by its
    /// angle about its centre) from (<paramref name="x"/>, <paramref name="baseline"/>) of that frame, whatever the page's
    /// /Rotate, stretched by <paramref name="scale"/>.
    /// </summary>
    private static void Place(StringBuilder ops, PdfPage page, OcrWord w, double x, double baseline, double scale)
    {
        var (sin, cos) = Math.SinCos(w.Angle * Math.PI / 180);
        var (dx, dy) = (x - w.Rect.CenterX, baseline - w.Rect.CenterY);
        var (px, py) = (w.Rect.CenterX + dx * cos - dy * sin, w.Rect.CenterY + dx * sin + dy * cos);
        var o = PdfObj.ToPdf(page, px, py);
        var u = PdfObj.ToPdf(page, px + cos, py + sin); // along the line
        var v = PdfObj.ToPdf(page, px + sin, py - cos); // up
        var tz = double.IsFinite(scale) && scale > 0 ? scale * 100 : 100;
        ops.Append(CultureInfo.InvariantCulture,
            $"{PdfObj.F(tz)} Tz {PdfObj.F(u.X - o.X)} {PdfObj.F(u.Y - o.Y)} {PdfObj.F(v.X - o.X)} {PdfObj.F(v.Y - o.Y)} {PdfObj.F(o.X)} {PdfObj.F(o.Y)} Tm ");
    }

    /// <summary>The page's /Font resource dictionary (created when missing).</summary>
    private static PdfDictionary FontDictionary(PdfDocument doc, PdfPage page)
    {
        var resources = PdfObj.Dict(page.Elements["/Resources"]);
        if (resources is null)
        {
            resources = new PdfDictionary(doc);
            page.Elements["/Resources"] = resources;
        }
        var fonts = PdfObj.Dict(resources.Elements["/Font"]);
        if (fonts is null)
        {
            fonts = new PdfDictionary(doc);
            resources.Elements["/Font"] = fonts;
        }
        return fonts;
    }
}
