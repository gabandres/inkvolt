import Foundation

/// One printer's supply history as its readings arrive (the Windows app's `PrinterViewModel.ShowSupplies`): each reading's
/// supplies and page count are kept in the store first, so the supplies card's lines and chart include it. The card's view is
/// worked out again only when the reading added or changed a row, or on a new day (days left count calendar days, so a day
/// without a reading of supplies, or offline, counts down too). The printer monitor feeds it for a network printer, the app
/// for a queue printer (CUPS gives no page count), both through `show`. Keeping a reading, working the view out and caching
/// it happen as one step, so readings arriving together each get a view with their own reading in it.
public final class SupplyHistoryFeed: @unchecked Sendable {
    public let store: SupplyHistoryStore
    public let printerId: String
    private let today: @Sendable () -> Day
    private let lock = NSLock()
    private var last: (day: Day, view: SupplyHistoryView)?
    private var forgotten = false

    public init(_ store: SupplyHistoryStore, _ printerId: String, today: @escaping @Sendable () -> Day = { Day(Date()) }) {
        self.store = store
        self.printerId = printerId
        self.today = today
    }

    /// One reading, the one rule for a network printer and a queue printer (Windows' `ShowSupplies`): supplies read (any list)
    /// are kept first; nil (not read this time) keeps nothing. `pages`: this reading's lifetime page count, when it gives one
    /// (a reading without it keeps the count the day already had). The card's view, whose `daysLeft` the reading's snapshot
    /// carries; nil before the first reading of its supplies, and once forgotten.
    public func show(_ supplies: [Consumable]?, pages: Int?) -> SupplyHistoryView? {
        lock.withLock {
            guard !forgotten else { return nil }
            let day = today()
            let changed = supplies.map { store.record(printerId, $0, pages, day) } ?? false
            if supplies == nil && last == nil { return nil }
            if !changed, let last, last.day == day { return last.view }
            let view = SupplyHistoryView.of(store.rows(printerId), day)
            last = (day, view)
            return view
        }
    }

    /// The card's view for today without a reading (the printer doesn't answer): worked out again on a new day.
    public func current() -> SupplyHistoryView? { show(nil, pages: nil) }

    /// The printer was removed: its history goes with it, and a reading still in flight keeps nothing (the file doesn't come
    /// back).
    public func forget() {
        lock.withLock {
            forgotten = true
            last = nil
            store.forget(printerId)
        }
    }
}
