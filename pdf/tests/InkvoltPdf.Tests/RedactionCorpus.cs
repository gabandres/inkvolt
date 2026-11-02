using System.Text;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.Tests;

/// <summary>
/// The roadmap 1.1 corpus, generated: values planted line-broken, hyphenated, in split text runs, on a turned page, on
/// scanned pages (upright, turned by the page's /Rotate, on its side on the glass), in a picture on a text page, under a
/// poor text layer, and the lot again in an encrypted copy. A scan's words are what <see cref="PlantedReader"/> says it
/// reads, so the tests don't depend on a recognizer; the real one reads the same file when driven through the app.
/// </summary>
internal static class RedactionCorpus
{
    public const string Password = "corpus-open-1";

    /// <summary>A value planted on a page.</summary>
    public sealed record Planted(int Page, RedactionPattern Kind, string Value);

    public static readonly RedactionPatternOptions Search = new()
    {
        Patterns = RedactionPatterns.BuiltIn.Where(p => p != RedactionPattern.ZipCode).ToHashSet(),
        Phrases = ["Quillfeather Holdings"],
        Expression = @"CASE-\d{4}",
    };

    public static readonly Planted[] Values =
    [
        // Page 1: line-broken.
        new(0, RedactionPattern.SocialSecurity, "123-45-6789"),
        new(0, RedactionPattern.Phone, "(555) 201 3434"),
        new(0, RedactionPattern.PaymentCard, "4111 1111 1111 1111"),
        new(0, RedactionPattern.Date, "October 27, 2026"),
        new(0, RedactionPattern.Phrase, "Quillfeather Holdings"),
        // Page 2: hyphenated at the line's end.
        new(1, RedactionPattern.Email, "jane.doe@example.com"),
        new(1, RedactionPattern.SocialSecurity, "078-05-1120"),
        new(1, RedactionPattern.Expression, "CASE-0412"),
        // Page 3: split text runs, kerning between digits.
        new(2, RedactionPattern.PaymentCard, "5555 5555 5555 4444"),
        new(2, RedactionPattern.Iban, "DE89 3704 0044 0532 0130 00"),
        new(2, RedactionPattern.IpAddress, "192.168.1.10"),
        // Page 4: a page turned by /Rotate 90.
        new(3, RedactionPattern.SocialSecurity, "219-09-9999"),
        new(3, RedactionPattern.Email, "turned@example.org"),
        // Page 5: a scan.
        new(4, RedactionPattern.SocialSecurity, "457-55-5462"),
        new(4, RedactionPattern.Email, "scan.one@example.net"),
        new(4, RedactionPattern.Phrase, "Quillfeather Holdings"),
        // Page 6: a scan with /Rotate 90.
        new(5, RedactionPattern.Phone, "555-867-5309"),
        // Page 7: a scan on its side on the glass.
        new(6, RedactionPattern.PaymentCard, "3782 822463 10005"),
        // Page 8: text, with a picture of text.
        new(7, RedactionPattern.Email, "own.text@example.org"),
        new(7, RedactionPattern.Expression, "CASE-7788"),
        // Page 9: a scan under an old text layer that misses the value.
        new(8, RedactionPattern.SocialSecurity, "321-54-9876"),
    ];

    public static readonly int[] ScanPages = [4, 5, 6, 8];

    public static byte[] Make(out PlantedReader reader)
    {
        reader = new PlantedReader();
        PageDef[] textPages =
        [
            new(["Public heading", "SSN 123-45-", "6789 and phone (555) 201", "3434, card 4111 1111", "1111 1111, born October", "27, 2026 for Quillfeather", "Holdings today."], 0),
            new(["Public heading", "Write to jane.doe@exam-", "ple.com about 078-05-", "1120 and CASE-", "0412 soon."], 0),
            new([], 0, "BT /F1 14 Tf 72 700 Td [(55)-5(55 55)-8(55 5555 4)-2(444)] TJ ET\n" +
                       "BT /F1 14 Tf 72 676 Td (DE89 3704 ) Tj (0044 0532 ) Tj (0130 00) Tj ET\n" +
                       "BT /F1 14 Tf 72 652 Td (192.) Tj (168.) Tj (1.) Tj (10) Tj ET\n"),
            new(["Sideways reading", "SSN 219-09-9999 here", "Mail turned@example.org"], 90),
        ];
        // Redacted, these pages are pictures too: the reader knows what is on them, and reads what stays visible.
        foreach (var page in textPages)
        {
            using var upright = PdfEngine.Open(TextPdf([page with { Rotate = 0 }]), InputFileTypes.PDF, null);
            var image = upright.Render(0, 150.0 / 72);
            reader.Plant(ScanCleanup.ToGray(image.Pixels, image.Width, image.Height), image.Width, image.Height, upright.GetText(0));
        }
        var text = TextPdf(textPages);
        byte[][] rest =
        [
            Scan(reader, ["Public heading on the scan", "SSN 457-55-5462 is here", "Mail scan.one@example.net now", "For Quillfeather", "Holdings today"]),
            Scan(reader, ["Please call this number soon", "Call 555-867-5309 today", "Thank you for your patience"], rotate: 90),
            Scan(reader, ["This page lay on its side", "Card 3782 822463 10005 was used", "All the lines read the same way", "So the page can be turned upright", "Before the words are read at all"], turn: 1),
            Mixed(reader),
            Layered(reader),
        ];
        return PageEditor.Merge([new PdfSource(text, null, "text"), .. rest.Select((r, i) => new PdfSource(r, null, $"scan{i}"))], false);
    }

    public static byte[] Encrypted(byte[] plain) => PdfSecurity.Protect(plain, null, Password, null, PdfPermissions.All);

    private sealed record PageDef(string[] Lines, int Rotate, string? Raw = null);

    private static byte[] TextPdf(IReadOnlyList<PageDef> pages)
    {
        var n = pages.Count;
        var objects = new List<string>
        {
            "<< /Type /Catalog /Pages 2 0 R >>",
            $"<< /Type /Pages /Kids [{string.Join(' ', Enumerable.Range(3, n).Select(i => $"{i} 0 R"))}] /Count {n} >>",
        };
        var font = 3 + 2 * n;
        for (var p = 0; p < n; p++)
            objects.Add($"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] {(pages[p].Rotate != 0 ? $"/Rotate {pages[p].Rotate}" : "")} /Contents {3 + n + p} 0 R /Resources << /Font << /F1 {font} 0 R >> >> >>");
        foreach (var page in pages)
        {
            var content = new StringBuilder(page.Raw ?? "");
            for (var l = 0; l < page.Lines.Length; l++)
                content.Append($"BT /F1 14 Tf 72 {700 - 24 * l} Td ({page.Lines[l].Replace(@"\", @"\\").Replace("(", @"\(").Replace(")", @"\)")}) Tj ET\n");
            objects.Add(Core2Pdf.Stream(content.ToString()));
        }
        objects.Add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>");
        return Core2Pdf.Build(objects);
    }

    /// <summary>A page of grey pixels in a PDF.</summary>
    internal static byte[] ImagePdf(byte[] gray, int width, int height, double pageWidth, double pageHeight, int rotate = 0, string extraContent = "", string extraResources = "", string[]? extraObjects = null)
    {
        List<string> objects =
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            $"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {pageWidth:0.###} {pageHeight:0.###}] {(rotate != 0 ? $"/Rotate {rotate}" : "")} /Contents 4 0 R /Resources << /XObject << /Im0 5 0 R >> {extraResources} >> >>",
            Core2Pdf.Stream($"q {pageWidth:0.###} 0 0 {pageHeight:0.###} 0 0 cm /Im0 Do Q\n{extraContent}"),
            Core2Pdf.Stream(Convert.ToHexString(gray) + ">", $"/Type /XObject /Subtype /Image /Width {width} /Height {height} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode"),
        ];
        if (extraObjects is not null) objects.AddRange(extraObjects);
        return Core2Pdf.Build(objects);
    }

    /// <summary>The lines typeset, drawn to pixels at 150 dpi, laid on the glass; the reader told where their words are.</summary>
    private static byte[] Scan(PlantedReader reader, string[] lines, int rotate = 0, int turn = 0)
    {
        using var engine = PdfEngine.Open(TextPdf([new PageDef(lines, 0)]), InputFileTypes.PDF, null);
        var image = engine.Render(0, 150.0 / 72);
        var gray = ScanCleanup.ToGray(image.Pixels, image.Width, image.Height);
        reader.Plant(gray, image.Width, image.Height, engine.GetText(0));
        var (w, h, pixels) = (image.Width, image.Height, gray);
        var quarters = turn - rotate / 90; // stored so that /Rotate shows it upright, or on its side
        pixels = ScanCleanup.Turn(pixels, w, h, 1, quarters);
        if (quarters % 2 != 0) (w, h) = (h, w);
        return ImagePdf(pixels, w, h, w * 72.0 / 150, h * 72.0 / 150, rotate);
    }

    /// <summary>A text page with a picture of text: the picture's words are for the recognizer only.</summary>
    private static byte[] Mixed(PlantedReader reader)
    {
        using var picture = PdfEngine.Open(TextPdf([new PageDef(["Stamped CASE-7788 received"], 0)]), InputFileTypes.PDF, null);
        var image = picture.Render(0, 3, new RectD(68, 74, 200, 24));
        var gray = ScanCleanup.ToGray(image.Pixels, image.Width, image.Height);
        var page = Core2Pdf.Build(
        [
            "<< /Type /Catalog /Pages 2 0 R >>",
            "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
            "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents 4 0 R /Resources << /Font << /F1 6 0 R >> /XObject << /Im0 5 0 R >> >> >>",
            Core2Pdf.Stream("BT /F1 14 Tf 72 700 Td (Mail own.text@example.org here) Tj ET\nq 200 0 0 24 72 472 cm /Im0 Do Q\n"),
            Core2Pdf.Stream(Convert.ToHexString(gray) + ">", $"/Type /XObject /Subtype /Image /Width {image.Width} /Height {image.Height} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /ASCIIHexDecode"),
            "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>",
        ]);
        using var engine = PdfEngine.Open(page, InputFileTypes.PDF, null);
        var shown = engine.Render(0, 150.0 / 72);
        var shownGray = ScanCleanup.ToGray(shown.Pixels, shown.Width, shown.Height);
        reader.PlantWords(shownGray, shown.Width, shown.Height, [("Stamped", new RectD(72, 296, 60, 24)), ("CASE-7788", new RectD(132, 296, 80, 24)), ("received", new RectD(212, 296, 60, 24))]);
        return page;
    }

    /// <summary>A scan with an invisible text layer that doesn't have the value: a poor old OCR, or a planted one.</summary>
    private static byte[] Layered(PlantedReader reader)
    {
        using var engine = PdfEngine.Open(TextPdf([new PageDef(["Public heading of this scan", "SSN 321-54-9876 on file", "Nothing else is written here"], 0)]), InputFileTypes.PDF, null);
        var image = engine.Render(0, 150.0 / 72);
        var gray = ScanCleanup.ToGray(image.Pixels, image.Width, image.Height);
        reader.Plant(gray, image.Width, image.Height, engine.GetText(0));
        return ImagePdf(gray, image.Width, image.Height, image.Width * 72.0 / 150, image.Height * 72.0 / 150, 0,
            "BT 3 Tr /F1 14 Tf 72 700 Td (Public heading of this scan) Tj 0 -24 Td (SSN on file) Tj ET\n",
            "/Font << /F1 6 0 R >>",
            ["<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]);
    }
}

/// <summary>
/// Stands in for the recognizer, without a language of its own: told where each page's words are on the upright page, it
/// tells which page it was handed from where the ink is, and returns the words it can see there (ink in the box, not blacked
/// out), so what comes back after redacting really is what is left to see. A word can be dropped, as Windows' recognizer
/// sometimes drops a whole line, and come back or not when its place is read on its own.
/// </summary>
internal sealed class PlantedReader : ITextRecognizer
{
    private const int GridW = 34, GridH = 44;

    /// <summary>A word, its box as shares of the page's size.</summary>
    private sealed record Word(string Text, double X, double Y, double W, double H);

    private sealed record Sheet(double[] Ink, List<Word> Words);

    private readonly List<Sheet> _sheets = [];

    public string Language => "en-US";

    public string LanguageName => "English";

    /// <summary>These words aren't read when a whole page is.</summary>
    public HashSet<string> Dropped { get; } = [];

    /// <summary>A dropped word is read when its place is read on its own.</summary>
    public bool ReadsPlacesAlone { get; set; }

    /// <summary>How many places were read on their own.</summary>
    public int PlacesRead { get; private set; }

    public void Plant(byte[] gray, int width, int height, PageText text)
    {
        var words = new List<(string, RectD)>();
        var value = text.Text;
        for (var i = 0; i < value.Length;)
        {
            if (char.IsWhiteSpace(value[i]))
            {
                i++;
                continue;
            }
            var end = i;
            while (end < value.Length && !char.IsWhiteSpace(value[end])) end++;
            words.Add((value[i..end], text.GetRects(i, end)[0]));
            i = end;
        }
        PlantWords(gray, width, height, words);
    }

    /// <param name="words">Boxes in points on a 612 x 792 page.</param>
    public void PlantWords(byte[] gray, int width, int height, IEnumerable<(string Text, RectD Box)> words) =>
        _sheets.Add(new Sheet(Signature(gray, width, height), [.. words.Select(w => new Word(w.Text, w.Box.X / 612, w.Box.Y / 792, w.Box.Width / 612, w.Box.Height / 792))]));

    public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
    {
        var gray = channels == 1 ? pixels : ScanCleanup.ToGray(pixels, width, height);
        if (height < 500)
        {
            PlacesRead++;
            if (!ReadsPlacesAlone || Dropped.Count == 0) return [];
            var inked = Enumerable.Range(0, gray.Length).Where(i => gray[i] < 128).ToList();
            if (inked.Count == 0) return [];
            var text = Dropped.First();
            Dropped.Remove(text);
            var (x0, y0) = (inked.Min(i => i % width), inked.Min(i => i / width));
            var (x1, y1) = (inked.Max(i => i % width), inked.Max(i => i / width));
            return [new RecognizedWord(text, x0, y0, x1 - x0 + 1, y1 - y0 + 1, 0)];
        }
        var ink = Signature(gray, width, height);
        var sheet = _sheets.MinBy(s => s.Ink.Zip(ink).Sum(p => Math.Abs(p.First - p.Second)));
        if (sheet is null) return [];
        var found = new List<RecognizedWord>();
        foreach (var w in sheet.Words)
        {
            if (Dropped.Contains(w.Text)) continue;
            var (x, y, bw, bh) = (w.X * width, w.Y * height, w.W * width, w.H * height);
            if (Sees(gray, width, height, x, y, bw, bh)) found.Add(new RecognizedWord(w.Text, x, y, bw, bh, 0));
        }
        return found;
    }

    private static double[] Signature(byte[] gray, int width, int height)
    {
        var cells = new double[GridW * GridH];
        for (var y = 0; y < height; y += 2)
            for (var x = 0; x < width; x += 2)
                if (gray[y * width + x] < 128) cells[y * GridH / height * GridW + x * GridW / width]++;
        var total = Math.Max(1, cells.Sum());
        for (var i = 0; i < cells.Length; i++) cells[i] /= total;
        return cells;
    }

    /// <summary>Ink in the word's box, and not a black bar.</summary>
    private static bool Sees(byte[] gray, int width, int height, double wx, double wy, double ww, double wh)
    {
        var (x0, y0) = (Math.Clamp((int)wx, 0, width), Math.Clamp((int)wy, 0, height));
        var (x1, y1) = (Math.Clamp((int)(wx + ww), 0, width), Math.Clamp((int)(wy + wh), 0, height));
        if (x1 <= x0 || y1 <= y0) return false;
        var dark = 0;
        for (var y = y0; y < y1; y++)
            for (var x = x0; x < x1; x++)
                if (gray[y * width + x] < 128) dark++;
        var share = dark / (double)((x1 - x0) * (y1 - y0));
        return share is > 0.03 and < 0.8;
    }
}
