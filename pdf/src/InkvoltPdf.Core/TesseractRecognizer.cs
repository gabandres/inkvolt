using System.Diagnostics;
using System.Globalization;
using System.Text;
using InkvoltPrint.Core.Imaging;

namespace InkvoltPdf.Core;

/// <summary>
/// A recognizer that says which recognizer reads again, alone, what its reading of a page left out
/// (<see cref="MissedLines"/>): none for one that leaves no line out the way Windows' does (Tesseract), so the page isn't
/// read dozens of times more. One without this is its own.
/// </summary>
public interface IRereadsMissed
{
    ITextRecognizer? Rereader { get; }
}

/// <summary>
/// Tesseract (Apache-2.0), the optional second engine for the languages Windows has no recognizer for (roadmap 2.2):
/// tesseract.exe, downloaded by the person into the app's data (<see cref="TesseractStore"/>), run as a separate program
/// for each image: the page goes in on stdin as a PGM, its words come back as TSV on stdout (<see cref="TesseractTsv"/>).
/// One run reads one or more languages at once ("hin+eng"). The program is treated as untrusted: a time limit, an output
/// limit, killed on Cancel (<see cref="BoundedProcess"/>), and its TSV parsed as hostile. Its words carry its confidence.
/// </summary>
public sealed class TesseractRecognizer : ITextRecognizer, IRereadsMissed
{
    private const long MaxPixels = 120_000_000;
    private const int MaxOutput = 32 << 20;

    private readonly string _exe;
    private readonly string _tessdata;
    private readonly IReadOnlyList<TesseractLanguage> _languages;
    private readonly TimeSpan _timeout;

    /// <param name="languages">What it reads, the first one first (its tag is <see cref="Language"/>).</param>
    /// <param name="name">How the person knows them ("Hindi + English").</param>
    /// <param name="timeout">For one image; null: two minutes, and one more per language past the first.</param>
    public TesseractRecognizer(string exe, string tessdata, IReadOnlyList<TesseractLanguage> languages, string name, TimeSpan? timeout = null)
    {
        if (languages.Count == 0) throw new ArgumentException("At least one language.", nameof(languages));
        (_exe, _tessdata, _languages, LanguageName) = (exe, tessdata, languages, name);
        _timeout = timeout ?? TimeSpan.FromMinutes(1 + languages.Count);
    }

    public string Language => _languages[0].Tag;

    public string LanguageName { get; }

    /// <summary>Its languages as Tesseract's -l takes them ("hin+eng").</summary>
    public string Codes => string.Join('+', _languages.Select(l => l.Code));

    public IReadOnlyList<TesseractLanguage> Languages => _languages;

    /// <summary>None: Tesseract doesn't leave out lines the way Windows' recognizer does.</summary>
    public ITextRecognizer? Rereader => null;

    /// <summary>The resolution Tesseract is told (PGM carries none): ScanText renders at 300 dpi.</summary>
    public int Dpi { get; init; } = (int)ScanText.Dpi;

    public IReadOnlyList<RecognizedWord> Recognize(byte[] pixels, int width, int height, int channels, CancellationToken cancel = default)
    {
        if (width <= 0 || height <= 0 || (long)width * height > MaxPixels || channels is not (1 or 3) || pixels.Length < (long)width * height * channels)
            throw new ArgumentException("Not a page image Tesseract is given.");
        var start = new ProcessStartInfo(_exe) { WorkingDirectory = Path.GetDirectoryName(_exe)! };
        foreach (var a in Arguments()) start.ArgumentList.Add(a);
        start.Environment["TESSDATA_PREFIX"] = _tessdata;
        start.Environment["OMP_THREAD_LIMIT"] = "1";
        try
        {
            var result = BoundedProcess.Run(start, Pgm(pixels, width, height, channels), MaxOutput, _timeout, cancel);
            if (result.ExitCode != 0)
            {
                var errors = result.Errors.Trim().ReplaceLineEndings(" ");
                throw new BoundedProcessException($"Tesseract ended with {result.ExitCode}: {errors[..Math.Min(300, errors.Length)]}");
            }
            return TesseractTsv.Parse(Encoding.UTF8.GetString(result.Output), width, height);
        }
        catch (Exception ex) when (ex is BoundedProcessException or InvalidDataException)
        {
            throw new TesseractException(ex is BoundedProcessException { TimedOut: true } ? PdfStrings.Tesseract_TooSlow : PdfStrings.Tesseract_Failed, ex);
        }
    }

    /// <summary>The command line: stdin to stdout, its languages from its data folder, TSV only.</summary>
    public IReadOnlyList<string> Arguments() =>
    [
        "stdin", "stdout", "--tessdata-dir", _tessdata, "-l", Codes, "--dpi", Dpi.ToString(CultureInfo.InvariantCulture), "--oem", "1", "--psm", "3",
        "-c", "tessedit_create_tsv=1", "-c", "tessedit_create_txt=0",
    ];

    /// <summary>The image as a binary PGM (grey; BGR made grey as Rec. 601 luma).</summary>
    public static byte[] Pgm(byte[] pixels, int width, int height, int channels)
    {
        var header = Encoding.ASCII.GetBytes($"P5\n{width} {height}\n255\n");
        var result = new byte[header.Length + (long)width * height];
        header.CopyTo(result, 0);
        var n = width * height;
        if (channels == 1) Buffer.BlockCopy(pixels, 0, result, header.Length, n);
        else
            for (int i = 0, src = 0, dst = header.Length; i < n; i++, src += 3, dst++)
                result[dst] = (byte)((pixels[src] * 29 + pixels[src + 1] * 150 + pixels[src + 2] * 77 + 128) >> 8);
        return result;
    }
}

/// <summary>Tesseract didn't read a page: <see cref="Exception.Message"/> says so in plain words, the inner exception what happened (for the log).</summary>
public sealed class TesseractException(string message, Exception inner) : Exception(message, inner);

/// <summary>
/// Tesseract's TSV (<c>-c tessedit_create_tsv=1</c>), read as hostile: its words (level 5) with their boxes, line and
/// confidence. A row that isn't twelve fields of the right kinds is left out; boxes are kept inside the image; text is
/// shortened and stripped of control characters; counts are bounded.
/// </summary>
public static class TesseractTsv
{
    public const int MaxWords = 200_000;
    public const int MaxWordLength = 200;
    private const int MaxLines = 50_000;

    /// <exception cref="InvalidDataException">It doesn't start with Tesseract's header row.</exception>
    public static List<RecognizedWord> Parse(string tsv, int width, int height)
    {
        var words = new List<RecognizedWord>();
        var lines = new Dictionary<(int, int, int, int), int>();
        var first = true;
        foreach (var raw in tsv.AsSpan().EnumerateLines())
        {
            if (first)
            {
                first = false;
                if (!raw.TrimStart('﻿').StartsWith("level\tpage_num\tblock_num\tpar_num\tline_num\tword_num\tleft\ttop\twidth\theight\tconf\ttext", StringComparison.Ordinal))
                    throw new InvalidDataException("Not Tesseract's TSV.");
                continue;
            }
            if (words.Count >= MaxWords) break;
            if (raw.Length == 0 || !raw.StartsWith("5\t", StringComparison.Ordinal)) continue;
            var f = raw.ToString().Split('\t');
            if (f.Length != 12) continue;
            if (!Int(f[1], out var page) || !Int(f[2], out var block) || !Int(f[3], out var par) || !Int(f[4], out var line)
                || !Int(f[6], out var left) || !Int(f[7], out var top) || !Int(f[8], out var w) || !Int(f[9], out var h)) continue;
            if (!double.TryParse(f[10], NumberStyles.Float, CultureInfo.InvariantCulture, out var conf) || !double.IsFinite(conf)) continue;
            var text = Clean(f[11]);
            if (text.Length == 0 || text.Length > MaxWordLength) continue;
            // Inside the image, at least a pixel wide and high.
            var (x0, y0) = (Math.Clamp(left, 0, width), Math.Clamp(top, 0, height));
            var (x1, y1) = (Math.Clamp((long)left + w, 0, width), Math.Clamp((long)top + h, 0, height));
            if (x1 - x0 < 1 || y1 - y0 < 1) continue;
            var key = (page, block, par, line);
            if (!lines.TryGetValue(key, out var index))
            {
                if (lines.Count >= MaxLines) continue;
                lines[key] = index = lines.Count;
            }
            words.Add(new RecognizedWord(text, x0, y0, x1 - x0, y1 - y0, index, Math.Clamp(conf, 0, 100)));
        }
        if (first) throw new InvalidDataException("Not Tesseract's TSV.");
        return words;
    }

    private static bool Int(string s, out int value) =>
        int.TryParse(s, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out value) && value is >= -1 and <= 1_000_000;

    private static string Clean(string text)
    {
        if (text.Length > MaxWordLength * 2) return "";
        var sb = new StringBuilder(text.Length);
        foreach (var c in text)
            if (!char.IsControl(c)) sb.Append(c);
        var clean = sb.ToString().Trim();
        try
        {
            return clean.Normalize(NormalizationForm.FormC);
        }
        catch (ArgumentException)
        {
            return clean; // not valid UTF-16 (a lone surrogate): left as it is, and a suspect word for its odd characters
        }
    }
}
