import Foundation

/// What an entry on the printer list is.
public enum ListedKind: Equatable, Sendable {
    /// Found on the network or added by address.
    case network
    /// Known only by its CUPS queue (USB, shared from another computer, a network printer macOS was set up for).
    case queue
    /// A USB scanner macOS has a driver for (ImageCaptureCore) that belongs to no printer on the list.
    case scanner
}

/// An entry on the printer list, as `PrinterList` sees it.
public struct ListedPrinter: Equatable, Sendable {
    /// The printer's UUID (or id from its address), or `CupsQueues.id(for:)`.
    public var id: String
    public var kind: ListedKind
    public var name: String
    public var model: String?
    /// A network printer's address and Bonjour host name.
    public var hosts: [String]
    /// A network printer's other UUIDs ("This is my printer"): its queues may carry them.
    public var acceptedUuids: [String]
    /// A queue printer's queue.
    public var destination: CupsDestination?
    /// A scanner of its own: the scanner.
    public var scanner: SystemScanner?
    /// Scanned pages not saved yet: a scanner on its own with them stays on the list.
    public var hasUnsavedScans = false

    public init(id: String, kind: ListedKind, name: String, model: String? = nil, hosts: [String] = [], acceptedUuids: [String] = [],
                destination: CupsDestination? = nil) {
        self.id = id
        self.kind = kind
        self.name = name
        self.model = model
        self.hosts = hosts
        self.acceptedUuids = acceptedUuids
        self.destination = destination
    }

    public static func forQueue(_ d: CupsDestination) -> ListedPrinter {
        ListedPrinter(id: CupsQueues.id(for: d.name), kind: .queue, name: d.displayName, model: d.makeAndModel, destination: d)
    }

    public static func forScanner(_ s: SystemScanner) -> ListedPrinter {
        var p = ListedPrinter(id: ScannerMatch.id(for: s), kind: .scanner, name: s.name)
        p.scanner = s
        return p
    }
}

/// What `PrinterList.reconcile` works from: the list now, and what macOS and the user say.
public struct PrinterListInput: Sendable {
    public var listed: [ListedPrinter]
    public var selected: String?
    /// macOS's CUPS destinations; nil: leave the queue printers as they are.
    public var destinations: [CupsDestination]?
    /// Discovery's first sweep is over: network queues may be listed (a printer it finds would take their place).
    public var sweepDone: Bool
    /// Ids the user removed from the list.
    public var forgotten: [String]
    /// A queue printer to select once it's listed (chosen last time).
    public var wantedQueue: String?
    /// macOS's USB scanners (ImageCaptureCore); nil: not read yet.
    public var scanners: [SystemScanner]?

    public init(listed: [ListedPrinter], selected: String?, destinations: [CupsDestination]?, sweepDone: Bool = true, forgotten: [String] = [],
                wantedQueue: String? = nil) {
        self.listed = listed
        self.selected = selected
        self.destinations = destinations
        self.sweepDone = sweepDone
        self.forgotten = forgotten
        self.wantedQueue = wantedQueue
    }
}

/// How the list changes: the caller removes, adds and selects in this order.
public struct PrinterListChange: Equatable, Sendable {
    public var removed: [String]
    public var addedQueues: [CupsDestination]
    public var selected: String?
    public var unforget: [String]
    /// The queue still waited for, to select once it's listed.
    public var wantedQueue: String?
    public var addedScanners: [SystemScanner] = []
    /// Each queue printer's USB scanner (nil: none), when scanners were read.
    public var systemScanners: [String: SystemScanner?]?

    public var changes: Bool { !removed.isEmpty || !addedQueues.isEmpty || !addedScanners.isEmpty }
}

/// The printer list module (the Windows app's `PrinterList`, queues part): which entries the list has besides network
/// printers, which is selected, and what the user's hidden list loses. Queue printers follow macOS's real CUPS queues that no
/// network printer here stands for; queues the user removed stay hidden until macOS no longer has them. Pure: the caller
/// makes and drops its entries as the change says. Scanners on their own come with ImageCaptureCore.
public enum PrinterList {
    /// The network printers on the list, as queue matching sees them.
    public static func claims(_ listed: [ListedPrinter]) -> [QueueClaim] {
        listed.filter { $0.kind == .network }.map { p in
            QueueClaim(id: p.id, name: p.name, model: p.model, hosts: p.hosts, uuids: (PrinterId.isValid(p.id) ? [p.id] : []) + p.acceptedUuids)
        }
    }

    public static func reconcile(_ input: PrinterListInput) -> PrinterListChange {
        var list = input.listed
        var selected = input.selected
        var wantedQueue = input.wantedQueue
        var removed: [String] = [], unforget: [String] = []
        var added: [CupsDestination] = []
        func isListed(_ id: String) -> Bool { list.contains { same($0.id, id) } }
        let forgotten = input.forgotten

        if let destinations = input.destinations {
            let claims = claims(list)
            var seen = Set<String>()
            let wanted = CupsQueues.unclaimed(destinations, claims)
                .filter { input.sweepDone || CupsQueues.connection($0) != .network }
                .filter { d in !forgotten.contains { same($0, CupsQueues.id(for: d.name)) } }
                .filter { seen.insert(CupsQueues.id(for: $0.name)).inserted }
            let ids = Set(wanted.map { CupsQueues.id(for: $0.name) })
            for gone in list where gone.kind == .queue && !ids.contains(gone.id.lowercased()) {
                list.removeAll { $0.id == gone.id }
                removed.append(gone.id)
                guard same(selected, gone.id) else { continue }
                // The network printer that now stands for it, else the first.
                let owner = gone.destination.flatMap { CupsQueues.claim($0, claims) }
                selected = owner.flatMap { o in list.first { same($0.id, o.id) }?.id } ?? list.first?.id
            }
            for d in wanted {
                let id = CupsQueues.id(for: d.name)
                if isListed(id) { continue }
                list.append(.forQueue(d))
                added.append(d)
                if selected == nil || same(id, wantedQueue) { selected = id }
            }
            if selected == nil { selected = list.first?.id }
            if !destinations.isEmpty {
                if input.sweepDone { wantedQueue = nil } // a network queue chosen last time is listed after the sweep
                // Hidden queues come back once macOS no longer has them (set up again later, they show again).
                let present = Set(destinations.map { CupsQueues.id(for: $0.name) })
                unforget = forgotten.filter { CupsQueues.isQueueId($0) && !present.contains($0.lowercased()) }
            }
        }
        var change = PrinterListChange(removed: removed, addedQueues: added, selected: selected, unforget: unforget, wantedQueue: wantedQueue)
        if let scanners = input.scanners { scannerPart(scanners, list, input.forgotten, &change) }
        return change
    }

    /// USB scanners: each goes to the queue printer it belongs to (`ScannerMatch`), one no printer claims is listed on its
    /// own; a scanner of its own goes when macOS drops it, unless it holds pages not saved yet; a hidden one stays hidden
    /// until macOS no longer has it.
    private static func scannerPart(_ scanners: [SystemScanner], _ listed: [ListedPrinter], _ forgotten: [String], _ change: inout PrinterListChange) {
        var list = listed // the queue part's list: queues gone are out, new ones in
        let usb = scanners.filter(\.usb)
        let candidates = list.filter { $0.kind == .queue }.map { (id: $0.id, names: [$0.name, $0.model ?? ""] + ($0.destination.map { [$0.name] } ?? [])) }
        var given: [String: SystemScanner?] = [:]
        for p in list where p.kind == .queue { given[p.id] = .some(nil) }
        var own: [SystemScanner] = []
        for s in usb {
            if let owner = ScannerMatch.owner(s, candidates), given[owner] == .some(nil) { given[owner] = .some(s) } else { own.append(s) }
        }
        change.systemScanners = given
        var seen = Set<String>()
        let wanted = own.filter { s in !forgotten.contains { same($0, ScannerMatch.id(for: s)) } && seen.insert(ScannerMatch.id(for: s)).inserted }
        let ids = Set(wanted.map(ScannerMatch.id(for:)))
        for gone in list where gone.kind == .scanner && !ids.contains(gone.id) && !gone.hasUnsavedScans {
            list.removeAll { $0.id == gone.id }
            change.removed.append(gone.id)
            if same(change.selected, gone.id) { change.selected = list.first?.id }
        }
        for s in wanted where !list.contains(where: { same($0.id, ScannerMatch.id(for: s)) }) {
            list.append(.forScanner(s))
            change.addedScanners.append(s)
            if change.selected == nil { change.selected = ScannerMatch.id(for: s) }
        }
        let present = Set(scanners.map(ScannerMatch.id(for:)))
        change.unforget += forgotten.filter { ScannerMatch.isScannerId($0) && !present.contains($0.lowercased()) }
    }

    /// What goes with a printer the user removes from the list, so none of it shows up again as an entry of its own: its id,
    /// and for a network printer its own CUPS queues.
    public static func hiddenWith(_ removed: ListedPrinter, _ destinations: [CupsDestination]) -> [String] {
        guard removed.kind == .network else { return [removed.id] }
        let own = destinations.filter { CupsQueues.isRealQueue($0) && CupsQueues.claim($0, claims([removed])) != nil }.map { CupsQueues.id(for: $0.name) }
        var seen = Set<String>()
        return ([removed.id] + own).filter { seen.insert($0.lowercased()).inserted }
    }

    private static func same(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return a.caseInsensitiveCompare(b) == .orderedSame
    }
}
