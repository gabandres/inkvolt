import CommonCrypto
import CryptoKit
import Foundation
import PrintCore

/// SNMPv3's cryptography from the system (roadmap 3.2): MD5, SHA-1 and SHA-256 and their HMACs from CryptoKit (MD5 and SHA-1
/// from its `Insecure`, which RFC 3414's HMAC-MD5-96 and HMAC-SHA-96 need), AES's forward cipher (16-, 24- or 32-byte keys)
/// and DES on one block from CommonCrypto (ECB: PrintCore's `Usm.aesCfb` and `Usm.desCbc` build RFC 3826's CFB and RFC 3414's
/// CBC on them; CryptoKit has no raw AES or DES). Apple frameworks only, no package. The app installs it at launch
/// (`Usm.crypto`).
public struct AppleSnmpCrypto: SnmpCrypto {
    public init() {}

    public func hash(_ algorithm: SnmpHash, _ data: [UInt8]) -> [UInt8] {
        switch algorithm {
        case .md5: Array(Insecure.MD5.hash(data: data))
        case .sha1: Array(Insecure.SHA1.hash(data: data))
        case .sha256: Array(SHA256.hash(data: data))
        }
    }

    public func hmac(_ algorithm: SnmpHash, key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        let k = SymmetricKey(data: key)
        switch algorithm {
        case .md5: return Array(HMAC<Insecure.MD5>.authenticationCode(for: data, using: k))
        case .sha1: return Array(HMAC<Insecure.SHA1>.authenticationCode(for: data, using: k))
        case .sha256: return Array(HMAC<SHA256>.authenticationCode(for: data, using: k))
        }
    }

    public func aes(key: [UInt8], block: [UInt8]) -> [UInt8] {
        precondition([kCCKeySizeAES128, kCCKeySizeAES192, kCCKeySizeAES256].contains(key.count) && block.count == kCCBlockSizeAES128,
                     "AES takes a 16-, 24- or 32-byte key and a 16-byte block.")
        return Self.oneBlock(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), key, block)
    }

    public func des(key: [UInt8], block: [UInt8], encrypt: Bool) -> [UInt8] {
        precondition(key.count == kCCKeySizeDES && block.count == kCCBlockSizeDES, "DES takes an 8-byte key and block.")
        return Self.oneBlock(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmDES), key, block)
    }

    /// One block through CommonCrypto in ECB mode, no padding.
    private static func oneBlock(_ operation: CCOperation, _ algorithm: CCAlgorithm, _ key: [UInt8], _ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: block.count * 2)
        let capacity = out.count
        var moved = 0
        let status = CCCrypt(operation, algorithm, CCOptions(kCCOptionECBMode), key, key.count, nil, block, block.count, &out, capacity, &moved)
        // One whole block with a valid key can't fail; were it to, nothing may go out encrypted with a made-up stream.
        precondition(status == kCCSuccess && moved == block.count, "CommonCrypto's block cipher failed.")
        return Array(out.prefix(block.count))
    }
}
