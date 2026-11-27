import Foundation
import Synchronization

/// What the person chose for one printer's scan button (the app keeps it with its settings).
public struct ScanButtonChoice: Codable, Equatable, Sendable {
    /// Turned on. Off by default: on an HP panel it adds this Mac to the printer's list, a change on the printer.
    public var on: Bool
    /// The preset a press runs; nil or gone: the first preset.
    public var presetId: String?
    /// What marks this app's destination on the printer's list (`LedmWalkupScan.marker`), made when first needed and kept, so
    /// a run after a crash or a lost answer knows its own destination and removes it.
    public var tag: String?

    public init(on: Bool = false, presetId: String? = nil, tag: String? = nil) {
        self.on = on
        self.presetId = presetId
        self.tag = tag
    }
}

/// How a press of the printer's button reaches this Mac.
public enum ScanButtonWay: Sendable {
    /// Not known yet (no connection or scanner has been looked at, or the printer couldn't be read yet).
    case unknown
    /// Neither way: the Scan tab says so.
    case none
    /// HP's Scan to Computer on the printer's panel (LEDM: `ScanToComputer`).
    case panel
    /// The scanner's button through its macOS driver (ImageCaptureCore's button presses: `ScannerButtons`).
    case driver
}

/// One printer's scan button (print/ROADMAP.md 2.2; Windows' `ScanButton`): a press on the printer runs the chosen scan preset
/// on this Mac. HP's Scan to Computer when the printer's panel offers it (this Mac added to its list while turned on and the
/// app or its menu bar icon runs, removed when turned off and on quit), else the button its macOS scanner's driver reports.
/// Off until the person turns it on. The app hands it each new connection and its USB scanner; it tells the app `changed`
/// and each press (both from any thread). Calls are serialized. Once closed (`seal`, `close`) it starts nothing and saves
/// nothing again.
public final class ScanButton: Sendable {
    private struct Driver {
        var system: any ScannerButtons
        var deviceId: String
        var buttons: [String]
    }

    private struct State {
        var choice: ScanButtonChoice
        var panel: ScanToComputer?
        var panelKnown = false, driverKnown = false, closed = false
        var driver: Driver?
        var run: Task<Void, Never>?
        var watch: (any ButtonWatch)?
        var panelState: PanelState?
        var driverFailed = false
        var generation = 0
        var changed: (@Sendable () -> Void)?
    }

    public let panelName: String
    /// How long after a printer that couldn't be read the panel is looked for again, on the same connection.
    public let detectRetry: Duration
    /// For the panel's run: how long after a check that got no answer the next one comes (`ScanToComputer.retryDelay`).
    public let panelRetry: Duration

    private let save: @Sendable (ScanButtonChoice) -> Void
    private let pressedAction: @Sendable () -> Void
    private let log: @Sendable (String) -> Void
    private let calls = AsyncGate()
    private let state: Mutex<State>

    /// - Parameters:
    ///   - panelName: this Mac's name on the printer's panel (`LedmWalkupScan.panelName`).
    ///   - save: keeps the choice when it changes.
    ///   - pressed: a press: run the chosen preset.
    public init(panelName: String, choice: ScanButtonChoice?, save: @escaping @Sendable (ScanButtonChoice) -> Void,
                pressed: @escaping @Sendable () -> Void, log: @escaping @Sendable (String) -> Void = { _ in },
                detectRetry: Duration = .seconds(30), panelRetry: Duration = .seconds(30)) {
        self.panelName = panelName
        self.save = save
        pressedAction = pressed
        self.log = log
        self.detectRetry = detectRetry
        self.panelRetry = panelRetry
        state = Mutex(State(choice: choice ?? ScanButtonChoice()))
    }

    /// Something the Scan tab shows changed (Windows' `Changed` event; one listener: the app's).
    public var changed: (@Sendable () -> Void)? {
        get { state.withLock { $0.changed } }
        set { state.withLock { $0.changed = newValue } }
    }

    public var choice: ScanButtonChoice { state.withLock { $0.choice } }

    public var on: Bool { choice.on }

    /// Closed: the app is quitting, or the printer forgotten.
    public var isClosed: Bool { state.withLock { $0.closed } }

    /// How a press reaches this Mac: the panel when the printer offers it, else the driver's button.
    public var way: ScanButtonWay {
        state.withLock { s in
            if s.panel != nil { return .panel }
            if let d = s.driver, !d.buttons.isEmpty { return .driver }
            return s.panelKnown || s.driverKnown ? .none : .unknown
        }
    }

    /// The panel's last check (nil before one).
    public var panelState: PanelState? { state.withLock { $0.panelState } }

    /// The Scan tab's line; `presetName` is what a press runs (nil: no preset to run).
    public func text(_ presetName: String?) -> String {
        let preset = presetName ?? loc("no preset yet (make one with Manage Presets…)")
        let (failed, panelState) = state.withLock { ($0.driverFailed, $0.panelState) }
        switch way {
        case .unknown: return ""
        case .none:
            return loc("This printer's own Scan button can't send scans here: it offers neither HP's Scan to Computer nor a scan button macOS can report.")
        case .panel where !on:
            return loc("Turn this on to add this Mac ({0}) to the printer's panel under Scan to Computer. Choosing it there then scans here.", panelName)
        case .panel:
            switch panelState {
            case .listed:
                return loc("On the printer's panel: Scan to Computer › {0}. Pressing Scan there runs {1} here while Inkvolt Print or its menu bar icon is running.",
                           panelName, preset)
            case .listedByOther:
                return loc("A computer named {0} is already on the printer's panel, put there by other software (HP's, perhaps), so Inkvolt Print doesn't add it twice. Close that software or restart the printer, then turn this off and on.",
                           panelName)
            case .needsPassword:
                return loc("The printer asks for its admin password before it adds this Mac. Enter it with Enter the Admin Password…, and Inkvolt Print tries again.")
            case .refused:
                return loc("The printer didn't add this Mac to its panel. It may not take computers added this way; scan from this tab instead.")
            case .notReached:
                return loc("The printer isn't answering, or answered with an error. Inkvolt Print tries again and puts this Mac back on its panel when it can.")
            case .failed:
                return loc("Something went wrong while adding this Mac to the printer's panel. Turn this off and on to try again, or scan from this tab.")
            case .adding, nil:
                return loc("Adding this Mac to the printer's panel…")
            }
        case .driver where !on:
            return loc("Turn this on to scan here when the scanner's button sends a scan to this Mac.")
        case .driver:
            return failed
                ? loc("macOS didn't let Inkvolt Print hear this scanner's button. Scan from this tab instead, or turn this off and on to try again.")
                : loc("When the scanner's button sends a scan to this Mac, {0} runs here while Inkvolt Print or its menu bar icon is running.", preset)
        }
    }

    /// The switch's words for the way offered.
    public var switchText: String {
        way == .driver ? loc("Scan here when the scanner's button is pressed") : loc("Show this Mac on the printer's panel")
    }

    /// A new connection to the printer (the session closed the one before), or nil: none, or another device answers at the
    /// address (nothing may reach it). Looks for the panel by reading only; the Mac is added only while turned on. A printer
    /// that can't be read now is looked at again every `detectRetry` on this connection (in the background, after this
    /// returns), and until then nothing is said about it.
    public func usePrinter(_ connection: PrinterConnection?) async {
        let generation = nextGeneration()
        guard let connection else {
            await usePanel(nil, known: false, generation: generation)
            return
        }
        let found = await detect(connection)
        await usePanel(found.panel, known: found.read, generation: generation)
        if !found.read {
            Task { await self.retryDetect(connection, generation) }
        }
    }

    private func detect(_ connection: PrinterConnection) async -> PanelFound {
        do {
            return try await ScanToComputer.detect(connection)
        } catch {
            log("Scan to Computer not checked: \(error)")
            return PanelFound(panel: nil, read: false)
        }
    }

    private func retryDetect(_ connection: PrinterConnection, _ generation: Int) async {
        while isCurrent(generation) {
            guard (try? await Task.sleep(for: detectRetry)) != nil, isCurrent(generation) else { return }
            let found = await detect(connection)
            if !found.read { continue }
            await usePanel(found.panel, known: true, generation: generation)
            return
        }
    }

    private func isCurrent(_ generation: Int) -> Bool { state.withLock { $0.generation == generation && !$0.closed } }

    /// Connections handed over so far: a slow check of an older one never replaces a newer one's.
    private func nextGeneration() -> Int {
        state.withLock { s in
            s.generation += 1
            return s.generation
        }
    }

    /// The printer's panel as found on the current connection (nil: it offers none, or there's no connection).
    public func usePanel(_ panel: ScanToComputer?, known: Bool = true) async {
        await usePanel(panel, known: known, generation: nextGeneration())
    }

    private func usePanel(_ panel: ScanToComputer?, known: Bool, generation: Int) async {
        await calls.run {
            if state.withLock({ $0.generation != generation }) { return } // a newer connection came meanwhile
            await stop()
            state.withLock { s in
                s.panel = panel
                s.panelKnown = known // not known: no connection, or one that couldn't be read yet (nothing is said until it is)
                s.panelState = nil
            }
            await start()
        }
    }

    /// The printer's USB scanner as connected (nil: none), with the scan buttons its driver reports.
    public func useDriver(_ system: (any ScannerButtons)?, deviceId: String?, buttons: [String]?) async {
        await calls.run {
            await stop()
            state.withLock { s in
                if let system, let deviceId { s.driver = Driver(system: system, deviceId: deviceId, buttons: buttons ?? []) } else { s.driver = nil }
                s.driverKnown = true
                s.driverFailed = false
            }
            await start()
        }
    }

    /// Turned on (the Mac goes on the printer's panel, or the driver's button is heard) or off (taken off the panel).
    public func setOn(_ on: Bool) async {
        await calls.run {
            if self.on == on || isClosed { return }
            await stop()
            if !on { await remove() }
            var next = choice
            next.on = on
            keep(next)
            await start()
        }
    }

    /// The preset a press runs (its id; nil: the first).
    public func setPreset(_ presetId: String?) {
        var next = choice
        if next.presetId == presetId { return }
        next.presetId = presetId
        keep(next)
    }

    /// Closed from now on, at once: nothing starts and nothing is saved again (the printer is being forgotten, so its choice
    /// must not come back; or the app is quitting). `close` then stops and takes this Mac off the panel.
    public func seal() {
        state.withLock { s in
            s.closed = true
            s.generation += 1 // a check still under way doesn't start it again
        }
    }

    /// The app is quitting, or the printer is forgotten: closed (`seal`), presses no longer heard, and this Mac taken off the
    /// printer's panel (one DELETE of this app's destination; the caller's task cancelled stops it). The choice stays as it
    /// was, so the next run adds it again.
    public func close() async {
        seal()
        await calls.run {
            await stop()
            if on { await remove() }
            state.withLock { s in
                s.panel = nil
                s.driver = nil
            }
        }
    }

    private func start() async {
        let (panel, driver, closed) = state.withLock { ($0.panel, $0.driver, $0.closed) }
        if closed { return }
        if on, let panel {
            let owner = owner()
            panel.retryDelay = panelRetry
            let onState: @Sendable (PanelState) -> Void = { [weak self] in self?.panelChanged(panel, $0) }
            let onPress: @Sendable () -> Void = { [weak self] in self?.pressed() }
            let run = Task { await panel.run(owner, state: onState, pressed: onPress) }
            state.withLock { s in
                s.run = run
                s.panelState = .adding
            }
        } else if on, let d = driver, !d.buttons.isEmpty {
            do {
                let watch = try await d.system.watchButtons(d.deviceId, d.buttons) { [weak self] in self?.pressed() }
                state.withLock { $0.watch = watch }
            } catch {
                log("Scanner's button not heard: \(error)")
                state.withLock { $0.driverFailed = true }
            }
        }
        notify()
    }

    /// This Mac on a printer's list: its name, and its marker, the tag made (and kept) the first time it's needed.
    private func owner() -> PanelOwner {
        var current = choice
        let tag: String
        if let kept = current.tag {
            tag = kept
        } else {
            tag = LedmWalkupScan.newTag()
            current.tag = tag
            keep(current)
        }
        return PanelOwner(panelName, LedmWalkupScan.marker(panelName, tag))
    }

    /// Stops hearing presses (the Mac stays on the panel).
    private func stop() async {
        let (run, watch) = state.withLock { s in
            defer {
                s.run = nil
                s.watch = nil
            }
            return (s.run, s.watch)
        }
        watch?.stop()
        guard let run else { return }
        run.cancel()
        await run.value
    }

    /// Takes this Mac off the panel (this app's destination, found by its marker when its path isn't known).
    private func remove() async {
        let panel = state.withLock { $0.panel }
        guard let panel, let tag = choice.tag else { return } // never added from here
        if await panel.remove(PanelOwner(panelName, LedmWalkupScan.marker(panelName, tag))) {
            state.withLock { $0.panelState = nil }
        } else {
            log("This Mac couldn't be taken off the printer's panel (no answer, or refused).")
        }
    }

    private func panelChanged(_ panel: ScanToComputer, _ panelState: PanelState) {
        let current = state.withLock { s -> Bool in
            guard s.panel === panel, !s.closed else { return false } // a run that's being stopped
            s.panelState = panelState
            return true
        }
        if current { notify() }
    }

    private func pressed() {
        if !on || isClosed { return }
        pressedAction()
    }

    private func keep(_ next: ScanButtonChoice) {
        let saving = state.withLock { s -> Bool in
            if s.closed || s.choice == next { return false } // closed: a forgotten printer's choice never comes back
            s.choice = next
            return true
        }
        guard saving else { return }
        save(next)
        notify()
    }

    private func notify() { changed?() }
}

/// One caller at a time through an async section (Windows' `SemaphoreSlim(1, 1)` around `ScanButton`'s calls), in the order
/// they came.
final class AsyncGate: Sendable {
    private let state = Mutex<(busy: Bool, waiters: [CheckedContinuation<Void, Never>])>((false, []))

    func run<T>(_ work: () async throws -> T) async rethrows -> T {
        await enter()
        defer { leave() }
        return try await work()
    }

    private func enter() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let go = state.withLock { s -> Bool in
                if !s.busy {
                    s.busy = true
                    return true
                }
                s.waiters.append(continuation)
                return false
            }
            if go { continuation.resume() }
        }
    }

    private func leave() {
        let next = state.withLock { s -> CheckedContinuation<Void, Never>? in
            if s.waiters.isEmpty {
                s.busy = false
                return nil
            }
            return s.waiters.removeFirst()
        }
        next?.resume()
    }
}
