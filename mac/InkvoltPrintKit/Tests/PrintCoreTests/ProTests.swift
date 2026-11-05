import Foundation
import Testing
@testable import PrintCore

/// A stand-in for ECDSA P-256 (PrintCore has no CryptoKit on Windows): the "signature" is 64 bytes drawn from FNV-1a over
/// the public key and the payload, so a key signed for one public key fails another's check and any changed byte of the
/// payload or signature fails. PrintMac's CryptoKit verifier is checked against the committed test vector on the Mac.
struct StandInSigner: ProSigner, ProSignatureVerifier {
    let publicKey: [UInt8]

    init(_ seed: UInt8) { publicKey = [4] + [UInt8](repeating: seed, count: 64) }
    init(publicKey: [UInt8]) { self.publicKey = publicKey }

    static func signature(_ payload: [UInt8], _ publicKey: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for round in 0..<8 {
            for b in publicKey + [UInt8(round)] + payload {
                h ^= UInt64(b)
                h = h &* 0x0000_0100_0000_01b3
            }
            withUnsafeBytes(of: h.littleEndian) { out += $0 }
        }
        return out
    }

    func sign(_ payload: [UInt8]) -> [UInt8] { Self.signature(payload, publicKey) }

    func isValid(signature: [UInt8], for payload: [UInt8], publicKey: [UInt8]) -> Bool { Self.signature(payload, publicKey) == signature }
}

/// Takes any signature: for reading the committed vector's keys (made on Windows with the real private key) without CryptoKit.
struct TrustingVerifier: ProSignatureVerifier {
    func isValid(signature: [UInt8], for payload: [UInt8], publicKey: [UInt8]) -> Bool { true }
}

/// Ported from ProTests.cs. The Inkvolt Pro licence as Inkvolt Print sees it: the shared key format, the products a key
/// lists, the gate, and the file both apps read (with any folder standing in for the app group container). Adapted:
/// PrintCore can't do ECDSA on Windows, so the keys here are signed by `StandInSigner` (as Inkvolt's public key, for the
/// app's own `Pro`), and the committed vector (pdf/tools/pro-key/test-vector.json, read in place) is decoded with a
/// verifier that trusts its signature: its fields, its public key and that its tampered key is refused. The real signature
/// check of the vector waits for PrintMac's CryptoKit verifier (on the Mac).
/// A_packaged_apps_redirected_copy_is_found_and_the_newest_copy_wins is left out: the Mac has no Store-package redirection,
/// so `ProKeyFile` reads one place (`candidates` covers it in A_key_installed_in_one_app_is_found_by_the_other).
extension ProGated {
@Suite final class ProTests {
    private let root: String
    private static let inkvolt = StandInSigner(publicKey: ProKeys.publicKey)

    init() throws {
        root = (NSTemporaryDirectory() as NSString).appendingPathComponent("InkvoltProTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        Pro.store = MemoryProStore()
        Pro.verifier = Self.inkvolt
        Pro.enforced = false
    }

    deinit {
        Pro.store = MemoryProStore()
        Pro.verifier = NoProSignatureVerifier()
        Pro.enforced = false
        try? FileManager.default.removeItem(atPath: root)
    }

    // ───────────── the committed test vector ─────────────

    private static func vector() throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath) // mac/InkvoltPrintKit/Tests/PrintCoreTests/ProTests.swift
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("pdf/tools/pro-key/test-vector.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func vectorKey(_ which: String) throws -> String {
        try #require((try vector()[which] as? [String: Any])?["key"] as? String)
    }

    /// Keys like the vector's, signed by the stand-in as Inkvolt.
    private static func key(_ name: String = "Ada Lovelace", _ email: String = "ada@example.com", _ products: [String] = ["pdf", "print"]) throws -> String {
        try ProKeys.issue(ProLicence(name: name, email: email, issued: "2026-10-30", products: products), inkvolt)
    }

    @Test func The_test_vector_reads_with_the_public_key_in_the_shared_library() throws {
        let v = try Self.vector()
        #expect(ProKeys.publicKeyBase64 == v["publicKey"] as? String)
        #expect(ProKeys.publicKey.count == 65 && ProKeys.publicKey[0] == 4)
        let valid = try #require(v["valid"] as? [String: Any])
        let licence = try ProKeys.parse(try #require(valid["key"] as? String), verifier: TrustingVerifier())
        #expect(licence.name == valid["name"] as? String)
        #expect(licence.email == valid["email"] as? String)
        #expect(licence.issued == valid["issued"] as? String)
        #expect(licence.products == valid["products"] as? [String])
        #expect(licence.covers(ProKeys.productPrint))
        // The tampered key: refused as altered by a signature check; past one (trusting), its changed name isn't even UTF-8.
        #expect(throws: ProKeyError("The key's contents can't be read. Ask for it again.")) {
            try ProKeys.parse(try Self.vectorKey("tampered"), verifier: TrustingVerifier())
        }
        #expect(throws: ProKeyError("This key has been altered or didn't paste whole. Paste it exactly as it was sent, or ask for it again.")) {
            try ProKeys.parse(try Self.vectorKey("tampered"), verifier: NoProSignatureVerifier())
        }
        // A key written as the vector's is read back to the same text: the encoding is Windows'.
        #expect(ProKeys.format(try #require(valid["key"] as? String)) == valid["key"] as? String)
    }

    @Test func Every_changed_character_of_a_key_is_refused() throws {
        let key = Array(try Self.key())
        for i in ProKeys.prefix.count..<key.count where key[i] != "-" {
            var changed = key
            changed[i] = key[i] == "A" ? "B" : "A"
            do {
                _ = try ProKeys.parse(String(changed), verifier: Self.inkvolt)
                Issue.record("position \(i): accepted")
            } catch let e as ProKeyError {
                #expect(e.message.contains("altered") || e.message.contains("newer version") || e.message.contains("can't be read"), "position \(i): \(e.message)")
            }
        }
    }

    @Test func A_key_signed_by_a_test_pair_passes_and_one_signed_by_another_fails() throws {
        let signer = StandInSigner(7)
        let licence = ProLicence(name: "Grace Hopper", email: "grace@example.com", issued: "2026-11-01", products: ["print"])
        let key = try ProKeys.issue(licence, signer)
        #expect(try ProKeys.parse(key, verifier: signer, publicKey: signer.publicKey) == licence)
        #expect(try ProKeys.parse(key, verifier: signer, publicKey: signer.publicKey).products == ["print"])
        do {
            _ = try ProKeys.parse(key, verifier: signer) // checked against Inkvolt's key: not signed by it
            Issue.record("accepted")
        } catch let e as ProKeyError {
            #expect(e.message.contains("altered"))
        }
    }

    // ───────────── products: a key for Inkvolt Print, for Inkvolt PDF, for both ─────────────

    @Test func A_print_only_key_installs_here_and_is_refused_by_the_pdf_check() throws {
        let printOnly = try Self.key("Pat Printer", "pat@example.com", ["print"])
        let licence = try Pro.install(printOnly)
        #expect(licence.products == ["print"])
        #expect(Pro.licence != nil)
        #expect(Pro.problem == nil)

        let pdf = ProCheck(ProKeys.productPdf, verifier: Self.inkvolt)
        pdf.store = MemoryProStore(printOnly)
        #expect(pdf.licence == nil)
        #expect(pdf.problem == "The saved key is for Inkvolt Print, not Inkvolt PDF.")
        #expect(throws: ProKeyError("This key is for Inkvolt Print, not Inkvolt PDF. A key for Inkvolt PDF lists it.")) { try pdf.install(printOnly) }
    }

    @Test func A_pdf_only_key_is_refused_here_in_plain_words() throws {
        let signer = StandInSigner(9)
        let key = try ProKeys.issue(ProLicence(name: "Ada", email: "ada@example.com", issued: "2026-10-30", products: ["pdf"]), signer)
        // Install checks against Inkvolt's key first (this one isn't signed by it), so test the product check on a parsed licence.
        #expect(!(try ProKeys.parse(key, verifier: signer, publicKey: signer.publicKey).covers(Pro.product)))
        do {
            try Pro.install(key)
            Issue.record("installed")
        } catch let e as ProKeyError {
            #expect(e.message.contains("altered"))
        }
        #expect(Pro.licence == nil)
        // One signed as Inkvolt that lists only pdf: refused here by its product, in plain words.
        #expect(throws: ProKeyError("This key is for Inkvolt PDF, not Inkvolt Print. A key for Inkvolt Print lists it.")) {
            try Pro.install(try Self.key("Ada Lovelace", "ada@example.com", ["pdf"]))
        }
    }

    @Test func With_enforcement_off_everything_is_allowed_with_it_on_a_licence_is_needed() throws {
        Pro.enforced = false
        #expect(ProFeature.allCases.allSatisfy { Pro.allows($0) })
        Pro.enforced = true
        #expect(ProFeature.allCases.allSatisfy { !Pro.allows($0) })
        try Pro.install(try Self.key())
        #expect(ProFeature.allCases.allSatisfy { Pro.allows($0) })
        Pro.remove()
        #expect(!Pro.allows(.fleetExport))
        #expect(Pro.store.read() == nil)
        Pro.enforced = false
    }

    @Test func Each_feature_has_a_title_a_description_and_a_locked_message() {
        for f in ProFeature.allCases {
            #expect(!Pro.title(f).isEmpty)
            #expect(Pro.describe(f).contains(" "))
            #expect(Pro.locked(f).contains("Inkvolt Pro"))
        }
        #expect(Pro.howToGet.contains("Help › Inkvolt Pro…"))
        #expect(Pro.howToGet.contains("Inkvolt PDF"))
    }

    /// Mac difference (PLAN.md P12 1.6): Inkvolt Print for Mac is the App Store's, where a price or a link to buy outside it
    /// breaks guidelines 3.1.1(a) and 3.1.3(b). Windows' refusals name the price and the shop; the Mac's, in the window and on
    /// the command line, say only that it's Pro and where a key is entered, as the Pro window does.
    @Test func No_refusal_names_a_price_or_a_shop() {
        #expect(!namesAPriceOrAShop(Pro.howToGet), "\(Pro.howToGet)")
        for f in ProFeature.allCases {
            #expect(!namesAPriceOrAShop(Pro.locked(f) + Pro.describe(f) + Pro.title(f)))
        }
    }


    // ───────────── the file both apps read ─────────────

    @Test func A_key_installed_in_one_app_is_found_by_the_other() throws {
        let pdfSettings = MemoryProStore(), printSettings = MemoryProStore()
        let pdf = ProCheck(ProKeys.productPdf, verifier: Self.inkvolt)
        pdf.store = SharedProStore(pdfSettings, root)
        let print = ProCheck(ProKeys.productPrint, verifier: Self.inkvolt)
        print.store = SharedProStore(printSettings, root)
        #expect(print.licence == nil)

        let key = try Self.key()
        try pdf.install("  " + key.lowercased() + "\n")
        let stored = try String(contentsOfFile: ProKeyFile.pathUnder(root), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(stored == key) // stored as shown: prefix and groups of five
        #expect(ProKeyFile.candidates(root) == [ProKeyFile.pathUnder(root)])
        #expect(pdfSettings.read() == nil) // the file is the key's home; neither app's settings hold a copy...
        #expect(printSettings.read() == nil)
        print.store = print.store // ...and the other app reads the file afresh
        #expect(print.licence?.name == "Ada Lovelace")
        print.remove()
        #expect(!FileManager.default.fileExists(atPath: ProKeyFile.pathUnder(root)))
        pdf.store = pdf.store
        #expect(pdf.licence == nil) // removed in one app: gone for both
    }

    @Test func A_key_from_the_apps_own_settings_moves_into_the_shared_file() throws {
        let key = try Self.key()
        let settings = MemoryProStore(key) // Inkvolt PDF for Mac keeps the key in its settings
        let print = ProCheck(ProKeys.productPrint, verifier: Self.inkvolt)
        print.store = SharedProStore(settings, root)
        #expect(print.licence?.name == "Ada Lovelace")
        #expect(ProKeyFile.read(root) == key)
        #expect(settings.read() == nil)
    }

    @Test func When_the_shared_file_cant_be_written_the_apps_own_settings_keep_the_key() throws {
        let blocked = (root as NSString).appendingPathComponent("blocked")
        try Data().write(to: URL(fileURLWithPath: blocked)) // a file where the Inkvolt folder should go: the key file can't be made
        let settings = MemoryProStore()
        let print = ProCheck(ProKeys.productPrint, verifier: Self.inkvolt)
        print.store = SharedProStore(settings, blocked)
        let key = try Self.key()
        try print.install(key)
        #expect(settings.read() == key)
        print.store = print.store
        #expect(print.licence?.name == "Ada Lovelace")
    }

    @Test func A_stored_key_that_no_longer_checks_out_counts_as_none_and_says_why() throws {
        var chars = Array(try Self.key())
        chars[chars.count - 3] = chars[chars.count - 3] == "A" ? "B" : "A" // inside the signature
        Pro.store = MemoryProStore(String(chars))
        #expect(Pro.licence == nil)
        #expect(Pro.problem?.contains("no longer checks out") == true)
    }

    // ───────────── Mac additions ─────────────

    @Test func Base32_round_trips_and_dates_are_real_dates() {
        let bytes: [UInt8] = Array(0...255)
        #expect(ProKeys.fromBase32(Array(ProKeys.toBase32(bytes))) == bytes)
        #expect(ProKeys.isDate("2028-02-29") && !ProKeys.isDate("2027-02-29") && !ProKeys.isDate("2026-13-01") && !ProKeys.isDate("26-10-30"))
        // The issue date shown in the user's locale: noon UTC of that day.
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let issued = ProLicence(name: "A", email: "a@example.com", issued: "2026-10-30", products: ["print"]).issuedDate
        #expect(issued.map { utc.dateComponents([.year, .month, .day, .hour], from: $0) } == DateComponents(year: 2026, month: 10, day: 30, hour: 12))
        #expect(ProLicence(name: "A", email: "a@example.com", issued: "2027-02-29", products: ["print"]).issuedDate == nil)
    }

    @Test func The_state_file_keeps_this_apps_own_copy_of_the_key() throws {
        // Windows' AppState.ProKey: the copy behind the shared file, kept while the file couldn't be written.
        var state = PrintState()
        state.proKey = "INKVOLT-PRO-ABCDE"
        let read = try JSONDecoder().decode(PrintState.self, from: try JSONEncoder().encode(state))
        #expect(read.proKey == "INKVOLT-PRO-ABCDE")
        #expect(try JSONDecoder().decode(PrintState.self, from: Data("{}".utf8)).proKey == nil) // a file from before it
    }
}
}

/// A price, a shop or a word asking to buy (Inkvolt Print for Mac's refusals have none: `No_refusal_names_a_price_or_a_shop`).
func namesAPriceOrAShop(_ text: String) -> Bool {
    let t = text.lowercased()
    return [ProCheck.priceText.lowercased(), ProCheck.buyUrl.lowercased(), "bermudezsystems", "http", "$", "purchase", "buy", "price"].contains { t.contains($0) }
}
