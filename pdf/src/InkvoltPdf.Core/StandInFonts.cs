using System.Runtime.CompilerServices;

namespace InkvoltPdf.Core;

/// <summary>An installed font that draws characters a page font lacks: the font and its name for the user ("Arial Bold").</summary>
internal sealed record StandInFont(TrueTypeFont Font, string Name);

/// <summary>
/// Picks the installed font closest to a page font, for characters its embedded subset lacks (paragraph editing,
/// roadmap 2.1): the same family when it is installed (the PDF's name, "Helvetica" as Arial, "Times" as Times New
/// Roman), else the nearest of the common Windows families by class (serif, sans, monospaced), then weight and slant,
/// then x-height and the widths of the characters both fonts have. Characters none of them has come from the script
/// fallbacks <see cref="SystemFonts"/> knows; past those, nothing (the character is refused).
/// </summary>
internal static class StandInFonts
{
    internal enum Kind { Sans, Serif, Mono }

    private sealed record Family(string Name, Kind Kind, string Regular, string? Bold, string? Italic, string? BoldItalic, string[] Aliases);

    private static readonly Family[] Families =
    [
        new("Arial", Kind.Sans, "arial.ttf", "arialbd.ttf", "ariali.ttf", "arialbi.ttf",
            ["Arial", "Helvetica", "Helv", "Arimo", "Liberation Sans", "Nimbus Sans", "Nimbus Sans L"]),
        new("Segoe UI", Kind.Sans, "segoeui.ttf", "segoeuib.ttf", "segoeuii.ttf", "segoeuiz.ttf", ["Segoe UI"]),
        new("Calibri", Kind.Sans, "calibri.ttf", "calibrib.ttf", "calibrii.ttf", "calibriz.ttf", ["Calibri", "Carlito"]),
        new("Verdana", Kind.Sans, "verdana.ttf", "verdanab.ttf", "verdanai.ttf", "verdanaz.ttf", ["Verdana", "DejaVu Sans"]),
        new("Tahoma", Kind.Sans, "tahoma.ttf", "tahomabd.ttf", null, null, ["Tahoma"]),
        new("Trebuchet MS", Kind.Sans, "trebuc.ttf", "trebucbd.ttf", "trebucit.ttf", "trebucbi.ttf", ["Trebuchet MS", "Trebuchet"]),
        new("Times New Roman", Kind.Serif, "times.ttf", "timesbd.ttf", "timesi.ttf", "timesbi.ttf",
            ["Times New Roman", "Times", "Tinos", "Liberation Serif", "Nimbus Roman", "Nimbus Roman No9 L"]),
        new("Georgia", Kind.Serif, "georgia.ttf", "georgiab.ttf", "georgiai.ttf", "georgiaz.ttf", ["Georgia"]),
        new("Cambria", Kind.Serif, "cambria.ttc", "cambriab.ttf", "cambriai.ttf", "cambriaz.ttf", ["Cambria", "Caladea"]),
        new("Palatino Linotype", Kind.Serif, "pala.ttf", "palab.ttf", "palai.ttf", "palabi.ttf",
            ["Palatino Linotype", "Palatino", "Book Antiqua", "URW Palladio L"]),
        new("Constantia", Kind.Serif, "constan.ttf", "constanb.ttf", "constani.ttf", "constanz.ttf", ["Constantia"]),
        new("Courier New", Kind.Mono, "cour.ttf", "courbd.ttf", "couri.ttf", "courbi.ttf",
            ["Courier New", "Courier", "Cousine", "Liberation Mono", "Nimbus Mono", "Nimbus Mono L"]),
        new("Consolas", Kind.Mono, "consola.ttf", "consolab.ttf", "consolai.ttf", "consolaz.ttf", ["Consolas", "Inconsolata"]),
        new("Lucida Console", Kind.Mono, "lucon.ttf", null, null, null, ["Lucida Console"]),
    ];

    private static readonly string[] SerifWords =
        ["Times", "Serif", "Roman", "Georgia", "Garamond", "Cambria", "Palatino", "Book", "Minion", "Caslon", "Baskerville", "Bodoni",
         "Century", "Cheltenham", "Constantia", "Didot", "Goudy", "Janson", "Sabon", "Utopia", "Charter", "Bookman", "Schoolbook", "Antiqua",
         "Cochin", "Perpetua", "Rockwell", "Clarendon", "Merriweather", "Lora", "Tiempos", "Source Serif", "Noto Serif", "Libertine", "CMR", "LMRoman"];

    private static readonly string[] MonoWords = ["Mono", "Courier", "Consol", "Code", "Typewriter", "Fixed", "Lucida Console", "Menlo", "Monaco", "CMTT", "LMMono"];

    private static readonly string[] SansWords = ["Sans", "Arial", "Helvetica", "Gothic", "Grotesk", "Verdana", "Tahoma", "Calibri", "Segoe", "Futura", "Frutiger", "Myriad", "Univers", "Gill"];

    /// <summary>Lowercase and capitals most text has: what the widths are compared on.</summary>
    private const string Sample = "etaoinshrdlucmfwypvbgkxqjzETAOINSHRDLUCM0123456789";

    private static readonly ConditionalWeakTable<TextFont, Dictionary<(bool, bool), List<StandInFont>>> Ranked = new();

    /// <summary>What a page font is like: its class, weight and slant (from its name and descriptor flags).</summary>
    internal static (Kind Kind, bool Bold, bool Italic) Describe(TextFont font)
    {
        var family = FontNames.Family(font.Name);
        bool Has(string[] words) => words.Any(w => font.Name.Contains(w, StringComparison.OrdinalIgnoreCase) || family.Contains(w, StringComparison.OrdinalIgnoreCase));
        Kind kind;
        if ((font.Flags & 1) != 0 || Has(MonoWords)) kind = Kind.Mono;
        else if (Has(SansWords)) kind = Kind.Sans;
        else if ((font.Flags & 2) != 0 || Has(SerifWords)) kind = Kind.Serif;
        else kind = Kind.Sans;
        return (kind, font.Bold, font.Italic);
    }

    /// <summary>Installed fonts in the order they come closest to <paramref name="font"/> (its own family first when installed).</summary>
    internal static IReadOnlyList<StandInFont> RankFor(TextFont font) => RankFor(font, font.Bold, font.Italic);

    /// <summary>The same, for text of <paramref name="font"/> made bold or italic (or not).</summary>
    internal static IReadOnlyList<StandInFont> RankFor(TextFont font, bool bold, bool italic)
    {
        var byStyle = Ranked.GetValue(font, _ => []);
        lock (byStyle)
        {
            if (!byStyle.TryGetValue((bold, italic), out var list)) byStyle[(bold, italic)] = list = Rank(font, bold, italic);
            return list;
        }
    }

    /// <summary>
    /// The installed families a look can name, by name ("Arial", "Georgia", "Comic Sans MS"): the common ones above
    /// that are on this PC and every other TrueType family Windows lists (<see cref="InstalledFamilies"/>), sorted.
    /// </summary>
    public static IReadOnlyList<string> Installed() =>
        [.. Families.Where(f => SystemFonts.Get(f.Regular) is not null).Select(f => f.Name).Concat(InstalledFamilies.Value.Keys)
            .Distinct(StringComparer.OrdinalIgnoreCase).Order(StringComparer.OrdinalIgnoreCase)];

    /// <summary>An installed family beyond the common ones: the file of each face Windows lists for it.</summary>
    private sealed record Listed(string Name, string? Regular, string? Bold, string? Italic, string? BoldItalic);

    /// <summary>
    /// The TrueType families (.ttf, .ttc) Windows lists for the machine and the user, by name, read once: each entry
    /// ("Arial Narrow Bold (TrueType)") gives a family and a face; a collection entry ("Cambria &amp; Cambria Math") gives
    /// its first font, the one the file loads as. Other platforms: none.
    /// </summary>
    private static readonly Lazy<Dictionary<string, Listed>> InstalledFamilies = new(ReadInstalled);

    private static Dictionary<string, Listed> ReadInstalled()
    {
        var families = new Dictionary<string, Listed>(StringComparer.OrdinalIgnoreCase);
        if (!OperatingSystem.IsWindows()) return families;
        foreach (var hive in new[] { Microsoft.Win32.Registry.LocalMachine, Microsoft.Win32.Registry.CurrentUser })
        {
            try
            {
                using var key = hive.OpenSubKey(@"SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts");
                if (key is null) continue;
                foreach (var entry in key.GetValueNames())
                {
                    if (key.GetValue(entry) is not string file || Path.GetExtension(file) is not (".ttf" or ".TTF" or ".ttc" or ".TTC")) continue;
                    var name = entry;
                    var paren = name.IndexOf(" (", StringComparison.Ordinal);
                    if (paren > 0) name = name[..paren];
                    var amp = name.IndexOf(" & ", StringComparison.Ordinal);
                    if (amp > 0) name = name[..amp];
                    name = name.Trim();
                    if (name.Length == 0) continue;
                    var (family, style) = StyleOf(name);
                    var f = families.GetValueOrDefault(family) ?? new Listed(family, null, null, null, null);
                    families[family] = style switch
                    {
                        (true, true) => f with { BoldItalic = f.BoldItalic ?? file },
                        (true, false) => f with { Bold = f.Bold ?? file },
                        (false, true) => f with { Italic = f.Italic ?? file },
                        _ => f with { Regular = f.Regular ?? file },
                    };
                }
            }
            catch (Exception ex) when (ex is System.Security.SecurityException or IOException or UnauthorizedAccessException or PlatformNotSupportedException)
            {
                // No font list to read: the common families still stand.
            }
        }
        foreach (var (name, f) in families.ToList())
            if (f.Regular is null) families[name] = f with { Regular = f.Bold ?? f.Italic ?? f.BoldItalic };
        return families;
    }

    /// <summary>A face name's family and style: "Arial Narrow Bold Italic" → ("Arial Narrow", bold, italic); weights by name ("Segoe UI Light") stay families.</summary>
    private static (string Family, (bool Bold, bool Italic) Style) StyleOf(string name)
    {
        bool bold = false, italic = false;
        while (true)
        {
            if (Strip(" Bold Italic")) bold = italic = true;
            else if (Strip(" Bold")) bold = true;
            else if (Strip(" Italic") || Strip(" Oblique")) italic = true;
            else if (!Strip(" Regular")) break;
        }
        return (name, (bold, italic));

        bool Strip(string suffix)
        {
            if (!name.EndsWith(suffix, StringComparison.OrdinalIgnoreCase) || name.Length <= suffix.Length) return false;
            name = name[..^suffix.Length].TrimEnd();
            return true;
        }
    }

    /// <summary>A listed family's face closest to the style asked (its regular one when it has no bold or italic); null when its file can't be loaded.</summary>
    private static StandInFont? Face(Listed f, bool bold, bool italic)
    {
        var file = (bold, italic) switch
        {
            (true, true) when f.BoldItalic is not null => f.BoldItalic,
            (true, _) when f.Bold is not null => f.Bold,
            (_, true) when f.Italic is not null => f.Italic,
            _ => f.Regular,
        };
        if (file is null) return null;
        var tt = SystemFonts.Get(file);
        if (tt is null && file != f.Regular && f.Regular is not null) (file, tt) = (f.Regular, SystemFonts.Get(f.Regular));
        if (tt is null) return null;
        var name = f.Name + (file == f.BoldItalic ? " Bold Italic" : file == f.Bold ? " Bold" : file == f.Italic ? " Italic" : "");
        return new StandInFont(tt, name);
    }

    /// <summary>
    /// The installed font for text of <paramref name="font"/> given a look: <paramref name="family"/> when it is one of
    /// the families here or one Windows lists, and installed (its bold or italic face when it has one), else the
    /// closest to the paragraph's font in that style.
    /// </summary>
    internal static StandInFont Styled(TextFont font, string? family, bool bold, bool italic)
    {
        if (family is not null && Families.FirstOrDefault(f => f.Name.Equals(family, StringComparison.OrdinalIgnoreCase) || f.Aliases.Contains(family, StringComparer.OrdinalIgnoreCase)) is { } f
            && Face(f, bold, italic) is { } face)
            return face;
        if (family is not null && InstalledFamilies.Value.TryGetValue(family, out var listed) && Face(listed, bold, italic) is { } other)
            return other;
        return RankFor(font, bold, italic).FirstOrDefault() ?? throw new ContentEditException("No font on this PC can draw this text.");
    }

    /// <summary>A family's face closest to the style asked (its regular one when it has no bold or italic); null when not installed.</summary>
    private static StandInFont? Face(Family f, bool bold, bool italic)
    {
        var file = (bold, italic) switch
        {
            (true, true) when f.BoldItalic is not null => f.BoldItalic,
            (true, _) when f.Bold is not null => f.Bold,
            (_, true) when f.Italic is not null => f.Italic,
            _ => f.Regular,
        };
        if (SystemFonts.Get(file) is not { } tt) return null;
        var name = f.Name + (file == f.BoldItalic ? " Bold Italic" : file == f.Bold ? " Bold" : file == f.Italic ? " Italic" : "");
        return new StandInFont(tt, name);
    }

    private static List<StandInFont> Rank(TextFont font, bool bold, bool italic)
    {
        var (kind, _, _) = Describe(font);
        var family = FontNames.Family(font.Name);
        // The widths the page font gives the sample characters it has (ems).
        var widths = new List<(int Cp, double W)>();
        foreach (var ch in Sample)
        {
            var enc = font.Encode(ch.ToString());
            if (enc.Missing.Count == 0 && enc.Codes is [var code and >= 0] && font.HasGlyph(code) && font.WidthOf(code) is var w and > 0) widths.Add((ch, w / 1000));
        }
        var scored = new List<(double Score, StandInFont Font)>();
        foreach (var f in Families)
        {
            var (file, styleMiss) = (bold, italic) switch
            {
                (true, true) when f.BoldItalic is not null => (f.BoldItalic, 0),
                (true, _) when f.Bold is not null => (f.Bold, italic ? 1 : 0),
                (_, true) when f.Italic is not null => (f.Italic, bold ? 1 : 0),
                _ => (f.Regular, (bold ? 1 : 0) + (italic ? 1 : 0)),
            };
            if (SystemFonts.Get(file) is not { } tt) continue;
            var name = f.Name + (file == f.BoldItalic ? " Bold Italic" : file == f.Bold ? " Bold" : file == f.Italic ? " Italic" : "");
            double score;
            if (f.Aliases.Contains(family, StringComparer.OrdinalIgnoreCase)) score = -1000 + 10 * styleMiss; // its own family
            else
            {
                score = (f.Kind == kind ? 0 : kind == Kind.Mono || f.Kind == Kind.Mono ? 200 : 100) + 30 * styleMiss;
                if (widths.Count >= 3)
                    score += 100 * widths.Average(x => tt.Has(x.Cp) && tt.Advance(x.Cp) > 0 ? Math.Abs(Math.Log(x.W / tt.Advance(x.Cp))) : 0.5);
                if (font.XHeight is { } xh && tt.XHeight is { } th) score += 100 * Math.Abs(Math.Log(xh / th));
            }
            scored.Add((score, new StandInFont(tt, name)));
        }
        return [.. scored.OrderBy(s => s.Score).Select(s => s.Font)];
    }

    /// <summary>
    /// The closest installed font that has every one of <paramref name="codePoints"/>; else, for each, the closest that
    /// has it or a script fallback. Characters no font here has are left out of the map.
    /// </summary>
    internal static Dictionary<int, StandInFont> For(TextFont font, IReadOnlyCollection<int> codePoints)
    {
        var map = new Dictionary<int, StandInFont>();
        if (codePoints.Count == 0) return map;
        var ranked = RankFor(font);
        if (ranked.FirstOrDefault(f => codePoints.All(f.Font.Has)) is { } all)
        {
            foreach (var cp in codePoints) map[cp] = all;
            return map;
        }
        foreach (var cp in codePoints)
        {
            if (ranked.FirstOrDefault(f => f.Font.Has(cp)) is { } one) map[cp] = one;
            else if (SystemFonts.For(cp, null) is { } fb && fb.Has(cp)) map[cp] = new StandInFont(fb, Pretty(fb.Family));
        }
        return map;
    }

    /// <summary>A script fallback's file name as a font name ("seguisym" → "Segoe UI Symbol").</summary>
    private static string Pretty(string file) => file.ToLowerInvariant() switch
    {
        "seguisym" => "Segoe UI Symbol",
        "seguiemj" => "Segoe UI Emoji",
        "seguihis" => "Segoe UI Historic",
        "segoeui" => "Segoe UI",
        "nirmala" => "Nirmala UI",
        "leelawui" => "Leelawadee UI",
        "malgun" => "Malgun Gothic",
        "msyh" => "Microsoft YaHei",
        "msjh" => "Microsoft JhengHei",
        "yugothr" => "Yu Gothic",
        "msgothic" => "MS Gothic",
        "simsun" => "SimSun",
        "simsunextg" => "SimSun-ExtG",
        "mmrtext" => "Myanmar Text",
        "javatext" => "Javanese Text",
        "monbaiti" => "Mongolian Baiti",
        "himalaya" => "Microsoft Himalaya",
        "ebrima" => "Ebrima",
        "gadugi" => "Gadugi",
        "sylfaen" => "Sylfaen",
        "tahoma" => "Tahoma",
        "arial" => "Arial",
        _ => file,
    };
}
