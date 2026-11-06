import Foundation
import PrintCore
import PrintMac

/// `--report … --snmp` (roadmap 3.2): a community per printer. The Keychain store as the sandboxed app has it (a login
/// kept under a made-up printer id, read back, replaced and deleted again; nothing else is touched), and the made-up
/// agent of demo mode's SNMP-only laser (the tests' fake, on no network) answering only to its community: silent to public
/// and a wrong one, read with the right one, and a printer session connecting only once the login is kept. Nothing secret
/// is written to the report: lines say what was checked and how it came out. Then SNMPv3 (`v3Check`).
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
        return lines + (await v3Check(walk))
    }

    /// SNMPv3 (Pro) with the system's cryptography as the app installed it (`AppleSnmpCrypto`): a made-up v3 agent
    /// discovered and read signed and encrypted, each wrong part refused and told apart, a v3 login's Keychain round trip,
    /// and the Pro gate switched on without a key keeping a kept v3 user unused (switched back after).
    private static func v3Check(_ walk: [SnmpVarBind]) async -> [String] {
        guard Usm.crypto is AppleSnmpCrypto else { return ["  SNMPv3: NO (the system's cryptography isn't installed)"] }
        guard let login = try? SnmpLogin.forUser("made-up-reader", "made-up auth 2026", "made-up priv 2026"), let user = login.user else {
            return ["  SNMPv3: NO (no login made)"]
        }
        let engine: [UInt8] = [0x80, 0x00, 0x1F, 0x88, 0x80, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08]
        let agent = SnmpAgent(walk, user: user, engineId: engine, engineBoots: 2, engineTime: 600)
        var lines: [String] = []
        let started = ContinuousClock.now
        if let printer = (try? await SnmpPrinterClient.probe(transport: agent, host: Demo.snmpHost, login: login)) ?? nil {
            let supplies = (try? await printer.supplies().count) ?? 0
            let took = (ContinuousClock.now - started) / .milliseconds(1)
            let discoveries = agent.v3Log.filter { $0 == "discovery" }.count
            let answered = agent.v3Log.filter { $0 == "answered" }.count
            lines.append("  SNMPv3: read signed and encrypted: \(printer.identity.version == .v3 ? "yes" : "NO"), \(supplies) supplies, "
                + "\(discoveries) discoveries, \(answered) answers, \(Int(took)) ms")
        } else {
            lines.append("  SNMPv3: read signed and encrypted: NO (no answer)")
        }
        var told: [String] = []
        let wrong: [(String, String, String)] = [("someone", user.authPassphrase, user.privPassphrase),
                                                 (user.name, "wrong auth 2026", user.privPassphrase),
                                                 (user.name, user.authPassphrase, "wrong priv 2026")]
        for (name, auth, priv) in wrong {
            guard let bad = try? SnmpLogin.forUser(name, auth, priv),
                  let client = try? SnmpClient(transport: agent, host: Demo.snmpHost, version: .v3, login: bad) else { continue }
            do {
                _ = try await client.get([PrinterMib.sysName.appending(0)])
                told.append("read!")
            } catch let error as SnmpAccessError {
                told.append("\(error.reason)")
            } catch {
                told.append("no answer")
            }
        }
        lines.append("  SNMPv3: a wrong user, auth and priv passphrase refused as: \(told.joined(separator: ", "))")
        lines.append("  SNMPv3 Keychain: " + keychainV3Check(login))
        let store = MemorySnmpLogins()
        store.save(login, for: "v3")
        let enforced = Pro.enforced
        Pro.enforced = true
        let gated = Pro.licence == nil ? store.usable("v3") == nil : store.usable("v3") != nil
        Pro.enforced = enforced
        lines.append("  SNMPv3 gate: with the Pro check on and \(Pro.licence == nil ? "no key, the kept user unused" : "a key, the kept user used"): "
            + yes(gated))
        return lines
    }

    private static func keychainV3Check(_ login: SnmpLogin) -> String {
        let store = SnmpLoginKeychain()
        let id = "inkvolt-report-check-\(UUID().uuidString.lowercased())"
        defer { store.delete(id) }
        guard store.save(login, for: id) else { return "NO (the keychain refused to keep it)" }
        return "kept and read back: \(yes(store.get(id) == login))"
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
