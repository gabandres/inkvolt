using System.Text;
using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using PdfSharp.Pdf.IO;
using Mat = InkvoltPdf.Core.ContentEditor.Mat;

namespace InkvoltPdf.Core;

public static partial class AutoTag
{
    /// <summary>
    /// Writes the plan's tags (see the class remarks). Tags the document already had are replaced. A signed document's
    /// edit is appended after its signed bytes when it can be (<see cref="PdfObj.Save"/>).
    /// </summary>
    /// <exception cref="SignaturesWouldBreakException">A signed document whose edit can't be appended.</exception>
    /// <exception cref="OwnerPasswordRequiredException">An encrypted document opened without its permissions password.</exception>
    public static byte[] Write(byte[] data, string? password, TagPlan plan, AccessibleOptions? options = null, CancellationToken cancel = default)
    {
        using var doc = PdfObj.Open(data, password, PdfDocumentOpenMode.Modify, "This PDF can't be tagged");
        new Writer(doc, plan, options ?? new AccessibleOptions(), cancel).Run();
        return PdfObj.Save(doc);
    }

    /// <summary>Where a piece of content goes: an element's leaf (and maybe a link inside it), an artifact, or left as it is.</summary>
    private readonly record struct Target(Leaf? Leaf, int Link, bool Artifact, bool Running)
    {
        public static readonly Target Leave = default;
        public static readonly Target Decor = new(null, -1, true, false);
        public static readonly Target Page = new(null, -1, true, true);
        public bool None => Leaf is null && !Artifact;
    }

    /// <summary>A structure element that holds content directly (P, H1, LBody, TD, Figure…), with where its content is.</summary>
    private sealed class Leaf(PdfDictionary elem, string type, int page, IReadOnlyList<RectD> sources, bool figure)
    {
        public PdfDictionary Elem { get; } = elem;
        public string Type { get; } = type;
        public int Page { get; } = page;
        public IReadOnlyList<RectD> Sources { get; } = sources;
        public bool Figure { get; } = figure;
        /// <summary>Pictures in a table cell (their content goes in the cell).</summary>
        public IReadOnlyList<RectD> Pictures { get; init; } = [];
        public PdfArray K { get; } = new();
        /// <summary>Link elements inside it, by the link's index on the page.</summary>
        public Dictionary<int, PdfDictionary> Links { get; } = [];
    }

    private sealed class Writer(PdfDocument doc, TagPlan plan, AccessibleOptions options, CancellationToken cancel)
    {
        private readonly SortedDictionary<int, PdfItem> _parentTree = [];
        private readonly List<Leaf> _leaves = [];
        private readonly Dictionary<PdfDictionary, PdfArray> _kids = new(ReferenceEqualityComparer.Instance);
        private PdfDictionary _root = null!;
        private PdfDictionary _document = null!;
        private int _nextKey;

        public void Run()
        {
            var catalog = doc.Internals.Catalog;
            var hadTags = catalog.Elements.ContainsKey("/StructTreeRoot");
            if (hadTags) RemoveTags();

            _root = Indirect();
            _root.Elements["/Type"] = new PdfName("/StructTreeRoot");
            _document = Elem("Document", _root);
            _root.Elements["/K"] = new PdfArray(doc, _document.Reference!);

            // Top-level elements per page in reading order; what each page adds after its blocks (fields, comments, links
            // without text).
            var blocks = EvenHeadings(plan.Blocks);
            var top = new List<(int Page, PdfDictionary Elem)>();
            foreach (var b in blocks)
                if (Block(b) is { } e) top.Add((b.Page, e));
            var extras = new Dictionary<int, List<PdfDictionary>>();

            var pages = doc.Pages.Cast<PdfPage>().ToList();
            for (var p = 0; p < pages.Count; p++)
            {
                cancel.ThrowIfCancellationRequested();
                var page = pages[p];
                var running = p < plan.Running.Count ? plan.Running[p] : [];
                var more = extras[p] = [];
                TagPage(page, p, [.. _leaves.Where(l => l.Page == p)], running, more, hadTags);
                page.Elements["/Tabs"] = new PdfName("/S");
            }

            // The Document's kids: each page's blocks, then its extras (also for pages without blocks).
            var docKids = Kids(_document);
            var flushed = -1;
            void Flush(int upTo)
            {
                for (var p = flushed + 1; p <= upTo; p++)
                    if (extras.TryGetValue(p, out var list))
                        foreach (var e in list) docKids.Elements.Add(e.Reference!);
                flushed = Math.Max(flushed, upTo);
            }
            foreach (var (page, e) in top)
            {
                Flush(page - 1);
                docKids.Elements.Add(e.Reference!);
            }
            Flush(pages.Count - 1);

            Prune(_document);
            foreach (var (elem, kids) in _kids)
            {
                if (kids.Elements.Count == 0) elem.Elements.Remove("/K");
                else if (kids.Elements.Count == 1 && PdfObj.Resolve(kids.Elements[0]) is PdfInteger) elem.Elements["/K"] = kids.Elements[0];
                else elem.Elements["/K"] = kids;
            }

            var nums = new PdfArray(doc);
            foreach (var (key, value) in _parentTree)
            {
                nums.Elements.Add(new PdfInteger(key));
                nums.Elements.Add(value);
            }
            var parentTree = Indirect();
            parentTree.Elements["/Nums"] = nums;
            _root.Elements["/ParentTree"] = parentTree.Reference!;
            _root.Elements["/ParentTreeNextKey"] = new PdfInteger(_nextKey);
            catalog.Elements["/StructTreeRoot"] = _root.Reference!;

            var markInfo = new PdfDictionary(doc);
            markInfo.Elements["/Marked"] = new PdfBoolean(true);
            catalog.Elements["/MarkInfo"] = markInfo;
            if ((options.Language ?? plan.Language) is { Length: > 0 } lang) catalog.Elements["/Lang"] = new PdfString(lang);
            var prefs = PdfObj.Dict(catalog.Elements["/ViewerPreferences"]) ?? new PdfDictionary(doc);
            prefs.Elements["/DisplayDocTitle"] = new PdfBoolean(true);
            if (!catalog.Elements.ContainsKey("/ViewerPreferences") || PdfObj.Resolve(catalog.Elements["/ViewerPreferences"]) is not PdfDictionary)
                catalog.Elements["/ViewerPreferences"] = prefs;
            if ((options.Title ?? plan.Title) is { Length: > 0 } title) doc.Info.Title = title.Trim();
            if (doc.Version < 14) doc.Version = 17;
            else if (doc.Version > 17) doc.Version = 17; // PDF/UA-1 is PDF 1.7
            doc.Info.ModificationDate = DateTime.Now;
            // PDF/UA wants every font embedded: the standard faces can be, from Windows' metric twins.
            PdfA.EmbedStandardFonts(doc);
            Xmp.MarkPdfUa(doc);
        }

        // ───────────────────────────── elements ─────────────────────────────

        private PdfDictionary Indirect()
        {
            var d = new PdfDictionary(doc);
            doc.Internals.AddObject(d);
            return d;
        }

        private PdfDictionary Elem(string type, PdfDictionary parent)
        {
            var e = Indirect();
            e.Elements["/Type"] = new PdfName("/StructElem");
            e.Elements["/S"] = new PdfName("/" + type);
            e.Elements["/P"] = parent.Reference!;
            return e;
        }

        private PdfArray Kids(PdfDictionary elem)
        {
            if (!_kids.TryGetValue(elem, out var k)) _kids[elem] = k = new PdfArray(doc);
            return k;
        }

        private PdfDictionary Child(string type, PdfDictionary parent)
        {
            var e = Elem(type, parent);
            Kids(parent).Elements.Add(e.Reference!);
            return e;
        }

        private Leaf NewLeaf(PdfDictionary elem, string type, int page, IReadOnlyList<RectD> sources, bool figure = false, IReadOnlyList<RectD>? pictures = null)
        {
            var leaf = new Leaf(elem, type, page, sources, figure) { Pictures = pictures ?? [] };
            _kids[elem] = leaf.K;
            elem.Elements["/Pg"] = doc.Pages[page].Reference!;
            _leaves.Add(leaf);
            return leaf;
        }

        /// <summary>A block's element (not yet in the Document's kids), or null when it adds none (a decorative figure).</summary>
        private PdfDictionary? Block(TagBlock b)
        {
            switch (b.Kind)
            {
                case TagBlockKind.Paragraph or TagBlockKind.Heading:
                {
                    var type = b.Kind == TagBlockKind.Heading ? $"H{Math.Clamp(b.Level, 1, 6)}" : "P";
                    var e = Elem(type, _document);
                    if (b.Lang is { Length: > 0 } lang) e.Elements["/Lang"] = new PdfString(lang);
                    NewLeaf(e, type, b.Page, b.Sources);
                    return e;
                }
                case TagBlockKind.List:
                {
                    var l = Elem("L", _document);
                    foreach (var item in b.Items)
                    {
                        var li = Child("LI", l);
                        NewLeaf(Child("LBody", li), "LBody", b.Page, item.Sources);
                    }
                    return l;
                }
                case TagBlockKind.Table:
                {
                    var t = Elem("Table", _document);
                    for (var r = 0; r < b.Rows.Count; r++)
                    {
                        var tr = Child("TR", t);
                        foreach (var cell in b.Rows[r])
                        {
                            var header = r == 0 && b.HeaderRow;
                            var type = header ? "TH" : "TD";
                            var c = Child(type, tr);
                            if (header || cell.ColSpan > 1)
                            {
                                var a = new PdfDictionary(doc);
                                a.Elements["/O"] = new PdfName("/Table");
                                if (header) a.Elements["/Scope"] = new PdfName("/Column");
                                if (cell.ColSpan > 1) a.Elements["/ColSpan"] = new PdfInteger(cell.ColSpan);
                                c.Elements["/A"] = a;
                            }
                            NewLeaf(c, type, b.Page, cell.Sources, pictures: cell.Pictures);
                        }
                    }
                    return t;
                }
                case TagBlockKind.Figure:
                {
                    if (b.Decorative)
                    {
                        // Its content becomes an artifact: a leaf that isn't in the tree.
                        var none = new Leaf(new PdfDictionary(doc), "", b.Page, b.Sources, figure: true);
                        _leaves.Add(none);
                        return null;
                    }
                    var e = Elem("Figure", _document);
                    if (!string.IsNullOrWhiteSpace(b.Alt)) e.Elements["/Alt"] = PdfObj.MakeString(b.Alt.Trim());
                    var page = doc.Pages[b.Page];
                    var (x1, y1) = PdfObj.ToPdf(page, b.Box.X, b.Box.Bottom);
                    var (x2, y2) = PdfObj.ToPdf(page, b.Box.Right, b.Box.Y);
                    var a = new PdfDictionary(doc);
                    a.Elements["/O"] = new PdfName("/Layout");
                    a.Elements["/Placement"] = new PdfName("/Block");
                    a.Elements["/BBox"] = PdfObj.Reals(doc, Math.Min(x1, x2), Math.Min(y1, y2), Math.Max(x1, x2), Math.Max(y1, y2));
                    e.Elements["/A"] = a;
                    NewLeaf(e, "Figure", b.Page, b.Sources, figure: true);
                    return e;
                }
                default:
                    return null;
            }
        }

        /// <summary>Removes elements left without content (a paragraph whose text wasn't found); true when <paramref name="e"/> is empty.</summary>
        private bool Prune(PdfDictionary e, int depth = 0)
        {
            if (!_kids.TryGetValue(e, out var kids)) return true;
            if (depth > 64) return false;
            var leaf = _leaves.FirstOrDefault(l => ReferenceEquals(l.Elem, e));
            if (leaf is not null) return kids.Elements.Count == 0;
            var type = PdfObj.Name(e.Elements["/S"]);
            for (var i = kids.Elements.Count - 1; i >= 0; i--)
                if (PdfObj.Dict(kids.Elements[i]) is { } kid && PdfObj.NameOf(kid, "/Type") == "/StructElem" && Prune(kid, depth + 1))
                {
                    // A table keeps its empty cells (rows stay the same length); an empty row or table goes.
                    var cell = PdfObj.Name(kid.Elements["/S"]) is "TD" or "TH";
                    if (cell) continue;
                    kids.Elements.RemoveAt(i);
                }
            if (type == "TR" && kids.Elements.All(k => PdfObj.Dict(k) is { } c && _kids.TryGetValue(c, out var ck) && ck.Elements.Count == 0)) return true;
            return kids.Elements.Count == 0;
        }

        // ───────────────────────────── a page ─────────────────────────────

        private void TagPage(PdfPage page, int index, List<Leaf> leaves, IReadOnlyList<RectD> running, List<PdfDictionary> extras, bool strip)
        {
            var annots = PdfObj.Array(page.Elements["/Annots"])?.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().ToList() ?? [];
            var links = annots.Where(a => PdfObj.NameOf(a, "/Subtype") == "/Link" && PdfObj.Array(a.Elements["/Rect"]) is not null)
                .Select(a => (Annot: a, Box: PdfObj.RectToPage(page, PdfObj.Array(a.Elements["/Rect"])!))).ToList();

            var content = ContentEditor.ContentBytes(page);
            var resources = Resources(page);
            var walk = new PageWalk(page, resources, cancel);
            var ops = ContentLexer.Parse(content, cancel);
            var items = walk.Items(ops, strip);
            var linkText = links.Select(_ => new StringBuilder()).ToList();

            Target Assign(Item it)
            {
                if (it.InArtifact || it.ArtifactOnly) return Target.Leave;
                switch (it.Kind)
                {
                    case ItemKind.Text:
                    case ItemKind.Form when it.HasText:
                    {
                        Leaf? best = null;
                        double bestScore = 0;
                        foreach (var l in leaves)
                        {
                            var s = 0.0;
                            foreach (var src in l.Sources) s += Area(it.Box.Intersect(src));
                            if (s > bestScore)
                            {
                                bestScore = s;
                                best = l;
                            }
                        }
                        var runScore = running.Sum(r => Area(it.Box.Intersect(r)));
                        if (runScore > bestScore) return Target.Page;
                        if (best is null)
                        {
                            if (it.Kind == ItemKind.Text && string.IsNullOrWhiteSpace(it.Text)) return Target.Decor;
                            // Not where the layout found text (a stray mark, text it dropped): the nearest text block.
                            var (cx, cy) = (it.Box.CenterX, it.Box.CenterY);
                            var near = leaves.Where(l => !l.Figure && l.Sources.Count > 0)
                                .Select(l => (l, d: l.Sources.Min(s => Distance(s, cx, cy)))).Where(x => x.d < 24).MinBy(x => x.d).l;
                            best = near ?? leaves.FirstOrDefault(l => l.Figure && l.Sources.Any(s => s.Inflate(2).Contains(cx, cy)));
                            if (best is null) return Target.Decor;
                        }
                        if (best.Type == "") return Target.Decor;
                        if (!best.Figure)
                            for (var k = 0; k < links.Count; k++)
                                if (links[k].Box.Inflate(1).Contains(it.Box.CenterX, it.Box.CenterY))
                                {
                                    linkText[k].Append(it.Text);
                                    return new Target(best, k, false, false);
                                }
                        return new Target(best, -1, false, false);
                    }
                    case ItemKind.Image:
                    case ItemKind.Form:
                    {
                        var area = Math.Max(1, Area(it.Box));
                        if (running.Sum(r => Area(it.Box.Intersect(r))) > 0.5 * area) return Target.Page;
                        Leaf? best = null;
                        double bestScore = 0;
                        foreach (var l in leaves)
                        {
                            var s = l.Figure ? l.Sources.Sum(src => Area(it.Box.Intersect(src))) : l.Pictures.Sum(src => Area(it.Box.Intersect(src)));
                            var whole = l.Figure ? l.Sources.Sum(Area) : l.Pictures.Sum(Area);
                            if (s >= 0.3 * Math.Min(area, Math.Max(1, whole)) && s > bestScore)
                            {
                                bestScore = s;
                                best = l;
                            }
                        }
                        return best is null || best.Type == "" ? Target.Decor : new Target(best, -1, false, false);
                    }
                    default: // paths and shadings: part of a chart or diagram, or decoration (rules, backgrounds, underlines)
                    {
                        var (cx, cy) = (it.Box.CenterX, it.Box.CenterY);
                        var fig = leaves.FirstOrDefault(l => l.Figure && l.Sources.Any(s => s.Inflate(2).Contains(cx, cy) && s.Inflate(2).Contains(it.Box.X, it.Box.Y) && s.Inflate(2).Contains(it.Box.Right, it.Box.Bottom)));
                        return fig is null || fig.Type == "" ? Target.Decor : new Target(fig, -1, false, false);
                    }
                }
            }

            // Marked content around each run of items that go to the same place.
            var output = new MemoryStream(content.Length + items.Count * 24);
            var cursor = 0;
            void Emit(int at, string text, int remove = 0)
            {
                output.Write(content, cursor, at - cursor);
                var bytes = Encoding.Latin1.GetBytes(text);
                output.Write(bytes);
                cursor = at + remove;
            }
            var mcids = new List<PdfItem>();
            Target? open = null;
            void Close(int at)
            {
                if (open is null) return;
                Emit(at, "\nEMC\n");
                open = null;
            }
            void Open(int at, Target t)
            {
                if (t.Artifact)
                {
                    Emit(at, t.Running ? "\n/Artifact <</Type /Pagination>> BDC\n" : "\n/Artifact BMC\n");
                    open = t;
                    return;
                }
                var leaf = t.Leaf!;
                var owner = leaf.Elem;
                var type = leaf.Type;
                if (t.Link >= 0)
                {
                    if (!leaf.Links.TryGetValue(t.Link, out var link))
                    {
                        link = Elem("Link", leaf.Elem);
                        link.Elements["/Pg"] = page.Reference!;
                        _kids[link] = new PdfArray(doc);
                        leaf.K.Elements.Add(link.Reference!);
                        leaf.Links[t.Link] = link;
                    }
                    owner = link;
                    type = "Link";
                }
                var mcid = mcids.Count;
                mcids.Add(owner.Reference!);
                if (t.Link >= 0) _kids[owner].Elements.Add(new PdfInteger(mcid));
                else leaf.K.Elements.Add(new PdfInteger(mcid));
                Emit(at, $"\n/{type} <</MCID {mcid}>> BDC\n");
                open = t;
            }

            var next = 0;
            var spanEnd = -1;
            for (var i = 0; i < ops.Count; i++)
            {
                var op = ops[i];
                if (spanEnd >= 0)
                {
                    Emit(spanEnd, "\nEMC\n");
                    spanEnd = -1;
                }
                if (op.Name is "BT" or "ET" or "q" or "Q" or "BMC" or "BDC" or "EMC") Close(op.Start);
                if (walk.Stripped.TryGetValue(i, out var instead))
                {
                    Emit(op.Start, instead, op.End - op.Start);
                    continue;
                }
                while (next < items.Count && items[next].StartOp < i) next++;
                if (next >= items.Count || items[next].StartOp != i) continue;
                var t = Assign(items[next]);
                if (open is { } o && o != t) Close(op.Start);
                if (open is null && !t.None) Open(op.Start, t);
                // A form drawn inside our marked content can't mark artifacts of its own (they'd be nested): they go.
                if (!t.None && items[next] is { HasArtifact: true, Form: { } form }) UnmarkArtifacts(form);
                // Characters a font maps into the Private Use Area (Word's Symbol and Wingdings bullets) say what they are.
                if (!t.None && items[next] is { Kind: ItemKind.Text } ti && ActualText(ti.Text) is { } actual && ti.StartOp == ti.EndOp)
                {
                    Emit(op.Start, $"\n/Span <</ActualText <FEFF{Convert.ToHexString(Encoding.BigEndianUnicode.GetBytes(actual))}>>> BDC\n");
                    spanEnd = op.End;
                }
            }
            if (spanEnd >= 0) Emit(spanEnd, "\nEMC\n");
            Close(content.Length);
            output.Write(content, cursor, content.Length - cursor);

            var stream = PdfObj.AddStream(doc, output.ToArray());
            page.Elements["/Contents"] = stream.Reference!;
            if (mcids.Count > 0)
            {
                var key = _nextKey++;
                page.Elements["/StructParents"] = new PdfInteger(key);
                _parentTree[key] = new PdfArray(doc, [.. mcids]);
            }
            else page.Elements.Remove("/StructParents");

            // Links: the annotation goes in its Link element (one with text when there is one).
            for (var k = 0; k < links.Count; k++)
            {
                var (annot, _) = links[k];
                var link = leaves.Select(l => l.Links.GetValueOrDefault(k)).FirstOrDefault(x => x is not null);
                if (link is null)
                {
                    link = Elem("Link", _document);
                    link.Elements["/Pg"] = page.Reference!;
                    _kids[link] = new PdfArray(doc);
                    extras.Add(link);
                }
                Objr(link, annot, page);
                if (!HasText(annot, "/Contents"))
                {
                    var text = string.Join(' ', linkText[k].ToString().Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
                    var uri = PdfObj.Text(PdfObj.Dict(annot.Elements["/A"])?.Elements["/URI"]);
                    var say = text.Length > 0 ? text : uri is { Length: > 0 } ? $"Link to {uri}" : "Link";
                    annot.Elements["/Contents"] = PdfObj.MakeString(say);
                }
            }
            // Form fields and comments: Form and Annot elements after the page's blocks.
            foreach (var a in annots)
            {
                var sub = PdfObj.NameOf(a, "/Subtype");
                if (sub is "/Link" or "/Popup" or "/PrinterMark" or "") continue;
                var e = Elem(sub == "/Widget" ? "Form" : "Annot", _document);
                e.Elements["/Pg"] = page.Reference!;
                _kids[e] = new PdfArray(doc);
                Objr(e, a, page);
                extras.Add(e);
            }
        }

        private readonly HashSet<PdfDictionary> _unmarked = new(ReferenceEqualityComparer.Instance);

        /// <summary>Removes a form's own artifact marked content (its operators, not what they enclose).</summary>
        private void UnmarkArtifacts(PdfDictionary form)
        {
            if (!_unmarked.Add(form)) return;
            var bytes = PdfObj.StreamBytes(form);
            var ops = ContentLexer.Parse(bytes, cancel);
            var drop = new List<int>();
            var stack = new Stack<bool>();
            for (var i = 0; i < ops.Count; i++)
            {
                if (ops[i].Name is "BMC" or "BDC")
                {
                    var artifact = ops[i].Operands.Count > 0 && ops[i].Operands[0] is { Kind: CKind.Name, Name: "Artifact" };
                    stack.Push(artifact);
                    if (artifact) drop.Add(i);
                }
                else if (ops[i].Name == "EMC" && stack.Count > 0 && stack.Pop()) drop.Add(i);
            }
            if (drop.Count == 0) return;
            using var ms = new MemoryStream(bytes.Length);
            var at = 0;
            foreach (var i in drop)
            {
                ms.Write(bytes, at, ops[i].Start - at);
                ms.WriteByte((byte)' ');
                at = ops[i].End;
            }
            ms.Write(bytes, at, bytes.Length - at);
            SetStream(form, ms.ToArray());
        }

        private static void SetStream(PdfDictionary x, byte[] bytes)
        {
            x.Elements.Remove("/Filter");
            x.Elements.Remove("/DecodeParms");
            x.Stream.Value = PdfObj.Deflate(bytes);
            x.Elements["/Filter"] = new PdfName("/FlateDecode");
        }

        private void Objr(PdfDictionary elem, PdfDictionary annot, PdfPage page)
        {
            var objr = new PdfDictionary(doc);
            objr.Elements["/Type"] = new PdfName("/OBJR");
            objr.Elements["/Obj"] = annot.Reference is { } r ? r : annot;
            objr.Elements["/Pg"] = page.Reference!;
            _kids[elem].Elements.Add(objr);
            var key = _nextKey++;
            annot.Elements["/StructParent"] = new PdfInteger(key);
            _parentTree[key] = elem.Reference!;
        }

        private static bool HasText(PdfDictionary d, string key) => !string.IsNullOrWhiteSpace(PdfObj.Text(d.Elements[key]));

        /// <summary>The tags the document had: the tree, its keys on pages, annotations and forms (their marked content goes as each stream is rewritten).</summary>
        private void RemoveTags()
        {
            var catalog = doc.Internals.Catalog;
            catalog.Elements.Remove("/StructTreeRoot");
            foreach (var page in doc.Pages.Cast<PdfPage>())
            {
                page.Elements.Remove("/StructParents");
                if (PdfObj.Array(page.Elements["/Annots"]) is { } annots)
                    foreach (var a in annots.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()) a.Elements.Remove("/StructParent");
                StripForms(Resources(page), 0, new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance));
            }
        }

        /// <summary>Forms drawn on a page that had marked content of their own (StructParents): their MCIDs go.</summary>
        private void StripForms(PdfDictionary? resources, int depth, HashSet<PdfDictionary> seen)
        {
            if (depth > 8 || PdfObj.Dict(resources?.Elements["/XObject"]) is not { } xs) return;
            foreach (var key in xs.Elements.Keys.ToList())
            {
                if (PdfObj.Dict(xs.Elements[key]) is not { Stream: not null } x || !seen.Add(x) || PdfObj.NameOf(x, "/Subtype") != "/Form") continue;
                var sub = PdfObj.Dict(x.Elements["/Resources"]);
                if (x.Elements.ContainsKey("/StructParents") || x.Elements.ContainsKey("/StructParent"))
                {
                    x.Elements.Remove("/StructParents");
                    x.Elements.Remove("/StructParent");
                    var bytes = PdfObj.StreamBytes(x);
                    var ops = ContentLexer.Parse(bytes, cancel);
                    var walk = new PageWalk(null, sub, cancel);
                    walk.Items(ops, strip: true);
                    if (walk.Stripped.Count > 0)
                    {
                        using var ms = new MemoryStream(bytes.Length);
                        var at = 0;
                        foreach (var (i, instead) in walk.Stripped.OrderBy(kv => kv.Key))
                        {
                            ms.Write(bytes, at, ops[i].Start - at);
                            ms.Write(Encoding.Latin1.GetBytes(instead));
                            at = ops[i].End;
                        }
                        ms.Write(bytes, at, bytes.Length - at);
                        SetStream(x, ms.ToArray());
                    }
                }
                StripForms(sub, depth + 1, seen);
            }
        }
    }

    internal static PdfDictionary? Resources(PdfPage page)
    {
        PdfDictionary? node = page;
        for (var guard = 0; node is not null && guard < 64; guard++, node = PdfObj.Dict(node.Elements["/Parent"]))
            if (PdfObj.Dict(node.Elements["/Resources"]) is { } r) return r;
        return null;
    }

    /// <summary>Private Use Area characters the symbol fonts use for bullets and marks, as the characters they show.</summary>
    private static readonly Dictionary<char, string> PuaSymbols = new()
    {
        [''] = "•", [''] = "▪", [''] = "●", [''] = "■", [''] = "➢", [''] = "✓",
        [''] = "❖", [''] = "°", [''] = "×", [''] = "±", [''] = "→", [''] = "◆",
    };

    /// <summary>The text with Private Use Area characters replaced (unknown ones dropped), or null when it has none.</summary>
    private static string? ActualText(string text)
    {
        if (!text.Any(c => c is >= '' and <= '')) return null;
        var sb = new StringBuilder(text.Length);
        foreach (var c in text)
            if (c is >= '' and <= '') sb.Append(PuaSymbols.GetValueOrDefault(c, ""));
            else sb.Append(c);
        return sb.ToString();
    }

    private static double Area(RectD r) => r.IsEmpty ? 0 : r.Width * r.Height;

    private static double Distance(RectD r, double x, double y)
    {
        var dx = Math.Max(0, Math.Max(r.X - x, x - r.Right));
        var dy = Math.Max(0, Math.Max(r.Y - y, y - r.Bottom));
        return Math.Sqrt(dx * dx + dy * dy);
    }

    // ───────────────────────────── reading content ─────────────────────────────

    private enum ItemKind { Text, Image, Path, Shading, Form }

    /// <summary>One thing a content stream draws: from its first operator to its last (a path from its first point to its paint).</summary>
    private sealed record Item(int StartOp, int EndOp, ItemKind Kind, RectD Box, string Text, bool InArtifact, bool HasText = false)
    {
        /// <summary>A form whose own content marks some of what it draws as artifacts (all of it: <see cref="ArtifactOnly"/>).</summary>
        public PdfDictionary? Form { get; init; }
        public bool HasArtifact { get; init; }
        public bool ArtifactOnly { get; init; }
    }

    /// <summary>
    /// Walks a content stream for what it draws and where (page space as shown): text shown, images, paths, shadings and
    /// forms. Notes the marked content around each item (inside an artifact already, it is left alone), and with
    /// <c>strip</c> the BDC operators that carry an MCID and their EMC (tags being replaced) in <see cref="Stripped"/>.
    /// </summary>
    private sealed class PageWalk(PdfPage? page, PdfDictionary? resources, CancellationToken cancel)
    {
        /// <summary>Operators to replace (by index): an MCID's BDC and its EMC by nothing, an artifact's BDC with an MCID by a plain BMC.</summary>
        public Dictionary<int, string> Stripped { get; } = [];

        private sealed class State
        {
            public Mat Ctm = Mat.Identity;
            public PdfDictionary? Font;
            public double Size = 12, CharSpace, WordSpace, Scale = 1, Leading, Rise;
            public State Clone() => (State)MemberwiseClone();
        }

        public List<Item> Items(List<COp> ops, bool strip)
        {
            var items = new List<Item>();
            var st = new State();
            var stack = new Stack<State>();
            var tm = Mat.Identity;
            var tlm = Mat.Identity;
            var path = new List<(double X, double Y)>();
            var pathStart = -1;
            var marks = new List<(bool Artifact, bool Strip, int Op)>();
            for (var i = 0; i < ops.Count; i++)
            {
                if ((i & 4095) == 0) cancel.ThrowIfCancellationRequested();
                var op = ops[i];
                var inArtifact = marks.Any(m => m.Artifact);
                switch (op.Name)
                {
                    case "q":
                        if (stack.Count < 256) stack.Push(st.Clone());
                        break;
                    case "Q":
                        if (stack.Count > 0) st = stack.Pop();
                        break;
                    case "cm" when op.Operands.Count >= 6:
                        st.Ctm = new Mat(op.N(0), op.N(1), op.N(2), op.N(3), op.N(4), op.N(5)).Times(st.Ctm);
                        break;
                    case "BMC" or "BDC":
                    {
                        var tag = op.Operands.Count > 0 && op.Operands[0].Kind == CKind.Name ? op.Operands[0].Name : "";
                        var hasMcid = op.Name == "BDC" && op.Operands.Count > 1 &&
                                      (op.Operands[1] is { Kind: CKind.Dict } d && d["MCID"] is not null ||
                                       op.Operands[1] is { Kind: CKind.Name } n && PdfObj.Dict(PdfObj.Dict(resources?.Elements["/Properties"])?.Elements["/" + n.Name])?.Elements.ContainsKey("/MCID") == true);
                        var drop = strip && hasMcid && tag != "Artifact";
                        if (drop) Stripped[i] = " ";
                        else if (strip && hasMcid) Stripped[i] = " /Artifact BMC ";
                        marks.Add((tag == "Artifact", drop, i));
                        break;
                    }
                    case "EMC":
                        if (marks.Count > 0)
                        {
                            if (marks[^1].Strip) Stripped[i] = " ";
                            marks.RemoveAt(marks.Count - 1);
                        }
                        break;
                    case "BT":
                        tm = tlm = Mat.Identity;
                        break;
                    case "Tf" when op.Operands.Count >= 2:
                        st.Font = op.Operands[0].Kind == CKind.Name ? PdfObj.Dict(PdfObj.Dict(resources?.Elements["/Font"])?.Elements["/" + op.Operands[0].Name]) : null;
                        st.Size = op.N(1);
                        break;
                    case "Tc" when op.Operands.Count >= 1: st.CharSpace = op.N(0); break;
                    case "Tw" when op.Operands.Count >= 1: st.WordSpace = op.N(0); break;
                    case "Tz" when op.Operands.Count >= 1: st.Scale = op.N(0) / 100; break;
                    case "TL" when op.Operands.Count >= 1: st.Leading = op.N(0); break;
                    case "Ts" when op.Operands.Count >= 1: st.Rise = op.N(0); break;
                    case "Td" when op.Operands.Count >= 2:
                        tlm = new Mat(1, 0, 0, 1, op.N(0), op.N(1)).Times(tlm);
                        tm = tlm;
                        break;
                    case "TD" when op.Operands.Count >= 2:
                        st.Leading = -op.N(1);
                        tlm = new Mat(1, 0, 0, 1, op.N(0), op.N(1)).Times(tlm);
                        tm = tlm;
                        break;
                    case "Tm" when op.Operands.Count >= 6:
                        tm = tlm = new Mat(op.N(0), op.N(1), op.N(2), op.N(3), op.N(4), op.N(5));
                        break;
                    case "T*":
                        tlm = new Mat(1, 0, 0, 1, 0, -st.Leading).Times(tlm);
                        tm = tlm;
                        break;
                    case "Tj" or "'" or "\"" or "TJ":
                    {
                        if (op.Name is "'" or "\"")
                        {
                            if (op.Name == "\"" && op.Operands.Count >= 3)
                            {
                                st.WordSpace = op.N(0);
                                st.CharSpace = op.N(1);
                            }
                            tlm = new Mat(1, 0, 0, 1, 0, -st.Leading).Times(tlm);
                            tm = tlm;
                        }
                        var start = tm;
                        var text = new StringBuilder();
                        foreach (var o in op.Operands)
                        {
                            if (o.Kind == CKind.String) Show(o.Bytes, st, ref tm, text);
                            else if (o.Kind == CKind.Array)
                                foreach (var item in o.Items)
                                {
                                    if (item.Kind == CKind.String) Show(item.Bytes, st, ref tm, text);
                                    else if (item.Kind == CKind.Number)
                                    {
                                        tm = new Mat(1, 0, 0, 1, -item.Num / 1000 * st.Size * st.Scale, 0).Times(tm);
                                        if (item.Num < -200) text.Append(' '); // a gap that reads as a space
                                    }
                                }
                        }
                        items.Add(new Item(i, i, ItemKind.Text, TextBox(start, tm, st), text.ToString(), inArtifact));
                        break;
                    }
                    case "m" or "l" when op.Operands.Count >= 2:
                        if (pathStart < 0) pathStart = i;
                        path.Add((op.N(0), op.N(1)));
                        break;
                    case "c" when op.Operands.Count >= 6:
                        if (pathStart < 0) pathStart = i;
                        path.Add((op.N(0), op.N(1)));
                        path.Add((op.N(2), op.N(3)));
                        path.Add((op.N(4), op.N(5)));
                        break;
                    case "v" or "y" when op.Operands.Count >= 4:
                        if (pathStart < 0) pathStart = i;
                        path.Add((op.N(0), op.N(1)));
                        path.Add((op.N(2), op.N(3)));
                        break;
                    case "re" when op.Operands.Count >= 4:
                        if (pathStart < 0) pathStart = i;
                        path.Add((op.N(0), op.N(1)));
                        path.Add((op.N(0) + op.N(2), op.N(1) + op.N(3)));
                        break;
                    case "h" or "W" or "W*":
                        if (pathStart < 0) pathStart = i;
                        break;
                    case "f" or "F" or "f*" or "B" or "B*" or "b" or "b*" or "S" or "s":
                        items.Add(new Item(pathStart < 0 ? i : pathStart, i, ItemKind.Path, Box(path, st.Ctm), "", inArtifact));
                        path.Clear();
                        pathStart = -1;
                        break;
                    case "n":
                        path.Clear();
                        pathStart = -1;
                        break;
                    case "sh":
                        items.Add(new Item(i, i, ItemKind.Shading, Box([(0, 0), (1, 1)], st.Ctm), "", inArtifact));
                        break;
                    case "BI":
                        items.Add(new Item(i, i, ItemKind.Image, Box([(0, 0), (1, 1), (0, 1), (1, 0)], st.Ctm), "", inArtifact));
                        break;
                    case "Do" when op.Operands.Count > 0 && op.Operands[0].Kind == CKind.Name:
                    {
                        if (PdfObj.Dict(PdfObj.Dict(resources?.Elements["/XObject"])?.Elements["/" + op.Operands[0].Name]) is not { } x) break;
                        var sub = PdfObj.NameOf(x, "/Subtype");
                        if (sub == "/Image")
                            items.Add(new Item(i, i, ItemKind.Image, Box([(0, 0), (1, 1), (0, 1), (1, 0)], st.Ctm), "", inArtifact));
                        else if (sub == "/Form")
                        {
                            var m = PdfObj.Array(x.Elements["/Matrix"]) is { Elements.Count: 6 } a
                                ? new Mat(PdfObj.Num(a, 0), PdfObj.Num(a, 1), PdfObj.Num(a, 2), PdfObj.Num(a, 3), PdfObj.Num(a, 4), PdfObj.Num(a, 5))
                                : Mat.Identity;
                            var bb = PdfObj.Array(x.Elements["/BBox"]);
                            List<(double, double)> corners = bb is { Elements.Count: 4 }
                                ? [(PdfObj.Num(bb, 0), PdfObj.Num(bb, 1)), (PdfObj.Num(bb, 2), PdfObj.Num(bb, 3)), (PdfObj.Num(bb, 0), PdfObj.Num(bb, 3)), (PdfObj.Num(bb, 2), PdfObj.Num(bb, 1))]
                                : [(0, 0), (1, 1)];
                            var bytes = SafeBytes(x);
                            var hasText = bytes.AsSpan().IndexOf("Tj"u8) >= 0 || bytes.AsSpan().IndexOf("TJ"u8) >= 0;
                            bool hasArtifact = false, artifactOnly = false;
                            if (bytes.AsSpan().IndexOf("/Artifact"u8) >= 0)
                            {
                                var inner = new PageWalk(null, PdfObj.Dict(x.Elements["/Resources"]) ?? resources, cancel).Items(ContentLexer.Parse(bytes, cancel), strip: false);
                                hasArtifact = inner.Any(t => t.InArtifact);
                                artifactOnly = inner.Count > 0 && inner.All(t => t.InArtifact);
                            }
                            items.Add(new Item(i, i, ItemKind.Form, Box(corners, m.Times(st.Ctm)), "", inArtifact, hasText)
                            {
                                Form = x, HasArtifact = hasArtifact, ArtifactOnly = artifactOnly,
                            });
                        }
                        break;
                    }
                }
            }
            return items;
        }

        private static byte[] SafeBytes(PdfDictionary x)
        {
            try
            {
                return PdfObj.StreamBytes(x);
            }
            catch (Exception ex) when (ex is InvalidDataException or InvalidOperationException or ArgumentException or NotSupportedException or NotImplementedException or IndexOutOfRangeException)
            {
                return [];
            }
        }

        private static void Show(byte[] bytes, State st, ref Mat tm, StringBuilder text)
        {
            if (st.Font is not { } font)
            {
                tm = new Mat(1, 0, 0, 1, bytes.Length * 0.5 * st.Size * st.Scale, 0).Times(tm);
                return;
            }
            foreach (var g in TextFont.For(font).Decode(bytes))
            {
                text.Append(g.Text);
                var tx = (g.Width * st.Size + st.CharSpace + (g.Length == 1 && g.Code == 32 ? st.WordSpace : 0)) * st.Scale;
                tm = new Mat(1, 0, 0, 1, tx, 0).Times(tm);
            }
        }

        private RectD TextBox(Mat start, Mat end, State st)
        {
            var size = st.Size == 0 ? 1 : st.Size;
            var trs = new Mat(size * st.Scale, 0, 0, size, 0, st.Rise);
            var a = trs.Times(start).Times(st.Ctm);
            var b = trs.Times(end).Times(st.Ctm);
            return Box([a.Apply(0, -0.2), a.Apply(0, 0.8), b.Apply(0, -0.2), b.Apply(0, 0.8)], Mat.Identity);
        }

        private RectD Box(List<(double X, double Y)> pts, Mat ctm)
        {
            if (page is null || pts.Count == 0) return default;
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
            if (!double.IsFinite(l) || !double.IsFinite(r) || !double.IsFinite(t) || !double.IsFinite(b)) return default;
            return new RectD(l, t, Math.Max(r - l, 0.5), Math.Max(b - t, 0.5));
        }
    }
}
