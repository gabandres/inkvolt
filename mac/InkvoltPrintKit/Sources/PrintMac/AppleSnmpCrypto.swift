import CommonCrypto
import CryptoKit
import Foundation
import PrintCore

/// SNMPv3's cryptography from the system (roadmap 3.2): SHA-256 and HMAC-SHA-256 from CryptoKit, AES-128's forward cipher
/// from CommonCrypto (one block, ECB: PrintCore's `Usm.aesCfb` builds RFC 3826's CFB on it; CryptoKit has no raw AES).
/// Apple frameworks only, no package. The app installs it at launch (`Usm.crypto`).
public struct AppleSnmpCrypto: SnmpCrypto {
    public init() {}

    public func sha256(_ data: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: data)) }

    public func hmacSha256(key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    public func aes128(key: [UInt8], block: [UInt8]) -> [UInt8] {
        precondition(key.count == kCCKeySizeAES128 && block.count == kCCBlockSizeAES128, "AES-128 takes a 16-byte key and block.")
        var out = [UInt8](repeating: 0, count: kCCBlockSizeAES128 * 2)
        let capacity = out.count
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode), key, key.count, nil,
                             block, block.count, &out, capacity, &moved)
        // One whole block with a valid key can't fail; were it to, nothing may go out encrypted with a made-up stream.
        precondition(status == kCCSuccess && moved == kCCBlockSizeAES128, "CommonCrypto's AES failed.")
        return Array(out.prefix(kCCBlockSizeAES128))
    }
}
