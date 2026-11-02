using System.Diagnostics;
using System.Globalization;
using System.Text;
using InkvoltPdf.Bench;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.OcrCorpus;

/// <summary>How a page of the cleanup corpus was printed and laid on the glass.</summary>
public enum CleanupDamage { SkewedOnLid, GreyPaper, Halftoned, Faded }

/// <summary>One file of Inkvolt Print's cleanup corpus (roadmap 2.3): language, damage, and the filters the preset would have on.</summary>
public sealed record CleanupFile(string Name, string Language, CleanupDamage Damage, PageFilters Filters, double Skew, int Pages = 2);

public sealed record CleanupResult(string Name, string Language, CleanupDamage Damage, int Words, double? Today, double? After, double AfterMs);

/// <summary>
/// Inkvolt Print's filters against Windows' recognizer, on made-up pages: "today" is what the Scan tab reads today (the page
/// straightened), "cleaned" the same page cropped and filtered as a preset would. Each page is made from the same seed, so a
/// result says which pixels it came from. Pixels go to the recognizer directly in both readings: no JPEG between.
/// </summary>
public static class CleanupCorpus
{
    public const int Dpi = 300;

    public static readonly IReadOnlyList<CleanupFile> Files =
    [
        new("en-skewed-lid", "en", CleanupDamage.SkewedOnLid, PageFilters.CropToPaper | PageFilters.Whiten, 4.5),
        new("en-grey", "en", CleanupDamage.GreyPaper, PageFilters.Whiten, 1.5),
        new("en-halftoned", "en", CleanupDamage.Halftoned, PageFilters.Descreen | PageFilters.Whiten, 2),
        new("en-faded", "en", CleanupDamage.Faded, PageFilters.RestoreColors | PageFilters.Whiten, 2),
        new("es-grey", "es", CleanupDamage.GreyPaper, PageFilters.Whiten, 3),
        new("es-halftoned", "es", CleanupDamage.Halftoned, PageFilters.Descreen | PageFilters.Whiten, 1),
        new("es-faded", "es", CleanupDamage.Faded, PageFilters.RestoreColors | PageFilters.Whiten, 3),
        new("ru-grey-skewed", "ru", CleanupDamage.GreyPaper, PageFilters.Whiten, 5),
        new("ru-halftoned", "ru", CleanupDamage.Halftoned, PageFilters.Descreen | PageFilters.Whiten, 2),
        new("ja-grey-skewed", "ja", CleanupDamage.GreyPaper, PageFilters.Whiten, 5),
        new("ja-faded", "ja", CleanupDamage.Faded, PageFilters.RestoreColors | PageFilters.Whiten, 2),
    ];

    public static string Tag(string language) => language switch { "es" => "es-MX", "ru" => "ru-RU", "ja" => "ja-JP", _ => "en-US" };

    public static string Describe(CleanupFile f) =>
        $"{f.Language}, {f.Damage}, skew {f.Skew:0.#}°, filters: {PageCleanup.Describe(f.Filters)}";

    /// <summary>The clean page, grey at 300 dpi, and its words in reading order.</summary>
    public static (byte[] Pixels, int Width, int Height, List<string> Words) CleanPage(CleanupFile file, int page)
    {
        if (file.Language is "en" or "es")
        {
            var source = new CorpusFile("cleanup-" + file.Name, file.Language, file.Language == "es" ? "/Helvetica" : "/Times-Roman", 11, 0, 0, 0, 0, 0, null, file.Pages);
            return ScanCorpus.CleanPage(source, page);
        }
        return NonLatinPage(file, page);
    }

    /// <summary>What the scanner sends for this page: BGR for a faded color print, else grey; straightened by nothing.</summary>
    public static (byte[] Pixels, int Width, int Height, int Channels, List<string> Words) ScanPage(CleanupFile file, int page)
    {
        var (clean, w, h, words) = CleanPage(file, page);
        var rng = new Rng(Seed(file.Name) + 1009UL * (ulong)(page + 1));
        var skew = file.Skew * (page % 2 == 0 ? 1 : -1);
        return file.Damage switch
        {
            CleanupDamage.SkewedOnLid => (OnLid(clean, w, h, skew, ref rng), w + 300, h + 300, 1, words),
            CleanupDamage.GreyPaper => (Grey(clean, w, h, skew, ref rng), w, h, 1, words),
            CleanupDamage.Halftoned => (Halftoned(clean, w, h, skew, ref rng), w, h, 1, words),
            _ => (Faded(clean, w, h, skew, ref rng), w, h, 3, words),
        };
    }

    private static byte[] OnLid(byte[] page, int w, int h, double skew, ref Rng rng)
    {
        // A sheet of off-white paper, smaller than the glass: 150 pixels of lid all round, the lid lighter than the paper.
        var (gw, gh) = (w + 300, h + 300);
        var glass = new byte[gw * gh];
        Array.Fill(glass, (byte)255);
        const int lid = 250, paper = 214;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                glass[(y + 150) * gw + x + 150] = (byte)(paper * page[y * w + x] / 255);
        var turned = PageRotate.Rotate(glass, gw, gh, gw, 1, skew);
        for (var i = 0; i < turned.Length; i++)
            if (turned[i] == 255) turned[i] = lid;
        return Soft(turned, gw, gh, 10, 500, ref rng);
    }

    private static byte[] Grey(byte[] page, int w, int h, double skew, ref Rng rng)
    {
        // Dark recycled paper, darker to one side, printed lightly.
        var turned = PageRotate.Rotate(page, w, h, w, 1, skew);
        var result = new byte[w * h];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var along = (double)x / w;
                var level = 170 - 45 * along * along;
                result[y * w + x] = (byte)(55 + (level - 55) * turned[y * w + x] / 255);
            }
        return Soft(result, w, h, 16, 1200, ref rng);
    }

    private static byte[] Halftoned(byte[] page, int w, int h, double skew, ref Rng rng)
    {
        // Printed on a tint: 65 lines an inch at 45°, the whole sheet's paper dotted, the type solid. Dot size wanders a little.
        var result = new byte[w * h];
        const double period = 4.6;
        var tone = 0.28 + rng.NextDouble() * 0.06;
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var (u, v) = ((x + y) / Math.Sqrt(2), (x - y) / Math.Sqrt(2));
                var spot = (Math.Cos(2 * Math.PI * u / period) + Math.Cos(2 * Math.PI * v / period)) / 4 + 0.5;
                var dot = spot < tone ? 60.0 : 240.0;
                result[y * w + x] = (byte)(dot * page[y * w + x] / 255);
            }
        return Soft(PageRotate.Rotate(result, w, h, w, 1, skew), w, h, 6, 200, ref rng);
    }

    private static byte[] Faded(byte[] page, int w, int h, double skew, ref Rng rng)
    {
        // A color print gone pale and yellow: blacks lifted a long way, blue fading out of the white.
        var turned = PageRotate.Rotate(page, w, h, w, 1, skew);
        var soft = Soft(turned, w, h, 7, 200, ref rng);
        var bgr = new byte[w * h * 3];
        for (var i = 0; i < soft.Length; i++)
        {
            var v = soft[i] / 255.0;
            bgr[i * 3] = (byte)(148 + v * (205 - 148));
            bgr[i * 3 + 1] = (byte)(150 + v * (225 - 150));
            bgr[i * 3 + 2] = (byte)(158 + v * (235 - 158));
        }
        return bgr;
    }

    /// <summary>A 3 × 3 blur as a scanner's optics do, Gaussian noise, dark specks.</summary>
    private static byte[] Soft(byte[] px, int w, int h, double noise, int specks, ref Rng rng)
    {
        var soft = new byte[px.Length];
        Parallel.For(0, h, y =>
        {
            for (var x = 0; x < w; x++)
            {
                int sum = 0, weight = 0;
                for (var dy = -1; dy <= 1; dy++)
                    for (var dx = -1; dx <= 1; dx++)
                    {
                        var (nx, ny) = (x + dx, y + dy);
                        if (nx < 0 || ny < 0 || nx >= w || ny >= h) continue;
                        var k = dx == 0 && dy == 0 ? 4 : dx == 0 || dy == 0 ? 2 : 1;
                        sum += px[ny * w + nx] * k;
                        weight += k;
                    }
                soft[y * w + x] = (byte)(sum / weight);
            }
        });
        for (var i = 0; i < soft.Length; i++)
        {
            var u = Math.Max(1e-12, rng.NextDouble());
            soft[i] = (byte)Math.Clamp(soft[i] + Math.Sqrt(-2 * Math.Log(u)) * Math.Cos(2 * Math.PI * rng.NextDouble()) * noise, 0, 255);
        }
        for (var i = 0; i < specks; i++)
        {
            var (cx, cy, r) = (rng.Next(w), rng.Next(h), 1 + rng.Next(3));
            for (var y = Math.Max(0, cy - r); y < Math.Min(h, cy + r); y++)
                for (var x = Math.Max(0, cx - r); x < Math.Min(w, cx + r); x++)
                    soft[y * w + x] = (byte)Math.Min(soft[y * w + x], 30 + rng.Next(70));
        }
        return soft;
    }

    private static ulong Seed(string name) => BitConverter.ToUInt64(System.Security.Cryptography.SHA256.HashData(Encoding.ASCII.GetBytes("inkvolt-cleanup-" + name)), 0);

    // ---- Cyrillic and Japanese pages: typeset with this PC's fonts through Fill & Sign's text (MuPDF's built-in fonts have neither) ----

    private static readonly string[] Russian =
    [
        "и", "в", "на", "с", "по", "для", "река", "окно", "город", "письмо", "дорога", "работа", "неделя", "счёт", "отчёт", "договор", "компания", "вопрос", "ответ",
        "история", "мост", "сад", "рынок", "часы", "зима", "весна", "лето", "осень", "утро", "вечер", "читает", "пишет", "строит", "ждёт", "идёт", "новый", "старый",
        "большой", "тихий", "ранний", "простой", "важный", "сегодня", "всегда", "почти", "обычно", "медленно", "платёж", "служба", "записка", "станция", "деревня",
    ];

    private static readonly string[] Japanese =
    [
        "東京", "大阪", "京都", "会社", "報告", "請求書", "支払い", "予定", "市場", "駅", "川", "窓", "手紙", "庭", "橋", "週間", "時間", "今日", "明日", "朝", "夜", "仕事",
        "質問", "回答", "新しい", "古い", "静か", "早い", "読む", "書く", "待つ", "歩く", "カタカナ", "ひらがな", "コーヒー", "ノート", "プリンタ", "スキャン",
    ];

    private static (byte[] Pixels, int Width, int Height, List<string> Words) NonLatinPage(CleanupFile file, int page)
    {
        var rng = new Rng(Seed(file.Name) + 31UL * (ulong)(page + 1));
        var bank = file.Language == "ru" ? Russian : Japanese;
        var data = BlankPage();
        var words = new List<string>();
        const double size = 13, leading = size * 1.7;
        for (var line = 0; line < 30; line++)
        {
            var parts = new List<string>();
            for (var length = 0; length < (file.Language == "ru" ? 58 : 30);)
            {
                var word = bank[rng.Next(bank.Length)];
                parts.Add(word);
                length += word.Length + 1;
            }
            // Japanese is read without spaces between words: one run, one "word" for the rate, the way it would be searched.
            var text = string.Join(file.Language == "ru" ? ' ' : '\0', parts).Replace("\0", "", StringComparison.Ordinal);
            words.AddRange(file.Language == "ru" ? parts : [text]);
            data = TextStamps.Put(data, null, 0, new RectD(60, 70 + line * leading, 492, leading), StampKind.Text, text, size);
        }
        using var engine = PdfEngine.Open(data, InputFileTypes.PDF, null);
        var image = engine.Render(0, Dpi / 72.0);
        var gray = new byte[image.Width * image.Height];
        for (int i = 0, j = 0; i < gray.Length; i++, j += 3) gray[i] = (byte)((image.Pixels[j] * 29 + image.Pixels[j + 1] * 150 + image.Pixels[j + 2] * 77) >> 8);
        return (gray, image.Width, image.Height, words);
    }

    private static byte[] BlankPage()
    {
        using var ms = new MemoryStream();
        var w = new PdfFileWriter(ms);
        var parent = w.Reserve();
        var content = w.AddStream("", " "u8.ToArray());
        var kid = w.Add($"<< /Type /Page /Parent {parent} 0 R /MediaBox [0 0 612 792] /Resources << >> /Contents {content} 0 R >>");
        w.Put(parent, $"<< /Type /Pages /Kids [{kid} 0 R] /Count 1 >>");
        var catalog = w.Add($"<< /Type /Catalog /Pages {parent} 0 R >>");
        var info = w.Add("<< /Producer (Inkvolt Print cleanup corpus) >>");
        w.Finish(catalog, info, new string('0', 32));
        return ms.ToArray();
    }

    // ---- The two readings ----

    /// <summary>What the Scan tab reads today: straightened (it looks at a 100 dpi copy), nothing else.</summary>
    public static (byte[] Pixels, int Width, int Height) Today(byte[] pixels, int w, int h, int channels)
    {
        var gray = channels == 1 ? pixels : ScanCleanup.ToGray(pixels, w, h);
        var angle = Deskew.Angle(ScanCleanup.Downscale(new GrayImage(w, h, gray), Dpi / 100));
        return (angle == 0 ? pixels : PageRotate.Rotate(pixels, w, h, w * channels, channels, -angle), w, h);
    }

    /// <summary>The same with the file's filters: cropped to the paper, then cleaned.</summary>
    public static (byte[] Pixels, int Width, int Height) Cleaned(byte[] pixels, int w, int h, int channels, PageFilters filters)
    {
        var gray = channels == 1 ? pixels : ScanCleanup.ToGray(pixels, w, h);
        var small = ScanCleanup.Downscale(new GrayImage(w, h, gray), Dpi / 100);
        var angle = Deskew.Angle(small);
        var (straight, width, height) = (angle == 0 ? pixels : PageRotate.Rotate(pixels, w, h, w * channels, channels, -angle), w, h);
        if (filters.HasFlag(PageFilters.CropToPaper) && PaperEdge.Find(small, Dpi / (double)(Dpi / 100), angle) is { } crop)
            (straight, width, height) = Cut(straight, w, h, channels, crop);
        return (PageCleanup.Apply(straight, width, height, channels, Dpi, filters).Pixels, width, height);
    }

    private static (byte[], int, int) Cut(byte[] px, int w, int h, int channels, CropBox crop)
    {
        var (x, y) = ((int)Math.Round(crop.X * w), (int)Math.Round(crop.Y * h));
        var (cw, ch) = (Math.Clamp((int)Math.Round(crop.Width * w), 1, w - x), Math.Clamp((int)Math.Round(crop.Height * h), 1, h - y));
        var cut = new byte[cw * ch * channels];
        for (var row = 0; row < ch; row++) Buffer.BlockCopy(px, (y + row) * w * channels + x * channels, cut, row * cw * channels, cw * channels);
        return (cut, cw, ch);
    }

    public static CleanupResult Measure(CleanupFile file, ITextRecognizer? recognizer)
    {
        var truth = new List<string>();
        if (recognizer is null)
        {
            for (var p = 0; p < file.Pages; p++) truth.AddRange(CleanPage(file, p).Words);
            return new CleanupResult(file.Name, file.Language, file.Damage, truth.Count, null, null, 0);
        }
        var (before, after) = (new List<string>(), new List<string>());
        var clock = new Stopwatch();
        for (var p = 0; p < file.Pages; p++)
        {
            var (px, w, h, channels, words) = ScanPage(file, p);
            truth.AddRange(words);
            var today = Today(px, w, h, channels);
            before.AddRange(recognizer.Recognize(today.Pixels, today.Width, today.Height, channels).Select(x => x.Text));
            clock.Start();
            var cleaned = Cleaned(px, w, h, channels, file.Filters);
            clock.Stop();
            after.AddRange(recognizer.Recognize(cleaned.Pixels, cleaned.Width, cleaned.Height, channels).Select(x => x.Text));
        }
        // Words run together in Japanese: compare it as characters, so a split the recognizer makes isn't an error.
        if (file.Language == "ja")
        {
            static List<string> Letters(IEnumerable<string> words) => [.. words.SelectMany(w => w.EnumerateRunes().Select(r => r.ToString()))];
            (truth, before, after) = (Letters(truth), Letters(before), Letters(after));
        }
        return new CleanupResult(file.Name, file.Language, file.Damage, truth.Count, WordErrorRate.Of(truth, before), WordErrorRate.Of(truth, after), clock.Elapsed.TotalMilliseconds / file.Pages);
    }

    public static string Report(IReadOnlyList<CleanupResult> results, IEnumerable<string> installed)
    {
        var sb = new StringBuilder();
        sb.AppendLine("# OCR corpus: Inkvolt Print's scan cleanup");
        sb.AppendLine();
        sb.AppendLine(CultureInfo.InvariantCulture, $"Made by `dotnet run --project pdf/tools/ocr-corpus -c Release -- cleanup` on {DateTime.Now:yyyy-MM-dd}, Windows {Environment.OSVersion.Version}, {System.Runtime.InteropServices.RuntimeInformation.OSArchitecture}. See [README.md](README.md).");
        sb.AppendLine();
        sb.AppendLine(CultureInfo.InvariantCulture, $"OCR languages installed on this PC: {string.Join(", ", installed)}.");
        sb.AppendLine();
        sb.AppendLine("| File | Words | Damage | Today (straightened) | Cleaned | Filters' ms a page |");
        sb.AppendLine("|---|---:|---|---:|---:|---:|");
        foreach (var r in results)
            sb.AppendLine(r.Today is { } t && r.After is { } a
                ? string.Create(CultureInfo.InvariantCulture, $"| `{r.Name}` | {r.Words} | {r.Damage} | {t:P1} | **{a:P1}** | {r.AfterMs:0} |")
                : $"| `{r.Name}` | {r.Words} | {r.Damage} | not run | not run: {Tag(r.Language)} isn't installed | |");
        var measured = results.Where(r => r.Today is not null).ToList();
        sb.AppendLine();
        sb.AppendLine(CultureInfo.InvariantCulture, $"Lower than today's on every file measured: **{(measured.All(r => r.After < r.Today) ? "yes" : "no")}** ({measured.Count} of {results.Count} files measured).");
        return sb.ToString();
    }
}
