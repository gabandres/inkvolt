using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;
using Mat = InkvoltPdf.Core.ContentEditor.Mat;

namespace InkvoltPdf.Core;

public static partial class AccessibilityCheck
{
    /// <summary>What a font is used for: the codes drawn (and of those, the ones that show), where it is first used.</summary>
    private sealed class FontUse
    {
        public HashSet<int> Codes { get; } = [];
        public HashSet<int> Shown { get; } = [];
        public int Page { get; set; } = -1;
        public RectD Box { get; set; }
    }

    private sealed partial class Checker
    {
        private const int MaxOperators = 2_000_000, MaxFormDepth = 12;

        private readonly Dictionary<PdfDictionary, FontUse> _fonts = new(ReferenceEqualityComparer.Instance);
        /// <summary>Form XObjects drawn from page content: how often, whether they hold marked-content ids, where first.</summary>
        private readonly Dictionary<PdfDictionary, (int Uses, bool Tagged, int Page)> _forms = new(ReferenceEqualityComparer.Instance);
        private readonly HashSet<PdfDictionary> _refForms = new(ReferenceEqualityComparer.Instance);

        private void Pages()
        {
            for (var p = 0; p < doc.PageCount; p++)
            {
                cancel.ThrowIfCancellationRequested();
                var page = doc.Pages[p];
                var walk = new Walk(this, p, page);
                try
                {
                    walk.Run(ContentEditor.ContentBytes(page), PdfObj.Dict(page.Elements["/Resources"]), Mat.Identity, PdfObj.Int(page.Elements["/StructParents"]), [], 0, contentOnly: false);
                }
                catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or IndexOutOfRangeException or NullReferenceException)
                {
                    _notes.Add($"Page {p + 1}'s content couldn't be read in full: {ex.Message}");
                }
                if (walk.Stopped) _notes.Add($"Page {p + 1}: its content is very long; only the first {MaxOperators:N0} drawing steps were checked.");
                if (walk.Untagged > 0)
                    Add("01-005", $"{Count(walk.Untagged, "content item")} on this page {(walk.Untagged == 1 ? "is" : "are")} neither tagged nor marked as an artifact (text, pictures or drawings a screen reader can't place).",
                        p, walk.UntaggedBox, "Page content", walk.Untagged);
                if (walk.ArtifactInTagged > 0)
                    Add("01-003", $"{Count(walk.ArtifactInTagged, "artifact")} on this page {(walk.ArtifactInTagged == 1 ? "is" : "are")} inside tagged content.", p, default, "Page content", walk.ArtifactInTagged);
                if (walk.TaggedInArtifact > 0)
                    Add("01-004", $"{Count(walk.TaggedInArtifact, "piece")} of tagged content on this page {(walk.TaggedInArtifact == 1 ? "is" : "are")} inside an artifact.", p, default, "Page content", walk.TaggedInArtifact);
                if (walk.NoLang > 0)
                    Add("11-001", $"The language of {Count(walk.NoLang, "piece")} of text on this page can't be told: the document, its tags and its marked content give none.", p, walk.NoLangBox, "Page text", walk.NoLang);
                if (walk.SpanNoLang > 0)
                    Add("11-002", $"{Count(walk.SpanNoLang, "span")} of marked content on this page {(walk.SpanNoLang == 1 ? "has" : "have")} alternate, actual or expansion text without a language.", p, default, "Page content", walk.SpanNoLang);
                foreach (var lang in walk.BadLangs) Add("UA 7.2-Lang", $"Marked content on this page has the language “{Short(lang)}”, which isn't a language code.", p, default, "Page content");
                Annotations(p, page);
                Step(p + 1);
            }
            foreach (var (form, use) in _forms)
                if (use.Tagged && use.Uses > 1)
                    Add("30-002", $"A form XObject with tagged content is drawn {use.Uses} times, so its tags would stand for several places at once.", use.Page, default, "Form XObject");
            foreach (var form in _refForms) Add("30-001", "The document draws content taken from another file (a reference XObject).", element: "Form XObject");
            FormFields();
        }

        private void UseFont(PdfDictionary font, IEnumerable<int> codes, bool shown, int page, RectD box)
        {
            if (!_fonts.TryGetValue(font, out var use))
            {
                _fonts[font] = use = new FontUse { Page = page, Box = box };
            }
            foreach (var c in codes)
            {
                use.Codes.Add(c);
                if (shown) use.Shown.Add(c);
            }
        }

        /// <summary>The element a marked-content id stands for (through the parent tree), and whether it stands for any.</summary>
        private (bool Tagged, Elem? Elem) ByMcid(int? key, int mcid)
        {
            if (key is not { } k || !_parentTree.TryGetValue(k, out var value)) return (false, null);
            if (PdfObj.Resolve(value) is not PdfArray a || mcid < 0 || mcid >= a.Elements.Count) return (false, null);
            // Tagged only when the element is in the tree: one the root doesn't lead to tags nothing.
            return PdfObj.Dict(a.Elements[mcid]) is { } d && _elems.TryGetValue(d, out var e) ? (true, e) : (false, null);
        }

        // ───────────────────────────── content ─────────────────────────────

        /// <summary>One marked-content sequence open around what is drawn.</summary>
        private sealed record Mc(string Tag, int? Mcid, int? Key, bool Tagged, Elem? Elem, bool Lang);

        /// <summary>Walks a page's content and the forms it draws: every item tagged or artifact, languages, fonts used.</summary>
        private sealed class Walk(Checker c, int pageIndex, PdfPage page)
        {
            public int Untagged, ArtifactInTagged, TaggedInArtifact, NoLang, SpanNoLang;
            public RectD UntaggedBox, NoLangBox;
            public readonly HashSet<string> BadLangs = new(StringComparer.Ordinal);
            public bool Stopped;
            private int _ops;
            private readonly HashSet<PdfDictionary> _active = new(ReferenceEqualityComparer.Instance);

            private sealed class State
            {
                public Mat Ctm = Mat.Identity;
                public PdfDictionary? Font;
                public double Size = 12, CharSpace, WordSpace, Scale = 1, Leading, Rise;
                public int Mode;
                public State Clone() => (State)MemberwiseClone();
            }

            /// <param name="contentOnly">An annotation's appearance: only its fonts count.</param>
            public void Run(byte[] content, PdfDictionary? resources, Mat ctm, int? key, List<Mc> marks, int depth, bool contentOnly)
            {
                var ops = ContentLexer.Parse(content, c.Cancel);
                var st = new State { Ctm = ctm };
                var stack = new Stack<State>();
                var tm = Mat.Identity;
                var tlm = Mat.Identity;
                var path = new List<(double X, double Y)>();
                var depthAtStart = marks.Count;
                foreach (var op in ops)
                {
                    if (++_ops > MaxOperators)
                    {
                        Stopped = true;
                        break;
                    }
                    if ((_ops & 4095) == 0) c.Cancel.ThrowIfCancellationRequested();
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
                            Begin(op, resources, key, marks, contentOnly);
                            break;
                        case "EMC":
                            if (marks.Count > depthAtStart) marks.RemoveAt(marks.Count - 1);
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
                        case "Tr" when op.Operands.Count >= 1: st.Mode = (int)op.N(0); break;
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
                            var codes = new List<int>();
                            foreach (var o in op.Operands)
                            {
                                if (o.Kind == CKind.String) Show(o.Bytes, st, ref tm, codes);
                                else if (o.Kind == CKind.Array)
                                    foreach (var item in o.Items)
                                    {
                                        if (item.Kind == CKind.String) Show(item.Bytes, st, ref tm, codes);
                                        else if (item.Kind == CKind.Number) tm = new Mat(1, 0, 0, 1, -item.Num / 1000 * st.Size * st.Scale, 0).Times(tm);
                                    }
                            }
                            if (codes.Count == 0) break;
                            var box = TextBox(start, tm, st);
                            if (st.Font is { } font) c.UseFont(font, codes, st.Mode != 3, pageIndex, box);
                            if (contentOnly) break;
                            Item(marks, box);
                            if (!c._docLang && !marks.Any(m => m.Lang) && !marks.Any(m => m.Elem is { } e && HasLang(e)))
                            {
                                NoLang++;
                                if (NoLang <= 8) NoLangBox = NoLangBox.Union(box);
                            }
                            break;
                        }
                        case "m" when op.Operands.Count >= 2:
                        case "l" when op.Operands.Count >= 2:
                            path.Add((op.N(0), op.N(1)));
                            break;
                        case "c" when op.Operands.Count >= 6:
                            path.Add((op.N(0), op.N(1)));
                            path.Add((op.N(2), op.N(3)));
                            path.Add((op.N(4), op.N(5)));
                            break;
                        case "v" or "y" when op.Operands.Count >= 4:
                            path.Add((op.N(0), op.N(1)));
                            path.Add((op.N(2), op.N(3)));
                            break;
                        case "re" when op.Operands.Count >= 4:
                            path.Add((op.N(0), op.N(1)));
                            path.Add((op.N(0) + op.N(2), op.N(1) + op.N(3)));
                            break;
                        case "f" or "F" or "f*" or "B" or "B*" or "b" or "b*" or "S" or "s":
                            if (!contentOnly && path.Count > 0) Item(marks, Box(path, st.Ctm));
                            path.Clear();
                            break;
                        case "n":
                            path.Clear();
                            break;
                        case "sh":
                            if (!contentOnly) Item(marks, Box([(0, 0), (1, 1)], st.Ctm));
                            break;
                        case "BI":
                            if (!contentOnly) Item(marks, Box([(0, 0), (1, 1), (0, 1), (1, 0)], st.Ctm));
                            break;
                        case "Do" when op.Operands.Count > 0 && op.Operands[0].Kind == CKind.Name:
                        {
                            if (PdfObj.Dict(PdfObj.Dict(resources?.Elements["/XObject"])?.Elements["/" + op.Operands[0].Name]) is not { } x) break;
                            var sub = PdfObj.NameOf(x, "/Subtype");
                            if (sub == "/Image")
                            {
                                if (!contentOnly) Item(marks, Box([(0, 0), (1, 1), (0, 1), (1, 0)], st.Ctm));
                            }
                            else if (sub == "/Form")
                            {
                                if (x.Elements.ContainsKey("/Ref")) c._refForms.Add(x);
                                if (!contentOnly)
                                {
                                    var known = c._forms.TryGetValue(x, out var use);
                                    c._forms[x] = (known ? use.Uses + 1 : 1, use.Tagged, known ? use.Page : pageIndex);
                                }
                                if (depth >= MaxFormDepth || !_active.Add(x)) break;
                                var m = PdfObj.Array(x.Elements["/Matrix"]) is { Elements.Count: 6 } a
                                    ? new Mat(PdfObj.Num(a, 0), PdfObj.Num(a, 1), PdfObj.Num(a, 2), PdfObj.Num(a, 3), PdfObj.Num(a, 4), PdfObj.Num(a, 5))
                                    : Mat.Identity;
                                var formKey = PdfObj.Int(x.Elements["/StructParents"]) ?? key;
                                var outer = _form;
                                _form = x;
                                Run(PdfObj.StreamBytes(x), PdfObj.Dict(x.Elements["/Resources"]) ?? resources, m.Times(st.Ctm), formKey, marks, depth + 1, contentOnly);
                                _form = outer;
                                _active.Remove(x);
                            }
                            break;
                        }
                    }
                }
                // Sequences left open at the end of a stream close with it.
                while (marks.Count > depthAtStart) marks.RemoveAt(marks.Count - 1);
            }

            private PdfDictionary? _form;

            private void Begin(COp op, PdfDictionary? resources, int? key, List<Mc> marks, bool contentOnly)
            {
                var tag = op.Operands.Count > 0 && op.Operands[0].Kind == CKind.Name ? op.Operands[0].Name : "";
                int? mcid = null;
                var lang = false;
                var alt = false;
                if (op.Name == "BDC" && op.Operands.Count > 1)
                {
                    var props = op.Operands[1];
                    if (props.Kind == CKind.Dict)
                    {
                        if (props["MCID"] is { Kind: CKind.Number } n) mcid = (int)n.Num;
                        if (props["Lang"] is { } l)
                        {
                            lang = true;
                            var s = l.Kind == CKind.String ? System.Text.Encoding.Latin1.GetString(l.Bytes) : null;
                            if (s is not null && !IsLanguage(s)) BadLangs.Add(s);
                        }
                        alt = props["Alt"] is not null || props["ActualText"] is not null || props["E"] is not null;
                    }
                    else if (props.Kind == CKind.Name && PdfObj.Dict(PdfObj.Dict(resources?.Elements["/Properties"])?.Elements["/" + props.Name]) is { } pd)
                    {
                        if (PdfObj.Int(pd.Elements["/MCID"]) is { } n) mcid = n;
                        if (pd.Elements.ContainsKey("/Lang"))
                        {
                            lang = true;
                            if (PdfObj.Text(pd.Elements["/Lang"]) is { } s && !IsLanguage(s)) BadLangs.Add(s);
                        }
                        alt = pd.Elements.ContainsKey("/Alt") || pd.Elements.ContainsKey("/ActualText") || pd.Elements.ContainsKey("/E");
                    }
                }
                var (tagged, elem) = mcid is { } id ? c.ByMcid(key, id) : (false, null);
                if (mcid is not null && _form is { } form && c._forms.TryGetValue(form, out var use)) c._forms[form] = use with { Tagged = true };
                if (!contentOnly)
                {
                    // An artifact with a marked-content id of its own is both at once.
                    var insideTagged = tagged || marks.Any(m => m.Tagged);
                    var insideArtifact = tag == "Artifact" || marks.Any(m => m.Tag == "Artifact");
                    if (tag == "Artifact" && insideTagged) ArtifactInTagged++;
                    if (insideTagged && insideArtifact) TaggedInArtifact++; // (an artifact inside tagged content is both, as veraPDF counts it)
                    if (tag == "Span" && alt && !lang && !c._docLang && !marks.Any(m => m.Lang) && !marks.Any(m => m.Elem is { } e && HasLang(e))) SpanNoLang++;
                }
                marks.Add(new Mc(tag, mcid, key, tagged, elem, lang));
            }

            /// <summary>A content item: tagged (in marked content an element stands for), an artifact, or neither.</summary>
            private void Item(List<Mc> marks, RectD box)
            {
                Elem? elem = null;
                var tagged = false;
                var artifact = false;
                foreach (var m in marks)
                {
                    if (m.Tag == "Artifact") artifact = true;
                    if (m.Tagged)
                    {
                        tagged = true;
                        elem = m.Elem ?? elem;
                    }
                }
                if (elem is not null && !box.IsEmpty && elem.Content.Count < 64) elem.Content.Add((pageIndex, box));
                if (tagged || artifact) return;
                Untagged++;
                if (Untagged <= 8) UntaggedBox = UntaggedBox.Union(box);
            }

            private void Show(byte[] bytes, State st, ref Mat tm, List<int> codes)
            {
                if (st.Font is not { } font)
                {
                    // No font set: still something drawn (one item), advanced roughly.
                    codes.Add(-1);
                    tm = new Mat(1, 0, 0, 1, bytes.Length * 0.5 * st.Size * st.Scale, 0).Times(tm);
                    return;
                }
                var tf = TextFont.For(font);
                foreach (var g in tf.Decode(bytes))
                {
                    codes.Add(g.Code);
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
                var pts = new List<(double, double)> { a.Apply(0, -0.2), a.Apply(0, 0.8), b.Apply(0, -0.2), b.Apply(0, 0.8) };
                return Box(pts, Mat.Identity);
            }

            private RectD Box(List<(double X, double Y)> pts, Mat ctm)
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
                if (!double.IsFinite(l) || !double.IsFinite(r) || !double.IsFinite(t) || !double.IsFinite(b)) return default;
                var (w, h) = PdfObj.DisplaySize(page);
                var box = RectD.FromEdges(Math.Max(l, -10), Math.Max(t, -10), Math.Min(r, w + 10), Math.Min(b, h + 10));
                return box.Width <= 0 && box.Height <= 0 ? default : new RectD(box.X, box.Y, Math.Max(box.Width, 1), Math.Max(box.Height, 1));
            }
        }

        // ───────────────────────────── annotations and fields ─────────────────────────────

        private void Annotations(int p, PdfPage page)
        {
            if (PdfObj.Array(page.Elements["/Annots"]) is not { Elements.Count: > 0 } annots) return;
            var tabs = PdfObj.Name(page.Elements["/Tabs"]);
            if (tabs is null) Add("28-008", "This page has comments, links or form fields but doesn't set its tab order (no Tabs entry).", p, default, "Page");
            else if (tabs != "S") Add("28-009", $"This page's tab order is “{tabs}”, not the order of the tags (S).", p, default, "Page");
            var (cx1, cy1, cx2, cy2) = PdfObj.VisibleBox(page);
            foreach (var a in annots.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Take(20_000))
            {
                var subtype = PdfObj.NameOf(a, "/Subtype").TrimStart('/');
                var rect = PdfObj.Array(a.Elements["/Rect"]);
                var box = rect is null ? default : PdfObj.RectToPage(page, rect);
                var hidden = ((PdfObj.Int(a.Elements["/F"]) ?? 0) & 2) != 0;
                var outside = rect is { Elements.Count: >= 4 } &&
                              (Math.Max(PdfObj.Num(rect, 0), PdfObj.Num(rect, 2)) < cx1 || Math.Min(PdfObj.Num(rect, 0), PdfObj.Num(rect, 2)) > cx2 ||
                               Math.Max(PdfObj.Num(rect, 1), PdfObj.Num(rect, 3)) < cy1 || Math.Min(PdfObj.Num(rect, 1), PdfObj.Num(rect, 3)) > cy2);
                var parent = PdfObj.Int(a.Elements["/StructParent"]) is { } k && _parentTree.TryGetValue(k, out var v) ? PdfObj.Dict(v) : null;
                var elem = parent is null ? null : _elems.GetValueOrDefault(parent);
                var std = elem?.Kind ?? (parent is null ? null : MapRole(PdfObj.Name(parent.Elements["/S"]) ?? "", out _));
                var alt = parent is not null && HasText(parent, "/Alt");
                var contents = HasText(a, "/Contents");
                var label = AnnotName(subtype);

                if (!hidden && !outside && subtype != "Popup") // a pop-up belongs to its comment and isn't read on its own
                {
                    if (subtype is not ("Widget" or "PrinterMark" or "Link") && std != "Annot")
                        Add("28-002", $"This {label} isn't inside an Annot tag{(std is null ? " (it isn't tagged)" : $" (it is in a {std} tag)")}.", p, box, Cap(label));
                    if (subtype != "Widget" && !contents && !alt)
                        Add("28-004", $"This {label} has no description: no text (Contents) and no alternate text on its tag.", p, box, Cap(label));
                    if (subtype == "Widget" && IsFieldWidget(a))
                    {
                        if (!HasFieldTooltip(a) && !alt)
                            Add("28-005", $"The form field “{Short(FieldName(a))}” has no tooltip and no alternate text, so a screen reader can't say what to fill in.", p, box, "Form field");
                    }
                    if (subtype == "Widget" && std != "Form")
                        Add("28-010", $"The form field “{Short(FieldName(a))}” isn't inside a Form tag{(std is null ? " (it isn't tagged)" : "")}.", p, box, "Form field");
                    if (subtype == "Link")
                    {
                        if (std != "Link") Add("28-011", $"This link isn't inside a Link tag{(std is null ? " (it isn't tagged)" : $" (it is in a {std} tag)")}.", p, box, "Link");
                        if (!contents) Add("28-012", "This link has no description of where it goes (Contents).", p, box, "Link");
                    }
                    if (subtype == "TrapNet") Add("28-007", "This page has a trap network annotation (TrapNet).", p, box, "Trap network");
                    if (subtype == "PrinterMark" && parent is not null) Add("28-017", "This printer's mark is in the tags.", p, box, "Printer's mark");
                }
                if (contents && !_docLang && !a.Elements.ContainsKey("/Lang") && parent?.Elements.ContainsKey("/Lang") != true)
                    Add("11-004", $"This {label}'s text has no language, and the document has none.", p, box, Cap(label));
                if (subtype == "FileAttachment" && PdfObj.Dict(a.Elements["/FS"]) is { } fs && fs.Elements.ContainsKey("/EF") && !HasBothNames(fs))
                    Add("28-016", "This attached file lacks one of its file names (F and UF).", p, box, "Attached file");
                MediaClips(a, p, box, 0);
                if (!hidden) Appearance(a, p, page);
            }
        }

        private static string AnnotName(string subtype) => subtype switch
        {
            "Text" => "note",
            "Link" => "link",
            "Widget" => "form field",
            "FreeText" => "text box",
            "Highlight" or "Underline" or "StrikeOut" or "Squiggly" => "text markup comment",
            "Stamp" => "stamp",
            "FileAttachment" => "attached-file comment",
            "Popup" => "pop-up note",
            "Ink" => "drawing",
            "Square" or "Circle" or "Line" or "Polygon" or "PolyLine" => "shape comment",
            "" => "annotation",
            _ => $"{subtype} annotation",
        };

        private static string Cap(string s) => s.Length == 0 ? s : char.ToUpperInvariant(s[0]) + s[1..];

        private static bool IsFieldWidget(PdfDictionary a)
        {
            var d = a;
            for (var i = 0; d is not null && i < 32; i++, d = PdfObj.Dict(d.Elements["/Parent"]))
                if (d.Elements.ContainsKey("/FT")) return true;
            return false;
        }

        /// <summary>The widget's field has a tooltip: the widget itself when it is the field (it has a name), else its parent.
        /// A tooltip on a widget that is only one of a field's buttons isn't the field's.</summary>
        private static bool HasFieldTooltip(PdfDictionary a)
        {
            var field = a.Elements.ContainsKey("/T") || PdfObj.Dict(a.Elements["/Parent"]) is not { } parent ? a : parent;
            return HasText(field, "/TU");
        }

        private static string FieldName(PdfDictionary a)
        {
            var parts = new List<string>();
            var d = a;
            for (var i = 0; d is not null && i < 32; i++, d = PdfObj.Dict(d.Elements["/Parent"]))
                if (PdfObj.Text(d.Elements["/T"]) is { Length: > 0 } t) parts.Insert(0, t);
            return parts.Count == 0 ? "(unnamed)" : string.Join('.', parts);
        }

        /// <summary>Media clips reached from a screen annotation's rendition actions: each needs its type (CT) and an alternate description.</summary>
        private void MediaClips(PdfDictionary a, int p, RectD box, int depth)
        {
            var actions = new List<PdfDictionary>();
            if (PdfObj.Dict(a.Elements["/A"]) is { } act) actions.Add(act);
            if (PdfObj.Dict(a.Elements["/AA"]) is { } aa)
                actions.AddRange(aa.Elements.Values.Select(PdfObj.Dict).OfType<PdfDictionary>());
            foreach (var action in actions.Take(32))
                if (PdfObj.NameOf(action, "/S") == "/Rendition") Rendition(PdfObj.Dict(action.Elements["/R"]), p, box, 0);
        }

        private void Rendition(PdfDictionary? r, int p, RectD box, int depth)
        {
            if (r is null || depth > 8) return;
            if (PdfObj.NameOf(r, "/S") == "/SR" && PdfObj.Array(r.Elements["/R"]) is { } list)
            {
                foreach (var sub in list.Elements.Select(PdfObj.Dict)) Rendition(sub, p, box, depth + 1);
                return;
            }
            if (PdfObj.Dict(r.Elements["/C"]) is not { } clip || PdfObj.NameOf(clip, "/S") != "/MCD") return;
            if (!clip.Elements.ContainsKey("/CT")) Add("28-014", "A media clip on this page doesn't say its type (CT).", p, box, "Media clip");
            // Alt: language and text pairs, every one a string, no text empty.
            var alt = PdfObj.Array(clip.Elements["/Alt"]);
            if (alt is null || alt.Elements.Count % 2 != 0 ||
                alt.Elements.Select((x, i) => (Text: PdfObj.Str(x), i)).Any(x => x.Text is null || (x.i % 2 == 1 && x.Text.Length == 0)))
                Add("28-015", "A media clip on this page has no usable alternate description (Alt: pairs of a language and a text).", p, box, "Media clip");
        }

        /// <summary>The fonts an annotation's appearance draws with (they must meet the font rules too).</summary>
        private void Appearance(PdfDictionary a, int p, PdfPage page)
        {
            if (PdfObj.Dict(PdfObj.Dict(a.Elements["/AP"])?.Elements["/N"]) is not { } n) return;
            var streams = new List<PdfDictionary>();
            if (n.Stream is not null) streams.Add(n);
            else streams.AddRange(n.Elements.Values.Select(PdfObj.Dict).OfType<PdfDictionary>().Where(s => s.Stream is not null).Take(8)); // every state (a check box's on and off)
            foreach (var s in streams)
                try
                {
                    new Walk(this, p, page).Run(PdfObj.StreamBytes(s), PdfObj.Dict(s.Elements["/Resources"]), Mat.Identity, null, [], 0, contentOnly: true);
                }
                catch (Exception ex) when (ex is InvalidOperationException or ArgumentException or IndexOutOfRangeException)
                {
                    // An unreadable appearance: its fonts aren't counted.
                }
        }

        /// <summary>A field's widget (the field itself, or a widget among its kids) is in a tag that has a language.</summary>
        private bool WidgetLang(PdfDictionary field)
        {
            var widgets = new List<PdfDictionary>();
            if (PdfObj.NameOf(field, "/Subtype") == "/Widget") widgets.Add(field);
            if (PdfObj.Array(field.Elements["/Kids"]) is { } kids)
                widgets.AddRange(kids.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Where(k => PdfObj.NameOf(k, "/Subtype") == "/Widget").Take(64));
            foreach (var w in widgets)
                if (PdfObj.Int(w.Elements["/StructParent"]) is { } k && _parentTree.TryGetValue(k, out var v) && PdfObj.Dict(v) is { } d && d.Elements.ContainsKey("/Lang"))
                    return true; // the widget's own tag; languages further up don't count here (as veraPDF reads it)
            return false;
        }

        /// <summary>Form fields' tooltips need a language too (the document's, or the field's).</summary>
        private void FormFields()
        {
            if (_docLang || PdfObj.Array(PdfObj.Dict(_catalog.Elements["/AcroForm"])?.Elements["/Fields"]) is not { } fields) return;
            var seen = new HashSet<PdfDictionary>(ReferenceEqualityComparer.Instance);
            var stack = new Stack<(PdfDictionary Field, int Depth)>(fields.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>().Select(f => (f, 0)));
            var count = 0;
            while (stack.Count > 0 && seen.Count < 50_000)
            {
                var (f, depth) = stack.Pop();
                if (!seen.Add(f) || depth > 32) continue;
                if (HasText(f, "/TU") && !f.Elements.ContainsKey("/Lang") && !WidgetLang(f)) count++;
                if (PdfObj.Array(f.Elements["/Kids"]) is { } kids)
                    foreach (var kid in kids.Elements.Select(PdfObj.Dict).OfType<PdfDictionary>()) stack.Push((kid, depth + 1));
            }
            if (count > 0) Add("11-005", $"The tooltips of {Count(count, "form field")} have no language, and the document has none.", element: "Form fields", count: count);
        }
    }
}
