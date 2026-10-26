import Foundation

/// A CUPS destination as libcups lists it (`cupsGetDests2`): its queue name and the options cupsd sent with it
/// (`printer-info`, `device-uri`, `printer-state`, `printer-state-reasons`, `marker-*`…). The Mac's print queue: what the
/// Windows app's `SpoolerQueue` is there.
public struct CupsDestination: Equatable, Sendable {
    /// The queue's name (`printer-name`): ASCII, no spaces; CUPS compares it without regard to case.
    public var name: String
    public var options: [String: String]
    /// Jobs waiting in the queue (not one of the destination's options; read with the jobs, nil when not read).
    public var jobs: Int?

    public init(name: String, options: [String: String], jobs: Int? = nil) {
        self.name = name
        self.options = options
        self.jobs = jobs
    }

    /// `printer-type` bits (cups.h `cups_ptype_e`).
    public enum TypeBit {
        public static let `class` = 0x1, remote = 0x2, fax = 0x40000, rejecting = 0x80000, discovered = 0x100_0000,
            scanner = 0x200_0000, mfp = 0x400_0000
    }

    /// The name people see: `printer-info` (what Printers & Scanners shows, and what renaming there changes), else the
    /// queue's name with its underscores as spaces.
    public var displayName: String {
        if let info = options["printer-info"]?.trimmingCharacters(in: .whitespacesAndNewlines), !info.isEmpty { return info }
        return name.replacingOccurrences(of: "_", with: " ")
    }

    public var deviceUri: String? { options["device-uri"] }
    public var makeAndModel: String? { options["printer-make-and-model"] }
    public var location: String? { options["printer-location"].flatMap { $0.isEmpty ? nil : $0 } }
    public var type: Int { options["printer-type"].flatMap { Int($0) } ?? 0 }
    public func has(_ bit: Int) -> Bool { type & bit != 0 }

    /// A destination macOS sees on the network (Bonjour) but nobody set up: CUPS lists it until it's used. Not a queue.
    public var isTemporary: Bool { options["printer-is-temporary"] == "true" || has(TypeBit.discovered) }

    /// 3 idle, 4 processing, 5 stopped (RFC 8011 `printer-state`).
    public var state: Int? { options["printer-state"].flatMap { Int($0) } }
    public var reasons: [String] { Self.list(options["printer-state-reasons"]) }
    public var isAcceptingJobs: Bool { options["printer-is-accepting-jobs"] != "false" && !has(TypeBit.rejecting) }

    /// The options as the IPP attributes they came from, so the network printers' IPP readers word their status and supplies.
    public var asIpp: IppResponse {
        var a: [String: [IppAttributeValue]] = [:]
        for key in ["printer-state", "printer-state-change-time"] { if let n = options[key].flatMap({ Int($0) }) { a[key] = [.integer(n)] } }
        for key in ["marker-levels", "marker-low-levels", "marker-high-levels"] {
            if let v = options[key] { a[key] = Self.list(v).compactMap { Int($0) }.map { .integer($0) } }
        }
        for key in ["printer-state-reasons", "marker-names", "marker-types", "marker-colors"] {
            if let v = options[key] { a[key] = Self.list(v).map { .text($0) } }
        }
        for key in ["printer-state-message", "printer-make-and-model", "printer-location", "printer-info"] {
            if let v = options[key] { a[key] = [.text(v)] }
        }
        return IppResponse(statusCode: 0, attributes: a)
    }

    /// A list option's values: CUPS joins them with commas, a comma, quote or backslash inside a value escaped with a
    /// backslash (`cups_make_string`); a value in quotes is taken whole.
    public static func list(_ text: String?) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        var values: [String] = []
        var current = ""
        var escaped = false, quoted: Character?
        for c in text {
            if escaped {
                current.append(c)
                escaped = false
            } else if c == "\\" {
                escaped = true
            } else if let q = quoted {
                if c == q { quoted = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quoted = c
            } else if c == "," {
                values.append(current)
                current = ""
            } else {
                current.append(c)
            }
        }
        values.append(current)
        return values
    }
}
