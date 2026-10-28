using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>
/// A piece of text as a page's content draws it: one text-showing operator (Tj, TJ, ' or ") of the page's own
/// content, which is usually a line or a word. Page space (points, top-left origin of the page as shown).
/// </summary>
/// <param name="Id">The operator's place in the page's content (with <see cref="Text"/>, how an edit finds it again).</param>
/// <param name="Box">Where it shows (the bounding box when it is turned).</param>
/// <param name="FontSize">Its size on the page, in points.</param>
/// <param name="Color">Its fill color (0xRRGGBB) when it is a plain gray, RGB or CMYK color, else black.</param>
/// <param name="Angle">The direction of its baseline on the page, degrees clockwise from left-to-right.</param>
/// <param name="Blocked">Why it can't be edited, as the end of a sentence ("it is …"); null when it can.</param>
public sealed record TextRun(int PageIndex, int Id, string Text, RectD Box, double FontSize, string FontName, bool Bold, bool Italic,
    int Color, double Angle, string? Blocked)
{
    internal TextFont? Font { get; init; }
    /// <summary>Page points per text-space unit along the baseline.</summary>
    internal double Scale { get; init; }
    internal double Size, CharSpacing, WordSpacing, HScale = 1;
    internal double GapEms = 0.25;

    internal ContentEditor.RunInfo? Info { get; init; }

    /// <summary>Where its baseline starts on the page (page space, the text rise included).</summary>
    internal PointD Origin { get; init; }

    /// <summary>The run's width as drawn (points along the baseline, to the end of its last glyph).</summary>
    public double OldWidth { get; init; }

    /// <summary>The width <paramref name="text"/> would take written into this run (points), and the characters the font can't draw.</summary>
    public TextCheck Check(string text)
    {
        if (Font is null || Info is null) return new TextCheck(OldWidth, OldWidth, []);
        var (parts, enc, _) = ContentEditor.Plan(Info, this, ContentEditor.OneLine(text));
        return new TextCheck(Width(parts) * Scale, OldWidth, enc.Missing);
    }

    /// <summary>To the end of the last glyph's ink, in text space (as <see cref="OldWidth"/> measures the run).</summary>
    internal double Width(IEnumerable<ContentEditor.Part> parts)
    {
        double w = 0, end = 0;
        foreach (var p in parts)
        {
            if (p.Code is not { } c)
            {
                w -= p.Number / 1000 * Size * HScale;
                continue;
            }
            var glyph = Font!.WidthOf(c) / 1000 * Size * HScale;
            end = w + glyph;
            w += glyph + (CharSpacing + (!Font.TwoByte && c == 32 ? WordSpacing : 0)) * HScale;
        }
        return end;
    }
}

/// <summary>What new text would look like: its width and the run's (points), and characters the font has no glyph for.</summary>
public readonly record struct TextCheck(double Width, double OldWidth, IReadOnlyList<string> Missing);

/// <summary>A picture the page draws: an image XObject (Do) or an inline image (BI … EI). Page space.</summary>
/// <param name="Id">The operator's place in the page's content.</param>
/// <param name="Box">Where it shows (the bounding box when it is turned).</param>
/// <param name="Blocked">Why it can't be edited ("it is …"); null when it can.</param>
public sealed record PageImage(int PageIndex, int Id, RectD Box, bool Inline, string? Blocked)
{
    /// <summary>Turned by other than a quarter turn, or skewed: resizing scales its bounding box.</summary>
    public bool Turned { get; init; }
}

/// <summary>The text runs and pictures of a page, for Edit Text &amp; Images.</summary>
public sealed record PageContent(IReadOnlyList<TextRun> Runs, IReadOnlyList<PageImage> Images)
{
    public static PageContent Empty { get; } = new([], []);

    /// <summary>The page's text runs grouped into paragraphs (see <see cref="ContentEditor.GroupParagraphs"/>); upright text only.</summary>
    public IReadOnlyList<TextParagraph> Paragraphs { get; init; } = [];

    /// <summary>The paragraph a run belongs to, or null (turned text, only spaces).</summary>
    public TextParagraph? ParagraphOf(TextRun run) => Paragraphs.FirstOrDefault(p => p.Runs.Contains(run));

    /// <summary>The paragraph under a point: the one holding the run there, else one of several lines whose box holds the point.</summary>
    public TextParagraph? ParagraphAt(double x, double y, double slop = 1) =>
        RunAt(x, y, slop) is { } run ? ParagraphOf(run) : Paragraphs.FirstOrDefault(p => p.Lines.Count > 1 && p.Box.Contains(x, y));

    /// <summary>The text run under a point (the smallest when several overlap), or null.</summary>
    public TextRun? RunAt(double x, double y, double slop = 1) =>
        Runs.Where(r => r.Box.Inflate(slop).Contains(x, y)).MinBy(r => r.Box.Width * r.Box.Height);

    /// <summary>The topmost picture under a point, or null.</summary>
    public PageImage? ImageAt(double x, double y) => Images.LastOrDefault(i => i.Box.Contains(x, y));
}

/// <summary>An edit of existing content that can't be made (the message says why, as a sentence for the user).</summary>
public sealed class ContentEditException(string message, IReadOnlyList<string>? missing = null) : InvalidOperationException(message)
{
    /// <summary>Characters the font has no glyph for (empty for other reasons).</summary>
    public IReadOnlyList<string> Missing { get; } = missing ?? [];

    /// <summary>A paragraph's new text would run into this (what follows below it, page space); null for other reasons.</summary>
    public RectD? Overlaps { get; init; }
}

/// <summary>
/// Edit Text &amp; Images, first step: replaces the text of one text-showing operator in the same embedded font (only
/// when every glyph is in it; no other font is substituted and nothing reflows), and moves, resizes, replaces or
/// deletes one picture by rewriting its placement. Works on the page's own content (all its content streams, read as
/// one); text and pictures inside form XObjects are listed but not edited. Each edit is bytes in → bytes out,
/// saved through <see cref="PdfObj.Save"/> (signed files appended to, protection kept).
/// </summary>
public static partial class ContentEditor
{
    private const int MaxDepth = 8;

    /// <summary>The page's text runs and pictures.</summary>
    public static PageContent Read(byte[] data, string? password, int pageIndex, CancellationToken cancel = default)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, "This PDF's pages can't be read");
        if (pageIndex < 0 || pageIndex >= doc.PageCount) throw new ArgumentOutOfRangeException(nameof(pageIndex));
        var page = doc.Pages[pageIndex];
        return WithParagraphs(Walk(page, pageIndex, Parse(page, cancel), cancel).Content);
    }

    /// <summary>Several pages' text runs and pictures (a page that can't be read comes back empty).</summary>
    public static IReadOnlyDictionary<int, PageContent> Read(byte[] data, string? password, IReadOnlyCollection<int> pages, CancellationToken cancel = default)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, "This PDF's pages can't be read");
        var result = new Dictionary<int, PageContent>();
        foreach (var p in pages)
        {
            if (p < 0 || p >= doc.PageCount) continue;
            try
            {
                var page = doc.Pages[p];
                result[p] = WithParagraphs(Walk(page, p, Parse(page, cancel), cancel).Content);
            }
            catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or InvalidCastException or IndexOutOfRangeException)
            {
                result[p] = PageContent.Empty; // a damaged page: nothing to edit on it
            }
        }
        return result;
    }

    // ---- Text ----

    /// <summary>Replaces a run's text, written in the run's own font.</summary>
    /// <exception cref="ContentEditException">The font can't draw the text (the message names the missing characters), the run can't be edited, or the page changed.</exception>
    public static byte[] ReplaceText(byte[] data, string? password, TextRun run, string text)
    {
        text = OneLine(text);
        if (text == run.Text) return data;
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, "This PDF can't be edited");
        var page = PageOf(doc, run.PageIndex);
        var streams = Streams(page);
        var content = streams.Bytes;
        var ops = ContentLexer.Parse(content);
        var walk = Walk(page, run.PageIndex, ops, default);
        // The run where it was; else (an earlier edit moved the page's operators) the same text in the same place.
        var now = walk.Content.Runs.FirstOrDefault(r => r.Id == run.Id && r.Text == run.Text)
                  ?? walk.Content.Runs.Where(r => r.Text == run.Text && Near(r.Box, run.Box)).MinBy(r => Math.Abs(r.Box.X - run.Box.X) + Math.Abs(r.Box.Y - run.Box.Y));
        if (now is { Blocked: { } why }) throw new ContentEditException($"This text can't be edited: {why}.");
        if (now is null || !walk.Runs.TryGetValue(now.Id, out var info))
            throw new ContentEditException("The page changed since this text was picked. Pick it again.");
        var font = now.Font!;

        var (parts, enc, middle) = Plan(info, now, text);
        if (enc.Missing.Count > 0) throw MissingGlyphs(font, enc.Missing);
        font.Prepare(doc, enc.Codes, middle);
        var op = ops[now.Id];
        var replacement = WriteShow(op, info, font, parts);
        WriteContent(doc, page, streams, ops, [(op.Start, op.End, replacement)]);
        SignedEdits.NoteRemoval(); // the old text stays in a signed file's earlier revision
        return PdfObj.Save(doc);
    }

    /// <summary>
    /// How a run's new text is written: what didn't change is kept (with its kerning), the changed middle is encoded
    /// plainly. Adjustments touching the change go with it, except the one before the first glyph (where the run
    /// starts) and any after the last.
    /// </summary>
    internal static (List<Part> Parts, EncodedText Middle, string MiddleText) Plan(RunInfo info, TextRun run, string text)
    {
        var items = info.Items;
        int pre = 0, preLen = 0;
        while (pre < items.Count && text.AsSpan(preLen).StartsWith(items[pre].Text, StringComparison.Ordinal))
            preLen += items[pre++].Text.Length;
        while (pre > 0 && items[pre - 1] is { IsNumber: true, Text.Length: 0 }) pre--;
        var lead = 0;
        while (lead < items.Count && items[lead].IsNumber) lead++;
        pre = Math.Max(pre, lead);
        preLen = items.Take(pre).Sum(i => i.Text.Length);
        int suf = 0, sufLen = 0;
        while (suf < items.Count - pre && items[^(suf + 1)].Text is var t1 && preLen + sufLen + t1.Length <= text.Length
               && text.AsSpan(0, text.Length - sufLen).EndsWith(t1, StringComparison.Ordinal))
        {
            sufLen += t1.Length;
            suf++;
        }
        while (suf > 0 && items[^suf] is { IsNumber: true, Text.Length: 0, Trailing: false }) suf--;
        sufLen = items.Skip(items.Count - suf).Sum(i => i.Text.Length);
        var middle = text[preLen..(text.Length - sufLen)];

        var enc = run.Font!.Encode(middle);
        var parts = new List<Part>();
        foreach (var it in items.Take(pre)) parts.Add(new Part(it.IsNumber ? null : it.Code, it.Number));
        foreach (var c in enc.Codes) parts.Add(c == TextFont.Gap ? new Part(null, -run.GapEms * 1000) : new Part(c, 0));
        foreach (var it in items.Skip(items.Count - suf)) parts.Add(new Part(it.IsNumber ? null : it.Code, it.Number));
        return (parts, enc, middle);
    }

    /// <summary>A glyph code, or (with no code) a TJ adjustment, of rewritten text.</summary>
    internal readonly record struct Part(int? Code, double Number);

    internal static string OneLine(string text) => text.Replace("\r\n", " ").Replace('\n', ' ').Replace('\r', ' ').Replace('\t', ' ');

    private static ContentEditException MissingGlyphs(TextFont font, IReadOnlyList<string> missing)
    {
        static string Show(string c) => c == " " ? "space" : char.IsControl(c[0]) ? $"U+{(int)c[0]:X4}" : $"“{c}”";
        var list = string.Join(", ", missing.Take(12).Select(Show)) + (missing.Count > 12 ? $" and {missing.Count - 12} more" : "");
        var name = font.Name.Length > 0 ? $"The font “{font.Name}”" : "This text's font";
        return new ContentEditException(
            $"{name} has no {(missing.Count == 1 ? "glyph" : "glyphs")} for {list} in this PDF (an embedded font usually holds only the characters the document uses). Use characters already in this text, or add a text box instead.",
            missing);
    }

    /// <summary>The text-showing operator rewritten with new parts (strings of codes and TJ adjustments).</summary>
    private static string WriteShow(COp op, RunInfo info, TextFont font, List<Part> parts)
    {
        var tokens = new List<string>();
        var codes = new List<int>();
        void Flush()
        {
            if (codes.Count == 0) return;
            var bytes = font.ToBytes(codes);
            tokens.Add(info.Hex ? ContentLexer.HexString(bytes) : ContentLexer.Literal(bytes));
            codes.Clear();
        }
        foreach (var (c, n) in parts)
        {
            if (c is { } code) codes.Add(code);
            else if (Math.Abs(n) > 1e-9)
            {
                Flush();
                tokens.Add(ContentLexer.Number(n));
            }
        }
        Flush();
        var plain = tokens.Count <= 1 && !parts.Any(p => p.Code is null && Math.Abs(p.Number) > 1e-9);
        var str = tokens.Count == 1 ? tokens[0] : info.Hex ? "<>" : "()";
        var array = "[" + string.Join(" ", tokens) + "]";
        return op.Name switch
        {
            "Tj" => plain ? $"{str} Tj" : $"{array} TJ",
            "'" => plain ? $"{str} '" : $"T* {array} TJ",
            "\"" => plain
                ? $"{ContentLexer.Number(op.N(0))} {ContentLexer.Number(op.N(1))} {str} \""
                : $"{ContentLexer.Number(op.N(0))} Tw {ContentLexer.Number(op.N(1))} Tc T* {array} TJ",
            _ => $"{array} TJ",
        };
    }

    // ---- Pictures ----

    /// <summary>Moves and/or resizes a picture so its bounding box becomes <paramref name="box"/> (page space).</summary>
    public static byte[] MoveImage(byte[] data, string? password, PageImage image, RectD box)
    {
        if (box.Width < 1 || box.Height < 1) throw new ContentEditException("A picture can't be made that small.");
        return EditImage(data, password, image, (doc, page, found, op, ctm, ops, content) =>
        {
            var p2u = PageToUser(page);
            var u2p = p2u.Invert() ?? throw new ContentEditException("This page's size can't be read.");
            var old = found.Box;
            var d = new Mat(box.Width / old.Width, 0, 0, box.Height / old.Height, box.X - old.X * box.Width / old.Width, box.Y - old.Y * box.Height / old.Height);
            var dUser = u2p.Times(d).Times(p2u);
            var inv = ctm.Invert() ?? throw new ContentEditException("This picture is drawn squashed flat, so it can't be moved.");
            var m = ctm.Times(dUser).Times(inv); // inserted before the Do, the image lands on CTM × D
            var at = ops.IndexOf(op);
            // "q a b c d e f cm /Im Do Q": change that cm; otherwise wrap the Do.
            if (at >= 2 && at + 1 < ops.Count && ops[at - 2].Name == "q" && ops[at - 1] is { Name: "cm", Operands.Count: 6 } cm && ops[at + 1].Name == "Q")
            {
                var c = new Mat(cm.N(0), cm.N(1), cm.N(2), cm.N(3), cm.N(4), cm.N(5));
                return [(cm.Start, cm.End, m.Times(c).Write() + " cm")];
            }
            return [(op.Start, op.End, $"q {m.Write()} cm {Slice(op, content)} Q")];
        });
    }

    /// <summary>Removes a picture from the page.</summary>
    public static byte[] DeleteImage(byte[] data, string? password, PageImage image) =>
        EditImage(data, password, image, (doc, page, found, op, ctm, ops, content) =>
        {
            SignedEdits.NoteRemoval();
            var at = ops.IndexOf(op);
            if (at >= 2 && at + 1 < ops.Count && ops[at - 2].Name == "q" && ops[at - 1].Name == "cm" && ops[at + 1].Name == "Q")
                return [(ops[at - 2].Start, ops[at + 1].End, " ")];
            return [(op.Start, op.End, " ")];
        }, dropName: true);

    /// <summary>Puts another picture (an image file) in a picture's place, upright and fitted in its box with its own proportions.</summary>
    /// <exception cref="InvalidOperationException">The file isn't an image that can be read.</exception>
    public static byte[] ReplaceImage(byte[] data, string? password, PageImage image, byte[] file, string fileName) =>
        EditImage(data, password, image, (doc, page, found, op, ctm, ops, content) =>
        {
            var (xobject, w, h, dpiX, dpiY, orientation) = ImageImport.StoreImage(doc, file, fileName);
            var name = AddXObject(doc, page, xobject);
            var (dw, dh) = (w / dpiX, h / dpiY);
            if (orientation is >= 5 and <= 8) (dw, dh) = (dh, dw);
            var b = found.Box;
            double fw = b.Width, fh = b.Height;
            if (dw / dh > b.Width / b.Height) fh = b.Width * dh / dw;
            else fw = b.Height * dw / dh;
            var (x, y) = (b.X + (b.Width - fw) / 2, b.Y + (b.Height - fh) / 2);
            // Placement works y-up: place in "page space flipped" (Y' = -Y), then back to page space and on to user space.
            var place = ImageImport.Placement(orientation, x, -(y + fh), fw, fh);
            var total = new Mat(place[0], place[1], place[2], place[3], place[4], place[5]).Times(new Mat(1, 0, 0, -1, 0, 0)).Times(PageToUser(page));
            var inv = ctm.Invert() ?? new Mat(1, 0, 0, 1, 0, 0);
            var m = total.Times(inv);
            SignedEdits.NoteRemoval();
            return [(op.Start, op.End, $"q {m.Write()} cm /{name} Do Q")];
        }, dropName: true);

    private delegate List<(int Start, int End, string Text)> ImageEdit(PdfDocument doc, PdfPage page, PageImage image, COp op, Mat ctm, List<COp> ops, byte[] content);

    private static byte[] EditImage(byte[] data, string? password, PageImage image, ImageEdit edit, bool dropName = false)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, "This PDF can't be edited");
        var page = PageOf(doc, image.PageIndex);
        var streams = Streams(page);
        var content = streams.Bytes;
        var ops = ContentLexer.Parse(content);
        var walk = Walk(page, image.PageIndex, ops, default);
        var now = walk.Content.Images.FirstOrDefault(i => i.Id == image.Id && Near(i.Box, image.Box))
                  ?? walk.Content.Images.LastOrDefault(i => Near(i.Box, image.Box));
        if (now is { Blocked: { } why }) throw new ContentEditException($"This picture can't be edited: {why}.");
        if (now is null || !walk.ImageCtm.TryGetValue(now.Id, out var ctm))
            throw new ContentEditException("The page changed since this picture was picked. Pick it again.");
        var op = ops[now.Id];
        var oldName = op.Name == "Do" ? op.Operands[0].Name : null;
        var edits = edit(doc, page, now, op, ctm, ops, content);
        var updated = WriteContent(doc, page, streams, ops, edits);
        // A picture no longer drawn anywhere on the page leaves the page's resources (when they are the page's own and
        // no form XObject that borrows the page's resources draws it).
        if (dropName && oldName is not null && !Draws(ContentLexer.Parse(updated), oldName)
            && page.Elements["/Resources"] is PdfDictionary res && res.Elements["/XObject"] is PdfDictionary xo && !UsedByInheritingForm(xo, oldName))
            xo.Elements.Remove("/" + oldName);
        return PdfObj.Save(doc);
    }

    private static bool Draws(List<COp> ops, string name) => ops.Any(o => o.Name == "Do" && o.Operands.Count > 0 && o.Operands[0].Name == name);

    /// <summary>Whether a form XObject without resources of its own (so it uses the page's) draws <paramref name="name"/>, at any depth.</summary>
    private static bool UsedByInheritingForm(PdfDictionary xobjects, string name)
    {
        var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
        bool Visit(PdfDictionary? xo, int depth)
        {
            if (xo is null || depth > MaxDepth) return false;
            foreach (var item in xo.Elements.Values)
            {
                if (PdfObj.Dict(item) is not { } form || PdfObj.NameOf(form, "/Subtype") != "/Form" || !seen.Add(form)) continue;
                var own = PdfObj.Dict(form.Elements["/Resources"]);
                if (own is null && Draws(ContentLexer.Parse(PdfObj.StreamBytes(form)), name)) return true;
                if (Visit(PdfObj.Dict(own?.Elements["/XObject"]), depth + 1)) return true;
            }
            return false;
        }
        return Visit(xobjects, 0);
    }

    private static bool Near(RectD a, RectD b) =>
        Math.Abs(a.X - b.X) < 1 && Math.Abs(a.Y - b.Y) < 1 && Math.Abs(a.Width - b.Width) < 1 && Math.Abs(a.Height - b.Height) < 1;

    /// <summary>Adds an image XObject to the page's own resources (copying shared ones first), under a fresh name.</summary>
    private static string AddXObject(PdfDocument doc, PdfPage page, PdfDictionary xobject)
    {
        var res = page.Elements["/Resources"] switch
        {
            PdfDictionary d => d,
            PdfReference r when r.Value is PdfDictionary shared => shared.Clone(),
            _ => new PdfDictionary(doc),
        };
        page.Elements["/Resources"] = res;
        var xo = res.Elements["/XObject"] switch
        {
            PdfDictionary d => d,
            PdfReference r when r.Value is PdfDictionary shared => shared.Clone(),
            _ => new PdfDictionary(doc),
        };
        res.Elements["/XObject"] = xo;
        var n = 1;
        while (xo.Elements.ContainsKey($"/InkImg{n}")) n++;
        xo.Elements[$"/InkImg{n}"] = xobject.Reference!;
        return $"InkImg{n}";
    }

    // ---- Content ----

    private static PdfPage PageOf(PdfDocument doc, int index)
    {
        if (index < 0 || index >= doc.PageCount) throw new ContentEditException("This page is no longer in the document.");
        return doc.Pages[index];
    }

    private static List<COp> Parse(PdfPage page, CancellationToken cancel) => ContentLexer.Parse(ContentBytes(page), cancel);

    /// <summary>One content stream of a page: where its bytes sit in the page's content read as one, its place in the /Contents array.</summary>
    private sealed record ContentPart(int Start, int End, int Slot, bool Unreadable);

    /// <summary>A page's content streams read as one (they are one content stream split at token boundaries).</summary>
    private sealed record PageStreams(byte[] Bytes, List<ContentPart> Parts);

    internal static byte[] ContentBytes(PdfPage page) => Streams(page).Bytes;

    private static PageStreams Streams(PdfPage page)
    {
        var parts = new List<ContentPart>();
        using var ms = new MemoryStream();
        void Add(PdfDictionary s, int slot)
        {
            byte[] bytes;
            try
            {
                bytes = PdfObj.StreamBytes(s);
            }
            catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or ArgumentException or NotSupportedException or NotImplementedException or IndexOutOfRangeException)
            {
                bytes = []; // a filter that fails on its data
            }
            // A stream that holds data but decodes to nothing (a damaged filter) must not be dropped by a rewrite.
            var unreadable = bytes.Length == 0 && s.Stream!.Value.Length > 0;
            var start = (int)ms.Length;
            ms.Write(bytes);
            parts.Add(new ContentPart(start, (int)ms.Length, slot, unreadable));
            ms.WriteByte((byte)'\n');
        }
        switch (PdfObj.Resolve(page.Elements["/Contents"]))
        {
            case PdfDictionary { Stream: not null } s:
                Add(s, -1);
                break;
            case PdfArray a:
                for (var i = 0; i < a.Elements.Count; i++)
                    if (PdfObj.Dict(a.Elements[i]) is { Stream: not null } part) Add(part, i);
                break;
        }
        return new PageStreams(ms.ToArray(), parts);
    }

    /// <summary>
    /// Writes the page's content with the edits. When every edit falls in one of several content streams and no operator
    /// crosses that stream's edges, only that stream is replaced (the others stay as they are, readable or not);
    /// otherwise the page gets one new stream, which a stream that can't be read would be lost from: refused.
    /// Returns the page's content as now read as one.
    /// </summary>
    private static byte[] WriteContent(PdfDocument doc, PdfPage page, PageStreams streams, List<COp> ops, List<(int Start, int End, string Text)> edits)
    {
        var updated = Splice(streams.Bytes, edits);
        if (streams.Parts.Count > 1 && edits.Count > 0 && PdfObj.Resolve(page.Elements["/Contents"]) is PdfArray old)
        {
            int lo = edits.Min(e => e.Start), hi = edits.Max(e => e.End);
            if (streams.Parts.FirstOrDefault(p => lo >= p.Start && hi <= p.End) is { } part
                && !ops.Any(o => o.Start < part.Start && o.End > part.Start || o.Start < part.End && o.End > part.End))
            {
                var bytes = Splice(streams.Bytes[part.Start..part.End], [.. edits.Select(e => (e.Start - part.Start, e.End - part.Start, e.Text))]);
                var array = new PdfArray(doc, [.. old.Elements]); // the page's own: another page may share the old one
                array.Elements[part.Slot] = PdfObj.AddStream(doc, bytes).Reference!;
                page.Elements["/Contents"] = array;
                return updated;
            }
        }
        if (streams.Parts.Any(p => p.Unreadable))
            throw new ContentEditException("Part of this page's content can't be read (it is damaged), so the page can't be rewritten without losing it.");
        page.Elements["/Contents"] = PdfObj.AddStream(doc, updated).Reference!;
        return updated;
    }

    private static byte[] Splice(byte[] content, List<(int Start, int End, string Text)> edits)
    {
        using var ms = new MemoryStream(content.Length + 256);
        var at = 0;
        foreach (var (start, end, text) in edits.OrderBy(e => e.Start))
        {
            ms.Write(content, at, start - at);
            // Keep the replacement apart from its neighbors (a name or number must not run into the next token).
            ms.WriteByte((byte)' ');
            ms.Write(Encoding.Latin1.GetBytes(text));
            ms.WriteByte((byte)' ');
            at = end;
        }
        ms.Write(content, at, content.Length - at);
        return ms.ToArray();
    }

    /// <summary>The drawing operator as written: the Do with its name, or the whole inline image (BI … EI, its bytes as Latin-1).</summary>
    private static string Slice(COp op, byte[] content) =>
        op.Name == "Do" ? $"/{EscapeName(op.Operands[0].Name)} Do" : Encoding.Latin1.GetString(content, op.Start, op.End - op.Start);

    private static string EscapeName(string name)
    {
        var sb = new StringBuilder();
        foreach (var c in name)
        {
            if (c is > ' ' and < (char)127 and not ('#' or '/' or '(' or ')' or '<' or '>' or '[' or ']' or '{' or '}' or '%')) sb.Append(c);
            else sb.Append('#').Append(((int)c & 0xFF).ToString("X2", System.Globalization.CultureInfo.InvariantCulture));
        }
        return sb.ToString();
    }

    /// <summary>Page space (top-left origin, as shown) → PDF user space.</summary>
    private static Mat PageToUser(PdfPage page)
    {
        var p0 = PdfObj.ToPdf(page, 0, 0);
        var px = PdfObj.ToPdf(page, 1, 0);
        var py = PdfObj.ToPdf(page, 0, 1);
        return new Mat(px.X - p0.X, px.Y - p0.Y, py.X - p0.X, py.Y - p0.Y, p0.X, p0.Y);
    }

    // ---- Walking the content ----

    /// <summary>A PDF matrix [a b c d e f]; points are row vectors, so A.Times(B) applies A first.</summary>
    internal readonly record struct Mat(double A, double B, double C, double D, double E, double F)
    {
        public static readonly Mat Identity = new(1, 0, 0, 1, 0, 0);

        public Mat Times(Mat m) => new(
            A * m.A + B * m.C, A * m.B + B * m.D,
            C * m.A + D * m.C, C * m.B + D * m.D,
            E * m.A + F * m.C + m.E, E * m.B + F * m.D + m.F);

        public (double X, double Y) Apply(double x, double y) => (A * x + C * y + E, B * x + D * y + F);

        public Mat? Invert()
        {
            var det = A * D - B * C;
            if (Math.Abs(det) < 1e-12) return null;
            return new Mat(D / det, -B / det, -C / det, A / det, (C * F - D * E) / det, (B * E - A * F) / det);
        }

        public string Write() => string.Join(' ', new[] { A, B, C, D, E, F }.Select(ContentLexer.Number));
    }

    /// <summary>One glyph or TJ adjustment of a run, with the text it stands for.</summary>
    internal sealed record RunItem(int Code, double Number, string Text, bool IsNumber, bool Trailing = false);

    /// <summary>
    /// A run as its operator draws it: its glyphs and adjustments; the text matrix where its first glyph starts
    /// (<see cref="Tm"/>), the line matrix after the operator (<see cref="TlmAfter"/>), the CTM, the text rise, and how
    /// far the operator advances the text matrix (text space). A paragraph rewrite needs these to keep what follows in place.
    /// </summary>
    internal sealed record RunInfo(List<RunItem> Items, bool Hex)
    {
        public Mat Tm { get; init; } = Mat.Identity;
        public Mat TlmAfter { get; init; } = Mat.Identity;
        public Mat Ctm { get; init; } = Mat.Identity;
        public double Rise { get; init; }
        public double Advance { get; init; }
    }

    private sealed class Walked
    {
        public readonly List<TextRun> TextRuns = [];
        public readonly List<PageImage> Images = [];
        public readonly Dictionary<int, RunInfo> Runs = [];
        public readonly Dictionary<int, Mat> ImageCtm = [];
        /// <summary>Things inside form XObjects get negative ids (they aren't page operators).</summary>
        public int Nested;
        public PageContent Content => new(TextRuns, Images);
    }

    private sealed class GState
    {
        public Mat Ctm = Mat.Identity;
        public TextFont? Font;
        public string FontKey = "";
        public double Size = 1, Tc, Tw, Th = 1, Tl, Rise;
        public int Render;
        public int Fill;
        public GState Clone() => (GState)MemberwiseClone();
    }

    private static Walked Walk(PdfPage page, int pageIndex, List<COp> ops, CancellationToken cancel)
    {
        var w = new Walked();
        Run(w, page, pageIndex, ops, PdfObj.Dict(page.Elements["/Resources"]), new GState(), 0, null, cancel);
        return w;
    }

    private static void Run(Walked w, PdfPage page, int pageIndex, List<COp> ops, PdfDictionary? resources, GState gs, int depth, string? blocked, CancellationToken cancel)
    {
        gs = gs.Clone();
        var stack = new Stack<GState>();
        var marked = new Stack<bool>(); // marked-content sequences: does one carry /ActualText?
        var actualText = 0;
        Mat tm = Mat.Identity, tlm = Mat.Identity;
        for (var i = 0; i < ops.Count; i++)
        {
            if ((i & 1023) == 1023) cancel.ThrowIfCancellationRequested();
            var op = ops[i];
            var id = depth == 0 ? i : -++w.Nested;
            switch (op.Name)
            {
                case "q":
                    if (stack.Count < 256) stack.Push(gs.Clone());
                    break;
                case "Q":
                    if (stack.Count > 0) gs = stack.Pop();
                    break;
                case "cm" when op.Operands.Count >= 6:
                    gs.Ctm = new Mat(op.N(0), op.N(1), op.N(2), op.N(3), op.N(4), op.N(5)).Times(gs.Ctm);
                    break;
                case "g" when op.Operands.Count >= 1:
                    gs.Fill = Gray(op.N(0));
                    break;
                case "rg" when op.Operands.Count >= 3:
                    gs.Fill = Rgb(op.N(0), op.N(1), op.N(2));
                    break;
                case "k" when op.Operands.Count >= 4:
                    gs.Fill = Rgb((1 - op.N(0)) * (1 - op.N(3)), (1 - op.N(1)) * (1 - op.N(3)), (1 - op.N(2)) * (1 - op.N(3)));
                    break;
                case "sc" or "scn" when op.Operands.Count is 1 or 3 or 4 && op.Operands.All(o => o.Kind == CKind.Number):
                    gs.Fill = op.Operands.Count switch
                    {
                        1 => Gray(op.N(0)),
                        3 => Rgb(op.N(0), op.N(1), op.N(2)),
                        _ => Rgb((1 - op.N(0)) * (1 - op.N(3)), (1 - op.N(1)) * (1 - op.N(3)), (1 - op.N(2)) * (1 - op.N(3))),
                    };
                    break;
                case "cs":
                    gs.Fill = 0;
                    break;
                case "BT":
                    tm = tlm = Mat.Identity;
                    break;
                case "BMC" or "BDC":
                {
                    var props = op.Name == "BDC" && op.Operands.Count >= 2 ? op.Operands[1] : null;
                    var has = props is { Kind: CKind.Dict } d ? d["ActualText"] is not null
                        : props is { Kind: CKind.Name } n && PdfObj.Dict(PdfObj.Dict(resources?.Elements["/Properties"])?.Elements["/" + n.Name]) is { } pd && pd.Elements.ContainsKey("/ActualText");
                    if (marked.Count < 256)
                    {
                        marked.Push(has);
                        if (has) actualText++;
                    }
                    break;
                }
                case "EMC":
                    if (marked.Count > 0 && marked.Pop()) actualText--;
                    break;
                case "Tf" when op.Operands.Count >= 2:
                    gs.FontKey = op.Operands[0].Name;
                    gs.Font = PdfObj.Dict(PdfObj.Dict(resources?.Elements["/Font"])?.Elements["/" + gs.FontKey]) is { } fd ? TextFont.For(fd) : null;
                    gs.Size = op.N(1);
                    break;
                case "Tc": gs.Tc = op.N(0); break;
                case "Tw": gs.Tw = op.N(0); break;
                case "Tz": gs.Th = op.N(0) / 100; break;
                case "TL": gs.Tl = op.N(0); break;
                case "Ts": gs.Rise = op.N(0); break;
                case "Tr": gs.Render = (int)op.N(0); break;
                case "Td" or "TD" when op.Operands.Count >= 2:
                    if (op.Name == "TD") gs.Tl = -op.N(1);
                    tlm = new Mat(1, 0, 0, 1, op.N(0), op.N(1)).Times(tlm);
                    tm = tlm;
                    break;
                case "Tm" when op.Operands.Count >= 6:
                    tm = tlm = new Mat(op.N(0), op.N(1), op.N(2), op.N(3), op.N(4), op.N(5));
                    break;
                case "T*":
                    tlm = new Mat(1, 0, 0, 1, 0, -gs.Tl).Times(tlm);
                    tm = tlm;
                    break;
                case "Tj" or "TJ" or "'" or "\"":
                {
                    if (op.Name is "'" or "\"")
                    {
                        if (op.Name == "\"")
                        {
                            gs.Tw = op.N(0);
                            gs.Tc = op.N(1);
                        }
                        tlm = new Mat(1, 0, 0, 1, 0, -gs.Tl).Times(tlm);
                        tm = tlm;
                    }
                    var arg = op.Operands.Count > 0 ? op.Operands[^1] : null;
                    if (arg is null || (op.Name == "TJ" ? arg.Kind != CKind.Array : arg.Kind != CKind.String)) break;
                    tm = ShowText(w, page, pageIndex, id, op, arg, gs, tm, tlm,
                        blocked ?? (actualText > 0 ? "it carries replacement text for copying and reading aloud (ActualText) that an edit would leave wrong" : null));
                    break;
                }
                case "Do" when op.Operands.Count > 0 && op.Operands[0].Kind == CKind.Name:
                {
                    var xobj = PdfObj.Dict(PdfObj.Dict(resources?.Elements["/XObject"])?.Elements["/" + op.Operands[0].Name]);
                    if (xobj is null) break;
                    var sub = PdfObj.NameOf(xobj, "/Subtype");
                    if (sub == "/Image") AddImage(w, page, pageIndex, id, gs.Ctm, false, blocked);
                    else if (sub == "/Form" && depth < MaxDepth)
                    {
                        var m = PdfObj.Array(xobj.Elements["/Matrix"]) is { Elements.Count: 6 } a
                            ? new Mat(PdfObj.Num(a, 0), PdfObj.Num(a, 1), PdfObj.Num(a, 2), PdfObj.Num(a, 3), PdfObj.Num(a, 4), PdfObj.Num(a, 5))
                            : Mat.Identity;
                        var inner = gs.Clone();
                        inner.Ctm = m.Times(gs.Ctm);
                        Run(w, page, pageIndex, ContentLexer.Parse(PdfObj.StreamBytes(xobj), cancel), PdfObj.Dict(xobj.Elements["/Resources"]) ?? resources, inner, depth + 1,
                            "it is part of a form XObject (a drawing the page reuses), and only the page's own content can be edited in this version", cancel);
                    }
                    break;
                }
                case "BI":
                    AddImage(w, page, pageIndex, id, gs.Ctm, true, blocked ?? (op.Broken ? "where its data ends can't be told for sure, so changing it could damage the page" : null));
                    break;
            }
        }
    }

    private static int Gray(double g) => Rgb(g, g, g);

    private static int Rgb(double r, double g, double b)
    {
        static int C(double v) => (int)Math.Round(Math.Clamp(v, 0, 1) * 255);
        return C(r) << 16 | C(g) << 8 | C(b);
    }

    private static void AddImage(Walked w, PdfPage page, int pageIndex, int id, Mat ctm, bool inline, string? blocked)
    {
        var box = BoxOf(page, ctm, 0, 0, 1, 1);
        if (box.Width <= 0 && box.Height <= 0) return;
        var turned = Math.Abs(ctm.B) > 1e-6 && Math.Abs(ctm.A) > 1e-6 || Math.Abs(ctm.C) > 1e-6 && Math.Abs(ctm.D) > 1e-6;
        w.Images.Add(new PageImage(pageIndex, id, box, inline, blocked) { Turned = turned });
        if (blocked is null) w.ImageCtm[id] = ctm;
    }

    /// <summary>The page-space bounding box of a rectangle in a coordinate system.</summary>
    private static RectD BoxOf(PdfPage page, Mat m, double x1, double y1, double x2, double y2)
    {
        double minX = double.MaxValue, minY = double.MaxValue, maxX = double.MinValue, maxY = double.MinValue;
        foreach (var (x, y) in new[] { (x1, y1), (x2, y1), (x2, y2), (x1, y2) })
        {
            var (ux, uy) = m.Apply(x, y);
            var (px, py) = PdfObj.ToPage(page, ux, uy);
            minX = Math.Min(minX, px);
            minY = Math.Min(minY, py);
            maxX = Math.Max(maxX, px);
            maxY = Math.Max(maxY, py);
        }
        return RectD.FromEdges(minX, minY, maxX, maxY);
    }

    /// <summary>Records a text-showing operator as a run and returns the text matrix after it.</summary>
    private static Mat ShowText(Walked w, PdfPage page, int pageIndex, int id, COp op, CObj arg, GState gs, Mat tm, Mat tlm, string? blocked)
    {
        var font = gs.Font;
        var items = new List<RunItem>();
        var hex = false;
        double adv = 0, gaps = 0, end = 0; // end: where the last glyph's ink ends (before its spacing)
        var gapCount = 0;
        var fs = gs.Size;
        void Glyphs(CObj s)
        {
            hex |= s.Hex;
            if (font is null)
            {
                foreach (var b in s.Bytes)
                {
                    items.Add(new RunItem(b, 0, ((char)b).ToString(), false));
                    end = adv + 0.5 * fs * gs.Th;
                    adv += (0.5 * fs + gs.Tc) * gs.Th;
                }
                return;
            }
            foreach (var g in font.Decode(s.Bytes))
            {
                items.Add(new RunItem(g.Code, 0, g.Text, false));
                end = adv + g.Width * fs * gs.Th;
                adv += (g.Width * fs + gs.Tc + (!font.TwoByte && g.Code == 32 ? gs.Tw : 0)) * gs.Th;
            }
        }
        if (arg.Kind == CKind.String) Glyphs(arg);
        else
        {
            foreach (var el in arg.Items)
            {
                if (el.Kind == CKind.String) Glyphs(el);
                else if (el.Kind == CKind.Number)
                {
                    // A wide gap between words shows (and copies) as a space.
                    var space = -el.Num > 180 && items.Count > 0 && items[^1].Text is { } prev && !prev.EndsWith(' ');
                    items.Add(new RunItem(0, el.Num, space ? " " : "", true));
                    adv -= el.Num / 1000 * fs * gs.Th;
                    if (space)
                    {
                        gaps += -el.Num / 1000;
                        gapCount++;
                    }
                }
            }
            // An adjustment after the last glyph moves what follows: it isn't part of the text.
            for (var k = items.Count - 1; k >= 0 && items[k].IsNumber; k--) items[k] = items[k] with { Text = "", Trailing = true };
        }

        var trm = new Mat(1, 0, 0, 1, 0, gs.Rise).Times(tm).Times(gs.Ctm);
        var asc = (font?.Ascent ?? 0.8) * fs;
        var desc = (font?.Descent ?? -0.2) * fs;
        var box = BoxOf(page, trm, 0, desc, end, asc);
        var (bx0, by0) = Project(page, trm, 0, 0);
        var (bx1, by1) = Project(page, trm, 1, 0);
        var (vx0, vy0) = Project(page, trm, 0, 1);
        var scale = Math.Sqrt((bx1 - bx0) * (bx1 - bx0) + (by1 - by0) * (by1 - by0));
        var vscale = Math.Sqrt((vx0 - bx0) * (vx0 - bx0) + (vy0 - by0) * (vy0 - by0));
        var angle = Math.Atan2(by1 - by0, bx1 - bx0) * 180 / Math.PI;
        var text = string.Concat(items.Select(i => i.Text));

        var why = blocked;
        if (why is null)
        {
            if (font is null) why = "its font is missing from the page";
            else if (font.Blocked is { } fb) why = fb;
            else if (gs.Render is 3 or 7) why = "it is invisible text (recognized text over a scan)";
            else if (text.Contains('�')) why = "some of its characters can't be read";
            else if (text.Trim().Length == 0) why = "it is only spaces";
        }
        var run = new TextRun(pageIndex, id, text, box, Math.Abs(fs) * vscale, font?.Name ?? gs.FontKey, font?.Bold ?? false, font?.Italic ?? false,
            gs.Fill, angle, why)
        {
            Font = font,
            Scale = scale,
            Size = fs,
            CharSpacing = gs.Tc,
            WordSpacing = gs.Tw,
            HScale = gs.Th,
            GapEms = gapCount > 0 ? gaps / gapCount : 0.25,
            OldWidth = end * scale,
            Origin = new PointD(bx0, by0),
        };
        var info = new RunInfo(items, hex) { Tm = tm, TlmAfter = tlm, Ctm = gs.Ctm, Rise = gs.Rise, Advance = adv };
        if (text.Length > 0) w.TextRuns.Add(run with { Info = why is null ? info : null });
        if (why is null) w.Runs[id] = info;
        return new Mat(1, 0, 0, 1, adv, 0).Times(tm);
    }

    private static (double X, double Y) Project(PdfPage page, Mat m, double x, double y)
    {
        var (ux, uy) = m.Apply(x, y);
        return PdfObj.ToPage(page, ux, uy);
    }
}
