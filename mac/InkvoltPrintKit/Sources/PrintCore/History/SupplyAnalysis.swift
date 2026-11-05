import Foundation

public enum ForecastState: Sendable {
    /// The supply never reported a level.
    case noLevel
    /// Too few days of this cartridge in the last 30 (a new cartridge, a new printer, no reading for a month).
    case notEnoughData
    /// The level isn't falling: nothing to divide by.
    case steady
    case estimate
    case empty
}

/// How long a supply should last, or why that can't be said yet.
public struct SupplyForecast: Equatable, Sendable {
    public var state: ForecastState
    /// The estimate in days; nil also for `estimate` beyond `SupplyAnalysis.longestEstimate`.
    public var daysLeft: Int?
    /// For `notEnoughData`: days of readings still needed.
    public var moreDays: Int

    public init(_ state: ForecastState, daysLeft: Int? = nil, moreDays: Int = 0) {
        self.state = state
        self.daysLeft = daysLeft
        self.moreDays = moreDays
    }

    public var text: String? {
        switch state {
        case .notEnoughData: "Not enough history for days left yet (about \(moreDays) more \(Self.days(moreDays)))"
        case .steady: "Level steady, so no estimate of days left"
        case .estimate:
            switch daysLeft {
            case nil: "More than two years left"
            case 0?: "Could run out any day"
            case let n?: "About \(NumberText.n0(n)) \(Self.days(n)) left"
            }
        default: nil
        }
    }

    private static func days(_ n: Int) -> String { n == 1 ? "day" : "days" }
}

/// One cartridge as the history saw it.
public struct CartridgeStint: Equatable, Sendable {
    /// The first row counted as this cartridge.
    public var from: Day
    /// Its last row.
    public var to: Day
    public var firstPercent: Int
    public var lastPercent: Int
    /// Pages printed on it: the page count from its first row to the next cartridge's first row, or for the one in the printer
    /// to the latest row. Nil when the printer gives no count, or the count went backwards (a replaced formatter board).
    public var pages: Int?
    /// The change to it was seen; false for the cartridge already in when the history started.
    public var seenGoingIn: Bool
}

/// What one supply's rows say.
public struct SupplySummary: Equatable, Sendable {
    public var supply: String
    public var color: String?
    public var cartridges: [CartridgeStint]
    public var forecast: SupplyForecast

    /// The days a cartridge change was seen.
    public var changeDates: [Day] { cartridges.filter(\.seenGoingIn).map(\.from) }

    public var pagesOnCurrent: Int? { cartridges.last?.pages }

    /// The supplies card's line ("About 34 days left · 1,240 pages since this cartridge went in"); nil when there's nothing to say.
    public var line: String? {
        let pages = pagesOnCurrent.map { n in
            "\(NumberText.n0(n)) \(n == 1 ? "page" : "pages") since \(cartridges.last!.seenGoingIn ? "this cartridge went in" : "Inkvolt Print started keeping track")"
        }
        let line = [forecast.text, pages].compactMap { $0 }.joined(separator: " · ")
        return line.isEmpty ? nil : line
    }
}

/// Works out cartridges, pages per cartridge and days left from a supply's rows (the Windows Core's `SupplyAnalysis`). The
/// method, in full:
/// - **A change of cartridge** is a level at least `changeJump` points above the last known one (a wobble of a few points
///   around a threshold isn't one, and an unknown level in between doesn't count as anything). To the day: one row a day.
/// - **Days left** is a straight line (least squares, by calendar day, so days with no rows don't bend it) through this
///   cartridge's known levels in the last `windowDays` days. It needs `minReadings` readings spanning `minSpanDays` days,
///   else "not enough history". A slope under `steadyPerDay` points a day is "steady". The estimate is the latest level over
///   that slope, less the days since that reading; past `longestEstimate` days it says "more than two years" rather than a
///   number nobody should plan on.
/// - **Pages** come from the printer's lifetime count, so on a color printer a color cartridge's figure counts every page
///   printed while it was in, not only pages that used it.
public enum SupplyAnalysis {
    public static let changeJump = 20, windowDays = 30, minReadings = 3, minSpanDays = 7, longestEstimate = 730
    public static let steadyPerDay = 0.02

    /// Every supply in the rows, in the order first seen.
    public static func summarizeAll(_ rows: [SupplyRow], _ today: Day) -> [SupplySummary] {
        var order: [String] = []
        var groups: [String: [SupplyRow]] = [:]
        for r in rows {
            if groups[r.key] == nil { order.append(r.key) }
            groups[r.key, default: []].append(r)
        }
        return order.map { summarize(groups[$0]!, today) }
    }

    /// - Parameter rows: one supply's rows, oldest first.
    public static func summarize(_ rows: [SupplyRow], _ today: Day) -> SupplySummary {
        let stints = self.stints(rows)
        let cartridges = stints.enumerated().map { i, s in
            CartridgeStint(from: s.rows[0].day, to: s.rows[s.rows.count - 1].day, firstPercent: s.firstPercent, lastPercent: s.lastPercent,
                           pages: pagesOn(s.rows, i + 1 < stints.count ? stints[i + 1].rows : nil), seenGoingIn: s.seenGoingIn)
        }
        return SupplySummary(supply: rows.first?.supply ?? "", color: rows.first?.color, cartridges: cartridges,
                             forecast: stints.isEmpty ? SupplyForecast(.noLevel) : forecast(stints[stints.count - 1].rows, today))
    }

    /// The first day of the cartridge each row belongs to, and the pages printed on it up to that row (the export's columns).
    static func annotate(_ rows: [SupplyRow]) -> [(row: SupplyRow, cartridgeFrom: Day, pagesOnCartridge: Int?)] {
        var stints = self.stints(rows)
        if stints.isEmpty && !rows.isEmpty { stints = [Stint(rows: rows, firstPercent: 0, lastPercent: 0, seenGoingIn: false)] } // never a level: one unknown cartridge
        var out: [(SupplyRow, Day, Int?)] = []
        for stint in stints {
            let start = stint.rows.first { $0.pages != nil }?.pages
            for row in stint.rows {
                let on: Int? = if let p = row.pages, let s = start, p >= s { p - s } else { nil }
                out.append((row, stint.rows[0].day, on))
            }
        }
        return out
    }

    struct Stint {
        var rows: [SupplyRow]
        var firstPercent: Int
        var lastPercent: Int
        var seenGoingIn: Bool
    }

    /// The rows split at each change of cartridge. Rows before the first known level join the first cartridge; no known level
    /// at all: none.
    static func stints(_ rows: [SupplyRow]) -> [Stint] {
        var stints: [Stint] = []
        var current: [SupplyRow] = []
        var first: Int?, last: Int?
        var seen = false
        for row in rows {
            if let p = row.percent, let before = last, p - before >= changeJump {
                stints.append(Stint(rows: current, firstPercent: first!, lastPercent: before, seenGoingIn: seen))
                current = []
                (first, seen) = (p, true)
            }
            current.append(row)
            if let known = row.percent {
                if first == nil { first = known }
                last = known
            }
        }
        if let f = first, let l = last { stints.append(Stint(rows: current, firstPercent: f, lastPercent: l, seenGoingIn: seen)) }
        return stints
    }

    private static func pagesOn(_ rows: [SupplyRow], _ next: [SupplyRow]?) -> Int? {
        let start = rows.first { $0.pages != nil }?.pages
        let end = next?.first { $0.pages != nil }?.pages ?? rows.last { $0.pages != nil }?.pages
        guard let s = start, let e = end, e >= s else { return nil }
        return e - s
    }

    private static func forecast(_ cartridge: [SupplyRow], _ today: Day) -> SupplyForecast {
        let known = cartridge.filter { $0.percent != nil }
        if known[known.count - 1].percent == 0 { return SupplyForecast(.empty) }
        let oldest = today.adding(days: -windowDays)
        let window = known.filter { $0.day >= oldest && $0.day <= today }
        let span = window.isEmpty ? 0 : window[window.count - 1].day.dayNumber - window[0].day.dayNumber
        if window.count < minReadings || span < minSpanDays {
            return SupplyForecast(.notEnoughData, moreDays: max(minSpanDays - span, minReadings - window.count))
        }
        // Least squares by calendar day; x from the window's first row, so the numbers stay small.
        let x0 = window[0].day.dayNumber
        let n = Double(window.count)
        var sx = 0.0, sy = 0.0, sxy = 0.0, sxx = 0.0
        for r in window {
            let x = Double(r.day.dayNumber - x0), y = Double(r.percent!)
            sx += x
            sy += y
            sxy += x * y
            sxx += x * x
        }
        let perDay = -(n * sxy - sx * sy) / (n * sxx - sx * sx)
        if !(perDay >= steadyPerDay) { return SupplyForecast(.steady) } // NaN too: readings that don't make a line
        let last = window[window.count - 1]
        let left = Double(last.percent!) / perDay - Double(today.dayNumber - last.day.dayNumber)
        return SupplyForecast(.estimate, daysLeft: left > Double(longestEstimate) ? nil : Int(max(0, left.rounded(.toNearestOrEven)))) // bounded: at most longestEstimate, and finite (perDay is a number at least steadyPerDay)
    }
}

/// A point on the chart: a stored row with a level, unchanged.
public struct ChartPoint: Equatable, Sendable {
    public var day: Day
    public var percent: Int
}

/// One supply on the chart. A new segment starts at a change of cartridge (a mark, not a line climbing to it) and after a row
/// with no level (nothing is drawn for it). Days with no row at all (the Mac off, the printer away) stay joined: the level did
/// go from one to the other.
public struct ChartLine: Equatable, Sendable {
    public var supply: String
    public var color: String?
    public var segments: [[ChartPoint]]
    public var changes: [Day]
}

/// What the supplies card's chart draws: the stored rows of the last `days` days, nothing resampled or smoothed.
public struct SupplyChartData: Equatable, Sendable {
    public static let days = 366
    public var from: Day
    public var to: Day
    public var lines: [ChartLine]

    /// Some supply has two readings on different days: a line to draw. Otherwise the card says the chart fills in as days pass.
    public var hasEnoughToDraw: Bool { lines.contains { Set($0.segments.flatMap { $0 }.map(\.day)).count >= 2 } }

    public static func build(_ rows: [SupplyRow], _ today: Day) -> SupplyChartData {
        let oldest = today.adding(days: -days)
        let shown = rows.filter { $0.day >= oldest && $0.day <= today }
        var order: [String] = []
        var groups: [String: [SupplyRow]] = [:]
        for r in rows {
            if groups[r.key] == nil { order.append(r.key) }
            groups[r.key, default: []].append(r)
        }
        var lines: [ChartLine] = []
        for key in order {
            let supply = groups[key]!
            var segments: [[ChartPoint]] = []
            var changes: [Day] = []
            for stint in SupplyAnalysis.stints(supply) {
                if stint.seenGoingIn && stint.rows[0].day >= oldest { changes.append(stint.rows[0].day) }
                var segment: [ChartPoint] = []
                for row in stint.rows where row.day >= oldest && row.day <= today {
                    if let p = row.percent {
                        segment.append(ChartPoint(day: row.day, percent: p))
                        continue
                    }
                    if !segment.isEmpty { segments.append(segment) }
                    segment = []
                }
                if !segment.isEmpty { segments.append(segment) }
            }
            if !segments.isEmpty { lines.append(ChartLine(supply: supply[0].supply, color: supply[0].color, segments: segments, changes: changes)) }
        }
        return SupplyChartData(from: shown.first?.day ?? today, to: today, lines: lines)
    }
}
