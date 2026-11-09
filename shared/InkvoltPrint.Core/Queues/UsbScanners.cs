using System.Text.RegularExpressions;

namespace InkvoltPrint.Core.Queues;

/// <summary>
/// Which USB devices with no driver are scanners (or an all-in-one's scanner part), for "Plugged in, needs its driver": one of the
/// still-image class (<c>USB\Class_06</c>) or from a maker of scanners whose own name or ids say scanner or all-in-one, or a scanner
/// maker's still-image device that isn't named as a camera (that class is mostly cameras and phones). Most
/// scanners report a vendor-specific class (<c>USB\Class_FF</c>), so the maker and the name decide. A phone, a camera or a webcam
/// (Samsung and HP make those too) is never one. Read from the device's ids and the name it reports, never its serial.
/// </summary>
public static partial class UsbScanners
{
    /// <summary>USB vendor ids of makers of scanners and all-in-ones, and the short name shown.</summary>
    private static readonly Dictionary<string, string> Makers = new(StringComparer.OrdinalIgnoreCase)
    {
        ["04B8"] = "Epson", ["04A9"] = "Canon", ["03F0"] = "HP", ["04F9"] = "Brother", ["04C5"] = "Fujitsu", ["07B3"] = "Plustek",
        ["0638"] = "Avision", ["04A7"] = "Visioneer", ["040A"] = "Kodak", ["043D"] = "Lexmark",
    };

    /// <summary>The vendor ids of the makers above: what the PnP watcher watches for scanners.</summary>
    public static IReadOnlyCollection<string> MakerVendorIds => Makers.Keys;

    /// <summary>Words in a name that make a maker's device a scanner or an all-in-one (whole words or a model's prefix).</summary>
    [GeneratedRegex(@"scan|perfection|\blide\b|\bfi-\d|\bds-\d|\bes-\d|\bads-\d|\bdr-[a-z]?\d|opticfilm|opticbook|opticslim|ephoto|fastfoto|\bff-\d|documate|\bmfp\b|all-in-one|\baio\b|multifunction|\bmfc-|\bdcp-|\bmf\d{3}",
        RegexOptions.IgnoreCase)]
    private static partial Regex ScannerWords();

    /// <summary>Words that make a device a phone, a camera or a webcam, whoever made it: never listed as a scanner.</summary>
    [GeneratedRegex(@"phone|android|galaxy|\bipad\b|\bmtp\b|\bptp\b|camera|webcam|\bcam\b|video|\badb\b|tablet|headset|audio|mouse|keyboard|\beos\b|powershot|\bixus\b|\bixy\b|coolpix|lumix|cyber-shot|finepix|easyshare|\bdsc\b|dslr|mirrorless|gopro|instax|\brebel\b",
        RegexOptions.IgnoreCase)]
    private static partial Regex NotScannerWords();

    [GeneratedRegex(@"VID_([0-9A-F]{4})&PID_([0-9A-F]{4})", RegexOptions.IgnoreCase)]
    private static partial Regex VidPid();

    /// <summary>"04B8:013C" from its hardware ids, null when they have none.</summary>
    public static string? UsbIdOf(UsbPrinterNode n) =>
        n.HardwareIds.Concat(n.DeviceIdName is { } d ? [d] : []).Select(h => VidPid().Match(h)).FirstOrDefault(m => m.Success) is { } m
            ? $"{m.Groups[1].Value.ToUpperInvariant()}:{m.Groups[2].Value.ToUpperInvariant()}" : null;

    private static string? Vid(UsbPrinterNode n) => UsbIdOf(n)?[..4];

    /// <summary>A scanner or an all-in-one's scanner part, by the rules above.</summary>
    public static bool IsScanner(UsbPrinterNode n)
    {
        var said = string.Join(' ', new[] { n.BusReportedName, n.FriendlyName }.Where(s => s is { Length: > 0 }).Concat(n.HardwareIds).Concat(n.CompatibleIds));
        if (NotScannerWords().IsMatch(said)) return false;
        var name = string.Join(' ', new[] { n.BusReportedName, n.FriendlyName }.Where(s => s is { Length: > 0 }).Concat(n.HardwareIds));
        var stillImage = n.CompatibleIds.Any(c => c.StartsWith(@"USB\Class_06", StringComparison.OrdinalIgnoreCase));
        var fromMaker = Vid(n) is { } vid && Makers.ContainsKey(vid);
        // A name that says scanner, from a scanner maker or of the still-image class. That class alone is mostly cameras and phones
        // (PTP), so without such a name only a scanner maker's still-image device that names itself, and not as a camera, counts.
        if (ScannerWords().IsMatch(name)) return stillImage || fromMaker;
        return stillImage && fromMaker && n.BusReportedName is { Length: > 0 };
    }

    /// <summary>The maker's short name, from its vendor id ("Epson"), else from its name; null when not known.</summary>
    public static string? MakerOf(UsbPrinterNode n) =>
        Vid(n) is { } vid && Makers.TryGetValue(vid, out var maker) ? maker : PrinterNames.MakerOf(n.BusReportedName ?? n.FriendlyName, null, []);

    /// <summary>
    /// The name to show: what the device reports ("Epson Perfection V19"; "EPSON" as "Epson"), else its friendly name unless that is
    /// Windows' "Unknown USB Device", else the maker's "Epson scanner", else "USB scanner". Shortened to 80 characters.
    /// </summary>
    public static string NameOf(UsbPrinterNode n)
    {
        var name = new[] { n.BusReportedName, n.FriendlyName }.Select(s => s?.Trim()).FirstOrDefault(s => s is { Length: > 0 } && !IsWindowsPlaceholder(s));
        var shown = name is null ? MakerOf(n) is { } maker ? $"{maker} scanner" : "USB scanner" : PrinterNames.ForDevice(name, null, []);
        if (MakerOf(n) is { } m && !shown.StartsWith(m + " ", StringComparison.OrdinalIgnoreCase) && !shown.Equals(m, StringComparison.OrdinalIgnoreCase)
            && name is not null && PrinterNames.MakerOf(shown, null, []) is null)
            shown = $"{m} {shown}"; // "Perfection V19" from an Epson: "Epson Perfection V19"
        return shown.Length > 80 ? shown[..80].TrimEnd() + "…" : shown;
    }

    private static bool IsWindowsPlaceholder(string s) =>
        s.StartsWith("Unknown USB Device", StringComparison.OrdinalIgnoreCase) || s.Equals("USB Composite Device", StringComparison.OrdinalIgnoreCase)
        || s.Equals("USB Device", StringComparison.OrdinalIgnoreCase);

    /// <summary>
    /// The scanner Windows lists under this name is this one: the same model words, the maker's way of writing its name aside
    /// ("EPSON Perfection V19" is "Epson Perfection V19"; "Epson Perfection V19 II" isn't).
    /// </summary>
    public static bool SameModel(string shown, string listed)
    {
        static string Words(string s) => Regex.Replace(PrinterNames.ForDevice(s, null, []).ToLowerInvariant(), @"[^a-z0-9]+", " ").Trim();
        var a = Words(shown);
        var b = Words(listed);
        if (a.Length == 0 || b.Length == 0) return false;
        // A WIA name may add the kind ("Epson Perfection V19 Scanner") or a number for a second one ("… #2").
        static string Trimmed(string s) => Regex.Replace(s, @"( (scanner|series|photo|\d))+$", "");
        return Trimmed(a) == Trimmed(b);
    }
}
