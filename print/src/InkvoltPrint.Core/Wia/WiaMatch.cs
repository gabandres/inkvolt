using System.Text.RegularExpressions;
using InkvoltPrint.Core.Suite;

namespace InkvoltPrint.Core.Wia;

/// <summary>A printer on the list as WIA matching sees it: its id, names (name, model, queue and driver names) and addresses.</summary>
public sealed record ScanTarget(string Id, IReadOnlyList<string> Names, IReadOnlyList<string> Hosts);

/// <summary>
/// Which listed printer a WIA scanner belongs to (an all-in-one's scanner part has its own driver, so Windows lists it apart from
/// the print queue). In order of certainty: the printer's address in the driver's port or name; the same name once makers' word
/// variants, "series", driver words and a "(1A2B3C)" suffix are taken out; the same model number (a word with a digit, like
/// "M234dw" or "MFC-L2710DW") with no other maker named. Null when nothing matches or more than one printer does.
/// </summary>
public static partial class WiaMatch
{
    public static string? Match(WiaDeviceInfo device, IReadOnlyList<ScanTarget> targets)
    {
        if (targets.Count == 0) return null;
        var text = $"{device.Port} {device.Name} {device.Description}";
        var hosts = device.Port is { Length: > 0 } port ? QueueMatch.HostsIn(port) : [];
        var byHost = targets.Where(t => t.Hosts.Any(h => h.Length > 0 && (hosts.Contains(h) || ContainsWord(text, h)))).ToList();
        if (byHost.Count == 1) return byHost[0].Id;

        var name = Normalize(device.Name);
        var byName = targets.Where(t => name.Length > 0 && t.Names.Any(n => Normalize(n) == name)).ToList();
        if (byName.Count == 1) return byName[0].Id;

        var models = Models(device.Name).Concat(Models(device.Description ?? "")).ToHashSet();
        var brand = Brand(device.Name);
        var byModel = targets.Where(t => t.Names.Any(n => Models(n).Overlaps(models) && SameMaker(brand, Brand(n)))).ToList();
        return byModel.Count == 1 ? byModel[0].Id : null;
    }

    private static readonly string[] Noise = ["series", "printer", "scanner", "scan", "wia", "twain", "driver", "class", "network", "lan",
        "usb", "wsd", "mfp", "pcl", "pcl5", "pcl5e", "pcl5c", "pcl6", "ps", "ps3", "postscript", "xl", "universal", "upd", "gdi", "ipp"];

    /// <summary>Lower case, "Hewlett-Packard" as "HP", without parentheses' contents, punctuation and <see cref="Noise"/> words.</summary>
    public static string Normalize(string name)
    {
        var s = Parenthesised().Replace(name.ToLowerInvariant().Replace("hewlett-packard", "hp").Replace("hewlett packard", "hp"), " ");
        return string.Join(' ', Words(s).Where(w => !Noise.Contains(w)));
    }

    /// <summary>
    /// Each device's printer (<see cref="Match"/>), at most one device per printer that takes a Windows scanner
    /// (<paramref name="takesScanner"/>, by id): a second device matching such a printer (its USB and its network driver, say) is
    /// left unclaimed, so it's listed as a scanner of its own instead of being neither used nor listed. Devices matching a printer
    /// that doesn't take one (it scans over eSCL) all stay with it, unused.
    /// </summary>
    public static IReadOnlyList<(WiaDeviceInfo Device, string? Owner)> Assign(
        IReadOnlyList<WiaDeviceInfo> devices, IReadOnlyList<ScanTarget> targets, Func<string, bool> takesScanner)
    {
        var given = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var result = new List<(WiaDeviceInfo, string?)>(devices.Count);
        foreach (var device in devices)
        {
            var owner = Match(device, targets);
            if (owner is not null && takesScanner(owner) && !given.Add(owner)) owner = null;
            result.Add((device, owner));
        }
        return result;
    }

    /// <summary>
    /// Model numbers in a name, inside parentheses too (Windows names network queues "NPI1A2B3C (Maker Model)"): words with a digit
    /// and at least three characters, a hyphenated one joined (MFC-L2710DW → mfcl2710dw; ET-2850 → et2850, never a bare 2850 that
    /// WF-2850 has too), and a number on its own joined to the word before it (Inkjet 3700 → inkjet3700, as Inkjet-3700 gives).
    /// </summary>
    public static HashSet<string> Models(string name)
    {
        var plain = name.Replace('(', ' ').Replace(')', ' ').Replace('[', ' ').Replace(']', ' ');
        var words = Normalize(Hyphenated().Replace(plain, "$1$2")).Split(' ', StringSplitOptions.RemoveEmptyEntries);
        var models = new HashSet<string>();
        for (var i = 0; i < words.Length; i++)
        {
            var w = words[i];
            if (w.All(char.IsDigit))
            {
                if (i > 0 && w.Length >= 2 && words[i - 1].All(char.IsLetter)) models.Add(words[i - 1] + w);
            }
            else if (w.Length >= 3 && w.Any(char.IsDigit) && !Noise.Contains(w)) models.Add(w);
        }
        return models;
    }

    /// <summary>The first word of letters only ("hp", "canon"), when the name starts with one.</summary>
    private static string? Brand(string name) => Normalize(name).Split(' ').FirstOrDefault() is { Length: > 1 } w && w.All(char.IsLetter) ? w : null;

    /// <summary>Different makers named on each side rule a match out; one side naming none (a bare model) doesn't.</summary>
    private static bool SameMaker(string? a, string? b) => a is null || b is null || a == b;

    private static IEnumerable<string> Words(string s) => NonWord().Split(s).Where(w => w.Length > 0);

    private static bool ContainsWord(string text, string word)
    {
        var i = text.IndexOf(word, StringComparison.OrdinalIgnoreCase);
        while (i >= 0)
        {
            var end = i + word.Length;
            if ((i == 0 || !char.IsLetterOrDigit(text[i - 1]) && text[i - 1] != '.')
                && (end == text.Length || !char.IsLetterOrDigit(text[end]) && (text[end] != '.' || end + 1 == text.Length || !char.IsDigit(text[end + 1]))))
                return true;
            i = text.IndexOf(word, i + 1, StringComparison.OrdinalIgnoreCase);
        }
        return false;
    }

    [GeneratedRegex(@"\([^)]*\)|\[[^\]]*\]")]
    private static partial Regex Parenthesised();

    [GeneratedRegex(@"[^a-z0-9]+")]
    private static partial Regex NonWord();

    [GeneratedRegex(@"\b([A-Za-z]+)-(?=[A-Za-z]*\d)([A-Za-z0-9]+)")]
    private static partial Regex Hyphenated();
}
