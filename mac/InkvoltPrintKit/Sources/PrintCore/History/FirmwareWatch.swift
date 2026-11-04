import Foundation

/// A calendar day without a time or zone (.NET's `DateOnly`): what the firmware watch and the supply history remember.
/// Codable as "yyyy-MM-dd", as Windows' state.json writes it.
public struct Day: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int, month: Int, day: Int

    public init(_ year: Int, _ month: Int, _ day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `timeZone`.
    public init(_ date: Date, timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(c.year ?? 1, c.month ?? 1, c.day ?? 1)
    }

    /// Days since 1 January of year 1 (.NET's `DayNumber`), so that differences are day counts.
    public var dayNumber: Int {
        // Days before this year, then before this month, then the day.
        let y = year - 1
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let before = [0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334][max(0, min(11, month - 1))]
        return y * 365 + y / 4 - y / 100 + y / 400 + before + (leap && month > 2 ? 1 : 0) + day - 1
    }

    public init(dayNumber: Int) {
        // From the 400-year cycle down (the inverse of `dayNumber`).
        var n = dayNumber
        let cycles400 = n / 146_097
        n %= 146_097
        let cycles100 = min(n / 36_524, 3)
        n -= cycles100 * 36_524
        let cycles4 = n / 1_461
        n %= 1_461
        let years = min(n / 365, 3)
        n -= years * 365
        let year = cycles400 * 400 + cycles100 * 100 + cycles4 * 4 + years + 1
        let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        let lengths = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
        var month = 1
        while month < 12 && n >= lengths[month - 1] {
            n -= lengths[month - 1]
            month += 1
        }
        self.init(year, month, n + 1)
    }

    public func adding(days: Int) -> Day { Day(dayNumber: dayNumber + days) }

    public static func < (a: Day, b: Day) -> Bool { a.dayNumber < b.dayNumber }

    public var description: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// The day as people read it ("12 October 2026"), in the current locale's month names.
    public var longText: String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? Date()
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = .current
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: date)
    }

    public init(from decoder: Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let parts = text.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Not a day: \(text)")) }
        self.init(parts[0], parts[1], parts[2])
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

/// One printer's firmware as remembered (roadmap 1.5): the version and the day it was first seen, and the last change, which
/// the status card shows until it's dismissed or `FirmwareWatch.noticeDays` have passed. Kept in the state file.
public struct FirmwareRecord: Equatable, Sendable, Codable {
    /// As the printer reports it (`FirmwareInfo.display`).
    public var version: String
    /// The day this version was first seen.
    public var since: Day
    /// The version before it, when a change was seen; nil for the first version seen.
    public var previous: String?
    /// The notice of the change to `version` was closed.
    public var dismissed: Bool

    public init(_ version: String, _ since: Day, previous: String? = nil, dismissed: Bool = false) {
        self.version = version
        self.since = since
        self.previous = previous
        self.dismissed = dismissed
    }
}

/// A firmware change to tell: "Firmware changed from X to Y on 12 October 2026".
public struct FirmwareChange: Equatable, Sendable {
    public var from: String
    public var to: String
    public var on: Day

    public init(_ from: String, _ to: String, _ on: Day) {
        self.from = from
        self.to = to
        self.on = on
    }

    public var text: String { "Firmware changed from \(from) to \(to) on \(on.longText)." }

    /// The alert's key: one per change, so the same change never alerts twice.
    public var key: String { "\(from)→\(to)" }
}

/// Where a printer monitor keeps its printer's `FirmwareRecord` (the state file's: `StateStore.firmwareMemory`), and the day
/// it is.
public struct FirmwareMemory: Sendable {
    public var get: @Sendable () -> FirmwareRecord?
    public var set: @Sendable (FirmwareRecord) -> Void
    public var today: @Sendable () -> Day

    public init(get: @escaping @Sendable () -> FirmwareRecord?, set: @escaping @Sendable (FirmwareRecord) -> Void,
                today: @escaping @Sendable () -> Day = { Day(Date()) }) {
        self.get = get
        self.set = set
        self.today = today
    }

    /// The connection reported `version`: the record kept (when it changed) and the notice to show now (`FirmwareWatch`).
    public func watch(_ version: String?) -> FirmwareChange? {
        let day = today()
        let known = get()
        let record = FirmwareWatch.observe(known, version, day)
        if let record, record != known { set(record) }
        return FirmwareWatch.notice(record, day)
    }

    /// The notice was closed: the record says so, and it isn't shown again for this change.
    public func dismiss() {
        guard var record = get(), !record.dismissed else { return }
        record.dismissed = true
        set(record)
    }
}

/// Firmware watch: remembers each printer's firmware version and notices when it changes (an update the printer installed
/// by itself, or one somebody installed). HP's firmware updates have brought "dynamic security", which stops cartridges with
/// non-HP chips from working, so a change is worth telling. Pure: the caller keeps the record and supplies the day.
public enum FirmwareWatch {
    /// How long a change stays on the status card when nobody closes it.
    public static let noticeDays = 30
    private static let maxVersion = 80

    /// The record after a connection reported `version`: unchanged when the version is the one known (or unknown now: an
    /// empty version tells nothing), a new record with the change otherwise. The first version seen is no change.
    public static func observe(_ known: FirmwareRecord?, _ version: String?, _ today: Day) -> FirmwareRecord? {
        let v = clean(version)
        if v.isEmpty { return known }
        guard let known else { return FirmwareRecord(v, today) }
        if known.version == v { return known }
        return FirmwareRecord(v, today, previous: known.version)
    }

    /// The change to show now: the last one, while it isn't dismissed and is under `noticeDays` old.
    public static func notice(_ record: FirmwareRecord?, _ today: Day) -> FirmwareChange? {
        guard let record, let from = record.previous, !record.dismissed, today.dayNumber - record.since.dayNumber < noticeDays else { return nil }
        return FirmwareChange(from, record.version, record.since)
    }

    /// What a printer reports, fit to remember and show: one line, no control characters, cut to length.
    private static func clean(_ version: String?) -> String {
        let clean = String(String.UnicodeScalarView((version ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
            .trimmingCharacters(in: .whitespaces)
        return clean.count <= maxVersion ? clean : String(clean.prefix(maxVersion))
    }
}
