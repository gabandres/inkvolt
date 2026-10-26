import Foundation

/// What the printer does about new HP firmware.
public enum FirmwareUpdateMode: Sendable, CaseIterable {
    /// Never checks.
    case off
    /// Checks and reports an available update; nothing installs until someone installs it.
    case notify
    /// Checks and installs updates by itself.
    case automatic
}

/// How a firmware update mode write turned out, from the printer's read-back.
public enum FirmwareUpdateWriteResult: Sendable {
    /// The printer reads back the mode written.
    case kept
    /// Notify was written and the printer reads back Automatic: it ties the check to installs.
    case notifyInstalls
    /// The printer reads back some other mode.
    case other
}

/// HP LEDM web firmware update (`FirmwareUpdate` interface, found through its manifest): the automatic check and automatic
/// update switches, read from `FirmwareUpdateDyn` and offered only as far as `FirmwareUpdateCap` marks them writable.
/// `configPath` is where a change is PUT (`/FirmwareUpdate/WebFWUpdate/Config`). `checkWritable`: the printer has an automatic
/// check switch and lets us write it (a change never writes a read-only one).
public struct FirmwareUpdateSettings: Equatable, Sendable {
    public static let webClass = "WebFWUpdate"

    public var mode: FirmwareUpdateMode
    public var choices: [FirmwareUpdateMode]
    public var status: String?
    public var configPath: String?
    /// The namespace of the printer's Config element; a change is written in it.
    public var namespace: String
    public var checkWritable: Bool

    public init(mode: FirmwareUpdateMode, choices: [FirmwareUpdateMode], status: String?, configPath: String?, namespace: String,
                checkWritable: Bool) {
        self.mode = mode
        self.choices = choices
        self.status = status
        self.configPath = configPath
        self.namespace = namespace
        self.checkWritable = checkWritable
    }

    public var canChange: Bool { choices.count > 1 && configPath != nil }

    /// Nil when the printer has no web firmware update settings.
    public static func parse(_ dyn: XmlElement, cap: XmlElement?, configPath: String?) -> FirmwareUpdateSettings? {
        guard let fw = pick(dyn), let config = fw.kid("Config") else { return nil }
        let check = config.kidValue("AutomaticCheck")
        let update = config.kidValue("AutomaticUpdate")
        if check == nil && update == nil { return nil }
        let mode: FirmwareUpdateMode = update == "enabled" ? .automatic : check == "enabled" ? .notify : .off

        // Choices: the switches the Cap lets us flip both ways. Updating needs checking, so Notify needs both.
        let capConfig = cap.flatMap(pick)?.kid("ConfigSupport")
        let updateWritable = update != nil && writable(capConfig?.kid("AutomaticUpdateSupport"))
        let checkWritable = check != nil && writable(capConfig?.kid("AutomaticCheckSupport"))
        var choices: [FirmwareUpdateMode] = []
        if updateWritable {
            choices.append(.automatic)
            if checkWritable { choices.append(.notify) }
            choices.append(.off)
        }
        return FirmwareUpdateSettings(mode: mode, choices: choices, status: fw.kid("State")?.kidValue("Status"), configPath: configPath,
                                      namespace: config.namespace, checkWritable: checkWritable)
    }

    /// These settings without Notify: for a printer that doesn't keep it (enabling only the check turns on automatic
    /// installs too, as the LaserJet MFP M234dw does: it reads back `AutomaticUpdate` enabled).
    public func withoutNotify() -> FirmwareUpdateSettings {
        guard choices.contains(.notify) else { return self }
        var copy = self
        copy.choices = choices.filter { $0 != .notify }
        return copy
    }

    /// Printers known not to keep Notify, by model: the LaserJet MFP M232–M237 series (one firmware for the series; the
    /// M234dw was seen turning installs on). Others are learned the first time a Notify write reads back as Automatic.
    public static func knownNotToKeepNotify(_ model: String?) -> Bool {
        guard let model else { return false }
        return model.range(of: #"\bLaserJet\s+MFP\s+M23[2-7]"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What the printer did with a written `chosen` mode, judged from its read-back.
    public static func judge(_ chosen: FirmwareUpdateMode, _ readBack: FirmwareUpdateMode) -> FirmwareUpdateWriteResult {
        readBack == chosen ? .kept : chosen == .notify && readBack == .automatic ? .notifyInstalls : .other
    }

    /// The `FirmwareUpdateConfig` document for `mode`, in the printer's own namespace: only the switches the Cap marks
    /// writable (a printer may refuse the whole PUT over one read-only element).
    public func buildPut(_ mode: FirmwareUpdateMode) -> String {
        let (check, update) = switch mode {
        case .automatic: ("enabled", "enabled")
        case .notify: ("enabled", "disabled")
        case .off: ("disabled", "disabled")
        }
        var root = LedmNode("FirmwareUpdateConfig", namespace: namespace, prefix: "fwudyn")
        if checkWritable { root.children.append(LedmNode("AutomaticCheck", namespace: namespace, prefix: "fwudyn", text: check)) }
        root.children.append(LedmNode("AutomaticUpdate", namespace: namespace, prefix: "fwudyn", text: update))
        return root.document()
    }

    /// The update state in words, or nil when there is nothing to say (idle).
    public var statusMessage: String? {
        switch status {
        case nil, "idle": nil
        case "available": "A firmware update is available."
        case "notAvailable": "The firmware is up to date."
        case "checkFailed": "The printer's last update check failed."
        case "checking": "Checking for updates…"
        case "downloadPreparation", "downloading": "Downloading an update…"
        case "installing": "Installing an update…"
        case "cancelling": "Cancelling the update…"
        case let other?: LedmStatusText.humanize(other)
        }
    }

    /// Where the web update's Config is PUT: the `FirmwareUpdateConfig` under the manifest's `/WebFWUpdate` node (a printer
    /// may list several update classes, each with its own Config), else the first one listed.
    public static func configPath(in manifest: [(type: String, path: String)]) -> String? {
        let configs = manifest.filter { $0.type == "FirmwareUpdateConfig" }.map(\.path)
        return configs.first { p in
            let parts = p.split(separator: "/")
            return parts.count >= 2 && parts[parts.count - 2] == webClass
        } ?? configs.first
    }

    /// The web-update entry (a printer may list several update classes), else the first.
    private static func pick(_ root: XmlElement) -> XmlElement? {
        let all = root.all("FirmwareUpdate").filter { $0.kid("Class") != nil }
        return all.first { $0.kidValue("Class") == webClass } ?? all.first
            ?? (root.kid("Config") != nil ? root : nil) // the bare /WebFWUpdate resource
    }

    private static func writable(_ support: XmlElement?) -> Bool {
        guard let support else { return false }
        if let access = support.attributes["access"], access != "readWrite" { return false }
        let values = Set(support.children.map { $0.value.trimmingCharacters(in: .whitespacesAndNewlines) })
        return values.contains("enabled") && values.contains("disabled")
    }
}

extension LedmClient {
    /// Web firmware update settings, via the FirmwareUpdate manifest the DiscoveryTree points to. Nil when the printer
    /// doesn't expose them (then only its firmware version is known).
    public func firmwareUpdate() async throws -> FirmwareUpdateSettings? {
        guard let manifestPath = try await tree()?.manifest(for: LedmResource.firmwareUpdateManifest),
              let manifest = try await get(path: manifestPath) else { return nil }
        let entries = LedmManifest.entries(manifest)
        let map = LedmManifest.parse(manifest)
        guard let dynPath = map["FirmwareUpdateDyn"], let dyn = try await get(path: dynPath) else { return nil }
        var cap: XmlElement?
        if let capPath = map["FirmwareUpdateCap"] { cap = try await get(path: capPath) }
        return FirmwareUpdateSettings.parse(dyn, cap: cap, configPath: FirmwareUpdateSettings.configPath(in: entries))
    }

    /// Writes `mode` to the printer's Config (`settings.configPath`). Read `firmwareUpdate()` back and `judge` it: a printer
    /// may store something else. Throws `LedmAuthRequiredError` when it wants the admin password.
    public func setFirmwareUpdate(_ mode: FirmwareUpdateMode, in settings: FirmwareUpdateSettings) async throws {
        guard let path = settings.configPath else { throw LedmNotOffered(what: "a firmware update configuration") }
        try await put(path: path, settings.buildPut(mode))
    }
}
