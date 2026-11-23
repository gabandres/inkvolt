import Foundation

/// A reply that isn't the IPP it should be: too short, or a value running past the end.
public struct IppFormatError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// One decoded attribute value: text (every string syntax, and `printer-alert`'s octetString), a number, a boolean, a
/// dateTime, a collection, or the raw bytes of a syntax Inkvolt Print doesn't read.
public enum IppAttributeValue: Equatable, Sendable {
    case text(String)
    case integer(Int)
    case boolean(Bool)
    case bytes([UInt8])
    /// A dateTime (RFC 8010 §3.9) as the instant it names.
    case date(Date)
    case collection(IppCollection)
}

/// A collection value (RFC 8010 §3.1.6): its members by name, each with one or more values (as `IppResponse`'s).
public struct IppCollection: Equatable, Sendable {
    /// Most members kept in one collection: a real one has a dozen.
    public static let maxMembers = 256

    public private(set) var members: [String: [IppAttributeValue]] = [:]

    public init() {}

    mutating func add(_ member: String, _ value: IppAttributeValue) {
        if members[member] == nil {
            if members.count >= Self.maxMembers { return }
            members[member] = []
        }
        if members[member]!.count < Self.maxMembers { members[member]!.append(value) }
    }

    public func str(_ name: String) -> String? {
        if case .text(let s)? = members[name]?.first { return s }
        return nil
    }

    public func int(_ name: String) -> Int? {
        if case .integer(let i)? = members[name]?.first { return i }
        return nil
    }

    public func collection(_ name: String) -> IppCollection? {
        if case .collection(let c)? = members[name]?.first { return c }
        return nil
    }

    public func has(_ name: String) -> Bool { members[name] != nil }
}

public struct IppResponse: Equatable, Sendable {
    public let statusCode: UInt16
    public let attributes: [String: [IppAttributeValue]]

    public init(statusCode: UInt16, attributes: [String: [IppAttributeValue]]) {
        self.statusCode = statusCode
        self.attributes = attributes
    }

    public var ok: Bool { statusCode < 0x0100 }

    public func str(_ name: String) -> String? { strs(name).first }
    public func int(_ name: String) -> Int? {
        if case .integer(let i)? = attributes[name]?.first { return i }
        return nil
    }

    public func strs(_ name: String) -> [String] {
        (attributes[name] ?? []).compactMap { if case .text(let s) = $0 { s } else { nil } }
    }

    public func ints(_ name: String) -> [Int] {
        (attributes[name] ?? []).compactMap { if case .integer(let i) = $0 { i } else { nil } }
    }

    public func collections(_ name: String) -> [IppCollection] {
        (attributes[name] ?? []).compactMap { if case .collection(let c) = $0 { c } else { nil } }
    }
}

/// Minimal IPP encoding (RFC 8010): enough for Get-Printer-Attributes and Identify-Printer.
public enum IppCodec {
    public static let getPrinterAttributes: UInt16 = 0x000B

    /// PWG 5100.13 §4.1 (IPP Job and Printer Extensions, Set 3): the printer shows where it is (lights, sound, panel).
    public static let identifyPrinter: UInt16 = 0x003C

    static let operationTag: UInt8 = 0x01, printerTag: UInt8 = 0x04, endTag: UInt8 = 0x03
    static let integer: UInt8 = 0x21, boolean: UInt8 = 0x22, enumeration: UInt8 = 0x23, octetString: UInt8 = 0x30, resolution: UInt8 = 0x32
    static let rangeOfInteger: UInt8 = 0x33, dateTime: UInt8 = 0x31
    static let begCollection: UInt8 = 0x34, endCollection: UInt8 = 0x37, memberAttrName: UInt8 = 0x4A

    /// Most collections nested in one another (media-col-database's media-size is two deep).
    public static let maxCollectionDepth = 8
    static let charset: UInt8 = 0x47, naturalLanguage: UInt8 = 0x48, uri: UInt8 = 0x45, keyword: UInt8 = 0x44, name: UInt8 = 0x42

    public static func encodeGetPrinterAttributes(_ printerUri: String, _ requested: [String], requestId: Int32 = 1) -> [UInt8] {
        var b = header(version: (1, 1), getPrinterAttributes, requestId)
        b.append(operationTag)
        writeAttribute(&b, charset, "attributes-charset", "utf-8")
        writeAttribute(&b, naturalLanguage, "attributes-natural-language", "en")
        writeAttribute(&b, uri, "printer-uri", printerUri)
        for (i, r) in requested.enumerated() { writeAttribute(&b, keyword, i == 0 ? "requested-attributes" : "", r) }
        b.append(endTag)
        return b
    }

    /// An Identify-Printer request (PWG 5100.13 §4.1.1): the operation attributes in the order the spec lists them,
    /// `requesting-user-name` when given (SHOULD) and `identify-actions` when any are chosen (the printer's
    /// `identify-actions-default` otherwise). Sent as IPP/2.0: JPS3 extends IPP/2.0, which IPP Everywhere printers support.
    public static func encodeIdentifyPrinter(_ printerUri: String, userName: String?, actions: [String], requestId: Int32 = 1) -> [UInt8] {
        var b = header(version: (2, 0), identifyPrinter, requestId)
        b.append(operationTag)
        writeAttribute(&b, charset, "attributes-charset", "utf-8")
        writeAttribute(&b, naturalLanguage, "attributes-natural-language", "en")
        writeAttribute(&b, uri, "printer-uri", printerUri)
        if let userName, !userName.isEmpty { writeAttribute(&b, name, "requesting-user-name", userName) }
        for (i, a) in actions.enumerated() { writeAttribute(&b, keyword, i == 0 ? "identify-actions" : "", a) }
        b.append(endTag)
        return b
    }

    /// Decodes the printer-attributes group, collections included (RFC 8010 §3.1.6: begCollection, memberAttrName and its
    /// value, endCollection). A truncated or corrupt reply, a collection nested deeper than `maxCollectionDepth` or one left
    /// open is an `IppFormatError`, never a crash.
    public static func decode(_ b: [UInt8]) throws -> IppResponse {
        guard b.count >= 9 else { throw IppFormatError("IPP response too short") }
        let status = UInt16(b[2]) << 8 | UInt16(b[3])
        var attributes: [String: [IppAttributeValue]] = [:]
        var i = 8
        var last: String?
        var group: UInt8 = 0
        // The collections open around the value being read: each one so far, and its current member's name.
        var open: [(collection: IppCollection, member: String?)] = []
        func add(_ value: IppAttributeValue) {
            if !open.isEmpty {
                if let member = open[open.count - 1].member { open[open.count - 1].collection.add(member, value) }
                return
            }
            guard let last, group == printerTag else { return }
            attributes[last, default: []].append(value)
        }
        while i < b.count {
            let tag = b[i]
            i += 1
            if tag == endTag { break }
            if tag < 0x10 {
                if !open.isEmpty { throw IppFormatError("IPP collection not closed") }
                group = tag
                last = nil
                continue
            }
            let truncated = IppFormatError("IPP response truncated")
            guard i + 2 <= b.count else { throw truncated }
            let nameLength = Int(b[i]) << 8 | Int(b[i + 1])
            i += 2
            guard i + nameLength + 2 <= b.count else { throw truncated }
            let name = String(decoding: b[i..<i + nameLength], as: UTF8.self)
            i += nameLength
            let valueLength = Int(b[i]) << 8 | Int(b[i + 1])
            i += 2
            guard i + valueLength <= b.count else { throw truncated }
            let value = Array(b[i..<i + valueLength])
            i += valueLength
            if open.isEmpty && nameLength > 0 { last = name }
            if !open.isEmpty && tag == memberAttrName {
                open[open.count - 1].member = String(decoding: value, as: UTF8.self)
                continue
            }
            if tag == endCollection {
                guard let done = open.popLast() else { throw IppFormatError("IPP collection closed twice") }
                add(.collection(done.collection))
                continue
            }
            if tag == begCollection {
                if open.count >= maxCollectionDepth { throw IppFormatError("IPP collections nested too deep") }
                open.append((IppCollection(), nil))
                continue
            }
            let decoded: IppAttributeValue
            switch tag {
            case integer where valueLength == 4, enumeration where valueLength == 4:
                decoded = .integer(Int(Int32(bitPattern: UInt32(value[0]) << 24 | UInt32(value[1]) << 16 | UInt32(value[2]) << 8 | UInt32(value[3]))))
            case boolean where valueLength == 1:
                decoded = .boolean(value[0] != 0)
            case 0x40...0x4F, octetString:
                // printer-alert (PWG 5100.9) is an octetString of US-ASCII "code=…;severity=…" text.
                decoded = .text(String(decoding: value, as: UTF8.self))
            case dateTime where valueLength == 11:
                decoded = readDateTime(value).map(IppAttributeValue.date) ?? .bytes(value)
            default:
                decoded = .bytes(value)
            }
            add(decoded)
        }
        if !open.isEmpty { throw IppFormatError("IPP collection not closed") }
        return IppResponse(statusCode: status, attributes: attributes)
    }

    /// RFC 2579 DateAndTime (RFC 8010 §3.9): year, month, day, hour, minutes, seconds, deciseconds, UTC direction, hours,
    /// minutes. Nil for anything that isn't a real time (a printer's clock is hostile input): a year outside 1970-9998, a day
    /// past its month's end, an offset past ±13:59. A leap second counts as second 59, as .NET's DateTimeOffset holds it.
    static func readDateTime(_ v: [UInt8]) -> Date? {
        guard v.count == 11 else { return nil }
        let year = Int(v[0]) << 8 | Int(v[1]), month = Int(v[2]), day = Int(v[3]), hour = Int(v[4]), minute = Int(v[5]), second = Int(v[6])
        guard (1970...9998).contains(year), (1...12).contains(month), day >= 1, day <= daysIn(month, year), hour <= 23, minute <= 59,
              second <= 60, v[9] <= 13, v[10] <= 59, v[8] == UInt8(ascii: "+") || v[8] == UInt8(ascii: "-") else { return nil }
        let sign = v[8] == UInt8(ascii: "-") ? -1 : 1
        let offset = sign * (Int(v[9]) * 60 + Int(v[10])) * 60
        guard let zone = TimeZone(secondsFromGMT: offset) else { return nil }
        var c = DateComponents()
        (c.year, c.month, c.day, c.hour, c.minute, c.second) = (year, month, day, hour, minute, min(second, 59))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: c)
    }

    private static func daysIn(_ month: Int, _ year: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Operation id and request id of an IPP request (for the fixture server).
    public static func readRequestHeader(_ b: [UInt8]) throws -> (operation: UInt16, requestId: Int32) {
        guard b.count >= 8 else { throw IppFormatError("IPP request too short") }
        let operation = UInt16(b[2]) << 8 | UInt16(b[3])
        let id = Int32(bitPattern: UInt32(b[4]) << 24 | UInt32(b[5]) << 16 | UInt32(b[6]) << 8 | UInt32(b[7]))
        return (operation, id)
    }

    /// A Get-Printer-Attributes response carrying `printerAttributes` (consecutive values with the same name form one
    /// multi-valued attribute). Demo mode and tests serve printers written in `IppText` with it.
    public static func encodeResponse(status: UInt16, requestId: Int32, _ printerAttributes: [IppValue]) -> [UInt8] {
        var b = header(version: (1, 1), status, requestId)
        b.append(operationTag)
        writeAttribute(&b, charset, "attributes-charset", "utf-8")
        writeAttribute(&b, naturalLanguage, "attributes-natural-language", "en")
        b.append(printerTag)
        var previous: String?
        for a in printerAttributes {
            writeValue(&b, a.name == previous ? "" : a.name, a)
            previous = a.name
        }
        b.append(endTag)
        return b
    }

    /// One value; a collection as RFC 8010 §3.1.6 writes it: begCollection, each member's name (memberAttrName) before its
    /// first value, the values with no name, endCollection.
    private static func writeValue(_ b: inout [UInt8], _ attributeName: String, _ a: IppValue) {
        if a.tag == begCollection {
            writeAttribute(&b, begCollection, attributeName, [UInt8]())
            var member: String?
            for m in a.members ?? [] {
                if m.name != member { writeAttribute(&b, memberAttrName, "", m.name) }
                member = m.name
                writeValue(&b, "", m)
            }
            writeAttribute(&b, endCollection, "", [UInt8]())
            return
        }
        let value: [UInt8]
        switch a.tag {
        case integer, enumeration: value = int32Bytes(Int32(a.value)!)
        case boolean: value = [a.value == "true" ? 1 : 0]
        case resolution:
            let r = IppText.parseResolution(a.value)!
            value = int32Bytes(r.x) + int32Bytes(r.y) + [r.units]
        case rangeOfInteger:
            let r = IppText.parseRange(a.value)!
            value = int32Bytes(r.lower) + int32Bytes(r.upper)
        case dateTime: value = IppText.parseDateTime(a.value) ?? Array(a.value.utf8)
        default: value = Array(a.value.utf8)
        }
        writeAttribute(&b, a.tag, attributeName, value)
    }

    private static func header(version: (UInt8, UInt8), _ operationOrStatus: UInt16, _ requestId: Int32) -> [UInt8] {
        [version.0, version.1, UInt8(operationOrStatus >> 8), UInt8(operationOrStatus & 0xFF)] + int32Bytes(requestId)
    }

    private static func int32Bytes(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
    }

    private static func writeAttribute(_ b: inout [UInt8], _ tag: UInt8, _ name: String, _ value: String) {
        writeAttribute(&b, tag, name, Array(value.utf8))
    }

    private static func writeAttribute(_ b: inout [UInt8], _ tag: UInt8, _ name: String, _ value: [UInt8]) {
        let n = Array(name.utf8)
        b.append(tag)
        b += [UInt8(n.count >> 8 & 0xFF), UInt8(n.count & 0xFF)] + n
        b += [UInt8(value.count >> 8 & 0xFF), UInt8(value.count & 0xFF)] + value
    }
}

/// One value of a printer attribute: its name, RFC 8010 value tag and the value as text. A collection's value is empty and
/// its members are in `members` (each member a value of its own, the same name twice for a member with two values).
public struct IppValue: Equatable, Sendable {
    public let name: String
    public let tag: UInt8
    public let value: String
    /// A collection's members (RFC 8010 §3.1.6), in order; nil for any other value.
    public var members: [IppValue]?

    public init(name: String, tag: UInt8, value: String, members: [IppValue]? = nil) {
        self.name = name
        self.tag = tag
        self.value = value
        self.members = members
    }
}

/// Readable form of a Get-Printer-Attributes response, for fixtures written from the specs: one value per line,
/// `<attribute> <syntax> <value>` (e.g. `marker-levels integer 72`); the same attribute on the next line adds another
/// value. `#` starts a comment line. `IppCodec.encodeResponse` turns it into the wire format. A collection opens with
/// `<attribute> collection {`, has a member a line in the same form (another collection too), and closes with `}` on a line
/// of its own; `{}` is an empty one. A dateTime is written `2026-11-20T09:30:15.0-04:00` (RFC 2579's fields: deciseconds,
/// then the offset from UTC).
public enum IppText {
    private static let syntaxes: [String: UInt8] = [
        "integer": IppCodec.integer,
        "boolean": IppCodec.boolean,
        "enum": IppCodec.enumeration,
        "octetString": IppCodec.octetString,
        "dateTime": IppCodec.dateTime,
        "text": 0x41,
        "name": 0x42,
        "keyword": IppCodec.keyword,
        "uri": IppCodec.uri,
        "uriScheme": 0x46,
        "charset": IppCodec.charset,
        "naturalLanguage": IppCodec.naturalLanguage,
        "mimeMediaType": 0x49,
        "resolution": IppCodec.resolution,
        "rangeOfInteger": IppCodec.rangeOfInteger,
        "collection": IppCodec.begCollection,
    ]

    /// `1-99` (either end may have a sign, `-5--1`); nil unless the lower end is at most the upper.
    public static func parseRange(_ text: String) -> (lower: Int32, upper: Int32)? {
        guard text.count > 1, let dash = text.dropFirst().firstIndex(of: "-"),
              let lower = signed(text[..<dash]), let upper = signed(text[text.index(after: dash)...]), lower <= upper else { return nil }
        return (lower, upper)

        // .NET's AllowLeadingSign: one optional sign, then digits only.
        func signed(_ s: Substring) -> Int32? {
            let digits = s.first == "-" || s.first == "+" ? s.dropFirst() : s
            return !digits.isEmpty && digits.allSatisfy { ("0"..."9").contains($0) } ? Int32(s) : nil
        }
    }

    /// `300dpi`, `600x300dpi` or `118dpcm` (as ipptool writes them); units 3 is dots per inch, 4 per centimetre (RFC 8010
    /// §3.9). Nil for anything else.
    public static func parseResolution(_ text: String) -> (x: Int32, y: Int32, units: UInt8)? {
        let units: UInt8 = text.hasSuffix("dpi") ? 3 : text.hasSuffix("dpcm") ? 4 : 0
        if units == 0 { return nil }
        let parts = text.dropLast(units == 3 ? 3 : 4).split(separator: "x", omittingEmptySubsequences: false)
        guard parts.count <= 2, let x = digits(parts[0]) else { return nil }
        guard parts.count == 2 else { return (x, x, units) }
        guard let y = digits(parts[1]) else { return nil }
        return (x, y, units)

        func digits(_ s: Substring) -> Int32? { !s.isEmpty && s.allSatisfy { ("0"..."9").contains($0) } ? Int32(s) : nil }
    }

    /// `2026-11-20T09:30:15.0-04:00` → RFC 2579 DateAndTime's 11 octets, as they were: year, month, day, hour, minutes,
    /// seconds (up to 60, a leap second), deciseconds, the direction from UTC and its hours and minutes. Nil for anything else.
    public static func parseDateTime(_ text: String) -> [UInt8]? {
        let t = Array(text.utf8)
        guard t.count == 27, t[4] == UInt8(ascii: "-"), t[7] == UInt8(ascii: "-"), t[10] == UInt8(ascii: "T"), t[13] == UInt8(ascii: ":"),
              t[16] == UInt8(ascii: ":"), t[19] == UInt8(ascii: "."), t[21] == UInt8(ascii: "+") || t[21] == UInt8(ascii: "-"),
              t[24] == UInt8(ascii: ":") else { return nil }
        func digits(_ at: Int, _ length: Int) -> Int? {
            var n = 0
            for c in t[at..<at + length] {
                guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
                n = n * 10 + Int(c - UInt8(ascii: "0"))
            }
            return n
        }
        guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2), let hour = digits(11, 2), let minute = digits(14, 2),
              let second = digits(17, 2), let tenth = digits(20, 1), let offsetHours = digits(22, 2), let offsetMinutes = digits(25, 2),
              (1...12).contains(month), (1...31).contains(day), hour <= 23, minute <= 59, second <= 60, offsetHours <= 14, offsetMinutes <= 59
        else { return nil }
        return [UInt8(year >> 8), UInt8(year & 0xFF), UInt8(month), UInt8(day), UInt8(hour), UInt8(minute), UInt8(second), UInt8(tenth),
                t[21], UInt8(offsetHours), UInt8(offsetMinutes)]
    }

    /// The other way: nil for octets that aren't a DateAndTime this form holds as they are.
    private static func dateTimeText(_ v: [UInt8]) -> String? {
        guard v.count == 11 else { return nil }
        func two(_ n: UInt8) -> String { n < 10 ? "0\(n)" : "\(n)" }
        let year = Int(v[0]) << 8 | Int(v[1])
        let yearText = String(repeating: "0", count: max(0, 4 - String(year).count)) + String(year)
        let text = "\(yearText)-\(two(v[2]))-\(two(v[3]))T\(two(v[4])):\(two(v[5])):\(two(v[6])).\(v[7])"
            + "\(Character(Unicode.Scalar(v[8])))\(two(v[9])):\(two(v[10]))"
        return parseDateTime(text) == v ? text : nil
    }

    private static func int32(_ b: [UInt8], _ at: Int) -> Int32 {
        Int32(bitPattern: UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3]))
    }

    /// A resolution as ipptool writes it: `300dpi`, or `600x300dpi` when the two differ.
    private static func resolutionText(_ x: Int32, _ y: Int32, _ units: UInt8) -> String {
        "\(x)\(x == y ? "" : "x\(y)")\(units == 3 ? "dpi" : "dpcm")"
    }

    public static func parse(_ text: String) throws -> [IppValue] {
        var top: [IppValue] = []
        // The collections open around the line being read: each one's value and its members so far.
        var open: [(collection: IppValue, members: [IppValue])] = []
        func add(_ v: IppValue) {
            if open.isEmpty { top.append(v) } else { open[open.count - 1].members.append(v) }
        }
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line == "}" {
                guard let popped = open.popLast() else { throw IppFormatError("IPP text line \(index + 1): \"}\" closes no collection") }
                var closed = popped.collection
                closed.members = popped.members
                add(closed)
                continue
            }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let tag = syntaxes[parts[1]] else {
                throw IppFormatError("IPP text line \(index + 1): expected \"<attribute> <syntax> <value>\"")
            }
            let value = parts.count == 3 ? parts[2] : ""
            if tag == IppCodec.begCollection {
                guard value == "{" || value == "{}" else { throw IppFormatError("IPP text line \(index + 1): a collection starts with \"{\"") }
                if open.count >= IppCodec.maxCollectionDepth { throw IppFormatError("IPP text line \(index + 1): collections nested too deep") }
                let collection = IppValue(name: parts[0], tag: tag, value: "")
                if value == "{}" {
                    add(IppValue(name: parts[0], tag: tag, value: "", members: []))
                } else {
                    open.append((collection, []))
                }
                continue
            }
            let valid: Bool
            switch tag {
            case IppCodec.integer, IppCodec.enumeration: valid = Int32(value) != nil
            case IppCodec.boolean: valid = value == "true" || value == "false"
            case IppCodec.resolution: valid = parseResolution(value) != nil
            case IppCodec.rangeOfInteger: valid = parseRange(value) != nil
            case IppCodec.dateTime: valid = parseDateTime(value) != nil
            default: valid = true
            }
            if !valid { throw IppFormatError("IPP text line \(index + 1): \"\(value)\" is not a valid \(parts[1])") }
            add(IppValue(name: parts[0], tag: tag, value: value))
        }
        if let unclosed = open.last { throw IppFormatError("IPP text: the collection \"\(unclosed.collection.name)\" isn't closed") }
        return top
    }

    /// The other way: a Get-Printer-Attributes response's printer attributes as this text, one value per line, collections
    /// with their members nested, so a recording (`PrinterRecorder`) can be read and served again. Values this form can't
    /// hold are left out with a comment line naming their attributes: the with-language strings, out-of-band values and any
    /// other type (a collection keeps its other members). Line breaks inside a text value become spaces.
    public static func fromResponse(_ response: [UInt8]) throws -> String {
        guard response.count >= 9 else { throw IppFormatError("IPP response too short") }
        let names = Dictionary(syntaxes.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        func u16(_ at: Int) -> Int { Int(response[at]) << 8 | Int(response[at + 1]) }
        var lines = ""
        var skipped = Set<String>()
        var i = 8
        var group: UInt8 = 0
        var last: String?
        // Inside collections: each open one's current member name (nil until its first memberAttrName) and whether it is
        // written (one in another group, or under a value with no member name, isn't, nor is anything in it).
        var open: [(member: String?, written: Bool)] = []
        func line(_ text: String) { lines += String(repeating: " ", count: 2 * open.count) + text + "\n" }
        while i < response.count {
            let tag = response[i]
            i += 1
            if tag == 0x03 { break } // end-of-attributes
            if tag < 0x10 {
                if !open.isEmpty { throw IppFormatError("IPP collection not closed") }
                group = tag
                last = nil
                continue
            }
            guard i + 2 <= response.count else { throw IppFormatError("IPP response truncated") }
            let nameLength = u16(i)
            i += 2
            guard i + nameLength + 2 <= response.count else { throw IppFormatError("IPP response truncated") }
            let name = String(decoding: response[i..<i + nameLength], as: UTF8.self)
            i += nameLength
            let valueLength = u16(i)
            i += 2
            guard i + valueLength <= response.count else { throw IppFormatError("IPP response truncated") }
            let value = Array(response[i..<i + valueLength])
            i += valueLength
            if nameLength > 0 && open.isEmpty { last = name }
            if !open.isEmpty && tag == IppCodec.memberAttrName {
                open[open.count - 1].member = String(decoding: value, as: UTF8.self)
                continue
            }
            if tag == IppCodec.endCollection {
                guard let closed = open.popLast() else { throw IppFormatError("IPP collection closed twice") }
                if closed.written { line("}") }
                continue
            }
            // Written: in the printer group (the operation group is the codec's own) and in no collection left out.
            let writing = group == 0x04 && last != nil && (open.last?.written ?? true)
            // The attribute's name at the top, the member's inside a collection (a value before any member name has none).
            let label = open.isEmpty ? last : open[open.count - 1].member
            if tag == IppCodec.begCollection {
                if open.count >= IppCodec.maxCollectionDepth { throw IppFormatError("IPP collections nested too deep") }
                if writing, let label {
                    line("\(label) collection {")
                } else if writing, let last {
                    skipped.insert("\(last) (part)")
                }
                open.append((nil, writing && label != nil))
                continue
            }
            guard writing, let attribute = last else { continue }
            let kept = names[tag].flatMap { syntax in Self.text(tag, value).map { (syntax: syntax, written: $0) } }
            guard let label, let kept else {
                skipped.insert(open.isEmpty ? attribute : "\(attribute) (part)")
                continue
            }
            line("\(label) \(kept.syntax) \(kept.written)")
        }
        if !open.isEmpty { throw IppFormatError("IPP collection not closed") }
        if !skipped.isEmpty { lines = "# Not kept (no IppText form): \(skipped.sorted().joined(separator: ", "))\n" + lines }
        return lines
    }

    /// One value as this form writes it; nil when it can't hold it as it is.
    private static func text(_ tag: UInt8, _ value: [UInt8]) -> String? {
        switch tag {
        case IppCodec.integer, IppCodec.enumeration:
            return value.count == 4 ? String(int32(value, 0)) : nil
        case IppCodec.boolean:
            return value.count == 1 ? (value[0] != 0 ? "true" : "false") : nil
        case IppCodec.resolution:
            return value.count == 9 && (value[8] == 3 || value[8] == 4) ? resolutionText(int32(value, 0), int32(value, 4), value[8]) : nil
        case IppCodec.rangeOfInteger:
            return value.count == 8 ? "\(int32(value, 0))-\(int32(value, 4))" : nil
        case IppCodec.dateTime:
            return dateTimeText(value)
        default:
            // A text that reads back as it was: one line, no edge spaces, and not a lone "{" (a collection's opening) or "}".
            let t = String(decoding: value, as: UTF8.self)
                .replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                .trimmingCharacters(in: .whitespaces)
            return t == "{" || t == "}" || t == "{}" ? nil : t
        }
    }
}

/// One `printer-alert` value (PWG 5100.9 §5.2.2): `code=jam;index=22;severity=critical;…`.
public struct IppAlert: Equatable, Sendable {
    public let code: String
    public let severity: String?
    public let fields: [String: String]

    /// Nil when the value has no code (malformed or empty: some printers send an empty string for "no alerts").
    public static func parse(_ value: String) -> IppAlert? {
        var fields: [String: String] = [:]
        for part in value.split(separator: ";") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard let eq = p.firstIndex(of: "="), eq > p.startIndex else { continue }
            fields[String(p[..<eq])] = String(p[p.index(after: eq)...])
        }
        guard let code = fields["code"], !code.isEmpty else { return nil }
        return IppAlert(code: code, severity: fields["severity"], fields: fields)
    }
}
