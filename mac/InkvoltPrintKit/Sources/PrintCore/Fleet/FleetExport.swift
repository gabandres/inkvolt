import Foundation

/// The Fleet page's Pro export and `status --all --json`: a CSV (a row per supply) and JSON
/// (`print/schemas/fleet-status.schema.json`) of the list as it stands (the Windows app's `FleetExport`). Both can leave the
/// Mac, so every text goes through `Diagnostics.scrub` first: a name or a status string a printer filled with its serial
/// number, UUID, address or someone's e-mail doesn't carry them out. A firmware version stays. The CSV's cells can't run as
/// formulas (`CsvCell`); the JSON is plain ASCII, so no terminal's encoding spoils it, whatever the names are written in.
/// Times are written in `timeZone` (the Mac's), with its offset.
public enum FleetExport {
    static let columns = "Printer,Model,Kind,State,Status,Problems,Supply,Color,Level %,Supply state,Pages printed,Firmware,Last reading"

    /// Whether the Pro check lets the list be exported (`ProFeature.fleetExport`).
    public static var allowed: Bool { Pro.allows(.fleetExport) }

    public static func csv(_ printers: [FleetPrinter], _ now: Date, _ who: Diagnostics.Identity, timeZone: TimeZone = .current) -> String {
        var csv = columns + "\r\n"
        for printer in FleetOrder.sort(printers).map({ scrubbed($0, who) }) {
            let problems = printer.problems.joined(separator: "; ")
            // A printer with no supplies still has its row.
            let supplies: [FleetSupply?] = printer.supplies.isEmpty ? [nil] : printer.supplies
            for s in supplies {
                let cells = [CsvCell.of(printer.name), CsvCell.of(printer.model ?? ""), kindWord(printer.kind), troubleWord(printer.trouble),
                             CsvCell.of(printer.status), CsvCell.of(problems), CsvCell.of(s?.name ?? ""), CsvCell.of(s?.color ?? ""),
                             number(s?.level), CsvCell.of(s?.state ?? ""), number(printer.pages), CsvCell.of(printer.firmware ?? ""),
                             lastReading(printer, timeZone) ?? ""]
                csv += cells.joined(separator: ",") + "\r\n"
            }
        }
        return csv
    }

    public static func json(_ printers: [FleetPrinter], _ notes: [String], _ now: Date, _ who: Diagnostics.Identity, timeZone: TimeZone = .current) -> String {
        var j = AsciiJson()
        j.open("{")
        j.number("version", 1)
        j.string("generated", time(now, timeZone))
        j.open("[", key: "notes")
        for note in notes { j.string(nil, FleetText.clean(Diagnostics.scrub(note, who), FleetPrinter.maxText) ?? "") }
        j.close("]")
        j.open("[", key: "printers")
        for p in FleetOrder.sort(printers).map({ scrubbed($0, who) }) {
            j.open("{")
            j.string("name", p.name)
            j.string("model", p.model)
            j.string("kind", kindWord(p.kind))
            j.string("connection", p.connection)
            j.string("trouble", troubleWord(p.trouble))
            j.string("status", p.status)
            j.open("[", key: "problems")
            for problem in p.problems { j.string(nil, problem) }
            j.close("]")
            j.open("[", key: "supplies")
            for s in p.supplies {
                j.open("{")
                j.string("name", s.name)
                j.string("color", s.color)
                j.number("level", s.level)
                j.string("state", s.state)
                j.close("}")
            }
            j.close("]")
            j.number("pages", p.pages)
            j.string("firmware", p.firmware)
            j.string("lastReading", lastReading(p, timeZone))
            j.bool("lastKnown", p.lastKnown)
            j.close("}")
        }
        j.close("]")
        j.close("}")
        return j.text
    }

    public static func kindWord(_ kind: FleetKind) -> String {
        switch kind {
        case .network: "network"
        case .queue: "queue"
        case .scanner: "scanner"
        }
    }

    public static func troubleWord(_ trouble: FleetTrouble) -> String {
        switch trouble {
        case .error: "error"
        case .warning: "warning"
        case .offline: "offline"
        case .unknown: "unknown"
        case .ok: "ok"
        }
    }

    private static func number(_ n: Int?) -> String { n.map(String.init) ?? "" }

    /// yyyy-MM-ddTHH:mm:ss and the offset (+00:00, never Z), to the second.
    static func time(_ t: Date, _ timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: t)
        let offset = timeZone.secondsFromGMT(for: t)
        let sign = offset < 0 ? "-" : "+"
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
            + sign + String(format: "%02d:%02d", abs(offset) / 3600, abs(offset) % 3600 / 60)
    }

    private static func lastReading(_ p: FleetPrinter, _ timeZone: TimeZone) -> String? {
        if let time = p.lastReading { return self.time(time, timeZone) }
        return p.lastReadingDay?.description
    }

    /// The entry as it may leave the Mac.
    static func scrubbed(_ p: FleetPrinter, _ who: Diagnostics.Identity) -> FleetPrinter {
        var s = p
        s.name = text(p.connection == FleetConnection.shared ? sharedName(p.name) : p.name, who) ?? "Printer with no name"
        s.model = text(p.model, who)
        s.connection = text(p.connection, who)
        s.status = text(p.status, who) ?? "Status not available"
        s.problems = p.problems.compactMap { text($0, who) }
        s.supplies = p.supplies.map { supply in
            var out = supply
            out.name = text(supply.name, who) ?? "Supply"
            out.color = supply.color.flatMap { FleetText.clean(Diagnostics.scrub($0, who), 24) }
            out.state = FleetText.clean(Diagnostics.scrub(supply.state, who), 24) ?? "unknown"
            return out
        }
        s.firmware = firmwareText(p.firmware, who)
        return s
    }

    /// A shared queue's name ends in the computer sharing it: "Reception on FRONTDESK" (Windows' way) or "Reception @ Front
    /// Desk" (macOS's), the other computer's name made "[pc]".
    private static func sharedName(_ name: String) -> String {
        let ns = name as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = sharedOn.firstMatch(in: name, range: all) ?? sharedAt.firstMatch(in: name, range: all) {
            return ns.substring(with: m.range(at: 1)) + " on [pc]"
        }
        return name
    }

    private static let sharedOn = try! NSRegularExpression(pattern: #"^(.+) on \S+$"#)
    private static let sharedAt = try! NSRegularExpression(pattern: #"^(.+) @ .+$"#)

    private static func text(_ text: String?, _ who: Diagnostics.Identity) -> String? {
        text.flatMap { FleetText.clean(Diagnostics.scrub($0, who), FleetPrinter.maxText) }
    }

    /// A firmware version looks like a serial number or an address to the scrubber, which keeps it after the words
    /// "Firmware version".
    private static func firmwareText(_ firmware: String?, _ who: Diagnostics.Identity) -> String? {
        guard let firmware else { return nil }
        let label = "Firmware version "
        let scrubbed = Diagnostics.scrub(label + firmware, who)
        return FleetText.clean(scrubbed.hasPrefix(label) ? String(scrubbed.dropFirst(label.count)) : scrubbed, FleetPrinter.maxText)
    }
}

/// An indented JSON writer whose output is ASCII: everything past it as \uXXXX, and what HTML would read (<, >, &, ', +)
/// escaped too, as .NET's default JSON encoder does.
struct AsciiJson {
    private(set) var text = ""
    private var depth = 0
    private var first = true

    private mutating func item(_ key: String?) {
        if !first { text += "," }
        first = false
        text += "\n" + String(repeating: "  ", count: depth)
        if let key { text += Self.quoted(key) + ": " }
    }

    mutating func open(_ bracket: String, key: String? = nil) {
        if depth > 0 || !text.isEmpty { item(key) }
        text += bracket
        depth += 1
        first = true
    }

    mutating func close(_ bracket: String) {
        depth -= 1
        if !first { text += "\n" + String(repeating: "  ", count: depth) }
        text += bracket
        first = false
    }

    mutating func string(_ key: String?, _ value: String?) {
        item(key)
        text += value.map(Self.quoted) ?? "null"
    }

    mutating func number(_ key: String, _ value: Int?) {
        item(key)
        text += value.map(String.init) ?? "null"
    }

    mutating func bool(_ key: String, _ value: Bool) {
        item(key)
        text += value ? "true" : "false"
    }

    static func quoted(_ s: String) -> String {
        var out = "\""
        for unit in s.utf16 {
            switch unit {
            case 0x22: out += "\\\""
            case 0x5C: out += "\\\\"
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x20..<0x7F where ![0x3C, 0x3E, 0x26, 0x27, 0x2B, 0x60].contains(unit):
                out.unicodeScalars.append(Unicode.Scalar(UInt8(unit)))
            default: out += String(format: "\\u%04X", unit)
            }
        }
        return out + "\""
    }
}
