import Foundation

/// Small real files written from their formats' specs, so demo mode and the tests can run a batch through the real engines
/// with no files shipped (Windows' `BatchPrintSamples`): PDFs with a given number of pages (one with a password, RC4 40-bit as
/// the PDF 1.3 standard handler writes it), a baseline JPEG, a PNG, a multi-page TIFF. Each page or picture is plain grey.
/// Mac difference: the PNG's pixels are stored, not deflated (PrintCore has no zlib; the file is larger, as valid).
public enum BatchPrintSamples {
    private static let pad: [UInt8] = [0x28, 0xBF, 0x4E, 0x5E, 0x4E, 0x75, 0x8A, 0x41, 0x64, 0x00, 0x4E, 0x56, 0xFF, 0xFA, 0x01, 0x08,
                                       0x2E, 0x2E, 0x00, 0xB6, 0xD0, 0x68, 0x3E, 0x80, 0x2F, 0x0C, 0xA9, 0xFE, 0x64, 0x53, 0x69, 0x7A]

    /// A PDF of `pages` Letter pages, each saying its number and file; with `password`, it opens only with that.
    public static func pdf(_ pages: Int, _ label: String, password: String? = nil) -> [UInt8] {
        let fileId = Digest.md5(Array((label + String(pages)).utf8))
        var key: [UInt8]?
        var encrypt: String?
        let kids = (0..<pages).map { "\(4 + $0 * 2) 0 R" }.joined(separator: " ")
        var objects: [[UInt8]] = [
            Array("<< /Type /Catalog /Pages 2 0 R >>".utf8),
            Array("<< /Type /Pages /Kids [\(kids)] /Count \(pages) >>".utf8),
            Array("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>".utf8),
        ]
        let encryptNumber = 4 + pages * 2
        if let password {
            let permissions: Int32 = -44 // all printing allowed; the bits above 6 set, as the standard handler has them
            let owner = rc4(Array(Digest.md5(padded(password)).prefix(5)), padded(password))
            let p = UInt32(bitPattern: permissions)
            let hashed = Digest.md5(padded(password) + owner + [UInt8(p & 0xFF), UInt8(p >> 8 & 0xFF), UInt8(p >> 16 & 0xFF), UInt8(p >> 24)] + fileId)
            key = Array(hashed.prefix(5))
            let user = rc4(key!, pad)
            encrypt = "<< /Filter /Standard /V 1 /R 2 /O <\(hex(owner))> /U <\(hex(user))> /P \(permissions) >>"
        }
        let text = String(label.unicodeScalars.filter { $0.value >= 0x20 && $0.value <= 0x7E && $0 != "(" && $0 != ")" && $0 != "\\" })
        for i in 0..<pages {
            let number = 4 + i * 2
            objects.append(Array("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents \(number + 1) 0 R >>".utf8))
            var content = Array("BT /F1 36 Tf 72 680 Td (\(text) page \(i + 1)) Tj ET".utf8)
            if let key { content = rc4(objectKey(key, number + 1), content) }
            objects.append(Array("<< /Length \(content.count) >>\nstream\n".utf8) + content + Array("\nendstream".utf8))
        }
        if let encrypt { objects.append(Array(encrypt.utf8)) }

        var pdf = Array("%PDF-1.3\n".utf8)
        var offsets: [Int] = []
        for (i, object) in objects.enumerated() {
            offsets.append(pdf.count)
            pdf += Array("\(i + 1) 0 obj\n".utf8) + object + Array("\nendobj\n".utf8)
        }
        let xref = pdf.count
        pdf += Array("xref\n0 \(objects.count + 1)\n0000000000 65535 f \n".utf8)
        for o in offsets { pdf += Array((String(repeating: "0", count: max(0, 10 - String(o).count)) + String(o) + " 00000 n \n").utf8) }
        let id = hex(fileId)
        let encryptRef = encrypt == nil ? "" : " /Encrypt \(encryptNumber) 0 R"
        pdf += Array("trailer\n<< /Size \(objects.count + 1) /Root 1 0 R /ID [<\(id)> <\(id)>]\(encryptRef) >>\nstartxref\n\(xref)\n%%EOF\n".utf8)
        return pdf
    }

    private static func hex(_ bytes: [UInt8]) -> String { Digest.hex(bytes, uppercase: true) }

    private static func padded(_ password: String) -> [UInt8] {
        let bytes = password.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) } // Latin-1
        return Array(bytes.prefix(32)) + Array(pad.prefix(32 - min(32, bytes.count)))
    }

    private static func objectKey(_ key: [UInt8], _ number: Int) -> [UInt8] {
        let extra: [UInt8] = [UInt8(number & 0xFF), UInt8(number >> 8 & 0xFF), UInt8(number >> 16 & 0xFF), 0, 0]
        return Array(Digest.md5(key + extra).prefix(min(key.count + 5, 16)))
    }

    private static func rc4(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        var s = (0..<256).map { UInt8($0) }
        var j = 0
        for i in 0..<256 {
            j = (j + Int(s[i]) + Int(key[i % key.count])) & 255
            s.swapAt(i, j)
        }
        var result = [UInt8](repeating: 0, count: data.count)
        var a = 0, b = 0
        for n in 0..<data.count {
            a = (a + 1) & 255
            b = (b + Int(s[a])) & 255
            s.swapAt(a, b)
            result[n] = data[n] ^ s[(Int(s[a]) + Int(s[b])) & 255]
        }
        return result
    }

    /// A baseline mid-grey JPEG: no block differs from the last, so the entropy data is two bits a block.
    public static func jpeg(_ width: Int, _ height: Int) -> [UInt8] {
        var j: [UInt8] = [0xFF, 0xD8]
        j += [0xFF, 0xE0, 0, 16, 0x4A, 0x46, 0x49, 0x46, 0, 1, 1, 1, 0, 150, 0, 150, 0, 0] // JFIF, 150 dpi
        j += [0xFF, 0xDB, 0, 67, 0] + [UInt8](repeating: 8, count: 64) // quantization 8: a DC step is one grey level
        j += [0xFF, 0xC0, 0, 11, 8, UInt8(height >> 8 & 0xFF), UInt8(height & 0xFF), UInt8(width >> 8 & 0xFF), UInt8(width & 0xFF), 1, 1, 0x11, 0]
        // One Huffman code each, "0": DC difference category 0, AC end of block.
        for table: UInt8 in [0x00, 0x10] {
            j += [0xFF, 0xC4, 0, 20, table, 1] + [UInt8](repeating: 0, count: 15) + [0]
        }
        j += [0xFF, 0xDA, 0, 8, 1, 1, 0x00, 0, 63, 0]
        let blocks = ((width + 7) / 8) * ((height + 7) / 8)
        j += [UInt8](repeating: 0, count: blocks / 4) // four blocks to the byte, each "0" and "0"
        let last = (blocks % 4) * 2
        if last > 0 { j.append(UInt8(0xFF >> last)) } // padded with ones
        j += [0xFF, 0xD9]
        return j
    }

    /// A grey 8-bit PNG, its pixels in stored deflate blocks.
    public static func png(_ width: Int, _ height: Int, shade: UInt8 = 128) -> [UInt8] {
        var raw: [UInt8] = []
        raw.reserveCapacity((width + 1) * height)
        for _ in 0..<height { raw += [0] + [UInt8](repeating: shade, count: width) }
        var z: [UInt8] = [0x78, 0x01]
        var at = 0
        repeat {
            let n = min(65_535, raw.count - at)
            let final: UInt8 = at + n >= raw.count ? 1 : 0
            z += [final, UInt8(n & 0xFF), UInt8(n >> 8), UInt8(~n & 0xFF), UInt8(~n >> 8 & 0xFF)] + raw[at..<at + n]
            at += n
        } while at < raw.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in raw {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        z += bigEndian(b << 16 | a)
        var ihdr = bigEndian(UInt32(width)) + bigEndian(UInt32(height))
        ihdr += [8, 0, 0, 0, 0] // 8 bits, grey
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", ihdr) + chunk("IDAT", z) + chunk("IEND", [])
        return png
    }

    private static func chunk(_ type: String, _ data: [UInt8]) -> [UInt8] {
        let body = Array(type.utf8) + data
        return bigEndian(UInt32(data.count)) + body + bigEndian(Crc32.of(body))
    }

    private static func bigEndian(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }

    /// A grey, uncompressed little-endian TIFF of `pages` pages.
    public static func tiff(_ pages: Int, _ width: Int, _ height: Int, shade: UInt8 = 128) -> [UInt8] {
        let tags = 8, ifdSize = 2 + tags * 12 + 4
        let pixels = width * height
        var bytes = [UInt8](repeating: 0, count: 8 + pages * (ifdSize + pixels))
        func put16(_ at: Int, _ v: Int) {
            bytes[at] = UInt8(v & 0xFF)
            bytes[at + 1] = UInt8(v >> 8 & 0xFF)
        }
        func put32(_ at: Int, _ v: Int) {
            for k in 0..<4 { bytes[at + k] = UInt8(v >> (8 * k) & 0xFF) }
        }
        bytes.replaceSubrange(0..<4, with: [0x49, 0x49, 0x2A, 0x00])
        put32(4, 8)
        var at = 8
        for p in 0..<pages {
            let data = at + ifdSize
            let next = p + 1 < pages ? data + pixels : 0
            put16(at, tags)
            let entries: [(tag: Int, type: Int, value: Int)] = [(256, 4, width), (257, 4, height), (258, 3, 8), (259, 3, 1), (262, 3, 1), (273, 4, data),
                                                                 (278, 4, height), (279, 4, pixels)]
            for (t, e) in entries.enumerated() {
                let entry = at + 2 + t * 12
                put16(entry, e.tag)
                put16(entry + 2, e.type)
                put32(entry + 4, 1)
                put32(entry + 8, e.value)
            }
            put32(at + 2 + tags * 12, next)
            for k in data..<data + pixels { bytes[k] = shade }
            at = data + pixels
        }
        return bytes
    }
}
