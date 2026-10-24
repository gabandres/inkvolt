using System.Globalization;
using System.IO.Compression;
using System.Text.RegularExpressions;
using System.Xml;

namespace InkvoltPdf.Core;

/// <summary>
/// Writes tables to an Excel workbook (.xlsx), one sheet per table: numbers ("1,234.50", "-7", "12.5%", "$5.00") become
/// numbers shown as they were (decimal places, thousands separator, percent, currency sign); everything else stays text
/// as shown; cells spanning columns are merged; a cell in bold type is bold; column widths follow the table's.
/// </summary>
public static partial class XlsxWriter
{
    private const string S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main";
    private const string R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships";
    private const string RelBase = "http://schemas.openxmlformats.org/officeDocument/2006/relationships/";

    public static void Write(Stream output, IReadOnlyList<(string Name, DocTable Table)> sheets, string? title)
    {
        if (sheets.Count == 0) throw new ArgumentException("A workbook needs at least one sheet.", nameof(sheets));
        var names = SheetNames(sheets.Select(s => s.Name));
        using var zip = new ZipArchive(output, ZipArchiveMode.Create, leaveOpen: true);
        var styles = new CellStyles();
        for (var i = 0; i < sheets.Count; i++)
        {
            var table = sheets[i].Table;
            OpenXmlParts.Entry(zip, $"xl/worksheets/sheet{i + 1}.xml", w => Sheet(w, table, styles));
        }
        OpenXmlParts.Entry(zip, "xl/workbook.xml", w =>
        {
            w.WriteStartElement("workbook", S);
            w.WriteAttributeString("xmlns", "r", null, R);
            w.WriteStartElement("sheets", S);
            for (var i = 0; i < names.Count; i++)
            {
                w.WriteStartElement("sheet", S);
                w.WriteAttributeString("name", names[i]);
                w.WriteAttributeString("sheetId", (i + 1).ToString(CultureInfo.InvariantCulture));
                w.WriteAttributeString("r", "id", R, $"rId{i + 1}");
                w.WriteEndElement();
            }
            w.WriteEndElement();
            w.WriteEndElement();
        });
        OpenXmlParts.Entry(zip, "xl/styles.xml", styles.Write);
        OpenXmlParts.Entry(zip, "xl/_rels/workbook.xml.rels", w =>
        {
            const string ns = "http://schemas.openxmlformats.org/package/2006/relationships";
            w.WriteStartElement("Relationships", ns);
            for (var i = 0; i < names.Count; i++) Rel(w, $"rId{i + 1}", RelBase + "worksheet", $"worksheets/sheet{i + 1}.xml");
            Rel(w, "rIdStyles", RelBase + "styles", "styles.xml");
            w.WriteEndElement();
        });
        OpenXmlParts.Entry(zip, "_rels/.rels", w =>
        {
            const string ns = "http://schemas.openxmlformats.org/package/2006/relationships";
            w.WriteStartElement("Relationships", ns);
            Rel(w, "rId1", RelBase + "officeDocument", "xl/workbook.xml");
            Rel(w, "rId2", "http://schemas.openxmlformats.org/package/2006/relationships/metadata/core-properties", "docProps/core.xml");
            Rel(w, "rId3", RelBase + "extended-properties", "docProps/app.xml");
            w.WriteEndElement();
        });
        OpenXmlParts.Entry(zip, "docProps/core.xml", w => OpenXmlParts.CoreProperties(w, title));
        OpenXmlParts.Entry(zip, "docProps/app.xml", OpenXmlParts.AppProperties);
        OpenXmlParts.Entry(zip, "[Content_Types].xml", w => OpenXmlParts.ContentTypes(w,
        [
            ("/xl/workbook.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"),
            ("/xl/styles.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"),
            .. Enumerable.Range(1, names.Count).Select(i =>
                ($"/xl/worksheets/sheet{i}.xml", "application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml")),
        ]));

        static void Rel(XmlWriter w, string id, string type, string target)
        {
            w.WriteStartElement("Relationship", "http://schemas.openxmlformats.org/package/2006/relationships");
            w.WriteAttributeString("Id", id);
            w.WriteAttributeString("Type", type);
            w.WriteAttributeString("Target", target);
            w.WriteEndElement();
        }
    }

    /// <summary>Sheet names Excel accepts: at most 31 characters, none of : \ / ? * [ ], unique (case-insensitive).</summary>
    public static List<string> SheetNames(IEnumerable<string> wanted)
    {
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<string>();
        foreach (var raw in wanted)
        {
            var name = new string([.. raw.Select(c => ":\\/?*[]".Contains(c) || char.IsControl(c) ? ' ' : c)]).Trim().Trim('\'');
            if (name.Length == 0) name = "Sheet";
            if (name.Length > 31) name = OpenXmlParts.Cut(name, 31).Trim();
            var candidate = name;
            for (var n = 2; !used.Add(candidate); n++)
            {
                var suffix = $" ({n})";
                candidate = (name.Length + suffix.Length > 31 ? OpenXmlParts.Cut(name, 31 - suffix.Length) : name) + suffix;
            }
            result.Add(candidate);
        }
        return result;
    }

    /// <summary>The number a cell's text shows, if any (see <see cref="Parse"/>).</summary>
    public static double? Number(string text) => Parse(text)?.Value;

    /// <summary>
    /// The number a cell's text shows and the Excel format that shows it the same way ("1,234.50" → 1234.5 with
    /// "#,##0.00"; "12.5%" → 0.125 with "0.0%"; "-$5" → -5 with "$"#,##0); a null format is General. Null when the
    /// text isn't a number: other separators ("1.234,50"), a leading zero ("007", an ID), more digits than Excel keeps.
    /// </summary>
    public static (double Value, string? Format)? Parse(string text)
    {
        var m = NumberText().Match(text.Trim());
        if (!m.Success || (m.Groups["sign"].Success && m.Groups["sign2"].Success)) return null;
        var whole = m.Groups["int"].Value;
        var frac = m.Groups["frac"].Value;
        var digits = whole.Replace(",", "");
        if (digits.Length > 1 && digits[0] == '0') return null; // "007": an ID, not a number
        if (digits.Length + frac.Length > 15) return null;       // longer than Excel keeps exactly
        if (!double.TryParse(frac.Length > 0 ? $"{digits}.{frac}" : digits, NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var v))
            return null;
        if (m.Groups["sign"].Value == "-" || m.Groups["sign2"].Value == "-") v = -v;
        var thousands = whole.Contains(',');
        var currency = m.Groups["cur"].Value;
        var percent = m.Groups["pct"].Success;
        if (percent) v /= 100;
        if (!thousands && frac.Length == 0 && currency.Length == 0 && !percent) return (v, null);
        var format = (thousands || currency.Length > 0 ? "#,##0" : "0") + (frac.Length > 0 ? "." + new string('0', frac.Length) : "");
        if (percent) format += "%";
        if (currency.Length > 0) format = "\"" + currency + "\"" + format;
        return (v, format);
    }

    // [sign][currency][sign]digits[.digits][%], thousands in groups of three after ",".
    [GeneratedRegex(@"^(?<sign>[-+])?(?<cur>[$€£¥])?(?<sign2>[-+])?(?<int>\d{1,3}(?:,\d{3})+|\d+)(?:\.(?<frac>\d+))?(?<pct>%)?$")]
    private static partial Regex NumberText();

    private static void Sheet(XmlWriter w, DocTable t, CellStyles styles)
    {
        w.WriteStartElement("worksheet", S);
        w.WriteAttributeString("xmlns", "r", null, R);
        var cols = Math.Max(1, t.ColumnWidths.Count);
        w.WriteStartElement("cols", S);
        for (var c = 0; c < cols; c++)
        {
            w.WriteStartElement("col", S);
            var n = (c + 1).ToString(CultureInfo.InvariantCulture);
            w.WriteAttributeString("min", n);
            w.WriteAttributeString("max", n);
            // Excel widths are in characters of about 5.25 pt (Calibri 11).
            var width = c < t.ColumnWidths.Count ? Math.Clamp(t.ColumnWidths[c] / 5.25 + 1, 4, 100) : 10;
            w.WriteAttributeString("width", width.ToString("0.##", CultureInfo.InvariantCulture));
            w.WriteAttributeString("customWidth", "1");
            w.WriteEndElement();
        }
        w.WriteEndElement();
        var merges = new List<string>();
        w.WriteStartElement("sheetData", S);
        for (var r = 0; r < t.Rows.Count; r++)
        {
            var rowNo = (r + 1).ToString(CultureInfo.InvariantCulture);
            w.WriteStartElement("row", S);
            w.WriteAttributeString("r", rowNo);
            var c = 0;
            foreach (var cell in t.Rows[r])
            {
                var span = Math.Max(1, cell.ColSpan);
                var text = OpenXmlParts.Clean(cell.Text).Trim();
                if (span > 1) merges.Add($"{Column(c)}{rowNo}:{Column(c + span - 1)}{rowNo}");
                if (text.Length > 0)
                {
                    var bold = cell.Paragraphs.Count > 0 && cell.Paragraphs.All(p => p.AllBold);
                    var wrap = text.Contains('\n');
                    w.WriteStartElement("c", S);
                    w.WriteAttributeString("r", Column(c) + rowNo);
                    var number = Parse(text);
                    var style = styles.Index(bold, wrap && number is null, number?.Format);
                    if (style != 0) w.WriteAttributeString("s", style.ToString(CultureInfo.InvariantCulture));
                    if (number is { } n)
                    {
                        w.WriteElementString("v", S, n.Value.ToString("R", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        w.WriteAttributeString("t", "inlineStr");
                        w.WriteStartElement("is", S);
                        w.WriteStartElement("t", S);
                        if (text != text.Trim() || text.Contains('\n')) w.WriteAttributeString("xml", "space", null, "preserve");
                        w.WriteString(OpenXmlParts.Cut(text, 32767)); // Excel's cell limit
                        w.WriteEndElement();
                        w.WriteEndElement();
                    }
                    w.WriteEndElement();
                }
                c += span;
            }
            w.WriteEndElement();
        }
        w.WriteEndElement();
        if (merges.Count > 0)
        {
            w.WriteStartElement("mergeCells", S);
            w.WriteAttributeString("count", merges.Count.ToString(CultureInfo.InvariantCulture));
            foreach (var m in merges)
            {
                w.WriteStartElement("mergeCell", S);
                w.WriteAttributeString("ref", m);
                w.WriteEndElement();
            }
            w.WriteEndElement();
        }
        w.WriteEndElement();
    }

    /// <summary>Column letters: 0 → A, 25 → Z, 26 → AA.</summary>
    public static string Column(int index)
    {
        var s = "";
        for (var n = index + 1; n > 0; n = (n - 1) / 26) s = (char)('A' + (n - 1) % 26) + s;
        return s;
    }

    /// <summary>
    /// The workbook's cell styles: bold or not, wrapped or not, and a number format; each combination once (index 0 is
    /// the plain style), each number format once (ids from 164 up, where custom formats start).
    /// </summary>
    private sealed class CellStyles
    {
        private readonly List<(bool Bold, bool Wrap, int NumFmt)> _xfs = [(false, false, 0)];
        private readonly Dictionary<string, int> _formats = [];

        public int Index(bool bold, bool wrap, string? format)
        {
            var id = 0;
            if (format is not null && !_formats.TryGetValue(format, out id)) _formats[format] = id = 164 + _formats.Count;
            var i = _xfs.IndexOf((bold, wrap, id));
            if (i >= 0) return i;
            _xfs.Add((bold, wrap, id));
            return _xfs.Count - 1;
        }

        public void Write(XmlWriter w)
        {
            w.WriteStartElement("styleSheet", S);
            if (_formats.Count > 0)
            {
                w.WriteStartElement("numFmts", S);
                w.WriteAttributeString("count", _formats.Count.ToString(CultureInfo.InvariantCulture));
                foreach (var (code, id) in _formats)
                {
                    w.WriteStartElement("numFmt", S);
                    w.WriteAttributeString("numFmtId", id.ToString(CultureInfo.InvariantCulture));
                    w.WriteAttributeString("formatCode", code);
                    w.WriteEndElement();
                }
                w.WriteEndElement();
            }
            w.WriteStartElement("fonts", S);
            w.WriteAttributeString("count", "2");
            foreach (var bold in new[] { false, true })
            {
                w.WriteStartElement("font", S);
                if (bold) w.WriteElementString("b", S, null);
                w.WriteStartElement("sz", S);
                w.WriteAttributeString("val", "11");
                w.WriteEndElement();
                w.WriteStartElement("name", S);
                w.WriteAttributeString("val", "Calibri");
                w.WriteEndElement();
                w.WriteEndElement();
            }
            w.WriteEndElement();
            w.WriteStartElement("fills", S);
            w.WriteAttributeString("count", "2");
            foreach (var pattern in new[] { "none", "gray125" })
            {
                w.WriteStartElement("fill", S);
                w.WriteStartElement("patternFill", S);
                w.WriteAttributeString("patternType", pattern);
                w.WriteEndElement();
                w.WriteEndElement();
            }
            w.WriteEndElement();
            w.WriteStartElement("borders", S);
            w.WriteAttributeString("count", "1");
            w.WriteStartElement("border", S);
            foreach (var side in new[] { "left", "right", "top", "bottom", "diagonal" }) w.WriteElementString(side, S, null);
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteStartElement("cellStyleXfs", S);
            w.WriteAttributeString("count", "1");
            Xf(w, (false, false, 0), null);
            w.WriteEndElement();
            w.WriteStartElement("cellXfs", S);
            w.WriteAttributeString("count", _xfs.Count.ToString(CultureInfo.InvariantCulture));
            foreach (var xf in _xfs) Xf(w, xf, 0);
            w.WriteEndElement();
            w.WriteStartElement("cellStyles", S);
            w.WriteAttributeString("count", "1");
            w.WriteStartElement("cellStyle", S);
            w.WriteAttributeString("name", "Normal");
            w.WriteAttributeString("xfId", "0");
            w.WriteAttributeString("builtinId", "0");
            w.WriteEndElement();
            w.WriteEndElement();
            w.WriteEndElement();
        }

        private static void Xf(XmlWriter w, (bool Bold, bool Wrap, int NumFmt) xf, int? xfId)
        {
            w.WriteStartElement("xf", S);
            w.WriteAttributeString("numFmtId", xf.NumFmt.ToString(CultureInfo.InvariantCulture));
            w.WriteAttributeString("fontId", xf.Bold ? "1" : "0");
            w.WriteAttributeString("fillId", "0");
            w.WriteAttributeString("borderId", "0");
            if (xfId is { } x) w.WriteAttributeString("xfId", x.ToString(CultureInfo.InvariantCulture));
            if (xf.NumFmt != 0) w.WriteAttributeString("applyNumberFormat", "1");
            if (xf.Bold) w.WriteAttributeString("applyFont", "1");
            if (xf.Wrap)
            {
                w.WriteAttributeString("applyAlignment", "1");
                w.WriteStartElement("alignment", S);
                w.WriteAttributeString("vertical", "top");
                w.WriteAttributeString("wrapText", "1");
                w.WriteEndElement();
            }
            w.WriteEndElement();
        }
    }
}
