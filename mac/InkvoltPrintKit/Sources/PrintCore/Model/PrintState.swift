import Foundation
import Synchronization

/// A remembered network printer: found on the network or added by address, so the app connects at once on the next start
/// instead of waiting for discovery.
public struct KnownPrinter: Equatable, Sendable, Codable {
    public var uuid: String
    public var name: String
    public var model: String?
    public var host: String
    public var esclRoot: String?
    /// The IPP URL the printer answered on last time (DNS-SD `rp`, IPPS), tried first on the next start.
    public var ippUri: String?
    /// Set for a printer that answered only SNMP when it was added: what it said about itself. Only these are read over SNMP.
    public var snmp: SnmpDevice?

    public init(uuid: String, name: String, model: String? = nil, host: String, esclRoot: String? = nil, ippUri: String? = nil,
                snmp: SnmpDevice? = nil) {
        self.uuid = uuid
        self.name = name
        self.model = model
        self.host = host
        self.esclRoot = esclRoot
        self.ippUri = ippUri
        self.snmp = snmp
    }

    /// Where the printer session reaches it.
    public var target: PrinterWhere {
        PrinterWhere(host, esclHint: esclRoot.flatMap { URL(string: $0) }, ippHint: ippUri.flatMap { URL(string: $0) }, snmp: snmp)
    }
}

/// What the app remembers between runs (the Windows app's `AppState`, the parts the Mac app has so far). Ids compare
/// without regard to case.
public struct PrintState: Equatable, Sendable, Codable {
    public var printers: [KnownPrinter] = []
    public var selectedUuid: String?
    /// `CertificatePinKey` → SHA-256 of the printer's TLS certificate (trust on first use).
    public var certificatePins: [String: String] = [:]
    /// Printer id → other UUIDs the user confirmed are that printer ("This is my printer").
    public var acceptedUuids: [String: [String]] = [:]
    /// Printers the user removed; discovery doesn't add them back.
    public var forgottenUuids: [String] = []
    /// The menu bar's alerts already shown, per printer (`AlertTracker.shown`).
    public var shownAlerts: [String: [String]] = [:]
    /// The menu bar item and its alerts, as the user set them.
    public var alertSettings = AlertSettings()
    /// The scan presets, as the Windows app stores them (its JSON field names, so the apps read each other's).
    public var scanPresets: ScanPresetSettings?
    /// Preset id → the folder its scans go to, as an app-scoped security bookmark (the sandbox writes only where the user
    /// pointed).
    public var presetFolders: [String: Data] = [:]
    /// Printers seen turning on automatic installs when only the update check was asked for: Notify isn't offered again.
    public var noFirmwareNotify: [String] = []

    public init() {}

    public init(from decoder: any Decoder) throws {
        // Every field optional, so a file from an older or newer version still loads.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        printers = try c.decodeIfPresent([KnownPrinter].self, forKey: .printers) ?? []
        selectedUuid = try c.decodeIfPresent(String.self, forKey: .selectedUuid)
        certificatePins = try c.decodeIfPresent([String: String].self, forKey: .certificatePins) ?? [:]
        acceptedUuids = try c.decodeIfPresent([String: [String]].self, forKey: .acceptedUuids) ?? [:]
        forgottenUuids = try c.decodeIfPresent([String].self, forKey: .forgottenUuids) ?? []
        shownAlerts = try c.decodeIfPresent([String: [String]].self, forKey: .shownAlerts) ?? [:]
        alertSettings = try c.decodeIfPresent(AlertSettings.self, forKey: .alertSettings) ?? AlertSettings()
        scanPresets = try? c.decodeIfPresent(ScanPresetSettings.self, forKey: .scanPresets)
        presetFolders = (try? c.decodeIfPresent([String: Data].self, forKey: .presetFolders)) ?? [:]
        noFirmwareNotify = try c.decodeIfPresent([String].self, forKey: .noFirmwareNotify) ?? []
    }
}

/// The state, shared by the app and the TLS handshakes that store certificate pins (from any thread), and its file: saved
/// whole, atomically, after each change. In memory only when there's no file (demo mode).
public final class StateStore: Sendable {
    private let state: Mutex<PrintState>
    private let file: URL?

    /// Loads `file`; a missing or unreadable file starts empty (an unreadable one is kept aside as `.bad`).
    public init(file: URL?) {
        self.file = file
        var loaded = PrintState()
        if let file, let data = try? Data(contentsOf: file) {
            if let state = try? JSONDecoder().decode(PrintState.self, from: data) {
                loaded = state
            } else {
                try? FileManager.default.removeItem(at: file.appendingPathExtension("bad"))
                try? FileManager.default.moveItem(at: file, to: file.appendingPathExtension("bad"))
            }
        }
        state = Mutex(loaded)
    }

    /// In memory only, starting from `state`.
    public init(memory state: PrintState) {
        file = nil
        self.state = Mutex(state)
    }

    public var isInMemory: Bool { file == nil }

    public var current: PrintState { state.withLock { $0 } }

    public func read<T: Sendable>(_ body: (PrintState) -> T) -> T { state.withLock { body($0) } }

    /// Changes the state and saves it when it changed.
    @discardableResult
    public func change<T: Sendable>(_ body: (inout PrintState) -> T) -> T {
        let (result, data): (T, Data?) = state.withLock { s in
            let before = s
            let result = body(&s)
            return (result, s == before ? nil : encode(s))
        }
        if let data, let file { write(data, to: file) }
        return result
    }

    private func encode(_ s: PrintState) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try? encoder.encode(s)
    }

    // Two saves may race; each writes a whole state, so the file is always one of them (the next change writes the latest).
    private func write(_ data: Data, to file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    // MARK: Printers

    /// Remembers a printer, replacing what was remembered under its id.
    public func remember(_ printer: KnownPrinter) {
        change { s in
            if let i = s.printers.firstIndex(where: { same($0.uuid, printer.uuid) }) {
                s.printers[i] = printer
            } else {
                s.printers.append(printer)
            }
        }
    }

    /// Forgets the printer and hides it from discovery.
    public func remove(_ id: String) {
        change { s in
            s.printers.removeAll { same($0.uuid, id) }
            if !s.forgottenUuids.contains(where: { same($0, id) }) { s.forgottenUuids.append(id) }
            if s.selectedUuid.map({ same($0, id) }) == true { s.selectedUuid = nil }
        }
    }

    public func isForgotten(_ id: String) -> Bool { read { $0.forgottenUuids.contains { same($0, id) } } }

    /// Added again by address: discovery may list it again.
    public func unforget(_ id: String) { change { $0.forgottenUuids.removeAll { same($0, id) } } }

    public func accepted(_ id: String) -> [String] { read { s in s.acceptedUuids.first { same($0.key, id) }?.value ?? [] } }

    public func accept(_ id: String, _ uuids: [String]) {
        change { s in
            let key = s.acceptedUuids.keys.first { same($0, id) } ?? id
            var list = s.acceptedUuids[key] ?? []
            for u in uuids where !list.contains(where: { same($0, u) }) { list.append(u) }
            s.acceptedUuids[key] = list
        }
    }

    // MARK: Firmware

    /// False once the printer read back automatic installs after Notify was written.
    public func keepsFirmwareNotify(_ id: String) -> Bool { read { !$0.noFirmwareNotify.contains { same($0, id) } } }

    public func setNoFirmwareNotify(_ id: String) {
        change { s in if !s.noFirmwareNotify.contains(where: { same($0, id) }) { s.noFirmwareNotify.append(id) } }
    }

    // MARK: Certificate pins

    /// The printer's pins, for its connections (`PrinterRecipe.pin`).
    public func pins(_ id: String) -> any CertificatePin { Pins(store: self, id: id) }

    public func pin(_ id: String, port: Int) -> String? {
        let key = CertificatePinKey.key(id, port: port)
        return read { s in s.certificatePins.first { same($0.key, key) }?.value }
    }

    /// Never overwrites a pin; returns the one stored.
    public func setPinIfAbsent(_ id: String, port: Int, _ sha256Hex: String) -> String {
        let key = CertificatePinKey.key(id, port: port)
        return change { s in
            if let stored = s.certificatePins.first(where: { same($0.key, key) })?.value { return stored }
            s.certificatePins[key] = sha256Hex
            return sha256Hex
        }
    }

    /// Forgets every pin of the printer (all ports): the user chose to trust its new certificate.
    public func clearPins(_ id: String) {
        change { s in
            for key in s.certificatePins.keys where CertificatePinKey.belongs(key, to: id) { s.certificatePins[key] = nil }
        }
    }

    private struct Pins: CertificatePin {
        let store: StateStore
        let id: String
        func get(_ port: Int) -> String? { store.pin(id, port: port) }
        func setIfAbsent(_ port: Int, _ sha256Hex: String) -> String { store.setPinIfAbsent(id, port: port, sha256Hex) }
    }
}

private func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
