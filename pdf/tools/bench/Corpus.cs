using System.Globalization;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;

namespace InkvoltPdf.Bench;

/// <summary>How big each file is. <see cref="Full"/> is the benchmark; <see cref="Small"/> keeps the smoke test quick.</summary>
public sealed record Sizes(int TextPages, int ScanPages, int DrawingSheets, int PathsPerSheet, int CommentPages, int CommentsPerPage)
{
    public static readonly Sizes Full = new(5000, 500, 400, 72_000, 250, 40);
    public static readonly Sizes Small = new(12, 3, 2, 5000, 5, 40);
}

/// <summary>One benchmark file: how it is made, and the word Find looks for in it.</summary>
public sealed record CorpusFile(string Name, string What, string FindWord, Action<string, Sizes, Action<string>> Make);

/// <summary>
/// The four files of roadmap 3.6's benchmark, written straight to disk with <see cref="PdfFileWriter"/>. Every file is
/// deterministic: its text, noise and paths come from <see cref="Rng"/> seeded by the page number, and nothing in it
/// comes from the clock, so a file's SHA-256 is the same on every machine (the hashes are in RESULTS.md).
/// </summary>
public static class Corpus
{
    public static readonly IReadOnlyList<CorpusFile> Files =
    [
        new("text.pdf", "{0:N0}-page text document: real paragraphs in Times, Helvetica, Courier and Helvetica-Bold (standard fonts, Flate content)", "lantern", MakeText),
        new("scan.pdf", "{0:N0}-page scan: 300 dpi grayscale JPEG pages (2550 × 3300 px) with paper noise, text-like lines and specks", "lantern", MakeScan),
        new("drawings.pdf", "{0:N0}-sheet drawing set (ARCH D, 36 × 24 in): hatching, polylines and circles, {1:N0} paths per sheet, a title block", "detail", MakeDrawings),
        new("comments.pdf", "{0:N0}-page text document with {1:N0} comments: notes, highlights, underlines, strike-outs, boxes, circles, ink, text boxes, with popups, and replies", "lantern", MakeComments),
    ];

    public static string Describe(CorpusFile f, Sizes s) => f.Name switch
    {
        "text.pdf" => string.Format(CultureInfo.InvariantCulture, f.What, s.TextPages),
        "scan.pdf" => string.Format(CultureInfo.InvariantCulture, f.What, s.ScanPages),
        "drawings.pdf" => string.Format(CultureInfo.InvariantCulture, f.What, s.DrawingSheets, s.PathsPerSheet),
        _ => string.Format(CultureInfo.InvariantCulture, f.What, s.CommentPages, s.CommentPages * s.CommentsPerPage),
    };

    /// <summary>Makes every file in <paramref name="dir"/> (a file that exists is left alone unless <paramref name="force"/>).</summary>
    public static void Make(string dir, Sizes sizes, Action<string> log, bool force = false)
    {
        Directory.CreateDirectory(dir);
        foreach (var f in Files)
        {
            var path = Path.Combine(dir, f.Name);
            if (File.Exists(path) && !force)
            {
                log($"{f.Name}: exists ({new FileInfo(path).Length / 1048576.0:N1} MB), kept");
                continue;
            }
            var sw = System.Diagnostics.Stopwatch.StartNew();
            var tmp = path + ".tmp";
            f.Make(tmp, sizes, log);
            File.Move(tmp, path, overwrite: true);
            log($"{f.Name}: {new FileInfo(path).Length / 1048576.0:N1} MB in {sw.Elapsed.TotalSeconds:N0} s, SHA-256 {Sha256(path)}");
        }
    }

    public static string Sha256(string path)
    {
        using var s = File.OpenRead(path);
        return Convert.ToHexStringLower(SHA256.HashData(s));
    }

    private static string FileId(string name) => Convert.ToHexString(MD5.HashData(Encoding.ASCII.GetBytes("inkvolt-bench-" + name)));

    private static int Info(PdfFileWriter w, string title) =>
        w.Add($"<< /Title {PdfFileWriter.Str(title)} /Producer (Inkvolt PDF benchmark corpus) >>");

    private const string Fonts =
        "/F1 << /Type /Font /Subtype /Type1 /BaseFont /Times-Roman /Encoding /WinAnsiEncoding >> " +
        "/F2 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >> " +
        "/F3 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >> " +
        "/F4 << /Type /Font /Subtype /Type1 /BaseFont /Courier /Encoding /WinAnsiEncoding >> " +
        "/F5 << /Type /Font /Subtype /Type1 /BaseFont /Times-Italic /Encoding /WinAnsiEncoding >>";

    // ---- text.pdf ----

    /// <summary>A text line as laid out: its font, size and baseline, and its estimated width (for highlights).</summary>
    public readonly record struct Line(string Font, double Size, double X, double Y, double Width);

    private const double Left = 72, Top = 720, TextWidth = 468, Body = 11, Leading = 14;

    /// <summary>Average glyph width in em for the standard fonts, on the wide side so no line runs off the page.</summary>
    private static double AvgWidth(string font) => font switch { "/F1" or "/F5" => 0.50, "/F4" => 0.60, _ => 0.56 };

    /// <summary>A Letter page of prose: a heading, paragraphs in the page's body font, a quote in italics, a footer.</summary>
    public static string TextPage(int pageNo, int pageCount, List<Line>? lines)
    {
        var rng = new Rng(1_000_003UL * (ulong)pageNo + 17);
        var body = ((pageNo / 7) % 3) switch { 0 => "/F1", 1 => "/F3", _ => "/F4" };
        var sb = new StringBuilder(4096);
        var y = Top;
        if (pageNo % 5 == 1)
        {
            var title = $"Chapter {pageNo / 5 + 1}: {Prose.Title(ref rng)}";
            sb.Append($"BT /F2 16 Tf {F(Left)} {F(y)} Td {PdfFileWriter.Str(title)} Tj ET\n");
            lines?.Add(new Line("/F2", 16, Left, y, title.Length * 16 * 0.56));
            y -= 30;
        }
        var para = 0;
        while (y > 100)
        {
            var font = para % 4 == 3 ? "/F5" : body;
            var maxChars = (int)(TextWidth / (Body * AvgWidth(font)));
            sb.Append($"BT {font} {F(Body)} Tf {F(Leading)} TL {F(Left)} {F(y)} Td\n");
            foreach (var line in Prose.Wrap(Prose.Paragraph(ref rng), maxChars))
            {
                if (y <= 100) break;
                sb.Append(PdfFileWriter.Str(line)).Append(" Tj T*\n");
                lines?.Add(new Line(font, Body, Left, y, line.Length * Body * AvgWidth(font)));
                y -= Leading;
            }
            sb.Append("ET\n");
            y -= Leading / 2;
            para++;
        }
        sb.Append($"BT /F3 9 Tf {F(Left)} 50 Td (Page {pageNo} of {pageCount}) Tj 330 0 Td (Inkvolt PDF benchmark corpus) Tj ET\n");
        return sb.ToString();
    }

    private static void MakeText(string path, Sizes s, Action<string> log) => WriteTextDocument(path, s.TextPages, "Benchmark: text", "text.pdf", null);

    /// <param name="annotate">Writes a page's annotations (given the writer, the page's object number, its index and its
    /// lines) and returns their object numbers for the page's /Annots.</param>
    private static void WriteTextDocument(string path, int pages, string title, string idName, Func<PdfFileWriter, int, int, List<Line>, List<int>>? annotate)
    {
        using var w = new PdfFileWriter(new BufferedStream(File.Create(path), 1 << 20));
        var info = Info(w, title);
        var fonts = w.Add($"<< {Fonts} >>");
        var resources = w.Add($"<< /Font {fonts} 0 R >>");
        var tree = new PageTree(w, pages);
        var lines = new List<Line>();
        for (var p = 0; p < pages; p++)
        {
            lines.Clear();
            var content = w.AddStream("", Encoding.Latin1.GetBytes(TextPage(p + 1, pages, lines)));
            var page = w.Reserve();
            tree.Add(page);
            var annots = annotate is null ? "" : $" /Annots [{string.Join(' ', annotate(w, page, p, lines).Select(i => $"{i} 0 R"))}]";
            w.Put(page, $"<< /Type /Page /Parent {tree.ParentOf(p)} 0 R /MediaBox [0 0 612 792] /Resources {resources} 0 R /Contents {content} 0 R{annots} >>");
        }
        tree.Write();
        var catalog = w.Add($"<< /Type /Catalog /Pages {tree.RootId} 0 R >>");
        w.Finish(catalog, info, FileId(idName));
    }

    // ---- scan.pdf ----

    public const int ScanWidth = 2550, ScanHeight = 3300, ScanDpi = 300;

    /// <summary>A scanned page as pixels: off-white paper with noise and a slight shading, lines of dark word-shaped blobs, specks.</summary>
    public static byte[] ScanPixels(int pageNo)
    {
        var rng = new Rng(7919UL * (ulong)pageNo + 101);
        var px = new byte[ScanWidth * ScanHeight];
        for (var y = 0; y < ScanHeight; y++)
        {
            var row = y * ScanWidth;
            for (var x = 0; x < ScanWidth; x++)
                px[row + x] = (byte)(236 + x * 8 / ScanWidth + rng.Next(13) - 6);
        }
        void Blob(int x0, int y0, int wdt, int hgt, int gray)
        {
            for (var y = Math.Max(0, y0); y < Math.Min(ScanHeight, y0 + hgt); y++)
                for (var x = Math.Max(0, x0); x < Math.Min(ScanWidth, x0 + wdt); x++)
                {
                    var edge = y == y0 || y == y0 + hgt - 1 || x == x0 || x == x0 + wdt - 1;
                    px[y * ScanWidth + x] = (byte)Math.Clamp(gray + (edge ? 60 : 0) + rng.Next(21) - 10, 0, 255);
                }
        }
        var lineY = 300 + rng.Next(40);
        for (var line = 0; line < 55; line++, lineY += 50)
        {
            if (rng.Next(100) < 8) continue; // a blank line between paragraphs
            var x = 250 + rng.Next(8);
            var end = rng.Next(100) < 15 ? 900 + rng.Next(1200) : 2300;
            var height = 22 + rng.Next(5);
            while (x < end)
            {
                var wdt = 60 + rng.Next(160);
                Blob(x, lineY + rng.Next(3), wdt, height, 25 + rng.Next(50));
                x += wdt + 18 + rng.Next(14);
            }
        }
        for (var i = 0; i < 400; i++) Blob(rng.Next(ScanWidth), rng.Next(ScanHeight), 1 + rng.Next(3), 1 + rng.Next(3), 40 + rng.Next(80));
        return px;
    }

    private static void MakeScan(string path, Sizes s, Action<string> log)
    {
        using var w = new PdfFileWriter(new BufferedStream(File.Create(path), 1 << 20));
        var info = Info(w, "Benchmark: scan");
        var tree = new PageTree(w, s.ScanPages);
        const int chunk = 8;
        for (var start = 0; start < s.ScanPages; start += chunk)
        {
            var n = Math.Min(chunk, s.ScanPages - start);
            var jpegs = new byte[n][];
            Parallel.For(0, n, i => jpegs[i] = JpegEncoder.EncodeGray(ScanPixels(start + i + 1), ScanWidth, ScanHeight, 75, ScanDpi));
            for (var i = 0; i < n; i++)
            {
                var image = w.AddStream($"/Type /XObject /Subtype /Image /Width {ScanWidth} /Height {ScanHeight} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", jpegs[i], null);
                var content = w.AddStream("", "q 612 0 0 792 0 0 cm /Im0 Do Q"u8, null);
                var p = start + i;
                var page = w.Add($"<< /Type /Page /Parent {tree.ParentOf(p)} 0 R /MediaBox [0 0 612 792] /Resources << /XObject << /Im0 {image} 0 R >> >> /Contents {content} 0 R >>");
                tree.Add(page);
            }
            log($"scan.pdf: {start + n} of {s.ScanPages} pages");
        }
        tree.Write();
        var catalog = w.Add($"<< /Type /Catalog /Pages {tree.RootId} 0 R >>");
        w.Finish(catalog, info, FileId("scan.pdf"));
    }

    // ---- drawings.pdf ----

    public const double SheetWidth = 2592, SheetHeight = 1728; // ARCH D in points

    private static readonly string[] SheetWords = ["PLAN", "ELEVATION", "SECTION", "DETAIL", "SCHEDULE", "LAYOUT", "FRAMING", "FOUNDATION", "ROOF", "SITE"];
    private static readonly string[] SheetWhere = ["NORTH WING", "SOUTH WING", "LEVEL 1", "LEVEL 2", "LEVEL 3", "BASEMENT", "EAST STAIR", "WEST STAIR", "PLANT ROOM", "LOBBY"];

    /// <summary>The sheet's title, as its title block shows it ("A-101  DETAIL PLAN, NORTH WING").</summary>
    public static string SheetTitle(int sheetNo) =>
        $"A-{100 + sheetNo}  {SheetWords[(sheetNo * 3) % SheetWords.Length]} {SheetWords[(sheetNo * 7 + 1) % SheetWords.Length]}, {SheetWhere[sheetNo % SheetWhere.Length]}";

    /// <summary>One sheet's content: a border, a light grid, the title block, then the paths.</summary>
    public static byte[] SheetContent(int sheetNo, int paths)
    {
        var rng = new Rng(104_729UL * (ulong)sheetNo + 7);
        var sb = new StringBuilder(paths * 40 + 4096);
        sb.Append($"0 G 1.5 w 36 36 {F(SheetWidth - 72)} {F(SheetHeight - 72)} re S\n0.85 G 0.25 w\n");
        for (var x = 136; x < SheetWidth - 100; x += 100) sb.Append($"{x} 36 m {x} {F(SheetHeight - 36)} l S\n");
        for (var y = 136; y < SheetHeight - 100; y += 100) sb.Append($"36 {y} m {F(SheetWidth - 36)} {y} l S\n");
        sb.Append($"0 G 1 w {F(SheetWidth - 636)} 36 600 120 re S\n");
        sb.Append($"BT /F2 24 Tf {F(SheetWidth - 616)} 110 Td {PdfFileWriter.Str(SheetTitle(sheetNo))} Tj ET\n");
        sb.Append($"BT /F3 12 Tf {F(SheetWidth - 616)} 70 Td (Inkvolt PDF benchmark corpus  Sheet {sheetNo} of the set  Scale 1:100  Not for construction) Tj ET\n");

        double x0 = 60, y0 = 180, x1 = SheetWidth - 60, y1 = SheetHeight - 60;
        for (var i = 0; i < paths; i++)
        {
            if (i % 400 == 0)
            {
                var gray = rng.Next(4) == 0;
                if (gray) sb.Append($"{F(rng.Next(60) / 100.0)} G ");
                else sb.Append($"{F(rng.Next(70) / 100.0)} {F(rng.Next(70) / 100.0)} {F(rng.Next(70) / 100.0)} RG ");
                sb.Append($"{F(0.25 + rng.Next(5) * 0.25)} w\n");
            }
            var x = x0 + rng.NextDouble() * (x1 - x0);
            var y = y0 + rng.NextDouble() * (y1 - y0);
            var kind = rng.Next(10);
            if (kind < 6)
            {
                // hatching: a short stroke at 45° or 135°, or axis-aligned
                var len = 2 + rng.NextDouble() * 24;
                var (dx, dy) = (rng.Next(4)) switch { 0 => (len, len), 1 => (len, -len), 2 => (len, 0.0), _ => (0.0, len) };
                Num(sb, x).Append(' '); Num(sb, y).Append(" m "); Num(sb, x + dx).Append(' '); Num(sb, y + dy).Append(" l S\n");
            }
            else if (kind < 9)
            {
                var n = 3 + rng.Next(6);
                Num(sb, x).Append(' '); Num(sb, y).Append(" m");
                for (var k = 1; k < n; k++)
                {
                    x = Math.Clamp(x + (rng.NextDouble() - 0.5) * 80, x0, x1);
                    y = Math.Clamp(y + (rng.NextDouble() - 0.5) * 80, y0, y1);
                    sb.Append(' '); Num(sb, x).Append(' '); Num(sb, y).Append(" l");
                }
                sb.Append(" S\n");
            }
            else
            {
                var r = 2 + rng.NextDouble() * 28;
                const double k = 0.5523;
                Num(sb, x + r).Append(' '); Num(sb, y).Append(" m ");
                Curve(sb, x + r, y + k * r, x + k * r, y + r, x, y + r);
                Curve(sb, x - k * r, y + r, x - r, y + k * r, x - r, y);
                Curve(sb, x - r, y - k * r, x - k * r, y - r, x, y - r);
                Curve(sb, x + k * r, y - r, x + r, y - k * r, x + r, y);
                sb.Append("h S\n");
            }
        }
        return Encoding.Latin1.GetBytes(sb.ToString());

        static void Curve(StringBuilder sb, double a, double b, double c, double d, double e, double f)
        {
            Num(sb, a).Append(' '); Num(sb, b).Append(' '); Num(sb, c).Append(' '); Num(sb, d).Append(' '); Num(sb, e).Append(' '); Num(sb, f).Append(" c ");
        }
    }

    /// <summary>Appends a coordinate with one decimal ("123.4", "7") without going through a format string.</summary>
    private static StringBuilder Num(StringBuilder sb, double v)
    {
        var tenths = (long)Math.Round(v * 10);
        if (tenths < 0) { sb.Append('-'); tenths = -tenths; }
        sb.Append(tenths / 10);
        if (tenths % 10 != 0) sb.Append('.').Append(tenths % 10);
        return sb;
    }

    private static void MakeDrawings(string path, Sizes s, Action<string> log)
    {
        using var w = new PdfFileWriter(new BufferedStream(File.Create(path), 1 << 20));
        var info = Info(w, "Benchmark: drawing set");
        var fonts = w.Add($"<< {Fonts} >>");
        var resources = w.Add($"<< /Font {fonts} 0 R >>");
        var tree = new PageTree(w, s.DrawingSheets);
        var chunk = Math.Max(1, Math.Min(8, Environment.ProcessorCount));
        for (var start = 0; start < s.DrawingSheets; start += chunk)
        {
            var n = Math.Min(chunk, s.DrawingSheets - start);
            var streams = new byte[n][];
            // CAD exports compress their content; Fastest keeps the generator quick and the file realistically large
            Parallel.For(0, n, i => streams[i] = PdfFileWriter.Deflate(SheetContent(start + i + 1, s.PathsPerSheet), CompressionLevel.Fastest));
            for (var i = 0; i < n; i++)
            {
                var content = w.AddStream("/Filter /FlateDecode", streams[i], null);
                var p = start + i;
                var page = w.Add($"<< /Type /Page /Parent {tree.ParentOf(p)} 0 R /MediaBox [0 0 {F(SheetWidth)} {F(SheetHeight)}] /Resources {resources} 0 R /Contents {content} 0 R >>");
                tree.Add(page);
            }
            log($"drawings.pdf: {start + n} of {s.DrawingSheets} sheets");
        }
        tree.Write();
        var catalog = w.Add($"<< /Type /Catalog /Pages {tree.RootId} 0 R >>");
        w.Finish(catalog, info, FileId("drawings.pdf"));
    }

    // ---- comments.pdf ----

    private static readonly string[] Authors = ["Ana Reviewer", "Ben Reviewer", "Chloe Reviewer", "Dev Reviewer", "Eva Reviewer", "Finn Reviewer"];

    /// <summary>A fixed, increasing /M date per comment (never the clock).</summary>
    private static string Date(int n) => $"(D:2026{1 + n / 44640 % 9:D2}{1 + n / 1440 % 28:D2}{n / 60 % 24:D2}{n % 60:D2}00Z)";

    private static void MakeComments(string path, Sizes s, Action<string> log)
    {
        var noteIcon = -1;
        var helv = -1;
        var serial = 0;
        WriteTextDocument(path, s.CommentPages, "Benchmark: comments", "comments.pdf", (w, page, p, lines) =>
        {
            var ids = new List<int>();
            if (noteIcon < 0)
            {
                noteIcon = w.AddStream("/Type /XObject /Subtype /Form /BBox [0 0 20 20]",
                    "q 0.35 G 0.8 w 1 0.85 0.1 rg 1.5 6 m 1.5 18.5 l 18.5 18.5 l 18.5 6 l 9 6 l 5 1.5 l 6 6 l h B 0.3 G 1 w 5 15 m 15 15 l 5 12 m 15 12 l 5 9 m 12 9 l S Q"u8, null);
                helv = w.Add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
            }
            var rng = new Rng(65_537UL * (ulong)p + 3);
            var topLevel = new List<(int Id, double X, double Top)>();
            var replies = Math.Max(0, s.CommentsPerPage * 3 / 10);
            var top = s.CommentsPerPage - replies;
            for (var i = 0; i < top; i++)
            {
                var n = serial++;
                var author = Authors[n % Authors.Length];
                var text = Prose.Sentence(ref rng);
                var line = lines[rng.Next(lines.Count)];
                var id = w.Reserve();
                var popup = w.Reserve();
                string common = $"/Type /Annot /P {page} 0 R /NM (bench-{p}-{i}) /T {PdfFileWriter.Str(author)} /Contents {PdfFileWriter.Str(text)} /M {Date(n)} /CreationDate {Date(n)} /F 4 /CA 1 /Popup {popup} 0 R";
                double x1, y1, x2, y2;
                switch (i % 28)
                {
                    case < 8:
                    {
                        x1 = Left + rng.NextDouble() * 400; y2 = line.Y + 10; x2 = x1 + 20; y1 = y2 - 20;
                        w.Put(id, $"<< {common} /Subtype /Text /Name /Comment /Open false /Rect [{F(x1)} {F(y1)} {F(x2)} {F(y2)}] /C [1 0.85 0.1] /AP << /N {noteIcon} 0 R >> >>");
                        break;
                    }
                    case < 14:
                    {
                        (x1, y1, x2, y2) = (line.X, line.Y - 3, line.X + Math.Max(40, line.Width), line.Y + line.Size * 0.8);
                        var ap = w.AddStream($"/Type /XObject /Subtype /Form /BBox [{F(x1)} {F(y1)} {F(x2)} {F(y2)}] /Resources << /ExtGState << /GS << /BM /Multiply >> >> >>",
                            Encoding.Latin1.GetBytes($"/GS gs 1 0.85 0.1 rg {F(x1)} {F(y1)} {F(x2 - x1)} {F(y2 - y1)} re f"), null);
                        w.Put(id, $"<< {common} /Subtype /Highlight /Rect [{F(x1)} {F(y1)} {F(x2)} {F(y2)}] /QuadPoints [{F(x1)} {F(y2)} {F(x2)} {F(y2)} {F(x1)} {F(y1)} {F(x2)} {F(y1)}] /C [1 0.85 0.1] /AP << /N {ap} 0 R >> >>");
                        break;
                    }
                    case < 20:
                    {
                        var strike = i % 28 >= 17;
                        (x1, y1, x2, y2) = (line.X, line.Y - 3, line.X + Math.Max(40, line.Width), line.Y + line.Size * 0.8);
                        var ly = strike ? (y1 + y2) / 2 : y1 + 1;
                        var color = strike ? "0.9 0.1 0.1" : "0 0 1";
                        var ap = w.AddStream($"/Type /XObject /Subtype /Form /BBox [{F(x1)} {F(y1)} {F(x2)} {F(y2)}]",
                            Encoding.Latin1.GetBytes($"{color} RG 1 w {F(x1)} {F(ly)} m {F(x2)} {F(ly)} l S"), null);
                        w.Put(id, $"<< {common} /Subtype /{(strike ? "StrikeOut" : "Underline")} /Rect [{F(x1)} {F(y1)} {F(x2)} {F(y2)}] /QuadPoints [{F(x1)} {F(y2)} {F(x2)} {F(y2)} {F(x1)} {F(y1)} {F(x2)} {F(y1)}] /C [{color}] /AP << /N {ap} 0 R >> >>");
                        break;
                    }
                    case < 23:
                    {
                        var circle = p % 2 == 1;
                        x1 = Left + rng.NextDouble() * 300; y1 = 120 + rng.NextDouble() * 500; x2 = x1 + 60 + rng.NextDouble() * 120; y2 = y1 + 30 + rng.NextDouble() * 60;
                        string ops;
                        if (circle)
                        {
                            double cx = (x1 + x2) / 2, cy = (y1 + y2) / 2, rx = (x2 - x1) / 2 - 1, ry = (y2 - y1) / 2 - 1;
                            const double k = 0.5523;
                            ops = $"0.9 0.1 0.1 RG 2 w {F(cx + rx)} {F(cy)} m {F(cx + rx)} {F(cy + k * ry)} {F(cx + k * rx)} {F(cy + ry)} {F(cx)} {F(cy + ry)} c " +
                                  $"{F(cx - k * rx)} {F(cy + ry)} {F(cx - rx)} {F(cy + k * ry)} {F(cx - rx)} {F(cy)} c {F(cx - rx)} {F(cy - k * ry)} {F(cx - k * rx)} {F(cy - ry)} {F(cx)} {F(cy - ry)} c " +
                                  $"{F(cx + k * rx)} {F(cy - ry)} {F(cx + rx)} {F(cy - k * ry)} {F(cx + rx)} {F(cy)} c h S";
                        }
                        else ops = $"0.9 0.1 0.1 RG 2 w {F(x1 + 1)} {F(y1 + 1)} {F(x2 - x1 - 2)} {F(y2 - y1 - 2)} re S";
                        var ap = w.AddStream($"/Type /XObject /Subtype /Form /BBox [{F(x1)} {F(y1)} {F(x2)} {F(y2)}]", Encoding.Latin1.GetBytes(ops), null);
                        w.Put(id, $"<< {common} /Subtype /{(circle ? "Circle" : "Square")} /Rect [{F(x1)} {F(y1)} {F(x2)} {F(y2)}] /C [0.9 0.1 0.1] /BS << /W 2 >> /AP << /N {ap} 0 R >> >>");
                        break;
                    }
                    case < 26:
                    {
                        var pts = new List<double>();
                        var x = Left + rng.NextDouble() * 300;
                        var y = 120 + rng.NextDouble() * 500;
                        (x1, y1, x2, y2) = (x, y, x, y);
                        for (var k = 0; k < 12; k++)
                        {
                            pts.Add(x); pts.Add(y);
                            x += 4 + rng.NextDouble() * 10; y += (rng.NextDouble() - 0.5) * 16;
                            (x1, y1, x2, y2) = (Math.Min(x1, x), Math.Min(y1, y), Math.Max(x2, x), Math.Max(y2, y));
                        }
                        (x1, y1, x2, y2) = (x1 - 2, y1 - 2, x2 + 2, y2 + 2);
                        var list = string.Join(' ', pts.Select(F));
                        var ops = new StringBuilder("0 0 0.8 RG 2 w 1 J 1 j ");
                        for (var k = 0; k < pts.Count; k += 2) ops.Append($"{F(pts[k])} {F(pts[k + 1])} {(k == 0 ? "m" : "l")} ");
                        ops.Append('S');
                        var ap = w.AddStream($"/Type /XObject /Subtype /Form /BBox [{F(x1)} {F(y1)} {F(x2)} {F(y2)}]", Encoding.Latin1.GetBytes(ops.ToString()), null);
                        w.Put(id, $"<< {common} /Subtype /Ink /Rect [{F(x1)} {F(y1)} {F(x2)} {F(y2)}] /InkList [[{list}]] /C [0 0 0.8] /BS << /W 2 >> /AP << /N {ap} 0 R >> >>");
                        break;
                    }
                    default:
                    {
                        x1 = Left + rng.NextDouble() * 250; y1 = 120 + rng.NextDouble() * 500; x2 = x1 + 180; y2 = y1 + 40;
                        var shown = text.Length > 30 ? text[..30] : text;
                        var ap = w.AddStream($"/Type /XObject /Subtype /Form /BBox [{F(x1)} {F(y1)} {F(x2)} {F(y2)}] /Resources << /Font << /Helv {helv} 0 R >> >>",
                            Encoding.Latin1.GetBytes($"1 1 0.8 rg 0 G 1 w {F(x1 + 0.5)} {F(y1 + 0.5)} 179 39 re B BT /Helv 10 Tf 0 g {F(x1 + 4)} {F(y2 - 14)} Td {PdfFileWriter.Str(shown)} Tj ET"), null);
                        w.Put(id, $"<< {common} /Subtype /FreeText /DA (/Helv 10 Tf 0 g) /Rect [{F(x1)} {F(y1)} {F(x2)} {F(y2)}] /C [1 1 0.8] /AP << /N {ap} 0 R >> >>");
                        break;
                    }
                }
                w.Put(popup, $"<< /Type /Annot /Subtype /Popup /Parent {id} 0 R /Open false /Rect [{F(Math.Min(x2 + 10, 420))} {F(Math.Max(y2 - 120, 40))} {F(Math.Min(x2 + 10, 420) + 180)} {F(Math.Max(y2 - 120, 40) + 120)}] >>");
                ids.Add(id);
                ids.Add(popup);
                topLevel.Add((id, x1, y2));
            }
            for (var r = 0; r < replies; r++)
            {
                var n = serial++;
                var parent = topLevel[r % topLevel.Count];
                var author = Authors[(n + 3) % Authors.Length];
                var text = Prose.Sentence(ref rng);
                var id = w.Add($"<< /Type /Annot /Subtype /Text /P {page} 0 R /NM (bench-{p}-r{r}) /IRT {parent.Id} 0 R /RT /R /Name /Comment /T {PdfFileWriter.Str(author)} " +
                               $"/Contents {PdfFileWriter.Str(text)} /M {Date(n)} /CreationDate {Date(n)} /F 28 /CA 1 /Rect [{F(parent.X)} {F(parent.Top - 20)} {F(parent.X + 20)} {F(parent.Top)}] /C [1 0.85 0.1] /AP << /N {noteIcon} 0 R >> >>");
                ids.Add(id);
            }
            return ids;
        });
    }

    private static string F(double v) => Math.Round(v, 2).ToString("0.##", CultureInfo.InvariantCulture);
}

/// <summary>xorshift64*: small, fast, and the same everywhere.</summary>
public struct Rng(ulong seed)
{
    private ulong _s = seed == 0 ? 0x9E3779B97F4A7C15UL : seed;

    public ulong NextRaw()
    {
        _s ^= _s >> 12;
        _s ^= _s << 25;
        _s ^= _s >> 27;
        return _s * 0x2545F4914F6CDD1DUL;
    }

    public int Next(int n) => (int)(NextRaw() % (ulong)n);

    public double NextDouble() => (NextRaw() >> 11) * (1.0 / (1UL << 53));
}

/// <summary>Made-up English prose from a word bank (a search target, "lantern", is in it).</summary>
public static class Prose
{
    private static readonly string[] Words =
    [
        "the", "a", "and", "of", "to", "in", "that", "with", "for", "on", "by", "from", "as", "at", "but", "not", "this", "which", "or", "an",
        "river", "lantern", "harbor", "window", "meadow", "ledger", "engine", "bridge", "garden", "letter", "market", "valley", "signal", "copper",
        "quarry", "orchard", "compass", "granite", "thunder", "candle", "willow", "saddle", "anchor", "barrel", "beacon", "canvas", "cellar",
        "chapel", "cobble", "cotton", "dagger", "ember", "falcon", "fossil", "furnace", "glacier", "hammer", "harvest", "hollow", "island",
        "jacket", "kettle", "lumber", "marble", "mirror", "needle", "oyster", "parcel", "pillar", "pocket", "quiver", "ribbon", "rudder",
        "shadow", "silver", "spring", "stable", "summit", "tunnel", "turret", "velvet", "wagon", "walnut", "whistle", "winter", "yonder",
        "walks", "turns", "carries", "builds", "finds", "holds", "keeps", "leaves", "meets", "opens", "reads", "sends", "stands", "takes",
        "waits", "writes", "measures", "returns", "follows", "answers", "gathers", "crosses", "remains", "settles", "remembers", "counts",
        "quiet", "early", "narrow", "steady", "bright", "distant", "hollow", "patient", "simple", "sudden", "little", "broad", "plain",
        "heavy", "gentle", "ancient", "careful", "common", "eager", "formal", "honest", "modest", "narrow", "proper", "rough", "sharp",
        "slowly", "often", "again", "almost", "rather", "nearly", "still", "already", "perhaps", "later", "before", "after", "between",
        "morning", "evening", "season", "village", "country", "station", "journey", "history", "minute", "moment", "number", "reason",
        "weather", "account", "balance", "chapter", "company", "council", "customs", "deposit", "freight", "invoice", "manager", "meeting",
        "notice", "office", "payment", "project", "record", "report", "request", "schedule", "service", "summary", "survey", "ticket",
    ];

    public static string Word(ref Rng rng) => Words[rng.Next(Words.Length)];

    public static string Sentence(ref Rng rng)
    {
        var n = 6 + rng.Next(11);
        var sb = new StringBuilder();
        for (var i = 0; i < n; i++)
        {
            var w = Words[rng.Next(Words.Length)];
            if (i == 0) w = char.ToUpperInvariant(w[0]) + w[1..];
            if (i > 0) sb.Append(i == n / 2 && rng.Next(3) == 0 ? ", " : " ");
            sb.Append(w);
        }
        return sb.Append('.').ToString();
    }

    public static string Paragraph(ref Rng rng)
    {
        var n = 3 + rng.Next(5);
        var sb = new StringBuilder();
        for (var i = 0; i < n; i++) sb.Append(i > 0 ? " " : "").Append(Sentence(ref rng));
        return sb.ToString();
    }

    public static string Title(ref Rng rng)
    {
        var n = 2 + rng.Next(3);
        var parts = new List<string>();
        for (var i = 0; i < n; i++)
        {
            var w = Words[20 + rng.Next(Words.Length - 20)];
            parts.Add(char.ToUpperInvariant(w[0]) + w[1..]);
        }
        return string.Join(' ', parts);
    }

    /// <summary>Greedy word wrap to at most <paramref name="maxChars"/> per line.</summary>
    public static IEnumerable<string> Wrap(string text, int maxChars)
    {
        var line = new StringBuilder();
        foreach (var word in text.Split(' '))
        {
            if (line.Length > 0 && line.Length + 1 + word.Length > maxChars)
            {
                yield return line.ToString();
                line.Clear();
            }
            if (line.Length > 0) line.Append(' ');
            line.Append(word);
        }
        if (line.Length > 0) yield return line.ToString();
    }
}
