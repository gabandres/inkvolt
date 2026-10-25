namespace InkvoltPrint.Core.Imaging;

/// <summary>
/// The six Kodak patch codes. Each is four bars, two wide and two narrow, read in order across the bars (W wide, N narrow):
/// Patch 1 WWNN, Patch 2 WNNW, Patch 3 WNWN, Patch 4 (toggle) NWWN, Patch 6 NNWW, Patch T (transfer) NWNW. Kodak's software
/// uses 2, 3 and T to separate documents and batches; 1, 4 and 6 control the image and separate nothing.
/// </summary>
public enum PatchCode { Patch1, Patch2, Patch3, Patch4, Patch6, PatchT }

/// <summary>
/// Finds a patch code on a scanned page (a separator sheet). Geometry from Kodak's patch code information (A-61801, as
/// summarised by barcode font vendors and Wikipedia): wide bars 0.20 in, narrow bars and the three spaces 0.08 in, so a patch
/// is 0.80 in across; bars at least 2 in long; a clear zone of about ten narrow bars around it. Read along every row and every
/// column of the analysis copy, so the sheet may be fed either way round and a few degrees crooked; widths are judged against
/// the patch's own size (toner spread and photocopies change them), and the patch must keep reading the same over an inch of
/// its length, so text, rules, tables and barcodes don't pass for one. Read backwards (the sheet upside down) Patch T is
/// Patch 3 and Patch 1 is Patch 6; 2 and 4 read the same either way.
/// </summary>
public static class PatchCodes
{
    /// <summary>Narrow bar and space width.</summary>
    public const double Narrow = 0.08;

    /// <summary>Wide bar width.</summary>
    public const double Wide = 0.20;

    /// <summary>Across the four bars and three spaces.</summary>
    public const double Size = 2 * Wide + 2 * Narrow + 3 * Narrow;

    /// <summary>How much of a bar's length must read the same (half the spec's 2 in minimum, for sheets fed off the edge).</summary>
    public const double MinLength = 1.0;

    private const int InkContrast = 80;

    /// <summary>The narrow / wide pattern of each code, in reading order.</summary>
    internal static string Pattern(PatchCode code) => code switch
    {
        PatchCode.Patch1 => "WWNN",
        PatchCode.Patch2 => "WNNW",
        PatchCode.Patch3 => "WNWN",
        PatchCode.Patch4 => "NWWN",
        PatchCode.Patch6 => "NNWW",
        _ => "NWNW",
    };

    private static PatchCode? FromPattern(string pattern) =>
        Enum.GetValues<PatchCode>().Cast<PatchCode?>().FirstOrDefault(c => Pattern(c!.Value) == pattern);

    /// <summary>Patch 2, 3 and T separate documents (Kodak's use); 1, 4 and 6 don't.</summary>
    public static bool Separates(PatchCode code) => code is PatchCode.Patch2 or PatchCode.Patch3 or PatchCode.PatchT;

    public static string Name(PatchCode code) => code switch
    {
        PatchCode.Patch1 => "Patch 1",
        PatchCode.Patch2 => "Patch 2",
        PatchCode.Patch3 => "Patch 3",
        PatchCode.Patch4 => "Patch 4",
        PatchCode.Patch6 => "Patch 6",
        _ => "Patch T",
    };

    /// <summary>The patch on the page, or null. <paramref name="pixelsPerInch"/>: the resolution of <paramref name="img"/>.</summary>
    public static PatchCode? Find(GrayImage img, double pixelsPerInch)
    {
        if (pixelsPerInch < 30 || img.Width < 16 || img.Height < 16) return null; // a narrow bar under 2.4 px can't be told from a wide one
        var paper = GrayImage.Median(img, 0, 0, img.Width, img.Height);
        if (paper < 128) return null;
        var ink = paper - InkContrast;

        PatchCode? best = null;
        var bestLength = MinLength * pixelsPerInch;
        foreach (var rows in new[] { true, false })
        {
            var lines = rows ? img.Height : img.Width;
            var length = rows ? img.Width : img.Height;
            var runs = new List<int>(64);
            var chains = new List<Chain>();
            for (var line = 0; line < lines; line++)
            {
                Runs(img, rows, line, length, ink, runs);
                foreach (var (code, centre) in Matches(runs, pixelsPerInch))
                    Extend(chains, code, line, centre, pixelsPerInch);
            }
            foreach (var chain in chains)
                if (chain.Last - chain.First + 1 >= bestLength)
                    (best, bestLength) = (chain.Code, chain.Last - chain.First + 1);
        }
        return best;
    }

    /// <summary>A patch read on neighbouring lines at about the same place.</summary>
    private sealed class Chain(PatchCode code, int line, double centre)
    {
        public PatchCode Code { get; } = code;
        public int First { get; } = line;
        public int Last { get; set; } = line;
        public double Centre { get; set; } = centre;
    }

    private static void Extend(List<Chain> chains, PatchCode code, int line, double centre, double ppi)
    {
        var gap = Math.Max(2, 0.08 * ppi);     // a line or two may miss (specks, a JPEG block)
        var drift = Math.Max(2, 0.06 * ppi);   // crooked sheets move the patch along the line a little per line
        foreach (var chain in chains)
            if (chain.Code == code && line - chain.Last <= gap && Math.Abs(centre - chain.Centre) <= drift)
            {
                if (chain.Last == line) return;
                chain.Last = line;
                chain.Centre = centre;
                return;
            }
        chains.Add(new Chain(code, line, centre));
    }

    /// <summary>Run lengths along one row or column, starting with a light run (possibly 0 long), alternating.</summary>
    private static void Runs(GrayImage img, bool row, int line, int length, int ink, List<int> runs)
    {
        runs.Clear();
        var dark = false;
        var run = 0;
        for (var i = 0; i < length; i++)
        {
            var isDark = (row ? img[i, line] : img[line, i]) < ink;
            if (isDark == dark) { run++; continue; }
            runs.Add(run);
            dark = isDark;
            run = 1;
        }
        runs.Add(run);
    }

    /// <summary>Patches on one line: four dark runs and three light ones between clear zones, in the patch's proportions.</summary>
    private static IEnumerable<(PatchCode Code, double Centre)> Matches(List<int> runs, double ppi)
    {
        // Runs alternate light, dark, light… with light at even indexes: a patch starts at an odd index.
        var start = 0; // where run i begins
        for (var i = 1; i + 7 < runs.Count; i += 2)
        {
            start += runs[i - 1] + (i > 1 ? runs[i - 2] : 0); // past the previous dark run and this light one
            var total = 0;
            for (var k = 0; k < 7; k++) total += runs[i + k];
            if (total < 0.75 * Size * ppi || total > 1.3 * Size * ppi) continue;
            var unit = total / 10.0; // 2 × 2.5 + 2 × 1 + 3 × 1 narrow widths
            if (runs[i - 1] < 1.5 * unit || runs[i + 7] < 1.5 * unit) continue; // clear before and after
            var pattern = new char[4];
            var ok = true;
            for (var k = 0; k < 7 && ok; k++)
            {
                var r = runs[i + k] / unit;
                if (k % 2 == 1) ok = r is >= 0.45 and <= 1.75; // a space
                else if (r is >= 0.45 and <= 1.6) pattern[k / 2] = 'N';
                else if (r is >= 1.8 and <= 3.6) pattern[k / 2] = 'W';
                else ok = false;
            }
            if (!ok || FromPattern(new string(pattern)) is not { } code) continue;
            yield return (code, start + total / 2.0);
        }
    }
}
