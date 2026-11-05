import Foundation

/// A ZIP archive of a few small files, stored as they are (Report a Problem's recording, roadmap 1.2), and read back.
/// Foundation only, so it builds and tests on the Windows PC too. Mac difference: Windows' `ZipFile.CreateFromDirectory`
/// deflates; a recording is a few hundred kilobytes of text, so storing costs little and needs no compression library
/// here (Inkvolt PDF's Office writers deflate through Apple's Compression framework, which PrintCore can't use). No
/// ZIP64: an archive over 4 GB or 65,535 entries is refused.
public enum ZipArchive {
    public struct Entry: Equatable, Sendable {
        public var name: String
        public var bytes: [UInt8]

        public init(name: String, bytes: [UInt8]) {
            self.name = name
            self.bytes = bytes
        }
    }

    /// An archive that isn't one this writes: cut, changed, or another kind of file.
    public struct Damaged: Error, CustomStringConvertible {
        public let description: String
    }

    /// The archive: each entry stored (method 0) with its CRC-32 and UTF-8 name, dated `modified` (local time, as ZIP's
    /// DOS dates are), then the central directory.
    public static func stored(_ entries: [Entry], modified: Date, calendar: Calendar = Calendar(identifier: .gregorian)) throws -> [UInt8] {
        let (time, date) = dosTime(modified, calendar)
        var out: [UInt8] = []
        var central: [UInt8] = []
        guard entries.count <= 0xFFFF else { throw Damaged(description: "Too many files for a ZIP archive.") }
        for e in entries {
            let name = Array(e.name.utf8)
            guard name.count <= 0xFFFF, out.count + 30 + name.count + e.bytes.count < Int(UInt32.max) else {
                throw Damaged(description: "The archive would be larger than 4 GB.")
            }
            let offset = UInt32(out.count) // bounded: checked against UInt32.max just above
            let crc = crc32(e.bytes)
            let size = UInt32(e.bytes.count) // bounded: as the offset
            let nameLength = UInt16(name.count) // bounded: checked against 0xFFFF above
            out += le32(0x0403_4B50) + le16(20) + le16(0x0800) + le16(0) + le16(time) + le16(date)
            out += le32(crc) + le32(size) + le32(size) + le16(nameLength) + le16(0)
            out += name
            out += e.bytes
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0x0800) + le16(0) + le16(time) + le16(date)
            central += le32(crc) + le32(size) + le32(size) + le16(nameLength)
            central += le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(offset)
            central += name
        }
        guard out.count + central.count + 22 < Int(UInt32.max) else { throw Damaged(description: "The archive would be larger than 4 GB.") }
        let count = UInt16(entries.count) // bounded: checked against 0xFFFF above
        let centralStart = UInt32(out.count), centralSize = UInt32(central.count) // bounded: just checked
        out += central
        out += le32(0x0605_4B50) + le16(0) + le16(0) + le16(count) + le16(count) + le32(centralSize) + le32(centralStart) + le16(0)
        return out
    }

    /// Every entry of an archive of stored entries, in its central directory's order, each checked against its CRC-32.
    public static func entries(_ zip: [UInt8]) throws -> [Entry] {
        guard zip.count >= 22 else { throw Damaged(description: "Not a ZIP archive.") }
        // The end record: the last 22 bytes when there's no comment (this writes none), else searched back from the end.
        var end = zip.count - 22
        while end >= 0 && u32(zip, end) != 0x0605_4B50 { end -= 1 }
        guard end >= 0, zip.count - end >= 22 else { throw Damaged(description: "Not a ZIP archive.") }
        let count = Int(u16(zip, end + 10))
        let centralSize = Int(u32(zip, end + 12)), centralStart = Int(u32(zip, end + 16))
        guard centralStart + centralSize <= end else { throw Damaged(description: "The archive is cut short.") }
        var entries: [Entry] = []
        var at = centralStart
        for _ in 0..<count {
            guard at + 46 <= end, u32(zip, at) == 0x0201_4B50 else { throw Damaged(description: "The archive's directory is damaged.") }
            let method = u16(zip, at + 10)
            let crc = u32(zip, at + 16)
            let packed = Int(u32(zip, at + 20)), size = Int(u32(zip, at + 24))
            let nameLength = Int(u16(zip, at + 28)), extra = Int(u16(zip, at + 30)), comment = Int(u16(zip, at + 32))
            let local = Int(u32(zip, at + 42))
            guard at + 46 + nameLength <= end else { throw Damaged(description: "The archive's directory is damaged.") }
            let name = String(decoding: zip[(at + 46)..<(at + 46 + nameLength)], as: UTF8.self)
            guard method == 0, packed == size else { throw Damaged(description: "\(name) is compressed; only stored entries are read.") }
            guard local + 30 <= centralStart, u32(zip, local) == 0x0403_4B50 else { throw Damaged(description: "\(name) isn't where the directory says.") }
            let data = local + 30 + Int(u16(zip, local + 26)) + Int(u16(zip, local + 28))
            guard data + size <= centralStart else { throw Damaged(description: "\(name) is cut short.") }
            let bytes = Array(zip[data..<(data + size)])
            guard crc32(bytes) == crc else { throw Damaged(description: "\(name) doesn't match its checksum.") }
            entries.append(Entry(name: name, bytes: bytes))
            at += 46 + nameLength + extra + comment
        }
        return entries
    }

    // MARK: Pieces

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: [UInt8]) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }

    private static func dosTime(_ when: Date, _ calendar: Calendar) -> (time: UInt16, date: UInt16) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let month = c.month ?? 1, day = c.day ?? 1
        let hour = c.hour ?? 0, minute = c.minute ?? 0, second = c.second ?? 0
        let time = (hour << 11) | (minute << 5) | (second / 2)
        let date = (year << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: date))
    }

    private static func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

    private static func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { i >= 0 && i + 2 <= b.count ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : 0 }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}
