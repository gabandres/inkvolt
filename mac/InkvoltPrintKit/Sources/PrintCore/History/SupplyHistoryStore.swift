import Foundation

/// One supply's state on one day. `pages` is the printer's lifetime page count that day (a printer that reports one);
/// `percent` is nil when the printer gave no level (SNMP's and IPP's -1, -2, -3 arrive as nil).
public struct SupplyRow: Equatable, Sendable {
    public var day: Day
    public var supply: String
    public var color: String?
    public var percent: Int?
    public var state: String
    public var pages: Int?

    public init(_ day: Day, _ supply: String, _ color: String?, _ percent: Int?, _ state: String, _ pages: Int?) {
        self.day = day
        self.supply = supply
        self.color = color
        self.percent = percent
        self.state = state
        self.pages = pages
    }

    public var key: String { Self.keyOf(supply, color) }

    public static func keyOf(_ supply: String, _ color: String?) -> String { "\(supply)|\(color ?? "")" }

    /// The key a reading's supply is kept under.
    public static func keyOf(_ supply: Consumable) -> String {
        keyOf(SupplyHistoryStore.clean(supply.name, SupplyHistoryStore.maxName), SupplyHistoryStore.cleanColor(supply.colorCode))
    }
}

/// Supply history kept on this Mac (the Windows Core's `SupplyHistoryStore`): for each printer one small text file beside the
/// state file, one row a day per supply, the day's last reading winning (ink and toner only: a waste box has no level to
/// follow). A row holds the date, the supply's name and color, its level and state, and the printer's page count: no serial
/// number, address, document or user, and nothing is ever sent. Bounded: `maxDays` per printer, `maxSupplies` per printer and
/// names cut to `maxName` (what a printer reports is not trusted), `maxPrinters` files. A reading that lost a part keeps what
/// the day already knew. Never throws for a file it can't read or write: the history is a nicety.
public final class SupplyHistoryStore: @unchecked Sendable {
    public typealias FirstReading = (SupplyHistoryStore, String, [Consumable], Int?, Day) -> Void

    /// About three years.
    public static let maxDays = 1100
    public static let maxSupplies = 16, maxName = 64, maxPrinters = 64
    private static let maxState = 24, maxFileBytes = 4 * 1024 * 1024
    private static let header = "#inkvolt-supply-history 1"

    private let folder: String?
    private let firstReading: FirstReading?
    private let log: ((String) -> Void)?
    private let lock = NSRecursiveLock()
    private var rowsById: [String: [SupplyRow]] = [:]
    private var seeded = Set<String>()

    /// - Parameters:
    ///   - folder: where the files live; nil keeps everything in memory (demo mode).
    ///   - firstReading: called once when a printer with no history gives its first reading (demo mode's made-up year).
    public init(_ folder: String?, firstReading: FirstReading? = nil, log: ((String) -> Void)? = nil) {
        self.folder = folder
        self.firstReading = firstReading
        self.log = log
    }

    /// This printer's rows, oldest first.
    public func rows(_ printerId: String) -> [SupplyRow] { lock.withLock { load(printerId) } }

    /// Takes in one reading. True when a row was added or changed (and saved).
    @discardableResult
    public func record(_ printerId: String, _ supplies: [Consumable], _ pages: Int?, _ today: Day) -> Bool {
        lock.withLock {
            var rows = load(printerId)
            if rows.isEmpty, let firstReading, seeded.insert(printerId.lowercased()).inserted {
                firstReading(self, printerId, supplies, pages, today)
                rows = load(printerId)
            }
            var changed = false
            for s in supplies where !s.isWaste {
                let name = Self.clean(s.name, Self.maxName)
                if name.isEmpty { continue }
                let row = SupplyRow(today, name, Self.cleanColor(s.colorCode), Self.inRange(s.percentRemaining), Self.clean(s.state, Self.maxState),
                                    pages.flatMap { $0 >= 0 ? $0 : nil })
                if let at = rows.lastIndex(where: { $0.day == today && $0.key == row.key }) {
                    var merged = row
                    merged.percent = row.percent ?? rows[at].percent
                    merged.pages = row.pages ?? rows[at].pages
                    if merged == rows[at] { continue }
                    rows[at] = merged
                } else {
                    if Set(rows.map(\.key)).count >= Self.maxSupplies && !rows.contains(where: { $0.key == row.key }) { continue }
                    rows.append(row)
                }
                changed = true
            }
            guard changed else { return false }
            Self.tidy(&rows)
            rowsById[printerId.lowercased()] = rows
            save(printerId, rows)
            return true
        }
    }

    /// Puts rows in as they are, replacing what the printer had (demo mode's made-up year, tests).
    public func importRows(_ printerId: String, _ rows: [SupplyRow]) {
        lock.withLock {
            var list = rows
            Self.tidy(&list)
            rowsById[printerId.lowercased()] = list
            save(printerId, list)
        }
    }

    /// The printer was removed from the app: its history goes with it.
    public func forget(_ printerId: String) {
        lock.withLock {
            rowsById[printerId.lowercased()] = nil
            guard let path = pathOf(printerId) else { return }
            do {
                if FileManager.default.fileExists(atPath: path) { try FileManager.default.removeItem(atPath: path) }
            } catch {
                log?("Supply history not removed: \(error)")
            }
        }
    }

    /// An older non-UUID id was normalised: the history moves with it.
    public func rename(_ oldId: String, _ newId: String) {
        lock.withLock {
            let rows = load(oldId)
            if rows.isEmpty { return }
            forget(oldId)
            rowsById[newId.lowercased()] = rows
            save(newId, rows)
        }
    }

    private static func inRange(_ percent: Int?) -> Int? { percent.flatMap { (0...100).contains($0) ? $0 : nil } }

    /// Oldest first (a clock put back can bring a day out of order), and no older than `maxDays` before the newest.
    private static func tidy(_ rows: inout [SupplyRow]) {
        guard !rows.isEmpty else { return }
        if zip(rows, rows.dropFirst()).contains(where: { $1.day < $0.day }) {
            // Stable: a day's supplies stay in order.
            rows = rows.enumerated().sorted { ($0.element.day, $0.offset) < ($1.element.day, $1.offset) }.map(\.element)
        }
        let oldest = rows[rows.count - 1].day.adding(days: -maxDays)
        rows.removeAll { $0.day < oldest }
    }

    private func load(_ printerId: String) -> [SupplyRow] {
        let id = printerId.lowercased()
        if let known = rowsById[id] { return known }
        var rows: [SupplyRow] = []
        defer { rowsById[id] = rows }
        guard let path = pathOf(printerId), FileManager.default.fileExists(atPath: path) else { return rows }
        let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber)?.intValue ?? 0
        if size > Self.maxFileBytes {
            log?("Supply history file too large, starting it again")
            return rows
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            log?("Supply history not read")
            return rows
        }
        var keys = Set<String>() // kept as the lines go: a file of 100,000 lines loads in a moment, not minutes
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = Self.parse(String(line)) else { continue }
            let key = row.key
            if keys.contains(key) || keys.count < Self.maxSupplies {
                keys.insert(key)
                rows.append(row)
            }
        }
        Self.tidy(&rows)
        return rows
    }

    private func save(_ printerId: String, _ rows: [SupplyRow]) {
        guard let folder, let path = pathOf(printerId) else { return }
        do {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            let isNew = !FileManager.default.fileExists(atPath: path)
            var text = Self.header + "\n"
            for r in rows { text += Self.format(r) + "\n" }
            try Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            if isNew { dropOldest(keep: path) }
        } catch {
            log?("Supply history not saved: \(error)")
        }
    }

    /// The files beyond `maxPrinters` that were written longest ago go (printers long since gone); never the one just made.
    private func dropOldest(keep: String) {
        guard let folder, let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return }
        let files = names.filter { $0.hasSuffix(".tsv") }.map { (folder as NSString).appendingPathComponent($0) }
            .filter { $0.caseInsensitiveCompare(keep) != .orderedSame }
        let dated = files.map { ($0, (try? FileManager.default.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) }
        for (file, _) in dated.sorted(by: { $0.1 > $1.1 }).dropFirst(Self.maxPrinters - 1) {
            try? FileManager.default.removeItem(atPath: file)
        }
    }

    private func pathOf(_ printerId: String) -> String? {
        folder.map { ($0 as NSString).appendingPathComponent("\(PrinterId.fileName(printerId)).tsv") }
    }

    private static func format(_ r: SupplyRow) -> String {
        [r.day.description, r.supply, r.color ?? "", r.percent.map(String.init) ?? "", r.state, r.pages.map(String.init) ?? ""].joined(separator: "\t")
    }

    /// A row from its line; nil for anything else (a header, a damaged line). A value out of range counts as not reported.
    private static func parse(_ line: String) -> SupplyRow? {
        let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        guard cells.count == 6, !cells[1].isEmpty, ProKeys.isDate(cells[0]) else { return nil }
        let parts = cells[0].split(separator: "-").compactMap { Int($0) }
        let pages = Int(cells[5]).flatMap { $0 >= 0 ? $0 : nil }
        return SupplyRow(Day(parts[0], parts[1], parts[2]), clean(cells[1], maxName), cleanColor(cells[2]), inRange(Int(cells[3])),
                         clean(cells[4], maxState), pages)
    }

    /// What a printer reports, fit for one cell: no control characters (tabs, line ends), cut to length.
    static func clean(_ text: String?, _ max: Int) -> String {
        let clean = String(String.UnicodeScalarView((text ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        return clean.count <= max ? clean : String(clean.prefix(max))
    }

    /// K, C, M, Y or #RRGGBB as the readers give it; empty counts as none.
    static func cleanColor(_ color: String?) -> String? {
        let c = clean(color, 7)
        return c.isEmpty ? nil : c
    }
}
