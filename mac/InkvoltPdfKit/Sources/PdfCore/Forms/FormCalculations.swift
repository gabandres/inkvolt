import Foundation
import PrintCore

/// What a field's value is computed as: nothing, one of Acrobat's simple calculations of chosen fields, simplified field
/// notation, or a script of the form's own (kept as it is). (.NET's `CalcKind.None` is `notCalculated` here: `.none`
/// would read as an Optional's.)
public enum CalcKind: Int, Sendable { case notCalculated, sum, product, average, minimum, maximum, notation, custom }

/// A field's calculation as Prepare Form shows and writes it (the field's /AA /C, in the form's /CO order). `fields`: the
/// fields a simple calculation reads; `notation`: the simplified field notation ("Price * Qty"); `script`: a custom
/// script, kept.
public struct FieldCalc: Equatable, Sendable {
    public var kind: CalcKind
    public var fields: [String]
    public var notation: String
    public var script: String

    public init(_ kind: CalcKind, _ fields: [String], notation: String = "", script: String = "") {
        self.kind = kind
        self.fields = fields
        self.notation = notation
        self.script = script
    }
}

/// Calculated form fields (the Windows app's `FormCalculations`), written the way Acrobat writes them so Acrobat's
/// Calculate tab reads them back: `AFSimple_Calculate("SUM", new Array ("a", "b"));` for a sum, product, average, minimum
/// or maximum, and `/** BVCALC Price * Qty EVCALC **/ event.value = …` for simplified field notation (the notation in the
/// comment, the JavaScript it stands for after it). Any other calculate script is a custom one and stays untouched. The
/// calculations run when the form is filled (`FormEditor.calculate`, through the JavaScript sandbox, in /CO order).
public enum FormCalculations {
    /// The longest script read as one of ours (UTF-16 units, as .NET's); a longer one is kept as a custom script.
    private static let maxScript = 64 * 1024

    /// The longest notation accepted, and the most field names in a calculation.
    public static let maxNotation = 4000, maxFields = 500

    // .NET's patterns; ICU allows a group name once, so the two spellings of the list are two groups.
    private static let simpleCall = try! NSRegularExpression(
        pattern: #"^\s*AFSimple_Calculate\s*\(\s*(["'])(SUM|PRD|AVG|MIN|MAX)\1\s*,\s*(?:new\s+Array\s*\((.*)\)|\[(.*)\])\s*\)\s*;?\s*$"#,
        options: [.dotMatchesLineSeparators])
    private static let stringLiteral = try! NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'"#, options: [.dotMatchesLineSeparators])
    private static let notationComment = try! NSRegularExpression(pattern: #"^\s*/\*\*\s*BVCALC(.*?)EVCALC\s*\*\*/"#, options: [.dotMatchesLineSeparators])

    private static let ops = ["SUM", "PRD", "AVG", "MIN", "MAX"]

    private static func group(_ m: NSTextCheckingResult, _ i: Int, in s: NSString) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : s.substring(with: r)
    }

    /// The calculation a field's calculate script is (nil: none).
    public static func read(_ script: String?) -> FieldCalc? {
        guard let script, !script.allSatisfy(\.isWhitespace) else { return nil }
        if script.utf16.count > maxScript { return FieldCalc(.custom, [], script: script) }
        let s = script as NSString
        let all = NSRange(location: 0, length: s.length)
        if let m = simpleCall.firstMatch(in: script, range: all), let op = group(m, 2, in: s),
           let names = names(group(m, 3, in: s) ?? group(m, 4, in: s) ?? "") {
            return FieldCalc(kindOf(op), names)
        }
        if let n = notationComment.firstMatch(in: script, range: all), let raw = group(m: n, s) {
            let sfn = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only ours when the script after the comment is what the notation stands for (else someone edited it).
            let after = s.substring(from: n.range.location + n.range.length)
            if case .success(let js) = tryCompile(sfn), normalize(after) == normalize(js) {
                return FieldCalc(.notation, notationFields(sfn), notation: sfn)
            }
        }
        return FieldCalc(.custom, [], script: script)
    }

    private static func group(m: NSTextCheckingResult, _ s: NSString) -> String? { group(m, 1, in: s) }

    private static func normalize(_ js: String) -> String { String(js.filter { !$0.isWhitespace && $0 != ";" }) }

    private static func kindOf(_ op: String) -> CalcKind {
        switch op {
        case "SUM": .sum
        case "PRD": .product
        case "AVG": .average
        case "MIN": .minimum
        default: .maximum
        }
    }

    /// The field names of `new Array("a", 'b')`'s list, or nil when it holds anything but string literals.
    private static func names(_ list: String) -> [String]? {
        let s = list as NSString
        var names: [String] = []
        var rest = ""
        var at = 0
        for m in stringLiteral.matches(in: list, range: NSRange(location: 0, length: s.length)) {
            rest += s.substring(with: NSRange(location: at, length: m.range.location - at))
            names.append(unescape(group(m, 1, in: s) ?? group(m, 2, in: s) ?? ""))
            at = m.range.location + m.range.length
            if names.count > maxFields { return nil }
        }
        rest += s.substring(from: at)
        return rest.allSatisfy({ $0 == "," || $0.isWhitespace }) ? names : nil
    }

    private static func unescape(_ s: String) -> String {
        guard s.contains("\\") else { return s }
        var out = ""
        var escaped = false
        for c in s {
            if c == "\\" && !escaped {
                escaped = true
                continue
            }
            out.append(c)
            escaped = false
        }
        // A trailing lone backslash is kept, as .NET's (it has nothing after it to take).
        if escaped { out.append("\\") }
        return out
    }

    private static func quote(_ s: String) -> String {
        "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\r", with: "\\r").replacingOccurrences(of: "\n", with: "\\n") + "\""
    }

    /// The calculate script for `calc` (a custom one: its own script). Throws `DesignRefusal` for a notation that can't be
    /// read.
    public static func scriptOf(_ calc: FieldCalc) throws -> String {
        switch calc.kind {
        case .notation: return "/** BVCALC \(calc.notation) EVCALC **/ \(try compile(calc.notation))"
        case .custom: return calc.script
        case .notCalculated: return ""
        default: return "AFSimple_Calculate(\(quote(ops[calc.kind.rawValue - 1])), new Array (\(calc.fields.map(quote).joined(separator: ", "))));"
        }
    }

    // MARK: Simplified field notation

    private enum TokenKind { case name, number, op }

    private struct Token {
        var kind: TokenKind
        var text: String
    }

    /// The JavaScript simplified field notation stands for: each field name read as a number
    /// (`AFMakeNumber(getField("Price").value)`), with numbers, + - * / and brackets as written. Names are as in Acrobat:
    /// letters, digits, '_' and '.', a backslash before any other character ("Unit\ price"). Throws `DesignRefusal` for
    /// anything else.
    public static func compile(_ notation: String) throws -> String {
        switch tryCompile(notation) {
        case .success(let js): return js
        case .failure(let r): throw r
        }
    }

    /// The field names a notation reads, in order of first use.
    public static func notationFields(_ notation: String) -> [String] {
        guard case .success(let tokens) = tryTokens(notation) else { return [] }
        var seen = Set<String>(), names: [String] = []
        for t in tokens where t.kind == .name && seen.insert(t.text).inserted { names.append(t.text) }
        return names
    }

    private static func syntax() -> DesignRefusal {
        DesignRefusal(loc("The calculation can't be read: use field names, numbers, + - * / and brackets, as Price * Quantity."))
    }

    private static func brackets() -> DesignRefusal { DesignRefusal(loc("The brackets don't match: each ( needs a ).")) }

    private static func tryCompile(_ notation: String) -> Result<String, DesignRefusal> {
        let tokens: [Token]
        switch tryTokens(notation) {
        case .success(let t): tokens = t
        case .failure(let r): return .failure(r)
        }
        // The notation is kept in a comment: nothing in it may end the comment, or hide the marker.
        if notation.contains("*/") || notation.contains("EVCALC") { return .failure(syntax()) }
        if tokens.isEmpty { return .failure(DesignRefusal(loc("Type the calculation, as Price * Quantity."))) }
        // Checked as an expression: operands and operators alternate, brackets match.
        var depth = 0
        var expectOperand = true
        for t in tokens {
            if expectOperand {
                if t.kind == .name || t.kind == .number {
                    expectOperand = false
                } else if t.text == "(" {
                    depth += 1
                } else if t.text != "-" && t.text != "+" {
                    return .failure(syntax())
                }
            } else if t.text == ")" {
                depth -= 1
                if depth < 0 { return .failure(brackets()) }
            } else if ["+", "-", "*", "/"].contains(t.text) {
                expectOperand = true
            } else {
                return .failure(syntax())
            }
            if depth > 32 { return .failure(syntax()) }
        }
        if expectOperand { return .failure(syntax()) }
        if depth != 0 { return .failure(brackets()) }
        // Tokens a space apart, none after "(" or before ")" (built so: a field name in quotes is never touched).
        var js = "event.value ="
        var prev: Token?
        for t in tokens {
            let afterOpen = prev.map { $0.kind == .op && $0.text == "(" } ?? false
            if !(afterOpen || (t.kind == .op && t.text == ")")) { js += " " }
            js += t.kind == .name ? "AFMakeNumber(getField(\(quote(t.text))).value)" : t.text
            prev = t
        }
        return .success(js + ";")
    }

    // .NET's char tests, on Unicode scalars.
    private static func isDigit(_ c: Unicode.Scalar) -> Bool { c.properties.numericType == .decimal }

    private static func isLetter(_ c: Unicode.Scalar) -> Bool {
        switch c.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter: true
        default: false
        }
    }

    private static func tryTokens(_ notation: String) -> Result<[Token], DesignRefusal> {
        if notation.utf16.count > maxNotation { return .failure(DesignRefusal(loc("The calculation is too long."))) }
        let s = Array(notation.unicodeScalars)
        var tokens: [Token] = []
        var nameCount = 0
        var i = 0
        while i < s.count {
            let c = s[i]
            if c.properties.isWhitespace {
                i += 1
                continue
            }
            if "+-*/()".unicodeScalars.contains(c) {
                tokens.append(Token(kind: .op, text: String(c)))
                i += 1
                continue
            }
            if isDigit(c) || (c == "." && i + 1 < s.count && isDigit(s[i + 1])) {
                let start = i
                while i < s.count && (isDigit(s[i]) || s[i] == ".") { i += 1 }
                var text = ""
                text.unicodeScalars.append(contentsOf: s[start..<i])
                // .NET reads only ASCII digits here; a dot more than once isn't a number.
                guard text.allSatisfy({ $0.isASCII }), text.filter({ $0 == "." }).count <= 1, Double(text) != nil else { return .failure(syntax()) }
                tokens.append(Token(kind: .number, text: text))
                continue
            }
            if isLetter(c) || c == "_" || c == "\\" {
                var name = String.UnicodeScalarView()
                while i < s.count && (isLetter(s[i]) || isDigit(s[i]) || s[i] == "_" || s[i] == "." || s[i] == "\\") {
                    if s[i] == "\\" {
                        if i + 1 >= s.count { return .failure(syntax()) }
                        i += 1
                    }
                    name.append(s[i])
                    i += 1
                }
                tokens.append(Token(kind: .name, text: String(name)))
                nameCount += 1
                if nameCount > maxFields { return .failure(DesignRefusal(loc("The calculation is too long."))) }
                continue
            }
            return .failure(DesignRefusal(loc("The calculation can't use \"{0}\". Put a backslash before it in a field's name (Unit\\ price).", String(c))))
        }
        return .success(tokens)
    }

    /// A notation written the Acrobat way: names with spaces or symbols get a backslash before those characters.
    public static func nameInNotation(_ name: String) -> String {
        var out = String.UnicodeScalarView()
        for c in name.unicodeScalars {
            if !(isLetter(c) || isDigit(c) || c == "_" || c == ".") { out.append("\\") }
            out.append(c)
        }
        if let first = out.first, isDigit(first) { out.insert("\\", at: out.startIndex) }
        return String(out)
    }
}
