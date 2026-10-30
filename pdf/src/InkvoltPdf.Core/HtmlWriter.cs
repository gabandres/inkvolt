using System.Globalization;
using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>
/// Writes one self-contained HTML5 file from laid-out pages: real headings (never skipping a level), paragraphs, lists,
/// tables and pictures embedded as data, in reading order, with nothing that fixes the page's width, so it reflows. A
/// running header and footer appear once. Everything from the PDF (text, alt text, the title) is escaped, and the file has
/// no script, link or request of any kind; its Content-Security-Policy says so as well, in case a browser ever disagrees.
/// </summary>
internal static partial class HtmlWriter
{
    private const string Style =
        "body{margin:0 auto;max-width:48em;padding:1em;font-family:system-ui,sans-serif;line-height:1.5;overflow-wrap:break-word}" +
        "img{max-width:100%;height:auto}figure{margin:1em 0}table{border-collapse:collapse;margin:1em 0;max-width:100%}" +
        "td,th{padding:.25em .5em;vertical-align:top;text-align:left}table.ruled td,table.ruled th{border:1px solid #888}" +
        "ul.typed{list-style:none;padding-left:0}ul.typed ul.typed{padding-left:1.5em}" +
        "header,footer{color:#555;font-size:.875em}";

    public static void Write(Stream output, DocLayoutResult layout, string? title, string? language)
    {
        using var w = new StreamWriter(output, new UTF8Encoding(false), 64 * 1024, leaveOpen: true) { NewLine = "\n" };
        var firstHeading = layout.Pages.SelectMany(p => p.Blocks).OfType<DocParagraph>().FirstOrDefault(p => p.HeadingLevel > 0)?.Text;
        var name = new[] { title, firstHeading }.Select(t => Clean(t ?? "").Trim()).FirstOrDefault(t => t.Length > 0) ?? "Document";

        w.WriteLine("<!DOCTYPE html>");
        w.WriteLine(AccessibilityCheck.IsLanguage(language) ? $"<html lang=\"{Attr(language!)}\">" : "<html>");
        w.WriteLine("<head>");
        w.WriteLine("<meta charset=\"utf-8\">");
        w.WriteLine("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">");
        w.WriteLine("<meta http-equiv=\"Content-Security-Policy\" content=\"default-src 'none'; img-src data:; style-src 'unsafe-inline'\">");
        w.WriteLine($"<title>{Text(name)}</title>");
        w.WriteLine($"<style>{Style}</style>");
        w.WriteLine("</head>");
        w.WriteLine("<body>");
        Running(w, layout.Header, "header");
        w.WriteLine("<main>");
        var level = 0;
        for (var i = 0; i < layout.Pages.Count; i++)
        {
            w.WriteLine($"<div id=\"page-{i + 1}\">");
            Blocks(w, layout.Pages[i].Blocks, ref level);
            w.WriteLine("</div>");
        }
        w.WriteLine("</main>");
        Running(w, layout.Footer, "footer");
        w.WriteLine("</body>");
        w.WriteLine("</html>");
    }

    private static void Blocks(StreamWriter w, IReadOnlyList<DocBlock> blocks, ref int level)
    {
        for (var b = 0; b < blocks.Count; b++)
        {
            switch (blocks[b])
            {
                case DocParagraph { List: not ListKind.None }:
                {
                    var items = new List<DocParagraph>();
                    while (b < blocks.Count && blocks[b] is DocParagraph { List: not ListKind.None } item)
                    {
                        items.Add(item);
                        b++;
                    }
                    b--;
                    List(w, items);
                    break;
                }
                case DocParagraph { HeadingLevel: > 0 } h:
                    // A level is never skipped: a screen reader lists headings as an outline.
                    level = Math.Min(h.HeadingLevel, level + 1);
                    w.WriteLine($"<h{level}>{Inline(h.Runs, bold: false)}</h{level}>");
                    break;
                case DocParagraph p:
                    if (p.Text.Any(c => !char.IsWhiteSpace(c))) w.WriteLine($"<p>{Inline(p.Runs)}</p>");
                    break;
                case DocTable t:
                    Table(w, t);
                    break;
                case DocPicture pic when Image(pic.Image, pic.Box) is { } img:
                    w.WriteLine($"<figure>{img}</figure>");
                    break;
            }
        }
    }

    // ---- lists ----

    /// <summary>A list as it looks: its tag and attributes. Items whose marker no list can show keep it as typed.</summary>
    private readonly record struct ListLook(string Tag, string Attributes);

    private static (ListLook Look, int? Value, IReadOnlyList<ExportSpan> Runs) Item(DocParagraph p)
    {
        if (p.List == ListKind.Bullet) return (new("ul", ""), null, p.Runs);
        var marker = DocLayout.ListMarker(p.Text) is { Bullet: false } m ? m.Marker : "";
        var number = Numbered().Match(marker);
        if (!number.Success) return (new("ul", " class=\"typed\""), null, p.Runs);
        var runs = AfterMarker(p.Runs, marker);
        var text = number.Groups[1].Value;
        if (char.IsAsciiDigit(text[0])) return (new("ol", ""), int.Parse(text, CultureInfo.InvariantCulture), runs);
        return char.IsLower(text[0]) ? (new("ol", " type=\"a\""), text[0] - 'a' + 1, runs) : (new("ol", " type=\"A\""), text[0] - 'A' + 1, runs);
    }

    // "3." "3)" "a." "b)": what <ol> shows by itself; "(iv)" and "7.2.1." aren't, nor digits of other scripts.
    [GeneratedRegex(@"^([0-9]{1,3}|[a-zA-Z])[.)]$")]
    private static partial Regex Numbered();

    /// <summary>The runs without the marker they start with and the space after it.</summary>
    private static List<ExportSpan> AfterMarker(IReadOnlyList<ExportSpan> runs, string marker)
    {
        var left = marker.Length;
        var kept = new List<ExportSpan>();
        var spaces = true;
        foreach (var run in runs)
        {
            var i = 0;
            var s = run.Text;
            while (spaces && i < s.Length && (left > 0 || char.IsWhiteSpace(s[i])))
            {
                if (!char.IsWhiteSpace(s[i]) || left > 0 && marker[^left] == s[i]) left = Math.Max(0, left - 1);
                i++;
            }
            if (i < s.Length) spaces = false;
            if (i < s.Length) kept.Add(run with { Text = s[i..] });
        }
        return kept;
    }

    /// <summary>
    /// Items in a row as one list, nested where the indent goes deeper: a deeper list opens inside the item before it, and
    /// a change of kind at the same depth starts a new list.
    /// </summary>
    private static void List(StreamWriter w, List<DocParagraph> items)
    {
        var open = new Stack<(double Indent, ListLook Look)>();
        void Close()
        {
            w.Write("</li>\n");
            w.Write($"</{open.Pop().Look.Tag}>\n");
        }
        foreach (var p in items)
        {
            var (look, value, runs) = Item(p);
            var indent = p.Box.X;
            while (open.Count > 0 && (open.Peek().Indent > indent + 4 || (Math.Abs(open.Peek().Indent - indent) <= 4 && open.Peek().Look != look))) Close();
            if (open.Count == 0 || open.Peek().Indent < indent - 4)
            {
                w.Write($"<{look.Tag}{look.Attributes}>\n");
                open.Push((indent, look));
            }
            else w.Write("</li>\n");
            w.Write(value is { } v ? $"<li value=\"{v.ToString(CultureInfo.InvariantCulture)}\">" : "<li>");
            w.Write(Inline(runs));
        }
        while (open.Count > 0) Close();
    }

    // ---- tables ----

    private static void Table(StreamWriter w, DocTable t)
    {
        var columns = Math.Max(t.ColumnWidths.Count, t.Rows.Select(r => r.Sum(c => Math.Max(1, c.ColSpan))).DefaultIfEmpty(0).Max());
        if (columns == 0 || t.Rows.Count == 0) return;
        var rows = Rows(t, columns);
        var head = rows.Count > 1 && t.Rows[0].Count > 0 && t.Rows[0].Where(c => c.Text.Any(ch => !char.IsWhiteSpace(ch))).ToList() is { Count: > 0 } first
            && first.All(c => c.Paragraphs.All(p => p.AllBold));
        w.WriteLine(t.Ruled ? "<table class=\"ruled\">" : "<table>");
        for (var r = 0; r < rows.Count; r++)
        {
            if (head && r == 0) w.WriteLine("<thead>");
            if (r == (head ? 1 : 0)) w.WriteLine("<tbody>");
            w.Write("<tr>");
            foreach (var (cell, span) in rows[r])
            {
                var tag = head && r == 0 ? "th" : "td";
                w.Write(tag == "th" ? "<th scope=\"col\"" : "<td");
                if (span > 1) w.Write($" colspan=\"{span.ToString(CultureInfo.InvariantCulture)}\"");
                w.Write(">");
                if (cell is not null) Cell(w, cell);
                w.Write($"</{tag}>");
            }
            w.WriteLine("</tr>");
            if (head && r == 0) w.WriteLine("</thead>");
        }
        w.WriteLine("</tbody>");
        w.WriteLine("</table>");
    }

    /// <summary>
    /// Every row covering every column, as a table must: a short row is padded, cells over the edge are cut, and a column
    /// no cell starts in (only ever spanned) is taken out.
    /// </summary>
    private static List<List<(DocCell? Cell, int Span)>> Rows(DocTable t, int columns)
    {
        var placed = new List<List<(DocCell? Cell, int Start, int End)>>();
        var starts = new bool[columns];
        foreach (var row in t.Rows)
        {
            var at = 0;
            var cells = new List<(DocCell?, int, int)>();
            foreach (var c in row)
            {
                if (at >= columns) break;
                var end = Math.Min(columns, at + Math.Max(1, c.ColSpan));
                cells.Add((c, at, end));
                starts[at] = true;
                at = end;
            }
            if (at < columns)
            {
                cells.Add((null, at, columns));
                starts[at] = true;
            }
            placed.Add(cells);
        }
        return [.. placed.Select(row => row.Select(c => (c.Cell, Span: starts[c.Start..c.End].Count(s => s))).ToList())];
    }

    private static void Cell(StreamWriter w, DocCell cell)
    {
        var paragraphs = cell.Paragraphs.Where(p => p.Text.Any(c => !char.IsWhiteSpace(c))).ToList();
        foreach (var pic in cell.Pictures)
            if (Image(pic.Image, pic.Box) is { } img) w.Write(img);
        if (paragraphs.Count == 1) w.Write(Inline(paragraphs[0].Runs));
        else
            foreach (var p in paragraphs) w.Write($"<p>{Inline(p.Runs)}</p>");
    }

    // ---- pieces ----

    private static void Running(StreamWriter w, DocRunning? running, string tag)
    {
        if (running is null) return;
        // A page number means nothing without pages: the part showing it is left out.
        var rows = running.Rows.Select(r => string.Join("  ", r.Parts.Where(p => !p.Span.Text.Contains(DocLayout.PageField)).Select(p => Text(p.Span.Text).Trim()).Where(s => s.Length > 0)))
            .Where(s => s.Length > 0).ToList();
        var pictures = running.Pictures.Select(p => Image(p.Image, p.Image.Box)).OfType<string>().ToList();
        if (rows.Count == 0 && pictures.Count == 0) return;
        w.WriteLine($"<{tag}>");
        foreach (var img in pictures) w.WriteLine($"<p>{img}</p>");
        foreach (var row in rows) w.WriteLine($"<p>{row}</p>");
        w.WriteLine($"</{tag}>");
    }

    /// <summary>A picture as an img with its data, at most as wide as the page had it; null when it has no bytes.</summary>
    private static string? Image(ExportImage image, RectD box)
    {
        if (image.Data.Length == 0) return null;
        var type = image.Extension == "jpeg" ? "image/jpeg" : "image/png";
        var (width, height) = (Px(box.Width), Px(box.Height));
        return $"<img src=\"data:{type};base64,{Convert.ToBase64String(image.Data)}\" alt=\"{Attr(image.Alt ?? "")}\" width=\"{width}\" height=\"{height}\">";

        static string Px(double pt) => Math.Max(1, (int)Math.Round(pt * 96 / 72)).ToString(CultureInfo.InvariantCulture);
    }

    /// <summary>Runs as text with what they stress: strong, em and code. Runs that look alike (or are only space) share the tags.</summary>
    private static string Inline(IReadOnlyList<ExportSpan> runs, bool bold = true)
    {
        var sb = new StringBuilder();
        var (b, i, m) = (false, false, false);
        void Set(bool nb, bool ni, bool nm)
        {
            if (m && !nm) sb.Append("</code>");
            if (i && !(ni && (!m || nm))) sb.Append("</em>");
            if (b && (!nb || (i && !ni) || (m && !nm))) sb.Append("</strong>");
            var closedB = b && (!nb || (i && !ni) || (m && !nm));
            var closedI = i && !(ni && (!m || nm));
            if (nb && (!b || closedB)) sb.Append("<strong>");
            if (ni && (!i || closedI)) sb.Append("<em>");
            if (nm && !m) sb.Append("<code>");
            (b, i, m) = (nb, ni, nm);
        }
        foreach (var run in runs)
        {
            var text = Text(run.Text);
            if (text.Length == 0) continue;
            if (string.IsNullOrWhiteSpace(run.Text))
            {
                sb.Append(text);
                continue;
            }
            Set(bold && run.Bold, run.Italic, run.Mono);
            sb.Append(text);
        }
        Set(false, false, false);
        return sb.ToString();
    }

    /// <summary>Text for element content: cleaned and escaped; a line break stays one and a tab becomes a space.</summary>
    private static string Text(string s) => Escape(Clean(s)).Replace("\t", " ").Replace("\n", "<br>");

    /// <summary>Text for an attribute's value: all on a line.</summary>
    private static string Attr(string s) => Escape(Clean(s)).Replace('\t', ' ').Replace('\n', ' ');

    private static string Escape(string s) => s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace("\"", "&quot;");

    /// <summary>
    /// Without the characters HTML forbids, on top of what XML does: C1 controls, noncharacters (U+FDD0-FDEF and the last
    /// two of every plane), and the mark for a running part's page number.
    /// </summary>
    internal static string Clean(string text)
    {
        var s = OpenXmlParts.Clean(text);
        var sb = new StringBuilder(s.Length);
        for (var i = 0; i < s.Length; i++)
        {
            var c = s[i];
            if (char.IsHighSurrogate(c) && i + 1 < s.Length)
            {
                if ((char.ConvertToUtf32(c, s[i + 1]) & 0xFFFE) != 0xFFFE) sb.Append(c).Append(s[i + 1]);
                i++;
                continue;
            }
            if (c is >= '\u007F' and <= '\u009F' or >= '﷐' and <= '﷯' or DocLayout.PageField) continue;
            sb.Append(c);
        }
        return sb.ToString();
    }
}
