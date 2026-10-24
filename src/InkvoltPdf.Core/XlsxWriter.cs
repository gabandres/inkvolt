using System.Globalization;
using System.IO.Compression;
using System.Text.RegularExpressions;
using System.Xml;

namespace InkvoltPdf.Core;

/// <summary>
/// Writes tables to an Excel workbook (.xlsx), one sheet per table: plain numbers ("1,234.50", "-7") become numbers,
/// everything else stays text as shown; cells spanning columns are merged; a cell in bold type is bold; column widths
/// follow the table's.
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
        for (var i = 0; i < sheets.Count; i++)
        {
            var table = sheets[i].Table;
            OpenXmlParts.Entry(zip, $"xl/worksheets/sheet{i + 1}.xml", w => Sheet(w, table));
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
        OpenXmlParts.Entry(zip, "xl/styles.xml", Styles);
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
            if (name.Length > 31) name = name[..31].Trim();
            var candidate = name;
            for (var n = 2; !used.Add(candidate); n++)
            {
                var suffix = $" ({n})";
                candidate = (name.Length + suffix.Length > 31 ? name[..(31 - suffix.Length)] : name) + suffix;
            }
            result.Add(candidate);
        }
        return result;
    }

    /// <summary>The number a cell's text shows, if it is a plain one (no currency, percent or leading zero).</summary>
    public static double? Number(string text)
    {
        var t = text.Trim();
        if (!PlainNumber().IsMatch(t)) return null;
        var digits = t.TrimStart('-', '+');
        if (digits.Length > 1 && digits[0] == '0' && digits[1] != '.') return null; // "007": an ID, not a number
        if (digits.Count(char.IsAsciiDigit) > 15) return null;                     // longer than Excel keeps exactly
        return double.TryParse(t.Replace(",", ""), NumberStyles.AllowLeadingSign | NumberStyles.AllowDecimalPoint, CultureInfo.InvariantCulture, out var v) ? v : null;
    }

    [GeneratedRegex(@"^[-+]?(\d{1,3}(,\d{3})+|\d+)(\.\d+)?$")]
    private static partial Regex PlainNumber();

    private static void Sheet(XmlWriter w, DocTable t)
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
                    var style = (bold ? 1 : 0) + (wrap ? 2 : 0);
                    if (style != 0) w.WriteAttributeString("s", style.ToString(CultureInfo.InvariantCulture));
                    if (Number(text) is { } v)
                    {
                        w.WriteElementString("v", S, v.ToString("R", CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        w.WriteAttributeString("t", "inlineStr");
                        w.WriteStartElement("is", S);
                        w.WriteStartElement("t", S);
                        if (text != text.Trim() || text.Contains('\n')) w.WriteAttributeString("xml", "space", null, "preserve");
                        w.WriteString(text.Length > 32767 ? text[..32767] : text); // Excel's cell limit
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

    /// <summary>Styles: 0 plain, 1 bold, 2 wrapped, 3 bold and wrapped.</summary>
    private static void Styles(XmlWriter w)
    {
        w.WriteStartElement("styleSheet", S);
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
        Xf(w, 0, false, null);
        w.WriteEndElement();
        w.WriteStartElement("cellXfs", S);
        w.WriteAttributeString("count", "4");
        Xf(w, 0, false, 0);
        Xf(w, 1, false, 0);
        Xf(w, 0, true, 0);
        Xf(w, 1, true, 0);
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

        static void Xf(XmlWriter w, int font, bool wrap, int? xfId)
        {
            w.WriteStartElement("xf", S);
            w.WriteAttributeString("numFmtId", "0");
            w.WriteAttributeString("fontId", font.ToString(CultureInfo.InvariantCulture));
            w.WriteAttributeString("fillId", "0");
            w.WriteAttributeString("borderId", "0");
            if (xfId is { } x) w.WriteAttributeString("xfId", x.ToString(CultureInfo.InvariantCulture));
            if (font != 0) w.WriteAttributeString("applyFont", "1");
            if (wrap)
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
