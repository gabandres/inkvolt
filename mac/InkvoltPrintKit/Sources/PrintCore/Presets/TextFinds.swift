import Foundation

/// A day as a page writes it (no time, no time zone): what `{text-date}` names a file with.
public struct TextDate: Hashable, Sendable {
    public var year: Int, month: Int, day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Midnight of the day in UTC, which `DotNetFormat.date` writes with UTC's clock.
    var date: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TextDate.utc
        return calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? Date(timeIntervalSince1970: 0)
    }

    static let utc = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0)!
}

/// What a scan's first page says that can name its file (roadmap 4.11): a `date` found on it, its `title` (the first
/// heading, else its first line) and an invoice-like `number`. Each nil when the page doesn't say.
public struct FoundInText: Equatable, Sendable {
    public var date: TextDate?
    public var title: String?
    public var number: String?

    public init(date: TextDate? = nil, title: String? = nil, number: String? = nil) {
        self.date = date
        self.title = title
        self.number = number
    }

    public static let none = FoundInText()
}

/// Reads `FoundInText` from a page's recognized text, for the file-name template's `{text-date}`, `{text-title}` and
/// `{text-number}`. Dates: 2026-03-04, 3/4/2026 or 4.3.26 (day or month first as the locale writes them, unless one of them
/// is over 12), "March 4, 2026", "4 March 2026", "4 de marzo de 2026"; one on a line that says date ("Date", "Fecha",
/// "Dated") comes first. A number: what follows "Invoice", "Order", "Receipt", "No.", "#", "Factura"… and has a digit, else
/// a code like INV-20931. Never trusts the text: lines and lengths are bounded. Windows' `TextFinds`, with a `Locale` for its
/// `CultureInfo`.
public enum TextFinds {
    /// Longest title kept (characters, cut at a word).
    public static let maxTitle = 60

    /// Lines read from the top of the page.
    public static let maxLines = 200

    private static let maxLineLength = 500

    public static func find(_ words: [PdfWriter.Word]?, locale: Locale = .current) -> FoundInText {
        find(lines: PageText.lines(words), locale: locale)
    }

    public static func find(lines: [TextLine], locale: Locale = .current) -> FoundInText {
        let read = lines.prefix(maxLines).map { l -> TextLine in
            var cut = l
            if cut.text.count > maxLineLength { cut.text = String(cut.text.prefix(maxLineLength)) }
            return cut
        }
        let texts = read.map(\.text)
        return FoundInText(date: findDate(texts, locale), title: findTitle(read), number: findNumber(texts))
    }

    // ---- Dates ----

    private static func regex(_ pattern: String, ignoreCase: Bool = false) -> NSRegularExpression {
        // A literal pattern: it compiles or the tests fail on the first call.
        try! NSRegularExpression(pattern: pattern, options: ignoreCase ? [.caseInsensitive] : [])
    }

    private static let isoDate = regex(#"\b(\d{4})[-./](\d{1,2})[-./](\d{1,2})\b"#)
    private static let numericDate = regex(#"\b(\d{1,2})[-./](\d{1,2})[-./](\d{4}|\d{2})\b"#)
    private static let dayMonthYear = regex(#"\b(\d{1,2})(?:st|nd|rd|th|º)?\.?\s+(?:de\s+)?(\p{L}{3,10})\.?,?\s+(?:de\s+|del\s+)?(\d{4})\b"#, ignoreCase: true)
    private static let monthDayYear = regex(#"\b(\p{L}{3,10})\.?\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})\b"#, ignoreCase: true)
    private static let dateWord = regex(#"\b(date|dated|fecha|issued|emitid[ao])\b"#, ignoreCase: true)

    /// A match's place in the line and its groups ("" for one that took no part).
    private struct Found {
        var at: Int
        var groups: [String]
    }

    private static func matches(_ re: NSRegularExpression, _ text: String) -> [Found] {
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { m in
            Found(at: m.range.location, groups: (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i)
                return r.location == NSNotFound ? "" : ns.substring(with: r)
            })
        }
    }

    private static func isMatch(_ re: NSRegularExpression, _ text: String) -> Bool {
        re.firstMatch(in: text, range: NSRange(location: 0, length: (text as NSString).length)) != nil
    }

    /// The first date on the page, one on a line that says it is the date first.
    static func findDate(_ lines: [String], _ locale: Locale) -> TextDate? {
        let months = monthNames(locale)
        let dayFirst = dayFirst(locale)
        var first: TextDate?
        for line in lines {
            guard let date = dateIn(line, months, dayFirst) else { continue }
            if isMatch(dateWord, line) { return date }
            if first == nil { first = date }
        }
        return first
    }

    /// Whether the locale writes the day before the month (es-MX "dd/MM/yy"), not after it (en-US "M/d/yy"; the year-first
    /// "y/MM/dd" of ja-JP, zh-CN, ko-KR, sv-SE, hu-HU): by where d and M stand in its short date.
    public static func dayFirst(_ locale: Locale) -> Bool {
        let f = DateFormatter()
        f.locale = locale
        f.dateStyle = .short
        f.timeStyle = .none
        let pattern = f.dateFormat ?? ""
        guard let d = pattern.firstIndex(of: "d") else { return false }
        guard let m = pattern.firstIndex(where: { $0 == "M" || $0 == "L" }) else { return true }
        return d < m
    }

    private static func dateIn(_ line: String, _ months: [String: Int], _ dayFirst: Bool) -> TextDate? {
        var found: [(at: Int, date: TextDate)] = []
        for m in matches(isoDate, line) {
            if let d = make(int(m, 1), int(m, 2), int(m, 3)) { found.append((m.at, d)) }
        }
        for m in matches(numericDate, line) {
            let (a, b) = (int(m, 1), int(m, 2))
            var y = int(m, 3)
            if m.groups[3].count == 2 { y += y < 70 ? 2000 : 1900 }
            let day = a > 12 ? true : b > 12 ? false : dayFirst // one over 12 can only be the day
            if let d = make(y, day ? b : a, day ? a : b) { found.append((m.at, d)) }
        }
        for m in matches(dayMonthYear, line) {
            if let month = months[m.groups[2].lowercased()], let d = make(int(m, 3), month, int(m, 1)) { found.append((m.at, d)) }
        }
        for m in matches(monthDayYear, line) {
            if let month = months[m.groups[1].lowercased()], let d = make(int(m, 3), month, int(m, 2)) { found.append((m.at, d)) }
        }
        return found.min { $0.at < $1.at }?.date
    }

    /// The group as a whole number of ASCII digits (.NET's `NumberStyles.None`), else -1.
    private static func int(_ m: Found, _ group: Int) -> Int {
        let s = m.groups[group]
        guard !s.isEmpty, s.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return -1 }
        return Int(s) ?? -1
    }

    private static func make(_ year: Int, _ month: Int, _ day: Int) -> TextDate? {
        guard (1900...2100).contains(year), (1...12).contains(month), day >= 1, day <= daysIn(year, month) else { return nil }
        return TextDate(year, month, day)
    }

    private static func daysIn(_ year: Int, _ month: Int) -> Int {
        switch month {
        case 2: return year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Month names and short names, lower case and without dots: English, Spanish and the locale's own.
    private static func monthNames(_ locale: Locale) -> [String: Int] {
        var names: [String: Int] = [:]
        for l in [Locale(identifier: "en_US_POSIX"), Locale(identifier: "es"), locale] {
            let f = DateFormatter()
            f.locale = l
            let lists = [f.monthSymbols, f.shortMonthSymbols, f.standaloneMonthSymbols, f.shortStandaloneMonthSymbols].compactMap { $0 }
            for list in lists where list.count >= 12 {
                for i in 0..<12 {
                    var key = list[i].trimmingCharacters(in: .whitespaces).lowercased()
                    while key.hasSuffix(".") { key.removeLast() }
                    if key.count >= 3 && names[key] == nil { names[key] = i + 1 }
                }
            }
        }
        if names["sept"] == nil { names["sept"] = 9 }
        if names["setiembre"] == nil { names["setiembre"] = 9 }
        return names
    }

    // ---- The title ----

    /// The first heading: the tallest line in the page's top third, when it stands out (a third taller than most lines); else
    /// the first line with three letters or more. Cut to `maxTitle` characters at a word.
    static func findTitle(_ lines: [TextLine]) -> String? {
        let worded = lines.filter { $0.text.filter(\.isLetter).count >= 3 }
        guard !worded.isEmpty else { return nil }
        let heights = worded.map(\.height).sorted()
        let usual = heights[heights.count / 2]
        let bottom = lines.map { $0.top + $0.height }.max()!
        let top = lines.map(\.top).min()!
        let heading = worded.filter { $0.top <= top + (bottom - top) / 3 && $0.height >= usual * 4 / 3 }.max { $0.height < $1.height }
        return shorten(PageText.withoutStrays(heading ?? worded[0]))
    }

    private static func shorten(_ text: String) -> String? {
        let trim = CharacterSet(charactersIn: " .,:;-")
        var s = text.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: trim)
        if s.count > maxTitle {
            let chars = Array(s)
            let cut = chars[...maxTitle].lastIndex(of: " ") ?? -1
            s = String(cut > maxTitle / 2 ? chars[..<cut] : chars[..<maxTitle])
            while let last = s.last, " ,:;-".contains(last) { s.removeLast() }
        }
        return s.isEmpty ? nil : s
    }

    // ---- The number ----

    private static let labelledNumber = regex(
        #"(?:\b(?:invoice|inv|receipt|order|ref|reference|document|doc|bill|factura|recibo|pedido|folio|n[uú]mero|no|num|nr)\b\.?|#|n[º°]\.?)\s*(?:(?:no|n[uú]mero|number|num|n[º°])\b\.?\s*)?[:#]?\s*([A-Z0-9][A-Z0-9\-/.]{1,24})"#,
        ignoreCase: true)
    private static let codeLike = regex(#"\b([A-Z]{2,5}-?\d{3,12})\b"#)

    /// An invoice, order or receipt number: labelled first, else a code like INV-20931. It must have a digit.
    static func findNumber(_ lines: [String]) -> String? {
        for line in lines {
            for m in matches(labelledNumber, line) {
                var value = m.groups[1]
                while let last = value.last, ".-/".contains(last) { value.removeLast() }
                let digit = value.unicodeScalars.contains { $0.properties.numericType == .decimal }
                if digit && !isMatch(isoDate, value) && !isMatch(numericDate, value) { return value }
            }
        }
        for line in lines {
            if let m = matches(codeLike, line).first { return m.groups[1] }
        }
        return nil
    }
}
