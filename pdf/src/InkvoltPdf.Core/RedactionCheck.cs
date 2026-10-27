using System.Security.Cryptography;
using MuPDFCore;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>What <see cref="RedactionCheck"/> finds: something of what was redacted (or covered) that can still be recovered.</summary>
public enum RedactionLeak
{
    /// <summary>Text still in the page under a box, a highlight or other cover, or drawn so it doesn't show (black on black,
    /// white on white): it can be selected, searched and copied.</summary>
    CoveredText,

    /// <summary>A picture or drawing still under a dark box: taking the box away shows it.</summary>
    CoveredContent,

    /// <summary>A redaction mark (a Redact annotation) that was never applied: what it marks is still there.</summary>
    UnappliedMark,

    /// <summary>Text right beside a box keeps its original positions, so the width of what was removed can be measured.</summary>
    GlyphSpacing,

    /// <summary>A redacted value is still in the text of a page.</summary>
    PageText,

    /// <summary>Text in a page's content that doesn't show: outside the page, in a hidden layer, clipped away, invisible.</summary>
    HiddenText,

    /// <summary>Hidden layers, hidden comments or hidden form fields: in the file, not shown.</summary>
    HiddenContent,

    /// <summary>A comment's text, author, subject or appearance.</summary>
    Annotation,

    /// <summary>A form field's value, default, choices, tooltip or appearance (also an XFA form's copy of the values).</summary>
    FormField,

    Bookmark,

    /// <summary>Document properties (the Info dictionary) or XMP metadata.</summary>
    Metadata,

    /// <summary>An attached file: its name, description or contents.</summary>
    Attachment,

    /// <summary>The structure tree (tags): alternate text, actual text, titles.</summary>
    StructureTree,

    /// <summary>An earlier version of the file, kept by an incremental save (signing, appending).</summary>
    EarlierRevision,

    /// <summary>Other data in the file: objects nothing uses, scripts, bytes outside the objects.</summary>
    FileData,

    /// <summary>A redacted area that still shows content, or still holds the original picture unchanged.</summary>
    AreaNotRemoved,
}

/// <summary>How a finding can be fixed with what Inkvolt PDF already does.</summary>
public enum RedactionFix
{
    None,
    /// <summary>Redact its area (<see cref="Redaction.Apply"/>: the page becomes an image).</summary>
    Redact,
    /// <summary>Sanitize Document with <see cref="RedactionFinding.Sanitize"/>.</summary>
    Sanitize,
    /// <summary>Rewrite the file as a single version (earlier versions and unused objects go).</summary>
    Rewrite,
}

/// <summary>One thing the check found.</summary>
/// <param name="Where">Where it is, in words ("Page 2", "Bookmark", "Earlier version 1 of the file").</param>
/// <param name="Text">What was found (the text, or what is wrong).</param>
public sealed record RedactionFinding(RedactionLeak Kind, string Where, string Text)
{
    /// <summary>Its page (index), or -1.</summary>
    public int Page { get; init; } = -1;

    /// <summary>Its area on <see cref="Page"/> (page space), when it has one: what a fix redacts. Outside the page (text that
    /// doesn't show): the redaction draws the page again as an image, without it, and blacks out nothing.</summary>
    public RectD Box { get; init; }

    /// <summary>The kind of content Sanitize Document removes it with.</summary>
    public SanitizeItem? Sanitize { get; init; }

    /// <summary>Rewriting the file as a single version removes it.</summary>
    public bool Rewrite { get; init; }

    public RedactionFix Fix =>
        Sanitize is not null ? RedactionFix.Sanitize
        : Rewrite ? RedactionFix.Rewrite
        : Page >= 0 && !Box.IsEmpty && Kind is RedactionLeak.CoveredText or RedactionLeak.CoveredContent or RedactionLeak.UnappliedMark
            or RedactionLeak.GlyphSpacing or RedactionLeak.PageText or RedactionLeak.HiddenText or RedactionLeak.AreaNotRemoved ? RedactionFix.Redact
        : RedactionFix.None;
}

/// <summary>What the check knows about the redaction it checks (nothing, for a file received from someone else).</summary>
public sealed record RedactionCheckOptions
{
    /// <summary>What was redacted (text): looked for everywhere in the file. See <see cref="RedactionCheck.ValuesUnder"/>.</summary>
    public IReadOnlyList<string> Values { get; init; } = [];

    /// <summary>The areas redacted in this file (page index → areas, page space): each must show nothing of what was there.</summary>
    public IReadOnlyDictionary<int, IReadOnlyList<RectD>>? Areas { get; init; }

    /// <summary>The document before it was redacted (opened with the same password): none of its pictures may be under a
    /// redacted area unchanged.</summary>
    public byte[]? Original { get; init; }
}

/// <param name="Values">The text looked for: <see cref="RedactionCheckOptions.Values"/> and what was found under covers.</param>
/// <param name="Notes">What couldn't be checked, and why.</param>
public sealed record RedactionCheckReport(IReadOnlyList<RedactionFinding> Findings, IReadOnlyList<string> Values, IReadOnlyList<string> Notes)
{
    public bool IsClean => Findings.Count == 0;

    /// <summary>Some findings can be fixed (<see cref="RedactionCheck.Fix"/>).</summary>
    public bool CanFix => Findings.Any(f => f.Fix != RedactionFix.None);

    /// <summary>"3 things found: text under a cover (2), bookmark (1).", or that nothing was found.</summary>
    public string Summary => IsClean
        ? "Nothing of what was redacted was found in the file."
        : $"{(Findings.Count == 1 ? "1 thing" : $"{Findings.Count} things")} found: " +
          string.Join(", ", Findings.GroupBy(f => f.Kind).OrderBy(g => g.Key).Select(g => $"{char.ToLowerInvariant(RedactionCheck.Name(g.Key)[0])}{RedactionCheck.Name(g.Key)[1..]} ({g.Count()})")) + ".";
}

/// <summary>
/// Redaction check: verifies that nothing recoverable is left of what was redacted, in a document just redacted (with
/// what was redacted: <see cref="RedactionCheckOptions"/>) or in any PDF. It looks for
/// <list type="bullet">
/// <item>covers that hide nothing for good: text under dark boxes, highlights and other content, or drawn in the color
/// behind it (each character is rendered: one that doesn't change a pixel doesn't show); pictures and drawings under dark
/// boxes (the page is drawn again without the box); Redact annotations never applied; text beside a box whose positions
/// give away the removed width;</item>
/// <item>the redacted text anywhere else: page text, text in the content that doesn't show (hidden layers, off the page),
/// comments and their appearances, form fields (and XFA), bookmarks, document properties and XMP, attached files (also
/// inside zipped Office files and PDFs), the structure tree, scripts, objects nothing uses, earlier versions kept by
/// incremental saves (each version opened on its own, streams decompressed), and the file's raw bytes;</item>
/// <item>redacted areas that still show something, or still hold the original picture; hidden layers and hidden comments.</item>
/// </list>
/// Text that an earlier version showed and the current one no longer does is reported too (it was removed by appending).
/// What can be fixed with Inkvolt PDF's own means says how (<see cref="RedactionFinding.Fix"/>; <see cref="Fix"/>).
/// </summary>
public static partial class RedactionCheck
{
    /// <summary>Pixels per point for the visibility test of every character (confirmed at <see cref="ConfirmScale"/>).</summary>
    private const double CharScale = 0.5, ConfirmScale = 2;

    /// <summary>Most covers per page drawn again without them (the darkest-box pages of a large file stay bounded).</summary>
    private const int MaxCoversPerPage = 64;

    /// <summary>Most values looked for; earlier versions examined.</summary>
    private const int MaxValues = 500, MaxRevisions = 32;

    /// <summary>A fill this dark (luminance 0-1) counts as a redaction box.</summary>
    private const double DarkLuminance = 0.25;

    /// <summary>An area just outside the page: redacting it only draws the page again as an image.</summary>
    internal static readonly RectD OffPage = new(-4, -4, 2, 2);

    public static string Name(RedactionLeak kind) => kind switch
    {
        RedactionLeak.CoveredText => "Text under a cover",
        RedactionLeak.CoveredContent => "Picture or drawing under a box",
        RedactionLeak.UnappliedMark => "Redaction mark not applied",
        RedactionLeak.GlyphSpacing => "Spacing that gives away a width",
        RedactionLeak.PageText => "Text on a page",
        RedactionLeak.HiddenText => "Text that doesn't show",
        RedactionLeak.HiddenContent => "Hidden content",
        RedactionLeak.Annotation => "Comment",
        RedactionLeak.FormField => "Form field",
        RedactionLeak.Bookmark => "Bookmark",
        RedactionLeak.Metadata => "Metadata",
        RedactionLeak.Attachment => "Attached file",
        RedactionLeak.StructureTree => "Tags (alternate text)",
        RedactionLeak.EarlierRevision => "Earlier version",
        RedactionLeak.FileData => "Other data in the file",
        RedactionLeak.AreaNotRemoved => "Redacted area",
        _ => kind.ToString(),
    };

    /// <summary>
    /// The text under areas about to be redacted (read before applying them): each line's characters whose middle is
    /// inside an area, as one value. These are what <see cref="RedactionCheckOptions.Values"/> looks for afterwards.
    /// </summary>
    public static List<string> ValuesUnder(PdfEngine engine, IReadOnlyDictionary<int, IReadOnlyList<RectD>> areas, CancellationToken cancel = default)
    {
        var values = new List<string>();
        foreach (var (page, rects) in areas.OrderBy(kv => kv.Key))
        {
            if (page < 0 || page >= engine.PageCount || rects.All(r => r.IsEmpty)) continue;
            var text = engine.GetText(page, cache: false, cancel);
            foreach (var (start, end) in Runs(text, i => rects.Any(r => !r.IsEmpty && r.Contains(text.BoxAt(i).CenterX, text.BoxAt(i).CenterY))))
                values.Add(text.Text[start..end]);
        }
        return [.. Clean(values)];
    }

    /// <summary>Checks the document. Nothing is changed.</summary>
    /// <param name="progress">(steps done, steps): pages read, then pages drawn, then earlier versions.</param>
    /// <exception cref="PasswordRequiredException">The password is missing or wrong.</exception>
    public static RedactionCheckReport Run(byte[] data, string? password, RedactionCheckOptions? options = null,
        IProgress<(int Done, int Total)>? progress = null, CancellationToken cancel = default) =>
        new Check(data, password, options ?? new(), progress, cancel).Run();

    /// <summary>The areas to redact to fix the findings that a redaction fixes, per page.</summary>
    public static Dictionary<int, IReadOnlyList<RectD>> RedactAreas(IEnumerable<RedactionFinding> findings) =>
        findings.Where(f => f.Fix == RedactionFix.Redact).GroupBy(f => f.Page)
            .ToDictionary(g => g.Key, g => (IReadOnlyList<RectD>)[.. g.Select(f => f.Box.Inflate(0.5)).Distinct()]);

    /// <summary>What Sanitize Document removes to fix the findings it fixes.</summary>
    public static HashSet<SanitizeItem> SanitizeItems(IEnumerable<RedactionFinding> findings) =>
        [.. findings.Where(f => f.Fix == RedactionFix.Sanitize).Select(f => f.Sanitize!.Value)];

    /// <summary>
    /// Fixes what can be fixed: redacts the areas of covered and leftover text (<see cref="Redaction.Apply"/>), then
    /// sanitizes the kinds that hold leftovers, which also rewrites the file as one version (earlier versions and unused
    /// objects go). Findings without a fix are left as they are. A signed file needs the rewrite allowed
    /// (<see cref="SignedEdits.Run"/>).
    /// </summary>
    public static byte[] Fix(byte[] data, string? password, IEnumerable<RedactionFinding> findings)
    {
        var list = findings.ToList();
        var areas = RedactAreas(list);
        if (areas.Count > 0) data = Redaction.Apply(data, password, areas);
        var items = SanitizeItems(list);
        if (items.Count > 0 || list.Any(f => f.Fix == RedactionFix.Rewrite)) data = Sanitizer.Sanitize(data, password, items).Data;
        return data;
    }

    private static double Luminance(double r, double g, double b) => 0.3 * r + 0.59 * g + 0.11 * b;

    /// <summary>Runs of characters (one line at a most) that <paramref name="pick"/> chooses, spaces between chosen ones included, trimmed.</summary>
    private static IEnumerable<(int Start, int End)> Runs(PageText text, Func<int, bool> pick)
    {
        var s = text.Text;
        var start = -1;
        var last = -1;
        for (var i = 0; i <= s.Length; i++)
        {
            var end = i == s.Length || s[i] == '\n';
            if (!end && char.IsWhiteSpace(s[i])) continue;
            var chosen = !end && pick(i);
            if (chosen)
            {
                if (start < 0) start = i;
                last = i;
                continue;
            }
            if (start >= 0) yield return (start, last + 1);
            start = -1;
        }
    }

    /// <summary>Values worth looking for: trimmed, spaces collapsed, at least three letters or digits, each once.</summary>
    private static IEnumerable<string> Clean(IEnumerable<string> values) =>
        values.Select(v => string.Join(' ', v.Replace("­", "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)))
            .Where(v => v.Count(char.IsLetterOrDigit) >= 3)
            .Distinct(StringComparer.OrdinalIgnoreCase);

    // ───────────────────────────── one run of the check ─────────────────────────────

    /// <summary>
    /// What a page draws that can hide something (dark boxes, dark comments, Redact marks), and what a cover can hide
    /// besides text: pictures and shadings, and paths that aren't white, each with its place in the drawing order.
    /// </summary>
    private sealed class PageScan
    {
        public readonly List<Cover> Covers = [];
        public readonly List<(RectD Box, PdfDictionary? Image)> Pictures = [];
        public readonly List<(RectD Box, int Order, bool Picture)> Drawn = [];
        public readonly List<RectD> LightBoxes = [];
        public readonly List<List<RectD>> Marks = [];

        /// <summary>Something other than text was drawn under the cover before it: a picture reaching into it, or a path
        /// mostly inside it (not a rule or a frame that just crosses it).</summary>
        public bool AnythingUnder(Cover c) => Drawn.Any(d => d.Order < c.Order && c.Box.Intersect(d.Box) is var i && !i.IsEmpty
            && (d.Picture ? i.Width * i.Height > 1 : i.Width * i.Height >= 0.5 * Math.Max(0.01, d.Box.Width * d.Box.Height)));
    }

    /// <summary>A dark box in the content (<see cref="Form"/> null: the page's own; its fill operator ends at <see cref="OpEnd"/>)
    /// or a dark comment (<see cref="Annot"/>: its index in /Annots, drawn after the content).</summary>
    private sealed record Cover(RectD Box, bool RectLike, PdfObjectID? Form, int OpEnd, int OpLength, int Order, int Annot = -1)
    {
        public bool InForm => Form is not null;
    }

    private sealed partial class Check(byte[] data, string? password, RedactionCheckOptions options,
        IProgress<(int Done, int Total)>? progress, CancellationToken cancel)
    {
        private readonly List<RedactionFinding> _findings = [];
        private readonly List<string> _notes = [];
        private readonly List<string> _found = []; // values found under covers and marks
        private PageText[] _texts = [];
        private HashSet<int>[] _reported = []; // per page: characters already reported
        private int _done, _total;

        private void Step(int n = 1)
        {
            _done += n;
            progress?.Report((Math.Min(_done, _total), _total));
        }

        private void Add(RedactionFinding f)
        {
            if (!_findings.Any(o => o.Kind == f.Kind && o.Page == f.Page && o.Where == f.Where && o.Text == f.Text && o.Box == f.Box)) _findings.Add(f);
        }

        public RedactionCheckReport Run()
        {
            using var engine = PdfEngine.Open(data, InputFileTypes.PDF, password);
            using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import, "This PDF can't be checked");
            var pages = engine.PageCount;
            var revisions = Revisions(data);
            _total = pages * 2 + Math.Min(revisions.Count, MaxRevisions);
            _texts = new PageText[pages];
            _reported = [.. Enumerable.Range(0, pages).Select(_ => new HashSet<int>())];

            // The pages' text is read on another thread (the engine reads text in a context of its own) while the pages are
            // walked and drawn here.
            var ready = new SemaphoreSlim(0);
            var reader = Task.Run(() =>
            {
                for (var p = 0; p < pages; p++)
                {
                    _texts[p] = engine.GetText(p, cache: false, cancel);
                    ready.Release();
                }
            }, cancel);
            var scans = new PageScan[pages];
            for (var p = 0; p < pages; p++)
            {
                cancel.ThrowIfCancellationRequested();
                scans[p] = p < doc.PageCount ? ScanPage(doc, p) : new PageScan();
                Step();
            }
            var hidden = new List<(int Start, int End)>[pages];
            for (var p = 0; p < pages; p++)
            {
                while (!ready.Wait(50, cancel))
                    if (reader.IsFaulted || reader.IsCanceled) reader.GetAwaiter().GetResult();
                hidden[p] = HiddenChars(engine, p, scans[p]);
                Marks(p, scans[p]);
                Step();
            }
            reader.GetAwaiter().GetResult();
            Covers(engine, scans);
            for (var p = 0; p < pages; p++) HiddenRuns(p, hidden[p], scans[p]);
            if (options.Areas is { Count: > 0 } areas) Areas(engine, doc, scans, areas);
            HiddenContent(doc);

            var values = Clean(options.Values.Concat(_found)).Take(MaxValues).ToList();
            var matcher = new ValueMatcher(values);
            if (!matcher.IsEmpty)
            {
                for (var p = 0; p < pages; p++) PageValues(p, matcher);
                var inFile = Objects(doc, matcher);
                EarlierVersions(engine, matcher, inFile, revisions);
                RawBytes(doc, matcher, inFile);
            }
            else EarlierVersions(engine, null, [], revisions);

            var order = _findings.Select((f, i) => (f, i)).OrderBy(x => x.f.Page < 0 ? int.MaxValue : x.f.Page).ThenBy(x => x.f.Kind).ThenBy(x => x.i);
            return new RedactionCheckReport([.. order.Select(x => x.f)], values, _notes);
        }

        // ───────────────────────────── covers ─────────────────────────────

        /// <summary>The page's dark boxes, dark comments, Redact marks and pictures.</summary>
        private PageScan ScanPage(PdfDocument doc, int index)
        {
            var scan = new PageScan();
            var page = doc.Pages[index];
            try
            {
                new Walker(page, scan, cancel).Run(ContentEditor.ContentBytes(page), PdfObj.Dict(page.Elements["/Resources"]), ContentEditor.Mat.Identity, null, 0);
            }
            catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or InvalidCastException or IndexOutOfRangeException or NotSupportedException)
            {
                _notes.Add($"Page {index + 1}: part of its content couldn't be read, so boxes on it may have been missed.");
            }
            if (PdfObj.Array(page.Elements["/Annots"]) is not { } annots) return scan;
            for (var i = 0; i < annots.Elements.Count; i++)
            {
                if (PdfObj.Dict(annots.Elements[i]) is not { } a || PdfObj.Array(a.Elements["/Rect"]) is not { } r) continue;
                if ((PdfObj.Int(a.Elements["/F"]) ?? 0) is var flags && (flags & 2) != 0) continue; // hidden: reported with hidden content
                var rect = PdfObj.RectToPage(page, r);
                var subtype = PdfObj.NameOf(a, "/Subtype");
                if (subtype == "/Redact")
                {
                    var quads = Quads(page, a);
                    scan.Marks.Add(quads.Count > 0 ? quads : [rect]);
                }
                else if (subtype is "/Square" or "/Circle" or "/Polygon" or "/Highlight" or "/Ink" or "/FreeText" or "/Squiggly" or "/StrikeOut" or "/Underline" or "/PolyLine"
                         && (IsDark(PdfObj.Array(a.Elements["/IC"])) || IsDark(PdfObj.Array(a.Elements["/C"]))) && !rect.IsEmpty)
                    scan.Covers.Add(new Cover(rect, subtype is "/Square" or "/Highlight", null, 0, 0, int.MaxValue, i));
            }
            return scan;
        }

        private static List<RectD> Quads(PdfPage page, PdfDictionary annot)
        {
            var list = new List<RectD>();
            if (PdfObj.Array(annot.Elements["/QuadPoints"]) is not { } q) return list;
            for (var i = 0; i + 7 < q.Elements.Count; i += 8)
            {
                double l = double.MaxValue, t = double.MaxValue, r = double.MinValue, b = double.MinValue;
                for (var k = 0; k < 8; k += 2)
                {
                    var (x, y) = PdfObj.ToPage(page, PdfObj.Num(q, i + k), PdfObj.Num(q, i + k + 1));
                    (l, r, t, b) = (Math.Min(l, x), Math.Max(r, x), Math.Min(t, y), Math.Max(b, y));
                }
                if (r - l > 0.1 && b - t > 0.1) list.Add(RectD.FromEdges(l, t, r, b));
            }
            return list;
        }

        /// <summary>A color array (gray, RGB or CMYK) dark enough to hide what is under it.</summary>
        private static bool IsDark(PdfArray? c) => c?.Elements.Count switch
        {
            1 => PdfObj.Num(c, 0) <= DarkLuminance,
            3 => Luminance(PdfObj.Num(c, 0), PdfObj.Num(c, 1), PdfObj.Num(c, 2)) <= DarkLuminance,
            4 => Luminance((1 - PdfObj.Num(c, 0)) * (1 - PdfObj.Num(c, 3)), (1 - PdfObj.Num(c, 1)) * (1 - PdfObj.Num(c, 3)), (1 - PdfObj.Num(c, 2)) * (1 - PdfObj.Num(c, 3))) <= DarkLuminance,
            _ => false,
        };

        /// <summary>
        /// Characters that don't show: each character's box is looked at in the page as drawn (with its comments); one whose
        /// pixels are all the same color draws nothing visible there (it is covered, or in the color behind it). The first
        /// look is small and takes the box with its edge pixels; characters that pass it, and those under a cover, a white
        /// box or a picture smaller than the page, are looked at again larger, inside their box only (a cover fitted to the
        /// glyphs must not let the page around it count as ink). Characters outside the page are reported here too.
        /// </summary>
        private List<(int Start, int End)> HiddenChars(PdfEngine engine, int p, PageScan scan)
        {
            var text = _texts[p];
            var g = engine.GetPage(p);
            var page = new RectD(0, 0, g.Width, g.Height);
            var hidden = new HashSet<int>();
            var offPage = new HashSet<int>();
            var candidates = new List<int>();
            for (var i = 0; i < text.Text.Length; i++)
            {
                if (!Visible(text.Text[i])) continue;
                var b = text.BoxAt(i);
                if (!page.Contains(b.CenterX, b.CenterY)) offPage.Add(i);
                else candidates.Add(i);
            }
            if (candidates.Count > 0)
            {
                var pixels = Math.Max(1, g.Width * g.Height);
                var scale = Math.Min(CharScale, Math.Sqrt(8_000_000 / pixels));
                var img = engine.Render(p, scale, cancel: cancel);
                var over = scan.Covers.Select(c => c.Box).Concat(scan.LightBoxes).Concat(scan.Pictures.Select(i => i.Box))
                    .Where(b => b.Width * b.Height < 0.5 * pixels).ToList();
                var maybe = candidates.Where(i => text.BoxAt(i) is var b && (over.Any(o => o.Contains(b.CenterX, b.CenterY)) || Uniform(img, b, scale, default, inner: false))).ToList();
                if (maybe.Count > 0)
                {
                    var big = Math.Min(ConfirmScale, Math.Sqrt(30_000_000 / pixels));
                    var close = engine.Render(p, big, cancel: cancel);
                    foreach (var i in maybe)
                        if (Uniform(close, text.BoxAt(i), big, default, inner: true)) hidden.Add(i);
                }
            }
            foreach (var (start, end) in Runs(text, offPage.Contains))
            {
                // Its box is outside the page: redacting it draws the page again as an image, without it, and blacks out nothing.
                var box = text.GetRects(start, end).Aggregate(default(RectD), (a, r) => a.Union(r));
                Add(new RedactionFinding(RedactionLeak.HiddenText, $"Page {p + 1}, outside the visible page", text.Text[start..end]) { Page = p, Box = box });
                _found.Add(text.Text[start..end]);
                for (var i = start; i < end; i++) _reported[p].Add(i);
            }
            return [.. Runs(text, hidden.Contains)];
        }

        private static bool Visible(char c) => !char.IsWhiteSpace(c) && !char.IsControl(c)
            && char.GetUnicodeCategory(c) is not (System.Globalization.UnicodeCategory.NonSpacingMark or System.Globalization.UnicodeCategory.Format);

        /// <summary>The pixels of <paramref name="box"/> (page points) in an image of <paramref name="origin"/> at <paramref name="scale"/>
        /// are all one color: those it touches, or (<paramref name="inner"/>) those wholly inside it, else the middle one.</summary>
        private static bool Uniform(RenderedImage img, RectD box, double scale, RectD origin, bool inner)
        {
            double l = (box.X - origin.X) * scale, rt = (box.Right - origin.X) * scale, t = (box.Y - origin.Y) * scale, b0 = (box.Bottom - origin.Y) * scale;
            int x0 = (int)(inner ? Math.Ceiling(l) : Math.Floor(l)), x1 = (int)(inner ? Math.Floor(rt) : Math.Ceiling(rt));
            int y0 = (int)(inner ? Math.Ceiling(t) : Math.Floor(t)), y1 = (int)(inner ? Math.Floor(b0) : Math.Ceiling(b0));
            if (x1 <= x0) x0 = (x1 = (int)Math.Floor((l + rt) / 2) + 1) - 1;
            if (y1 <= y0) y0 = (y1 = (int)Math.Floor((t + b0) / 2) + 1) - 1;
            (x0, x1, y0, y1) = (Math.Clamp(x0, 0, img.Width), Math.Clamp(x1, 0, img.Width), Math.Clamp(y0, 0, img.Height), Math.Clamp(y1, 0, img.Height));
            if (x1 <= x0 || y1 <= y0) return false;
            int min0 = 255, min1 = 255, min2 = 255, max0 = 0, max1 = 0, max2 = 0;
            for (var y = y0; y < y1; y++)
            {
                var row = y * img.Stride;
                for (var x = x0; x < x1; x++)
                {
                    var o = row + x * 3;
                    int b = img.Pixels[o], gg = img.Pixels[o + 1], r = img.Pixels[o + 2];
                    if (b < min0) min0 = b;
                    if (b > max0) max0 = b;
                    if (gg < min1) min1 = gg;
                    if (gg > max1) max1 = gg;
                    if (r < min2) min2 = r;
                    if (r > max2) max2 = r;
                }
            }
            return max0 - min0 <= 24 && max1 - min1 <= 24 && max2 - min2 <= 24;
        }

        /// <summary>Redact marks never applied, with the text under them.</summary>
        private void Marks(int p, PageScan scan)
        {
            var text = _texts[p];
            foreach (var rects in scan.Marks)
            {
                var runs = Runs(text, i => rects.Any(r => r.Contains(text.BoxAt(i).CenterX, text.BoxAt(i).CenterY))).ToList();
                var words = string.Join(" ", runs.Select(r => text.Text[r.Start..r.End]));
                var box = rects.Aggregate(default(RectD), (a, r) => a.Union(r));
                Add(new RedactionFinding(RedactionLeak.UnappliedMark, $"Page {p + 1}", words.Length > 0 ? words : "(no text under it: what it covers is still in the page)")
                    { Page = p, Box = box });
                foreach (var (s, e) in runs)
                {
                    _found.Add(text.Text[s..e]);
                    for (var i = s; i < e; i++) _reported[p].Add(i);
                }
            }
        }

        /// <summary>
        /// Covers drawn over pictures or drawings: the page is drawn again without its dark boxes and dark comments (a copy,
        /// in memory), and a cover that hides something (pixels that show without it and are the cover's color with it) is
        /// reported, with the text under it if there is any (text under a cover alone is found character by character). A box
        /// with nothing under it but text right beside it on the same line gives the removed width away.
        /// </summary>
        private void Covers(PdfEngine engine, PageScan[] scans)
        {
            foreach (var scan in scans)
                if (scan.Covers.Count > MaxCoversPerPage) scan.Covers.RemoveRange(MaxCoversPerPage, scan.Covers.Count - MaxCoversPerPage);
            var pages = Enumerable.Range(0, scans.Length).Where(p => scans[p].Covers.Any(scans[p].AnythingUnder)).ToList();
            foreach (var p in Enumerable.Range(0, scans.Length).Except(pages)) Beside(p, scans[p]);
            if (pages.Count == 0) return;

            byte[] bare;
            try
            {
                bare = WithoutCovers(scans, pages);
            }
            catch (Exception ex) when (ex is InvalidOperationException or PdfSharp.PdfSharpException or ArgumentException or NotSupportedException or NullReferenceException)
            {
                _notes.Add("What is under the dark boxes couldn't be drawn (the file can't be copied without them), so only text under them was looked for.");
                foreach (var p in pages) Beside(p, scans[p]);
                return;
            }
            using var without = PdfEngine.Open(bare, InputFileTypes.PDF, null);
            foreach (var p in pages)
            {
                cancel.ThrowIfCancellationRequested();
                var g = engine.GetPage(p);
                var text = _texts[p];
                foreach (var cover in scans[p].Covers.Where(scans[p].AnythingUnder))
                {
                    var area = cover.Box.Intersect(new RectD(0, 0, g.Width, g.Height));
                    if (area.Width < 1 || area.Height < 1 || p >= without.PageCount) continue;
                    var scale = Math.Min(1.5, Math.Sqrt(1_500_000 / (area.Width * area.Height)));
                    if (!HidesSomething(engine.Render(p, scale, area, cancel), without.Render(p, scale, area, cancel))) continue;
                    var under = Runs(text, i => area.Contains(text.BoxAt(i).CenterX, text.BoxAt(i).CenterY)).ToList();
                    var where = cover.Annot >= 0 ? $"Page {p + 1}, under a dark comment" : $"Page {p + 1}, under a dark box";
                    if (under.Count > 0)
                    {
                        Add(new RedactionFinding(RedactionLeak.CoveredText, where, string.Join(" ", under.Select(r => text.Text[r.Start..r.End]))) { Page = p, Box = area });
                        foreach (var (s, e) in under)
                        {
                            _found.Add(text.Text[s..e]);
                            for (var i = s; i < e; i++) _reported[p].Add(i);
                        }
                    }
                    else Add(new RedactionFinding(RedactionLeak.CoveredContent, where, "A picture or drawing is still under it") { Page = p, Box = area });
                }
                Beside(p, scans[p]);
            }
        }

        /// <summary>Pixels that show without the cover (differ from what is most common there) and are the cover's color with it.</summary>
        private static bool HidesSomething(RenderedImage with, RenderedImage without)
        {
            if (with.Width != without.Width || with.Height != without.Height || with.Pixels.Length == 0) return false;
            var cover = Dominant(with);
            var behind = Dominant(without);
            var n = with.Width * with.Height;
            var count = 0;
            for (var i = 0; i < n * 3; i += 3)
            {
                if (Distance(without.Pixels, i, behind) <= 60) continue; // nothing drawn there without the cover
                if (Distance(with.Pixels, i, cover) <= 45) count++;      // and with it, just the cover's color
            }
            return count >= Math.Max(6, n / 300);
        }

        private static int Distance(byte[] px, int i, (int B, int G, int R) c) => Math.Abs(px[i] - c.B) + Math.Abs(px[i + 1] - c.G) + Math.Abs(px[i + 2] - c.R);

        /// <summary>The most common color (in steps of 16), as its middle.</summary>
        private static (int B, int G, int R) Dominant(RenderedImage img)
        {
            var counts = new Dictionary<int, int>();
            for (var i = 0; i + 2 < img.Pixels.Length; i += 3)
            {
                var key = img.Pixels[i] >> 4 << 8 | img.Pixels[i + 1] >> 4 << 4 | img.Pixels[i + 2] >> 4;
                counts[key] = counts.GetValueOrDefault(key) + 1;
            }
            var k = counts.Count == 0 ? 0 : counts.MaxBy(kv => kv.Value).Key;
            return ((k >> 8 & 15) * 16 + 8, (k >> 4 & 15) * 16 + 8, (k & 15) * 16 + 8);
        }

        /// <summary>
        /// A box (wider than tall, so not a bullet or a check box) with no text under it, beside text on its line: the text
        /// around it keeps the positions it had, so the removed width can be measured from them.
        /// </summary>
        private void Beside(int p, PageScan scan)
        {
            var text = _texts[p];
            foreach (var cover in scan.Covers.Where(c => c.RectLike && c.Box.Width >= 12 && c.Box.Width >= 1.5 * c.Box.Height && c.Box.Height >= 4))
            {
                var box = cover.Box;
                var inside = false;
                var near = new List<int>();
                for (var i = 0; i < text.Text.Length && !inside; i++)
                {
                    if (!Visible(text.Text[i])) continue;
                    var b = text.BoxAt(i);
                    if (box.Inflate(-0.5).Contains(b.CenterX, b.CenterY)) inside = true;
                    else if (b.CenterY >= box.Y && b.CenterY <= box.Bottom && b.Height >= 0.4 * box.Height && b.Height <= 2.5 * box.Height
                             && (b.Right <= box.X + 0.5 ? box.X - b.Right : b.X >= box.Right - 0.5 ? b.X - box.Right : double.MaxValue) <= Math.Max(2, b.Height))
                        near.Add(i);
                }
                if (inside || near.Count == 0 || near.Any(_reported[p].Contains)) continue;
                // The text on either side, with the box between: "Name: ▮ lives here".
                var lines = near.Select(text.LineAt).Distinct().OrderBy(l => text.BoxAt(l.Start).X).ToList();
                var left = lines.Where(l => text.BoxAt(l.Start).X < box.X).Select(l => text.Text[l.Start..l.End].Trim());
                var right = lines.Where(l => text.BoxAt(l.Start).X >= box.X).Select(l => text.Text[l.Start..l.End].Trim());
                Add(new RedactionFinding(RedactionLeak.GlyphSpacing, $"Page {p + 1}, beside a dark box", string.Join(" ", [.. left, "▮", .. right])) { Page = p, Box = box });
            }
        }

        /// <summary>Characters found not to show (not reported yet): under a dark box or comment, or else under other content or
        /// in the color behind them.</summary>
        private void HiddenRuns(int p, List<(int Start, int End)> runs, PageScan scan)
        {
            var text = _texts[p];
            foreach (var (start, end) in runs)
            {
                if (Enumerable.Range(start, end - start).Any(_reported[p].Contains)) continue;
                var box = text.GetRects(start, end).Aggregate(default(RectD), (a, r) => a.Union(r));
                var cover = scan.Covers.FirstOrDefault(c => c.Box.Inflate(0.5).Contains(box.CenterX, box.CenterY));
                var where = cover is null ? "covered or drawn in the color behind it" : cover.Annot >= 0 ? "under a dark comment" : "under a dark box";
                Add(new RedactionFinding(RedactionLeak.CoveredText, $"Page {p + 1}, {where}", text.Text[start..end]) { Page = p, Box = cover?.Box ?? box });
                _found.Add(text.Text[start..end]);
                for (var i = start; i < end; i++) _reported[p].Add(i);
            }
        }

        /// <summary>A copy of the document without the covers: dark fills become unpainted paths, dark comments go.</summary>
        private byte[] WithoutCovers(PageScan[] scans, List<int> pages)
        {
            using var copy = string.IsNullOrEmpty(password)
                ? PdfReader.Open(new MemoryStream(data, false), PdfDocumentOpenMode.Modify)
                : PdfReader.Open(new MemoryStream(data, false), password, PdfDocumentOpenMode.Modify);
            if (copy.SecurityHandler.Elements.ContainsKey("/Filter"))
                copy.SecurityHandler.SetEncryptionToNoneAndResetPasswords();
            var forms = new Dictionary<PdfObjectID, List<Cover>>();
            foreach (var p in pages)
            {
                var page = copy.Pages[p];
                var own = scans[p].Covers.Where(c => c.Annot < 0 && !c.InForm).ToList();
                if (own.Count > 0) page.Elements["/Contents"] = PdfObj.AddStream(copy, Unpaint(ContentEditor.ContentBytes(page), own)).Reference!;
                foreach (var c in scans[p].Covers.Where(c => c.InForm))
                    (forms.TryGetValue(c.Form!.Value, out var l) ? l : forms[c.Form!.Value] = []).Add(c);
                if (PdfObj.Array(page.Elements["/Annots"]) is { } annots)
                    foreach (var i in scans[p].Covers.Where(c => c.Annot >= 0 && c.Annot < annots.Elements.Count).Select(c => c.Annot).Distinct().OrderDescending())
                        annots.Elements.RemoveAt(i);
            }
            foreach (var (id, covers) in forms)
            {
                if (copy.Internals.GetObject(id) is not PdfDictionary { Stream: not null } form) continue;
                var bytes = Unpaint(PdfObj.StreamBytes(form), covers.DistinctBy(c => c.OpEnd).ToList());
                form.Stream.Value = PdfObj.Deflate(bytes);
                form.Elements["/Filter"] = new PdfName("/FlateDecode");
                form.Elements.Remove("/DecodeParms");
                form.Elements["/Length"] = new PdfInteger(form.Stream.Value.Length);
            }
            using var ms = new MemoryStream();
            copy.Save(ms, false);
            return ms.ToArray();
        }

        /// <summary>The content with the covers' fill operators turned into "n" (the path is dropped unpainted).</summary>
        private static byte[] Unpaint(byte[] content, List<Cover> covers)
        {
            var copy = (byte[])content.Clone();
            foreach (var c in covers)
            {
                var at = c.OpEnd - c.OpLength;
                if (at < 0 || c.OpEnd > copy.Length) continue;
                copy[at] = (byte)'n';
                for (var i = at + 1; i < c.OpEnd; i++) copy[i] = (byte)' ';
            }
            return copy;
        }

        // ───────────────────────────── redacted areas ─────────────────────────────

        /// <summary>
        /// Each redacted area must be one solid color now (a few edge pixels aside), and no picture placed under it may be
        /// one the original held, byte for byte (a box drawn over a picture that was never changed).
        /// </summary>
        private void Areas(PdfEngine engine, PdfDocument doc, PageScan[] scans, IReadOnlyDictionary<int, IReadOnlyList<RectD>> areas)
        {
            var originals = OriginalPictures();
            foreach (var (p, rects) in areas.OrderBy(kv => kv.Key))
            {
                if (p < 0 || p >= engine.PageCount) continue;
                var g = engine.GetPage(p);
                foreach (var rect in rects)
                {
                    var area = rect.Inflate(-1).Intersect(new RectD(0, 0, g.Width, g.Height));
                    if (area.IsEmpty) continue;
                    var scale = Math.Min(1, Math.Sqrt(1_500_000 / (area.Width * area.Height)));
                    var img = engine.Render(p, scale, area, cancel);
                    var main = Dominant(img);
                    var n = img.Width * img.Height;
                    var off = 0;
                    for (var i = 0; i + 2 < img.Pixels.Length; i += 3)
                        if (Distance(img.Pixels, i, main) > 60) off++;
                    if (off > Math.Max(4, n / 50))
                        Add(new RedactionFinding(RedactionLeak.AreaNotRemoved, $"Page {p + 1}", "The redacted area still shows content") { Page = p, Box = rect });
                    if (originals.Count > 0 && scans[p].Pictures.Any(pic => pic.Image is { } im && !pic.Box.Intersect(area).IsEmpty && originals.Contains(Hash(im))))
                        Add(new RedactionFinding(RedactionLeak.AreaNotRemoved, $"Page {p + 1}", "The picture under the redacted area is the original, unchanged") { Page = p, Box = rect });
                }
            }
        }

        private HashSet<string> OriginalPictures()
        {
            var set = new HashSet<string>();
            if (options.Original is not { } original) return set;
            try
            {
                using var doc = PdfObj.Open(original, password, PdfDocumentOpenMode.Import);
                foreach (var o in doc.Internals.GetAllObjects())
                    if (o is PdfDictionary { Stream: not null } d && PdfObj.NameOf(d, "/Subtype") == "/Image") set.Add(Hash(d));
            }
            catch (InvalidOperationException)
            {
                _notes.Add("The document before redaction couldn't be read, so pictures under the redacted areas weren't compared with it.");
            }
            return set;
        }

        private static string Hash(PdfDictionary image) => Convert.ToHexString(SHA256.HashData(image.Stream?.Value ?? []));

        /// <summary>Hidden layers and hidden comments or fields hold content nobody sees (Sanitize Document removes them).</summary>
        private void HiddenContent(PdfDocument doc)
        {
            SanitizeReport scan;
            try
            {
                scan = Sanitizer.Scan(doc);
            }
            catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or InvalidCastException or NullReferenceException)
            {
                return;
            }
            _hiddenLayers = scan[SanitizeItem.HiddenLayers];
            if (scan[SanitizeItem.HiddenLayers] is var layers and > 0)
                Add(new RedactionFinding(RedactionLeak.HiddenContent, "Hidden layers",
                    $"{(layers == 1 ? "1 layer" : $"{layers} layers")} that don't show, with what they draw") { Sanitize = SanitizeItem.HiddenLayers });
            if (scan[SanitizeItem.HiddenAnnotations] is var annots and > 0)
                Add(new RedactionFinding(RedactionLeak.HiddenContent, "Hidden comments and form fields",
                    $"{(annots == 1 ? "1 comment or field" : $"{annots} comments and fields")} that don't show") { Sanitize = SanitizeItem.HiddenAnnotations });
        }

        /// <summary>The values in each page's text (characters already reported under a cover aside).</summary>
        private void PageValues(int p, ValueMatcher matcher)
        {
            var text = _texts[p];
            foreach (var (v, start, length) in matcher.Matches(text.Text))
            {
                _hit.Add(v);
                if (Enumerable.Range(start, length).Any(_reported[p].Contains)) continue; // reported under its cover
                var box = text.GetRects(start, start + length).Aggregate(default(RectD), (a, r) => a.Union(r));
                Add(new RedactionFinding(RedactionLeak.PageText, $"Page {p + 1}", text.Text.Substring(start, length).ReplaceLineEndings(" ")) { Page = p, Box = box });
                for (var i = start; i < start + length; i++) _reported[p].Add(i);
            }
        }
    }

    // ───────────────────────────── what a page draws ─────────────────────────────

    /// <summary>
    /// Walks a page's content (and the forms it draws, a few levels deep) for dark filled boxes and pictures, in page
    /// space. A box is a path filled with a dark gray, RGB or CMYK color (black when no color was set).
    /// </summary>
    private sealed class Walker(PdfPage page, PageScan scan, CancellationToken cancel)
    {
        private const int MaxDepth = 8, MaxOperators = 400_000;
        private int _ops, _order;
        private readonly HashSet<PdfDictionary> _active = new(ReferenceEqualityComparer.Instance);

        private sealed class State
        {
            public ContentEditor.Mat Ctm;
            public bool Dark = true, Light;
            public State Clone() => (State)MemberwiseClone();
        }

        public void Run(byte[] content, PdfDictionary? resources, ContentEditor.Mat ctm, PdfObjectID? form, int depth)
        {
            var ops = ContentLexer.Parse(content, cancel);
            var state = new State { Ctm = ctm };
            var stack = new Stack<State>();
            var points = new List<(double X, double Y)>();
            int rects = 0, subpaths = 0;
            var curved = false;
            foreach (var op in ops)
            {
                if (++_ops > MaxOperators) return;
                if ((_ops & 1023) == 0) cancel.ThrowIfCancellationRequested();
                switch (op.Name)
                {
                    case "q":
                        if (stack.Count < 256) stack.Push(state.Clone());
                        break;
                    case "Q":
                        if (stack.Count > 0) state = stack.Pop();
                        break;
                    case "cm" when op.Operands.Count >= 6:
                        state.Ctm = new ContentEditor.Mat(op.N(0), op.N(1), op.N(2), op.N(3), op.N(4), op.N(5)).Times(state.Ctm);
                        break;
                    case "g" when op.Operands.Count >= 1:
                        Fill(state, op.N(0));
                        break;
                    case "rg" when op.Operands.Count >= 3:
                        Fill(state, Luminance(op.N(0), op.N(1), op.N(2)));
                        break;
                    case "k" when op.Operands.Count >= 4:
                        Fill(state, Cmyk(op));
                        break;
                    case "sc" or "scn":
                        Fill(state, !op.Operands.All(o => o.Kind == CKind.Number) ? 0.5 : op.Operands.Count switch
                        {
                            1 => op.N(0),
                            3 => Luminance(op.N(0), op.N(1), op.N(2)),
                            4 => Cmyk(op),
                            _ => 0.5,
                        });
                        break;
                    case "cs":
                        Fill(state, 0); // a new color space starts at black (or full ink)
                        break;
                    case "sh":
                        scan.Drawn.Add((new RectD(-1e5, -1e5, 2e5, 2e5), ++_order, true)); // a shading fills the clip: anywhere
                        break;
                    case "m" when op.Operands.Count >= 2:
                        subpaths++;
                        points.Add((op.N(0), op.N(1)));
                        break;
                    case "l" when op.Operands.Count >= 2:
                        points.Add((op.N(0), op.N(1)));
                        break;
                    case "c" when op.Operands.Count >= 6:
                        curved = true;
                        points.Add((op.N(0), op.N(1)));
                        points.Add((op.N(2), op.N(3)));
                        points.Add((op.N(4), op.N(5)));
                        break;
                    case "v" or "y" when op.Operands.Count >= 4:
                        curved = true;
                        points.Add((op.N(0), op.N(1)));
                        points.Add((op.N(2), op.N(3)));
                        break;
                    case "re" when op.Operands.Count >= 4:
                        rects++;
                        subpaths++;
                        points.AddRange([(op.N(0), op.N(1)), (op.N(0) + op.N(2), op.N(1) + op.N(3))]);
                        break;
                    case "f" or "F" or "f*" or "B" or "B*" or "b" or "b*" or "S" or "s" or "n":
                        var fills = op.Name is not ("S" or "s" or "n");
                        if (op.Name != "n" && points.Count > 0)
                        {
                            var box = Box(points, state.Ctm);
                            var rectLike = subpaths == 1 && (rects == 1 || (!curved && points.Count is 4 or 5 && Axis(points)));
                            if (fills && state.Dark && box.Width >= 3 && box.Height >= 3 && scan.Covers.Count < MaxCoversPerPage * 4)
                                scan.Covers.Add(new Cover(box, rectLike, form, op.End, op.Name.Length, ++_order));
                            else if (!(state.Light && op.Name is "f" or "F" or "f*")) scan.Drawn.Add((box, ++_order, false));
                            else if (rectLike && scan.LightBoxes.Count < MaxCoversPerPage * 4) scan.LightBoxes.Add(box);
                        }
                        points.Clear();
                        rects = subpaths = 0;
                        curved = false;
                        break;
                    case "Do" when op.Operands.Count > 0 && op.Operands[0].Kind == CKind.Name:
                    {
                        var entry = PdfObj.Dict(resources?.Elements["/XObject"])?.Elements["/" + op.Operands[0].Name];
                        if (PdfObj.Dict(entry) is not { } xobj) break;
                        var sub = PdfObj.NameOf(xobj, "/Subtype");
                        if (sub == "/Image")
                        {
                            var box = Box([(0, 0), (1, 1), (0, 1), (1, 0)], state.Ctm);
                            scan.Pictures.Add((box, xobj));
                            scan.Drawn.Add((box, ++_order, true));
                        }
                        else if (sub == "/Form" && depth < MaxDepth && entry is PdfReference r && _active.Add(xobj))
                        {
                            var m = PdfObj.Array(xobj.Elements["/Matrix"]) is { Elements.Count: 6 } a
                                ? new ContentEditor.Mat(PdfObj.Num(a, 0), PdfObj.Num(a, 1), PdfObj.Num(a, 2), PdfObj.Num(a, 3), PdfObj.Num(a, 4), PdfObj.Num(a, 5))
                                : ContentEditor.Mat.Identity;
                            Run(PdfObj.StreamBytes(xobj), PdfObj.Dict(xobj.Elements["/Resources"]) ?? resources, m.Times(state.Ctm), r.ObjectID, depth + 1);
                            _active.Remove(xobj);
                        }
                        break;
                    }
                    case "BI":
                    {
                        var box = Box([(0, 0), (1, 1), (0, 1), (1, 0)], state.Ctm);
                        scan.Pictures.Add((box, null));
                        scan.Drawn.Add((box, ++_order, true));
                        break;
                    }
                }
            }
        }

        /// <summary>The fill color: dark enough to cover, or (nearly) white.</summary>
        private static void Fill(State state, double luminance)
        {
            state.Dark = luminance <= DarkLuminance;
            state.Light = luminance >= 0.95;
        }

        private static double Cmyk(COp op) =>
            Luminance((1 - op.N(0)) * (1 - op.N(3)), (1 - op.N(1)) * (1 - op.N(3)), (1 - op.N(2)) * (1 - op.N(3)));

        /// <summary>Four (or five, closing) points on two x and two y values: an upright rectangle drawn with lines.</summary>
        private static bool Axis(List<(double X, double Y)> pts) =>
            pts.Select(p => Math.Round(p.X, 1)).Distinct().Count() == 2 && pts.Select(p => Math.Round(p.Y, 1)).Distinct().Count() == 2;

        private RectD Box(List<(double X, double Y)> pts, ContentEditor.Mat ctm)
        {
            double l = double.MaxValue, t = double.MaxValue, r = double.MinValue, b = double.MinValue;
            foreach (var (x, y) in pts)
            {
                var (ux, uy) = ctm.Apply(x, y);
                var (px, py) = PdfObj.ToPage(page, ux, uy);
                l = Math.Min(l, px);
                r = Math.Max(r, px);
                t = Math.Min(t, py);
                b = Math.Max(b, py);
            }
            return double.IsFinite(l) && double.IsFinite(r) && double.IsFinite(t) && double.IsFinite(b) ? RectD.FromEdges(l, t, r, b) : default;
        }
    }
}
