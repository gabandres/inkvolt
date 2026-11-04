using PdfSharp.Pdf;
using PdfSharp.Pdf.Advanced;

namespace InkvoltPdf.Core;

public static partial class AccessibilityCheck
{
    /// <summary>The standard structure types of ISO 32000-1, 14.8.4 (what PDF/UA-1 tags must be, or map to).</summary>
    internal static readonly HashSet<string> StandardTypes =
    [
        "Document", "Part", "Art", "Sect", "Div", "BlockQuote", "Caption", "TOC", "TOCI", "Index", "NonStruct", "Private",
        "P", "H", "H1", "H2", "H3", "H4", "H5", "H6", "L", "LI", "Lbl", "LBody", "Table", "TR", "TH", "TD", "THead", "TBody", "TFoot",
        "Span", "Quote", "Note", "Reference", "BibEntry", "Code", "Link", "Annot", "Ruby", "RB", "RT", "RP", "Warichu", "WT", "WP",
        "Figure", "Formula", "Form",
    ];

    /// <summary>A structure element (tag) as the check sees it.</summary>
    private sealed class Elem(PdfDictionary dict, string type, Elem? parent, int order)
    {
        public PdfDictionary Dict { get; } = dict;
        /// <summary>Its /S, without the slash.</summary>
        public string Type { get; } = type;
        /// <summary>The standard type it is or maps to; null when it maps to none.</summary>
        public string? Std { get; set; }
        public Elem? Parent { get; } = parent;
        public int Order { get; } = order;
        public List<Elem> Kids { get; } = [];
        /// <summary>Every kid in order: an element, a marked-content id or an object reference (for the Form rule).</summary>
        public int KidCount { get; set; }
        public List<PdfDictionary> Objects { get; } = [];
        /// <summary>Its /Pg (index), or -1.</summary>
        public int Page { get; set; } = -1;
        /// <summary>Where its own marked content is drawn (filled by the content walk).</summary>
        public List<(int Page, RectD Box)> Content { get; } = [];

        /// <summary>The type to compare with: the standard one, else its own.</summary>
        public string Kind => Std ?? Type;
    }

    private sealed partial class Checker
    {
        private const int MaxElements = 500_000, MaxDepth = 256;
        /// <summary>Places a table's grid may add or write (about 130 MB). Spans can ask for 5,000 rows of a million columns; no real table comes near.</summary>
        private const int MaxTablePlaces = 16_000_000;

        private readonly Dictionary<PdfDictionary, Elem> _elems = new(ReferenceEqualityComparer.Instance);
        private readonly List<Elem> _ordered = [];
        private readonly Dictionary<int, PdfItem?> _parentTree = [];
        private readonly Dictionary<string, string> _roleMap = new(StringComparer.Ordinal);
        private PdfDictionary? _classMap;
        private Dictionary<PdfDictionary, int>? _pageIndex;
        private Dictionary<int, int>? _pageByObject;

        private int PageOf(PdfItem? pg)
        {
            if (_pageIndex is null)
            {
                _pageIndex = new(ReferenceEqualityComparer.Instance);
                _pageByObject = [];
                for (var i = 0; i < doc.PageCount; i++)
                {
                    _pageIndex.TryAdd(doc.Pages[i], i);
                    if (doc.Pages[i].Reference is { } r) _pageByObject.TryAdd(r.ObjectNumber, i);
                }
            }
            if (pg is PdfReference re && _pageByObject!.TryGetValue(re.ObjectNumber, out var n)) return n;
            return PdfObj.Dict(pg) is { } d && _pageIndex.TryGetValue(d, out var m) ? m : -1;
        }

        private void ReadStructure()
        {
            if (PdfObj.Dict(_root!.Elements["/RoleMap"]) is { } roles)
                foreach (var key in roles.Elements.Keys)
                    if (PdfObj.Name(roles.Elements[key]) is { } to) _roleMap[key.TrimStart('/')] = to;
            _classMap = PdfObj.Dict(_root.Elements["/ClassMap"]);
            foreach (var (key, value) in PdfObj.NumberTree(PdfObj.Dict(_root.Elements["/ParentTree"])).Take(2_000_000)) _parentTree.TryAdd(key, value);
            Kids(null, _root.Elements["/K"], 0);
        }

        private void Kids(Elem? parent, PdfItem? k, int depth)
        {
            if (PdfObj.Resolve(k) is PdfArray a)
                foreach (var item in a.Elements) Kid(parent, item, depth);
            else if (k is not null) Kid(parent, k, depth);
        }

        private void Kid(Elem? parent, PdfItem? item, int depth)
        {
            switch (PdfObj.Resolve(item))
            {
                case PdfInteger or PdfReal:
                    if (parent is not null) parent.KidCount++;
                    break;
                case PdfDictionary d:
                    var type = PdfObj.NameOf(d, "/Type");
                    if (type == "/MCR")
                    {
                        if (parent is not null) parent.KidCount++;
                    }
                    else if (type == "/OBJR")
                    {
                        if (parent is null) break;
                        parent.KidCount++;
                        if (PdfObj.Dict(d.Elements["/Obj"]) is { } obj) parent.Objects.Add(obj);
                    }
                    else if (d.Elements.ContainsKey("/S") && depth < MaxDepth && _elems.Count < MaxElements && !_elems.ContainsKey(d))
                    {
                        var e = new Elem(d, PdfObj.Name(d.Elements["/S"]) ?? "", parent, _ordered.Count);
                        _elems[d] = e;
                        _ordered.Add(e);
                        e.Std = MapRole(e.Type, out _);
                        e.Page = d.Elements.ContainsKey("/Pg") ? PageOf(d.Elements["/Pg"]) : parent?.Page ?? -1;
                        if (parent is not null)
                        {
                            parent.Kids.Add(e);
                            parent.KidCount++;
                        }
                        Kids(e, d.Elements["/K"], depth + 1);
                    }
                    else if (d.Elements.ContainsKey("/S") && !_elems.ContainsKey(d))
                        NoteOnce(PdfStrings.A11y_TagsTooMany);
                    break;
            }
        }

        private enum Mapping { Standard, Mapped, Remapped, Circular, Unmapped }

        /// <summary>The standard type <paramref name="type"/> is or maps to (null: none), and how it got there.</summary>
        private string? MapRole(string type, out Mapping how)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal) { type };
            if (StandardTypes.Contains(type))
            {
                // A standard type in the role map: remapped, unless the map leads back to it (Div → Div is a circle).
                how = Mapping.Standard;
                for (var s = type; how == Mapping.Standard && _roleMap.TryGetValue(s, out var to); s = to)
                    how = to == type || !seen.Add(to) ? Mapping.Circular : StandardTypes.Contains(to) ? Mapping.Remapped : Mapping.Standard;
                if (how == Mapping.Standard && _roleMap.ContainsKey(type)) how = Mapping.Remapped;
                return type;
            }
            var t = type;
            while (_roleMap.TryGetValue(t, out var next))
            {
                if (StandardTypes.Contains(next))
                {
                    how = Mapping.Mapped;
                    return next;
                }
                if (!seen.Add(next) || seen.Count > 32)
                {
                    how = Mapping.Circular;
                    return null;
                }
                t = next;
            }
            how = Mapping.Unmapped;
            return null;
        }

        // ───────────────────────────── where an element is ─────────────────────────────

        /// <summary>The page an element is on and its box there: from its marked content (its own, else its kids'), else its /Pg.</summary>
        private (int Page, RectD Box) Locate(Elem e)
        {
            var stack = new Stack<Elem>([e]);
            int page = -1, visited = 0;
            var box = default(RectD);
            while (stack.Count > 0 && visited++ < 5000)
            {
                var x = stack.Pop();
                foreach (var (p, b) in x.Content)
                {
                    if (page < 0) page = p;
                    if (p == page) box = box.Union(b);
                }
                if (page >= 0 && visited > 64) break;
                for (var i = x.Kids.Count - 1; i >= 0; i--) stack.Push(x.Kids[i]);
            }
            if (page >= 0) return (page, box);
            if (e.Page >= 0) return (e.Page, default);
            foreach (var o in e.Objects)
                if (PageOf(o.Elements["/P"]) is var n and >= 0)
                    return (n, PdfObj.Array(o.Elements["/Rect"]) is { } r ? PdfObj.RectToPage(doc.Pages[n], r) : default);
            return (-1, default);
        }

        private static string Label(Elem e) =>
            e.Std is null ? Loc.Format(PdfStrings.A11y_TagLabel, e.Type) : e.Std == e.Type ? Describe(e.Std) : Loc.Format(PdfStrings.A11y_TagLabelTagged, Describe(e.Std), e.Type);

        private static string Describe(string std) => std switch
        {
            "H" => PdfStrings.A11y_TagHeading,
            "P" => PdfStrings.A11y_TagParagraph,
            "L" => PdfStrings.A11y_TagList,
            "LI" => PdfStrings.A11y_TagListItem,
            "LBody" => PdfStrings.A11y_TagListItemBody,
            "Lbl" => PdfStrings.A11y_TagListLabel,
            "TR" => PdfStrings.A11y_TagTableRow,
            "TH" => PdfStrings.A11y_TagTableHeaderCell,
            "TD" => PdfStrings.A11y_TagTableCell,
            "THead" => PdfStrings.A11y_TagTableHeaderGroup,
            "TBody" => PdfStrings.A11y_TagTableBody,
            "TFoot" => PdfStrings.A11y_TagTableFooterGroup,
            "TOC" => PdfStrings.A11y_TagToc,
            "TOCI" => PdfStrings.A11y_TagContentsItem,
            _ when std.Length == 2 && std[0] == 'H' && char.IsDigit(std[1]) => Loc.Format(PdfStrings.A11y_TagHeadingN, std),
            _ => std,
        };

        /// <summary>"this table body": a table part as a sentence names it (the first letter capitalized where it starts one).</summary>
        private static string ThisPart(string std) => std switch
        {
            "THead" => PdfStrings.A11y_ThisTHead,
            "TBody" => PdfStrings.A11y_ThisTBody,
            "TFoot" => PdfStrings.A11y_ThisTFoot,
            "TH" => PdfStrings.A11y_ThisTH,
            _ => PdfStrings.A11y_ThisTD,
        };

        private void AddAt(Elem e, string condition, string problem, string? fix = null)
        {
            var (page, box) = Locate(e);
            Add(condition, problem, page, box, Label(e), fix: fix);
        }

        private static bool HasLang(Elem? e)
        {
            for (var depth = 0; e is not null && depth < MaxDepth; e = e.Parent, depth++)
                if (e.Dict.Elements.ContainsKey("/Lang")) return true;
            return false;
        }

        /// <summary>An attribute of the element (its /A, then its classes in the class map), owned by <paramref name="owner"/> ("/Table").</summary>
        private PdfItem? Attribute(Elem e, string owner, string key)
        {
            PdfItem? Find(PdfItem? a)
            {
                switch (PdfObj.Resolve(a))
                {
                    case PdfDictionary d:
                        return PdfObj.NameOf(d, "/O") == owner && d.Elements.ContainsKey(key) ? d.Elements[key] : null;
                    case PdfArray arr:
                        foreach (var item in arr.Elements)
                            if (PdfObj.Dict(item) is { } dd && Find(dd) is { } v) return v;
                        return null;
                    default:
                        return null;
                }
            }
            if (Find(e.Dict.Elements["/A"]) is { } own) return own;
            if (_classMap is null) return null;
            var classes = PdfObj.Resolve(e.Dict.Elements["/C"]) switch
            {
                PdfName n => [n.Value],
                PdfArray arr => arr.Elements.Select(PdfObj.Resolve).OfType<PdfName>().Select(n => n.Value).ToList(),
                _ => new List<string>(),
            };
            foreach (var c in classes)
                if (Find(_classMap.Elements[c]) is { } v) return v;
            return null;
        }

        // ───────────────────────────── the checks ─────────────────────────────

        private void CheckStructure()
        {
            var noteIds = new Dictionary<string, Elem>(StringComparer.Ordinal);
            var roleReported = new HashSet<(string, string)>();
            Elem? firstH = null, firstHn = null;
            var lastLevel = 0;
            foreach (var e in _ordered)
            {
                cancel.ThrowIfCancellationRequested();
                if (!e.Dict.Elements.ContainsKey("/P")) AddAt(e, "UA 7.1-P", PdfStrings.A11y_TagNoParent);
                if (PdfObj.Text(e.Dict.Elements["/Lang"]) is { } lang && !IsLanguage(lang))
                    AddAt(e, "UA 7.2-Lang", Loc.Format(PdfStrings.A11y_TagLangNotCode, Short(lang)));

                MapRole(e.Type, out var how);
                switch (how)
                {
                    case Mapping.Remapped when roleReported.Add(("02-004", e.Type)):
                        AddAt(e, "02-004", Loc.Format(PdfStrings.A11y_StandardRemapped, e.Type, _roleMap[e.Type]));
                        break;
                    case Mapping.Circular when roleReported.Add(("02-003", e.Type)):
                        AddAt(e, "02-003", Loc.Format(PdfStrings.A11y_RoleMapCircle, e.Type));
                        break;
                    case Mapping.Unmapped when roleReported.Add(("02-001", e.Type)):
                        AddAt(e, "02-001", e.Type.Length == 0 ? PdfStrings.A11y_TagNoType : Loc.Format(PdfStrings.A11y_TagTypeUnmapped, e.Type));
                        break;
                }

                if (!_docLang && !HasLang(e))
                {
                    var which = new[] { ("/Alt", PdfStrings.A11y_AltText), ("/ActualText", PdfStrings.A11y_ActualText), ("/E", PdfStrings.A11y_ExpansionText) }
                        .Where(x => e.Dict.Elements.ContainsKey(x.Item1)).Select(x => x.Item2).ToList();
                    if (which.Count > 0) AddAt(e, "11-002", Loc.Format(PdfStrings.A11y_TagNoLang, which.Count == 1 ? which[0] : Loc.Format(PdfStrings.A11y_ListAnd, string.Join(", ", which[..^1]), which[^1])));
                }

                var kids = e.Kids.Select(k => k.Kind).ToList();
                switch (e.Std)
                {
                    case "Figure" when !HasText(e.Dict, "/Alt") && !e.Dict.Elements.ContainsKey("/ActualText"):
                        AddAt(e, "13-004", PdfStrings.A11y_FigureNoAlt);
                        break;
                    case "Formula" when !HasText(e.Dict, "/Alt") && !e.Dict.Elements.ContainsKey("/ActualText"):
                        AddAt(e, "17-002", PdfStrings.A11y_FormulaNoAlt);
                        break;
                    case "Note":
                        var id = PdfObj.Text(e.Dict.Elements["/ID"]);
                        if (string.IsNullOrEmpty(id)) AddAt(e, "19-003", PdfStrings.A11y_NoteNoId);
                        else if (!noteIds.TryAdd(id, e)) AddAt(e, "19-004", Loc.Format(PdfStrings.A11y_NoteIdUsed, Short(id)));
                        break;
                    case "Table":
                        Table(e, kids);
                        break;
                    case "TR":
                        if (e.Parent?.Kind is not ("Table" or "THead" or "TBody" or "TFoot")) AddAt(e, "09-004", PdfStrings.A11y_RowNotInTable);
                        if (kids.Any(k => k is not ("TH" or "TD"))) AddAt(e, "09-004", Loc.Format(PdfStrings.A11y_RowHolds, Others(kids, "TH", "TD")));
                        break;
                    case "THead" or "TBody" or "TFoot":
                        if (e.Parent?.Kind != "Table") AddAt(e, "09-004", Cap(Loc.Format(PdfStrings.A11y_GroupNotInTable, ThisPart(e.Std))));
                        if (kids.Any(k => k != "TR")) AddAt(e, "09-004", Cap(Loc.Format(PdfStrings.A11y_GroupHolds, ThisPart(e.Std), Others(kids, "TR"))));
                        break;
                    case "TH" or "TD":
                        if (e.Parent?.Kind != "TR") AddAt(e, "09-004", Cap(Loc.Format(PdfStrings.A11y_CellNotInRow, ThisPart(e.Std))));
                        break;
                    case "L":
                        if (kids.Any(k => k is not ("L" or "LI" or "Caption"))) AddAt(e, "09-005", Loc.Format(PdfStrings.A11y_ListHolds, Others(kids, "L", "LI", "Caption")));
                        if (kids.Skip(1).Contains("Caption")) AddAt(e, "09-005", PdfStrings.A11y_ListCaptionNotFirst);
                        break;
                    case "LI":
                        if (e.Parent?.Kind != "L") AddAt(e, "09-005", PdfStrings.A11y_ListItemNotInList);
                        if (kids.Any(k => k is not ("Lbl" or "LBody"))) AddAt(e, "09-005", Loc.Format(PdfStrings.A11y_ListItemHolds, Others(kids, "Lbl", "LBody")));
                        break;
                    case "LBody":
                        if (e.Parent?.Kind != "LI") AddAt(e, "09-005", PdfStrings.A11y_LBodyNotInLi);
                        break;
                    case "TOC":
                        if (kids.Any(k => k is not ("TOC" or "TOCI" or "Caption"))) AddAt(e, "09-006", Loc.Format(PdfStrings.A11y_TocHolds, Others(kids, "TOC", "TOCI", "Caption")));
                        if (kids.Skip(1).Contains("Caption")) AddAt(e, "09-006", PdfStrings.A11y_TocCaptionNotFirst);
                        break;
                    case "TOCI":
                        if (e.Parent?.Kind != "TOC") AddAt(e, "09-006", PdfStrings.A11y_ToCiNotInToc);
                        break;
                    case "Form":
                        if (Attribute(e, "/PrintField", "/Role") is null && !(e.KidCount == 1 && e.Objects.Count == 1 && PdfObj.NameOf(e.Objects[0], "/Subtype") == "/Widget"))
                            AddAt(e, "28-010", PdfStrings.A11y_FormTagHoldsMore);
                        break;
                    case "H":
                        firstH ??= e;
                        break;
                    case { Length: 2 } h when h[0] == 'H' && h[1] is >= '1' and <= '6':
                        firstHn ??= e;
                        var level = h[1] - '0';
                        if (level > lastLevel + 1)
                            AddAt(e, lastLevel == 0 ? "14-002" : "14-003", lastLevel == 0
                                ? Loc.Format(PdfStrings.A11y_FirstHeadingNotH1, h)
                                : Loc.Format(PdfStrings.A11y_HeadingSkipped, h, lastLevel, string.Join(", ", Enumerable.Range(lastLevel + 1, level - lastLevel - 1).Select(n => "H" + n))));
                        lastLevel = level;
                        break;
                }
                if (kids.Count(k => k == "H") > 1) AddAt(e, "14-006", Loc.Format(PdfStrings.A11y_TagHoldsHeadings, kids.Count(k => k == "H")));
            }
            if (firstH is not null && firstHn is not null)
                AddAt(firstH, "14-007", PdfStrings.A11y_BothHeadingKinds);
        }

        private static bool HasText(PdfDictionary d, string key) => !string.IsNullOrEmpty(PdfObj.Text(d.Elements[key]));

        /// <summary>"a P and a Span": the kinds in <paramref name="kids"/> other than <paramref name="allowed"/>.</summary>
        private static string Others(List<string> kids, params string[] allowed)
        {
            var others = kids.Where(k => !allowed.Contains(k)).Distinct().Take(3).Select(k => k.Length == 0 ? PdfStrings.A11y_UntypedTag : Loc.Format(PdfStrings.A11y_OtherKind, k)).ToList();
            return others.Count switch { 0 => PdfStrings.A11y_NothingElse, 1 => others[0], _ => Loc.Format(PdfStrings.A11y_ListAnd, string.Join(", ", others[..^1]), others[^1]) };
        }

        private void Table(Elem table, List<string> kids)
        {
            if (kids.Any(k => k is not ("TR" or "THead" or "TBody" or "TFoot" or "Caption")))
                AddAt(table, "09-004", Loc.Format(PdfStrings.A11y_TableHolds, Others(kids, "TR", "THead", "TBody", "TFoot", "Caption")));
            if (kids.Count(k => k == "THead") > 1) AddAt(table, "09-004", PdfStrings.A11y_TableTwoTHead);
            if (kids.Count(k => k == "TFoot") > 1) AddAt(table, "09-004", PdfStrings.A11y_TableTwoTFoot);
            if ((kids.Contains("THead") || kids.Contains("TFoot")) && !kids.Contains("TBody"))
                AddAt(table, "09-004", PdfStrings.A11y_TableNoTBody);
            if (kids.Count(k => k == "Caption") > 1) AddAt(table, "09-004", PdfStrings.A11y_TableTwoCaptions);
            else if (kids.Count > 2 && kids.Skip(1).SkipLast(1).Contains("Caption")) AddAt(table, "09-004", PdfStrings.A11y_TableCaptionMiddle);

            // The cells on a grid, spans taken into account.
            var rows = new List<Elem>();
            foreach (var k in table.Kids)
            {
                if (k.Kind == "TR") rows.Add(k);
                else if (k.Kind is "THead" or "TBody" or "TFoot") rows.AddRange(k.Kids.Where(r => r.Kind == "TR"));
            }
            if (rows.Count == 0 || rows.Count > 5000) return;
            var grid = new List<List<Elem?>>();
            var place = new Dictionary<Elem, (int Row, int Col)>();
            var overlap = false;
            var spanPast = false;
            var places = 0;
            for (var r = 0; r < rows.Count; r++)
            {
                while (grid.Count <= r) grid.Add([]);
                var c = 0;
                if (rows[r].Kids.Count(x => x.Kind is "TH" or "TD") > 1000) NoteOnce(PdfStrings.A11y_RowTooManyCells);
                foreach (var cell in rows[r].Kids.Where(x => x.Kind is "TH" or "TD").Take(1000))
                {
                    while (c < grid[r].Count && grid[r][c] is not null) c++;
                    var rs = Math.Clamp(PdfObj.Int(Attribute(cell, "/Table", "/RowSpan")) ?? 1, 1, 1000);
                    var cs = Math.Clamp(PdfObj.Int(Attribute(cell, "/Table", "/ColSpan")) ?? 1, 1, 1000);
                    if (r + rs > rows.Count) spanPast = true;
                    place[cell] = (r, c);
                    for (var dr = 0; dr < rs && r + dr < rows.Count; dr++)
                    {
                        while (grid.Count <= r + dr) grid.Add([]);
                        var row = grid[r + dr];
                        // What this adds (the empty places left of a span too) and what it writes (over other cells too).
                        places += Math.Max(0, c + cs - row.Count) + cs;
                        if (places > MaxTablePlaces)
                        {
                            NoteOnce(PdfStrings.A11y_TableTooBig);
                            return;
                        }
                        while (row.Count < c + cs) row.Add(null);
                        for (var dc = 0; dc < cs; dc++)
                        {
                            if (row[c + dc] is not null) overlap = true;
                            row[c + dc] = cell;
                        }
                    }
                    c += cs;
                }
            }
            if (overlap) AddAt(table, "09-004", PdfStrings.A11y_CellsOverlap);
            var widths = grid.Select(row => row.Count(x => x is not null)).ToList();
            if (spanPast) AddAt(table, "09-004", PdfStrings.A11y_CellSpansPast);
            else if (widths.Distinct().Count() > 1)
                AddAt(table, "09-004", Loc.Format(PdfStrings.A11y_RowWidthsDiffer, string.Join(", ", widths.Distinct().Order().Take(4))));

            // Headers (Matterhorn 15-003): in a table that doesn't tie its data cells to header cells through Headers and IDs,
            // every header cell needs a scope. Checked on regular tables only (an irregular one already fails above).
            if (overlap || spanPast || widths.Distinct().Count() > 1) return;
            var headerCells = place.Keys.Where(x => x.Kind == "TH").ToList();
            var unscoped = headerCells.Count(th => Attribute(th, "/Table", "/Scope") is null);
            if (unscoped == 0) return;
            var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var th in headerCells)
                if (PdfObj.Text(th.Dict.Elements["/ID"]) is { Length: > 0 } id) ids.Add(id);
            int unlinked = 0, unknown = 0;
            foreach (var (cell, (r, c)) in place)
            {
                if (cell.Kind != "TD" || (r == 0 && c == 0)) continue;
                if (PdfObj.Array(Attribute(cell, "/Table", "/Headers")) is { Elements.Count: > 0 } headers)
                {
                    if (headers.Elements.Any(h => PdfObj.Text(h) is not { } s || !ids.Contains(s))) unknown++;
                }
                else unlinked++;
            }
            if (unlinked + unknown == 0) return;
            var cells = unlinked > 0
                ? Loc.Plural(unlinked, PdfStrings.A11y_Unlinked_One, PdfStrings.A11y_Unlinked_Many)
                : Loc.Plural(unknown, PdfStrings.A11y_UnknownHeaders_One, PdfStrings.A11y_UnknownHeaders_Many);
            AddAt(table, "15-003", Loc.Plural(unscoped, PdfStrings.A11y_Unscoped_One, PdfStrings.A11y_Unscoped_Many, cells));
        }
    }
}
