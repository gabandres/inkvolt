using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using InkvoltPdf.Bench;
using InkvoltPdf.Core;
using InkvoltPrint.Core.Imaging;
using MuPDFCore;

namespace InkvoltPdf.OcrCorpus;

/// <summary>
/// One file of the OCR corpus: its language, how its pages were "scanned" (skew range in degrees, both signs; paper
/// noise as a standard deviation in grey levels; dark specks per page; how much darker one side of the page is), and
/// how each page lies on the glass (quarter turns clockwise; none for most files).
/// </summary>
public sealed record CorpusFile(string Name, string Language, string Font, double FontSize, double MinSkew, double MaxSkew,
    double Noise, int Specks, int Shading, int[]? Turns = null, int Pages = 2)
{
    public string Describe() =>
        $"{(Language == "es" ? "Spanish" : "English")}, {(Font == "/Helvetica" ? "Helvetica" : "Times")} {FontSize:0} pt, skew {MinSkew:0.#}-{MaxSkew:0.#}°, " +
        $"noise σ {Noise:0}, {Specks} specks a page{(Shading > 0 ? $", paper {Shading} levels darker on one side" : "")}" +
        (Turns is { } t && t.Any(q => q != 0) ? $", pages turned {string.Join(" and ", t.Select(q => $"{q * 90}°"))}" : "");
}

/// <summary>A generated page: its words in reading order (the ground truth) and how it was put on the glass.</summary>
public sealed record CorpusPage(IReadOnlyList<string> Words, double Skew, int Turns);

/// <summary>
/// The scan corpus for roadmap 2.2 (Better OCR): made-up prose in English and Spanish, typeset in a standard font,
/// rendered at 300 dpi by MuPDF (its built-in fonts, so the same pixels on every PC), then "scanned": turned on the glass,
/// skewed 3-10°, softened, put on uneven paper, given noise and specks, and saved as a JPEG in a PDF. Nothing is
/// copyrighted or personal and nothing is committed: the same code gives the same bytes (a seeded <see cref="Rng"/>, no
/// dates), so a file's SHA-256 says which corpus a number came from.
/// </summary>
public static class ScanCorpus
{
    public const int Dpi = 300;

    public static readonly IReadOnlyList<CorpusFile> Files =
    [
        new("en-skew3-light", "en", "/Times-Roman", 11, 3, 4, Noise: 8, Specks: 150, Shading: 10),
        new("en-skew6-noisy", "en", "/Helvetica", 10, 5, 7, Noise: 26, Specks: 1500, Shading: 0),
        new("en-skew10-shaded", "en", "/Times-Roman", 10, 8.5, 10, Noise: 14, Specks: 400, Shading: 60),
        new("es-skew4-noisy", "es", "/Helvetica", 11, 3.5, 5, Noise: 24, Specks: 1200, Shading: 0),
        new("es-skew8-shaded", "es", "/Times-Roman", 11, 7, 9, Noise: 14, Specks: 400, Shading: 50),
        new("en-turned", "en", "/Times-Roman", 11, 3, 5, Noise: 12, Specks: 300, Shading: 20, Turns: [2, 1]),
    ];

    /// <summary>The scanned PDF and each page's ground truth.</summary>
    public static (byte[] Pdf, List<CorpusPage> Pages) Make(CorpusFile file)
    {
        var (text, lines) = TextPdf(file);
        using var engine = PdfEngine.Open(text, InputFileTypes.PDF, null);
        var pages = new List<CorpusPage>();
        var jpegs = new List<(byte[] Jpeg, int Width, int Height)>();
        for (var p = 0; p < file.Pages; p++)
        {
            var (pixels, width, height, truth) = ScanPage(file, engine, lines, p);
            jpegs.Add((JpegEncoder.EncodeGray(pixels, width, height, 70, Dpi), width, height));
            pages.Add(truth);
        }
        return (ScanPdf(file, jpegs), pages);
    }

    /// <summary>One page as scanned (grey, before the JPEG), and its truth.</summary>
    public static (byte[] Pixels, int Width, int Height, CorpusPage Truth) MakePage(CorpusFile file, int page)
    {
        var (text, lines) = TextPdf(file);
        using var engine = PdfEngine.Open(text, InputFileTypes.PDF, null);
        return ScanPage(file, engine, lines, page);
    }

    /// <summary>One page as typeset, grey at 300 dpi, before any damage, and its words.</summary>
    public static (byte[] Pixels, int Width, int Height, List<string> Words) CleanPage(CorpusFile file, int page)
    {
        var (text, lines) = TextPdf(file);
        using var engine = PdfEngine.Open(text, InputFileTypes.PDF, null);
        var gray = Gray(engine.Render(page, Dpi / 72.0));
        return (gray.Pixels, gray.Width, gray.Height, [.. lines[page].SelectMany(l => l.Split(' ', StringSplitOptions.RemoveEmptyEntries))]);
    }

    private static (byte[] Pixels, int Width, int Height, CorpusPage Truth) ScanPage(CorpusFile file, PdfEngine engine, List<List<string>> lines, int p)
    {
        var rng = new Rng(Seed(file.Name) + 977UL * (ulong)(p + 1));
        var turns = file.Turns is { } t && p < t.Length ? t[p] : 0;
        var skew = Math.Round((file.MinSkew + (file.MaxSkew - file.MinSkew) * rng.NextDouble()) * (p % 2 == 0 ? 1 : -1), 2);
        var gray = Gray(engine.Render(p, Dpi / 72.0));
        var (pixels, width, height) = Scan(gray.Pixels, gray.Width, gray.Height, file, turns, skew, ref rng);
        return (pixels, width, height, new CorpusPage(lines[p].SelectMany(l => l.Split(' ', StringSplitOptions.RemoveEmptyEntries)).ToList(), skew, turns));
    }

    /// <summary>A page as the scanner would see it: <paramref name="turns"/> quarter turns clockwise, then skewed, softened, on uneven paper, noisy, specked.</summary>
    public static (byte[] Pixels, int Width, int Height) Scan(byte[] gray, int width, int height, CorpusFile file, int turns, double skew, ref Rng rng)
    {
        var (px, w, h) = (gray, width, height);
        for (var i = 0; i < ((turns % 4) + 4) % 4; i++) (px, w, h) = (TurnClockwise(px, w, h), h, w);
        px = PageRotate.Rotate(px, w, h, w, 1, skew);

        // Softened as a scanner's optics do: a 3 × 3 blur, the centre weighted.
        var soft = new byte[px.Length];
        for (var y = 0; y < h; y++)
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

        // Paper: off-white, darker towards one side (a lid's shadow, grey recycled paper), ink never quite black; then noise.
        var paper = 236 - rng.Next(8);
        var side = rng.Next(2);
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
            {
                var along = side == 0 ? (double)x / w : (double)y / h;
                var level = paper - file.Shading * along * along;
                var v = 22 + (level - 22) * soft[y * w + x] / 255.0 + Gaussian(ref rng) * file.Noise;
                soft[y * w + x] = (byte)Math.Clamp(Math.Round(v), 0, 255);
            }

        // Dust and toner specks: small dark dots, a few short hairs.
        for (var i = 0; i < file.Specks; i++)
        {
            var (cx, cy) = (rng.Next(w), rng.Next(h));
            var r = 0.8 + rng.NextDouble() * 1.8;
            var tone = 20 + rng.Next(90);
            var hair = rng.Next(20) == 0;
            var (dx, dy) = hair ? (Math.Cos(rng.NextDouble() * Math.PI), Math.Sin(rng.NextDouble() * Math.PI)) : (0.0, 0.0);
            var length = hair ? 8 + rng.Next(20) : 0;
            for (var s = 0; s <= length; s++)
            {
                var (sx, sy) = (cx + dx * s, cy + dy * s);
                for (var y = (int)(sy - r); y <= (int)(sy + r); y++)
                    for (var x = (int)(sx - r); x <= (int)(sx + r); x++)
                        if (x >= 0 && y >= 0 && x < w && y < h && (x - sx) * (x - sx) + (y - sy) * (y - sy) <= r * r)
                            soft[y * w + x] = (byte)Math.Min(soft[y * w + x], tone);
            }
        }
        return (soft, w, h);
    }

    public static byte[] TurnClockwise(byte[] px, int w, int h)
    {
        var turned = new byte[px.Length];
        for (var y = 0; y < h; y++)
            for (var x = 0; x < w; x++)
                turned[x * h + (h - 1 - y)] = px[y * w + x];
        return turned;
    }

    public static string Sha256(byte[] data) => Convert.ToHexStringLower(SHA256.HashData(data));

    private static ulong Seed(string name)
    {
        var h = SHA256.HashData(Encoding.ASCII.GetBytes("inkvolt-ocr-" + name));
        return BitConverter.ToUInt64(h, 0);
    }

    private static GrayImage Gray(RenderedImage img)
    {
        var g = new byte[img.Width * img.Height];
        for (int i = 0, j = 0; i < g.Length; i++, j += 3)
            g[i] = (byte)((img.Pixels[j] * 29 + img.Pixels[j + 1] * 150 + img.Pixels[j + 2] * 77) >> 8);
        return new GrayImage(img.Width, img.Height, g);
    }

    /// <summary>A normal distribution's sample (Box-Muller), mean 0, standard deviation 1.</summary>
    private static double Gaussian(ref Rng rng)
    {
        var u = Math.Max(1e-12, rng.NextDouble());
        return Math.Sqrt(-2 * Math.Log(u)) * Math.Cos(2 * Math.PI * rng.NextDouble());
    }

    // ---- the typeset text ----

    private const double Left = 72, Top = 720, TextWidth = 468;

    /// <summary>
    /// The clean text pages: a heading in Helvetica-Bold, then paragraphs in the file's font, wrapped by an estimated
    /// glyph width (on the wide side, so no line runs off the page); with each page's lines.
    /// </summary>
    private static (byte[] Pdf, List<List<string>> Lines) TextPdf(CorpusFile file)
    {
        var seed = Seed(file.Name);
        var lines = new List<List<string>>();
        using var ms = new MemoryStream();
        var w = new PdfFileWriter(ms);
        var parent = w.Reserve();
        var fonts = $"/F1 << /Type /Font /Subtype /Type1 /BaseFont {file.Font} /Encoding /WinAnsiEncoding >> " +
                    "/F2 << /Type /Font /Subtype /Type1 /BaseFont /Helvetica-Bold /Encoding /WinAnsiEncoding >>";
        var kids = new List<int>();
        var rng = new Rng(seed);
        var bank = file.Language == "es" ? Spanish : English;
        var leading = file.FontSize * 1.4;
        var maxChars = (int)(TextWidth / (file.FontSize * (file.Font == "/Helvetica" ? 0.56 : 0.50)));
        for (var p = 0; p < file.Pages; p++)
        {
            var pageLines = new List<string>();
            var ops = new StringBuilder();
            var title = Title(bank, ref rng);
            ops.Append(CultureInfo.InvariantCulture, $"BT /F2 16 Tf {Left} {Top} Td {Str(title)} Tj ET\n");
            pageLines.Add(title);
            var y = Top - 34;
            while (y > 90)
            {
                foreach (var line in Wrap(Paragraph(bank, ref rng), maxChars))
                {
                    if (y <= 90) break;
                    ops.Append(CultureInfo.InvariantCulture, $"BT /F1 {file.FontSize} Tf {Left} {y:0.##} Td {Str(line)} Tj ET\n");
                    pageLines.Add(line);
                    y -= leading;
                }
                y -= leading * 0.6;
            }
            lines.Add(pageLines);
            var content = w.AddStream("", Encoding.Latin1.GetBytes(ops.ToString()));
            kids.Add(w.Add($"<< /Type /Page /Parent {parent} 0 R /MediaBox [0 0 612 792] /Resources << /Font << {fonts} >> >> /Contents {content} 0 R >>"));
        }
        w.Put(parent, $"<< /Type /Pages /Kids [{string.Join(' ', kids.Select(k => $"{k} 0 R"))}] /Count {kids.Count} >>");
        var catalog = w.Add($"<< /Type /Catalog /Pages {parent} 0 R >>");
        var info = w.Add("<< /Producer (Inkvolt PDF OCR corpus) >>");
        w.Finish(catalog, info, new string('0', 32));
        return (ms.ToArray(), lines);
    }

    private static byte[] ScanPdf(CorpusFile file, List<(byte[] Jpeg, int Width, int Height)> pages)
    {
        using var ms = new MemoryStream();
        var w = new PdfFileWriter(ms);
        var parent = w.Reserve();
        var kids = new List<int>();
        foreach (var (jpeg, width, height) in pages)
        {
            var (pw, ph) = (width * 72.0 / Dpi, height * 72.0 / Dpi);
            var image = w.AddStream($"/Type /XObject /Subtype /Image /Width {width} /Height {height} /ColorSpace /DeviceGray /BitsPerComponent 8 /Filter /DCTDecode", jpeg, null);
            var content = w.AddStream("", Encoding.ASCII.GetBytes(string.Create(CultureInfo.InvariantCulture, $"q {pw:0.##} 0 0 {ph:0.##} 0 0 cm /Im0 Do Q")), null);
            kids.Add(w.Add(string.Create(CultureInfo.InvariantCulture,
                $"<< /Type /Page /Parent {parent} 0 R /MediaBox [0 0 {pw:0.##} {ph:0.##}] /Resources << /XObject << /Im0 {image} 0 R >> >> /Contents {content} 0 R >>")));
        }
        w.Put(parent, $"<< /Type /Pages /Kids [{string.Join(' ', kids.Select(k => $"{k} 0 R"))}] /Count {kids.Count} >>");
        var catalog = w.Add($"<< /Type /Catalog /Pages {parent} 0 R >>");
        var info = w.Add($"<< /Title {Str("OCR corpus: " + file.Name)} /Producer (Inkvolt PDF OCR corpus) >>");
        w.Finish(catalog, info, Convert.ToHexString(MD5.HashData(Encoding.ASCII.GetBytes("inkvolt-ocr-" + file.Name))));
        return ms.ToArray();
    }

    /// <summary>A PDF literal string in WinAnsi (Latin-1 covers every letter in the word banks).</summary>
    private static string Str(string s) => "(" + s.Replace("\\", "\\\\").Replace("(", "\\(").Replace(")", "\\)") + ")";

    private static string Title(string[] bank, ref Rng rng)
    {
        var parts = new List<string>();
        for (var i = 2 + rng.Next(3); i > 0; i--)
        {
            var word = bank[12 + rng.Next(bank.Length - 12)];
            parts.Add(char.ToUpperInvariant(word[0]) + word[1..]);
        }
        return string.Join(' ', parts);
    }

    private static string Paragraph(string[] bank, ref Rng rng)
    {
        var sb = new StringBuilder();
        for (var s = 3 + rng.Next(4); s > 0; s--)
        {
            if (sb.Length > 0) sb.Append(' ');
            var n = 6 + rng.Next(10);
            for (var i = 0; i < n; i++)
            {
                var word = rng.Next(14) == 0 ? Number(ref rng) : bank[rng.Next(bank.Length)];
                if (i == 0) word = char.ToUpperInvariant(word[0]) + word[1..];
                if (i > 0) sb.Append(i == n / 2 && rng.Next(3) == 0 ? ", " : " ");
                sb.Append(word);
            }
            sb.Append('.');
        }
        return sb.ToString();
    }

    /// <summary>A number as documents have them: a count, an amount, a reference, a year.</summary>
    private static string Number(ref Rng rng) => rng.Next(4) switch
    {
        0 => (2 + rng.Next(98)).ToString(CultureInfo.InvariantCulture),
        1 => $"{10 + rng.Next(990)}.{rng.Next(100):00}",
        2 => $"{1000 + rng.Next(9000)}",
        _ => (1990 + rng.Next(40)).ToString(CultureInfo.InvariantCulture),
    };

    private static IEnumerable<string> Wrap(string text, int maxChars)
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

    // The first 12 words of each bank are short function words, left out of headings.
    private static readonly string[] English =
    [
        "the", "a", "and", "of", "to", "in", "that", "with", "for", "on", "by", "from",
        "river", "lantern", "harbor", "window", "meadow", "ledger", "engine", "bridge", "garden", "letter", "market", "valley",
        "signal", "copper", "quarry", "orchard", "compass", "granite", "thunder", "candle", "willow", "saddle", "anchor",
        "barrel", "beacon", "canvas", "cellar", "chapel", "cotton", "falcon", "fossil", "furnace", "glacier", "hammer",
        "harvest", "island", "jacket", "kettle", "lumber", "marble", "mirror", "needle", "parcel", "pillar", "pocket",
        "ribbon", "shadow", "silver", "spring", "stable", "summit", "tunnel", "velvet", "wagon", "walnut", "winter",
        "walks", "turns", "carries", "builds", "finds", "holds", "keeps", "leaves", "meets", "opens", "reads", "sends",
        "stands", "takes", "waits", "writes", "measures", "returns", "follows", "answers", "gathers", "crosses", "remains",
        "quiet", "early", "narrow", "steady", "bright", "distant", "patient", "simple", "sudden", "little", "broad", "plain",
        "heavy", "gentle", "ancient", "careful", "common", "eager", "formal", "honest", "modest", "proper", "rough", "sharp",
        "slowly", "often", "again", "almost", "rather", "nearly", "still", "already", "perhaps", "later", "before", "after",
        "morning", "evening", "season", "village", "country", "station", "journey", "history", "minute", "moment", "number",
        "weather", "account", "balance", "chapter", "company", "council", "deposit", "freight", "invoice", "manager",
        "notice", "office", "payment", "project", "record", "report", "request", "schedule", "service", "summary", "ticket",
    ];

    private static readonly string[] Spanish =
    [
        "el", "la", "de", "que", "y", "en", "un", "una", "los", "las", "por", "con",
        "año", "niño", "señal", "mañana", "montaña", "pequeño", "español", "compañía", "diseño", "otoño", "sueño", "baño",
        "canción", "información", "corazón", "nación", "estación", "reunión", "camión", "razón", "lección", "atención",
        "después", "también", "además", "jamás", "quizás", "allá", "está", "están", "será", "habrá", "tendrá", "podrá",
        "página", "público", "número", "último", "rápido", "teléfono", "música", "método", "árbol", "lápiz", "fácil", "difícil",
        "ciudad", "puerta", "ventana", "camino", "río", "mesa", "libro", "carta", "cuenta", "factura", "oficina", "informe",
        "mercado", "puente", "jardín", "invierno", "verano", "tiempo", "semana", "pueblo", "campo", "viaje", "historia",
        "guarda", "lleva", "abre", "cierra", "envía", "recibe", "escribe", "lee", "cruza", "espera", "cuenta", "vuelve",
        "sigue", "encuentra", "construye", "mide", "reúne", "queda", "trae", "busca", "piensa", "pregunta", "responde",
        "tranquilo", "temprano", "estrecho", "brillante", "lejano", "paciente", "sencillo", "repentino", "antiguo",
        "cuidadoso", "común", "honesto", "modesto", "pesado", "suave", "amplio", "claro", "oscuro", "nuevo", "viejo",
        "despacio", "siempre", "nunca", "todavía", "casi", "pronto", "tarde", "antes", "entre", "hacia", "según", "sobre",
        "acción", "artículo", "crédito", "depósito", "envío", "garantía", "período", "propósito", "próximo", "régimen",
        "pingüino", "vergüenza", "cigüeña", "acuífero", "exhibición", "electrónico", "económico", "político", "técnico",
    ];
}
