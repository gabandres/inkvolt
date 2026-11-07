using System.Globalization;
using System.Text;

namespace InkvoltPdf.FormsCorpus;

/// <summary>
/// Small hand-written forms for the cases the real corpus has too few of, each as plain PDF syntax so it shows
/// exactly one trait: comb fields, hex and UTF-16 field names, /FT and /DA inherited from a parent, a.b.c names,
/// NeedAppearances, missing appearances, rich text, choice pairs, radio kids, check box /Opt, Spanish number formats
/// with a calculation, an incremental update, and fields in an object stream. Generated, never downloaded.
/// </summary>
public static class SyntheticForms
{
    public static IReadOnlyList<(string Name, string What)> All { get; } =
    [
        ("synth-comb", "comb text field, MaxLen 9"),
        ("synth-hex-names", "field names as hex strings, UTF-16 with BOM and accented"),
        ("synth-inherited", "/FT, /DA, /Ff and /MaxLen inherited from parents; widgets without /T"),
        ("synth-hierarchy", "a.b.c names: a terminal field three levels down, a check box beside it"),
        ("synth-needappearances", "NeedAppearances true, text fields with no appearance"),
        ("synth-no-appearance", "no NeedAppearances, a text field and a check box (with /MK /CA) with no appearance"),
        ("synth-richtext", "rich text field (/RV, /DS)"),
        ("synth-choice", "combo with [export display] pairs, editable combo, multi-select list"),
        ("synth-radio-kids", "radio group of three kids, NoToggleToOff; a RadiosInUnison group"),
        ("synth-checkbox-opt", "check boxes sharing a name, export values in /Opt"),
        ("synth-js-es", "Spanish number format AFNumber_Format(2, 2, ...), 1.234,56; SUM calculation; dd/mm/yyyy date"),
        ("synth-js-es3", "AFNumber sepStyle 3 (1234,56) with a currency suffix; AFPercent; product calculation"),
        ("synth-da-acroform", "text fields with no /DA of their own: the AcroForm's /DA and /Q"),
        ("synth-incremental", "an incremental update that changes a value and adds a field"),
        ("synth-objstm", "fields and widgets inside an object stream, cross-reference stream"),
        ("synth-rotated", "page /Rotate 90 with fields, widget /MK /R 90"),
        ("synth-multiline", "multiline centered text, a password field, a field with no font size (auto)"),
    ];

    public static byte[] Build(string name) => name switch
    {
        "synth-comb" => Simple([Tx("Comb", 72, 700, 200, 20, ff: 1 << 24, extra: "/MaxLen 9")]),
        "synth-hex-names" => Simple([TxRaw("<FEFF004E006F006D006200720065>", 72, 700), TxRaw("<4369747920>", 72, 660), TxRaw("<FEFF0041006E0303006F>", 72, 620), TxRaw("(Pa\\355s)", 72, 580)]),
        "synth-inherited" => Inherited(),
        "synth-hierarchy" => Hierarchy(),
        "synth-needappearances" => Simple([Tx("First", 72, 700), Tx("Second", 72, 660), Check("Agree", 72, 620, ap: true)], acroExtra: "/NeedAppearances true"),
        "synth-no-appearance" => Simple([Tx("Plain", 72, 700), Check("Bare", 72, 660, ap: false, extra: "/MK << /CA (8) /BC [0 0 0] >>")]),
        "synth-richtext" => Simple([Tx("Rich", 72, 700, 300, 40, ff: 1 << 25 | 1 << 12, extra: "/RV (<?xml version=\"1.0\"?><body xmlns=\"http://www.w3.org/1999/xhtml\"><p>Old <b>rich</b> text</p></body>) /DS (font: Helvetica 10pt) /V (Old rich text)")]),
        "synth-choice" => Simple([
            Field("Pais", "/FT /Ch /Ff 131072 /Opt [[(PR) (Puerto Rico)] [(US) (Estados Unidos)] [(ES) (Espa\\361a)]] /V (PR) /DA (/Helv 10 Tf 0 g)", 72, 700, 200, 20),
            Field("Ciudad", "/FT /Ch /Ff 393216 /Opt [(San Juan) (Ponce) (Mayag\\374ez)] /DA (/Helv 10 Tf 0 g)", 72, 660, 200, 20),
            Field("Colores", "/FT /Ch /Ff 2097152 /Opt [(Rojo) (Verde) (Azul) (Negro)] /DA (/Helv 10 Tf 0 g)", 72, 560, 200, 80)]),
        "synth-radio-kids" => RadioKids(),
        "synth-checkbox-opt" => CheckOpt(),
        "synth-js-es" => Spanish(sep: 2),
        "synth-js-es3" => Spanish(sep: 3),
        "synth-da-acroform" => Simple([TxNoDa("Uno", 72, 700), TxNoDa("Dos", 72, 660)], acroExtra: "/Q 2"),
        "synth-incremental" => Incremental(),
        "synth-objstm" => ObjStm(),
        "synth-rotated" => Simple([Tx("Turned", 100, 500, 20, 200, extra: "/MK << /R 90 >>"), Check("TurnedBox", 140, 500, ap: true)], rotate: 90),
        "synth-multiline" => Simple([Tx("Notes", 72, 600, 300, 100, ff: 1 << 12, extra: "/Q 1"), Tx("Secret", 72, 560, 200, 20, ff: 1 << 13), Field("Auto", "/FT /Tx /DA (/Helv 0 Tf 0 g)", 72, 520, 200, 14)]),
        _ => throw new ArgumentException($"no synthetic form '{name}'"),
    };

    // ───────────────────────────── fields ─────────────────────────────

    /// <summary>A field written as the objects it needs; "{P}" stands for the page, "{SELF}" for its own object.</summary>
    private sealed record Spec(string Dict, string? Ap = null, string? ApOff = null, bool Merged = true);

    private static string R(double x, double y, double w, double h) => string.Create(CultureInfo.InvariantCulture, $"[{x} {y} {x + w} {y + h}]");

    private static Spec Field(string t, string body, double x, double y, double w, double h) =>
        new($"/Type /Annot /Subtype /Widget /T ({t}) {body} /Rect {R(x, y, w, h)} /P {{P}} /F 4");

    private static Spec Tx(string t, double x, double y, double w = 200, double h = 20, int ff = 0, string extra = "") =>
        new($"/Type /Annot /Subtype /Widget /FT /Tx /T ({t}) /Ff {ff} /DA (/Helv 10 Tf 0 g) {extra} /Rect {R(x, y, w, h)} /P {{P}} /F 4");

    private static Spec TxRaw(string tRaw, double x, double y) =>
        new($"/Type /Annot /Subtype /Widget /FT /Tx /T {tRaw} /DA (/Helv 10 Tf 0 g) /Rect {R(x, y, 200, 20)} /P {{P}} /F 4");

    private static Spec TxNoDa(string t, double x, double y) =>
        new($"/Type /Annot /Subtype /Widget /FT /Tx /T ({t}) /Rect {R(x, y, 200, 20)} /P {{P}} /F 4");

    private static Spec Check(string t, double x, double y, bool ap, string extra = "") =>
        new($"/Type /Annot /Subtype /Widget /FT /Btn /T ({t}) /V /Off /AS /Off /DA (/ZaDb 0 Tf 0 g) {extra} /Rect {R(x, y, 14, 14)} /P {{P}} /F 4",
            ap ? CheckFace : null, ap ? "" : null);

    private const string CheckFace = "q 0 g BT /ZaDb 10 Tf 2 3 Td (4) Tj ET Q";

    // ───────────────────────────── documents ─────────────────────────────

    private sealed class Writer
    {
        private readonly List<string?> _objs = [null]; // 1-based
        public int Reserve() { _objs.Add(null); return _objs.Count - 1; }
        public int Add(string body) { _objs.Add(body); return _objs.Count - 1; }
        public void Set(int id, string body) => _objs[id] = body;
        public int Stream(string dict, string content) => Add($"<< {dict} /Length {Encoding.Latin1.GetByteCount(content)} >>\nstream\n{content}\nendstream");
        public int Count => _objs.Count - 1;

        public byte[] Build(int root, string header = "%PDF-1.7")
        {
            var sb = new StringBuilder(header + "\n%\u00e2\u00e3\u00cf\u00d3\n");
            var offsets = new int[_objs.Count];
            for (var i = 1; i < _objs.Count; i++)
            {
                offsets[i] = Encoding.Latin1.GetByteCount(sb.ToString());
                sb.Append(CultureInfo.InvariantCulture, $"{i} 0 obj\n{_objs[i]}\nendobj\n");
            }
            var xref = Encoding.Latin1.GetByteCount(sb.ToString());
            sb.Append(CultureInfo.InvariantCulture, $"xref\n0 {_objs.Count}\n0000000000 65535 f \n");
            for (var i = 1; i < _objs.Count; i++) sb.Append(CultureInfo.InvariantCulture, $"{offsets[i]:D10} 00000 n \n");
            sb.Append(CultureInfo.InvariantCulture, $"trailer\n<< /Size {_objs.Count} /Root {root} 0 R >>\nstartxref\n{xref}\n%%EOF\n");
            return Encoding.Latin1.GetBytes(sb.ToString());
        }
    }

    private const string Fonts = "/Font << /Helv << /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >> /ZaDb << /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >> >>";

    /// <summary>One page, each spec a merged field/widget at the top of /Fields.</summary>
    private static byte[] Simple(Spec[] specs, string acroExtra = "", int rotate = 0)
    {
        var w = new Writer();
        var catalog = w.Reserve();
        var pages = w.Reserve();
        var page = w.Reserve();
        var ids = new List<int>();
        foreach (var s in specs) ids.Add(AddWidget(w, s, page));
        var labels = w.Stream("", "BT /F1 12 Tf 72 740 Td (Synthetic form for Inkvolt's forms corpus) Tj ET");
        w.Set(page, $"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 612 792] {(rotate != 0 ? $"/Rotate {rotate}" : "")} /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents {labels} 0 R /Annots [{Refs(ids)}] >>");
        w.Set(pages, $"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>");
        w.Set(catalog, $"<< /Type /Catalog /Pages {pages} 0 R /AcroForm << /Fields [{Refs(ids)}] /DR << {Fonts} >> /DA (/Helv 0 Tf 0 g) {acroExtra} >> >>");
        return w.Build(catalog);
    }

    private static int AddWidget(Writer w, Spec s, int page, string parent = "")
    {
        var id = w.Reserve();
        var ap = "";
        if (s.Ap is not null)
        {
            var rect = System.Text.RegularExpressions.Regex.Match(s.Dict, @"/Rect \[([\d. -]+)\]").Groups[1].Value.Split(' ').Select(v => double.Parse(v, CultureInfo.InvariantCulture)).ToArray();
            var bbox = string.Create(CultureInfo.InvariantCulture, $"[0 0 {rect[2] - rect[0]} {rect[3] - rect[1]}]");
            var on = w.Stream($"/Type /XObject /Subtype /Form /BBox {bbox} /Resources << {Fonts} >>", s.Ap);
            if (s.ApOff is not null)
            {
                var off = w.Stream($"/Type /XObject /Subtype /Form /BBox {bbox}", s.ApOff);
                var state = System.Text.RegularExpressions.Regex.Match(s.Dict, @"/OnState /(\w+)").Groups[1].Value is { Length: > 0 } st ? st : "Yes";
                ap = $"/AP << /N << /{state} {on} 0 R /Off {off} 0 R >> >>";
            }
            else ap = $"/AP << /N {on} 0 R >>";
        }
        var dict = System.Text.RegularExpressions.Regex.Replace(s.Dict, @"/OnState /\w+", "");
        w.Set(id, $"<< {dict.Replace("{P}", $"{page} 0 R").Replace("{SELF}", $"{id} 0 R")} {ap} {parent} >>");
        return id;
    }

    private static string Refs(IEnumerable<int> ids) => string.Join(" ", ids.Select(i => $"{i} 0 R"));

    private static byte[] Inherited()
    {
        var w = new Writer();
        var catalog = w.Reserve();
        var pages = w.Reserve();
        var page = w.Reserve();
        // A text field whose /FT, /DA, /Ff and /MaxLen are on the parent; two widgets without /T.
        var parent = w.Reserve();
        var k1 = AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /Rect {R(72, 700, 200, 20)} /P {{P}} /F 4"), page, $"/Parent {parent} 0 R");
        var k2 = AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /Rect {R(72, 660, 200, 20)} /P {{P}} /F 4"), page, $"/Parent {parent} 0 R");
        w.Set(parent, $"<< /FT /Tx /T (Shared) /DA (/Helv 9 Tf 0 0 1 rg) /MaxLen 12 /Kids [{k1} 0 R {k2} 0 R] >>");
        // A grandparent holding /FT /Tx and /DA; the terminal field has /T only.
        var grand = w.Reserve();
        var leaf = AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /T (Leaf) /Rect {R(72, 620, 200, 20)} /P {{P}} /F 4"), page, $"/Parent {grand} 0 R");
        w.Set(grand, $"<< /FT /Tx /T (Group) /DA (/Helv 11 Tf 0 g) /Kids [{leaf} 0 R] >>");
        // A check box whose /FT is on the parent.
        var cbParent = w.Reserve();
        var cb = AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /AS /Off /Rect {R(72, 580, 14, 14)} /P {{P}} /F 4 /OnState /Si", CheckFace, ""), page, $"/Parent {cbParent} 0 R");
        w.Set(cbParent, $"<< /FT /Btn /T (Acepto) /V /Off /DA (/ZaDb 0 Tf 0 g) /Kids [{cb} 0 R] >>");
        var labels = w.Stream("", "BT /F1 12 Tf 72 740 Td (Inherited attributes) Tj ET");
        w.Set(page, $"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents {labels} 0 R /Annots [{Refs([k1, k2, leaf, cb])}] >>");
        w.Set(pages, $"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>");
        w.Set(catalog, $"<< /Type /Catalog /Pages {pages} 0 R /AcroForm << /Fields [{Refs([parent, grand, cbParent])}] /DR << {Fonts} >> >> >>");
        return w.Build(catalog);
    }

    private static byte[] Hierarchy()
    {
        var w = new Writer();
        var catalog = w.Reserve();
        var pages = w.Reserve();
        var page = w.Reserve();
        var a = w.Reserve();
        var b = w.Reserve();
        var c = AddWidget(w, Tx("c", 72, 700), page, $"/Parent {b} 0 R");
        var d = AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /FT /Btn /T (d) /V /Off /AS /Off /Rect {R(72, 660, 14, 14)} /P {{P}} /F 4", CheckFace, ""), page, $"/Parent {b} 0 R");
        var e = AddWidget(w, Tx("e", 72, 620), page, $"/Parent {a} 0 R");
        w.Set(b, $"<< /T (b) /Parent {a} 0 R /Kids [{c} 0 R {d} 0 R] >>");
        w.Set(a, $"<< /T (a) /Kids [{b} 0 R {e} 0 R] >>");
        var labels = w.Stream("", "BT /F1 12 Tf 72 740 Td (a.b.c) Tj ET");
        w.Set(page, $"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents {labels} 0 R /Annots [{Refs([c, d, e])}] >>");
        w.Set(pages, $"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>");
        w.Set(catalog, $"<< /Type /Catalog /Pages {pages} 0 R /AcroForm << /Fields [{a} 0 R] /DR << {Fonts} >> /DA (/Helv 0 Tf 0 g) >> >>");
        return w.Build(catalog);
    }

    private static byte[] RadioKids()
    {
        var w = new Writer();
        var catalog = w.Reserve();
        var pages = w.Reserve();
        var page = w.Reserve();
        const string Dot = "q 0 g 7 7 m 7 9.2 5.2 11 3 11 c 0.8 11 -1 9.2 -1 7 c -1 4.8 0.8 3 3 3 c 5.2 3 7 4.8 7 7 c f Q";
        var group = w.Reserve();
        var kids = new List<int>();
        foreach (var (state, i) in new[] { "Uno", "Dos", "Tres" }.Select((s, i) => (s, i)))
            kids.Add(AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /AS /{(i == 0 ? state : "Off")} /Rect {R(72 + i * 40, 700, 14, 14)} /P {{P}} /F 4 /MK << /CA (l) >> /OnState /{state}", Dot, ""), page, $"/Parent {group} 0 R"));
        w.Set(group, $"<< /FT /Btn /Ff {(1 << 15) | (1 << 14)} /T (Opcion) /V /Uno /DA (/ZaDb 0 Tf 0 g) /Kids [{Refs(kids)}] >>");
        var unison = w.Reserve();
        var ukids = new List<int>();
        foreach (var (state, i) in new[] { "A", "A", "B" }.Select((s, i) => (s, i)))
            ukids.Add(AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /AS /Off /Rect {R(72 + i * 40, 650, 14, 14)} /P {{P}} /F 4 /OnState /{state}", Dot, ""), page, $"/Parent {unison} 0 R"));
        w.Set(unison, $"<< /FT /Btn /Ff {(1 << 15) | (1 << 25)} /T (Unison) /V /Off /DA (/ZaDb 0 Tf 0 g) /Kids [{Refs(ukids)}] >>");
        var labels = w.Stream("", "BT /F1 12 Tf 72 740 Td (Radio groups) Tj ET");
        w.Set(page, $"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents {labels} 0 R /Annots [{Refs(kids.Concat(ukids))}] >>");
        w.Set(pages, $"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>");
        w.Set(catalog, $"<< /Type /Catalog /Pages {pages} 0 R /AcroForm << /Fields [{group} 0 R {unison} 0 R] /DR << {Fonts} >> >> >>");
        return w.Build(catalog);
    }

    private static byte[] CheckOpt()
    {
        var w = new Writer();
        var catalog = w.Reserve();
        var pages = w.Reserve();
        var page = w.Reserve();
        var parent = w.Reserve();
        var kids = new List<int>();
        for (var i = 0; i < 3; i++)
            kids.Add(AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /AS /Off /Rect {R(72 + i * 40, 700, 14, 14)} /P {{P}} /F 4 /OnState /{i}", CheckFace, ""), page, $"/Parent {parent} 0 R"));
        w.Set(parent, $"<< /FT /Btn /T (Estado) /V /Off /Opt [(Soltero) (Casado) (Viudo)] /DA (/ZaDb 0 Tf 0 g) /Kids [{Refs(kids)}] >>");
        var labels = w.Stream("", "BT /F1 12 Tf 72 740 Td (Check boxes with /Opt) Tj ET");
        w.Set(page, $"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents {labels} 0 R /Annots [{Refs(kids)}] >>");
        w.Set(pages, $"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>");
        w.Set(catalog, $"<< /Type /Catalog /Pages {pages} 0 R /AcroForm << /Fields [{parent} 0 R] /DR << {Fonts} >> >> >>");
        return w.Build(catalog);
    }

    /// <summary>The owner's case in miniature: amounts in a Spanish number format, a total calculated from them.</summary>
    private static byte[] Spanish(int sep)
    {
        var w = new Writer();
        var catalog = w.Reserve();
        var pages = w.Reserve();
        var page = w.Reserve();
        string Js(string s) => w.Add($"<< /S /JavaScript /JS ({s.Replace("(", "\\(").Replace(")", "\\)")}) >>").ToString(CultureInfo.InvariantCulture);
        var cur = sep == 3 ? "\" \\\\u20AC\", false" : "\"\", true"; // \\ in the PDF string: JavaScript gets €
        var fmt = $"AFNumber_Format(2, {sep}, 0, 0, {cur});";
        var key = $"AFNumber_Keystroke(2, {sep}, 0, 0, {cur});";
        var ids = new List<int>();
        int Amount(string t, double y, string? calc = null)
        {
            var aa = $"/AA << /F {Js(fmt)} 0 R /K {Js(key)} 0 R {(calc is null ? "" : $"/C {Js(calc)} 0 R")} >>";
            var id = AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /FT /Tx /T ({t}) /DA (/Helv 10 Tf 0 g) /Q 2 {aa} /Rect {R(300, y, 150, 20)} /P {{P}} /F 4"), page);
            ids.Add(id);
            return id;
        }
        Amount("Importe1", 700);
        Amount("Importe2", 660);
        var total = sep == 2
            ? Amount("Total", 620, "AFSimple_Calculate(\"SUM\", new Array(\"Importe1\", \"Importe2\"));")
            : Amount("Total", 620, "AFSimple_Calculate(\"PRD\", new Array(\"Importe1\", \"Importe2\"));");
        var date = AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /FT /Tx /T (Fecha) /DA (/Helv 10 Tf 0 g) /AA << /F {Js("AFDate_FormatEx(\"dd/mm/yyyy\");")} 0 R /K {Js("AFDate_KeystrokeEx(\"dd/mm/yyyy\");")} 0 R >> /Rect {R(300, 580, 150, 20)} /P {{P}} /F 4"), page);
        ids.Add(date);
        if (sep == 3)
        {
            var pct = AddWidget(w, new Spec($"/Type /Annot /Subtype /Widget /FT /Tx /T (Porcentaje) /DA (/Helv 10 Tf 0 g) /AA << /F {Js("AFPercent_Format(1, 3);")} 0 R /K {Js("AFPercent_Keystroke(1, 3);")} 0 R >> /Rect {R(300, 540, 150, 20)} /P {{P}} /F 4"), page);
            ids.Add(pct);
        }
        var labels = w.Stream("", "BT /F1 12 Tf 72 704 Td (Importe 1) Tj 0 -40 Td (Importe 2) Tj 0 -40 Td (Total) Tj 0 -40 Td (Fecha) Tj ET");
        w.Set(page, $"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents {labels} 0 R /Annots [{Refs(ids)}] >>");
        w.Set(pages, $"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>");
        w.Set(catalog, $"<< /Type /Catalog /Pages {pages} 0 R /AcroForm << /Fields [{Refs(ids)}] /CO [{total} 0 R] /DR << {Fonts} >> /DA (/Helv 0 Tf 0 g) >> >>");
        return w.Build(catalog);
    }

    /// <summary>A form saved, then updated incrementally: the update changes a value and adds a field.</summary>
    private static byte[] Incremental()
    {
        var w = new Writer();
        var catalog = w.Reserve();
        var pages = w.Reserve();
        var page = w.Reserve();
        var name = AddWidget(w, Tx("Nombre", 72, 700, extra: "/V (Viejo)"), page);
        var labels = w.Stream("", "BT /F1 12 Tf 72 740 Td (Incremental update) Tj ET");
        string Page(string annots) => $"<< /Type /Page /Parent {pages} 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents {labels} 0 R /Annots [{annots}] >>";
        w.Set(page, Page($"{name} 0 R"));
        w.Set(pages, $"<< /Type /Pages /Kids [{page} 0 R] /Count 1 >>");
        string Catalog(string fields) => $"<< /Type /Catalog /Pages {pages} 0 R /AcroForm << /Fields [{fields}] /DR << {Fonts} >> /DA (/Helv 0 Tf 0 g) >> >>";
        w.Set(catalog, Catalog($"{name} 0 R"));
        var first = w.Build(catalog);
        var prevXref = int.Parse(Encoding.Latin1.GetString(first).Split("startxref\n")[1].Split('\n')[0], CultureInfo.InvariantCulture);

        // The update: the field's new value, a new field, the page and catalog that list it.
        var added = w.Count + 1;
        var updates = new (int Id, string Body)[]
        {
            (name, $"<< /Type /Annot /Subtype /Widget /FT /Tx /T (Nombre) /Ff 0 /DA (/Helv 10 Tf 0 g) /V (Nuevo) /Rect {R(72, 700, 200, 20)} /P {page} 0 R /F 4 >>"),
            (added, $"<< /Type /Annot /Subtype /Widget /FT /Tx /T (Agregado) /DA (/Helv 10 Tf 0 g) /Rect {R(72, 660, 200, 20)} /P {page} 0 R /F 4 >>"),
            (page, Page($"{name} 0 R {added} 0 R")),
            (catalog, Catalog($"{name} 0 R {added} 0 R")),
        };
        var sb = new StringBuilder();
        var offsets = new Dictionary<int, int>();
        foreach (var (id, body) in updates)
        {
            offsets[id] = first.Length + Encoding.Latin1.GetByteCount(sb.ToString());
            sb.Append(CultureInfo.InvariantCulture, $"{id} 0 obj\n{body}\nendobj\n");
        }
        var xref = first.Length + Encoding.Latin1.GetByteCount(sb.ToString());
        sb.Append("xref\n0 1\n0000000000 65535 f \n");
        foreach (var id in offsets.Keys.Order()) sb.Append(CultureInfo.InvariantCulture, $"{id} 1\n{offsets[id]:D10} 00000 n \n");
        sb.Append(CultureInfo.InvariantCulture, $"trailer\n<< /Size {added + 1} /Root {catalog} 0 R /Prev {prevXref} >>\nstartxref\n{xref}\n%%EOF\n");
        return [.. first, .. Encoding.Latin1.GetBytes(sb.ToString())];
    }

    /// <summary>Fields and widgets stored in an object stream, found through a cross-reference stream.</summary>
    private static byte[] ObjStm()
    {
        // Objects: 1 catalog, 2 pages, 3 page, 4 contents, 5 object stream, 6 xref stream; 7..9 fields inside 5.
        var inside = new[]
        {
            $"<< /Type /Annot /Subtype /Widget /FT /Tx /T (Comprimido) /DA (/Helv 10 Tf 0 g) /Rect {R(72, 700, 200, 20)} /P 3 0 R /F 4 >>",
            $"<< /Type /Annot /Subtype /Widget /FT /Tx /T (Otro) /DA (/Helv 10 Tf 0 g) /MaxLen 20 /Rect {R(72, 660, 200, 20)} /P 3 0 R /F 4 >>",
            $"<< /Type /Annot /Subtype /Widget /FT /Ch /Ff 131072 /T (Lista) /Opt [(Si) (No)] /DA (/Helv 10 Tf 0 g) /Rect {R(72, 620, 200, 20)} /P 3 0 R /F 4 >>",
        };
        var header = new StringBuilder();
        var body = new StringBuilder();
        for (var i = 0; i < inside.Length; i++)
        {
            header.Append(CultureInfo.InvariantCulture, $"{7 + i} {Encoding.Latin1.GetByteCount(body.ToString())} ");
            body.Append(inside[i]).Append('\n');
        }
        var first = Encoding.Latin1.GetByteCount(header.ToString());
        var objstm = header + body.ToString();
        var content = "BT /F1 12 Tf 72 740 Td (Object stream) Tj ET";
        var objs = new[]
        {
            $"<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [7 0 R 8 0 R 9 0 R] /DR << {Fonts} >> /DA (/Helv 0 Tf 0 g) >> >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> >> >> /Contents 4 0 R /Annots [7 0 R 8 0 R 9 0 R] >>",
            $"<< /Length {content.Length} >>\nstream\n{content}\nendstream",
            $"<< /Type /ObjStm /N {inside.Length} /First {first} /Length {Encoding.Latin1.GetByteCount(objstm)} >>\nstream\n{objstm}\nendstream",
        };
        var sb = new StringBuilder("%PDF-1.7\n%\u00e2\u00e3\u00cf\u00d3\n");
        var offsets = new List<int>();
        for (var i = 0; i < objs.Length; i++)
        {
            offsets.Add(Encoding.Latin1.GetByteCount(sb.ToString()));
            sb.Append(CultureInfo.InvariantCulture, $"{i + 1} 0 obj\n{objs[i]}\nendobj\n");
        }
        var xrefOffset = Encoding.Latin1.GetByteCount(sb.ToString());
        // W [1 4 2]: type, offset or object stream number, generation or index.
        var rows = new List<byte[]> { Row(0, 0, 65535) };
        rows.AddRange(offsets.Select(o => Row(1, o, 0)));
        rows.Add(Row(1, xrefOffset, 0)); // 6: this stream
        for (var i = 0; i < inside.Length; i++) rows.Add(Row(2, 5, i));
        var data = rows.SelectMany(r => r).ToArray();
        var head = Encoding.Latin1.GetBytes(sb.ToString() + $"6 0 obj\n<< /Type /XRef /Size {rows.Count} /W [1 4 2] /Root 1 0 R /Length {data.Length} >>\nstream\n");
        var tail = Encoding.Latin1.GetBytes($"\nendstream\nendobj\nstartxref\n{xrefOffset}\n%%EOF\n");
        return [.. head, .. data, .. tail];

        static byte[] Row(int type, int a, int b) => [(byte)type, (byte)(a >> 24), (byte)(a >> 16), (byte)(a >> 8), (byte)a, (byte)(b >> 8), (byte)b];
    }
}
