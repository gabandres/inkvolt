using System.Globalization;
using System.Reflection;

namespace InkvoltPdf.Core;

/// <summary>
/// The standard ZapfDingbats font, which Windows has no twin of: its built-in encoding and widths from Adobe's Core 14 AFM
/// (<c>Fonts/ZapfDingbats.afm</c>, unmodified, under Adobe's AFM licence in <c>Fonts/README.txt</c>) and the characters
/// its glyph names stand for from Adobe's ITC Zapf Dingbats Glyph List (<c>Fonts/zapfdingbats.txt</c>, BSD-3-Clause).
/// Both are embedded in this assembly with the licence.
/// </summary>
internal static class ZapfDingbats
{
    private static readonly string?[] Names = new string?[256];
    private static readonly Dictionary<string, double> Widths = new(StringComparer.Ordinal);
    private static readonly Dictionary<string, string> Characters = new(StringComparer.Ordinal);

    static ZapfDingbats()
    {
        // AFM: "C 33 ; WX 974 ; N a1 ; B 35 72 939 621 ;"
        foreach (var line in Lines("ZapfDingbats.afm"))
        {
            if (!line.StartsWith("C ", StringComparison.Ordinal)) continue;
            int? code = null;
            double? width = null;
            string? name = null;
            foreach (var part in line.Split(';'))
            {
                var kv = part.Trim().Split(' ', 2, StringSplitOptions.TrimEntries);
                if (kv.Length != 2) continue;
                switch (kv[0])
                {
                    case "C" when int.TryParse(kv[1], NumberStyles.Integer, CultureInfo.InvariantCulture, out var c):
                        code = c;
                        break;
                    case "WX" when double.TryParse(kv[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var w):
                        width = w;
                        break;
                    case "N":
                        name = kv[1];
                        break;
                }
            }
            if (name is null || width is null) continue;
            Widths.TryAdd(name, width.Value);
            if (code is >= 0 and < 256) Names[code.Value] = name;
        }
        // Glyph list: "a20;2714"
        foreach (var line in Lines("zapfdingbats.txt"))
        {
            if (line.StartsWith('#') || line.Split(';') is not [var n, var u]) continue;
            if (int.TryParse(u, NumberStyles.HexNumber, CultureInfo.InvariantCulture, out var cp) && cp is > 0 and < 0x110000 and not (>= 0xD800 and <= 0xDFFF))
                Characters.TryAdd(n, char.ConvertFromUtf32(cp));
        }
        Characters.TryAdd("space", " ");
    }

    private static IEnumerable<string> Lines(string file)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("InkvoltPdf.Core.Fonts." + file)
            ?? throw new InvalidOperationException("Font data missing: " + file);
        using var reader = new StreamReader(stream);
        var lines = new List<string>();
        while (reader.ReadLine() is { } line) lines.Add(line);
        return lines;
    }

    /// <summary>The glyph name of a code in ZapfDingbats' built-in encoding, or null.</summary>
    public static string? Name(int code) => code is < 0 or > 255 ? null : Names[code];

    /// <summary>A glyph's width in thousandths of an em, or null when the font has no glyph of that name.</summary>
    public static double? Width(string name) => Widths.TryGetValue(name, out var w) ? w : null;

    /// <summary>The character a glyph name stands for, or null.</summary>
    public static string? Text(string name) => Characters.GetValueOrDefault(name);

    /// <summary>The built-in encoding as an array of glyph names by code.</summary>
    public static string?[] Encoding => (string?[])Names.Clone();
}
