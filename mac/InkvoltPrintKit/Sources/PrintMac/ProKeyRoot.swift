import CryptoKit
import Foundation
import PrintCore

/// The Inkvolt Pro key's ECDSA P-256 check with CryptoKit (the Windows suite's `ECDsa.VerifyData`): SHA-256 of the
/// payload, the signature as r||s (IEEE P1363, CryptoKit's raw representation), the public key as the uncompressed point.
/// Both Mac apps set it on their `Pro`; anything malformed is a failed check, never a trap.
public struct CryptoKitProVerifier: ProSignatureVerifier {
    public init() {}

    public func isValid(signature: [UInt8], for payload: [UInt8], publicKey: [UInt8]) -> Bool {
        guard let key = try? P256.Signing.PublicKey(x963Representation: Data(publicKey)),
              let signature = try? P256.Signing.ECDSASignature(rawRepresentation: Data(signature)) else { return false }
        return key.isValidSignature(signature, for: Data(payload))
    }
}

/// Signs keys with a CryptoKit P-256 private key: the tests' test pairs (and an issuing tool). The apps never sign.
public struct P256ProSigner: ProSigner {
    private let key: P256.Signing.PrivateKey

    /// A new, random test pair.
    public init() { key = P256.Signing.PrivateKey() }
    public init(_ key: P256.Signing.PrivateKey) { self.key = key }

    public var publicKey: [UInt8] { Array(key.publicKey.x963Representation) }

    public func sign(_ payload: [UInt8]) -> [UInt8] {
        // CryptoKit's signing fails only when the system's random source does, which the app can't recover from either.
        Array((try? key.signature(for: Data(payload)).rawRepresentation) ?? Data())
    }
}

/// Where both Mac apps keep the key (`ProKeyFile`'s root): the app group container they both claim in their
/// `com.apple.security.application-groups` entitlement, `~/Library/Group Containers/<appGroup>/` (the key at
/// `Inkvolt/pro-key.txt` in it). Inkvolt Print is sandboxed (Mac App Store), Inkvolt PDF isn't (Developer ID); a group
/// whose ID starts with the team ID is one macOS 15 lets either open without asking the user (research file, "The Pro
/// key's shared file").
public enum ProKeyRoot {
    public static let appGroup = "AE6TTXW92K.com.bermudezsystems.inkvolt"

    /// The container, or nil when this copy of the app doesn't claim the group (a build signed without the entitlement).
    public static var url: URL? { FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) }

    /// The app's key store: the shared file under `root` with the app's own settings behind it (`SharedProStore`), or the
    /// settings alone when there's no container.
    public static func store(own: ProStore, root: URL? = ProKeyRoot.url) -> ProStore {
        guard let root else { return own }
        return SharedProStore(own, root.path)
    }
}
