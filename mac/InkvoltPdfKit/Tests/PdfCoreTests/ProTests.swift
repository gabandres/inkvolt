import CryptoKit
import Foundation
import Testing
@testable import PdfCore

/// Ported from ProTests.cs (same names): the Inkvolt Pro licence, its key format (pdf/tools/pro-key/README.md), the
/// committed test vector against the public key built in, install and remove, the gate. The suite runs serialized (it
/// sets `Pro.store` and `Pro.enforced`, which the command line asks too). Adapted: Issuing_refuses… expects
/// `PdfEditError` (.NET's ArgumentException); The_command_line_without_a_licence… comes with E8's command line.
extension ProGated {
@Suite struct ProTests {
    private static let ada = ProLicence("Ada Lovelace", "ada@example.com", "2026-10-30", ["pdf", "print"])

    private let signer = P256.Signing.PrivateKey()
    private var publicKey: [UInt8] { Array(signer.publicKey.x963Representation) }

    init() {
        Pro.store = MemoryProStore()
        Pro.enforced = false
    }

    private func issue(_ licence: ProLicence) throws -> String { try ProKeys.issue(licence, signer) }

    private static func refusal(_ key: String, _ publicKey: [UInt8]) -> String {
        do {
            _ = try ProKeys.parse(key, publicKey)
            return "(accepted)"
        } catch let e as ProKeyError {
            return e.message
        } catch {
            return "\(error)"
        }
    }

    @Test func A_key_reads_back_what_was_issued() throws {
        let key = try issue(Self.ada)
        #expect(key.hasPrefix("INKVOLT-PRO-"))
        #expect(key.range(of: "^INKVOLT-PRO-([A-Z2-7]{5}-)*[A-Z2-7]{1,5}$", options: .regularExpression) != nil)
        let read = try ProKeys.parse(key, publicKey)
        #expect(read.name == "Ada Lovelace" && read.email == "ada@example.com" && read.issued == "2026-10-30")
        #expect(read.products == ["pdf", "print"])
        #expect(read.covers("pdf"))
        #expect(!ProLicence("P", "p@x", read.issued, ["print"]).covers("pdf"))
    }

    @Test func Spacing_case_and_line_breaks_from_an_email_dont_matter() throws {
        let key = try issue(Self.ada)
        var mangled = key.lowercased().replacingOccurrences(of: "-", with: " ")
        mangled.insert(contentsOf: "\r\n", at: mangled.index(mangled.startIndex, offsetBy: 40))
        mangled = "  " + mangled + "\n"
        #expect(try ProKeys.parse(mangled, publicKey).name == "Ada Lovelace")
        #expect(ProKeys.format(mangled) == key)
    }

    @Test func Names_in_any_script_round_trip() throws {
        var licence = Self.ada
        licence.name = "José Núñez 李"
        licence.email = "josé@example.com"
        let r = try ProKeys.parse(try issue(licence), publicKey)
        #expect(r.name == "José Núñez 李" && r.email == "josé@example.com")
    }

    @Test func A_changed_character_is_refused_as_altered() throws {
        let key = try issue(Self.ada)
        let from = key.index(key.startIndex, offsetBy: 20)
        let i = key.index(after: key[from...].firstIndex(of: "-")!) // inside the payload (the name)
        var tampered = Array(key)
        let at = key.distance(from: key.startIndex, to: i)
        tampered[at] = tampered[at] == "A" ? "B" : "A"
        #expect(Self.refusal(String(tampered), publicKey).contains("altered"))
        let cut = String(key.dropLast(12)) // the end of the signature missing
        #expect(Self.refusal(cut, publicKey).contains("altered"))
    }

    @Test func A_key_signed_with_another_key_is_refused() throws {
        let other = P256.Signing.PrivateKey()
        #expect(Self.refusal(try ProKeys.issue(Self.ada, other), publicKey).contains("altered"))
    }

    @Test func A_newer_format_version_is_refused_saying_to_update() throws {
        var payload = ProKeys.payload(Self.ada)
        payload[0] = 2
        #expect(Self.refusal(try ProKeys.encode(payload, signer), publicKey).contains("newer version"))
    }

    @Test func Wrong_prefix_bad_characters_and_too_little_are_refused_in_plain_words() {
        #expect(Self.refusal("", publicKey).contains("Paste the key"))
        #expect(Self.refusal("ABCDE-FGHIJ", publicKey).contains("starts with INKVOLT-PRO-"))
        #expect(Self.refusal("INKVOLT-PRINT-ABCDE", publicKey).contains("starts with INKVOLT-PRO-"))
        #expect(Self.refusal("INKVOLT-PRO-ABCD1-0EFGH", publicKey).contains("character that doesn't belong"))
        #expect(Self.refusal("INKVOLT-PRO-ABCDE-FGHIJ", publicKey).contains("incomplete"))
    }

    @Test func A_payload_that_isnt_four_lines_is_refused_even_when_signed() throws {
        let bad = try ProKeys.encode([ProKeys.version] + Array("Ada\nada@example.com\n2026-10-30".utf8), signer)
        #expect(Self.refusal(bad, publicKey).contains("can't be read"))
        let badDate = try ProKeys.encode([ProKeys.version] + Array("Ada\nada@example.com\nOctober\npdf".utf8), signer)
        #expect(Self.refusal(badDate, publicKey).contains("can't be read"))
    }

    @Test func Issuing_refuses_an_empty_name_or_unknown_product() {
        var blank = Self.ada
        blank.name = " "
        var broken = Self.ada
        broken.email = "a\nb"
        var word = Self.ada
        word.products = ["word"]
        var none = Self.ada
        none.products = []
        #expect(throws: PdfEditError.self) { try issue(blank) }
        #expect(throws: PdfEditError.self) { try issue(broken) }
        #expect(throws: PdfEditError.self) { try issue(word) }
        #expect(throws: PdfEditError.self) { try issue(none) }
    }

    @Test func Base32_round_trips_every_length() {
        for n in 0..<12 {
            let bytes = (0..<n).map { UInt8(($0 * 37 + 11) & 255) }
            let text = ProKeys.toBase32(bytes)
            #expect(text.count == (n * 8 + 4) / 5)
            #expect(ProKeys.fromBase32(text) == bytes)
        }
    }

    // ───────────── the committed test vector, against the public key built in ─────────────

    /// pdf/tools/pro-key/test-vector.json, read in place from the repo.
    private static func vector() throws -> [String: Any] {
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: dir.appendingPathComponent("Inkvolt.slnx").path) {
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path { throw PdfEditError("The repo root wasn't found above \(#filePath).") }
            dir = up
        }
        let data = try Data(contentsOf: dir.appendingPathComponent("pdf/tools/pro-key/test-vector.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func vectorKey(_ which: String) throws -> String {
        try #require((try vector()[which] as? [String: Any])?["key"] as? String)
    }

    @Test func The_test_vector_matches_the_public_key_in_core() throws {
        let v = try Self.vector()
        #expect(v["publicKey"] as? String == ProKeys.publicKeyBase64)
        #expect(ProKeys.publicKey.count == 65)
        #expect(ProKeys.publicKey[0] == 4)

        let valid = try #require(v["valid"] as? [String: Any])
        let licence = try ProKeys.parse(try #require(valid["key"] as? String))
        #expect(licence.name == valid["name"] as? String)
        #expect(licence.email == valid["email"] as? String)
        #expect(licence.issued == valid["issued"] as? String)
        #expect(licence.products == valid["products"] as? [String])

        #expect(Self.refusal(try Self.vectorKey("tampered"), ProKeys.publicKey).contains("altered"))

        let printOnly = try ProKeys.parse(try Self.vectorKey("printOnly"))
        #expect(printOnly.products == ["print"])
    }

    // ───────────── install, remove, the gate ─────────────

    @Test func Install_keeps_the_key_in_the_store_and_remove_forgets_it() throws {
        let store = MemoryProStore()
        Pro.store = store
        #expect(Pro.licence == nil)

        let key = try Self.vectorKey("valid")
        let licence = try Pro.install("  " + key.lowercased() + "\n")
        #expect(licence.name == "Ada Lovelace")
        #expect(store.read() == key) // stored as it is shown: prefix and groups of five
        #expect(Pro.licence?.name == "Ada Lovelace")
        #expect(Pro.problem == nil)

        Pro.store = store // another run, same settings
        #expect(Pro.licence?.name == "Ada Lovelace")

        Pro.remove()
        #expect(store.read() == nil)
        #expect(Pro.licence == nil)
    }

    @Test func A_key_for_print_only_or_a_bad_key_isnt_installed() throws {
        func refusal(_ key: String) -> String {
            do {
                try Pro.install(key)
                return "(accepted)"
            } catch let e as ProKeyError {
                return e.message
            } catch {
                return "\(error)"
            }
        }
        #expect(refusal(try Self.vectorKey("printOnly")).contains("Inkvolt Print, not Inkvolt PDF"))
        #expect(refusal(try Self.vectorKey("tampered")).contains("altered"))
        #expect(Pro.licence == nil)
        #expect(Pro.store.read() == nil)
    }

    @Test func A_stored_key_that_no_longer_checks_out_counts_as_none_and_says_why() throws {
        Pro.store = MemoryProStore(try Self.vectorKey("tampered"))
        #expect(Pro.licence == nil)
        #expect(Pro.problem?.contains("no longer checks out") == true)
        Pro.store = MemoryProStore(try Self.vectorKey("printOnly"))
        #expect(Pro.licence == nil)
        #expect(Pro.problem?.contains("Inkvolt Print") == true)
    }

    @Test func With_enforcement_off_everything_is_allowed_with_it_on_a_licence_is_needed() throws {
        Pro.enforced = false
        #expect(ProFeature.allCases.allSatisfy { Pro.allows($0) })

        Pro.enforced = true
        #expect(ProFeature.allCases.allSatisfy { !Pro.allows($0) })
        try Pro.install(try Self.vectorKey("valid"))
        #expect(ProFeature.allCases.allSatisfy { Pro.allows($0) })
        Pro.remove()
        #expect(!Pro.allows(.commandLine))
        Pro.enforced = false
    }

    @Test func Each_feature_has_a_title_a_description_and_a_locked_message() {
        for f in ProFeature.allCases {
            #expect(!Pro.title(f).isEmpty)
            #expect(Pro.describe(f).contains(" "))
            #expect(Pro.locked(f).contains("Inkvolt Pro"))
        }
        #expect(Pro.howToGet.contains("$19"))
    }
}
}
