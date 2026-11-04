import CryptoKit
import Foundation
import PrintCore
import Testing
@testable import PrintMac

/// Ported from ProTests.cs (same names): the three tests that need the real ECDSA P-256 check, which PrintCore's tests on
/// the PC do with a stand-in. Here `CryptoKitProVerifier` checks the committed test vector's signatures (made on Windows
/// with Inkvolt's private key; pdf/tools/pro-key/test-vector.json, read in place) and CryptoKit test pairs' keys. Plus
/// the key file's root: the app group both Inkvolt apps claim (mac/docs/research/print-v1-platform.md, "The Pro key's
/// shared file").
@Suite struct ProTests {
    private static func vector() throws -> [String: Any] {
        var url = URL(fileURLWithPath: #filePath) // mac/InkvoltPrintKit/Tests/PrintMacTests/ProTests.swift
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let data = try Data(contentsOf: url.appendingPathComponent("pdf/tools/pro-key/test-vector.json"))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private static func vectorKey(_ which: String) throws -> String {
        try #require((try vector()[which] as? [String: Any])?["key"] as? String)
    }

    private static func refusal(_ key: String, publicKey: [UInt8] = ProKeys.publicKey) -> String {
        do {
            _ = try ProKeys.parse(key, verifier: CryptoKitProVerifier(), publicKey: publicKey)
            return "(accepted)"
        } catch let e as ProKeyError {
            return e.message
        } catch {
            return "\(error)"
        }
    }

    @Test func The_test_vector_reads_with_the_public_key_in_the_shared_library() throws {
        let v = try Self.vector()
        #expect(ProKeys.publicKeyBase64 == v["publicKey"] as? String)
        let valid = try #require(v["valid"] as? [String: Any])
        let licence = try ProKeys.parse(try #require(valid["key"] as? String), verifier: CryptoKitProVerifier())
        #expect(licence.name == valid["name"] as? String)
        #expect(licence.email == valid["email"] as? String)
        #expect(licence.issued == valid["issued"] as? String)
        #expect(licence.products == valid["products"] as? [String])
        #expect(licence.covers(ProKeys.productPrint))
        #expect(Self.refusal(try Self.vectorKey("tampered")).contains("altered"))
        #expect(try ProKeys.parse(try Self.vectorKey("printOnly"), verifier: CryptoKitProVerifier()).products == ["print"])
    }

    @Test func Every_changed_character_of_a_key_is_refused() throws {
        let key = Array(try Self.vectorKey("valid"))
        for i in ProKeys.prefix.count..<key.count where key[i] != "-" {
            var changed = key
            changed[i] = key[i] == "A" ? "B" : "A"
            let refusal = Self.refusal(String(changed))
            #expect(refusal.contains("altered") || refusal.contains("newer version") || refusal.contains("can't be read"), "position \(i): \(refusal)")
        }
    }

    @Test func A_key_signed_by_a_test_pair_passes_and_one_signed_by_another_fails() throws {
        let signer = P256ProSigner()
        #expect(signer.publicKey.count == 65 && signer.publicKey[0] == 4)
        let licence = ProLicence(name: "Grace Hopper", email: "grace@example.com", issued: "2026-11-01", products: ["print"])
        let key = try ProKeys.issue(licence, signer)
        #expect(try ProKeys.parse(key, verifier: CryptoKitProVerifier(), publicKey: signer.publicKey) == licence)
        #expect(Self.refusal(key).contains("altered")) // not Inkvolt's key
        #expect(Self.refusal(key, publicKey: P256ProSigner().publicKey).contains("altered")) // another pair's
    }

    // ───────────── Mac additions ─────────────

    @Test func A_signature_that_isnt_a_p256_point_or_r_and_s_is_refused_not_trapped() {
        let verifier = CryptoKitProVerifier()
        let signer = P256ProSigner()
        let payload: [UInt8] = [1, 2, 3]
        #expect(verifier.isValid(signature: signer.sign(payload), for: payload, publicKey: signer.publicKey))
        #expect(!verifier.isValid(signature: [UInt8](repeating: 0, count: 64), for: payload, publicKey: signer.publicKey))
        #expect(!verifier.isValid(signature: [1, 2], for: payload, publicKey: signer.publicKey))
        #expect(!verifier.isValid(signature: signer.sign(payload), for: payload, publicKey: [4] + [UInt8](repeating: 9, count: 64)))
    }

    @Test func The_key_file_lives_in_the_app_group_both_apps_claim() {
        #expect(ProKeyRoot.appGroup == "AE6TTXW92K.com.bermudezsystems.inkvolt") // the team ID first: no prompt on macOS 15
        let own = MemoryProStore("INKVOLT-PRO-OWN")
        #expect(ProKeyRoot.store(own: own, root: nil) === own) // no container: the app's own settings alone
        let root = (NSTemporaryDirectory() as NSString).appendingPathComponent("InkvoltProRoot-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let shared = ProKeyRoot.store(own: own, root: URL(fileURLWithPath: root))
        #expect(shared is SharedProStore)
        #expect(shared.read() == "INKVOLT-PRO-OWN") // moved into the file
        #expect(ProKeyFile.read(root) == "INKVOLT-PRO-OWN" && own.read() == nil)
    }
}
