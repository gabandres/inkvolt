import Foundation
import PrintCore
import PrintMac

/// `--report … --snmp` (roadmap 3.2): a community per printer. The Keychain store as the sandboxed app has it (a login
/// kept under a made-up printer id, read back, replaced and deleted again; nothing else is touched), and the made-up
/// agent of demo mode's SNMP-only laser (the tests' fake, on no network) answering only to its community: silent to public
/// and a wrong one, read with the right one, and a printer session connecting only once the login is kept. Nothing secret
/// is written to the report: lines say what was checked and how it came out.
extension Report {
    static func snmpCheck(_ model: AppModel) async -> [String] {
        var lines = ["SNMP access:"]
        lines.append("  Keychain: " + keychainCheck())
        guard let walk = demoWalk() else { return lines + ["  The made-up agent's objects aren't in the app's Demo folder."] }
        let community = "made-up-ro community"
        let agent = SnmpAgent(walk, community: community)
        let host = Demo.snmpHost
        func probe(_ login: SnmpLogin?) async -> SnmpPrinterClient? {
            (try? await SnmpPrinterClient.probe(transport: agent, host: host, login: login)) ?? nil
        }
        let silentToPublic = await probe(nil) == nil
        let silentToWrong = await probe(try? SnmpLogin.forCommunity("wrong")) == nil
        lines.append("  the made-up agent silent to public: \(yes(silentToPublic)), to a wrong community: \(yes(silentToWrong))")
        let right = try? SnmpLogin.forCommunity(community)
        if let printer = await probe(right) {
            let supplies = (try? await printer.supplies().count) ?? 0
            let carried = agent.received.suffix(4).allSatisfy { $0.community == community }
            lines.append("  read with its community: \(printer.identity.model ?? "a printer"), \(supplies) supplies; requests carry it: \(yes(carried))")
        } else {
            lines.append("  read with its community: no answer")
        }
        lines.append("  a session: " + (await sessionCheck(agent, right)))
        return lines
    }

    private static func yes(_ ok: Bool) -> String { ok ? "yes" : "NO" }

    /// The Keychain store's round trip under an id no printer has, deleted at the end.
    private static func keychainCheck() -> String {
        let store = SnmpLoginKeychain()
        let id = "inkvolt-report-check-\(UUID().uuidString.lowercased())"
        defer { store.delete(id) }
        guard let first = try? SnmpLogin.forCommunity("report-check one"), let second = try? SnmpLogin.forCommunity("report-check two")
        else { return "NO (no login made)" }
        guard store.save(first, for: id) else { return "NO (the keychain refused to keep a login)" }
        let readBack = store.get(id) == first
        let replaced = store.save(second, for: id) && store.get(id) == second
        let publicDeletes = store.save(.public, for: id) && store.get(id) == nil
        return "kept and read back: \(yes(readBack)), replaced: \(yes(replaced)), public keeps nothing: \(yes(publicDeletes))"
    }

    /// Connects as the app's printers do, with the login kept in a store of its own.
    private static func sessionCheck(_ agent: SnmpAgent, _ login: SnmpLogin?) async -> String {
        guard let login, let found = (try? await SnmpPrinterClient.probe(transport: agent, host: Demo.snmpHost, login: login)) ?? nil else {
            return "NO (no identity)"
        }
        let id = PrinterId.normalize(nil, host: Demo.snmpHost)
        let logins = MemorySnmpLogins()
        let recipe = PrinterRecipe(transport: { _, _ in HostRouter([:]) }, snmp: agent, snmpLogin: { logins.get(id) })
        let target = PrinterWhere(Demo.snmpHost, snmp: SnmpDevice.from(found.identity))
        func connects() async -> Bool {
            let session = PrinterSession(id: id, recipe: recipe, accepted: { [] }, acceptUuids: { _ in })
            if case .connected? = try? await session.connect(target) { return true }
            return false
        }
        let without = await connects()
        logins.save(login, for: id)
        let with = await connects()
        return "offline without the login: \(yes(!without)), connected with it: \(yes(with))"
    }

    /// demo mode's SNMP-only laser, from the app bundle's `Demo` folder.
    static func demoWalk() -> [SnmpVarBind]? {
        guard let url = Bundle.main.resourceURL?.appendingPathComponent("Demo/snmp-demo/workgroup-laser.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return try? SnmpAgent.parseWalk(text)
    }
}
