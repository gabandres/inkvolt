import Foundation

/// Where this Mac's Wi-Fi is: no adapter, on a network (its name's bytes), or on none.
public struct WifiNow: Equatable, Sendable {
    public var hasAdapter: Bool
    public var ssid: [UInt8]?

    public init(hasAdapter: Bool, ssid: [UInt8]?) {
        self.hasAdapter = hasAdapter
        self.ssid = ssid
    }

    public static let noAdapter = WifiNow(hasAdapter: false, ssid: nil)

    public var connected: Bool { ssid?.isEmpty == false }
    public func isOn(_ network: WifiNetwork) -> Bool { ssid.map { $0 == network.ssid } ?? false }
    public var name: String? { ssid.map(SetupNetworks.show) }
}

/// macOS won't say which networks are nearby: Location Services is off for the app (macOS 14 and later show Wi-Fi names
/// only to apps with location access).
public struct WifiLocationError: Error, Equatable {
    public init() {}
}

/// This Mac's Wi-Fi as the setup guide reads it (PrintMac's `CoreWifi` over CoreWLAN; `DemoWifi` in tests and demo mode).
/// Read only: on the Mac the person changes networks in macOS's Wi-Fi menu, never the app (Windows' `IWifi` also joins).
public protocol WifiReading: Sendable {
    func now() async throws -> WifiNow
    /// The networks in range (scanned again first). `WifiLocationError` when macOS won't say.
    func nearby() async throws -> [WifiNetwork]
    /// The gateway this Mac's Wi-Fi was given (the printer, on its own network), as an IPv4 address; nil when none.
    func gateway() async -> String?
}

/// Where the setup guide is (Windows' `SetupStep`; the Mac has no Connecting: the person joins in the Wi-Fi menu).
public enum SetupStep: Equatable, Sendable {
    /// Looking for the printer's network.
    case looking
    /// No Wi-Fi on this Mac.
    case noWifi
    /// macOS won't list networks: Location Services is off for the app.
    case locationOff
    /// Networks listed (`candidates`; none: `problem` says what to try).
    case choose
    /// The person joins the printer's network in the Wi-Fi menu; the guide waits to see the Mac on it (Windows' InWindows).
    case inMenu
    /// On the printer's network: its setup page is `page`.
    case onPrinter
    /// The person goes back to the network the Mac was on; the guide waits to see it.
    case returning
    /// Back on that network (or told how to leave the printer's, when the Mac was on none).
    case back
    /// Not back yet: `problem` says how.
    case couldNotReturn
}

/// What the guide shows: its step, the printers' networks, the one joined, the page and what to do.
public struct SetupState: Equatable, Sendable {
    public var step: SetupStep = .looking
    public var candidates: [SetupCandidate] = []
    public var joined: SetupCandidate?
    public var page: URL?
    /// What went wrong, or what to do by hand, in plain words.
    public var problem: String?
    /// The network the Mac was on before (nil: none, or not left yet).
    public var homeName: String?
    /// The Mac is (or may be) on the printer's network and not back yet.
    public var isAway = false

    public init() {}
}

/// The guide's sentences (Windows' `CoreStrings.Setup_*`, in the Mac's words).
public enum SetupText {
    public static var noWifi: String { loc("This Mac has no Wi-Fi, so it can't join the printer's setup network. Set the printer up from its control panel or the maker's phone app instead.") }
    public static var locationOff: String { loc("macOS shows Wi-Fi names to an app only with Location Services on for it. Turn on Inkvolt Print in System Settings › Privacy & Security › Location Services, then look again.") }
    public static var notListed: String { loc("macOS didn't list the Wi-Fi networks nearby. Check that Wi-Fi is on and look again in a moment.") }
    public static var noneFound: String { loc("No printer's setup network is in range. Turn the printer on, put it in Wi-Fi setup mode (its manual says how; many start it on their own when new or after a network reset), wait a minute and look again.") }
    public static func inMenu(_ name: String) -> String { loc("Choose \"{0}\" in the Wi-Fi menu in the menu bar. If it asks for a password, type the one shown on the printer's panel or its network page; Inkvolt Print never sees it. This window goes on once the Mac is on it.", name) }
    public static var notJoined: String { loc("The Mac didn't join the printer's network. Check that the printer is still in Wi-Fi setup mode and try again.") }
    public static var noPage: String { loc("The Mac is on the printer's network, but the printer gave no address for its setup page. Its manual names the address to type in a browser.") }
    public static func goBack(_ name: String) -> String { loc("Now choose \"{0}\" again in the Wi-Fi menu. This window goes on once the Mac is back on it.", name) }
    public static func couldNotReturn(_ name: String) -> String { loc("The Mac isn't back on \"{0}\" yet. Choose \"{0}\" in the Wi-Fi menu in the menu bar, then Check Again.", name) }
    public static var leavePrinter: String { loc("This Mac wasn't on Wi-Fi before. Leave the printer's network in the Wi-Fi menu, or turn Wi-Fi off there.") }
}

/// Whether the guide's window may close (Windows' `PrinterSetupViewModel.MayClose`): not while the Mac is on the printer's
/// network and the person wasn't told how to go back. Then the guide stops its wait and goes back first (on the Mac: says
/// how, `PrinterSetupGuide.returnOnClose`); the window closes once back, or stays open saying how, and the next Close closes.
public struct SetupClosing: Equatable, Sendable {
    public enum Answer: Equatable, Sendable {
        /// Close now.
        case close
        /// Stay open: stop the wait, go back (`returnOnClose`), then ask `wentBack`.
        case goBackFirst
        /// Stay open: going back is under way.
        case wait
    }

    public private(set) var returning = false
    public private(set) var toldHow = false

    public init() {}

    /// The window is asked to close while the guide shows `state`.
    public mutating func asked(_ state: SetupState) -> Answer {
        if returning { return .wait }
        if !state.isAway || toldHow { return .close }
        returning = true
        return .goBackFirst
    }

    /// The guide went back, or said how: true when the window closes now (back), false when it stays open saying how.
    public mutating func wentBack(_ state: SetupState) -> Bool {
        returning = false
        toldHow = state.isAway || state.problem == SetupText.leavePrinter
        return !toldHow
    }
}

/// Setting up a new printer's Wi-Fi (roadmap 4.17, the owner's "middle option"; Windows' `PrinterSetupGuide`): find the
/// printer's setup network nearby, have the person join it in macOS's Wi-Fi menu (a sandboxed app doesn't join networks:
/// PLAN, "Mac differences"), open the printer's own setup page where the person enters the home Wi-Fi's details, then have
/// the person go back to the network the Mac was on, waiting to see each step happen. Inkvolt Print never reads, keeps or
/// sends a Wi-Fi password and never changes networks. One call at a time: a call while another runs is ignored (a wait is
/// stopped by cancelling its task). `pause` is how it waits a second (tests make it instant); `onChange` gets each new state.
public actor PrinterSetupGuide {
    /// How long the guide waits for the person to join the printer's network, or to go back, in the Wi-Fi menu.
    public static let menuLimit = 180

    private let wifi: any WifiReading
    private let pause: @Sendable (Duration) async throws -> Void
    private let log: @Sendable (String) -> Void
    private let onChange: @Sendable (SetupState) -> Void
    private var current = SetupState()
    private var before: WifiNow?
    private var busy = false

    public init(_ wifi: any WifiReading, log: @escaping @Sendable (String) -> Void = { _ in },
                pause: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                onChange: @escaping @Sendable (SetupState) -> Void = { _ in }) {
        self.wifi = wifi
        self.log = log
        self.pause = pause
        self.onChange = onChange
    }

    public var state: SetupState { current }

    /// Lists the printers' networks nearby. Read only.
    public func look() async {
        guard !busy, !current.isAway else { return }
        busy = true
        defer { busy = false }
        set(.looking, nil)
        let now: WifiNow
        do { now = try await wifi.now() } catch {
            log("Printer setup: Wi-Fi not read: \(type(of: error))")
            now = .noAdapter
        }
        guard now.hasAdapter else { return set(.noWifi, SetupText.noWifi) }
        let nearby: [WifiNetwork]
        do { nearby = try await wifi.nearby() } catch is WifiLocationError {
            return set(.locationOff, SetupText.locationOff)
        } catch {
            log("Printer setup: networks not listed: \(type(of: error))")
            return set(.choose, SetupText.notListed)
        }
        let found = SetupNetworks.find(nearby.filter { !now.isOn($0) })
        current.candidates = found
        log("Printer setup: \(nearby.count) network(s) nearby, \(found.count) like a printer's.")
        set(.choose, found.isEmpty ? SetupText.noneFound : nil)
    }

    /// The person chose `candidate`: they join it in the Wi-Fi menu and the guide waits to see the Mac on it, then finds the
    /// printer's page. The network the Mac is on now is remembered to go back to. Cancelling the task stops the wait.
    public func connect(_ candidate: SetupCandidate) async {
        guard !busy, !current.isAway, current.candidates.contains(candidate) else { return }
        busy = true
        defer { busy = false }
        do {
            before = try await wifi.now()
            current.homeName = before?.name
            current.joined = candidate
            current.page = nil
            set(.inMenu, SetupText.inMenu(candidate.network.name))
            log("Printer setup: the person joins the printer's network in the Wi-Fi menu.")
            if try await waitFor({ $0.isOn(candidate.network) }) {
                try await findPage()
                return
            }
            log("Printer setup: the Mac didn't join the printer's network in time.")
            await returnCore(SetupText.notJoined, wait: false)
        } catch {
            await returnCore(nil, wait: false)
        }
    }

    /// On the printer's network: its setup page is its gateway (the printer is the access point).
    private func findPage() async throws {
        var page: URL?
        for i in 0..<10 where page == nil {
            page = SetupNetworks.setupPage(await wifi.gateway())
            if page == nil && i < 9 { try await pause(.seconds(1)) } // the printer's DHCP answers after the join
        }
        current.page = page
        set(.onPrinter, page == nil ? SetupText.noPage : nil)
        log(page == nil ? "Printer setup: on the printer's network, no setup page found." : "Printer setup: on the printer's network.")
    }

    /// The person is done on the printer's page (or cancels): they go back in the Wi-Fi menu, and the guide waits to see it.
    public func returnHome() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await returnCore(nil, wait: true)
    }

    /// The window is closing while the Mac may be away (`SetupClosing`): back already is fine, else the person is told at once
    /// how to go back (`couldNotReturn`, or `leavePrinter` for a Mac that was on none), with no wait.
    public func returnOnClose() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        await returnCore(nil, wait: false)
    }

    /// Back by the person's hand after the guide gave up waiting: checked (and waited for) again.
    public func checkBack() async {
        guard !busy, current.step == .couldNotReturn else { return }
        busy = true
        defer { busy = false }
        await returnCore(nil, wait: true)
    }

    /// Back where the Mac was: already there is fine; a Mac that was on no network is told how to leave the printer's;
    /// else the person is asked to choose the network again and, with `wait`, the guide waits to see it.
    private func returnCore(_ why: String?, wait: Bool) async {
        guard let b = before else { return }
        let home = b.name ?? ""
        let now = try? await wifi.now()
        if !b.connected {
            return done(now?.connected == true ? SetupText.leavePrinter : why)
        }
        if let now, now.ssid == b.ssid { return done(why) }
        guard wait else { return couldNotReturn(home) }
        set(.returning, SetupText.goBack(home))
        do {
            if try await waitFor({ $0.ssid == b.ssid }) { return done(why) }
        } catch {
            // the window went: says how, below
        }
        couldNotReturn(home)
    }

    private func couldNotReturn(_ home: String) {
        set(.couldNotReturn, SetupText.couldNotReturn(home))
        log("Printer setup: not back yet; the person is told how.")
    }

    private func done(_ why: String?) {
        current.page = nil
        set(.back, why)
        log("Printer setup: back on the network the Mac was on.")
    }

    /// Up to `menuLimit` seconds, asking each second; a cancelled task throws.
    private func waitFor(_ condition: (WifiNow) -> Bool) async throws -> Bool {
        for second in 0...Self.menuLimit {
            if let now = try? await wifi.now(), condition(now) { return true } // between networks: asked again
            try Task.checkCancellation()
            if second < Self.menuLimit { try await pause(.seconds(1)) }
        }
        return false
    }

    private func set(_ step: SetupStep, _ problem: String?) {
        current.step = step
        current.problem = problem
        current.isAway = before != nil && [.inMenu, .onPrinter, .returning, .couldNotReturn].contains(step)
        onChange(current)
    }

    /// The printer, found on the home network once back: of the printers listed now (id and name, as discovery lists them),
    /// one that wasn't there before the Mac left, the maker's name first. Nil while none is.
    public static func foundPrinter(_ now: [(id: String, name: String)], before: Set<String>, maker: String?) -> (id: String, name: String)? {
        let new = now.filter { !before.contains($0.id) }
        if let maker, !maker.isEmpty, let named = new.first(where: { $0.name.range(of: maker, options: .caseInsensitive) != nil }) { return named }
        return new.first
    }
}
