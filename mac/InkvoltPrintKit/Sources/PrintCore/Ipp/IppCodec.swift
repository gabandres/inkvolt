import Foundation

/// A reply that isn't the IPP it should be: too short, or a value running past the end.
public struct IppFormatError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// One decoded attribute value: text (every string syntax, and `printer-alert`'s octetString), a number, a boolean, or the
/// raw bytes of a syntax Inkvolt Print doesn't read.
public enum IppAttributeValue: Equatable, Sendable {
    case text(String)
    case integer(Int)
    case boolean(Bool)
    case bytes([UInt8])
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
}

/// Minimal IPP encoding (RFC 8010): enough for Get-Printer-Attributes and Identify-Printer.
public enum IppCodec {
    public static let getPrinterAttributes: UInt16 = 0x000B

    /// PWG 5100.13 §4.1 (IPP Job and Printer Extensions, Set 3): the printer shows where it is (lights, sound, panel).
    public static let identifyPrinter: UInt16 = 0x003C

    static let operationTag: UInt8 = 0x01, printerTag: UInt8 = 0x04, endTag: UInt8 = 0x03
    static let integer: UInt8 = 0x21, boolean: UInt8 = 0x22, enumeration: UInt8 = 0x23, octetString: UInt8 = 0x30
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

    /// Decodes the printer-attributes group. A truncated or corrupt reply is an `IppFormatError`, never a crash.
    public static func decode(_ b: [UInt8]) throws -> IppResponse {
        guard b.count >= 9 else { throw IppFormatError("IPP response too short") }
        let status = UInt16(b[2]) << 8 | UInt16(b[3])
        var attributes: [String: [IppAttributeValue]] = [:]
        var i = 8
        var last: String?
        var group: UInt8 = 0
        while i < b.count {
            let tag = b[i]
            i += 1
            if tag == endTag { break }
            if tag < 0x10 {
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
            if nameLength > 0 { last = name }
            guard let last, group == printerTag else { continue }
            let decoded: IppAttributeValue
            switch tag {
            case integer where valueLength == 4, enumeration where valueLength == 4:
                decoded = .integer(Int(Int32(bitPattern: UInt32(value[0]) << 24 | UInt32(value[1]) << 16 | UInt32(value[2]) << 8 | UInt32(value[3]))))
            case boolean where valueLength == 1:
                decoded = .boolean(value[0] != 0)
            case 0x40...0x4F, octetString:
                // printer-alert (PWG 5100.9) is an octetString of US-ASCII "code=…;severity=…" text.
                decoded = .text(String(decoding: value, as: UTF8.self))
            default:
                decoded = .bytes(value)
            }
            attributes[last, default: []].append(decoded)
        }
        return IppResponse(statusCode: status, attributes: attributes)
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
            let attributeName = a.name == previous ? "" : a.name
            previous = a.name
            let value: [UInt8]
            switch a.tag {
            case integer, enumeration: value = int32Bytes(Int32(a.value)!)
            case boolean: value = [a.value == "true" ? 1 : 0]
            default: value = Array(a.value.utf8)
            }
            writeAttribute(&b, a.tag, attributeName, value)
        }
        b.append(endTag)
        return b
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

/// One value of a printer attribute: its name, RFC 8010 value tag and the value as text.
public struct IppValue: Equatable, Sendable {
    public let name: String
    public let tag: UInt8
    public let value: String
}

/// Readable form of a Get-Printer-Attributes response, for fixtures written from the specs: one value per line,
/// `<attribute> <syntax> <value>` (e.g. `marker-levels integer 72`); the same attribute on the next line adds another
/// value. `#` starts a comment line. `IppCodec.encodeResponse` turns it into the wire format.
public enum IppText {
    private static let syntaxes: [String: UInt8] = [
        "integer": IppCodec.integer,
        "boolean": IppCodec.boolean,
        "enum": IppCodec.enumeration,
        "octetString": IppCodec.octetString,
        "text": 0x41,
        "name": 0x42,
        "keyword": IppCodec.keyword,
        "uri": IppCodec.uri,
        "uriScheme": 0x46,
        "charset": IppCodec.charset,
        "naturalLanguage": IppCodec.naturalLanguage,
        "mimeMediaType": 0x49,
    ]

    public static func parse(_ text: String) throws -> [IppValue] {
        var values: [IppValue] = []
        for (index, raw) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 2, let tag = syntaxes[parts[1]] else {
                throw IppFormatError("IPP text line \(index + 1): expected \"<attribute> <syntax> <value>\"")
            }
            let value = parts.count == 3 ? parts[2] : ""
            let valid: Bool
            switch tag {
            case IppCodec.integer, IppCodec.enumeration: valid = Int32(value) != nil
            case IppCodec.boolean: valid = value == "true" || value == "false"
            default: valid = true
            }
            if !valid { throw IppFormatError("IPP text line \(index + 1): \"\(value)\" is not a valid \(parts[1])") }
            values.append(IppValue(name: parts[0], tag: tag, value: value))
        }
        return values
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
