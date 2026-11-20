using System.Globalization;

namespace InkvoltPrint.Core.Ipp;

/// <summary>
/// One <c>printer-supply</c> value (PWG 5100.13): the Printer MIB's supply row as <c>key=value;</c> text, e.g.
/// <c>index=1;class=supplyThatIsConsumed;type=tonerCartridge;unit=impressions;maxcapacity=3000;level=1050;colorantname=black;</c>.
/// Only a supply counted in pages (<c>unit</c> impressions or sheets) gives pages: its <c>level</c> is the pages left and its
/// <c>maxcapacity</c> what a full one is rated for; a percentage or unknown unit gives neither.
/// </summary>
public sealed record IppSupply(string? Unit, int? MaxCapacity, int? Level)
{
    /// <summary>Longest value read (the octetString is at most 1023 octets in PWG 5100.13).</summary>
    private const int MaxLength = 1023;

    /// <summary>Counted in pages: impressions or sheets (PrtMarkerSuppliesSupplyUnitTC's names).</summary>
    public bool InPages => Unit is "impressions" or "sheets";

    /// <summary>The pages left: the level of a supply counted in pages (RFC 3805: −1, −2 and −3 aren't counts).</summary>
    public int? PagesLeft => InPages && Level is >= 0 && (MaxCapacity is not > 0 || Level <= MaxCapacity) ? Level : null;

    /// <summary>The pages a full one is rated for: the maximum of a supply counted in pages.</summary>
    public int? PageYield => InPages && MaxCapacity is > 0 ? MaxCapacity : null;

    public static IppSupply Parse(string value)
    {
        string? unit = null;
        int? max = null, level = null;
        foreach (var part in value.Length > MaxLength ? value[..MaxLength].Split(';') : value.Split(';'))
        {
            var eq = part.IndexOf('=');
            if (eq <= 0) continue;
            var key = part[..eq].Trim();
            var text = part[(eq + 1)..].Trim();
            switch (key)
            {
                case "unit": unit = text; break;
                case "maxcapacity": max = Number(text); break;
                case "level": level = Number(text); break;
            }
        }
        return new IppSupply(unit, max, level);

        static int? Number(string text) =>
            int.TryParse(text, NumberStyles.AllowLeadingSign, CultureInfo.InvariantCulture, out var n) ? n : null;
    }
}
