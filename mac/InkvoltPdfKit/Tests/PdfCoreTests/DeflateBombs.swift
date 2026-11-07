import Foundation

/// Bytes as a head, one byte repeated `count` times, and a tail: a compression bomb's layers described without holding
/// them (4 GB of zeros is a count), so building one costs microseconds, not the minutes zlib takes to deflate 4 GB.
struct RunBytes {
    var head: [UInt8]
    var byte: UInt8 = 0
    var count = 0
    var tail: [UInt8] = []

    var bytes: [UInt8] { head + [UInt8](repeating: byte, count: count) + tail }

    /// RFC 1950's Adler-32 of the bytes, the run's in one step.
    var adler32: UInt32 {
        let m: UInt64 = 65521
        var a: UInt64 = 1, b: UInt64 = 0
        for x in head {
            a = (a + UInt64(x)) % m
            b = (b + a) % m
        }
        // k bytes c: b grows by k·a + c·k(k+1)/2, a by k·c.
        let k = UInt64(count), c = UInt64(byte)
        let triangle = k % 2 == 0 ? (k / 2 % m) * ((k + 1) % m) % m : (k % m) * ((k + 1) / 2 % m) % m
        let grown = (k % m) * a % m
        b = (b + grown + c * triangle % m) % m
        a = (a + (k % m) * c % m) % m
        for x in tail {
            a = (a + UInt64(x)) % m
            b = (b + a) % m
        }
        return UInt32(b << 16 | a)
    }
}

/// Deflate written by hand (RFC 1951), for bombs: a run of one byte becomes matches of 258 at distance 1 in a block whose
/// code gives the match two bits, so four go to a byte, 1,032 to 1, deflate's most; and those bytes are themselves one
/// byte repeated, so the next layer is built the same way.
enum HandDeflate {
    /// Deflate's bit order: numbers least significant bit first, Huffman codes most significant first. The one stretch
    /// of a repeated byte is kept as a count.
    private struct Bits {
        var out = RunBytes(head: [])
        var pastRun = false
        var acc = 0
        var n = 0

        mutating func number(_ value: Int, _ width: Int) {
            for i in 0..<width { bit((value >> i) & 1) }
        }

        mutating func code(_ value: Int, _ width: Int) {
            for i in stride(from: width - 1, through: 0, by: -1) { bit((value >> i) & 1) }
        }

        mutating func bit(_ b: Int) {
            acc |= b << n
            n += 1
            if n == 8 {
                put(UInt8(acc))
                acc = 0
                n = 0
            }
        }

        mutating func put(_ b: UInt8) {
            if pastRun { out.tail.append(b) } else { out.head.append(b) }
        }

        /// A literal in the fixed code (RFC 1951 3.2.6).
        mutating func literal(_ b: UInt8) {
            if b < 144 { code(0x30 + Int(b), 8) } else { code(0x190 + Int(b) - 144, 9) }
        }

        /// `pairs` times the bits 1 then 0; the whole bytes among them kept as the run.
        mutating func pairs(_ pairs: Int) {
            let total = pairs * 2
            var i = 0
            while i < total && n != 0 {
                bit(i % 2 == 0 ? 1 : 0)
                i += 1
            }
            let whole = (total - i) / 8
            var value = 0
            for t in 0..<8 where (i + t) % 2 == 0 { value |= 1 << t }
            out.byte = UInt8(value)
            out.count = whole
            pastRun = true
            i += whole * 8
            while i < total {
                bit(i % 2 == 0 ? 1 : 0)
                i += 1
            }
        }

        mutating func finish() -> RunBytes {
            if n > 0 { put(UInt8(acc)) }
            acc = 0
            n = 0
            return out
        }
    }

    /// Raw deflate of `data`: its head, the run's first byte and what doesn't fill a match as fixed-code literals; the
    /// rest of the run as matches; its tail as literals.
    static func raw(_ data: RunBytes) -> RunBytes {
        var w = Bits()
        let matches = data.count > 0 ? (data.count - 1) / 258 : 0
        let literals = data.count - matches * 258
        w.number(0, 1)
        w.number(1, 2) // fixed codes
        for b in data.head { w.literal(b) }
        for _ in 0..<literals { w.literal(data.byte) }
        w.code(0, 7) // end of block
        if matches > 0 {
            w.number(0, 1)
            w.number(2, 2) // dynamic codes: 286 lengths, 1 distance, 18 code-length lengths
            w.number(29, 5)
            w.number(0, 5)
            w.number(14, 4)
            // The code-length code, in RFC order: only 18 (k unused symbols) and 1 (a symbol of length 1), a bit each:
            // 1 is 0, 18 is 1.
            for symbol in [16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1] { w.number(symbol == 18 || symbol == 1 ? 1 : 0, 3) }
            func unused(_ k: Int) {
                w.code(1, 1)
                w.number(k - 11, 7)
            }
            func lengthOne() { w.code(0, 1) }
            unused(138)
            unused(118) // literals 0-255
            lengthOne() // 256, the end of the block: code 0
            unused(28) // 257-284
            lengthOne() // 285, a match of 258: code 1
            lengthOne() // distance 1: code 0
            w.pairs(matches) // each match: 1, then its distance, 0
            w.code(0, 1) // end of block
        }
        w.number(1, 1)
        w.number(1, 2) // final block, fixed codes
        for b in data.tail { w.literal(b) }
        w.code(0, 7)
        return w.finish()
    }

    /// A zlib stream (RFC 1950) of `data`.
    static func zlib(_ data: RunBytes) -> RunBytes {
        var out = raw(data)
        out.head = [0x78, 0x9C] + out.head
        let sum = data.adler32
        out.tail += [UInt8(sum >> 24), UInt8((sum >> 16) & 255), UInt8((sum >> 8) & 255), UInt8(sum & 255)]
        return out
    }

    /// `data` zlib-compressed `times` times over.
    static func zlib(_ data: RunBytes, times: Int) -> RunBytes {
        var out = data
        for _ in 0..<times { out = zlib(out) }
        return out
    }
}
