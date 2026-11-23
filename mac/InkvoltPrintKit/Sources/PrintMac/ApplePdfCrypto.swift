import CommonCrypto
import CryptoKit
import Foundation
import PrintCore

/// A PDF password's cryptography from the system (roadmap 4.18): SHA-256, SHA-384 and SHA-512 from CryptoKit, AES-128 and
/// AES-256 in CBC from CommonCrypto (CryptoKit has no raw AES-CBC). PrintCore's `PdfEncryption` builds the standard security
/// handler's revision 6 on it. Apple frameworks only, no package. The app installs it at launch (`PdfEncryption.crypto`).
public struct ApplePdfCrypto: PdfCrypto {
    public init() {}

    public func sha256(_ data: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: data)) }

    public func sha384(_ data: [UInt8]) -> [UInt8] { Array(SHA384.hash(data: data)) }

    public func sha512(_ data: [UInt8]) -> [UInt8] { Array(SHA512.hash(data: data)) }

    public func aesCbcEncrypt(key: [UInt8], iv: [UInt8], _ data: [UInt8], pad: Bool) -> [UInt8] {
        precondition((key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256) && iv.count == kCCBlockSizeAES128,
                     "AES-CBC takes a 16- or 32-byte key and a 16-byte IV.")
        precondition(pad || data.count % kCCBlockSizeAES128 == 0, "Without padding, AES-CBC takes whole blocks.")
        var out = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
        let capacity = out.count
        var moved = 0
        let status = CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(pad ? kCCOptionPKCS7Padding : 0),
                             key, key.count, iv, data, data.count, &out, capacity, &moved)
        // Whole blocks (or padding) with a valid key can't fail; were it to, nothing may go out with made-up bytes.
        precondition(status == kCCSuccess, "CommonCrypto's AES failed.")
        return Array(out.prefix(moved))
    }
}
