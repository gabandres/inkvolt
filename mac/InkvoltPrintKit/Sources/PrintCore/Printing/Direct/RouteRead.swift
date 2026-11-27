import Foundation

/// One thing a tab reads of where its printer's jobs go (Print's and Copy's two-sided check, Print photos' paper options, a
/// batch's queue), kept in step with the print routing (`PrintRouting`; Windows' `RouteRead`). Read when the tab asks (`ask`),
/// once; after a change of route (`routeChanged`) read again only if it was asked for, so a tab never shown reads nothing. One
/// read at a time: a change during a read reads again when it ends, so the last read is always the current route's.
/// `read` reads and keeps what it read, true when that counts as read (false: no answer yet, asked again next time); it
/// catches its own failures. Mac difference: a read starts when the caller next yields (a Swift task), so `routeChanged`
/// returns the read it started for a caller that waits on it.
@MainActor
public final class RouteRead {
    private let read: @MainActor () async -> Bool
    private var routeCount = 0, readFor = -1
    private var asked = false
    private var reading: Task<Void, Never>?

    public init(_ read: @escaping @MainActor () async -> Bool) { self.read = read }

    /// Read for the current route.
    public var isRead: Bool { readFor == routeCount && reading == nil }

    /// A read is under way.
    public var isReading: Bool { reading != nil }

    /// The tab wants it: read now unless it's read for the current route; a read under way is waited for.
    @discardableResult
    public func ask() -> Task<Void, Never> {
        asked = true
        if let running = reading { return running }
        return readFor == routeCount ? Task {} : start()
    }

    /// The route or the queue changed: what was read is stale, and read again now if it was asked for.
    @discardableResult
    public func routeChanged() -> Task<Void, Never>? {
        routeCount += 1
        guard asked, reading == nil else { return nil }
        return start()
    }

    private func start() -> Task<Void, Never> {
        let run = Task { @MainActor in
            defer { reading = nil }
            while true {
                let route = routeCount
                let done = await read()
                if route != routeCount { continue } // the route changed meanwhile: read for the new one
                if done { readFor = route }
                return
            }
        }
        reading = run
        return run
    }
}
