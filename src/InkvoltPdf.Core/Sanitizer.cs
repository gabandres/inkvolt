using System.Text;
using System.Xml;
using System.Xml.Linq;
using MuPDFCore;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;

namespace InkvoltPdf.Core;

/// <summary>What <see cref="Sanitizer"/> finds and removes.</summary>
public enum SanitizeItem
{
    /// <summary>Document properties (the Info dictionary), XMP metadata packets (of the document, pages, images, fonts, ...)
    /// and other apps' private data (/PieceInfo, /LastModified).</summary>
    Metadata,

    /// <summary>Layers (optional content groups) hidden by default, with everything they draw.</summary>
    HiddenLayers,

    /// <summary>Annotations and form fields flagged as hidden or not to be shown (/F Hidden or NoView).</summary>
    HiddenAnnotations,

    /// <summary>Comments, markup, stamps and drawings (every annotation but links, form fields and the kinds below).</summary>
    Comments,

    /// <summary>Values filled into form fields (and an XFA form's copy of them).</summary>
    FormValues,

    Bookmarks,

    /// <summary>Embedded page thumbnails.</summary>
    Thumbnails,

    /// <summary>
    /// JavaScript (document scripts, open actions, additional actions of the document, pages, annotations and fields,
    /// script actions of links, fields and bookmarks), Launch, SubmitForm, ImportData and multimedia actions; RichMedia,
    /// 3D, Sound, Movie and Screen annotations; XFA forms (they carry scripts).
    /// </summary>
    ActiveContent,

    /// <summary>Links and actions leading out of the document: web addresses (URI), other files (GoToR, GoToE, articles in other files).</summary>
    ExternalLinks,

    /// <summary>Attached files: the EmbeddedFiles name tree, file attachment annotations, associated files (/AF), portfolios.</summary>
    EmbeddedFiles,

    /// <summary>Digital signatures (signature values, their certification permissions and validation data); the fields stay, empty.</summary>
    Signatures,
}

/// <summary>Counts per <see cref="SanitizeItem"/>: what a document holds (<see cref="Sanitizer.Scan"/>) or what was removed.</summary>
/// <param name="EarlierRevisions">Earlier versions kept in the file by incremental saves (a rewrite drops them).</param>
/// <param name="UnusedObjects">Objects nothing refers to any more (a rewrite drops them).</param>
/// <param name="Notes">What couldn't be removed, and why.</param>
public sealed record SanitizeReport(IReadOnlyDictionary<SanitizeItem, int> Counts, int EarlierRevisions, int UnusedObjects, IReadOnlyList<string> Notes)
{
    public int this[SanitizeItem item] => Counts.GetValueOrDefault(item);

    /// <summary>Nothing of any kind found.</summary>
    public bool IsClean => Counts.Values.All(c => c == 0);
}

/// <param name="Remaining">The output scanned again (null if it couldn't be read back with the same password).</param>
public sealed record SanitizeResult(byte[] Data, SanitizeReport Removed, SanitizeReport? Remaining);

/// <summary>
/// Sanitize Document: removes what a document carries besides its visible pages. Always a full rewrite, so earlier
/// revisions of an incrementally saved file and objects nothing uses are gone too. Hidden layers lose their content, not
/// just the layer: marked content of a layer that is off is cut out of every content stream (pages, form XObjects,
/// appearances, patterns), keeping the graphics-state operators it holds (as viewers apply them to hidden content too),
/// and XObjects and annotations that belong to it go. A part that can't be cut out safely (a content stream that
/// can't be decoded, hidden text whose width the visible text after it relies on) is kept, with its layer, and noted.
/// Text drawn in white or off the page is not looked for (it can't be told reliably from text that shows).
/// Signed documents need the caller's consent (<see cref="SignedEdits.Run"/> with the rewrite allowed): the rewrite
/// invalidates their signatures. An encrypted document keeps its protection (see <see cref="KeptProtection"/>).
/// </summary>
public static class Sanitizer
{
    /// <summary>What the document holds of each kind (every kind counted, nothing changed).</summary>
    public static SanitizeReport Scan(byte[] data, string? password)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Import);
        return new Pass(doc, null).Run(EarlierRevisions(data));
    }

    /// <summary>Removes the chosen kinds of content; the report counts what went.</summary>
    /// <exception cref="SignaturesWouldBreakException">The document is signed and the rewrite wasn't allowed.</exception>
    public static SanitizeResult Sanitize(byte[] data, string? password, IReadOnlySet<SanitizeItem> items)
    {
        SanitizeReport removed;
        byte[] saved;
        int pages;
        using (var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, "This PDF can't be edited"))
        {
            SignedEdits.RequireRewrite(data, doc, "sanitizing rewrites the whole file");
            pages = doc.PageCount;
            removed = new Pass(doc, items).Run(EarlierRevisions(data));
            saved = PdfObj.Save(doc, rewrite: true, bareXmp: items.Contains(SanitizeItem.Metadata));
        }

        // The result must open as before: never hand back a file MuPDF can't read.
        try
        {
            using var check = PdfEngine.Open(saved, InputFileTypes.PDF, password);
            if (check.PageCount != pages) throw new InvalidOperationException($"The sanitized file has {check.PageCount} pages instead of {pages}.");
        }
        catch (PasswordRequiredException)
        {
            // Saved without the password it was opened with (KeptProtection dropped an unknown open password): nothing to check with.
        }
        catch (Exception ex) when (ex is MuPDFException or ArgumentException)
        {
            throw new InvalidOperationException("The sanitized file couldn't be read back, so nothing was changed: " + ex.Message, ex);
        }

        SanitizeReport? remaining;
        try
        {
            remaining = Scan(saved, password);
        }
        catch (Exception ex) when (ex is InvalidOperationException or OwnerPasswordRequiredException or PdfReaderException)
        {
            remaining = null;
        }
        return new SanitizeResult(saved, removed, remaining);
    }

    /// <summary>Incremental updates after the first version (a linearized file's first-page section isn't one).</summary>
    internal static int EarlierRevisions(byte[] data)
    {
        var count = 0;
        var span = data.AsSpan();
        for (int at; (at = span.IndexOf("startxref"u8)) >= 0; span = span[(at + 9)..]) count++;
        var head = data.AsSpan(0, Math.Min(data.Length, 2048));
        if (head.IndexOf("/Linearized"u8) >= 0) count--;
        return Math.Max(0, count - 1);
    }

    /// <summary>
    /// One walk over the document: counts every kind (scan, <c>apply</c> null), or removes the chosen kinds and counts
    /// what it removed. Something that falls under several kinds (a hidden comment) counts once, under the first that
    /// applies in <see cref="SanitizeItem"/> order.
    /// </summary>
    private sealed class Pass(PdfDocument doc, IReadOnlySet<SanitizeItem>? apply)
    {
        private const int AnnotHidden = 2, AnnotNoView = 32, FfPushButton = 1 << 16;
        private static readonly ReferenceEqualityComparer RefEq = ReferenceEqualityComparer.Instance;

        private readonly Dictionary<SanitizeItem, int> _counts = Enum.GetValues<SanitizeItem>().ToDictionary(i => i, _ => 0);
        private readonly List<string> _notes = [];
        private readonly HashSet<PdfDictionary> _aaDone = new(RefEq);
        private readonly HashSet<PdfDictionary> _actionDone = new(RefEq);

        /// <summary>Layers that are off in the default configuration (null: none).</summary>
        private HashSet<PdfDictionary>? _hiddenOcgs;
        private bool _stripLayers;
        /// <summary>Some hidden-layer content couldn't be cut out: its layers stay (hidden) so it stays hidden.</summary>
        private bool _layerContentKept;

        private PdfDictionary Catalog => doc.Internals.Catalog;

        public SanitizeReport Run(int earlierRevisions)
        {
            var unused = 0;
            if (apply is null)
            {
                try
                {
                    var used = new HashSet<PdfDictionary>(Objects(), RefEq) { doc.Info };
                    foreach (var o in doc.Internals.GetClosure(doc.Info)) if (o is PdfDictionary d) used.Add(d);
                    // Not content: cross-reference and object streams, the encryption dictionary.
                    unused = doc.Internals.GetAllObjects().Count(o => o is PdfDictionary d && !used.Contains(d)
                        && PdfObj.NameOf(d, "/Type") is not ("/XRef" or "/ObjStm") && !(PdfObj.NameOf(d, "/Filter") == "/Standard" && d.Elements.ContainsKey("/O")));
                }
                catch (Exception ex) when (ex is InvalidOperationException or NullReferenceException)
                {
                    unused = 0;
                }
            }

            PrepareLayers();
            for (var i = 0; i < doc.PageCount; i++) Page(doc.Pages[i]);
            DocumentLevel();
            Fields();
            if (_stripLayers) StripLayers();
            OtherObjects();
            Info();
            return new SanitizeReport(_counts, earlierRevisions, unused, _notes);
        }

        /// <summary>
        /// Something of kind <paramref name="item"/> was found: counted when scanning (true never: nothing is removed),
        /// or when that kind is being removed (true: remove it).
        /// </summary>
        private bool Hit(SanitizeItem item, int n = 1)
        {
            if (n <= 0) return false;
            if (apply is null)
            {
                _counts[item] += n;
                return false;
            }
            if (!apply.Contains(item)) return false;
            _counts[item] += n;
            return true;
        }

        private bool Removing(SanitizeItem item) => apply?.Contains(item) == true;

        /// <summary>The indirect dictionaries the document uses (what a rewrite keeps), the catalog first.</summary>
        private List<PdfDictionary> Objects()
        {
            var list = new List<PdfDictionary> { Catalog };
            var seen = new HashSet<PdfDictionary>(RefEq) { Catalog };
            foreach (var o in doc.Internals.GetClosure(Catalog))
                if (o is PdfDictionary d && seen.Add(d)) list.Add(d);
            return list;
        }

        // ───────────────────────────── Pages and annotations ─────────────────────────────

        private void Page(PdfPage page)
        {
            if (page.Elements.ContainsKey("/Thumb") && Hit(SanitizeItem.Thumbnails)) page.Elements.Remove("/Thumb");
            CleanAA(page);
            Annotations(page);
        }

        private void Annotations(PdfPage page)
        {
            if (PdfObj.Array(page.Elements["/Annots"]) is not { } annots) return;
            var remove = new HashSet<PdfDictionary>(RefEq);
            foreach (var a in annots.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().ToList())
            {
                var subtype = PdfObj.NameOf(a, "/Subtype");
                if (subtype == "/Popup" || remove.Contains(a)) continue;
                if (Classify(a, subtype) is not null)
                {
                    remove.Add(a);
                    continue;
                }
                var hadAction = a.Elements.ContainsKey("/A");
                CleanActionEntry(a, "/A");
                CleanAA(a);
                // A link whose only action went leads nowhere: it goes too.
                if (subtype == "/Link" && hadAction && !a.Elements.ContainsKey("/A") && !a.Elements.ContainsKey("/Dest")) remove.Add(a);
            }
            if (remove.Count == 0) return;

            // Pop-up notes go with their annotation.
            foreach (var r in remove.ToList())
                if (PdfObj.Dict(r.Elements["/Popup"]) is { } popup) remove.Add(popup);
            foreach (var a in annots.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>())
                if (PdfObj.NameOf(a, "/Subtype") == "/Popup" && PdfObj.Dict(a.Elements["/Parent"]) is { } parent && remove.Contains(parent)) remove.Add(a);

            var own = PdfObj.Annots(doc, page);
            for (var k = own.Elements.Count - 1; k >= 0; k--)
                if (PdfObj.Dict(own.Elements[k]) is { } d && remove.Contains(d)) own.Elements.RemoveAt(k);
            if (own.Elements.Count == 0) page.Elements.Remove("/Annots");
            foreach (var w in remove.Where(w => PdfObj.NameOf(w, "/Subtype") == "/Widget")) DetachWidget(w);
        }

        /// <summary>The kind an annotation is removed as (counted), or null when it stays.</summary>
        private SanitizeItem? Classify(PdfDictionary a, string subtype)
        {
            var kinds = new List<SanitizeItem>(3);
            if (_hiddenOcgs is not null && IsHiddenOc(a.Elements["/OC"])) kinds.Add(SanitizeItem.HiddenLayers);
            if (((PdfObj.Int(a.Elements["/F"]) ?? 0) & (AnnotHidden | AnnotNoView)) != 0) kinds.Add(SanitizeItem.HiddenAnnotations);
            switch (subtype)
            {
                case "/FileAttachment":
                    kinds.Add(SanitizeItem.EmbeddedFiles);
                    break;
                case "/RichMedia" or "/3D" or "/Sound" or "/Movie" or "/Screen":
                    kinds.Add(SanitizeItem.ActiveContent);
                    break;
                case "/Link" or "/Widget" or "/PrinterMark" or "/TrapNet" or "/Watermark" or "":
                    break;
                default:
                    kinds.Add(SanitizeItem.Comments);
                    break;
            }
            if (kinds.Count == 0) return null;
            // Annotations of a hidden layer go with it: the layer is what's counted.
            if (kinds[0] == SanitizeItem.HiddenLayers && Removing(SanitizeItem.HiddenLayers)) return SanitizeItem.HiddenLayers;
            if (apply is null)
            {
                if (kinds[0] != SanitizeItem.HiddenLayers) Hit(kinds[0]);
                return null;
            }
            foreach (var k in kinds)
                if (k != SanitizeItem.HiddenLayers && Hit(k)) return k;
            return null;
        }

        /// <summary>Takes a removed widget out of its field; a field left without widgets (and so on up) goes too.</summary>
        private void DetachWidget(PdfDictionary widget)
        {
            var acro = PdfObj.Dict(Catalog.Elements["/AcroForm"]);
            var node = widget;
            for (var guard = 0; guard < 64; guard++)
            {
                var parent = PdfObj.Dict(node.Elements["/Parent"]);
                var list = parent is null ? PdfObj.Array(acro?.Elements["/Fields"]) : PdfObj.Array(parent.Elements["/Kids"]);
                if (list is null) return;
                for (var k = list.Elements.Count - 1; k >= 0; k--)
                    if (ReferenceEquals(PdfObj.Dict(list.Elements[k]), node)) list.Elements.RemoveAt(k);
                if (PdfObj.Array(acro?.Elements["/CO"]) is { } co)
                    for (var k = co.Elements.Count - 1; k >= 0; k--)
                        if (ReferenceEquals(PdfObj.Dict(co.Elements[k]), node)) co.Elements.RemoveAt(k);
                if (parent is null || list.Elements.Count > 0) return;
                node = parent;
            }
        }

        // ───────────────────────────── Actions ─────────────────────────────

        /// <summary>The kind of content an action is (null: one that stays, such as going to a page).</summary>
        private static SanitizeItem? ActionKind(PdfDictionary a)
        {
            var s = PdfObj.NameOf(a, "/S");
            if (s is "/JavaScript" or "/Launch" or "/SubmitForm" or "/ImportData" or "/Rendition" or "/Movie" or "/Sound" or "/RichMediaExecute" or "/GoTo3DView"
                || a.Elements.ContainsKey("/JS")) return SanitizeItem.ActiveContent;
            if (s is "/URI" or "/GoToR" or "/GoToE" || (s == "/Thread" && a.Elements.ContainsKey("/F"))) return SanitizeItem.ExternalLinks;
            return null;
        }

        /// <summary>Cleans the action chain in <paramref name="owner"/>[<paramref name="key"/>] (each owner once).</summary>
        private void CleanActionEntry(PdfDictionary owner, string key)
        {
            if (key == "/A" && !_actionDone.Add(owner)) return;
            if (owner.Elements[key] is not { } item || PdfObj.Dict(item) is null) return;
            var cleaned = CleanChain(item);
            if (ReferenceEquals(cleaned, item)) return;
            if (cleaned is null) owner.Elements.Remove(key);
            else owner.Elements[key] = cleaned;
        }

        /// <summary>
        /// An action with the ones after it (/Next) minus those being removed, in the order they run; the same item when
        /// nothing goes, null when nothing is left.
        /// </summary>
        private PdfItem? CleanChain(PdfItem item)
        {
            var chain = new List<PdfDictionary>();
            Flatten(item, chain, new HashSet<PdfDictionary>(RefEq), 0);
            var keep = new List<PdfDictionary>();
            var removed = false;
            foreach (var a in chain)
            {
                if (ActionKind(a) is { } kind && Hit(kind)) removed = true;
                else keep.Add(a);
            }
            if (!removed) return item;
            foreach (var k in keep) k.Elements.Remove("/Next");
            if (keep.Count == 0) return null;
            if (keep.Count > 1)
            {
                var next = new PdfArray(doc);
                foreach (var k in keep.Skip(1)) next.Elements.Add(k.Reference ?? (PdfItem)k);
                keep[0].Elements["/Next"] = next;
            }
            return keep[0].Reference ?? (PdfItem)keep[0];
        }

        private static void Flatten(PdfItem? item, List<PdfDictionary> chain, HashSet<PdfDictionary> seen, int depth)
        {
            if (depth > 32 || PdfObj.Dict(item) is not { } a || !seen.Add(a)) return;
            chain.Add(a);
            switch (PdfObj.Resolve(a.Elements["/Next"]))
            {
                case PdfDictionary next:
                    Flatten(next, chain, seen, depth + 1);
                    break;
                case PdfArray list:
                    foreach (var n in list.Elements) Flatten(n, chain, seen, depth + 1);
                    break;
            }
        }

        /// <summary>Cleans the additional actions (/AA) of a document, page, annotation or field.</summary>
        private void CleanAA(PdfDictionary owner)
        {
            if (!_aaDone.Add(owner) || PdfObj.Dict(owner.Elements["/AA"]) is not { } aa) return;
            foreach (var key in aa.Elements.Keys.ToList()) CleanActionEntry(aa, key);
            if (apply is not null && aa.Elements.Count == 0) owner.Elements.Remove("/AA");
        }

        // ───────────────────────────── Document level ─────────────────────────────

        private void DocumentLevel()
        {
            var catalog = Catalog;
            if (PdfObj.Dict(catalog.Elements["/OpenAction"]) is not null) CleanActionEntry(catalog, "/OpenAction");
            CleanAA(catalog);

            var names = PdfObj.Dict(catalog.Elements["/Names"]);
            if (PdfObj.Dict(names?.Elements["/JavaScript"]) is { } js && Hit(SanitizeItem.ActiveContent, Math.Max(1, PdfObj.NameTree(js).Count())))
                names!.Elements.Remove("/JavaScript");
            if (PdfObj.Dict(names?.Elements["/EmbeddedFiles"]) is { } files && PdfObj.NameTree(files).Count() is var n and > 0 && Hit(SanitizeItem.EmbeddedFiles, n))
                names!.Elements.Remove("/EmbeddedFiles");
            if (Removing(SanitizeItem.EmbeddedFiles)) catalog.Elements.Remove("/Collection"); // a portfolio's layout: its files are gone
            if (Removing(SanitizeItem.ExternalLinks)) catalog.Elements.Remove("/URI"); // the base of relative web addresses

            if (PdfObj.Dict(catalog.Elements["/Outlines"]) is { } outlines)
            {
                var items = OutlineItems(outlines);
                if (items.Count > 0 && Hit(SanitizeItem.Bookmarks, items.Count))
                {
                    catalog.Elements.Remove("/Outlines");
                    if (PdfObj.Name(catalog.Elements["/PageMode"]) == "UseOutlines") catalog.Elements.Remove("/PageMode");
                }
                else
                {
                    foreach (var item in items)
                    {
                        // A bookmark keeps going where it went; only a removed action is taken off it.
                        CleanActionEntry(item, "/A");
                    }
                }
            }
        }

        private static List<PdfDictionary> OutlineItems(PdfDictionary outlines)
        {
            var list = new List<PdfDictionary>();
            var seen = new HashSet<PdfDictionary>(RefEq) { outlines };
            var stack = new Stack<PdfDictionary>();
            if (PdfObj.Dict(outlines.Elements["/First"]) is { } first) stack.Push(first);
            while (stack.Count > 0 && list.Count < 200_000)
            {
                for (var item = stack.Pop(); item is not null && seen.Add(item); item = PdfObj.Dict(item.Elements["/Next"]))
                {
                    list.Add(item);
                    if (PdfObj.Dict(item.Elements["/First"]) is { } child) stack.Push(child);
                }
            }
            return list;
        }

        // ───────────────────────────── Form fields ─────────────────────────────

        private void Fields()
        {
            if (PdfObj.Dict(Catalog.Elements["/AcroForm"]) is not { } acro) return;
            foreach (var node in FieldNodes(acro)) CleanAA(node);

            var fields = new List<FormEditor.Field>();
            FormEditor.Collect(doc, acro, fields);

            if (acro.Elements.ContainsKey("/XFA"))
            {
                if (fields.Count == 0)
                {
                    // XFA-only: the pages are a placeholder, the form is all there is.
                    if (apply is null || Removing(SanitizeItem.ActiveContent))
                        _notes.Add("The XFA form (with its scripts and data) was kept: the document has no other form, so removing it would leave only a placeholder page.");
                }
                else if (Hit(SanitizeItem.ActiveContent)) acro.Elements.Remove("/XFA");
            }

            var valued = fields.Where(HasValue).ToList();
            if (valued.Count > 0 && Hit(SanitizeItem.FormValues, valued.Count))
            {
                FormEditor.ClearFields(doc, new HashSet<PdfDictionary>(valued.SelectMany(f => f.Widgets), RefEq));
                foreach (var f in valued)
                {
                    // Fields without widgets, and default values (what Reset Form would bring back).
                    foreach (var key in new[] { "/V", "/RV", "/I" })
                        if (f.Widgets.Count == 0) f.Dict.Elements.Remove(key);
                    if (f.Type is "/Tx" or "/Ch") f.Dict.Elements.Remove("/DV");
                }
            }

            var signed = fields.Where(f => f.Type == "/Sig" && PdfObj.Dict(FormEditor.Inherited(f.Dict, "/V")) is not null).ToList();
            if (signed.Count > 0 && Hit(SanitizeItem.Signatures, signed.Count))
            {
                foreach (var f in signed)
                {
                    PdfDictionary? d = f.Dict;
                    for (var guard = 0; d is not null && guard < 64; d = PdfObj.Dict(d.Elements["/Parent"]), guard++) d.Elements.Remove("/V");
                    foreach (var w in f.Widgets) w.Elements.Remove("/AP"); // the visible signature (the signer's name, an image)
                }
                Catalog.Elements.Remove("/Perms"); // certification (DocMDP) refers to a signature that is gone
                Catalog.Elements.Remove("/DSS"); // validation data: certificates, revocation answers
                acro.Elements.Remove("/SigFlags");
            }

        }

        private static bool HasValue(FormEditor.Field f)
        {
            static bool Filled(PdfItem? v) => PdfObj.Resolve(v) switch
            {
                PdfString s => s.Value.Length > 0,
                PdfArray a => a.Elements.Count > 0,
                PdfDictionary { Stream: not null } d => d.Stream.Value.Length > 0,
                _ => false,
            };
            switch (f.Type)
            {
                case "/Tx" or "/Ch":
                    return Filled(FormEditor.Inherited(f.Dict, "/V")) || Filled(f.Dict.Elements["/DV"]);
                case "/Btn" when (f.Flags & FfPushButton) == 0:
                    return PdfObj.Name(FormEditor.Inherited(f.Dict, "/V")) is { } on && on != "Off"
                           || f.Widgets.Any(w => PdfObj.Name(w.Elements["/AS"]) is { } s && s != "Off");
                default:
                    return false;
            }
        }

        /// <summary>Every node of the field tree (each once).</summary>
        private static List<PdfDictionary> FieldNodes(PdfDictionary acro)
        {
            var list = new List<PdfDictionary>();
            var seen = new HashSet<PdfDictionary>(RefEq);
            var stack = new Stack<(PdfDictionary Node, int Depth)>();
            if (PdfObj.Array(acro.Elements["/Fields"]) is { } top)
                foreach (var f in top.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()) stack.Push((f, 0));
            while (stack.Count > 0)
            {
                var (node, depth) = stack.Pop();
                if (depth > 64 || !seen.Add(node)) continue;
                list.Add(node);
                if (PdfObj.Array(node.Elements["/Kids"]) is { } kids)
                    foreach (var k in kids.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()) stack.Push((k, depth + 1));
            }
            return list;
        }

        // ───────────────────────────── Metadata and the rest of the objects ─────────────────────────────

        private void OtherObjects()
        {
            var catalog = Catalog;
            foreach (var d in Objects())
            {
                if (d.Elements.ContainsKey("/PieceInfo") && Hit(SanitizeItem.Metadata))
                {
                    d.Elements.Remove("/PieceInfo");
                    d.Elements.Remove("/LastModified"); // when the private data was last changed
                }
                if (PdfObj.Dict(d.Elements["/Metadata"]) is { Stream: not null } xmp && (!ReferenceEquals(d, catalog) || XmpHasData(xmp)) && Hit(SanitizeItem.Metadata))
                    d.Elements.Remove("/Metadata");
                if (PdfObj.Array(d.Elements["/AF"]) is { Elements.Count: > 0 } af && Hit(SanitizeItem.EmbeddedFiles, af.Elements.Count))
                    d.Elements.Remove("/AF");
            }
        }

        private void Info()
        {
            var info = doc.Info.Elements;
            // Not counted: what PDFsharp writes itself (its name; opened for editing, a /ModDate of now).
            var keys = info.Keys.Where(k => !(k is "/Producer" or "/Creator" && PdfObj.Str(info[k]) is { } v && v.StartsWith("PDFsharp", StringComparison.Ordinal))
                                            && !(k == "/ModDate" && apply is not null && PdfObj.ParseDate(PdfObj.Str(info[k]) ?? info[k]?.ToString()) is { } t && (DateTimeOffset.Now - t).Duration() < TimeSpan.FromMinutes(5))).ToList();
            if (keys.Count > 0 && Hit(SanitizeItem.Metadata, keys.Count))
                foreach (var k in info.Keys.ToList()) info.Remove(k);
        }

        private static readonly XNamespace Rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#";

        /// <summary>
        /// Whether an XMP packet says anything beyond what a save writes anyway (producer, tool, fresh document IDs,
        /// PDFsharp's placeholder dates). An unreadable packet counts as data.
        /// </summary>
        private static bool XmpHasData(PdfDictionary stream)
        {
            try
            {
                using var reader = XmlReader.Create(new MemoryStream(PdfObj.StreamBytes(stream)),
                    new XmlReaderSettings { DtdProcessing = DtdProcessing.Prohibit, XmlResolver = null });
                var xmp = XDocument.Load(reader);
                foreach (var desc in xmp.Descendants(Rdf + "Description"))
                {
                    foreach (var attr in desc.Attributes())
                        if (!attr.IsNamespaceDeclaration && attr.Name != Rdf + "about" && Meaningful(attr.Name.LocalName, attr.Value)) return true;
                    foreach (var el in desc.Elements())
                        if (Meaningful(el.Name.LocalName, string.Concat(el.DescendantNodes().OfType<XText>().Select(t => t.Value)))) return true;
                }
                return false;
            }
            catch (Exception ex) when (ex is XmlException or InvalidOperationException or NotImplementedException or ArgumentException)
            {
                return true;
            }

            static bool Meaningful(string name, string value)
            {
                value = value.Trim();
                if (value.Length == 0 || name is "Producer" or "CreatorTool" or "DocumentID" or "InstanceID") return false;
                return !(name is "CreateDate" or "ModifyDate" or "MetadataDate" && value.StartsWith("0001-", StringComparison.Ordinal));
            }
        }

        // ───────────────────────────── Hidden layers ─────────────────────────────

        private void PrepareLayers()
        {
            var props = PdfObj.Dict(Catalog.Elements["/OCProperties"]);
            if (PdfObj.Array(props?.Elements["/OCGs"]) is not { } list) return;
            var ocgs = list.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Distinct(RefEq).Cast<PdfDictionary>().ToList();
            var d = PdfObj.Dict(props!.Elements["/D"]);
            var on = Members(d?.Elements["/ON"]);
            var off = Members(d?.Elements["/OFF"]);
            var baseOff = PdfObj.Name(d?.Elements["/BaseState"]) == "OFF";
            var hidden = new HashSet<PdfDictionary>(ocgs.Where(o => off.Contains(o) || (baseOff && !on.Contains(o))), RefEq);
            if (hidden.Count == 0) return;
            _hiddenOcgs = hidden;
            _stripLayers = Hit(SanitizeItem.HiddenLayers, hidden.Count);
        }

        /// <summary>The dictionaries in an array (or a single one).</summary>
        private static HashSet<PdfDictionary> Members(PdfItem? item)
        {
            var set = new HashSet<PdfDictionary>(RefEq);
            switch (PdfObj.Resolve(item))
            {
                case PdfArray a:
                    foreach (var d in a.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()) set.Add(d);
                    break;
                case PdfDictionary d:
                    set.Add(d);
                    break;
            }
            return set;
        }

        /// <summary>Whether an /OC entry (a layer or a membership dictionary) hides what it marks in the default configuration.</summary>
        private bool IsHiddenOc(PdfItem? oc)
        {
            if (_hiddenOcgs is null || PdfObj.Dict(oc) is not { } d) return false;
            return PdfObj.NameOf(d, "/Type") == "/OCMD" ? !OcmdVisible(d) : _hiddenOcgs.Contains(d);
        }

        private bool OcmdVisible(PdfDictionary ocmd)
        {
            if (PdfObj.Array(ocmd.Elements["/VE"]) is { } ve && Evaluate(ve, 0) is { } result) return result;
            var members = Members(ocmd.Elements["/OCGs"]);
            if (members.Count == 0) return true;
            bool On(PdfDictionary m) => !_hiddenOcgs!.Contains(m);
            return PdfObj.Name(ocmd.Elements["/P"]) switch
            {
                "AllOn" => members.All(On),
                "AnyOff" => members.Any(m => !On(m)),
                "AllOff" => members.All(m => !On(m)),
                _ => members.Any(On),
            };
        }

        /// <summary>A visibility expression ([/And ...], [/Or ...], [/Not x]); null when it can't be read.</summary>
        private bool? Evaluate(PdfArray ve, int depth)
        {
            if (depth > 16 || ve.Elements.Count < 2) return null;
            var operands = new List<bool>();
            foreach (var e in ve.Elements.Skip(1))
            {
                bool? v = PdfObj.Resolve(e) switch
                {
                    PdfArray sub => Evaluate(sub, depth + 1),
                    PdfDictionary ocg => !_hiddenOcgs!.Contains(ocg),
                    _ => null,
                };
                if (v is null) return null;
                operands.Add(v.Value);
            }
            return PdfObj.Name(ve.Elements[0]) switch
            {
                "And" => operands.All(x => x),
                "Or" => operands.Any(x => x),
                "Not" => !operands[0],
                _ => null,
            };
        }

        private void StripLayers()
        {
            var resources = new HashSet<PdfDictionary>(RefEq);
            for (var i = 0; i < doc.PageCount; i++)
            {
                var page = doc.Pages[i];
                var res = PageResources(page);
                if (res is not null) resources.Add(res);
                StripPage(page, res, i);
            }
            foreach (var d in Objects())
            {
                if (d.Stream is null) continue;
                var isForm = PdfObj.NameOf(d, "/Subtype") == "/Form";
                var isPattern = PdfObj.Int(d.Elements["/PatternType"]) == 1;
                if (!isForm && !isPattern) continue;
                if (isForm && IsHiddenOc(d.Elements["/OC"]))
                {
                    // A form XObject of a hidden layer draws nothing: empty it (it may be used in places not rewritten).
                    SetStream(d, []);
                    d.Elements.Remove("/Resources");
                    continue;
                }
                var res = PdfObj.Dict(d.Elements["/Resources"]);
                if (res is not null) resources.Add(res);
                byte[] bytes;
                try
                {
                    bytes = PdfObj.StreamBytes(d);
                }
                catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or ArgumentException or NotSupportedException or NotImplementedException or IndexOutOfRangeException)
                {
                    bytes = [];
                }
                if (bytes.Length == 0 && d.Stream.Value.Length > 0)
                {
                    if (MentionsHidden(res)) KeepLayerContent("A drawing that uses a hidden layer couldn't be decoded");
                    continue;
                }
                if (Strip(bytes, res, out var why) is { } stripped) SetStream(d, stripped);
                if (why is not null) KeepLayerContent(why);
            }

            if (!_layerContentKept)
            {
                // Resource entries of hidden layers and their XObjects: nothing draws them now.
                foreach (var res in resources)
                {
                    if (PdfObj.Dict(res.Elements["/Properties"]) is { } props)
                        foreach (var key in props.Elements.Keys.ToList())
                            if (IsHiddenOc(props.Elements[key])) props.Elements.Remove(key);
                    if (PdfObj.Dict(res.Elements["/XObject"]) is { } xobjects)
                        foreach (var key in xobjects.Elements.Keys.ToList())
                            if (PdfObj.Dict(xobjects.Elements[key]) is { } x && IsHiddenOc(x.Elements["/OC"])) xobjects.Elements.Remove(key);
                }
            }
            RemoveHiddenLayers(resources);
        }

        private void KeepLayerContent(string why)
        {
            if (!_notes.Contains(why + ": hidden layers were kept (still hidden) so it stays hidden.")) _notes.Add(why + ": hidden layers were kept (still hidden) so it stays hidden.");
            _layerContentKept = true;
        }

        private bool MentionsHidden(PdfDictionary? res) =>
            PdfObj.Dict(res?.Elements["/Properties"]) is { } props && props.Elements.Keys.Any(k => IsHiddenOc(props.Elements[k]))
            || PdfObj.Dict(res?.Elements["/XObject"]) is { } xs && xs.Elements.Keys.Any(k => PdfObj.Dict(xs.Elements[k]) is { } x && IsHiddenOc(x.Elements["/OC"]));

        private static PdfDictionary? PageResources(PdfPage page)
        {
            PdfDictionary? node = page;
            for (var guard = 0; node is not null && guard < 64; guard++, node = PdfObj.Dict(node.Elements["/Parent"]))
                if (PdfObj.Dict(node.Elements["/Resources"]) is { } r) return r;
            return null;
        }

        /// <summary>The page's content streams read as one, hidden-layer content cut out, written back as one stream.</summary>
        private void StripPage(PdfPage page, PdfDictionary? res, int index)
        {
            var parts = PdfObj.Resolve(page.Elements["/Contents"]) switch
            {
                PdfDictionary { Stream: not null } s => [s],
                PdfArray a => a.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Where(s => s.Stream is not null).ToList(),
                _ => new List<PdfDictionary>(),
            };
            if (parts.Count == 0) return;
            using var ms = new MemoryStream();
            foreach (var s in parts)
            {
                byte[] bytes;
                try
                {
                    bytes = PdfObj.StreamBytes(s);
                }
                catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or ArgumentException or NotSupportedException or NotImplementedException or IndexOutOfRangeException)
                {
                    bytes = [];
                }
                if (bytes.Length == 0 && s.Stream!.Value.Length > 0)
                {
                    if (MentionsHidden(res)) KeepLayerContent($"Page {index + 1} has content that couldn't be decoded");
                    return;
                }
                ms.Write(bytes);
                ms.WriteByte((byte)'\n');
            }
            var stripped = Strip(ms.ToArray(), res, out var why);
            if (why is not null) KeepLayerContent($"Page {index + 1}: {why}");
            if (stripped is null) return;
            var stream = PdfObj.AddStream(doc, stripped);
            page.Elements["/Contents"] = stream.Reference!;
        }

        private static void SetStream(PdfDictionary d, byte[] content)
        {
            var packed = PdfObj.Deflate(content);
            if (d.Stream is null) d.CreateStream(packed);
            else d.Stream.Value = packed;
            d.Elements["/Filter"] = new PdfName("/FlateDecode");
            d.Elements.Remove("/DecodeParms");
            d.Elements["/Length"] = new PdfInteger(packed.Length);
        }

        private byte[]? Strip(byte[] content, PdfDictionary? res, out string? kept)
        {
            var props = PdfObj.Dict(res?.Elements["/Properties"]);
            var xobjects = PdfObj.Dict(res?.Elements["/XObject"]);
            return HiddenContent.Strip(content,
                tag => IsHiddenOc(props?.Elements["/" + tag]),
                name => PdfObj.Dict(xobjects?.Elements["/" + name]) is { } x && IsHiddenOc(x.Elements["/OC"]),
                out kept);
        }

        /// <summary>Takes the hidden layers out of the layer configuration (unless some of their content had to stay).</summary>
        private void RemoveHiddenLayers(HashSet<PdfDictionary> resources)
        {
            var props = PdfObj.Dict(Catalog.Elements["/OCProperties"]);
            if (props is null || _hiddenOcgs is null || _layerContentKept) return;
            var gone = new HashSet<PdfDictionary>(_hiddenOcgs, RefEq);

            // Membership dictionaries: an expression that names a hidden layer keeps it; plain lists are rewritten so
            // what they show doesn't change (the hidden layers are off for good).
            // They are often direct objects: in /Properties of resources, or an /OC entry.
            var ocmds = new HashSet<PdfDictionary>(RefEq);
            void Consider(PdfItem? item)
            {
                if (PdfObj.Dict(item) is { } m && PdfObj.NameOf(m, "/Type") == "/OCMD") ocmds.Add(m);
            }
            foreach (var o in Objects())
            {
                Consider(o);
                Consider(o.Elements["/OC"]);
            }
            foreach (var res in resources)
                if (PdfObj.Dict(res.Elements["/Properties"]) is { } list)
                    foreach (var key in list.Elements.Keys) Consider(list.Elements[key]);
            foreach (var m in ocmds.Where(m => m.Elements.ContainsKey("/VE")))
            {
                var used = new HashSet<PdfDictionary>(RefEq);
                CollectVe(PdfObj.Array(m.Elements["/VE"]), used, 0);
                if (used.Overlaps(gone)) _notes.Add("A layer visibility expression uses a hidden layer, so that layer was kept (still hidden; its content was removed).");
                gone.ExceptWith(used);
            }
            foreach (var m in ocmds.Where(m => !m.Elements.ContainsKey("/VE")))
            {
                var members = Members(m.Elements["/OCGs"]);
                if (!members.Overlaps(gone)) continue;
                var visible = OcmdVisible(m);
                var rest = members.Where(x => !gone.Contains(x)).ToList();
                if (visible && PdfObj.Name(m.Elements["/P"]) == "AnyOff" || rest.Count == 0)
                {
                    m.Elements.Remove("/OCGs"); // satisfied for good (or marks only removed content): no effect
                    m.Elements.Remove("/P");
                }
                else m.Elements["/OCGs"] = new PdfArray(doc, [.. rest.Select(x => x.Reference ?? (PdfItem)x)]);
            }
            if (gone.Count == 0) return;

            Filter(PdfObj.Array(props.Elements["/OCGs"]), gone);
            var configs = new List<PdfDictionary>();
            if (PdfObj.Dict(props.Elements["/D"]) is { } d) configs.Add(d);
            if (PdfObj.Array(props.Elements["/Configs"]) is { } more) configs.AddRange(more.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>());
            foreach (var c in configs)
            {
                foreach (var key in new[] { "/ON", "/OFF", "/Locked", "/Order" }) Filter(PdfObj.Array(c.Elements[key]), gone);
                if (PdfObj.Array(c.Elements["/RBGroups"]) is { } groups)
                    foreach (var g in groups.Elements) Filter(PdfObj.Array(g), gone);
                if (PdfObj.Array(c.Elements["/AS"]) is { } auto)
                    foreach (var a in auto.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()) Filter(PdfObj.Array(a.Elements["/OCGs"]), gone);
            }
            if (PdfObj.Array(props.Elements["/OCGs"]) is not { Elements.Count: > 0 }) Catalog.Elements.Remove("/OCProperties");
        }

        private static void CollectVe(PdfArray? ve, HashSet<PdfDictionary> into, int depth)
        {
            if (ve is null || depth > 16) return;
            foreach (var e in ve.Elements.Skip(1))
            {
                if (PdfObj.Resolve(e) is PdfArray sub) CollectVe(sub, into, depth + 1);
                else if (PdfObj.Dict(e) is { } ocg) into.Add(ocg);
            }
        }

        /// <summary>Removes the layers from an array, and from arrays inside it (/Order nests them).</summary>
        private static void Filter(PdfArray? a, HashSet<PdfDictionary> gone, int depth = 0)
        {
            if (a is null || depth > 32) return;
            for (var k = a.Elements.Count - 1; k >= 0; k--)
            {
                var e = a.Elements[k];
                if (PdfObj.Dict(e) is { } d && gone.Contains(d)) a.Elements.RemoveAt(k);
                else if (PdfObj.Resolve(e) is PdfArray sub) Filter(sub, gone, depth + 1);
            }
        }
    }
}

/// <summary>
/// Cuts optional content out of a content stream: marked content (/OC /name BDC … EMC) of a hidden layer, and XObjects
/// of a hidden layer (Do). Viewers still apply the graphics state a hidden section sets (PDF 2.0, 8.11.3.2), so its
/// q/Q, transformations, colors, line and text-state settings and clipping paths stay; what it draws (text, paths,
/// images, XObjects, shadings) goes. Inside a text object, text positioning stays; a section that shows text the
/// visible text after it is placed after (no Td/Tm in between) can't be cut without moving that text, so it is kept.
/// </summary>
internal static class HiddenContent
{
    private static readonly HashSet<string> State =
        ["q", "Q", "cm", "w", "J", "j", "M", "d", "ri", "i", "gs", "CS", "cs", "SC", "SCN", "sc", "scn", "G", "g", "RG", "rg", "K", "k", "Tc", "Tw", "Tz", "TL", "Tf", "Tr", "Ts"];
    private static readonly HashSet<string> TextPosition = ["Td", "TD", "Tm", "T*"];
    private static readonly HashSet<string> Path = ["m", "l", "c", "v", "y", "h", "re"];
    private static readonly HashSet<string> Paint = ["S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n"];
    private static readonly HashSet<string> Show = ["Tj", "TJ", "'", "\""];

    /// <param name="hiddenTag">Whether a /OC property name (without the slash) is a hidden layer.</param>
    /// <param name="hiddenXObject">Whether an XObject name (without the slash) belongs to a hidden layer.</param>
    /// <param name="kept">Why some hidden content had to stay (null when all of it went).</param>
    /// <returns>The new content, or null when nothing changed.</returns>
    public static byte[]? Strip(byte[] content, Func<string, bool> hiddenTag, Func<string, bool> hiddenXObject, out string? kept)
    {
        kept = null;
        var ops = ContentLexer.Parse(content);
        var broken = ops.Count > 0 && ops[^1].Broken;
        using var output = new MemoryStream();
        var copied = 0; // content before this is written
        var changed = false;
        var inText = false;

        void CopyTo(int end)
        {
            if (end > copied) output.Write(content, copied, end - copied);
        }
        void Write(int start, int end)
        {
            output.Write(content, start, end - start);
            output.WriteByte((byte)'\n');
        }

        for (var i = 0; i < ops.Count; i++)
        {
            var op = ops[i];
            switch (op.Name)
            {
                case "BT":
                    inText = true;
                    continue;
                case "ET":
                    inText = false;
                    continue;
                case "Do" when op.Operands.Count > 0 && op.Operands[^1].Kind == CKind.Name && hiddenXObject(op.Operands[^1].Name):
                    CopyTo(op.Start);
                    copied = op.End;
                    changed = true;
                    continue;
                case "BDC" when op.Operands.Count >= 2 && op.Operands[0] is { Kind: CKind.Name, Name: "OC" } && op.Operands[1].Kind == CKind.Name && hiddenTag(op.Operands[1].Name):
                    break;
                default:
                    continue;
            }

            // A hidden section: from this BDC to its EMC (or to the end).
            var end = -1;
            for (int k = i + 1, depth = 1; k < ops.Count; k++)
            {
                if (ops[k].Name is "BMC" or "BDC") depth++;
                else if (ops[k].Name == "EMC" && --depth == 0)
                {
                    end = k;
                    break;
                }
            }
            if (end < 0 && broken)
            {
                kept = "hidden content runs into data that can't be read";
                continue;
            }
            var last = end < 0 ? ops.Count : end;
            if (Section(ops, i + 1, last, inText) is not { } plan)
            {
                kept = "hidden content can't be cut without moving visible text";
                continue;
            }
            if (inText && plan.ShowsText && !NextTextRepositions(ops, last + 1))
            {
                kept = "hidden text can't be cut without moving the visible text after it";
                continue;
            }
            CopyTo(op.Start);
            foreach (var (start, stop, text) in plan.Keep)
            {
                if (text is not null)
                {
                    output.Write(Encoding.ASCII.GetBytes(text));
                    output.WriteByte((byte)'\n');
                }
                else Write(start, stop);
            }
            copied = end < 0 ? content.Length : ops[end].End;
            changed = true;
            i = last;
        }
        if (!changed) return null;
        CopyTo(content.Length);
        return output.ToArray();
    }

    private sealed record Plan(List<(int Start, int End, string? Text)> Keep, bool ShowsText);

    /// <summary>What of ops [from, to) stays: graphics state, clipping paths, and (inside an open text object) text positioning.</summary>
    private static Plan? Section(List<COp> ops, int from, int to, bool inText)
    {
        var keep = new List<(int, int, string?)>();
        var path = new List<(int, int, string?)>();
        var clip = false;
        var ownText = false; // a text object that starts (and ends) inside the section
        var shows = false;
        for (var k = from; k < to; k++)
        {
            var op = ops[k];
            var name = op.Name;
            if (name == "BT")
            {
                if (inText || ownText) return null;
                ownText = true;
                continue;
            }
            if (name == "ET")
            {
                if (!ownText) return null; // closes the text object the section started in
                ownText = false;
                continue;
            }
            if (State.Contains(name)) keep.Add((op.Start, op.End, null));
            else if (Path.Contains(name) || name is "W" or "W*")
            {
                if (name is "W" or "W*") clip = true;
                path.Add((op.Start, op.End, null));
            }
            else if (Paint.Contains(name))
            {
                if (clip)
                {
                    keep.AddRange(path);
                    keep.Add((0, 0, "n"));
                }
                path.Clear();
                clip = false;
            }
            else if (inText && !ownText)
            {
                if (TextPosition.Contains(name)) keep.Add((op.Start, op.End, null));
                else if (name == "'")
                {
                    keep.Add((0, 0, "T*"));
                    shows = true;
                }
                else if (name == "\"" && op.Operands.Count >= 3)
                {
                    keep.Add((0, 0, $"{ContentLexer.Number(op.N(0))} Tw {ContentLexer.Number(op.N(1))} Tc T*"));
                    shows = true;
                }
                else if (Show.Contains(name)) shows = true;
            }
        }
        if (ownText) return null; // a text object left open
        return new Plan(keep, shows);
    }

    /// <summary>Whether the visible text after a cut section starts from a new position (or the text object ends) before it shows anything.</summary>
    private static bool NextTextRepositions(List<COp> ops, int from)
    {
        for (var k = from; k < ops.Count; k++)
        {
            var name = ops[k].Name;
            if (name is "Tj" or "TJ") return false;
            if (name is "Td" or "TD" or "Tm" or "T*" or "'" or "\"" or "ET" or "BT") return true;
        }
        return true;
    }
}
