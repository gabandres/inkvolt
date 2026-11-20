using System.Text;
using System.Text.RegularExpressions;

namespace InkvoltPdf.Core;

/// <summary>Turns PDF font names ("ABCDEF+Arial-BoldMT", "TimesNewRomanPSMT") into family names Word knows ("Arial", "Times New Roman").</summary>
public static partial class FontNames
{
    private static readonly Dictionary<string, string> Known = new(StringComparer.OrdinalIgnoreCase)
    {
        ["Helvetica"] = "Arial",
        ["Helv"] = "Arial",
        ["Arial MT"] = "Arial",
        ["Times"] = "Times New Roman",
        ["Times Roman"] = "Times New Roman",
        ["Tim"] = "Times New Roman",
        ["Courier"] = "Courier New",
        ["Cour"] = "Courier New",
        ["Zapf Dingbats"] = "Wingdings",
    };

    private static readonly string[] StyleWords =
        ["Bold", "Italic", "Oblique", "Regular", "Book", "Medium", "Light", "Semibold", "SemiBold", "Demi", "Black", "Heavy", "Condensed", "Narrow"];

    /// <summary>
    /// Whether a font's name says bold: "Bold", "Black", "Heavy", "Demi" in it; URW's "Medi" style ("NimbusRomNo9L-Medi",
    /// "-MediItal": the bold of its Times); TeX's bold Computer Modern ("CMBX10", "CMBXTI10", "CMMIB10").
    /// </summary>
    public static bool LooksBold(string name) =>
        name.Contains("Bold", StringComparison.OrdinalIgnoreCase) || name.Contains("Black", StringComparison.OrdinalIgnoreCase)
        || name.Contains("Heavy", StringComparison.OrdinalIgnoreCase) || name.Contains("Demi", StringComparison.OrdinalIgnoreCase)
        || UrwMedium().IsMatch(StyleOf(name)) || TexBold().IsMatch(Untagged(name));

    /// <summary>
    /// Whether a font's name says italic: "Italic", "Oblique" in it; a style ending in URW's "Ital" ("-ReguItal") or
    /// Adobe's "It" ("MinionPro-It", "-BoldIt"); TeX's italic, slanted and math italic Computer Modern ("CMTI10",
    /// "CMSL10", "CMMI10": the "d" of "d_model").
    /// </summary>
    public static bool LooksItalic(string name) =>
        name.Contains("Italic", StringComparison.OrdinalIgnoreCase) || name.Contains("Oblique", StringComparison.OrdinalIgnoreCase)
        || StyleItalic().IsMatch(StyleOf(name)) || TexItalic().IsMatch(Untagged(name));

    /// <summary>A font name without its subset tag ("ABCDEF+").</summary>
    private static string Untagged(string name) =>
        name.Length > 7 && name[6] == '+' && !name.AsSpan(0, 6).ContainsAnyExceptInRange('A', 'Z') ? name[7..] : name;

    /// <summary>The style part of a font name: after its last '-' or ',' ("Medi" of "NimbusRomNo9L-Medi"); empty when it has none.</summary>
    private static string StyleOf(string name)
    {
        var cut = name.LastIndexOfAny(['-', ',']);
        return cut >= 0 ? name[(cut + 1)..].Trim() : "";
    }

    [GeneratedRegex("^Medi(Ital)?$", RegexOptions.IgnoreCase)]
    private static partial Regex UrwMedium();

    // A style of capitalized words ending in "Ital" or "It" ("ReguItal", "MediItal", "BoldIt", "SemiboldIt", "It"); not a
    // word that merely ends so ("Digital", "Capital", "Orbital", "Bandit").
    [GeneratedRegex("^(?:[A-Z][a-z]*)*?(?:Ital|It)$")]
    private static partial Regex StyleItalic();

    [GeneratedRegex(@"^CM(?:BX(?:SL|TI)?|B|MIB|BSY|SSBX)\d+$")]
    private static partial Regex TexBold();

    [GeneratedRegex(@"^CM(?:MI|MIB|TI|SL|BXTI|BXSL|ITT|SSI|U)\d+$")]
    private static partial Regex TexItalic();

    /// <summary>The family name for Word: subset tag, style suffix and PostScript "MT"/"PS" endings dropped, words spaced.</summary>
    public static string Family(string pdfName)
    {
        var name = pdfName.Trim();
        if (name.Length > 7 && name[6] == '+' && name.Take(6).All(char.IsAsciiLetterUpper)) name = name[7..];
        var cut = name.IndexOfAny([',', '-']);
        if (cut > 0) name = name[..cut];
        name = PostScriptSuffix().Replace(name, "");
        if (!name.Contains(' ')) name = SpaceWords(name);
        // "Arial Bold" → "Arial" (a style glued to the family); never strip the whole name.
        var words = name.Split(' ', StringSplitOptions.RemoveEmptyEntries).ToList();
        while (words.Count > 1 && StyleWords.Contains(words[^1], StringComparer.OrdinalIgnoreCase)) words.RemoveAt(words.Count - 1);
        name = string.Join(' ', words);
        if (Known.TryGetValue(name, out var known)) return known;
        return name;
    }

    /// <summary>"TimesNewRoman" → "Times New Roman"; runs of capitals stay together ("SegoeUI" → "Segoe UI").</summary>
    private static string SpaceWords(string s)
    {
        var sb = new StringBuilder(s.Length + 4);
        for (var i = 0; i < s.Length; i++)
        {
            if (i > 0 && char.IsUpper(s[i]) && (char.IsLower(s[i - 1]) || (i + 1 < s.Length && char.IsLower(s[i + 1]) && char.IsUpper(s[i - 1]))))
                sb.Append(' ');
            sb.Append(s[i]);
        }
        return sb.ToString();
    }

    [GeneratedRegex("(PSMT|PS|MT)$")]
    private static partial Regex PostScriptSuffix();
}
