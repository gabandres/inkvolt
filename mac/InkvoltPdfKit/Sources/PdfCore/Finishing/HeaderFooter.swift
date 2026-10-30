import Foundation

/// Bates numbering: a prefix, a running number padded with zeros, a suffix ("ABC-000123").
public struct BatesFormat: Equatable, Sendable {
    public var prefix: String
    public var start: Int64
    public var digits: Int
    public var suffix: String

    public init(_ prefix: String = "", _ start: Int64 = 1, _ digits: Int = 6, _ suffix: String = "") {
        self.prefix = prefix
        self.start = start
        self.digits = digits
        self.suffix = suffix
    }

    /// The number of the `index`th page numbered (0 = the first).
    public func format(_ index: Int) -> String {
        prefix + String(format: "%0*lld", min(max(digits, 1), 18), start + Int64(index)) + suffix
    }
}

/// The six places a header or footer text can go.
public enum HeaderFooterSlot: Int, CaseIterable, Sendable { case headerLeft, headerCenter, headerRight, footerLeft, footerCenter, footerRight }

/// What `HeaderFooter.apply` writes. Texts may hold tokens (see `HeaderFooter.expand`).
public struct HeaderFooterOptions: Equatable, Sendable {
    public var headerLeft = ""
    public var headerCenter = ""
    public var headerRight = ""
    public var footerLeft = ""
    public var footerCenter = ""
    public var footerRight = ""
    public var fontSize: Double = 10
    public var color = AnnotColor(0, 0, 0)
    /// Points from the edges of the page as shown: the header's top, the footer's bottom, the side texts' outer edges.
    public var marginTop: Double = 36
    public var marginBottom: Double = 36
    public var marginLeft: Double = 72
    public var marginRight: Double = 72
    /// What <<bates>> becomes; nil leaves it empty.
    public var bates: BatesFormat?
    /// <<file>>: the document's file name.
    public var fileName = ""
    /// <<date>> and <<time>>.
    public var date = Date()
    /// How dates and times are written (nil: the current locale; `HeaderFooter.invariant` for the Windows tests' invariant culture).
    public var locale: Locale?
    // For a preview made on a page extracted from the document: the numbers it would get there.
    /// Added to each page's number (<<page>>).
    public var pageNumberOffset = 0
    /// <<pages>> instead of the document's page count.
    public var pageCount: Int?
    /// Added to each page's Bates index.
    public var batesOffset = 0

    public init() {}

    public func text(_ slot: HeaderFooterSlot) -> String {
        switch slot {
        case .headerLeft: headerLeft
        case .headerCenter: headerCenter
        case .headerRight: headerRight
        case .footerLeft: footerLeft
        case .footerCenter: footerCenter
        case .footerRight: footerRight
        }
    }

    public var isEmpty: Bool { HeaderFooterSlot.allCases.allSatisfy { text($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
}

/// Headers and footers, page numbers and Bates numbers (the Windows app's `HeaderFooter`), written into the pages as
/// content (they print everywhere and can't be moved by accident), in Helvetica (embedded fonts for other scripts). Each
/// page's text is a form XObject laid out on the page as shown (rotation and crop applied); `remove` finds and removes
/// it again (see `PageMarks`). Applying again replaces the earlier header and footer of those pages.
public enum HeaderFooter {
    static let kind = "HeaderFooter"

    /// The tokens texts may use (date and time also take a format: <<date:yyyy-MM-dd>>).
    public static let tokens = ["<<page>>", "<<pages>>", "<<date>>", "<<time>>", "<<file>>", "<<bates>>"]

    /// Dates as the Windows app's invariant culture writes them (MM/dd/yyyy, HH:mm).
    public static let invariant = Locale(identifier: "en_US_POSIX")

    private static let tokenPattern = try! NSRegularExpression(pattern: #"<<\s*(page|pages|date|time|file|bates)\s*(?::([^<>]*))?>>"#, options: [.caseInsensitive])

    /// Replaces the tokens in `template`: <<page>> (1-based), <<pages>>, <<date>> and <<time>> (short forms of
    /// `locale`, or a format after a colon), <<file>> and <<bates>>. Tokens are matched ignoring case; anything else stays
    /// as typed.
    public static func expand(_ template: String, _ page: Int, _ pages: Int, _ bates: String?, _ fileName: String, _ date: Date, locale: Locale? = nil) -> String {
        let ns = template as NSString
        var out = ""
        var last = 0
        for m in tokenPattern.matches(in: template, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let format = m.range(at: 2).location != NSNotFound ? ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces) : nil
            switch ns.substring(with: m.range(at: 1)).lowercased() {
            case "page": out += String(page)
            case "pages": out += String(pages)
            case "date": out += formatDate(date, format ?? "d", locale)
            case "time": out += formatDate(date, format ?? "t", locale)
            case "file": out += fileName
            default: out += bates ?? ""
            }
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// A date in a .NET format ("d" the short date, "t" the short time, or a custom pattern); a pattern that can't be
    /// used falls back to the short date.
    static func formatDate(_ date: Date, _ format: String, _ locale: Locale?) -> String {
        let f = DateFormatter()
        f.locale = locale ?? .current
        let posix = locale?.identifier == invariant.identifier
        switch format.isEmpty ? "d" : format {
        case "d":
            if posix { f.dateFormat = "MM/dd/yyyy" } else { f.dateStyle = .short; f.timeStyle = .none }
        case "t":
            if posix { f.dateFormat = "HH:mm" } else { f.dateStyle = .none; f.timeStyle = .short }
        default:
            guard let pattern = unicodePattern(format) else { return formatDate(date, "d", locale) }
            f.dateFormat = pattern
        }
        return f.string(from: date)
    }

    /// A .NET custom date format as a Unicode pattern (the parts that differ: tt → a, f → S); nil when it isn't one
    /// (a lone "%" or an unbalanced quote, which .NET refuses).
    private static func unicodePattern(_ format: String) -> String? {
        if format == "%" || format.contains("%") { return nil }
        if format.filter({ $0 == "'" }).count % 2 != 0 || format.filter({ $0 == "\"" }).count % 2 != 0 { return nil }
        return format.replacingOccurrences(of: "tt", with: "a").replacingOccurrences(of: "f", with: "S")
    }

    /// Where a slot's text starts (its baseline's left end), in displayed-page coordinates (origin at the bottom-left
    /// of the page as shown, y up), for text `textWidth` wide whose font rises `ascent` above and drops `descent`
    /// (negative) below the baseline.
    public static func position(_ slot: HeaderFooterSlot, _ textWidth: Double, _ pageWidth: Double, _ pageHeight: Double,
                                _ ascent: Double, _ descent: Double, _ o: HeaderFooterOptions) -> (x: Double, y: Double) {
        let header = slot == .headerLeft || slot == .headerCenter || slot == .headerRight
        let y = header ? pageHeight - o.marginTop - ascent : o.marginBottom - descent
        let x: Double
        switch slot {
        case .headerLeft, .footerLeft: x = o.marginLeft
        case .headerCenter, .footerCenter: x = (pageWidth - textWidth) / 2
        default: x = pageWidth - o.marginRight - textWidth
        }
        return (x, y)
    }

    /// Writes the header and footer on `pages` (0-based; Bates numbers follow page order).
    /// - Throws: `PdfEditError` when there is nothing to write or the size is out of range; `OwnerPasswordRequired`.
    public static func apply(_ data: [UInt8], _ password: String?, _ pages: [Int], _ options: HeaderFooterOptions) throws -> [UInt8] {
        if options.isEmpty { throw PdfEditError("Type the text of a header or a footer.") }
        if !options.fontSize.isFinite || options.fontSize < 1 || options.fontSize > 200 { throw PdfEditError("The font size must be from 1 to 200 points.") }
        let doc = try PdfEdit.open(data, password)
        let pageCount = try doc.pageCount()
        let count = options.pageCount ?? pageCount
        let color = PdfColorValue(c: [options.color.r, options.color.g, options.color.b])
        let size = options.fontSize
        var k = 0
        var todo: [(page: Int, texts: [HeaderFooterSlot: String])] = []
        for p in Set(pages).filter({ $0 >= 0 && $0 < pageCount }).sorted() {
            let bates = options.bates.map { $0.format(options.batesOffset + k) }
            k += 1
            var texts: [HeaderFooterSlot: String] = [:]
            for s in HeaderFooterSlot.allCases {
                texts[s] = expand(options.text(s), p + 1 + options.pageNumberOffset, count, bates, options.fileName, options.date, locale: options.locale)
                    .replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                    .trimmingCharacters(in: .whitespaces)
            }
            todo.append((p, texts))
        }

        // One painter and one resource dictionary for every page: text in other scripts embeds its fonts once, with the
        // glyphs of all pages (filled in after the last page).
        let painter = TextPainter(.helvetica, todo.flatMap { Array($0.texts.values) })
        let resources = doc.add(doc.dict())
        for (p, texts) in todo {
            let page = doc.page(p)
            PageMarks.remove(doc, page, kind)
            if texts.values.allSatisfy(\.isEmpty) { continue }
            let (w, h, matrix) = PageMarks.frame(doc, page)
            for slot in HeaderFooterSlot.allCases {
                guard let text = texts[slot], !text.isEmpty else { continue }
                let (x, y) = position(slot, painter.measure(text) * size, w, h, painter.ascent * size, painter.descent * size, options)
                painter.draw(text, x, y, size)
            }
            let form = doc.formXObject(painter.ops("/Helv", color), 0, 0, w, h, resources, matrix: matrix)
            PageMarks.add(doc, page, form, kind, behind: false, "<</Type /Pagination>>")
        }
        let built = painter.resources(doc, "/Helv")
        for key in built.keys { resources.set(key, built[key]) }
        InfoDict.setDate(doc, "ModDate", Date())
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    /// Removes every header and footer Inkvolt PDF added. Returns `data` itself when there are none.
    public static func remove(_ data: [UInt8], _ password: String?) throws -> [UInt8] {
        let doc = try PdfEdit.open(data, password)
        var any = false
        for page in try doc.pages() where PageMarks.remove(doc, page, kind) { any = true }
        if !any { return data }
        InfoDict.setDate(doc, "ModDate", Date())
        try doc.checkFailure()
        return try PdfEdit.save(doc, original: data, password: password)
    }

    /// True when the document has a header or footer Inkvolt PDF added.
    public static func has(_ data: [UInt8], _ password: String?) throws -> Bool {
        PageMarks.has(try PdfEdit.openToRead(data, password), kind)
    }
}
