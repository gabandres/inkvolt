using System.Globalization;

namespace InkvoltPdf.Core;

public static partial class CommentFiles
{
    /// <summary>
    /// The columns of a comments CSV. Page is from 1; Date is ISO 8601; Color and Fill are #RRGGBB; Rect is
    /// "x1 y1 x2 y2" in PDF points (origin at the bottom left; a text box's own box, without its callout); Points holds the geometry in the same units: the quads of
    /// a text markup, the strokes of a drawing (separated by ";"), a line's two ends, the vertices of a polygon or a
    /// callout's points. Ends are the line endings (start and end, or a callout's one), Dashes the dash pattern.
    /// </summary>
    public static readonly IReadOnlyList<string> CsvColumns =
        ["Id", "Page", "Type", "Author", "Date", "Subject", "Text", "Reply to", "Color", "Fill", "Opacity", "Width", "Dashes", "Ends", "Icon", "Rect", "Points"];

    private static byte[] WriteCsv(List<Record> records)
    {
        var rows = new List<IReadOnlyList<string>> { CsvColumns };
        foreach (var r in records)
        {
            var d = r.Dict;
            var width = d.GetValueOrDefault("BS") is Dictionary<string, object?> bs && bs.GetValueOrDefault("W") is double w ? Fdf.Number(w)
                : Numbers(d.GetValueOrDefault("Border")) is { Count: >= 3 } border ? Fdf.Number(border[2]) : "";
            rows.Add(
            [
                r.Key,
                (r.Page + 1).ToString(CultureInfo.InvariantCulture),
                r.Subtype,
                d.GetValueOrDefault("T") as string ?? "",
                PdfObj.ParseDate(d.GetValueOrDefault("M") as string)?.ToString("yyyy-MM-dd'T'HH:mm:sszzz", CultureInfo.InvariantCulture) ?? "",
                d.GetValueOrDefault("Subj") as string ?? "",
                d.GetValueOrDefault("Contents") as string ?? "",
                r.ReplyTo ?? "",
                Hex(Numbers(d.GetValueOrDefault("C"))) ?? "",
                Hex(Numbers(d.GetValueOrDefault("IC"))) ?? "",
                d.GetValueOrDefault("CA") is double ca && ca < 1 ? Fdf.Number(ca) : "",
                width,
                d.GetValueOrDefault("BS") is Dictionary<string, object?> bsd && bsd.GetValueOrDefault("S") is Fdf.Name { Value: "D" } ? Spaced(Numbers(bsd.GetValueOrDefault("D"))) : "",
                d.GetValueOrDefault("LE") switch
                {
                    Fdf.Name one => one.Value,
                    List<object?> ends => string.Join(' ', ends.OfType<Fdf.Name>().Select(n => n.Value)),
                    _ => "",
                },
                (d.GetValueOrDefault("Name") as Fdf.Name)?.Value ?? "",
                Spaced(r.Subtype == "FreeText" ? TextBox(d) : Numbers(d.GetValueOrDefault("Rect"))),
                PointsOf(r),
            ]);
        }
        return Csv.Write(rows);
    }

    /// <summary>A text box's own rectangle: its /Rect less the /RD fringe a callout adds.</summary>
    private static List<double>? TextBox(Dictionary<string, object?> d)
    {
        if (Numbers(d.GetValueOrDefault("Rect")) is not { Count: 4 } r) return null;
        if (Numbers(d.GetValueOrDefault("RD")) is not { Count: 4 } rd || rd.Any(v => v < 0)) return r;
        double x1 = Math.Min(r[0], r[2]) + rd[0], y1 = Math.Min(r[1], r[3]) + rd[1], x2 = Math.Max(r[0], r[2]) - rd[2], y2 = Math.Max(r[1], r[3]) - rd[3];
        return x2 > x1 && y2 > y1 ? [x1, y1, x2, y2] : r;
    }

    private static string Spaced(IEnumerable<double>? values) => values is null ? "" : string.Join(' ', values.Select(Fdf.Number));

    private static string PointsOf(Record r)
    {
        var d = r.Dict;
        return r.Subtype switch
        {
            "Ink" when d.GetValueOrDefault("InkList") is List<object?> strokes => string.Join(';', strokes.Select(s => Spaced(Numbers(s)))),
            "Line" => Spaced(Numbers(d.GetValueOrDefault("L"))),
            "Polygon" or "PolyLine" => Spaced(Numbers(d.GetValueOrDefault("Vertices"))),
            "FreeText" => Spaced(Numbers(d.GetValueOrDefault("CL"))),
            _ => Spaced(Numbers(d.GetValueOrDefault("QuadPoints"))),
        };
    }

    private static List<Record> ReadCsv(byte[] file, List<string> skipped)
    {
        List<List<string>> rows;
        try
        {
            rows = Csv.Read(Csv.Decode(file));
        }
        catch (InvalidDataException ex)
        {
            throw new InvalidDataException(ex.Message, ex);
        }
        if (rows.Count == 0) throw new InvalidDataException("The file is empty.");
        var header = rows[0].Select(h => h.Trim()).ToList();
        int Col(string name) => header.FindIndex(h => h.Equals(name, StringComparison.OrdinalIgnoreCase));
        int page = Col("Page"), type = Col("Type");
        if (page < 0 || type < 0 || Col("Rect") < 0)
            throw new InvalidDataException("The file isn't XFDF, FDF or a comments CSV: a CSV needs the columns Page, Type and Rect (export one to see them all).");
        if (rows.Count - 1 > MaxComments) throw new InvalidDataException($"The file has more than {MaxComments:N0} comments, the most Inkvolt PDF imports.");

        var records = new List<Record>();
        for (var i = 1; i < rows.Count; i++)
        {
            var row = rows[i];
            string Cell(string name) => Col(name) is var c and >= 0 && c < row.Count ? row[c] : "";
            var line = i + 1;
            var pg = int.TryParse(Cell("Page"), NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n - 1 : -1;
            var subtype = Cell("Type").Trim();
            if (!XfdfElements.ContainsKey(subtype))
            {
                skipped.Add($"Row {line}: \"{subtype}\" isn't a kind of comment Inkvolt PDF imports");
                continue;
            }
            var d = new Dictionary<string, object?>(StringComparer.Ordinal) { ["Subtype"] = new Fdf.Name(subtype) };
            if (Nums(Cell("Rect")) is { Count: 4 } rect) d["Rect"] = Box(rect);
            if (Cell("Author") is { Length: > 0 } author) d["T"] = author;
            if (Cell("Subject") is { Length: > 0 } subject) d["Subj"] = subject;
            d["Contents"] = Cell("Text");
            if (DateTimeOffset.TryParse(Cell("Date"), CultureInfo.InvariantCulture, DateTimeStyles.AssumeLocal, out var date)) d["M"] = PdfObj.DateString(date).Value;
            if (Color(Cell("Color")) is { } c) d["C"] = c;
            if (Color(Cell("Fill")) is { } fill) d["IC"] = fill;
            if (Num(Cell("Opacity")) is { } ca) d["CA"] = Math.Clamp(ca, 0, 1);
            var dashes = Nums(Cell("Dashes"));
            if (Num(Cell("Width")) is { } w || dashes is { Count: > 0 })
            {
                var bs = new Dictionary<string, object?>(StringComparer.Ordinal) { ["Type"] = new Fdf.Name("Border"), ["W"] = Math.Clamp(Num(Cell("Width")) ?? 1, 0, 1000), ["S"] = new Fdf.Name("S") };
                if (dashes is { Count: > 0 })
                {
                    bs["S"] = new Fdf.Name("D");
                    bs["D"] = dashes.Take(16).Cast<object?>().ToList();
                }
                d["BS"] = bs;
            }
            var ends = Cell("Ends").Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (subtype == "FreeText" && ends.Length == 1) d["LE"] = new Fdf.Name(ends[0]);
            else if (ends.Length == 2) d["LE"] = new List<object?> { new Fdf.Name(ends[0]), new Fdf.Name(ends[1]) };
            if (Cell("Icon") is { Length: > 0 } icon) d["Name"] = new Fdf.Name(icon);
            d["F"] = 4.0; // print
            var points = Cell("Points");
            switch (subtype)
            {
                case "Ink":
                    var strokes = points.Split(';').Select(Nums).OfType<List<double>>().Where(p => p.Count >= 2 && p.Count % 2 == 0)
                        .Select(p => (object?)p.Cast<object?>().ToList()).ToList();
                    if (strokes.Count > 0) d["InkList"] = strokes;
                    break;
                case "Line" when Nums(points) is { Count: 4 } l:
                    d["L"] = l.Cast<object?>().ToList();
                    break;
                case "Polygon" or "PolyLine" when Nums(points) is { Count: >= 4 } v && v.Count % 2 == 0:
                    d["Vertices"] = v.Cast<object?>().ToList();
                    break;
                case "FreeText" when Nums(points) is { Count: 4 or 6 } cl:
                    d["CL"] = cl.Cast<object?>().ToList();
                    break;
                case "Highlight" or "Underline" or "StrikeOut" or "Squiggly" or "Redact" when Nums(points) is { Count: > 0 } q && q.Count % 8 == 0:
                    d["QuadPoints"] = q.Cast<object?>().ToList();
                    break;
            }
            var key = Cell("Id") is { Length: > 0 } id ? id : HashKey("csv", i, null, d);
            var replyTo = Cell("Reply to") is { Length: > 0 } to ? to : null;
            if (replyTo is not null) d["RT"] = new Fdf.Name("R");
            records.Add(new Record { Key = key, Page = pg, Dict = d, ReplyTo = replyTo });
        }
        return records;
    }
}
