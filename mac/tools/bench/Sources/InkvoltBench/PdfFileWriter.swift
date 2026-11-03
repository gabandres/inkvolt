import Compression
import Foundation

/// Writes a PDF one object at a time to a file (a gigabyte file never sits in memory), with a classic cross-reference
/// table: Windows' `PdfFileWriter`. Objects can be reserved ahead and written in any order; nothing in the output depends
/// on the clock or the machine.
final class PdfFileWriter {
    private static let header: [UInt8] = [0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x37, 0x0A, 0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A]
    private let handle: FileHandle
    private var buffer: [UInt8] = []
    private var offsets: [Int] = [-1] // by object number; 0 is the free-list head
    private var pos = 0

    init(path: String) throws {
        FileManager.default.createFile(atPath: path, contents: nil)
        guard let h = FileHandle(forWritingAtPath: path) else { throw BenchError("Can't write \(path)") }
        handle = h
        buffer.reserveCapacity(1 << 20)
        write(Self.header)
    }

    /// Takes the next object number without writing the object yet (see `put`).
    func reserve() -> Int {
        offsets.append(-1)
        return offsets.count - 1
    }

    @discardableResult
    func add(_ body: String) -> Int {
        let id = reserve()
        put(id, body)
        return id
    }

    func put(_ id: Int, _ body: String) {
        offsets[id] = pos
        write("\(id) 0 obj\n\(body)\nendobj\n")
    }

    /// A stream object; `entries` are the dictionary's other entries. `compress` deflates it (zlib, as /FlateDecode reads).
    func addStream(_ entries: String, _ data: [UInt8], compress: Bool = true) -> Int {
        let id = reserve()
        putStream(id, entries, data, compress: compress)
        return id
    }

    func putStream(_ id: Int, _ entries: String, _ data: [UInt8], compress: Bool = true) {
        if compress {
            putStream(id, entries + " /Filter /FlateDecode", Self.deflate(data), compress: false)
            return
        }
        offsets[id] = pos
        write("\(id) 0 obj\n<< \(entries) /Length \(data.count) >>\nstream\n")
        write(data)
        write("\nendstream\nendobj\n")
    }

    func finish(root: Int, info: Int, fileId: String) throws {
        let xref = pos
        var s = "xref\n0 \(offsets.count)\n0000000000 65535 f \n"
        for i in 1..<offsets.count {
            guard offsets[i] >= 0 else { throw BenchError("Object \(i) was reserved but never written.") }
            s += String(format: "%010d 00000 n \n", offsets[i])
        }
        s += "trailer\n<< /Size \(offsets.count) /Root \(root) 0 R /Info \(info) 0 R /ID [<\(fileId)> <\(fileId)>] >>\nstartxref\n\(xref)\n%%EOF\n"
        write(s)
        flush()
        try handle.close()
    }

    /// zlib (RFC 1950) around the Compression framework's raw deflate: a header, the deflate stream, Adler-32.
    static func deflate(_ data: [UInt8]) -> [UInt8] {
        let capacity = data.count + data.count / 10 + 1024
        var raw = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBufferPointer { src in
            raw.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, capacity, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        precondition(n > 0 || data.isEmpty, "deflate failed")
        var a: UInt32 = 1, b: UInt32 = 0
        var i = 0
        while i < data.count {
            let end = min(i + 5552, data.count)
            while i < end {
                a += UInt32(data[i])
                b += a
                i += 1
            }
            a %= 65521
            b %= 65521
        }
        let adler = b << 16 | a
        return [0x78, 0x9C] + raw[0..<n] + [UInt8(adler >> 24), UInt8((adler >> 16) & 255), UInt8((adler >> 8) & 255), UInt8(adler & 255)]
    }

    /// A PDF literal string: letters, digits and punctuation only (what the corpus uses), escaped where needed.
    static func str(_ s: String) -> String {
        "(" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "(", with: "\\(").replacingOccurrences(of: ")", with: "\\)") + ")"
    }

    private func write(_ s: String) { write(Array(s.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) })) }

    private func write(_ bytes: [UInt8]) {
        buffer += bytes
        pos += bytes.count
        if buffer.count >= 1 << 20 { flush() }
    }

    private func flush() {
        handle.write(Data(buffer))
        buffer.removeAll(keepingCapacity: true)
    }
}

/// A page tree in groups of 64 kids under one root (Windows' `PageTree`).
final class PageTree {
    static let groupSize = 64
    private let w: PdfFileWriter
    private var groups: [Int] = []
    private var pages: [Int] = []
    let rootId: Int

    init(_ w: PdfFileWriter, pageCount: Int) {
        self.w = w
        rootId = w.reserve()
        for _ in 0..<((pageCount + Self.groupSize - 1) / Self.groupSize) { groups.append(w.reserve()) }
    }

    func parentOf(_ pageIndex: Int) -> Int { groups[pageIndex / Self.groupSize] }

    func add(_ pageId: Int) { pages.append(pageId) }

    func write() {
        for g in 0..<groups.count {
            let kids = pages.dropFirst(g * Self.groupSize).prefix(Self.groupSize)
            w.put(groups[g], "<< /Type /Pages /Parent \(rootId) 0 R /Count \(kids.count) /Kids [\(kids.map { "\($0) 0 R" }.joined(separator: " "))] >>")
        }
        w.put(rootId, "<< /Type /Pages /Count \(pages.count) /Kids [\(groups.map { "\($0) 0 R" }.joined(separator: " "))] >>")
    }
}

struct BenchError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
