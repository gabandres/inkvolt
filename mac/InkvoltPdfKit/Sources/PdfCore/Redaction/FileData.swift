import Compression
import Foundation

/// zlib streams (RFC 1950) inflated through the Compression framework (.NET's `ZLibStream`), for reading a file's raw
/// streams and attached files.
enum Inflate {
    /// The data of a zlib stream (its two-byte header checked, its deflate data inflated), at most `limit` bytes; nil
    /// when it isn't one.
    static func zlib(_ data: ArraySlice<UInt8>, limit: Int) -> [UInt8]? {
        guard data.count >= 3 else { return nil }
        let cmf = data[data.startIndex], flg = data[data.startIndex + 1]
        // Deflate (8), a window of at most 32 KB, no preset dictionary, and the header's check bits.
        guard cmf & 0x0F == 8, cmf >> 4 <= 7, flg & 0x20 == 0, (Int(cmf) << 8 | Int(flg)) % 31 == 0 else { return nil }
        return raw(data.dropFirst(2), limit: limit)
    }

    /// Raw DEFLATE (RFC 1951) inflated, at most `limit` bytes; nil when nothing could be read.
    static func raw(_ data: ArraySlice<UInt8>, limit: Int) -> [UInt8]? {
        if data.isEmpty { return nil }
        var stream = compression_stream(dst_ptr: UnsafeMutablePointer<UInt8>(bitPattern: 1)!, dst_size: 0,
                                        src_ptr: UnsafePointer<UInt8>(bitPattern: 1)!, src_size: 0, state: nil)
        guard compression_stream_init(&stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else { return nil }
        defer { compression_stream_destroy(&stream) }
        let chunk = 64 << 10
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: chunk)
        var failed = false
        Array(data).withUnsafeBufferPointer { src in
            stream.src_ptr = src.baseAddress!
            stream.src_size = src.count
            buffer.withUnsafeMutableBufferPointer { dst in
                while out.count < limit {
                    stream.dst_ptr = dst.baseAddress!
                    stream.dst_size = chunk
                    let status = compression_stream_process(&stream, Int32(COMPRESSION_STREAM_FINALIZE.rawValue))
                    let produced = chunk - stream.dst_size
                    out.append(contentsOf: UnsafeBufferPointer(start: dst.baseAddress!, count: produced))
                    if status == COMPRESSION_STATUS_END { break }
                    if status == COMPRESSION_STATUS_ERROR {
                        failed = true
                        break
                    }
                    if produced == 0 && stream.src_size == 0 { break }
                }
            }
        }
        if failed && out.isEmpty { return nil }
        return out.count > limit ? Array(out.prefix(limit)) : out
    }
}

/// The entries of a ZIP file (an Office document attached to a PDF), stored or deflated (.NET's `ZipArchive`, read only).
enum ZipReader {
    /// Each entry's name and data, from the central directory; at most `count` entries and `limit` bytes in all. Nil when
    /// the data isn't a ZIP file.
    static func entries(_ zip: [UInt8], count: Int = 2000, limit: Int) -> [(name: String, data: [UInt8])]? {
        func u16(_ i: Int) -> Int { i + 2 <= zip.count ? Int(zip[i]) | Int(zip[i + 1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 4 <= zip.count ? u16(i) | u16(i + 2) << 16 : 0 }
        // The end of central directory record: its signature within the last 64 KB (a comment may follow it).
        var eocd = -1
        var i = zip.count - 22
        while i >= max(0, zip.count - 22 - 65_535) {
            if zip[i] == 0x50 && zip[i + 1] == 0x4B && zip[i + 2] == 5 && zip[i + 3] == 6 {
                eocd = i
                break
            }
            i -= 1
        }
        guard eocd >= 0 else { return nil }
        let total = u16(eocd + 10)
        var at = u32(eocd + 16)
        var out: [(String, [UInt8])] = []
        var bytes = 0
        for _ in 0..<min(total, count) {
            guard at + 46 <= zip.count, u32(at) == 0x0201_4B50 else { break }
            let method = u16(at + 10), packed = u32(at + 20), size = u32(at + 24)
            let nameLength = u16(at + 28), extra = u16(at + 30), comment = u16(at + 32), local = u32(at + 42)
            let name = String(decoding: zip[min(at + 46, zip.count)..<min(at + 46 + nameLength, zip.count)], as: UTF8.self)
            at += 46 + nameLength + extra + comment
            guard local + 30 <= zip.count, u32(local) == 0x0403_4B50 else { continue }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start <= zip.count, size <= limit, bytes + size <= limit else { break }
            let body = zip[start..<min(start + packed, zip.count)]
            let data: [UInt8]?
            switch method {
            case 0: data = Array(body)
            case 8: data = Inflate.raw(body, limit: size + 1)
            default: data = nil
            }
            guard let data else { continue }
            bytes += data.count
            out.append((name, data))
        }
        return out
    }
}

extension MuDoc {
    /// Every object of the file (.NET's `GetAllObjects`): a reference to each object number in use.
    func allObjects() -> [PObj] {
        (1..<max(objectCount, 1)).compactMap { n in
            let o = object(n)
            return o.kind == .null ? nil : o
        }
    }

    /// The object numbers reachable from `roots` by following references through dictionaries and arrays (.NET's
    /// `GetClosure`), with a reference to each, in the order they were reached.
    func closure(_ roots: [PObj?]) -> [PObj] {
        var seen = Set<Int>()
        var out: [PObj] = []
        var stack: [(PObj, Int)] = []
        for r in roots.compactMap({ $0 }) {
            if r.isRef {
                if seen.insert(r.num).inserted { out.append(r) }
            }
            stack.append((r, 0))
        }
        var direct = Set<UInt>()
        while let (o, depth) = stack.popLast() {
            if depth > 512 { continue }
            let children: [PObj]
            if o.isDict {
                children = o.keys.compactMap { o[$0] }
            } else if o.isArray {
                children = o.elements
            } else {
                continue
            }
            for c in children {
                if c.isRef {
                    if seen.insert(c.num).inserted {
                        out.append(c)
                        stack.append((c, depth + 1))
                    }
                } else if c.isDict || c.isArray, direct.insert(c.identity).inserted {
                    stack.append((c, depth + 1))
                }
            }
        }
        return out
    }

    /// The trailer's /Info, when there is one.
    var info: PObj? { trailer.dict("Info") }
}

/// A run of a regular expression that stops after a time (.NET's `Regex` match timeout): NSRegularExpression has no
/// timeout, but with `reportProgress` it calls back while a long match runs, and the callback can stop it.
enum TimedRegex {
    struct Timeout: Error {}

    /// Every match in `text`, or `Timeout` when the search took longer than `seconds`.
    static func matches(_ regex: NSRegularExpression, in text: NSString, seconds: Double) throws -> [NSTextCheckingResult] {
        let deadline = Date().addingTimeInterval(seconds)
        var out: [NSTextCheckingResult] = []
        var late = false
        regex.enumerateMatches(in: text as String, options: [.reportProgress], range: NSRange(location: 0, length: text.length)) { m, _, stop in
            if let m { out.append(m) }
            if Date() > deadline {
                late = true
                stop.pointee = true
            }
        }
        if late { throw Timeout() }
        return out
    }
}
