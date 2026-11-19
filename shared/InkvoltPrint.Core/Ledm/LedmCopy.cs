using System.Xml.Linq;

namespace InkvoltPrint.Core.Ledm;

/// <summary>Where a printer's copy start setting sits in its CopyConfigDyn (local names below the root) and the value that starts a copy.</summary>
public sealed record CopyStart(IReadOnlyList<string> Path, string Value);

/// <summary>
/// HP LEDM's copy settings (<c>/DevMgmt/CopyConfigCap.xml</c>, <c>/DevMgmt/CopyConfigDyn.xml</c>, namespace
/// <c>…/ledm/cpcfgdyn/2008/05/05</c> as the LaserJet MFP M234dw's DiscoveryTree lists them), driven the way LEDM's other
/// writable settings are: the Cap names a writable element (<c>access="readWrite"</c>, its place in <c>elementXPath</c>, its
/// choices as child elements), and a PUT of a partial Dyn document built from the printer's own element names and
/// namespaces (<see cref="LedmSettingCatalog.BuildPut"/>) changes it.
/// <para>
/// <b>Only the start is written.</b> CopyConfigDyn holds the copy settings the printer keeps for its control panel (copies,
/// two-sided and the like); writing them for one copy would change everyone's walk-up defaults, and putting them back means
/// knowing when the copy has finished, which nothing captured shows. So the printer copies with its own settings, and the
/// app's copy options are for copies through the PC.
/// </para>
/// <para>
/// <b>Unconfirmed.</b> No CopyConfigCap or CopyConfigDyn has been captured: the fixtures hold only the DiscoveryTree that
/// lists them. The start's element names (<see cref="StartNames"/>) and values (<see cref="StartValues"/>) are an assumption,
/// modelled on the naming of the LEDM documents that were captured and kept here so a recording corrects them in one place.
/// Only an explicit command counts as a start (a state such as <c>processing</c> doesn't). A printer whose documents don't
/// match gets nothing (<see cref="Read"/> returns null) and copies through the PC: nothing is sent on a guess.
/// </para>
/// </summary>
public static class LedmCopy
{
    public const string CapResource = "ledm:hpLedmCopyConfigCap";
    public const string DynResource = "ledm:hpLedmCopyConfigDyn";

    /// <summary>Bounds on what a printer's Cap may hold: choices read per entry, a choice's length, steps in an <c>elementXPath</c>.</summary>
    private const int MaxChoices = 32, MaxValueLength = 64, MaxPathDepth = 12, MaxXPathLength = 512;

    /// <summary>The Dyn element (local name) that starts a copy. Assumed: see the class summary.</summary>
    internal static readonly IReadOnlyList<string> StartNames = ["CopyState", "StartCopy"];

    /// <summary>The Cap choices that are a command to start (compared ignoring case; the printer's own spelling is written). Assumed.</summary>
    internal static readonly IReadOnlyList<string> StartValues = ["start", "startCopy"];

    /// <summary>The tree lists both copy documents.</summary>
    public static bool Listed(DiscoveryTree tree) => tree.UriFor(CapResource) is not null && tree.UriFor(DynResource) is not null;

    /// <summary>
    /// The printer's copy start, or null when it can't be started from here: no Cap, no Cap entry marked <c>readWrite</c> for a
    /// start element, no start command among its choices, or no such element where the entry says it is in the Dyn.
    /// </summary>
    public static CopyStart? Read(XDocument dyn, XDocument? cap)
    {
        if (dyn.Root is not { } root || cap?.Root is not { } capRoot) return null;
        foreach (var entry in capRoot.Descendants())
        {
            if ((string?)entry.Attribute("access") != "readWrite" || Locate(entry, root) is not { } path) continue;
            if (!StartNames.Contains(path[^1], StringComparer.Ordinal)) continue;
            var choices = entry.Elements().Select(e => e.Value.Trim()).Where(v => v.Length is > 0 and <= MaxValueLength).Take(MaxChoices);
            var start = StartValues.Select(v => choices.FirstOrDefault(c => string.Equals(c, v, StringComparison.OrdinalIgnoreCase))).FirstOrDefault(c => c is not null);
            if (start is not null) return new CopyStart(path, start);
        }
        return null;
    }

    /// <summary>The PUT body that starts one copy: the start element alone, in the printer's own names and namespaces (from <paramref name="dyn"/>, read again just before sending).</summary>
    public static XDocument Build(XDocument dyn, CopyStart start) =>
        LedmSettingCatalog.BuildPut(dyn, [(new LedmSettingDef("CopyStart", DynResource, CapResource, [.. start.Path], start.Path[^1], SettingKind.Choice), start.Value)]);

    /// <summary>
    /// The Dyn element a Cap entry is about, as local names below the root, or null when it isn't there. With an
    /// <c>elementXPath</c>, every step is followed (prefixes dropped; the root's own name may lead; a position <c>[n]</c> picks the
    /// n-th of that name, other predicates aren't understood); without one, the root's child named like the entry less a
    /// trailing <c>Support</c> (<c>CopyStateSupport</c> → <c>CopyState</c>). The element must hold a value, not more elements,
    /// and be the one a PUT built by <see cref="LedmSettingCatalog.BuildPut"/> reaches (it follows the first of each name).
    /// </summary>
    internal static string[]? Locate(XElement capEntry, XElement root)
    {
        string[] steps;
        var positions = new List<int>();
        if ((string?)capEntry.Attribute("elementXPath") is { } xpath)
        {
            if (xpath.Length is 0 or > MaxXPathLength) return null;
            var parts = xpath.Trim().Trim('/').Split('/');
            if (parts.Length > MaxPathDepth + 1) return null;
            var names = new List<string>();
            foreach (var part in parts)
            {
                var (name, position) = Step(part);
                if (name is null) return null;
                names.Add(name);
                positions.Add(position);
            }
            if (names.Count > 1 && names[0] == root.Name.LocalName)
            {
                names.RemoveAt(0);
                positions.RemoveAt(0);
            }
            steps = [.. names];
        }
        else
        {
            var name = capEntry.Name.LocalName;
            steps = [name.EndsWith("Support", StringComparison.Ordinal) && name.Length > "Support".Length ? name[..^"Support".Length] : name];
            positions.Add(1);
        }
        if (steps.Length is 0 or > MaxPathDepth) return null;

        XElement? node = root;
        for (var i = 0; i < steps.Length && node is not null; i++)
        {
            // Only the first of each name: BuildPut couldn't reach a second one.
            if (positions[i] != 1) return null;
            node = node.Kid(steps[i]);
        }
        return node is { HasElements: false } ? steps : null;
    }

    /// <summary><c>prefix:Name[n]</c> → (Name, n); a position defaults to 1; anything else (another predicate, an empty name) → null.</summary>
    private static (string? Name, int Position) Step(string part)
    {
        var position = 1;
        var bracket = part.IndexOf('[');
        if (bracket >= 0)
        {
            if (!part.EndsWith(']') || !int.TryParse(part[(bracket + 1)..^1], out position) || position < 1) return (null, 0);
            part = part[..bracket];
        }
        var name = part[(part.IndexOf(':') + 1)..].Trim();
        return name.Length > 0 && System.Xml.XmlConvert.IsNCNameChar(name[0]) && name.All(System.Xml.XmlConvert.IsNCNameChar) ? (name, position) : (null, 0);
    }
}
