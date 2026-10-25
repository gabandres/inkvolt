using System.Text.RegularExpressions;

namespace InkvoltPrint.Core.Model;

public enum PrinterBrand { Other, Hp, Canon, Epson, Brother }

/// <summary>The maker, from text the printer reports (IPP make-and-model, eSCL MakeAndModel / Manufacturer, DNS-SD <c>ty</c>).</summary>
public static class PrinterBrands
{
    public static PrinterBrand Detect(params string?[] texts)
    {
        foreach (var t in texts)
        {
            if (string.IsNullOrWhiteSpace(t)) continue;
            if (Word(t, "Hewlett-Packard") || Word(t, "HP")) return PrinterBrand.Hp;
            if (Word(t, "Canon")) return PrinterBrand.Canon;
            if (Word(t, "Epson")) return PrinterBrand.Epson;
            if (Word(t, "Brother")) return PrinterBrand.Brother;
        }
        return PrinterBrand.Other;
    }

    public static string Name(PrinterBrand b) => b switch
    {
        PrinterBrand.Hp => "HP",
        PrinterBrand.Canon => "Canon",
        PrinterBrand.Epson => "Epson",
        PrinterBrand.Brother => "Brother",
        _ => "",
    };

    private static bool Word(string text, string word) =>
        Regex.IsMatch(text, $@"(?<![\p{{L}}\p{{N}}]){Regex.Escape(word)}(?![\p{{L}}\p{{N}}])", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
}
