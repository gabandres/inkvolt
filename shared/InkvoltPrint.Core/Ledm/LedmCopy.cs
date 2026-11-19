using System.Xml.Linq;

namespace InkvoltPrint.Core.Ledm;

/// <summary>One copy the printer makes on its own: what to set before it starts.</summary>
public sealed record PrinterCopyRequest(int Copies, bool Collate, bool TwoSided, bool Color);

/// <summary>
/// What a printer's own copier lets an app set, read from its <c>CopyConfigCap</c> and <c>CopyConfigDyn</c>
/// (<see cref="LedmCopy.Read"/>). Only made when the printer has a writable start setting: without one it can't be told to copy.
/// </summary>
public sealed class PrinterCopyOffer
{
    internal PrinterCopyOffer(IReadOnlyDictionary<LedmCopy.Field, LedmCopy.Leaf> leaves) => Leaves = leaves;

    internal IReadOnlyDictionary<LedmCopy.Field, LedmCopy.Leaf> Leaves { get; }

    /// <summary>The number of copies can be set (otherwise the printer makes one).</summary>
    public bool CanSetCopies => Leaves.ContainsKey(LedmCopy.Field.Copies);

    /// <summary>The most copies one request asks for: the printer's own maximum, never more than <see cref="LedmCopy.MaxCopies"/>.</summary>
    public int MaxCopies => Leaves.TryGetValue(LedmCopy.Field.Copies, out var c) ? c.Max : 1;

    public bool CanCollate => Leaves.ContainsKey(LedmCopy.Field.Collate);
    public bool CanTwoSided => Leaves.ContainsKey(LedmCopy.Field.TwoSided);
    public bool CanColor => Leaves.ContainsKey(LedmCopy.Field.Color);
}

/// <summary>
/// HP LEDM's copy settings (<c>/DevMgmt/CopyConfigCap.xml</c>, <c>/DevMgmt/CopyConfigDyn.xml</c>, namespace
/// <c>…/ledm/cpcfgdyn/2008/05/05</c> as the LaserJet MFP M234dw's DiscoveryTree lists them), driven the way LEDM's other
/// writable settings are: the Cap names each writable element (<c>access="readWrite"</c>, its target in <c>elementXPath</c>,
/// its choices as child elements, numbers as <c>min</c>/<c>max</c>), and a PUT of a partial Dyn document built from the
/// printer's own element names and namespaces (<see cref="LedmSettingCatalog.BuildPut"/>) changes them.
/// <para>
/// <b>Unconfirmed.</b> No CopyConfigCap or CopyConfigDyn has been captured: the fixtures hold only the DiscoveryTree that
/// lists them. The element names in <see cref="Names"/> and the values in <see cref="Values"/> are an assumption, modelled on the
/// naming of the LEDM documents that were captured (<c>DuplexSupport</c>/<c>Duplex</c>, <c>DefaultPrintCopies</c>) and
/// kept in this one table so a recording of a real printer corrects them in one place. A printer whose documents don't
/// match gets no offer (<see cref="Read"/> returns null) and copies through the PC as before: nothing is sent on a guess.
/// </para>
/// </summary>
public static class LedmCopy
{
    public const string CapResource = "ledm:hpLedmCopyConfigCap";
    public const string DynResource = "ledm:hpLedmCopyConfigDyn";

    /// <summary>Copies asked for in one request, whatever the printer allows (the Copy tab's own limit).</summary>
    public const int MaxCopies = 99;

    /// <summary>Bounds on what a printer's Cap may list: choices per setting, a choice's length, how deep a setting sits.</summary>
    private const int MaxChoices = 32, MaxValueLength = 64, MaxPathDepth = 12;

    internal enum Field { Copies, Collate, TwoSided, Color, Start }

    /// <summary>A setting found on this printer: where it sits in the Dyn, the value that turns it on and off (or the number range).</summary>
    internal sealed record Leaf(Field Field, string[] Path, string? On, string? Off, int Min, int Max);

    /// <summary>The Dyn element (local name) each setting is looked for under. Assumed: see the class summary.</summary>
    internal static readonly IReadOnlyDictionary<Field, string[]> Names = new Dictionary<Field, string[]>
    {
        [Field.Copies] = ["Copies", "NumberOfCopies"],
        [Field.Collate] = ["Collate", "Collation"],
        [Field.TwoSided] = ["Duplex", "Sides", "PlexMode"],
        [Field.Color] = ["ColorMode", "CopyColorMode"],
        [Field.Start] = ["CopyState", "StartCopy"],
    };

    /// <summary>The Cap choices that mean on and off (compared ignoring case; the printer's own spelling is written). Assumed.</summary>
    internal static readonly IReadOnlyDictionary<Field, (string[] On, string[] Off)> Values = new Dictionary<Field, (string[], string[])>
    {
        [Field.Collate] = (["collated", "on", "true", "enabled"], ["uncollated", "off", "false", "disabled"]),
        [Field.TwoSided] = (["simplexToDuplex", "oneToTwoSided", "twoSidedLongEdge", "duplex", "twoSided", "on"],
            ["simplexToSimplex", "oneToOneSided", "oneSided", "simplex", "off"]),
        [Field.Color] = (["color", "RGB24", "rgb"], ["mono", "monochrome", "grayscale", "Grayscale8", "blackAndWhite", "gray"]),
        [Field.Start] = (["start", "startCopy", "processing"], []),
    };

    /// <summary>The tree lists both copy documents.</summary>
    public static bool Listed(DiscoveryTree tree) => tree.UriFor(CapResource) is not null && tree.UriFor(DynResource) is not null;

    /// <summary>
    /// What this printer lets an app set, or null when it can't be started from here (no writable start setting the app
    /// knows, or no Cap). Each setting needs a Cap entry marked <c>readWrite</c> and the element in the Dyn; a choice needs
    /// both its on and off values among the Cap's choices.
    /// </summary>
    public static PrinterCopyOffer? Read(XDocument dyn, XDocument? cap)
    {
        if (dyn.Root is not { } root || cap?.Root is not { } capRoot) return null;
        var leaves = new Dictionary<Field, Leaf>();
        foreach (var entry in capRoot.Descendants())
        {
            if ((string?)entry.Attribute("access") != "readWrite" || Target(entry) is not { } target) continue;
            if (FieldFor(target) is not { } field || leaves.ContainsKey(field)) continue;
            if (FindLeaf(root, target) is not { } path) continue;
            if (field == Field.Copies)
            {
                var min = Math.Max(1, ((string?)entry.Attribute("min")).ToInt() ?? 1);
                var max = Math.Min(MaxCopies, ((string?)entry.Attribute("max")).ToInt() ?? MaxCopies);
                if (min <= 1 && max > 1) leaves[field] = new Leaf(field, path, null, null, 1, max);
                continue;
            }
            var choices = entry.Elements().Select(e => e.Value.Trim()).Where(v => v.Length is > 0 and <= MaxValueLength)
                .Distinct(StringComparer.Ordinal).Take(MaxChoices).ToList();
            var (onNames, offNames) = Values[field];
            var on = Pick(choices, onNames);
            var off = Pick(choices, offNames);
            if (on is null || (off is null && field != Field.Start)) continue;
            leaves[field] = new Leaf(field, path, on, off, 0, 0);
        }
        return leaves.ContainsKey(Field.Start) ? new PrinterCopyOffer(leaves) : null;
    }

    /// <summary>
    /// The PUT body that sets up and starts one copy: each setting the printer offers (copies clamped to its range; collate
    /// only with more than one copy), then the start setting last. Element names and namespaces are the printer's own, from
    /// <paramref name="dyn"/> (read again just before sending).
    /// </summary>
    public static XDocument Build(XDocument dyn, PrinterCopyOffer offer, PrinterCopyRequest request)
    {
        var changes = new List<(LedmSettingDef, string)>();
        var copies = 1;
        if (offer.Leaves.TryGetValue(Field.Copies, out var c))
        {
            copies = Math.Clamp(request.Copies, 1, c.Max);
            changes.Add((Def(c), copies.ToString(System.Globalization.CultureInfo.InvariantCulture)));
        }
        void Choice(Field field, bool on)
        {
            if (offer.Leaves.TryGetValue(field, out var leaf)) changes.Add((Def(leaf), on ? leaf.On! : leaf.Off!));
        }
        Choice(Field.Collate, request.Collate || copies == 1);
        Choice(Field.TwoSided, request.TwoSided);
        Choice(Field.Color, request.Color);
        var start = offer.Leaves[Field.Start];
        changes.Add((Def(start), start.On!));
        return LedmSettingCatalog.BuildPut(dyn, changes);
    }

    private static LedmSettingDef Def(Leaf leaf) =>
        new(leaf.Field.ToString(), DynResource, CapResource, leaf.Path, leaf.Path[^1], SettingKind.Choice);

    /// <summary>
    /// The Dyn element a Cap entry is about: the last step of its <c>elementXPath</c> (prefix and position dropped), else
    /// its own name less a trailing <c>Support</c> (<c>DuplexSupport</c> → <c>Duplex</c>).
    /// </summary>
    internal static string? Target(XElement capEntry)
    {
        if ((string?)capEntry.Attribute("elementXPath") is { Length: > 0 and <= 512 } xpath)
        {
            var step = xpath.TrimEnd('/');
            step = step[(step.LastIndexOf('/') + 1)..];
            if (step.IndexOf('[') is >= 0 and var bracket) step = step[..bracket];
            step = step[(step.IndexOf(':') + 1)..].Trim();
            return step.Length > 0 ? step : null;
        }
        var name = capEntry.Name.LocalName;
        return name.EndsWith("Support", StringComparison.Ordinal) && name.Length > "Support".Length ? name[..^"Support".Length] : name;
    }

    private static Field? FieldFor(string localName)
    {
        foreach (var (field, names) in Names)
            if (names.Contains(localName, StringComparer.Ordinal)) return field;
        return null;
    }

    /// <summary>The path (local names below the root) to the first element named <paramref name="localName"/> holding a value, not more elements.</summary>
    private static string[]? FindLeaf(XElement root, string localName)
    {
        var leaf = root.Descendants().FirstOrDefault(e => e.Name.LocalName == localName && !e.HasElements);
        if (leaf is null) return null;
        var path = leaf.AncestorsAndSelf().TakeWhile(e => e != root).Select(e => e.Name.LocalName).Reverse().ToArray();
        // BuildPut follows the first element of each name: a leaf behind an earlier namesake (a second InputTray) can't be reached.
        if (path.Length > MaxPathDepth || Follow(root, path) != leaf) return null;
        return path;
    }

    private static XElement? Follow(XElement root, string[] path)
    {
        XElement? node = root;
        foreach (var name in path) node = node?.Kid(name);
        return node;
    }

    private static string? Pick(IReadOnlyList<string> choices, string[] names)
    {
        foreach (var name in names)
            if (choices.FirstOrDefault(c => string.Equals(c, name, StringComparison.OrdinalIgnoreCase)) is { } found) return found;
        return null;
    }
}
