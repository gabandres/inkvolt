import Foundation

/// A line drawn on a sheet (fold and cut marks, a calendar's grid), in inches from the paper's top-left corner.
public struct SheetLine: Equatable, Sendable {
    public var x1: Double, y1: Double, x2: Double, y2: Double
    public var dashed: Bool

    public init(_ x1: Double, _ y1: Double, _ x2: Double, _ y2: Double, dashed: Bool = false) {
        (self.x1, self.y1, self.x2, self.y2, self.dashed) = (x1, y1, x2, y2, dashed)
    }
}

public enum PhotoTextAlign: Sendable { case left, center, right }

/// Text drawn on a photo sheet (Windows' `SheetText`; PrintCore's `SheetText` is the separator sheet's): wrapped within `box` (inches, from the paper's top-left), `size` the font's size in inches, `bold`
/// for titles, `muted` in grey (days of a calendar's next month left out are never drawn).
public struct PhotoText: Equatable, Sendable {
    public var text: String
    public var box: Placement
    public var size: Double
    public var align: PhotoTextAlign
    public var bold: Bool
    public var muted: Bool

    public init(_ text: String, _ box: Placement, _ size: Double, align: PhotoTextAlign = .center, bold: Bool = false, muted: Bool = false) {
        (self.text, self.box, self.size, self.align, self.bold, self.muted) = (text, box, size, align, bold, muted)
    }
}

/// A collage's arrangement: rows as even as can be, columns as even as can be, or the first photo large above the rest.
public enum CollageArrangement: Sendable, CaseIterable { case rows, columns, oneLarge }

/// Cards, calendars and collages (roadmap 4.16; Windows' `PhotoProjects`): sheets made from the photos with words and marks on
/// them, laid out here in inches (pure arithmetic and the interface language's calendar), drawn by the app exactly as photo
/// sheets are (preview, print, PDF). Photos are never turned to suit a cell here: a sideways picture in a card or a calendar
/// would read sideways. Week days are numbered as .NET's `DayOfWeek`: 0 Sunday to 6 Saturday.
public enum PhotoProjects {
    /// Photos one collage holds; more make another collage sheet.
    public static let maxCollage = 9
    /// A card's message is cut to this many characters (it has half a page at most).
    public static let maxMessage = 400
    /// Spacing and border choices for collages, inches.
    public static let spacings = [0, 0.08, 0.2]
    public static let borders = [0, 0.25, 0.5]
    /// Space kept between a card panel's edge (its fold or the cut between two cards) and what is printed on it.
    public static let cardPad = 0.25

    public static func isProject(_ kind: PhotoLayoutKind) -> Bool {
        switch kind {
        case .card, .monthCalendar, .yearCalendar, .collage: true
        default: false
        }
    }

    public static func sheets(_ photos: [PhotoInput], _ options: PhotoLayoutOptions, _ paper: SheetPaper) -> [PhotoSheet] {
        if photos.isEmpty || paper.printable.width <= 0 || paper.printable.height <= 0 { return [] }
        switch options.kind {
        case .card: return cards(photos, options, paper)
        case .monthCalendar: return photos.enumerated().map { monthSheet($0.offset, $0.element, options, paper, $0.offset) }
        case .yearCalendar: return photos.enumerated().map { yearSheet($0.offset, $0.element, options, paper) }
        case .collage: return collages(photos, options, paper)
        default: return []
        }
    }

    private static func cell(_ index: Int, _ photo: PhotoInput, _ cell: Placement) -> PhotoCell {
        PhotoCell(index, cell, PhotoLayout.place(cell, photo.width, photo.height, .fill, photo.crop, turned: false), false)
    }

    private static func inset(_ p: Placement, _ d: Double) -> Placement {
        Placement(p.x + d, p.y + d, max(0, p.width - 2 * d), max(0, p.height - 2 * d))
    }

    // MARK: Cards

    /// Folded greeting cards, two to a sheet (the top half and the bottom half, each folded down its middle): on the outside the
    /// photo is the front (the right panel), the left panel the back; with a message, the next sheet is the inside, printed on
    /// the back of the outside (both sides, flipping on the long edge: the message lands behind the back panel, on the
    /// inside's right). Fold marks at each card's fold and cut marks between the two cards, short ticks inside the printable
    /// area. A photo's copies make more cards.
    public static func cards(_ photos: [PhotoInput], _ options: PhotoLayoutOptions, _ paper: SheetPaper) -> [PhotoSheet] {
        var cards: [Int] = []
        for (i, photo) in photos.enumerated() { cards += Array(repeating: i, count: max(0, min(photo.copies, 999))) }
        let message = message(options.cardMessage)
        let area = paper.printable
        var sheets: [PhotoSheet] = []
        for start in stride(from: 0, to: cards.count, by: 2) {
            var cells: [PhotoCell] = []
            var lines: [SheetLine] = []
            for k in 0..<2 where start + k < cards.count {
                let card = cardBox(paper, k)
                let front = inset(panel(card, right: true).intersect(area), cardPad)
                cells.append(cell(cards[start + k], photos[cards[start + k]], front))
                // The fold: a short tick at its top and its bottom, inside what the printer prints.
                let x = card.centerX
                let tick = min(0.25, card.height / 8)
                let top = max(card.y, area.y), bottom = min(card.bottom, area.bottom)
                lines.append(SheetLine(x, top, x, top + tick, dashed: true))
                lines.append(SheetLine(x, bottom - tick, x, bottom, dashed: true))
            }
            // Between the two cards: where to cut, a tick at each side.
            let cutY = paper.height / 2
            let cutTick = min(0.25, paper.width / 8)
            lines.append(SheetLine(area.x, cutY, area.x + cutTick, cutY))
            lines.append(SheetLine(area.right - cutTick, cutY, area.right, cutY))
            sheets.append(PhotoSheet(cells, lines: lines))
            if message.isEmpty { continue }
            var inside: [PhotoText] = []
            for k in 0..<2 where start + k < cards.count {
                let panel = inset(panel(cardBox(paper, k), right: true).intersect(area), cardPad * 2)
                inside.append(PhotoText(message, panel, messageSize(panel)))
            }
            sheets.append(PhotoSheet([], texts: inside, inside: true))
        }
        return sheets
    }

    /// The sheets need both sides of the paper: a card with an inside (its message on the back of its outside).
    public static func needsTwoSided(_ sheets: [PhotoSheet]) -> Bool { sheets.contains { $0.inside } }

    /// The `k`th card (0 the top, 1 the bottom) on the paper: half of it, whole width.
    public static func cardBox(_ paper: SheetPaper, _ k: Int) -> Placement { Placement(0, Double(k) * paper.height / 2, paper.width, paper.height / 2) }

    /// A card's left or right panel: half of it, either side of the fold.
    public static func panel(_ card: Placement, right: Bool) -> Placement {
        Placement(right ? card.centerX : card.x, card.y, card.width / 2, card.height)
    }

    /// A card's message as written: trimmed, without control characters but line breaks, at most `maxMessage` characters.
    public static func message(_ text: String?) -> String {
        guard let text, !text.allSatisfy(\.isWhitespace) else { return "" }
        let scalars = text.replacingOccurrences(of: "\r\n", with: "\n").unicodeScalars.filter { $0 == "\n" || $0.properties.generalCategory != .control }
        let clean = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.count > maxMessage ? String(clean.prefix(maxMessage)) : clean
    }

    /// The message's size: about a tenth of the panel's width, a large hand's writing (inches).
    private static func messageSize(_ panel: Placement) -> Double { max(0.08, min(panel.width / 12, 0.3)) }

    // MARK: Calendars

    /// The first day of the week in `locale` (0 Sunday in English, 1 Monday in Spanish), from Foundation's calendar.
    public static func firstDay(_ locale: Locale) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = locale
        return (calendar.firstWeekday - 1 + 7) % 7
    }

    /// The week day names, short, from the locale's first day: "Sun".."Sat"; "Lun".."Dom" (the trailing period gone).
    public static func dayNames(_ locale: Locale) -> [String] {
        let formatter = DateFormatter()
        formatter.locale = locale
        let names = symbols(formatter.shortWeekdaySymbols, 7) ?? ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let first = firstDay(locale)
        return (0..<7).map { capital(trimmedPeriod(names[(first + $0) % 7]), locale) }
    }

    /// A month's name in `locale`, its first letter capital (Spanish writes them small).
    public static func monthName(_ month: Int, _ locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        let names = symbols(formatter.standaloneMonthSymbols, 12) ?? symbols(formatter.monthSymbols, 12) ?? []
        let m = max(1, min(month, 12))
        return m - 1 < names.count ? capital(names[m - 1], locale) : String(m)
    }

    /// A formatter's list when it has `count` names (Darwin's Foundation types the lists as implicitly unwrapped, the
    /// Windows one's as plain arrays: taken as optional here for both).
    private static func symbols(_ list: [String]?, _ count: Int) -> [String]? {
        guard let list, list.count == count else { return nil }
        return list
    }

    private static func trimmedPeriod(_ s: String) -> String {
        var s = s
        while s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static func capital(_ s: String, _ locale: Locale) -> String {
        guard let first = s.first else { return s }
        return String(first).uppercased(with: locale) + s.dropFirst()
    }

    /// A month as weeks from `firstDay` (0 Sunday): each row seven day numbers, 0 where the day belongs to another month.
    /// Four to six rows. Counted from the proleptic Gregorian calendar's day numbers, never through a date.
    public static func weeks(_ year: Int, _ month: Int, _ firstDay: Int) -> [[Int]] {
        let days = daysInMonth(year, month)
        let weekday = (Day(year, month, 1).dayNumber + 1) % 7 // day 0 (1 January of year 1) was a Monday
        let offset = (weekday - firstDay + 7) % 7
        let rows = (offset + days + 6) / 7
        return (0..<rows).map { r in
            (0..<7).map { c in
                let d = r * 7 + c - offset + 1
                return d >= 1 && d <= days ? d : 0
            }
        }
    }

    private static func daysInMonth(_ year: Int, _ month: Int) -> Int {
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        return [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][max(1, min(month, 12)) - 1]
    }

    /// The `index`th month from the options' first month (photo 2 of a month calendar is the month after photo 1's).
    public static func monthAt(_ year: Int, _ month: Int, _ index: Int) -> (year: Int, month: Int) {
        // Counted in months from year 1, never through a date: past December 9999 the last month stays the last.
        let start = (Int64(max(1, min(year, 9999))) - 1) * 12 + Int64(max(1, min(month, 12)) - 1)
        let at = min(start + Int64(max(0, min(index, 9999 * 12))), 9999 * 12 - 1) // an index past every month is the last (Int.max would overflow)
        return (Int(at / 12) + 1, Int(at % 12) + 1)
    }

    /// A month's sheet: the photo over the top half, the month's name and year, and its days in a grid of weeks.
    public static func monthSheet(_ photo: Int, _ input: PhotoInput, _ options: PhotoLayoutOptions, _ paper: SheetPaper, _ index: Int) -> PhotoSheet {
        let locale = options.locale ?? Locale(identifier: "en_US_POSIX")
        let (year, month) = monthAt(options.calendarYear, options.calendarMonth, index)
        let area = inset(paper.printable, 0.1)
        let photoBox = Placement(area.x, area.y, area.width, area.height * 0.52)
        let titleH = area.height * 0.07
        let title = PhotoText("\(monthName(month, locale)) \(year)", Placement(area.x, photoBox.bottom + area.height * 0.02, area.width, titleH),
                              titleH * 0.6, bold: true)
        let grid = Placement(area.x, title.box.bottom + area.height * 0.01, area.width, area.bottom - title.box.bottom - area.height * 0.01)
        let (lines, texts) = monthGrid(year, month, locale, grid, lines: true)
        return PhotoSheet([cell(photo, input, photoBox)], lines: lines, texts: [title] + texts)
    }

    /// A year's sheet: the photo over the top, the year, and its twelve months small, three across and four down.
    public static func yearSheet(_ photo: Int, _ input: PhotoInput, _ options: PhotoLayoutOptions, _ paper: SheetPaper) -> PhotoSheet {
        let locale = options.locale ?? Locale(identifier: "en_US_POSIX")
        let year = max(1, min(options.calendarYear, 9999))
        let area = inset(paper.printable, 0.1)
        let landscape = area.width > area.height
        let photoBox = Placement(area.x, area.y, area.width, area.height * 0.36)
        let titleH = area.height * 0.06
        var texts = [PhotoText(String(year), Placement(area.x, photoBox.bottom + area.height * 0.01, area.width, titleH), titleH * 0.65, bold: true)]
        let monthsTop = photoBox.bottom + area.height * 0.01 + titleH
        let (cols, rows) = landscape ? (4, 3) : (3, 4)
        let gap = min(area.width, area.height) * 0.02
        let w = (area.width - Double(cols - 1) * gap) / Double(cols)
        let h = (area.bottom - monthsTop - Double(rows - 1) * gap) / Double(rows)
        for m in 1...12 {
            let (c, r) = ((m - 1) % cols, (m - 1) / cols)
            let box = Placement(area.x + Double(c) * (w + gap), monthsTop + Double(r) * (h + gap), w, h)
            let nameH = h / 8
            texts.append(PhotoText(monthName(m, locale), Placement(box.x, box.y, box.width, nameH), nameH * 0.75, bold: true))
            texts += monthGrid(year, m, locale, Placement(box.x, box.y + nameH, box.width, box.height - nameH), lines: false).texts
        }
        return PhotoSheet([cell(photo, input, photoBox)], texts: texts)
    }

    /// A month's week day names and day numbers in `box`: the names in a row on top, then a row a week; with `lines` a ruled
    /// grid with each number in its box's top left corner, else the numbers centered.
    public static func monthGrid(_ year: Int, _ month: Int, _ locale: Locale, _ box: Placement, lines: Bool) -> (lines: [SheetLine], texts: [PhotoText]) {
        let weeks = weeks(year, month, firstDay(locale))
        let names = dayNames(locale)
        let cw = box.width / 7
        let headH = min(box.height / 8, lines ? box.height / 10 : box.height / 7)
        let rowH = (box.height - headH) / Double(max(weeks.count, lines ? weeks.count : 6))
        var texts: [PhotoText] = []
        var rules: [SheetLine] = []
        for c in 0..<7 { texts.append(PhotoText(names[c], Placement(box.x + Double(c) * cw, box.y, cw, headH), headH * 0.55, muted: true)) }
        let top = box.y + headH
        for (r, week) in weeks.enumerated() {
            for (c, day) in week.enumerated() where day != 0 {
                let cell = Placement(box.x + Double(c) * cw, top + Double(r) * rowH, cw, rowH)
                if lines {
                    var corner = inset(cell, min(cw, rowH) * 0.08)
                    corner.height = rowH * 0.4
                    texts.append(PhotoText(String(day), corner, min(rowH * 0.28, cw * 0.3), align: .left))
                } else {
                    texts.append(PhotoText(String(day), cell, min(rowH, cw) * 0.55))
                }
            }
        }
        if lines {
            let bottom = top + Double(weeks.count) * rowH
            for r in 0...weeks.count { rules.append(SheetLine(box.x, top + Double(r) * rowH, box.right, top + Double(r) * rowH)) }
            for c in 0...7 { rules.append(SheetLine(box.x + Double(c) * cw, top, box.x + Double(c) * cw, bottom)) }
        }
        return (rules, texts)
    }

    // MARK: Collages

    /// The arrangements offered for `count` photos (one large needs at least three).
    public static func arrangements(_ count: Int) -> [CollageArrangement] { count >= 3 ? [.rows, .columns, .oneLarge] : [.rows, .columns] }

    /// How many photos go in each row (or column) for `count`: as even as can be, the fuller lines last (5: 2, 3).
    public static func lines(_ count: Int) -> [Int] {
        if count <= 0 { return [] }
        let lines = max(1, Int(Double(count).squareRoot().rounded(.toNearestOrEven))) // bounded: the square root of a positive Int
        return (0..<lines).map { count / lines + ($0 >= lines - count % lines ? 1 : 0) }
    }

    /// The cells of one collage of `count` photos (1 to `maxCollage`) in `area`, `spacing` apart (inches), in the photos' order.
    public static func collageCells(_ count: Int, _ arrangement: CollageArrangement, _ area: Placement, _ spacing: Double) -> [Placement] {
        let count = max(1, min(count, maxCollage))
        let spacing = max(0, min(spacing, min(area.width, area.height) / 10))
        if arrangement == .oneLarge && count >= 3 {
            let bigH = (area.height - spacing) * 0.6
            let rest = rows(count - 1, Placement(area.x, area.y + bigH + spacing, area.width, area.height - bigH - spacing), spacing, [count - 1])
            return [Placement(area.x, area.y, area.width, bigH)] + rest
        }
        if arrangement == .columns {
            // The rows' arrangement on the area turned a quarter: columns as even as rows would be.
            return rows(count, Placement(area.y, area.x, area.height, area.width), spacing, lines(count)).map { Placement($0.y, $0.x, $0.height, $0.width) }
        }
        return rows(count, area, spacing, lines(count))
    }

    private static func rows(_ count: Int, _ area: Placement, _ spacing: Double, _ perRow: [Int]) -> [Placement] {
        var cells: [Placement] = []
        let rows = Double(perRow.count)
        let rh = (area.height - (rows - 1) * spacing) / rows
        for (r, n) in perRow.enumerated() {
            let cw = (area.width - Double(n - 1) * spacing) / Double(n)
            for c in 0..<n {
                cells.append(Placement(area.x + Double(c) * (cw + spacing), area.y + Double(r) * (rh + spacing), max(0, cw), max(0, rh)))
            }
        }
        return cells
    }

    /// Collages of the photos in order, at most `maxCollage` to a sheet, inside a border of `collageBorder` around the printable
    /// area. Each photo once (copies don't apply); an arrangement a sheet's count doesn't offer becomes rows.
    public static func collages(_ photos: [PhotoInput], _ options: PhotoLayoutOptions, _ paper: SheetPaper) -> [PhotoSheet] {
        var area = paper.printable
        let border = max(0, min(options.collageBorder, min(area.width, area.height) / 4))
        area = inset(area, border)
        var sheets: [PhotoSheet] = []
        for start in stride(from: 0, to: photos.count, by: maxCollage) {
            let n = min(maxCollage, photos.count - start)
            let arrangement = arrangements(n).contains(options.collage) ? options.collage : .rows
            let cells = collageCells(n, arrangement, area, options.collageSpacing)
            sheets.append(PhotoSheet(cells.enumerated().map { cell(start + $0.offset, photos[start + $0.offset], $0.element) }))
        }
        return sheets
    }

    /// The photos' order with `a` and `b` swapped (dragging one collage photo onto another).
    public static func swap(_ count: Int, _ a: Int, _ b: Int) -> [Int] {
        var order = Array(0..<max(0, count))
        if a >= 0 && b >= 0 && a < count && b < count { order.swapAt(a, b) }
        return order
    }
}
