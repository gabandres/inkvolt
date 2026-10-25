using System.Xml.Linq;

namespace InkvoltPrint.Core.Ledm;

/// <summary>Parsed <c>/DevMgmt/DiscoveryTree.xml</c>: resource type → URI, plus advertised interfaces.</summary>
public sealed class DiscoveryTree
{
    public const string Path = "/DevMgmt/DiscoveryTree.xml";

    private readonly Dictionary<string, string> _resources;
    private readonly Dictionary<string, string> _interfaces;

    private DiscoveryTree(Dictionary<string, string> resources, Dictionary<string, string> interfaces)
    {
        _resources = resources;
        _interfaces = interfaces;
    }

    public IReadOnlyDictionary<string, string> Resources => _resources;
    public IReadOnlyDictionary<string, string> Interfaces => _interfaces;

    public bool HasCdm => _interfaces.ContainsKey("cdm:servicesDiscovery");
    public bool HasEscl => _interfaces.ContainsKey("eSCL:eSclManifest");
    public bool HasEvents => _resources.ContainsKey(LedmResource.EventTable);

    public string? UriFor(string resourceType) => _resources.GetValueOrDefault(resourceType);

    /// <summary>Manifest URI of an interface the tree lists as <c>SupportedIfc</c> (its resources are in the manifest, not the tree).</summary>
    public string? ManifestFor(string interfaceType) => _interfaces.GetValueOrDefault(interfaceType);

    public static DiscoveryTree Parse(XDocument doc)
    {
        var res = new Dictionary<string, string>(StringComparer.Ordinal);
        var ifc = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var e in doc.Root!.Elements())
        {
            var type = e.KidValue("ResourceType");
            if (type is null) continue;
            switch (e.Name.LocalName)
            {
                case "SupportedTree" or "SupportedFeature" when e.KidValue("ResourceURI") is { } uri:
                    res[type] = uri;
                    break;
                case "SupportedIfc" when e.KidValue("ManifestURI") is { } man:
                    ifc[type] = man;
                    break;
            }
        }
        return new DiscoveryTree(res, ifc);
    }
}

public static class LedmResource
{
    public const string ProductStatusDyn = "ledm:hpLedmProductStatusDyn";
    public const string ProductConfigDyn = "ledm:hpLedmProductConfigDyn";
    public const string ProductConfigCap = "ledm:hpLedmProductConfigCap";
    public const string ConsumableConfigDyn = "ledm:hpLedmConsumableConfigDyn";
    public const string ProductUsageDyn = "ledm:hpLedmProductUsageDyn";
    public const string PrintConfigDyn = "ledm:hpLedmPrintConfigDyn";
    public const string PrintConfigCap = "ledm:hpLedmPrintConfigCap";
    public const string MediaHandlingDyn = "ledm:hpLedmMediaHandlingDyn";
    public const string MediaHandlingCap = "ledm:hpLedmMediaHandlingCap";
    public const string EventTable = "ledm:hpLedmEventTable";
    public const string FirmwareUpdateManifest = "ledm:hpLedmFirmwareUpdateManifest";
}

/// <summary>
/// An LEDM interface manifest's resource map: element type (e.g. <c>FirmwareUpdateDyn</c>) → absolute path. Paths nest:
/// the map's root link is the base (<c>/FirmwareUpdate</c>), each node's link is relative to its parent
/// (<c>/WebFWUpdate</c> → <c>/Config</c> is <c>/FirmwareUpdate/WebFWUpdate/Config</c>).
/// </summary>
public static class LedmManifest
{
    /// <summary>Type → path; a type listed more than once (one per update class, say) keeps its first path: see <see cref="Entries"/>.</summary>
    public static IReadOnlyDictionary<string, string> Parse(XDocument doc)
    {
        var map = new Dictionary<string, string>(StringComparer.Ordinal);
        foreach (var (type, path) in Entries(doc)) map.TryAdd(type, path);
        return map;
    }

    /// <summary>Every resource in document order, repeated types included.</summary>
    public static IReadOnlyList<(string Type, string Path)> Entries(XDocument doc)
    {
        var map = new List<(string, string)>();
        if (doc.Root?.Kid("ResourceMap") is not { } root) return map;
        var basePath = root.Kid("ResourceLink")?.KidValue("ResourceURI") ?? "";
        Walk(root, basePath, map);
        return map;
    }

    private static void Walk(XElement resourceMap, string basePath, List<(string, string)> map)
    {
        foreach (var node in resourceMap.Kids("ResourceNode"))
        {
            if (node.Kid("ResourceLink")?.KidValue("ResourceURI") is not { } link) continue;
            var path = basePath.TrimEnd('/') + "/" + link.TrimStart('/');
            // The type is the text of whichever element sits in ResourceType (its name varies per interface).
            if (node.Kid("ResourceType")?.Elements().FirstOrDefault()?.Value.Trim() is { Length: > 0 } type) map.Add((type, path));
            if (node.Kid("ResourceMap") is { } nested) Walk(nested, path, map);
        }
    }
}
