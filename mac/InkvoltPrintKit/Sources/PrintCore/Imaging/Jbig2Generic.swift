import Foundation

/// Lossless JBIG2 (ITU-T T.88) of a black-and-white image (Inkvolt PDF's roadmap 4.8, the Windows suite's `Jbig2Generic`,
/// ported as is so both write the same bytes): one immediate generic region over the whole page, coded pixel by pixel with
/// the MQ arithmetic coder in template 0's 16-pixel contexts (the four adaptive pixels where T.88 puts them by default).
/// Every pixel is coded as it is: no symbol matching or substitution, so nothing like the scanners whose JBIG2 swapped a 6
/// for an 8. As PDF's /JBIG2Decode reads it embedded (a page information segment, then the region; no globals, no file
/// header): a set bit is black. A page of text usually comes out a quarter smaller than `CcittG4`'s, since each pixel is
/// predicted from its neighbours rather than coded as runs. No typical prediction (TPGDON): Windows' own PDF reader draws
/// noise for most pages coded with it, though MuPDF reads them, and it saves little on a page of text.
public enum Jbig2Generic {
    /// Template 0's adaptive pixels at T.88's nominal places: (3, −1), (−3, −1), (2, −2), (−2, −2).
    private static let adaptive: [Int8] = [3, -1, -3, -1, 2, -2, -2, -2]

    /// The image as PDF's /JBIG2Decode stream data (embedded organisation, no globals).
    /// - Throws: `CancellationError` when `stop` fires (checked every 64 rows).
    public static func encode(_ image: BitImage, stop: BatchStop? = nil) throws -> [UInt8] {
        let region = try self.region(image, stop)
        var out: [UInt8] = []
        out.reserveCapacity(region.count + 64)
        // Page information (type 48): size, resolution unknown, flags 0 (white default, lossless region), not striped.
        var page = [UInt8](repeating: 0, count: 19)
        put32(&page, 0, image.width)
        put32(&page, 4, image.height)
        segment(&out, 0, 48, page)
        // Immediate generic region (type 38): region information, generic region flags, the adaptive pixels, the coded data.
        var head = [UInt8](repeating: 0, count: 17 + 1 + 8)
        put32(&head, 0, image.width)
        put32(&head, 4, image.height)
        // x and y 0, combination operator OR (the page is white beneath)
        head[17] = 0 // MMR 0, GBTEMPLATE 0, TPGDON 0
        for i in 0..<8 { head[18 + i] = UInt8(bitPattern: adaptive[i]) }
        segment(&out, 1, 38, head + region)
        return out
    }

    private static func put32(_ b: inout [UInt8], _ at: Int, _ v: Int) {
        let u = UInt32(truncatingIfNeeded: v)
        b[at] = UInt8(u >> 24)
        b[at + 1] = UInt8((u >> 16) & 0xFF)
        b[at + 2] = UInt8((u >> 8) & 0xFF)
        b[at + 3] = UInt8(u & 0xFF)
    }

    /// A segment header (T.88 §7.2) with no referred-to segments, on page 1, then its data.
    private static func segment(_ out: inout [UInt8], _ number: Int, _ type: UInt8, _ data: [UInt8]) {
        var h = [UInt8](repeating: 0, count: 11)
        put32(&h, 0, number)
        h[4] = type // page association in one byte, not deferred
        h[5] = 0    // no referred-to segments, no retention bits
        h[6] = 1    // page 1
        put32(&h, 7, data.count)
        out += h
        out += data
    }

    /// The generic region's arithmetic-coded pixels (T.88 §6.2.5.7 run backwards, as its encoder).
    private static func region(_ image: BitImage, _ stop: BatchStop?) throws -> [UInt8] {
        let width = image.width, height = image.height, stride = image.stride
        let pad = 4 // each row with 4 white pixels either side, so a context never reads past the row
        let rowLength = width + 2 * pad
        // Three rows of 0/1 bytes: two above and the row coded.
        var up2 = [UInt8](repeating: 0, count: rowLength)
        var up1 = [UInt8](repeating: 0, count: rowLength)
        var line = [UInt8](repeating: 0, count: rowLength)
        var coder = MqEncoder(capacity: max(64, image.bits.count / 16))
        try image.bits.withUnsafeBufferPointer { src in
            for y in 0..<height {
                if y & 63 == 0 { try stop?.check() }
                for i in 0..<rowLength { line[i] = 0 }
                let start = y * stride
                for x in 0..<width { line[pad + x] = (src[start + (x >> 3)] >> UInt8(7 - (x & 7))) & 1 }

                // The context as T.88's Figure 3 numbers it: bits 0-3 this row's x−1 to x−4; bits 4-10 the row above's x+3
                // (A1) to x−3 (A2); bits 11-15 the row two above's x+2 (A3) to x−2 (A4). Each part is a window slid one
                // pixel right per pixel, the newest pixel coming in at its low bit.
                var left = 0, above = 0, above2 = 0
                for i in (pad - 3)..<pad { above = (above << 1) | Int(up1[i + 3]) }
                for i in (pad - 2)..<pad { above2 = (above2 << 1) | Int(up2[i + 2]) }
                for i in pad..<(pad + width) {
                    above = ((above << 1) | Int(up1[i + 3])) & 0x7F
                    above2 = ((above2 << 1) | Int(up2[i + 2])) & 0x1F
                    coder.encode(Int(line[i]), left | above << 4 | above2 << 11)
                    left = ((left << 1) | Int(line[i])) & 0xF
                }
                // The rows move up one (Windows' rows[0] = up1, rows[1] = line, rows[2] = up2): the row two above becomes
                // the next row's buffer.
                swap(&up2, &up1)
                swap(&up1, &line)
            }
        }
        return coder.finish()
    }

    /// The MQ arithmetic encoder (T.88 Annex E, as JPEG 2000's): 65536 contexts, each a probability state and its more
    /// probable symbol; bytes after a 0xFF carry 7 bits, so the data never holds a marker; ended with 0xFF 0xAC.
    private struct MqEncoder {
        private static let qe: [UInt32] = [
            0x5601, 0x3401, 0x1801, 0x0AC1, 0x0521, 0x0221, 0x5601, 0x5401, 0x4801, 0x3801, 0x3001, 0x2401, 0x1C01, 0x1601,
            0x5601, 0x5401, 0x5101, 0x4801, 0x3801, 0x3401, 0x3001, 0x2801, 0x2401, 0x2201, 0x1C01, 0x1801, 0x1601, 0x1401,
            0x1201, 0x1101, 0x0AC1, 0x09C1, 0x08A1, 0x0521, 0x0441, 0x02A1, 0x0221, 0x0141, 0x0111, 0x0085, 0x0049, 0x0025,
            0x0015, 0x0009, 0x0005, 0x0001, 0x5601,
        ]

        private static let nmps: [UInt8] = [
            1, 2, 3, 4, 5, 38, 7, 8, 9, 10, 11, 12, 13, 29, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31,
            32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 44, 45, 45, 46,
        ]

        private static let nlps: [UInt8] = [
            1, 6, 9, 12, 29, 33, 6, 14, 14, 14, 17, 18, 20, 21, 14, 14, 15, 16, 17, 18, 19, 19, 20, 21, 22, 23, 24, 25, 26, 27,
            28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39, 40, 41, 42, 43, 46,
        ]

        private static let switches: [Bool] = [true, false, false, false, false, false, true, false, false, false, false, false, false, false, true]

        /// Per context: the state's index (low 7 bits) and the more probable symbol (bit 7).
        private var states = [UInt8](repeating: 0, count: 65536)
        private var out: [UInt8]
        private var a: UInt32 = 0x8000, c: UInt32 = 0
        private var ct = 12
        private var b = -1 // the byte not yet written (−1: none yet; T.88's byte before the first)

        init(capacity: Int) {
            out = []
            out.reserveCapacity(capacity)
        }

        mutating func encode(_ bit: Int, _ context: Int) {
            let state = states[context]
            let index = Int(state & 0x7F)
            var mps = Int(state >> 7)
            let q = Self.qe[index]
            a -= q
            if bit == mps {
                if a & 0x8000 != 0 {
                    c += q
                    return
                }
                if a < q { a = q } else { c += q }
                states[context] = Self.nmps[index] | UInt8(mps << 7)
            } else {
                if a < q { c += q } else { a = q }
                if index < Self.switches.count && Self.switches[index] { mps = 1 - mps }
                states[context] = Self.nlps[index] | UInt8(mps << 7)
            }
            repeat {
                a <<= 1
                c <<= 1
                ct -= 1
                if ct == 0 { byteOut() }
            } while a & 0x8000 == 0
        }

        private mutating func byteOut() {
            if b == 0xFF {
                next(Int((c >> 20) & 0xFF))
                c &= 0xFFFFF
                ct = 7
                return
            }
            if c >= 0x800_0000 {
                b += 1 // the carry (never into the byte before the first: the interval starts below 2^27 there)
                if b == 0xFF {
                    c &= 0x7FF_FFFF
                    next(Int((c >> 20) & 0xFF))
                    c &= 0xFFFFF
                    ct = 7
                    return
                }
            }
            next(Int((c >> 19) & 0xFF)) // a carry already added to the byte before is cut off here
            c &= 0x7FFFF
            ct = 8
        }

        private mutating func next(_ v: Int) {
            if b >= 0 { out.append(UInt8(b)) }
            b = v
        }

        mutating func finish() -> [UInt8] {
            // SETBITS: the most 1s in C within the interval, so the decoder's trailing reads can be anything.
            let temp = c + a
            c |= 0xFFFF
            if c >= temp { c -= 0x8000 }
            c <<= UInt32(ct)
            byteOut()
            c <<= UInt32(ct)
            byteOut()
            if b != 0xFF { next(0xFF) }
            next(0xAC)
            next(-1)
            return out
        }
    }
}
