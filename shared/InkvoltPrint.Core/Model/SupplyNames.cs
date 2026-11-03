namespace InkvoltPrint.Core.Model;

/// <summary>
/// The words of a supply's name that Inkvolt Print writes itself (LEDM and CDM give a colour code and a kind keyword, not
/// a name): "Black toner", "Cyan ink cartridge"; in Spanish the kind comes first ("Tóner negro"). Read at the moment of
/// use, as the interface's language is chosen at start-up. SNMP's names are the printer's own and are shown as sent.
/// </summary>
internal static class SupplyNames
{
    /// <summary>The word for a kind keyword we know; other keywords as they are.</summary>
    public static string Kind(string kind) => kind switch
    {
        "toner" => CoreStrings.Supply_Toner,
        "ink" => CoreStrings.Supply_Ink,
        "ink cartridge" => CoreStrings.Supply_InkCartridge,
        "ink tank" => CoreStrings.Supply_InkTank,
        "printhead" => CoreStrings.Supply_Printhead,
        "drum" => CoreStrings.Supply_Drum,
        "supply" => CoreStrings.Supply_Supply,
        "developer" => CoreStrings.Supply_Developer,
        "fuser oil" => CoreStrings.Supply_FuserOil,
        "wax" => CoreStrings.Supply_Wax,
        "waste-toner" => CoreStrings.Supply_WasteToner,
        "waste-ink" => CoreStrings.Supply_WasteInk,
        "waste-wax" => CoreStrings.Supply_WasteWax,
        _ => kind,
    };

    /// <summary>
    /// The name from a colour word (null or empty for none) and a kind keyword. A known colour leads in English ("Black
    /// toner") and follows in Spanish ("Tóner negro"), so the first letter is made upper case when there is one.
    /// </summary>
    public static string Name(string? color, bool colorKnown, string kind)
    {
        var word = Kind(kind);
        var name = string.IsNullOrEmpty(color) ? word
            : colorKnown ? string.Format(CoreStrings.Supply_ColorAndKind, color, word)
            : $"{color} {word}";
        name = name.Trim();
        return colorKnown && name.Length > 0 ? char.ToUpperInvariant(name[0]) + name[1..] : name;
    }

    /// <summary>
    /// The English name (<see cref="Consumable.Key"/>), as the parsers wrote it before the interface had a language:
    /// "Black toner", "Tri-color ink cartridge", "Photo black ink"; an unknown colour code as it is (LEDM's names as they
    /// came, CDM's with a capital first letter).
    /// </summary>
    public static string EnglishName(string? colorCode, string kind, bool capitalize)
    {
        var color = colorCode switch
        {
            "K" => "Black",
            "C" => "Cyan",
            "M" => "Magenta",
            "Y" => "Yellow",
            "CMY" => "Tri-color",
            "pK" => "Photo black",
            "mK" => "Matte black",
            "G" => "Gray",
            null => "",
            _ => colorCode,
        };
        var name = $"{color} {kind}".Trim();
        return capitalize && name.Length > 0 ? char.ToUpperInvariant(name[0]) + name[1..] : name;
    }

    /// <summary>
    /// A name the supply history kept (<see cref="EnglishName"/>) in the interface's language, for the chart's spoken text: "Black
    /// toner" reads "Tóner negro" in Spanish. A printer's own name (IPP, SNMP) stays as it is.
    /// </summary>
    public static string FromEnglish(string english)
    {
        foreach (var kind in KnownKinds)
        {
            if (english.Equals(kind, StringComparison.OrdinalIgnoreCase)) return Name(null, colorKnown: false, kind);
            if (!english.EndsWith(" " + kind, StringComparison.OrdinalIgnoreCase)) continue;
            var color = ColorWord(english[..^(kind.Length + 1)], Feminine(kind));
            return color is null ? english : Name(color, colorKnown: true, kind);
        }
        return english;
    }

    // The longest first: "ink cartridge" before "ink".
    private static readonly string[] KnownKinds = ["ink cartridge", "ink tank", "printhead", "toner", "drum", "supply", "ink"];

    private static string? ColorWord(string english, bool feminine) => english.ToLowerInvariant() switch
    {
        "black" => feminine ? CoreStrings.Supply_Black_Feminine : CoreStrings.Supply_Black,
        "cyan" => CoreStrings.Supply_Cyan,
        "magenta" => CoreStrings.Supply_Magenta,
        "yellow" => feminine ? CoreStrings.Supply_Yellow_Feminine : CoreStrings.Supply_Yellow,
        "tri-color" => CoreStrings.Supply_TriColor,
        "photo black" => CoreStrings.Supply_PhotoBlack,
        "matte black" => CoreStrings.Supply_MatteBlack,
        "gray" => CoreStrings.Supply_Gray,
        _ => null,
    };

    /// <summary>
    /// Kinds whose word takes the feminine form of a colour in Spanish ("tinta negra"); the English is the same either way.
    /// </summary>
    public static bool Feminine(string kind) => kind is "ink" or "wax";
}
