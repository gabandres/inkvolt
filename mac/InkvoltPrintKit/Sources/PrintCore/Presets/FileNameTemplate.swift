import Foundation

/// What a file-name template's tokens stand for when a scan is saved.
public struct NameContext: Sendable {
    public var now: Date
    public var preset: String
    public var printer: String
    /// The preset's counter, `{n}`.
    public var number: Int
    /// Pages saved, `{pages}`.
    public var pages: Int
    /// For date and time formats: the clock (time zone) and the month and day names (locale).
    public var timeZone: TimeZone
    public var locale: Locale

    public init(now: Date, preset: String, printer: String, number: Int, pages: Int, timeZone: TimeZone = .current, locale: Locale = .current) {
        self.now = now
        self.preset = preset
        self.printer = printer
        self.number = number
        self.pages = pages
        self.timeZone = timeZone
        self.locale = locale
    }
}

/// File-name and subfolder templates for scan presets: `{date}` / `{date:yyyy-MM}`, `{time}` / `{time:HH.mm}`, `{preset}`,
/// `{printer}`, `{n}` / `{n:000}` (the preset's counter), `{pages}`; `{{` and `}}` are literal braces. Date and number
/// formats are .NET's custom ones, so presets mean the same on both apps. Names come out safe on Windows too (they may land
/// in a synced folder): no reserved characters or device names, no trailing dots or spaces, never empty; subfolders never
/// leave the chosen folder; and a name already taken gets `-2`, `-3`… so nothing is overwritten.
public enum FileNameTemplate {
    /// Longest file name (without extension) a template makes.
    public static let maxNameLength = 120

    private static let defaultDate = "yyyy-MM-dd", defaultTime = "HHmm"
    private static let fallback = "Scan"
    private static let tokenList = "{date}, {time}, {preset}, {printer}, {n} or {pages}"

    // Windows' reserved characters, whatever the OS (a Mac's names may sync to a PC).
    private static let reserved: Set<Character> = ["<", ">", ":", "\"", "/", "\\", "|", "?", "*"]

    private static let deviceNames: Set<String> = [
        "con", "prn", "aux", "nul",
        "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
        "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9",
        // Windows also maps the superscript digits (Latin-1's ¹ ² ³) and the console handles.
        "com¹", "com²", "com³", "lpt¹", "lpt²", "lpt³", "conin$", "conout$",
    ]

    private enum Kind { case text, token, separator }

    private struct Part {
        var kind: Kind
        var text: String
        var format: String?
    }

    /// What's wrong with the template, in words for the editor; nil when it's fine.
    public static func problem(_ template: String?) -> String? {
        let (parts, error) = parse(template ?? "")
        for part in parts where part.kind == .token {
            switch part.text.lowercased() {
            case "date", "time":
                if let f = part.format, DotNetFormat.date(f, Date(timeIntervalSince1970: 0), TimeZone(identifier: "UTC")!, Locale(identifier: "en_US_POSIX")) == nil {
                    return "{\(part.text):\(f)} isn't a date or time format."
                }
            case "n":
                break
            case "preset", "printer", "pages":
                if part.format != nil { return "{\(part.text)} takes no format." }
            default:
                return "Unknown token {\(part.text)}. Use \(tokenList)."
            }
        }
        return error
    }

    /// The template as one safe file name (no extension). Unknown tokens stay as typed.
    public static func fileName(_ template: String?, _ ctx: NameContext) -> String {
        sanitize(parse(template ?? "").parts.map { $0.kind == .token ? value($0, ctx) : $0.text }.joined())
    }

    /// The template as a relative folder path ("" = none): `/` and `\` outside tokens separate folders; each folder name is
    /// made safe, and empty, `.` and `..` parts are dropped, so it never leaves the chosen folder. Joined with "/".
    public static func subfolder(_ template: String?, _ ctx: NameContext) -> String {
        var segments: [String] = []
        var current = ""
        func flush() {
            let safe = sanitize(current, fallback: nil)
            if !safe.isEmpty { segments.append(safe) }
            current = ""
        }
        for part in parse(template ?? "").parts {
            switch part.kind {
            case .separator: flush()
            case .token: current += value(part, ctx)
            case .text: current += part.text
            }
        }
        flush()
        return segments.joined(separator: "/")
    }

    /// `stem` + `extension` in `folder`, else stem-2, stem-3… (first free).
    public static func uniquePath(_ folder: String, _ stem: String, _ ext: String, exists: (String) -> Bool) throws -> String {
        try uniquePaths(folder, stem, ext, count: 1, exists: exists)[0]
    }

    /// Names for `count` files saved together (images of one scan): "stem (1).jpg", "stem (2).jpg"…, or just "stem.jpg" for
    /// one. When any of them is taken, the whole set moves on to stem-2, stem-3…, so a scan's pages keep one name.
    public static func uniquePaths(_ folder: String, _ stem: String, _ ext: String, count: Int, exists: (String) -> Bool) throws -> [String] {
        precondition(count >= 1)
        for attempt in 1..<10_000 {
            let name = attempt == 1 ? stem : "\(stem)-\(attempt)"
            let set = count == 1 ? [join(folder, name + ext)] : (1...count).map { join(folder, "\(name) (\($0))\(ext)") }
            if !set.contains(where: exists) { return set }
        }
        throw CocoaError(.fileWriteFileExists, userInfo: [NSLocalizedDescriptionKey: "Too many files called \"\(stem)\" in \(folder)."])
    }

    /// Moves files already written under temporary names to their final names as one set, never over another file: when a
    /// name turns out to be taken (another program saved there since `uniquePaths` looked), the files moved so far go back
    /// and the whole set tries the next free stem, so a scan's pages are never split across names.
    /// - Parameter tryMove: moves the first path to the second unless the second exists (then false; nothing moved).
    /// - Returns: the final paths, in the order of `temps`.
    public static func placeSet(_ temps: [String], _ folder: String, _ stem: String, _ ext: String, exists: (String) -> Bool,
                                tryMove: (String, String) -> Bool) throws -> [String] {
        for _ in 0..<20 {
            let targets = try uniquePaths(folder, stem, ext, count: temps.count, exists: exists)
            var moved = 0
            while moved < temps.count && tryMove(temps[moved], targets[moved]) { moved += 1 }
            if moved == temps.count { return targets }
            for i in stride(from: moved - 1, through: 0, by: -1) where !tryMove(targets[i], temps[i]) {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't put \(targets[i]) back while picking another name."])
            }
        }
        throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "Couldn't find a free name for \"\(stem)\" in \(folder)."])
    }

    private static func join(_ folder: String, _ name: String) -> String { folder.hasSuffix("/") ? folder + name : folder + "/" + name }

    /// One safe file or folder name: reserved and control characters become '-', no leading or trailing spaces, no trailing
    /// dots, no device names.
    public static func sanitize(_ name: String) -> String { sanitize(name, fallback: fallback) }

    private static func sanitize(_ name: String, fallback: String?) -> String {
        var s = String(name.map { c -> Character in
            if let a = c.asciiValue, a < 32 { return "-" }
            return reserved.contains(c) ? "-" : c
        }).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count > maxNameLength { s = String(s.prefix(maxNameLength)) }
        while let last = s.last, last == "." || last == " " { s.removeLast() }
        while s.first == " " { s.removeFirst() }
        if s.isEmpty { return fallback ?? "" }
        // "CON", "nul.txt": Windows maps these to devices whatever the extension.
        let stem = s.firstIndex(of: ".").map { String(s[..<$0]) } ?? s
        var trimmedStem = stem
        while trimmedStem.last == " " { trimmedStem.removeLast() }
        if deviceNames.contains(trimmedStem.lowercased()) {
            let rest = s.firstIndex(of: ".").map { String(s[$0...]) } ?? ""
            s = stem + "_" + rest
        }
        return s
    }

    private static func value(_ token: Part, _ ctx: NameContext) -> String {
        switch token.text.lowercased() {
        case "date": return DotNetFormat.date(token.format ?? defaultDate, ctx.now, ctx.timeZone, ctx.locale) ?? literal(token)
        case "time": return DotNetFormat.date(token.format ?? defaultTime, ctx.now, ctx.timeZone, ctx.locale) ?? literal(token)
        case "n": return DotNetFormat.number(ctx.number, token.format ?? "0") ?? literal(token)
        case "preset" where token.format == nil: return ctx.preset
        case "printer" where token.format == nil: return ctx.printer
        case "pages" where token.format == nil: return String(ctx.pages)
        default: return literal(token)
        }
    }

    private static func literal(_ token: Part) -> String { token.format.map { "{\(token.text):\($0)}" } ?? "{\(token.text)}" }

    /// Splits into text, tokens and (outside tokens) folder separators. A stray brace is kept as text and reported.
    private static func parse(_ template: String) -> (parts: [Part], error: String?) {
        var error: String?
        var parts: [Part] = []
        var text = ""
        func flushText() {
            if !text.isEmpty { parts.append(Part(kind: .text, text: text)) }
            text = ""
        }
        let chars = Array(template)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" && i + 1 < chars.count && chars[i + 1] == "{" {
                text.append("{")
                i += 1
            } else if c == "}" && i + 1 < chars.count && chars[i + 1] == "}" {
                text.append("}")
                i += 1
            } else if c == "{" {
                guard let end = chars[(i + 1)...].firstIndex(of: "}") else {
                    if error == nil { error = "A { has no closing }. Type {{ for a brace." }
                    text += String(chars[i...])
                    break
                }
                flushText()
                let body = String(chars[(i + 1)..<end])
                if let colon = body.firstIndex(of: ":") {
                    parts.append(Part(kind: .token, text: body[..<colon].trimmingCharacters(in: .whitespaces), format: String(body[body.index(after: colon)...])))
                } else {
                    parts.append(Part(kind: .token, text: body.trimmingCharacters(in: .whitespaces)))
                }
                i = end
            } else if c == "}" {
                if error == nil { error = "A } has no opening {. Type }} for a brace." }
                text.append(c)
            } else if c == "/" || c == "\\" {
                flushText()
                parts.append(Part(kind: .separator, text: String(c)))
            } else {
                text.append(c)
            }
            i += 1
        }
        flushText()
        return (parts, error)
    }
}

/// .NET's custom date and number formats (the parts presets use), so a template means the same on both apps.
enum DotNetFormat {
    /// A date in a .NET custom format: d dd ddd dddd, M MM MMM MMMM, y yy yyy yyyy, h hh H HH, m mm, s ss, f…, t tt, quoted
    /// text, `\` escapes; other characters as they are. Nil for a format .NET would reject (an unclosed quote).
    static func date(_ format: String, _ date: Date, _ timeZone: TimeZone, _ locale: Locale) -> String? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond, .weekday], from: date)
        let names = DateFormatter()
        names.locale = locale
        names.calendar = calendar
        names.timeZone = timeZone
        let chars = Array(format)
        var out = ""
        var i = 0
        func run(_ ch: Character) -> Int {
            var n = 0
            while i + n < chars.count && chars[i + n] == ch { n += 1 }
            return n
        }
        func pad(_ v: Int, _ width: Int) -> String {
            let s = String(v)
            return s.count >= width ? s : String(repeating: "0", count: width - s.count) + s
        }
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "d":
                let n = run(ch)
                if n <= 2 { out += pad(c.day!, n) } else {
                    let w = c.weekday! - 1
                    out += n == 3 ? names.shortWeekdaySymbols[w] : names.weekdaySymbols[w]
                }
                i += n
            case "M":
                let n = run(ch)
                out += n <= 2 ? pad(c.month!, n) : n == 3 ? names.shortMonthSymbols[c.month! - 1] : names.monthSymbols[c.month! - 1]
                i += n
            case "y":
                let n = run(ch)
                out += n <= 2 ? pad(c.year! % 100, n) : pad(c.year!, n)
                i += n
            case "h":
                let n = run(ch)
                let h = c.hour! % 12
                out += pad(h == 0 ? 12 : h, min(n, 2))
                i += n
            case "H":
                let n = run(ch)
                out += pad(c.hour!, min(n, 2))
                i += n
            case "m":
                let n = run(ch)
                out += pad(c.minute!, min(n, 2))
                i += n
            case "s":
                let n = run(ch)
                out += pad(c.second!, min(n, 2))
                i += n
            case "f", "F":
                let n = run(ch)
                let digits = String(pad(c.nanosecond! / 1000, 6).prefix(min(n, 6)))
                out += ch == "F" ? String(digits.reversed().drop(while: { $0 == "0" }).reversed()) : digits
                i += n
            case "t":
                let n = run(ch)
                // An optional on some platforms, not on others.
                let am: String? = names.amSymbol, pm: String? = names.pmSymbol
                let marker = c.hour! < 12 ? am ?? "AM" : pm ?? "PM"
                out += n == 1 ? String(marker.prefix(1)) : marker
                i += n
            case "'", "\"":
                guard let close = chars[(i + 1)...].firstIndex(of: ch) else { return nil }
                out += String(chars[(i + 1)..<close])
                i = close + 1
            case "\\":
                guard i + 1 < chars.count else { return nil }
                out.append(chars[i + 1])
                i += 2
            default:
                out.append(ch)
                i += 1
            }
        }
        return out
    }

    /// A whole number in a .NET format: custom (`0` pads, `#` doesn't, other characters as they are) or `D<n>`. Nil
    /// otherwise.
    static func number(_ value: Int, _ format: String) -> String? {
        if let first = format.first, first == "D" || first == "d", let width = Int(format.dropFirst()) ?? (format.count == 1 ? 0 : nil) {
            let s = String(abs(value))
            return (value < 0 ? "-" : "") + (s.count >= width ? s : String(repeating: "0", count: width - s.count) + s)
        }
        guard format.contains(where: { $0 == "0" || $0 == "#" }) else { return format.isEmpty ? String(value) : nil }
        let zeros = format.filter { $0 == "0" }.count
        var digits = String(abs(value))
        if digits.count < zeros { digits = String(repeating: "0", count: zeros - digits.count) + digits }
        if value == 0 && zeros == 0 { digits = "" }
        // The digits take the place of the placeholders, the rest of the format stays around them.
        let first = format.firstIndex { $0 == "0" || $0 == "#" }!
        let last = format.lastIndex { $0 == "0" || $0 == "#" }!
        return String(format[..<first]) + (value < 0 ? "-" : "") + digits + String(format[format.index(after: last)...])
    }
}
