using System.Xml.Linq;

namespace PrintDesk.Core.Ledm;

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
}
