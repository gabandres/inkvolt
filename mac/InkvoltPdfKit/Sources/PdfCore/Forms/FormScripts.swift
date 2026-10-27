import Foundation

public enum FieldFormatKind: Sendable { case number, percent, date, special }

/// A field's display format, from its Acrobat format script (/AA /F): AFNumber_Format, AFPercent_Format,
/// AFDate_FormatEx / AFDate_Format, AFSpecial_Format. The field value (/V) stays raw; only the appearance changes.
/// `separatorStyle`: 0 = 1,234.56; 1 = 1234.56; 2 = 1.234,56; 3 = 1234,56; 4 = 1'234.56. `negativeStyle`: 0 = minus
/// sign; 1 = red; 2 = parentheses; 3 = red parentheses. `datePattern`: an Acrobat date pattern (d, dd, ddd, dddd, m, mm,
/// mmm, mmmm, yy, yyyy, H, HH, h, hh, M, MM, s, ss, t, tt). `special`: 0 = ZIP, 1 = ZIP+4, 2 = phone, 3 = SSN.
public struct FieldFormat: Equatable, Sendable {
    public var kind: FieldFormatKind
    public var decimals: Int
    public var separatorStyle: Int
    public var negativeStyle: Int
    public var currency: String
    public var currencyPrepend: Bool
    public var datePattern: String
    public var special: Int

    public init(_ kind: FieldFormatKind, decimals: Int = 2, separatorStyle: Int = 0, negativeStyle: Int = 0, currency: String = "",
                currencyPrepend: Bool = true, datePattern: String = "", special: Int = 0) {
        self.kind = kind
        self.decimals = decimals
        self.separatorStyle = separatorStyle
        self.negativeStyle = negativeStyle
        self.currency = currency
        self.currencyPrepend = currencyPrepend
        self.datePattern = datePattern
        self.special = special
    }
}

/// A date and time as form scripts read and write it (.NET's `DateTime` in the Windows code): no time zone.
public struct FormDate: Equatable, Sendable, CustomStringConvertible {
    public var year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int

    /// Nil when the date doesn't exist (31 February) or is out of range (years 1 to 9999).
    public init?(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) {
        guard (1...9999).contains(year), (1...12).contains(month), day >= 1, day <= FormDate.days(year, month),
              (0...23).contains(hour), (0...59).contains(minute), (0...59).contains(second) else { return nil }
        self.year = year
        self.month = month
        self.day = day
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    public var description: String { String(format: "%04d-%02d-%02d %02d:%02d:%02d", year, month, day, hour, minute, second) }

    static func days(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 (Howard Hinnant's days_from_civil).
    private static func daysFromCivil(_ y0: Int, _ m: Int, _ d: Int) -> Int {
        let y = m <= 2 ? y0 - 1 : y0
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    private static func civil(_ z0: Int) -> (Int, Int, Int) {
        let z = z0 + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let doe = z - era * 146_097
        let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146_096) / 365
        let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
        let mp = (5 * doy + 2) / 153
        let d = doy - (153 * mp + 2) / 5 + 1
        let m = mp + (mp < 10 ? 3 : -9)
        return (yoe + era * 400 + (m <= 2 ? 1 : 0), m, d)
    }

    /// 0 = Sunday.
    var weekday: Int { ((FormDate.daysFromCivil(year, month, day) % 7) + 11) % 7 }

    /// The first of `month` plus the given days and time (.NET's `new DateTime(y, m, 1).AddDays(...)...`); nil when out of
    /// range.
    static func from(_ year: Int, _ month: Int, plusDays days: Int, hours: Int, minutes: Int, seconds: Int) -> FormDate? {
        guard (1...9999).contains(year), (1...12).contains(month) else { return nil }
        let base = daysFromCivil(year, month, 1)
        let total = (base + days) * 86400 + hours * 3600 + minutes * 60 + seconds
        let dayNumber = Int((Double(total) / 86400).rounded(.down))
        let rest = total - dayNumber * 86400
        let (y, m, d) = civil(dayNumber)
        return FormDate(y, m, d, rest / 3600, rest % 3600 / 60, rest % 60)
    }

    /// Today's date (local), at midnight.
    static var today: FormDate {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: Date())
        return FormDate(c.year ?? 2000, c.month ?? 1, c.day ?? 1) ?? FormDate(2000, 1, 1)!
    }
}

/// A field's calculate script (/AA /C) in a form evaluated without a JavaScript engine.
public final class FieldCalculation {
    private let eval: (@escaping (String) -> [String]) -> Double?

    init(_ inputs: [String], _ eval: @escaping (@escaping (String) -> [String]) -> Double?) {
        self.inputs = inputs
        self.eval = eval
    }

    /// The field names the script reads.
    public let inputs: [String]

    /// Evaluates the script. `valuesOf` returns the raw values of the terminal fields a name refers to (the field itself,
    /// or every field under it when it names a parent). Nil when it can't be computed.
    public func evaluate(_ valuesOf: @escaping (String) -> [String]) -> Double? { eval(valuesOf) }
}

/// The common Acrobat form built-ins, interpreted without a JavaScript engine (the Windows app's `FormScripts`):
/// calculations `AFSimple_Calculate("SUM"|"AVG"|"PRD"|"MIN"|"MAX", new Array("a","b"))` and simple arithmetic scripts
/// (`event.value = this.getField("a").value * getField("b").value + 1;`, with `var` locals, `AFMakeNumber`, `Number`,
/// `Math.round/floor/ceil/abs/min/max`); formats AFNumber_Format, AFPercent_Format, AFDate_FormatEx, AFDate_Format,
/// AFSpecial_Format. Anything else is ignored (nil). Form scripts normally run in the JavaScript sandbox (`JsFormHost`);
/// these are the fallback when a script can't run there, and the formatting helpers the sandbox's AF* built-ins use.
public enum FormScripts {
    struct ParseError: Error {}

    // ---------------- Calculations ----------------

    public static func parseCalculation(_ script: String?) -> FieldCalculation? {
        guard let script, !script.allSatisfy(\.isWhitespace) else { return nil }
        do {
            let tokens = try tokenize(script)
            // A chain like "1+1+1+…" evaluates as nested closures, one level per operator: kept far from the stack limit.
            if tokens.count > 2000 { return nil }
            return try Parser(tokens).program()
        } catch {
            return nil
        }
    }

    /// Acrobat's AFMakeNumber: a number from a field value ("1,234.50", "$12", "3,5"), or nil when it isn't one.
    public static func toNumber(_ value: String?) -> Double? {
        guard let value else { return nil }
        let s = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return nil }
        let negative = s.hasPrefix("(") && s.hasSuffix(")")
        var t = String(s.filter { $0.isASCII && ($0.isNumber || ".,-+eE".contains($0)) })
        let comma = t.lastIndex(of: ","), dot = t.lastIndex(of: ".")
        if let comma, let dot {
            t = comma > dot ? t.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
                : t.replacingOccurrences(of: ",", with: "")
        } else if comma != nil {
            t = t.filter { $0 == "," }.count == 1 ? t.replacingOccurrences(of: ",", with: ".") : t.replacingOccurrences(of: ",", with: "")
        }
        guard let v = Double(t), v.isFinite else { return nil }
        return negative ? -abs(v) : v
    }

    /// A computed number as Acrobat stores it in /V ("15", "0.3", "-2.5"): up to 10 decimals, no exponent.
    public static func numberToValue(_ v: Double) -> String {
        guard v.isFinite else { return v.isNaN ? "NaN" : v > 0 ? "Infinity" : "-Infinity" }
        var s = String(format: "%.10f", v)
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s == "-0" ? "0" : s
    }

    private final class Env {
        let valuesOf: (String) -> [String]
        var vars: [String: Double?] = [:]
        var result: Double?
        init(_ valuesOf: @escaping (String) -> [String]) { self.valuesOf = valuesOf }
    }

    private typealias Expr = (Env) -> Double?

    private final class Parser {
        private let tokens: [Token]
        private var i = 0
        private var inputs: [String] = []
        private var statements: [(Env) -> Bool] = []
        /// Nesting allowed in one expression ("((((" or "----"): a hostile script must fail to parse, not overflow the
        /// stack while parsing or evaluating.
        private let maxDepth = 64
        private var depth = 0

        init(_ tokens: [Token]) { self.tokens = tokens }

        private func peek(_ ahead: Int = 0) -> Token { i + ahead < tokens.count ? tokens[i + ahead] : .end }

        private func next() -> Token {
            defer { if i < tokens.count { i += 1 } }
            return peek()
        }

        private func accept(_ text: String) -> Bool {
            if peek().text != text || peek().kind == .str { return false }
            i += 1
            return true
        }

        private func expect(_ text: String) throws { if !accept(text) { throw ParseError() } }

        func program() throws -> FieldCalculation? {
            var assignsResult = false
            while peek().kind != .end {
                if accept(";") { continue }
                let t = peek()
                if t.kind == .ident && t.text == "AFSimple_Calculate" {
                    statements.append(try simpleCalculate())
                    assignsResult = true
                } else if t.kind == .ident && t.text == "var" {
                    _ = next()
                    let name = try ident()
                    try expect("=")
                    let e = try expr()
                    statements.append { env in
                        let v = e(env)
                        env.vars[name] = .some(v)
                        return v != nil
                    }
                } else if t.kind == .ident && t.text == "event.value" {
                    _ = next()
                    try expect("=")
                    let e = try expr()
                    statements.append { env in
                        env.result = e(env)
                        return env.result != nil
                    }
                    assignsResult = true
                } else if t.kind == .ident && peek(1).text == "=" && !t.text.contains(".") {
                    let name = try ident()
                    try expect("=")
                    let e = try expr()
                    statements.append { env in
                        let v = e(env)
                        env.vars[name] = .some(v)
                        return v != nil
                    }
                } else {
                    throw ParseError()
                }
                if peek().kind != .end { try expect(";") }
            }
            if !assignsResult { return nil }
            let list = statements
            var unique: [String] = []
            for n in inputs where !unique.contains(n) { unique.append(n) }
            return FieldCalculation(unique) { valuesOf in
                let env = Env(valuesOf)
                for s in list where !s(env) { return nil }
                return env.result
            }
        }

        private func ident() throws -> String {
            let t = next()
            if t.kind != .ident || t.text.contains(".") { throw ParseError() }
            return t.text
        }

        private func simpleCalculate() throws -> (Env) -> Bool {
            _ = next()
            try expect("(")
            let op = next()
            if op.kind != .str { throw ParseError() }
            try expect(",")
            var names: [String] = []
            if accept("new") {
                if next().text != "Array" { throw ParseError() }
                try expect("(")
                try stringList(&names, ")")
            } else if accept("[") {
                try stringList(&names, "]")
            } else if peek().kind == .str {
                names += next().text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else {
                throw ParseError()
            }
            try expect(")")
            inputs += names
            let operation = op.text.uppercased()
            if !["SUM", "AVG", "PRD", "MIN", "MAX"].contains(operation) { throw ParseError() }
            return { env in
                let values = names.flatMap { env.valuesOf($0) }.map { FormScripts.toNumber($0) ?? 0 }
                if values.isEmpty {
                    env.result = 0
                    return true
                }
                switch operation {
                case "SUM": env.result = values.reduce(0, +)
                case "AVG": env.result = values.reduce(0, +) / Double(values.count)
                case "PRD": env.result = values.reduce(1, *)
                case "MIN": env.result = values.min()
                default: env.result = values.max()
                }
                return true
            }
        }

        private func stringList(_ into: inout [String], _ close: String) throws {
            while !accept(close) {
                let t = next()
                if t.kind != .str { throw ParseError() }
                into.append(t.text)
                if !accept(",") && peek().text != close { throw ParseError() }
            }
        }

        private func expr() throws -> Expr {
            var left = try term()
            while peek().kind == .op && (peek().text == "+" || peek().text == "-") {
                let op = next().text
                let right = try term()
                let l = left
                left = op == "+" ? { env in add(l(env), right(env), +) } : { env in add(l(env), right(env), -) }
            }
            return left
        }

        private func term() throws -> Expr {
            var left = try unary()
            while peek().kind == .op && ["*", "/", "%"].contains(peek().text) {
                let op = next().text
                let right = try unary()
                let l = left
                switch op {
                case "*": left = { env in add(l(env), right(env), *) }
                // Acrobat shows nothing useful for x/0; 0 keeps totals sane.
                case "/": left = { env in
                        guard let d = right(env), d != 0 else { return 0 }
                        return l(env).map { $0 / d }
                    }
                default: left = { env in
                        guard let d = right(env), d != 0 else { return 0 }
                        return l(env).map { $0.truncatingRemainder(dividingBy: d) }
                    }
                }
            }
            return left
        }

        private func unary() throws -> Expr {
            depth += 1
            defer { depth -= 1 }
            if depth > maxDepth { throw ParseError() }
            if peek().kind == .op && peek().text == "-" {
                _ = next()
                let e = try unary()
                return { env in e(env).map { -$0 } }
            }
            if peek().kind == .op && peek().text == "+" {
                _ = next()
                return try unary()
            }
            return try primary()
        }

        private func primary() throws -> Expr {
            let t = next()
            switch t.kind {
            case .num:
                guard let n = Double(t.text) else { throw ParseError() }
                return { _ in n }
            case .op where t.text == "(":
                let inner = try expr()
                try expect(")")
                return inner
            case .ident:
                switch t.text {
                case "this.getField", "getField":
                    try expect("(")
                    let name = next()
                    if name.kind != .str { throw ParseError() }
                    try expect(")")
                    let prop = next()
                    if prop.kind != .ident || (prop.text != ".value" && prop.text != ".valueAsString") { throw ParseError() }
                    inputs.append(name.text)
                    let field = name.text
                    return { env in env.valuesOf(field).first.map { FormScripts.toNumber($0) ?? 0 } ?? 0 }
                case "AFMakeNumber", "Number", "parseFloat", "Math.abs", "Math.round", "Math.floor", "Math.ceil":
                    try expect("(")
                    let arg = try expr()
                    try expect(")")
                    switch t.text {
                    case "Math.abs": return { env in arg(env).map { abs($0) } }
                    case "Math.round": return { env in arg(env).map { ($0 + 0.5).rounded(.down) } }
                    case "Math.floor": return { env in arg(env).map { $0.rounded(.down) } }
                    case "Math.ceil": return { env in arg(env).map { $0.rounded(.up) } }
                    default: return arg
                    }
                case "Math.min", "Math.max":
                    try expect("(")
                    var args = [try expr()]
                    while accept(",") { args.append(try expr()) }
                    try expect(")")
                    let min = t.text == "Math.min"
                    return { env in
                        let vals = args.map { $0(env) }
                        if vals.contains(where: { $0 == nil }) { return nil }
                        let nums = vals.compactMap { $0 }
                        return min ? nums.min() : nums.max()
                    }
                default:
                    if t.text.contains(".") { throw ParseError() }
                    let local = t.text
                    return { env in env.vars[local] ?? nil }
                }
            default:
                throw ParseError()
            }
        }
    }

    private static func add(_ a: Double?, _ b: Double?, _ op: (Double, Double) -> Double) -> Double? {
        guard let a, let b else { return nil }
        return op(a, b)
    }

    private enum TokenKind { case ident, num, str, op, end }

    private struct Token {
        var kind: TokenKind
        var text: String
        static let end = Token(kind: .end, text: "")
    }

    private static func isDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// JavaScript-ish tokens. Dotted member chains (this.getField, event.value, .value, Math.round) are one identifier.
    private static func tokenize(_ text: String) throws -> [Token] {
        let s = Array(text)
        var list: [Token] = []
        var i = 0
        while i < s.count {
            let c = s[i]
            if c.isWhitespace {
                i += 1
                continue
            }
            if c == "/" && i + 1 < s.count && s[i + 1] == "/" {
                while i < s.count && s[i] != "\n" { i += 1 }
                continue
            }
            if c == "/" && i + 1 < s.count && s[i + 1] == "*" {
                var j = i + 2
                while j + 1 < s.count && !(s[j] == "*" && s[j + 1] == "/") { j += 1 }
                i = j + 1 < s.count ? j + 2 : s.count
                continue
            }
            if c.isLetter || c == "_" || c == "$" || (c == "." && i + 1 < s.count && s[i + 1].isLetter) {
                let start = i
                while i < s.count && (s[i].isLetter || s[i].isNumber || s[i] == "_" || s[i] == "$" || s[i] == ".") { i += 1 }
                list.append(Token(kind: .ident, text: String(s[start..<i])))
                continue
            }
            if isDigit(c) || (c == "." && i + 1 < s.count && isDigit(s[i + 1])) {
                let start = i
                while i < s.count && (isDigit(s[i]) || s[i] == ".") { i += 1 }
                if i < s.count && (s[i] == "e" || s[i] == "E") {
                    i += 1
                    if i < s.count && (s[i] == "+" || s[i] == "-") { i += 1 }
                    while i < s.count && isDigit(s[i]) { i += 1 }
                }
                list.append(Token(kind: .num, text: String(s[start..<i])))
                continue
            }
            if c == "\"" || c == "'" {
                var sb = ""
                i += 1
                while i < s.count && s[i] != c {
                    if s[i] == "\\" && i + 1 < s.count {
                        i += 1
                        switch s[i] {
                        case "n": sb.append("\n")
                        case "t": sb.append("\t")
                        case "r": sb.append("\r")
                        default: sb.append(s[i])
                        }
                    } else {
                        sb.append(s[i])
                    }
                    i += 1
                }
                if i >= s.count { throw ParseError() }
                i += 1
                list.append(Token(kind: .str, text: sb))
                continue
            }
            if "()[],;=+-*/%".contains(c) {
                if c == "=" && i + 1 < s.count && s[i + 1] == "=" { throw ParseError() }
                list.append(Token(kind: .op, text: String(c)))
                i += 1
                continue
            }
            throw ParseError()
        }
        return list
    }

    // ---------------- Formats ----------------

    public static func parseFormat(_ script: String?) -> FieldFormat? {
        guard let script, !script.allSatisfy(\.isWhitespace), let tokens = try? tokenize(script) else { return nil }
        var i = 0
        while i + 1 < tokens.count {
            defer { i += 1 }
            guard tokens[i].kind == .ident, tokens[i + 1].text == "(", let args = arguments(tokens, i + 2) else { continue }
            func int(_ k: Int, _ def: Int) -> Int {
                if k < args.count, case .number(let d) = args[k] { return d.isFinite ? Int(max(min(d, 1e9), -1e9)) : def }
                return def
            }
            func str(_ k: Int) -> String {
                if k < args.count, case .string(let s) = args[k] { return s }
                return ""
            }
            func bool(_ k: Int, _ def: Bool) -> Bool {
                guard k < args.count else { return def }
                switch args[k] {
                case .bool(let b): return b
                case .number(let d): return d != 0
                default: return def
                }
            }
            switch tokens[i].text {
            case "AFNumber_Format":
                return FieldFormat(.number, decimals: min(max(int(0, 2), 0), 10), separatorStyle: int(1, 0), negativeStyle: int(2, 0),
                                   currency: str(4), currencyPrepend: bool(5, true))
            case "AFPercent_Format":
                return FieldFormat(.percent, decimals: min(max(int(0, 2), 0), 10), separatorStyle: int(1, 0), currencyPrepend: bool(2, false))
            case "AFDate_FormatEx" where !args.isEmpty, "AFDate_Format" where !args.isEmpty:
                let pattern: String
                if case .string(let p) = args[0] {
                    pattern = p
                } else {
                    let n = int(0, 0)
                    pattern = n >= 0 && n < dateFormats.count ? dateFormats[n] : "m/d/yy"
                }
                return FieldFormat(.date, datePattern: pattern)
            case "AFSpecial_Format":
                return FieldFormat(.special, special: int(0, 0))
            default:
                break
            }
        }
        return nil
    }

    static let dateFormats = ["m/d", "m/d/yy", "mm/dd/yy", "mm/yy", "d-mmm", "d-mmm-yy", "dd-mmm-yy", "yy-mm-dd", "mmm-yy",
                              "mmmm-yy", "mmm d, yyyy", "mmmm d, yyyy", "m/d/yy h:MM tt", "m/d/yy HH:MM"]

    private enum Arg { case number(Double), string(String), bool(Bool) }

    private static func arguments(_ tokens: [Token], _ start: Int) -> [Arg]? {
        var args: [Arg] = []
        var i = start
        while i < tokens.count {
            var t = tokens[i]
            if t.text == ")" && t.kind == .op { return args }
            var negative = false
            if t.kind == .op && t.text == "-" {
                negative = true
                i += 1
                t = i < tokens.count ? tokens[i] : .end
            }
            switch t.kind {
            // "1.2.3" tokenizes as a number too: a malformed script must not make every fill of the form fail.
            case .num:
                guard let n = Double(t.text) else { return nil }
                args.append(.number(negative ? -n : n))
            case .str: args.append(.string(t.text))
            case .ident where t.text == "true": args.append(.bool(true))
            case .ident where t.text == "false": args.append(.bool(false))
            default: return nil
            }
            i += 1
            if i < tokens.count && tokens[i].text == "," { i += 1 }
        }
        return nil
    }

    /// The text a format displays for a raw value, and whether it should be drawn red (negative styles 1 and 3).
    public static func format(_ format: FieldFormat, _ raw: String) -> (text: String, red: Bool) {
        if raw.isEmpty { return ("", false) }
        switch format.kind {
        case .number:
            guard let v = toNumber(raw) else { return (raw, false) }
            var body = grouped(abs(v), format.decimals, format.separatorStyle)
            let negative = v < 0 && roundAway(abs(v), format.decimals) != 0
            if !format.currency.isEmpty { body = format.currencyPrepend ? format.currency + body : body + format.currency }
            if !negative { return (body, false) }
            switch format.negativeStyle {
            case 1: return (body, true)
            case 2: return ("(\(body))", false)
            case 3: return ("(\(body))", true)
            default: return ("-" + body, false)
            }
        case .percent:
            guard let v = toNumber(raw) else { return (raw, false) }
            let body = grouped(abs(v * 100), format.decimals, format.separatorStyle)
            let sign = v < 0 && roundAway(abs(v * 100), format.decimals) != 0 ? "-" : ""
            return (format.currencyPrepend ? sign + "%" + body : sign + body + "%", false)
        case .date:
            return (parseDate(raw, format.datePattern).map { formatDate($0, format.datePattern) } ?? raw, false)
        case .special:
            let digits = Array(raw.filter { $0.isASCII && $0.isNumber })
            func part(_ a: Int, _ b: Int) -> String { String(digits[a..<b]) }
            let text: String
            switch (format.special, digits.count) {
            case (0, 5): text = String(digits)
            case (1, 9): text = "\(part(0, 5))-\(part(5, 9))"
            case (2, 10): text = "(\(part(0, 3))) \(part(3, 6))-\(part(6, 10))"
            case (2, 7): text = "\(part(0, 3))-\(part(3, 7))"
            case (3, 9): text = "\(part(0, 3))-\(part(3, 5))-\(part(5, 9))"
            default: text = raw
            }
            return (text, false)
        }
    }

    /// Rounded half away from zero to `decimals` places (.NET's `MidpointRounding.AwayFromZero`).
    private static func roundAway(_ v: Double, _ decimals: Int) -> Double {
        let m = pow(10.0, Double(decimals))
        let scaled = v * m
        return scaled.isFinite && abs(scaled) < 1e17 ? scaled.rounded(.toNearestOrAwayFromZero) / m : v
    }

    private static func grouped(_ v: Double, _ decimals: Int, _ style: Int) -> String {
        let s = String(format: "%.\(decimals)f", roundAway(v, decimals))
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        let intPart = Array(parts[0])
        let frac = parts.count > 1 ? String(parts[1]) : ""
        let (group, dec): (String, String)
        switch style {
        case 1: (group, dec) = ("", ".")
        case 2: (group, dec) = (".", ",")
        case 3: (group, dec) = ("", ",")
        case 4: (group, dec) = ("'", ".")
        default: (group, dec) = (",", ".")
        }
        var sb = ""
        for (i, c) in intPart.enumerated() {
            if i > 0 && (intPart.count - i) % 3 == 0 { sb += group }
            sb.append(c)
        }
        return frac.isEmpty ? sb : sb + dec + frac
    }

    private static let dateTokens = ["mmmm", "mmm", "mm", "m", "dddd", "ddd", "dd", "d", "yyyy", "yy", "HH", "H", "hh", "h", "MM", "M",
                                     "ss", "s", "tt", "t"]

    private typealias Part = (token: Bool, text: String)

    private static func splitPattern(_ pattern: String) -> [Part] {
        let p = Array(pattern)
        var parts: [Part] = []
        var i = 0
        while i < p.count {
            if p[i] == "\\" && i + 1 < p.count {
                parts.append((false, String(p[i + 1])))
                i += 2
                continue
            }
            if let tok = dateTokens.first(where: { t in i + t.count <= p.count && String(p[i..<i + t.count]) == t }) {
                parts.append((true, tok))
                i += tok.count
            } else {
                parts.append((false, String(p[i])))
                i += 1
            }
        }
        return parts
    }

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October",
                             "November", "December"]
    static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// Formats a date with an Acrobat pattern (util.printd style; English month and day names).
    public static func formatDate(_ d: FormDate, _ pattern: String) -> String {
        func two(_ n: Int) -> String { String(format: "%02d", n) }
        let h12 = d.hour % 12 == 0 ? 12 : d.hour % 12
        var sb = ""
        for (isToken, text) in splitPattern(pattern) {
            guard isToken else {
                sb += text
                continue
            }
            switch text {
            case "mmmm": sb += monthNames[d.month - 1]
            case "mmm": sb += String(monthNames[d.month - 1].prefix(3))
            case "mm": sb += two(d.month)
            case "m": sb += String(d.month)
            case "dddd": sb += dayNames[d.weekday]
            case "ddd": sb += String(dayNames[d.weekday].prefix(3))
            case "dd": sb += two(d.day)
            case "d": sb += String(d.day)
            case "yyyy": sb += String(format: "%04d", d.year)
            case "yy": sb += two(d.year % 100)
            case "HH": sb += two(d.hour)
            case "H": sb += String(d.hour)
            case "hh": sb += two(h12)
            case "h": sb += String(h12)
            case "MM": sb += two(d.minute)
            case "M": sb += String(d.minute)
            case "ss": sb += two(d.second)
            case "s": sb += String(d.second)
            case "tt": sb += d.hour < 12 ? "am" : "pm"
            case "t": sb += d.hour < 12 ? "a" : "p"
            default: sb += text
            }
        }
        return sb
    }

    /// Reads a typed date the way Acrobat's AFParseDateEx does: in the field's own pattern, then leniently in the same
    /// order (single-digit days and months, two-digit years, any separators: "3/4/25" for dd/mm/yyyy is 3 April), then
    /// ISO and spelled-out month forms. Only a pattern without a day/month order falls back to US and general forms.
    public static func parseDate(_ text: String, _ pattern: String) -> FormDate? {
        let raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = splitPattern(pattern)
        // Exact first, then with every number allowed one or two digits (dd → d, mm → m, HH → H...), same order.
        for lenient in [false, true] {
            if let exact = DatePattern(acrobat: parts, lenient: lenient).match(raw) { return exact }
        }
        if let d = DatePattern.firstMatch(raw, ["yyyy-MM-dd", "yyyy-MM-ddTHH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyyMMdd"]) {
            return d
        }
        if let ordered = parseInOrder(raw, parts) { return ordered }
        if let d = DatePattern.firstMatch(raw, ["d-MMM-yyyy", "d MMM yyyy", "d MMMM yyyy", "MMM d, yyyy", "MMMM d, yyyy"]) { return d }
        // A pattern that doesn't say whether the day or the month comes first: the usual US and general forms (where
        // Windows also tries .NET's culture-dependent parsing).
        if parts.contains(where: { $0.token && ["d", "dd", "m", "mm"].contains($0.text) }) { return nil }
        return DatePattern.firstMatch(raw, ["M/d/yyyy", "M/d/yy", "MM/dd/yyyy", "M/d/yyyy H:mm", "M/d/yyyy H:mm:ss", "M/d/yyyy h:mm tt",
                                            "H:mm", "H:mm:ss", "h:mm tt", "h:mm:ss tt", "h tt", "yyyy-M-d", "yyyy/M/d", "MMMM d yyyy",
                                            "d MMMM, yyyy", "yyyy-MM-ddTHH:mm:ssZ", "yyyy-MM-ddTHH:mm"])
    }

    /// AFParseDateEx's fallback: the numbers in the text, taken in the order the pattern puts day, month and year (and
    /// then hours, minutes, seconds), a spelled-out month wherever it is; a missing year is this year, a missing day the
    /// 1st; two-digit years are 19xx from 50 up, else 20xx.
    private static func parseInOrder(_ raw: String, _ parts: [Part]) -> FormDate? {
        var order: [Character] = []
        for (isToken, text) in parts where isToken {
            let slot: Character?
            switch text {
            case "d", "dd": slot = "d"
            case "m", "mm", "mmm", "mmmm": slot = "m"
            case "yy", "yyyy": slot = "y"
            case "H", "HH", "h", "hh": slot = "H"
            case "M", "MM": slot = "M"
            case "s", "ss": slot = "s"
            default: slot = nil
            }
            if let slot, !order.contains(slot) { order.append(slot) }
        }
        if !order.contains("d") && !order.contains("m") { return nil }

        // A month name (or its first three letters) anywhere fills the month.
        var month: Int?
        for word in runs(raw, \.isLetter) where word.count >= 3 {
            if let i = monthNames.firstIndex(where: { $0.lowercased().hasPrefix(word.lowercased()) && (word.count == $0.count || word.count == 3) }) {
                month = i + 1
                break
            }
        }
        let numbers = runs(raw) { $0.isASCII && $0.isNumber }
        let slots = order.filter { $0 != "m" || month == nil }
        if numbers.isEmpty || numbers.count > slots.count || numbers.contains(where: { $0.count > 4 }) { return nil }
        var values: [Character: Int] = [:]
        for (i, n) in numbers.enumerated() { values[slots[i]] = Int(n) ?? 0 }
        if let month { values["m"] = month }
        // A date part left out (other than the year) means the text is too short to read safely.
        if (order.contains("d") && values["d"] == nil) || values["m"] == nil { return nil }
        let year: Int
        if let y = values["y"], let at = slots.firstIndex(of: "y") {
            year = y < 100 && numbers[at].count <= 2 ? (y >= 50 ? 1900 + y : 2000 + y) : y
        } else {
            year = FormDate.today.year
        }
        var hour = values["H"] ?? 0
        if parts.contains(where: { $0.token && ($0.text == "tt" || $0.text == "t") }) && hour < 12
            && raw.range(of: #"\bp"#, options: [.regularExpression, .caseInsensitive]) != nil {
            hour += 12
        }
        return FormDate(year, values["m"] ?? 0, values["d"] ?? 1, hour, values["M"] ?? 0, values["s"] ?? 0)
    }

    /// The runs of characters in `s` that pass `test`.
    private static func runs(_ s: String, _ test: (Character) -> Bool) -> [String] {
        var out: [String] = []
        var cur = ""
        for c in s {
            if test(c) {
                cur.append(c)
            } else if !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// Exact date parsing with a fixed pattern (the parts of .NET's `DateTime.TryParseExact` the form code uses, with
/// whitespace allowed around and between the parts): numbers with fixed or one-or-two digits, English month and day
/// names, AM/PM, literals. A date without a day is the 1st, without a year this year, without any date part today.
struct DatePattern {
    enum Element {
        case number(field: Character, min: Int, max: Int)
        case monthName(full: Bool)
        case dayName(full: Bool)
        case ampm
        case literal(Character)
    }

    var elements: [Element]

    /// From an Acrobat pattern (FormScripts' parts); `lenient` lets every number have one or two digits.
    init(acrobat parts: [(token: Bool, text: String)], lenient: Bool) {
        elements = []
        for (isToken, text) in parts {
            guard isToken else {
                elements += text.map { Element.literal($0) }
                continue
            }
            let fixed = lenient ? 1 : 2
            switch text {
            case "mmmm": elements.append(.monthName(full: true))
            case "mmm": elements.append(.monthName(full: false))
            case "mm": elements.append(.number(field: "m", min: fixed, max: 2))
            case "m": elements.append(.number(field: "m", min: 1, max: 2))
            case "dddd": elements.append(.dayName(full: true))
            case "ddd": elements.append(.dayName(full: false))
            case "dd": elements.append(.number(field: "d", min: fixed, max: 2))
            case "d": elements.append(.number(field: "d", min: 1, max: 2))
            case "yyyy": elements.append(.number(field: "y", min: 4, max: 4))
            case "yy": elements.append(.number(field: "Y", min: 2, max: 2))
            case "HH": elements.append(.number(field: "H", min: fixed, max: 2))
            case "H": elements.append(.number(field: "H", min: 1, max: 2))
            case "hh": elements.append(.number(field: "h", min: fixed, max: 2))
            case "h": elements.append(.number(field: "h", min: 1, max: 2))
            case "MM": elements.append(.number(field: "M", min: fixed, max: 2))
            case "M": elements.append(.number(field: "M", min: 1, max: 2))
            case "ss": elements.append(.number(field: "s", min: fixed, max: 2))
            case "s": elements.append(.number(field: "s", min: 1, max: 2))
            default: elements.append(.ampm) // tt, t
            }
        }
    }

    /// From a .NET pattern (yyyy, yy, MMMM, MMM, MM, M, dd, d, HH, H, hh, h, mm, m, ss, s, tt; anything else literal).
    init(net pattern: String) {
        let p = Array(pattern)
        elements = []
        var i = 0
        while i < p.count {
            let c = p[i]
            var n = 1
            while i + n < p.count && p[i + n] == c { n += 1 }
            switch c {
            case "y": elements.append(n >= 4 ? .number(field: "y", min: 4, max: 4) : .number(field: "Y", min: 2, max: 2))
            case "M": elements.append(n >= 4 ? .monthName(full: true) : n == 3 ? .monthName(full: false) : .number(field: "m", min: n, max: 2))
            case "d": elements.append(.number(field: "d", min: n, max: 2))
            case "H": elements.append(.number(field: "H", min: n, max: 2))
            case "h": elements.append(.number(field: "h", min: n, max: 2))
            case "m": elements.append(.number(field: "M", min: n, max: 2))
            case "s": elements.append(.number(field: "s", min: n, max: 2))
            case "t": elements.append(.ampm)
            default:
                elements += Array(repeating: Element.literal(c), count: n)
            }
            i += n
        }
    }

    static func firstMatch(_ raw: String, _ patterns: [String]) -> FormDate? {
        for p in patterns {
            if let d = DatePattern(net: p).match(raw) { return d }
        }
        return nil
    }

    func match(_ text: String) -> FormDate? {
        let s = Array(text)
        var i = 0
        var values: [Character: Int] = [:]
        var pm: Bool?
        var weekday: Int?
        func skipSpace() { while i < s.count && s[i].isWhitespace { i += 1 } }
        func word() -> String {
            var w = ""
            while i < s.count && s[i].isLetter {
                w.append(s[i])
                i += 1
            }
            return w.lowercased()
        }
        skipSpace()
        for e in elements {
            switch e {
            case .literal(let c):
                if c.isWhitespace {
                    skipSpace()
                    continue
                }
                skipSpace()
                guard i < s.count, s[i] == c else { return nil }
                i += 1
            case .number(let field, let min, let max):
                skipSpace()
                var digits = ""
                while i < s.count && digits.count < max && s[i].isASCII && s[i].isNumber {
                    digits.append(s[i])
                    i += 1
                }
                guard digits.count >= min, let v = Int(digits) else { return nil }
                values[field] = v
            case .monthName(let full):
                skipSpace()
                let w = word()
                guard let m = FormScripts.monthNames.firstIndex(where: { full ? $0.lowercased() == w : $0.prefix(3).lowercased() == w }) else { return nil }
                values["m"] = m + 1
            case .dayName(let full):
                skipSpace()
                let w = word()
                guard let d = FormScripts.dayNames.firstIndex(where: { full ? $0.lowercased() == w : $0.prefix(3).lowercased() == w }) else { return nil }
                weekday = d
            case .ampm:
                skipSpace()
                let w = word()
                switch w {
                case "am", "a": pm = false
                case "pm", "p": pm = true
                default: return nil
                }
            }
        }
        skipSpace()
        guard i == s.count else { return nil }
        let today = FormDate.today
        let hasDate = values["y"] != nil || values["Y"] != nil || values["m"] != nil || values["d"] != nil
        var year = values["y"] ?? values["Y"].map { $0 <= 49 ? 2000 + $0 : 1900 + $0 } ?? today.year
        var month = values["m"] ?? 1
        var day = values["d"] ?? 1
        if !hasDate {
            (year, month, day) = (today.year, today.month, today.day)
        }
        var hour = values["H"] ?? 0
        if let h = values["h"] {
            guard (1...12).contains(h) || (pm == nil && h == 0) else { return nil }
            hour = h % 12
        }
        if let pm {
            guard values["H"].map({ $0 <= 12 }) ?? true else { return nil }
            if values["h"] == nil { hour %= 12 }
            if pm { hour += 12 }
        }
        guard let d = FormDate(year, month, day, hour, values["M"] ?? 0, values["s"] ?? 0) else { return nil }
        if let weekday, weekday != d.weekday { return nil }
        return d
    }
}
