import Foundation

/// A JSON value as read, with booleans, integers and other numbers told apart (JSONSerialization's NSNumber blurs them).
indirect enum JsonValue: Decodable, Equatable {
    case null, bool(Bool), int(Int64), double(Double), string(String), array([JsonValue]), object([String: JsonValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null } else if let b = try? c.decode(Bool.self) { self = .bool(b) } else if let i = try? c.decode(Int64.self) {
            self = .int(i)
        } else if let d = try? c.decode(Double.self) { self = .double(d) } else if let s = try? c.decode(String.self) { self = .string(s) } else if let a = try? c.decode([JsonValue].self) {
            self = .array(a)
        } else { self = .object(try c.decode([String: JsonValue].self)) }
    }

    static func parse(_ text: String) throws -> JsonValue { try JSONDecoder().decode(JsonValue.self, from: Data(text.utf8)) }

    subscript(_ key: String) -> JsonValue? { if case .object(let o) = self { o[key] } else { nil } }
    subscript(_ index: Int) -> JsonValue? { if case .array(let a) = self, index < a.count { a[index] } else { nil } }
    var string: String? { if case .string(let s) = self { s } else { nil } }
}

/// The part of JSON Schema (draft 2020-12) that `print/schemas/fleet-status.schema.json` uses, so a test can hold the export
/// against the file in the repository without a package (the Windows tests' `JsonSchemaCheck`): type, const, enum,
/// required, properties, additionalProperties false, items, maxItems, minLength, maxLength, minimum, maximum, pattern and
/// local $ref. A keyword it doesn't know fails, so the schema can't quietly say more than is checked.
enum JsonSchemaCheck {
    private static let known: Set<String> = ["$schema", "$id", "$defs", "title", "description", "type", "const", "enum", "required", "properties",
                                             "additionalProperties", "items", "maxItems", "minLength", "maxLength", "minimum", "maximum", "pattern", "$ref"]

    struct UnknownKeyword: Error { let name: String }

    /// Every place `document` breaks `schema`; empty when it validates.
    static func errors(_ schema: JsonValue, _ document: JsonValue) throws -> [String] {
        var errors: [String] = []
        try check(schema, schema, document, "$", &errors)
        return errors
    }

    private static func check(_ root: JsonValue, _ schema: JsonValue, _ value: JsonValue, _ at: String, _ errors: inout [String]) throws {
        guard case .object(let s) = schema else { return }
        for key in s.keys where !known.contains(key) { throw UnknownKeyword(name: key) }
        if let ref = s["$ref"]?.string {
            var target = root
            for part in ref.drop(while: { $0 == "#" || $0 == "/" }).split(separator: "/") { target = target[String(part)] ?? .null }
            try check(root, target, value, at, &errors)
            return
        }
        if let type = s["type"], !typeMatches(type, value) { errors.append("\(at): is \(value), the schema says \(type)") }
        if let constant = s["const"], constant != value { errors.append("\(at): is not \(constant)") }
        if case .array(let choices)? = s["enum"], !choices.contains(value) { errors.append("\(at): \(value) isn't one of \(choices)") }
        switch value {
        case .string(let text):
            let length = text.utf16.count
            if case .int(let min)? = s["minLength"], length < min { errors.append("\(at): shorter than \(min)") }
            if case .int(let max)? = s["maxLength"], length > max { errors.append("\(at): longer than \(max)") }
            if let pattern = s["pattern"]?.string {
                let re = try NSRegularExpression(pattern: pattern)
                if re.firstMatch(in: text, range: NSRange(location: 0, length: length)) == nil { errors.append("\(at): \"\(text)\" doesn't match \(pattern)") }
            }
        case .int, .double:
            let n: Double = if case .int(let i) = value { Double(i) } else if case .double(let d) = value { d } else { 0 }
            if let min = number(s["minimum"]), n < min { errors.append("\(at): under \(min)") }
            if let max = number(s["maximum"]), n > max { errors.append("\(at): over \(max)") }
        case .array(let items):
            if case .int(let most)? = s["maxItems"], items.count > most { errors.append("\(at): more than \(most) items") }
            if let itemSchema = s["items"] {
                for (i, item) in items.enumerated() { try check(root, itemSchema, item, "\(at)[\(i)]", &errors) }
            }
        case .object(let o):
            if case .array(let required)? = s["required"] {
                for name in required.compactMap(\.string) where o[name] == nil { errors.append("\(at): \(name) is missing") }
            }
            let closed = s["additionalProperties"] == .bool(false)
            for (name, sub) in o {
                if let propertySchema = s["properties"]?[name] { try check(root, propertySchema, sub, "\(at).\(name)", &errors) } else if closed {
                    errors.append("\(at): \(name) isn't in the schema")
                }
            }
        default: break
        }
    }

    private static func number(_ v: JsonValue?) -> Double? {
        switch v {
        case .int(let i)?: Double(i)
        case .double(let d)?: d
        default: nil
        }
    }

    private static func typeMatches(_ type: JsonValue, _ value: JsonValue) -> Bool {
        if case .array(let types) = type { return types.contains { typeMatches($0, value) } }
        switch (type.string, value) {
        case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool), ("null", .null), ("integer", .int), ("number", .int), ("number", .double):
            return true
        default:
            return false
        }
    }
}
