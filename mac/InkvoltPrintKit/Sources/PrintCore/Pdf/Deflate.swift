import Foundation

/// zlib data (RFC 1950) holding one DEFLATE block (RFC 1951) with the fixed Huffman codes, its repeats found through a hash of
/// three bytes: what PDF's /FlateDecode reads. PrintCore can't use Apple's Compression (it builds on the PC too) and .NET's
/// `ZLibStream` has no Foundation equivalent there, so this is written here; it only has to be small on the pages
/// `PdfWriter.oneBit` gives it (fine, even patterns that CCITT G4 codes badly), not as small as zlib's best.
enum Deflate {
    private static let window = 32_768, minMatch = 3, maxMatch = 258, maxChain = 64

    static func zlib(_ data: [UInt8]) -> [UInt8] {
        var out = BitWriter()
        out.bytes = [0x78, 0x01] // deflate, 32 KB window; (0x78 × 256 + 0x01) is a multiple of 31
        out.put(1, 1) // the last block
        out.put(1, 2) // fixed Huffman codes
        let n = data.count
        var head = [Int](repeating: -1, count: 1 << 15)
        var prev = [Int](repeating: -1, count: window)
        func hash(_ i: Int) -> Int { (Int(data[i]) << 10 ^ Int(data[i + 1]) << 5 ^ Int(data[i + 2])) & 0x7FFF }
        func insert(_ i: Int) {
            guard i + minMatch <= n else { return }
            let h = hash(i)
            prev[i & (window - 1)] = head[h]
            head[h] = i
        }
        data.withUnsafeBufferPointer { d in
            var i = 0
            while i < n {
                var best = 0, distance = 0
                if i + minMatch <= n {
                    var candidate = head[hash(i)]
                    var chain = maxChain
                    let limit = min(maxMatch, n - i)
                    while candidate >= 0 && i - candidate <= window && chain > 0 {
                        var length = 0
                        while length < limit && d[candidate + length] == d[i + length] { length += 1 }
                        if length > best {
                            (best, distance) = (length, i - candidate)
                            if length == limit { break }
                        }
                        let earlier = prev[candidate & (window - 1)]
                        if earlier >= candidate { break } // a slot written over by a later position
                        candidate = earlier
                        chain -= 1
                    }
                }
                if best >= minMatch {
                    out.length(best)
                    out.distance(distance)
                    for k in 0..<best { insert(i + k) }
                    i += best
                } else {
                    out.literal(Int(d[i]))
                    insert(i)
                    i += 1
                }
            }
        }
        out.literal(256) // end of block
        out.flush()
        var (a, b): (UInt32, UInt32) = (1, 0)
        for byte in data {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let adler = b << 16 | a
        out.bytes += [UInt8(adler >> 24), UInt8(adler >> 16 & 0xFF), UInt8(adler >> 8 & 0xFF), UInt8(adler & 0xFF)]
        return out.bytes
    }

    /// Lengths 3 to 258 as codes 257 to 285: each code's first length and its extra bits.
    static let lengthBase = [3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258]
    static let lengthExtra = [0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0]
    /// Distances 1 to 32768 as codes 0 to 29.
    static let distanceBase = [1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145,
                               8193, 12289, 16385, 24577]
    static let distanceExtra = [0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13]

    /// Bits packed from each byte's lowest bit up, as DEFLATE stores them; Huffman codes go in from their first bit.
    private struct BitWriter {
        var bytes: [UInt8] = []
        private var acc = 0, count = 0

        mutating func put(_ value: Int, _ length: Int) {
            acc |= (value & ((1 << length) - 1)) << count
            count += length
            while count >= 8 {
                bytes.append(UInt8(acc & 0xFF))
                acc >>= 8
                count -= 8
            }
        }

        /// A Huffman code, its first bit first.
        mutating func code(_ code: Int, _ length: Int) {
            var reversed = 0
            for i in 0..<length { reversed |= (code >> i & 1) << (length - 1 - i) }
            put(reversed, length)
        }

        /// A literal/length symbol in the fixed code (RFC 1951 3.2.6).
        mutating func literal(_ symbol: Int) {
            switch symbol {
            case 0...143: code(0x30 + symbol, 8)
            case 144...255: code(0x190 + symbol - 144, 9)
            case 256...279: code(symbol - 256, 7)
            default: code(0xC0 + symbol - 280, 8)
            }
        }

        mutating func length(_ length: Int) {
            var c = lengthBase.count - 1
            while lengthBase[c] > length { c -= 1 }
            literal(257 + c)
            put(length - lengthBase[c], lengthExtra[c])
        }

        mutating func distance(_ distance: Int) {
            var c = distanceBase.count - 1
            while distanceBase[c] > distance { c -= 1 }
            code(c, 5)
            put(distance - distanceBase[c], distanceExtra[c])
        }

        mutating func flush() {
            if count > 0 { bytes.append(UInt8(acc & 0xFF)) }
            (acc, count) = (0, 0)
        }
    }
}
