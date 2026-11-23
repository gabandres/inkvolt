import Foundation

/// A made-up Wi-Fi for demo mode and tests (roadmap 4.17, Windows' `DemoWifi`): on "Home Wi-Fi", with a new HP printer's open
/// setup network, an Epson's secured Wi-Fi Direct network, a phone's Wi-Fi Direct and a neighbour's in range. The made-up
/// person joins `personJoins` when the guide looks a second time after it's set (the first look is the guide noting where the
/// Mac is; the person acts once asked); the printer's network gives 192.168.223.1, as HP's setup networks do. Nothing
/// touches this Mac's real Wi-Fi.
public final class DemoWifi: WifiReading, @unchecked Sendable {
    public static let home = net("Home Wi-Fi", 90, secured: true)
    public static let hpSetup = net("HP-Setup>5c-DeskJet 4155e", 70, secured: false)
    public static let epsonDirect = net("DIRECT-7A-EPSON-ET-2850 Series", 55, secured: true)
    public static let phone = net("DIRECT-ab-Galaxy S24", 60, secured: true)
    public static let neighbour = net("Neighbour 5G", 30, secured: true)

    public static func net(_ name: String, _ signal: Int, secured: Bool) -> WifiNetwork {
        WifiNetwork(ssid: Array(name.utf8), signal: signal, secured: secured)
    }

    private let lock = NSLock()
    private var _current = WifiNow(hasAdapter: true, ssid: home.ssid)
    private var _inRange = [home, hpSetup, epsonDirect, phone, neighbour]
    private var _calls: [String] = []
    private var _personJoins: WifiNetwork?
    private var looks = 0
    private var _noAdapter = false
    private var _locationOff = false

    public init() {}

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    public var current: WifiNow {
        get { locked { _current } }
        set { locked { _current = newValue } }
    }

    public var inRange: [WifiNetwork] {
        get { locked { _inRange } }
        set { locked { _inRange = newValue } }
    }

    /// What the made-up Mac was asked to do, in order (tests: nothing but scans).
    public var calls: [String] { locked { _calls } }

    /// The network the made-up person joins in the Wi-Fi menu once asked (nil: they don't).
    public var personJoins: WifiNetwork? {
        get { locked { _personJoins } }
        set { locked { _personJoins = newValue; looks = 0 } }
    }

    public var noAdapter: Bool {
        get { locked { _noAdapter } }
        set { locked { _noAdapter = newValue } }
    }

    public var locationOff: Bool {
        get { locked { _locationOff } }
        set { locked { _locationOff = newValue } }
    }

    public func now() async throws -> WifiNow {
        locked {
            if _noAdapter { return .noAdapter }
            if let joins = _personJoins {
                looks += 1
                if looks >= 2 {
                    _current = WifiNow(hasAdapter: true, ssid: joins.ssid)
                    _personJoins = nil
                }
            }
            return _current
        }
    }

    public func nearby() async throws -> [WifiNetwork] {
        let (off, list): (Bool, [WifiNetwork]) = locked {
            _calls.append("scan")
            return (_locationOff, _inRange)
        }
        if off { throw WifiLocationError() }
        return list
    }

    public func gateway() async -> String? {
        let now = current
        if now.isOn(Self.hpSetup) || now.isOn(Self.epsonDirect) { return "192.168.223.1" }
        return now.isOn(Self.home) ? "192.168.1.1" : nil
    }
}
