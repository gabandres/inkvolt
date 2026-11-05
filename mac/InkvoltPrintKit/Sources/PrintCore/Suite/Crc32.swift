/// CRC-32 (ZIP's and PNG's): the suite's one, for `ZipArchive` here and Inkvolt PDF's Office and PNG writers (PdfCore).
public enum Crc32 {
    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    /// `crc` carried over `data`, unfinished: start from 0xFFFFFFFF and XOR the end with it (PNG's chunks span two pieces).
    public static func update(_ crc: UInt32, _ data: some Sequence<UInt8>) -> UInt32 {
        var c = crc
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c
    }

    public static func of(_ data: [UInt8]) -> UInt32 { update(0xFFFF_FFFF, data) ^ 0xFFFF_FFFF }
}
