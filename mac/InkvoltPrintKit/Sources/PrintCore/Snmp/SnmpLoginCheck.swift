import Foundation

/// SNMP Access…'s check of a login before it's kept (roadmap 3.2): the printer at its address asked with it, as a probe
/// asks. What the sheet says comes from it: kept once answered; a refusal names the part the agent refused (as Add a
/// Printer's `ProbeResult.snmpRefused` does) and keeps nothing; no answer may be a printer that's off or an agent ignoring a
/// wrong community (v1 and v2c agents say nothing), so the user may keep it anyway.
public enum SnmpLoginCheck: Equatable, Sendable {
    /// The printer answered with it, as itself.
    case answered
    /// The SNMPv3 agent refused the user or one of its keys.
    case refused(SnmpRefusal)
    /// Nothing answered with it.
    case noAnswer
    /// A device answered with it that isn't this printer (another serial number, model or name than `known`'s).
    case anotherDevice

    /// Asks the printer at `host` over `transport` with `login`; `known` is what it said about itself when it was added.
    public static func check(_ login: SnmpLogin, host: String, known: SnmpDevice?, transport: any SnmpTransport) async -> SnmpLoginCheck {
        let refused = RefusalSeen()
        let found = try? await SnmpPrinterClient.probe(transport: transport, host: host, login: login, refused: { refused.saw($0) })
        guard let found else { return refused.reason.map(SnmpLoginCheck.refused) ?? .noAnswer }
        return known?.identify(found.identity) == .different ? .anotherDevice : .answered
    }
}
