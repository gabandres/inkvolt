import Foundation
import Synchronization

/// The line the Print tab shows about where its pages go; the words are the app's (`PrintRouteNote.text`).
public enum PrintRouteNote: Sendable, Equatable {
    /// Through the macOS queue, or nowhere yet: no line.
    case none
    /// Straight to the printer: macOS has no queue for it.
    case direct
    /// Straight to the printer as the person chose, though macOS has a queue for it.
    case directChosen
    /// Straight to the printer: macOS has a queue for it, but can't print through it (its driver or filter failed).
    case directQueueBroken
}

/// A printer's print routing (roadmap 2.1, print/GLOSSARY.md; Windows' `PrintRouting`): what the tabs that print (Print a PDF,
/// Batch print, Copy, Print photos, the print queue card) know of where its jobs go, kept in one place. Whether macOS has a
/// queue for it (`hasQueue`), whether it can be set up in macOS (`canSetUp`, `needsSetup`), whether it takes jobs straight and
/// the person may choose that (`canChooseDirect`, `choseDirect`), the route last decided and its note. Every listener
/// (`listen`) is told when any of it changes, or when the queue was made again; none is told by hand. The decision is the
/// router's (`router`), which every print asks afresh; this keeps the last one the app asked for, when what it's made from
/// changed: discovery's word, a queue lookup, a queue set up, a connection, the person's choice. What's known of the queue is
/// told at once, the decision when it's made (a lookup can take a moment).
/// Mac difference: each call does its part at once and returns the decision's task (Windows returns a Task the same way;
/// Swift's starts once the caller yields), which a caller awaits when it needs the route decided.
@MainActor
public final class PrintRouting {
    /// The person's choice, read by the router off the main actor.
    private final class Choice: Sendable {
        let value: Mutex<Bool>
        init(_ v: Bool) { value = Mutex(v) }
        var get: Bool { value.withLock { $0 } }
    }

    private let rememberChoice: (Bool) -> Void
    private let log: ((String) -> Void)?
    private let hasAddress: Bool
    private let choice: Choice
    private var queueKnown = false, discoveredQueue = false, foundQueue = false, pairs = false, takesDirect = false
    private var listeners: [(id: Int, hear: () throws -> Void)] = []
    private var nextListener = 0

    /// `findQueue` looks the printer's macOS queue up (nil: none); `rasterIpp` gives its IPP client when it takes a raster
    /// format (nil: it doesn't, or isn't connected); `hasAddress`: a network printer, which macOS can add by its address;
    /// `choseDirect` the person's choice as remembered for this printer, `rememberChoice` keeps a new one; `queueWorks`
    /// whether a queue can take jobs (`PrintRoutes.queueWorks`; nil: taken as yes).
    public init(findQueue: @escaping @Sendable () async throws -> String?, rasterIpp: @escaping @Sendable () async -> IppClient?, hasAddress: Bool,
                choseDirect: Bool, rememberChoice: @escaping (Bool) -> Void, log: ((String) -> Void)? = nil,
                queueWorks: (@Sendable (String) async -> Bool)? = nil) {
        self.hasAddress = hasAddress
        self.rememberChoice = rememberChoice
        self.log = log
        let choice = Choice(choseDirect)
        self.choice = choice
        router = PrintRouter(findQueue: findQueue, rasterIpp: rasterIpp, personChoseDirect: { choice.get }, queueWorks: queueWorks)
    }

    /// Decides where each print, batch and job alert goes (`PrintRouter`), with the person's choice kept here.
    public let router: PrintRouter

    /// Hears every change; one that throws is logged and the rest still hear it. Returns its id for `stopListening`.
    @discardableResult
    public func listen(_ hear: @escaping () throws -> Void) -> Int {
        nextListener += 1
        listeners.append((nextListener, hear))
        return nextListener
    }

    public func stopListening(_ id: Int) { listeners.removeAll { $0.id == id } }

    /// macOS has a queue for it: discovery saw one or a lookup found one. Taken as yes until either has said, so a printer isn't
    /// offered setting up before anything was asked.
    public var hasQueue: Bool { !queueKnown || discoveredQueue || foundQueue }

    /// Its jobs have somewhere to go: a macOS queue, or the printer takes them straight (as of the last decision).
    public var hasRoute: Bool { hasQueue || takesDirect }

    /// Discovery can pair it with macOS (it has a print endpoint), or it's a network printer macOS can add by address.
    public var canSetUp: Bool { pairs || hasAddress }

    /// No macOS queue yet, and one can be set up: the Overview offers Set Up.
    public var needsSetup: Bool { !hasQueue && canSetUp }

    /// The printer takes jobs straight and has a macOS queue too: the person may choose which.
    public private(set) var canChooseDirect = false

    /// The person chose straight to the printer over its macOS queue (kept per printer).
    public var choseDirect: Bool { choice.get }

    /// Where its jobs went at the last decision; `.none` before the first.
    public private(set) var route: PrintRoute = .none

    /// The Print tab's line for `route`.
    public private(set) var note: PrintRouteNote = .none

    /// What it's made from may have changed (a connection): decide again.
    @discardableResult
    public func decide() -> Task<Void, Never> { decide(current) }

    /// Discovery's word: whether macOS has a queue for it, and whether it can pair one.
    @discardableResult
    public func discovered(queueInstalled: Bool, pairs: Bool) -> Task<Void, Never> {
        let before = current
        discoveredQueue = queueInstalled
        self.pairs = pairs
        return queueSaid(before)
    }

    /// A lookup of its macOS queue found one or didn't.
    @discardableResult
    public func queueLookedUp(found: Bool) -> Task<Void, Never> {
        let before = current
        foundQueue = found
        return queueSaid(before)
    }

    /// Its macOS queue was set up or made again (`made`), or that failed: always told at once (the queue is new), then decided again.
    @discardableResult
    public func queueSetUp(made: Bool) -> Task<Void, Never> {
        queueKnown = true
        foundQueue = made
        tell()
        return decide(current)
    }

    /// The person chose straight to the printer, or the macOS queue: kept, decided again, told.
    @discardableResult
    public func chooseDirect(_ direct: Bool) -> Task<Void, Never> {
        if direct == choseDirect { return Task {} }
        let before = current
        choice.value.withLock { $0 = direct }
        rememberChoice(direct)
        return decide(before)
    }

    /// What's known of the queue is told at once; a change of whether it has one decides again.
    private func queueSaid(_ before: Facts) -> Task<Void, Never> {
        queueKnown = true
        let decideAgain = hasQueue != before.hasQueue
        if current != before { tell() }
        return decideAgain ? decide(current) : Task {}
    }

    /// Decides as a print decides, from one look at the queue and the connection. A decision that fails changes nothing: the
    /// route, its note and whether the printer takes jobs straight stay as the last one left them, and the next print decides again.
    private func decide(_ before: Facts) -> Task<Void, Never> {
        let router = router
        return Task { @MainActor in
            let choice: RouteChoice
            do {
                choice = try await router.choose()
            } catch {
                log?("Print route: \(Self.message(error))")
                if current != before { tell() } // a choice made just before (chooseDirect) is still news
                return
            }
            let queue = choice.queue != nil
            takesDirect = choice.ipp != nil
            canChooseDirect = takesDirect && queue
            route = choice.route
            note = choice.route != .direct ? .none : choice.queueBroken ? .directQueueBroken : queue ? .directChosen : .direct
            if current != before { tell() }
        }
    }

    private static func message(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func tell() {
        for (_, hear) in listeners {
            do {
                try hear()
            } catch {
                log?("Print route: a tab failed to follow the change: \(Self.message(error))")
            }
        }
    }

    /// Everything a tab reads, to tell whether it changed.
    private struct Facts: Equatable {
        var hasQueue, hasRoute, canSetUp, canChooseDirect, choseDirect: Bool
        var route: PrintRoute
        var note: PrintRouteNote
    }

    private var current: Facts {
        Facts(hasQueue: hasQueue, hasRoute: hasRoute, canSetUp: canSetUp, canChooseDirect: canChooseDirect, choseDirect: choseDirect, route: route, note: note)
    }
}

extension PrintRouteNote {
    /// The Print tab's words for the note (Windows' `Print_RouteDirect…`, its queue macOS's), nil for none.
    public var text: String? {
        switch self {
        case .none: nil
        case .direct: loc("No macOS queue for this printer: pages go straight to it over the network (IPP Everywhere).")
        case .directChosen: loc("Pages go straight to the printer over the network, not through its macOS queue.")
        case .directQueueBroken: loc("Pages go straight to the printer over the network: macOS can't print through its queue for this printer (its driver failed).")
        }
    }

    /// The Print tab's choice, shown when the printer has a queue and takes jobs straight (Windows' `PrintTab_Direct`).
    public static var chooseText: String { loc("Print straight to the printer (no macOS queue)") }

    /// Its help (Windows' `PrintTab_DirectTip`).
    public static var chooseTip: String {
        loc("Sends the pages over the network as the printer's own raster format (IPP Everywhere), without its macOS queue. Also for Copy and Photos.")
    }
}
