import Foundation

/// One printer's supply history as its readings arrive (the Windows app's `PrinterViewModel.ShowSupplies`): each reading's
/// supplies and page count are kept in the store first, so the supplies card's lines and chart include it. The card's view is
/// worked out again only when the reading added or changed a row, or on a new day (days left count calendar days). The
/// printer monitor feeds it for a network printer, the app for a queue printer (CUPS gives no page count).
public final class SupplyHistoryFeed: @unchecked Sendable {
    public let store: SupplyHistoryStore
    public let printerId: String
    private let today: @Sendable () -> Day
    private let lock = NSLock()
    private var last: (day: Day, view: SupplyHistoryView)?

    public init(_ store: SupplyHistoryStore, _ printerId: String, today: @escaping @Sendable () -> Day = { Day(Date()) }) {
        self.store = store
        self.printerId = printerId
        self.today = today
    }

    /// Takes in one reading. `pages`: the printer's lifetime page count, when it gives one.
    public func take(_ supplies: [Consumable], pages: Int?) -> SupplyHistoryView {
        let day = today()
        let changed = store.record(printerId, supplies, pages, day)
        return lock.withLock {
            if !changed, let last, last.day == day { return last.view }
            let view = SupplyHistoryView.of(store.rows(printerId), day)
            last = (day, view)
            return view
        }
    }
}
