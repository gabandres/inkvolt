/// Parsed `/DevMgmt/DiscoveryTree.xml`: resource type → URI, plus advertised interfaces.
public struct DiscoveryTree: Equatable, Sendable {
    public static let path = "/DevMgmt/DiscoveryTree.xml"

    public let resources: [String: String]
    public let interfaces: [String: String]

    public var hasCdm: Bool { interfaces["cdm:servicesDiscovery"] != nil }
    public var hasEscl: Bool { interfaces["eSCL:eSclManifest"] != nil }
    public var hasEvents: Bool { resources[LedmResource.eventTable] != nil }

    public func uri(for resourceType: String) -> String? { resources[resourceType] }

    /// Manifest URI of an interface the tree lists as `SupportedIfc` (its resources are in the manifest, not the tree).
    public func manifest(for interfaceType: String) -> String? { interfaces[interfaceType] }

    public static func parse(_ root: XmlElement) -> DiscoveryTree {
        var resources: [String: String] = [:]
        var interfaces: [String: String] = [:]
        for e in root.children {
            guard let type = e.kidValue("ResourceType") else { continue }
            switch e.name {
            case "SupportedTree", "SupportedFeature":
                if let uri = e.kidValue("ResourceURI") { resources[type] = uri }
            case "SupportedIfc":
                if let manifest = e.kidValue("ManifestURI") { interfaces[type] = manifest }
            default:
                break
            }
        }
        return DiscoveryTree(resources: resources, interfaces: interfaces)
    }
}

public enum LedmResource {
    public static let productStatusDyn = "ledm:hpLedmProductStatusDyn"
    public static let productConfigDyn = "ledm:hpLedmProductConfigDyn"
    public static let productConfigCap = "ledm:hpLedmProductConfigCap"
    public static let consumableConfigDyn = "ledm:hpLedmConsumableConfigDyn"
    public static let productUsageDyn = "ledm:hpLedmProductUsageDyn"
    public static let printConfigDyn = "ledm:hpLedmPrintConfigDyn"
    public static let printConfigCap = "ledm:hpLedmPrintConfigCap"
    public static let mediaHandlingDyn = "ledm:hpLedmMediaHandlingDyn"
    public static let mediaHandlingCap = "ledm:hpLedmMediaHandlingCap"
    public static let eventTable = "ledm:hpLedmEventTable"
    public static let firmwareUpdateManifest = "ledm:hpLedmFirmwareUpdateManifest"
}

/// An LEDM interface manifest's resource map: element type (e.g. `FirmwareUpdateDyn`) → absolute path. Paths nest: the
/// map's root link is the base (`/FirmwareUpdate`), each node's link is relative to its parent (`/WebFWUpdate` → `/Config`
/// is `/FirmwareUpdate/WebFWUpdate/Config`).
public enum LedmManifest {
    /// Type → path; a type listed more than once (one per update class, say) keeps its first path: see `entries`.
    public static func parse(_ root: XmlElement) -> [String: String] {
        var map: [String: String] = [:]
        for (type, path) in entries(root) where map[type] == nil { map[type] = path }
        return map
    }

    /// Every resource in document order, repeated types included.
    public static func entries(_ root: XmlElement) -> [(type: String, path: String)] {
        guard let resourceMap = root.kid("ResourceMap") else { return [] }
        var map: [(type: String, path: String)] = []
        walk(resourceMap, resourceMap.kid("ResourceLink")?.kidValue("ResourceURI") ?? "", &map, depth: 1)
        return map
    }

    /// Nested maps followed; deeper ones are ignored. Real manifests nest three or four deep; the reply comes over plain
    /// HTTP before the device is identified, so a map nested thousands deep must not recurse once per level.
    private static let maxDepth = 32

    private static func walk(_ resourceMap: XmlElement, _ basePath: String, _ map: inout [(type: String, path: String)], depth: Int) {
        for node in resourceMap.kids("ResourceNode") {
            guard let link = node.kid("ResourceLink")?.kidValue("ResourceURI") else { continue }
            var base = Substring(basePath)
            while base.hasSuffix("/") { base = base.dropLast() }
            var tail = Substring(link)
            while tail.hasPrefix("/") { tail = tail.dropFirst() }
            let path = "\(base)/\(tail)"
            // The type is the text of whichever element sits in ResourceType (its name varies per interface).
            if let type = node.kid("ResourceType")?.children.first?.value.trimmingCharacters(in: .whitespacesAndNewlines), !type.isEmpty {
                map.append((type, path))
            }
            if depth < maxDepth, let nested = node.kid("ResourceMap") { walk(nested, path, &map, depth: depth + 1) }
        }
    }
}
