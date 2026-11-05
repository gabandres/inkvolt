import Foundation

/// Whole numbers as people read them in their locale (.NET's "N0": 1500 → "1,500").
enum NumberText {
    static func n0(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }
}

/// What the supplies card shows from a printer's history after a reading: the chart, each supply's line ("About 34 days left ·
/// 1,240 pages since this cartridge went in") and the days left the low-supply alert names.
public struct SupplyHistoryView: Equatable, Sendable {
    public var chart: SupplyChartData
    public var summaries: [String: SupplySummary]

    public static func empty(_ today: Day) -> SupplyHistoryView {
        SupplyHistoryView(chart: SupplyChartData(from: today, to: today, lines: []), summaries: [:])
    }

    /// - Parameter rows: one printer's rows (`SupplyHistoryStore.rows`).
    public static func of(_ rows: [SupplyRow], _ today: Day) -> SupplyHistoryView {
        var summaries: [String: SupplySummary] = [:]
        for s in SupplyAnalysis.summarizeAll(rows, today) { summaries[SupplyRow.keyOf(s.supply, s.color)] = s }
        return SupplyHistoryView(chart: SupplyChartData.build(rows, today), summaries: summaries)
    }

    /// The supply's line under its level; nil for a supply the history has nothing to say about (a waste box, no level).
    public func line(for supply: Consumable) -> String? {
        supply.isWaste ? nil : summaries[SupplyRow.keyOf(supply)]?.line
    }

    /// Days left per supply where there is an estimate (for `PrinterSnapshot.daysLeft`).
    public var daysLeft: [String: Int] {
        summaries.compactMapValues { $0.forecast.state == .estimate ? $0.forecast.daysLeft : nil }
    }

    /// The card's line under the chart when it can't draw yet: why, in plain words. Nil when the chart draws, or when no
    /// supply reports a level at all (nothing will ever be drawn: the card says nothing).
    public func chartNote(_ supplies: [Consumable]) -> String? {
        if chart.hasEnoughToDraw { return nil }
        return supplies.contains { !$0.isWaste && ($0.percentRemaining.map { (0...100).contains($0) } ?? false) }
            ? "The level chart fills in as days pass: Inkvolt Print keeps one reading a day on this Mac."
            : nil
    }
}

/// The Pro export (roadmap 1.1): one CSV (RFC 4180) of the supply history across all printers, a row per stored row, with
/// the cartridge it belongs to and the pages printed on that cartridge so far. Names come from the printers, so a cell a
/// spreadsheet would run as a formula is quoted with a leading apostrophe.
public enum SupplyHistoryCsv {
    private static let columns = "Printer,Supply,Color,Date,Level %,State,Pages printed,Cartridge seen since,Pages on this cartridge"

    /// The file's text when the Pro check allows it; nil when it doesn't (the caller shows what Pro does and where to get it).
    public static func export(_ store: SupplyHistoryStore, _ printers: [(id: String, name: String)]) -> String? {
        Pro.allows(.supplyHistoryExport) ? build(store, printers) : nil
    }

    /// The file's text.
    public static func build(_ store: SupplyHistoryStore, _ printers: [(id: String, name: String)]) -> String {
        var csv = columns + "\r\n"
        for (id, name) in printers {
            var order: [String] = []
            var groups: [String: [SupplyRow]] = [:]
            for r in store.rows(id) {
                if groups[r.key] == nil { order.append(r.key) }
                groups[r.key, default: []].append(r)
            }
            for key in order {
                let annotated = SupplyAnalysis.annotate(groups[key]!).enumerated()
                    .sorted { ($0.element.row.day, $0.offset) < ($1.element.row.day, $1.offset) }.map(\.element)
                for (row, from, pagesOn) in annotated {
                    let cells = [CsvCell.of(name), CsvCell.of(row.supply), CsvCell.of(row.color ?? ""), row.day.description,
                                 number(row.percent), CsvCell.of(row.state), number(row.pages), from.description, number(pagesOn)]
                    csv += cells.joined(separator: ",") + "\r\n"
                }
            }
        }
        return csv
    }

    private static func number(_ n: Int?) -> String { n.map(String.init) ?? "" }
}

/// A CSV cell (RFC 4180), safe to open in a spreadsheet (the Windows suite's `CsvCell`).
public enum CsvCell {
    public static func of(_ text: String) -> String {
        let text = notFormula(text)
        return text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\r" || $0 == "\n" || $0 == "\r\n" })
            ? "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : text
    }

    /// The text with what a spreadsheet would run as a formula made words, for a file that isn't CSV but ends up in one.
    public static func notFormula(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        var start = 0
        while start < scalars.count {
            let s = scalars[start]
            if CharacterSet.whitespacesAndNewlines.contains(s) || CharacterSet.controlCharacters.contains(s) || s.properties.generalCategory == .format {
                start += 1
            } else {
                break
            }
        }
        if start < scalars.count, ["=", "+", "-", "@", "\u{FF1D}", "\u{FF0B}", "\u{FF0D}", "\u{FF20}"].contains(scalars[start]) { return "'" + text }
        return start > 0 && start == scalars.count ? "" : text
    }
}

/// Demo mode's made-up year behind a printer's first reading, so demo mode shows the chart: each supply falling at its own
/// pace with a little day-to-day noise, a change of cartridge whenever the level would pass 100% going back, a week the
/// printer was away, and the page count rising with it (only for a printer that reports one). It ends at the reading itself,
/// and is the same every run for the same reading. The numbers aren't Windows' (its `System.Random` can't be reproduced); the
/// shape is.
public enum DemoSupplyHistory {
    private static let days = 365

    /// For `SupplyHistoryStore`'s first-reading hook.
    public static func seed(_ store: SupplyHistoryStore, _ printerId: String, _ supplies: [Consumable], _ pages: Int?, _ today: Day) {
        var rows: [SupplyRow] = []
        var random = SeededRandom(stableHash(printerId))
        // About a third of the printer's count printed over the year, so a young printer's count stays well above zero.
        let perDayPages = pages.map { min(max(Double($0) / 3 / Double(days), 0.3), 40) } ?? 0
        var counts = [Int?](repeating: nil, count: days + 1)
        counts[0] = pages
        for back in 1...days {
            counts[back] = counts[back - 1].map { n in
                max(0, n - (random.next(6) == 0 ? 0 : Int((perDayPages * (0.4 + 1.2 * random.nextDouble())).rounded(.toNearestOrEven)))) // bounded: perDayPages is 0.3...40
            }
        }
        for s in supplies where !s.isWaste && s.percentRemaining != nil {
            let name = SupplyHistoryStore.clean(s.name, SupplyHistoryStore.maxName)
            let color = SupplyHistoryStore.cleanColor(s.colorCode)
            var perDay = 0.22 + random.nextDouble() * 0.28
            var level = Double(s.percentRemaining!)
            for back in 1...days {
                level += perDay
                if level > Double(97 + random.next(4)) { // going back past a full cartridge: the one before ran down to a few percent
                    level = Double(4 + random.next(9))
                    perDay = 0.22 + random.nextDouble() * 0.28
                }
                if (120..<127).contains(back) { continue } // the printer was away that week
                let noise = random.next(5) == 0 ? random.next(3) - 1 : 0
                let shown = min(max(Int((level + Double(noise)).rounded(.toNearestOrEven)), 0), 100) // bounded: an Int's level, at most 100 here (more starts over above)
                rows.append(SupplyRow(today.adding(days: -back), name, color, shown, shown <= 15 ? "low" : "ok", counts[back]))
            }
        }
        store.importRows(printerId, rows.enumerated().sorted { ($0.element.day, $0.offset) < ($1.element.day, $1.offset) }.map(\.element))
    }

    /// The same number for the same id in every run (Swift's `hashValue` isn't).
    private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 17
        for u in text.utf16 { hash = hash &* 31 &+ UInt64(u) }
        return hash
    }

    /// SplitMix64: small, seeded, the same everywhere.
    private struct SeededRandom {
        private var state: UInt64

        init(_ seed: UInt64) { state = seed }

        mutating func nextRaw() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }

        /// 0 ..< n.
        mutating func next(_ n: Int) -> Int { Int(nextRaw() % UInt64(n)) }

        /// 0 ..< 1.
        mutating func nextDouble() -> Double { Double(nextRaw() >> 11) / Double(1 << 53) }
    }
}
