import Foundation

/// A ZIP archive of a few small files, stored as they are (Report a Problem's recording, roadmap 1.2), and read back.
/// Foundation only, so it builds and tests on the Windows PC too. Mac difference: Windows' `ZipFile.CreateFromDirectory`
/// deflates; a recording is a few hundred kilobytes of text, so storing costs little and needs no compression library
/// here. `Writer` is the suite's one ZIP writer: Inkvolt PDF's Office files go through it too (PdfCore's `ZipWriter`
/// deflates through Apple's Compression framework, which PrintCore can't use, and hands it the deflated bytes). No
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

    /// An archive this can't write, or isn't one this reads: cut, changed, or another kind of file.
    public struct Damaged: Error, CustomStringConvertible {
        public let description: String
    }

    /// The archive: each entry stored (method 0), as `Writer` writes it.
    public static func stored(_ entries: [Entry], modified: Date, calendar: Calendar = Calendar(identifier: .gregorian)) throws -> [UInt8] {
        var out: [UInt8] = []
        let writer = Writer(modified: modified, calendar: calendar) { out += $0 }
        for e in entries { try writer.add(e.name, e.bytes) }
        try writer.finish()
        return out
    }

    /// An archive written as its entries arrive, to `write`: each entry stored, or deflated (method 8) when it's given its
    /// raw DEFLATE bytes, with its CRC-32 and UTF-8 name, dated `modified` (local time, as ZIP's DOS dates are); then the
    /// central directory (`finish`). The suite's one ZIP writer: `stored` here, Inkvolt PDF's Office files (PdfCore's
    /// `ZipWriter`, which deflates).
    public final class Writer {
        private let write: ([UInt8]) throws -> Void
        private let time: UInt16
        private let date: UInt16
        private var offset = 0
        private var central: [UInt8] = []
        private var count = 0

        public init(modified: Date, calendar: Calendar = Calendar(identifier: .gregorian), write: @escaping ([UInt8]) throws -> Void) {
            let dos = ZipArchive.dosTime(modified, calendar)
            time = dos.time
            date = dos.date
            self.write = write
        }

        /// Adds an entry: `data` as it is, or `deflated` (its raw DEFLATE bytes) in its place.
        public func add(_ name: String, _ data: [UInt8], deflated: [UInt8]? = nil) throws {
            let body = deflated ?? data
            let nameBytes = Array(name.utf8)
            guard count < 0xFFFF else { throw Damaged(description: "Too many files for a ZIP archive.") }
            guard nameBytes.count <= 0xFFFF, data.count < Int(UInt32.max), offset + 30 + nameBytes.count + body.count < Int(UInt32.max) else {
                throw Damaged(description: "The file would be larger than 4 GB.")
            }
            let method: UInt16 = deflated == nil ? 0 : 8
            let crc = Crc32.of(data)
            let packed = UInt32(body.count), size = UInt32(data.count) // bounded: checked against UInt32.max just above
            let at = UInt32(offset) // bounded: as the sizes
            let nameLength = UInt16(nameBytes.count) // bounded: checked against 0xFFFF above
            var local = le32(0x0403_4B50) + le16(20) + le16(0x0800) + le16(method) + le16(time) + le16(date)
            local += le32(crc) + le32(packed) + le32(size) + le16(nameLength) + le16(0)
            local += nameBytes
            central += le32(0x0201_4B50) + le16(20) + le16(20) + le16(0x0800) + le16(method) + le16(time) + le16(date)
            central += le32(crc) + le32(packed) + le32(size) + le16(nameLength)
            central += le16(0) + le16(0) + le16(0) + le16(0) + le32(0) + le32(at)
            central += nameBytes
            try write(local)
            try write(body)
            offset += local.count + body.count
            count += 1
        }

        /// Writes the central directory: the archive is complete.
        public func finish() throws {
            guard offset + central.count + 22 < Int(UInt32.max) else { throw Damaged(description: "The file would be larger than 4 GB.") }
            let entries = UInt16(count) // bounded: add refuses the 65,536th
            let start = UInt32(offset), size = UInt32(central.count) // bounded: just checked
            try write(central + le32(0x0605_4B50) + le16(0) + le16(0) + le16(entries) + le16(entries) + le32(size) + le32(start) + le16(0))
        }
    }

    /// Every entry of an archive of stored entries, in its central directory's order, each checked against its CRC-32.
    public static func entries(_ zip: [UInt8]) throws -> [Entry] {
        guard zip.count >= 22 else { throw Damaged(description: "Not a ZIP archive.") }
        // The end record: the last 22 bytes when there's no comment (this writes none), else searched back from the end, no
        // further than its comment's longest (65,535 bytes) can push it.
        let lowest = max(0, zip.count - 22 - 0xFFFF)
        var end = zip.count - 22
        while end >= lowest && u32(zip, end) != 0x0605_4B50 { end -= 1 }
        guard end >= lowest else { throw Damaged(description: "Not a ZIP archive.") }
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
            guard Crc32.of(bytes) == crc else { throw Damaged(description: "\(name) doesn't match its checksum.") }
            entries.append(Entry(name: name, bytes: bytes))
            at += 46 + nameLength + extra + comment
        }
        return entries
    }

    // MARK: Pieces

    fileprivate static func dosTime(_ when: Date, _ calendar: Calendar) -> (time: UInt16, date: UInt16) {
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: when)
        let year = min(max((c.year ?? 1980) - 1980, 0), 127)
        let month = c.month ?? 1, day = c.day ?? 1
        let hour = c.hour ?? 0, minute = c.minute ?? 0, second = c.second ?? 0
        let time = (hour << 11) | (minute << 5) | (second / 2)
        let date = (year << 9) | (month << 5) | day
        return (UInt16(truncatingIfNeeded: time), UInt16(truncatingIfNeeded: date))
    }

    private static func u16(_ b: [UInt8], _ i: Int) -> UInt16 { i >= 0 && i + 2 <= b.count ? UInt16(b[i]) | UInt16(b[i + 1]) << 8 : 0 }

    private static func u32(_ b: [UInt8], _ i: Int) -> UInt32 {
        guard i >= 0, i + 4 <= b.count else { return 0 }
        return UInt32(b[i]) | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2]) << 16 | UInt32(b[i + 3]) << 24
    }
}

private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8(v >> 8)] }

private func le32(_ v: UInt32) -> [UInt8] {
    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8(v >> 24)]
}
