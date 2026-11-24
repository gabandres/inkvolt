import Foundation

/// SNMP Access…'s check of a login before it's kept (roadmap 3.2): the printer at its address asked with it, as a probe
/// asks. What the sheet says comes from it: kept once answered; a refusal names the part the agent refused (as Add a
/// Printer's `ProbeResult.snmpRefused` does) and keeps nothing; no answer may be a printer that's off or an agent ignoring a
/// wrong community (v1 and v2c agents say nothing), so the user may keep it anyway.
public enum SnmpLoginCheck: Equatable, Sendable {
    /// The printer answered with it, as itself.
    case answered
    /// The SNMPv3 agent refused the user or one of its keys. `fromThisPrinter`: the agent is the printer's own (its engine is
    /// the one its signed answers came from, `SnmpDevice.isItsEngine`); otherwise it may be another device at the address, or a
    /// printer never read over SNMPv3, so Save Anyway may keep the login.
    case refused(SnmpRefusal, fromThisPrinter: Bool = true)
    /// Nothing answered with it.
    case noAnswer
    /// A device answered with it that isn't this printer (another serial number, model or name than `known`'s).
    case anotherDevice

    /// Asks the printer at `host` over `transport` with `login`; `known` is what it said about itself when it was added.
    public static func check(_ login: SnmpLogin, host: String, known: SnmpDevice?, transport: any SnmpTransport) async -> SnmpLoginCheck {
        let refused = RefusalSeen()
        let found = try? await SnmpPrinterClient.probe(transport: transport, host: host, login: login, refused: { refused.saw($0, by: $1) })
        guard let found else {
            guard let why = refused.reason else { return .noAnswer }
            return .refused(why, fromThisPrinter: known?.isItsEngine(refused.by) == true)
        }
        return known?.identify(found.identity) == .different ? .anotherDevice : .answered
    }
}
