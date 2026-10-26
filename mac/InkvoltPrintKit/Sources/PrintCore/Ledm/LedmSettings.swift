import Foundation

public enum SettingKind: Sendable { case choice, text, integer }

/// A curated, writable LEDM setting. `path` is the element path (local names) below the Dyn root; `keySiblings` are
/// elements copied next to the leaf so the device knows which instance is meant (e.g. the tray's `InputBin`). Allowed values
/// come from the matching Cap resource.
public struct LedmSettingDef: Equatable, Sendable {
    public let key: String
    public let label: String
    public let group: String
    public let dynResource: String
    public let capResource: String
    public let path: [String]
    public let capElement: String
    public let kind: SettingKind
    public let keySiblings: [String]

    public init(_ key: String, _ label: String, _ group: String, _ dynResource: String, _ capResource: String, _ path: [String],
                _ capElement: String, _ kind: SettingKind, keySiblings: [String] = []) {
        self.key = key
        self.label = label
        self.group = group
        self.dynResource = dynResource
        self.capResource = capResource
        self.path = path
        self.capElement = capElement
        self.kind = kind
        self.keySiblings = keySiblings
    }
}

/// A setting as the printer reports it: its value, and what the Cap allows (choices, a text's length, a number's range).
public struct LedmSetting: Equatable, Sendable {
    public let def: LedmSettingDef
    public let value: String
    public let choices: [String]
    public let maxLength: Int?
    public let min: Int?
    public let max: Int?

    public func display(_ value: String) -> String { def.kind == .choice ? SettingText.display(def.key, value) : value }
}

/// The settings read from one printer, with the Dyn documents a change is built from (`LedmSettingCatalog.buildPut`).
public struct LedmSettings: Sendable {
    public let items: [LedmSetting]
    /// Dyn resource type → the document the printer sent.
    public let documents: [String: XmlElement]
}

public enum LedmSettingCatalog {
    private static let pc = LedmResource.productConfigDyn, pcCap = LedmResource.productConfigCap
    private static let pr = LedmResource.printConfigDyn, prCap = LedmResource.printConfigCap
    private static let mh = LedmResource.mediaHandlingDyn, mhCap = LedmResource.mediaHandlingCap

    public static let all: [LedmSettingDef] = [
        LedmSettingDef("FriendlyName", "Printer name", "General", pc, pcCap, ["ProductSettings", "FriendlyName"], "FriendlyName", .text),
        LedmSettingDef("DeviceLocation", "Location", "General", pc, pcCap, ["ProductSettings", "DeviceInformation", "DeviceLocation"], "DeviceLocation", .text),
        LedmSettingDef("PowerSaveTimeout", "Sleep after", "Power", pc, pcCap, ["ProductSettings", "PowerSaveTimeout"], "PowerSaveTimerSupport", .choice),
        LedmSettingDef("ShutDownDelay", "Turn off after", "Power", pc, pcCap, ["ProductSettings", "ShutDownDelay"], "ShutDownDelaySupport", .choice),
        LedmSettingDef("ShutDownDelayApply", "Delay turn-off while ports are active", "Power", pc, pcCap, ["ProductSettings", "ShutDownDelayApply"],
                       "ShutDownDelayApplySupport", .choice),
        LedmSettingDef("Duplex", "Print on both sides by default", "Printing", pc, pcCap, ["ProductSettings", "Duplex"], "DuplexSupport", .choice),
        LedmSettingDef("DuplexBindingOption", "Two-sided binding", "Printing", pc, pcCap, ["ProductSettings", "DuplexBindingOption"],
                       "DuplexBindingOptionSupport", .choice),
        LedmSettingDef("ManualFeed", "Manual feed", "Printing", pc, pcCap, ["ProductSettings", "ManualFeed"], "ManualFeedSupport", .choice),
        LedmSettingDef("DefaultPrintCopies", "Default copies", "Printing", pr, prCap, ["DefaultPrintCopies"], "DefaultPrintCopies", .integer),
        LedmSettingDef("AutoContinue", "Continue automatically after errors", "Printing", pr, prCap, ["AutoContinue"], "PrintOptionAutoContinueSupport", .choice),
        LedmSettingDef("MediaSizeName", "Tray paper size", "Paper", mh, mhCap, ["InputTray", "MediaSizeName"], "MediaSizeNameSupport", .choice,
                       keySiblings: ["InputBin"]),
        LedmSettingDef("MediaType", "Tray paper type", "Paper", mh, mhCap, ["InputTray", "MediaType"], "MediaTypeSupport", .choice, keySiblings: ["InputBin"]),
        LedmSettingDef("MediaOutActionType", "When paper runs out", "Paper", mh, mhCap, ["MediaHandlingInfo", "MediaOutActionType"],
                       "MediaOutActionTypeSupport", .choice),
    ]

    /// Settings present in `dyn` and marked readWrite in `cap`.
    public static func read(_ defs: some Sequence<LedmSettingDef>, dyn: XmlElement, cap: XmlElement?) -> [LedmSetting] {
        defs.compactMap { def in
            guard let leaf = find(dyn, def.path), let capEl = cap?.all(def.capElement).first else { return nil }
            if let access = capEl.attributes["access"], access != "readWrite" { return nil }
            var choices: [String] = []
            if def.kind == .choice {
                for v in capEl.children.map({ $0.value.trimmingCharacters(in: .whitespacesAndNewlines) }) where !v.isEmpty && !choices.contains(v) {
                    choices.append(v)
                }
                if choices.isEmpty { return nil }
            }
            return LedmSetting(def: def, value: leaf.value.trimmingCharacters(in: .whitespacesAndNewlines), choices: choices,
                               maxLength: capEl.attributes["length"].asInt, min: capEl.attributes["min"].asInt, max: capEl.attributes["max"].asInt)
        }
    }

    /// A minimal PUT body containing only the changed leaves (plus key siblings), reusing the exact element names and
    /// namespaces from the device's current document so firmware schema drift is harmless. Throws `LedmNotOffered` when a
    /// setting isn't in `dyn`.
    public static func buildPut(_ dyn: XmlElement, _ changes: [(def: LedmSettingDef, value: String)]) throws -> String {
        var root = LedmNode(like: dyn)
        for (def, value) in changes {
            var sources: [XmlElement] = []
            var node = dyn
            for name in def.path {
                guard let next = node.kid(name) else { throw LedmNotOffered(what: "\(def.key) on this printer") }
                sources.append(next)
                node = next
            }
            place(&root, sources[...], def: def, value: value)
        }
        return root.document()
    }

    /// Adds the path's next element under `parent` (once), with the key siblings beside the leaf, and sets the leaf.
    private static func place(_ parent: inout LedmNode, _ path: ArraySlice<XmlElement>, def: LedmSettingDef, value: String) {
        guard let source = path.first else { return }
        let i: Int
        if let found = parent.children.firstIndex(where: { $0.name == source.name && $0.namespace == source.namespace }) {
            i = found
        } else {
            var child = LedmNode(like: source)
            if path.count == 2 {
                for key in def.keySiblings { if let k = source.kid(key) { child.children.append(LedmNode(copy: k)) } }
            }
            parent.children.append(child)
            i = parent.children.count - 1
        }
        if path.count == 1 {
            parent.children[i].text = value
        } else {
            place(&parent.children[i], path.dropFirst(), def: def, value: value)
        }
    }

    private static func find(_ root: XmlElement, _ path: [String]) -> XmlElement? {
        var node = root
        for name in path {
            guard let next = node.kid(name) else { return nil }
            node = next
        }
        return node
    }
}

public enum SettingText {
    public static func display(_ key: String, _ value: String) -> String {
        switch value {
        case "enabled", "on", "true": return "On"
        case "disabled", "off", "false": return "Off"
        case "never": return "Never"
        case "longEdge": return "Long edge"
        case "shortEdge": return "Short edge"
        case "any": return "Any size"
        case "auto": return "Automatic"
        default: return key == "MediaSizeName" ? mediaSize(value) : duration(value) ?? LedmStatusText.humanize(value)
        }
    }

    /// "1minute", "15_minutes", "2hours" → "1 minute", "15 minutes", "2 hours".
    private static func duration(_ v: String) -> String? {
        let t = v.replacingOccurrences(of: "_", with: " ")
        let digits = t.prefix { $0.isASCII && $0.isNumber }
        guard !digits.isEmpty, digits.count < t.count else { return nil }
        let unit = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        return ["minute", "minutes", "hour", "hours", "second", "seconds"].contains(unit) ? "\(digits) \(unit)" : nil
    }

    /// PWG self-describing names: "na_letter_8.5x11in" → "Letter (8.5x11in)".
    private static func mediaSize(_ v: String) -> String {
        let parts = v.split(separator: "_", omittingEmptySubsequences: false).map(String.init)
        guard parts.count >= 3 else { return LedmStatusText.humanize(v) }
        var name = parts[1..<(parts.count - 1)].joined(separator: " ").replacingOccurrences(of: "-", with: " ")
        guard !name.isEmpty else { return "\(name) (\(parts[parts.count - 1]))" }
        name = name.count <= 3 && !name.contains("x") ? name.uppercased() : name.prefix(1).uppercased() + name.dropFirst()
        return "\(name) (\(parts[parts.count - 1]))"
    }
}

extension LedmClient {
    /// The Dyn and Cap resources the catalog reads, in its order.
    static let settingResources: [(dyn: String, cap: String)] = [
        (LedmResource.productConfigDyn, LedmResource.productConfigCap),
        (LedmResource.printConfigDyn, LedmResource.printConfigCap),
        (LedmResource.mediaHandlingDyn, LedmResource.mediaHandlingCap),
    ]

    /// The catalog's settings this printer has and lets apps change (a resource it doesn't list is skipped).
    public func settings(_ defs: [LedmSettingDef] = LedmSettingCatalog.all) async throws -> LedmSettings {
        var items: [LedmSetting] = []
        var documents: [String: XmlElement] = [:]
        for (dyn, cap) in Self.settingResources {
            let wanted = defs.filter { $0.dynResource == dyn }
            guard !wanted.isEmpty, let dynDoc = try await get(dyn) else { continue }
            documents[dyn] = dynDoc
            items += LedmSettingCatalog.read(wanted, dyn: dynDoc, cap: try await get(cap))
        }
        return LedmSettings(items: items, documents: documents)
    }

    /// Writes changed values: one PUT per Dyn resource, built from the documents `settings()` read. Read the settings again
    /// afterwards to show what the printer kept. Throws `LedmAuthRequiredError` when it wants the admin password.
    public func save(_ changes: [(def: LedmSettingDef, value: String)], over settings: LedmSettings) async throws {
        var order: [String] = []
        for c in changes where !order.contains(c.def.dynResource) { order.append(c.def.dynResource) }
        for resource in order {
            guard let dyn = settings.documents[resource] else { throw LedmNotOffered(what: resource) }
            try await put(resource, try LedmSettingCatalog.buildPut(dyn, changes.filter { $0.def.dynResource == resource }))
        }
    }
}
