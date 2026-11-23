import Compression
import Foundation
import PrintCore

/// Where an export's bytes go: a file being written, or memory.
public protocol ByteSink: AnyObject {
    func write(_ bytes: [UInt8]) throws
}

/// Bytes kept in memory.
public final class MemorySink: ByteSink {
    public private(set) var bytes: [UInt8] = []
    public init() {}
    public func write(_ bytes: [UInt8]) throws { self.bytes += bytes }
}

/// Bytes written to an open file.
final class FileSink: ByteSink {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
    func write(_ bytes: [UInt8]) throws { try handle.write(contentsOf: bytes) }
}

/// Raw DEFLATE (RFC 1951) through the Compression framework, for ZIP entries and PNG's zlib stream.
enum Deflate {
    /// The data deflated; nil when it doesn't get smaller (or can't be compressed).
    static func compress(_ data: [UInt8]) -> [UInt8]? {
        if data.isEmpty { return nil }
        let capacity = data.count + data.count / 8 + 1024
        var out = [UInt8](repeating: 0, count: capacity)
        let n = data.withUnsafeBufferPointer { src in
            out.withUnsafeMutableBufferPointer { dst in
                compression_encode_buffer(dst.baseAddress!, capacity, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
            }
        }
        if n == 0 || n >= data.count { return nil }
        return Array(out.prefix(n))
    }

    /// A zlib stream (RFC 1950) of the data: deflated, or in stored blocks when that doesn't help.
    static func zlib(_ data: [UInt8]) -> [UInt8] {
        var out: [UInt8] = [0x78, 0x01]
        if let deflated = compress(data) {
            out += deflated
        } else {
            var at = 0
            repeat {
                let n = min(65535, data.count - at)
                let final: UInt8 = at + n == data.count ? 1 : 0
                out += [final, UInt8(n & 255), UInt8(n >> 8), UInt8(~n & 255), UInt8((~n >> 8) & 255)]
                out += data[at..<at + n]
                at += n
            } while at < data.count
        }
        var a: UInt32 = 1, b: UInt32 = 0
        var k = 0
        while k < data.count {
            // Sums stay below 2^32 for 5552 bytes between reductions (zlib's NMAX).
            let end = min(data.count, k + 5552)
            for i in k..<end {
                a += UInt32(data[i])
                b += a
            }
            a %= 65521
            b %= 65521
            k = end
        }
        let adler = b << 16 | a
        out += [UInt8(adler >> 24), UInt8((adler >> 16) & 255), UInt8((adler >> 8) & 255), UInt8(adler & 255)]
        return out
    }
}

/// A ZIP archive written as entries arrive (what .NET's `ZipArchive` in Create mode does for the Windows writers): the
/// suite's one ZIP writer (PrintCore's `ZipArchive.Writer`), each entry deflated here when that makes it smaller.
/// ZIP64 isn't written: an archive over 4 GB fails.
final class ZipWriter {
    private let writer: ZipArchive.Writer

    init(_ sink: ByteSink) { writer = ZipArchive.Writer(modified: Date()) { try sink.write($0) } }

    /// Adds an entry; `compress` deflates it when that makes it smaller.
    func add(_ name: String, _ data: [UInt8], compress: Bool) throws {
        do {
            try writer.add(name, data, deflated: compress ? Deflate.compress(data) : nil)
        } catch let e as ZipArchive.Damaged {
            throw PdfEngineError(message: e.description)
        }
    }

    /// Writes the central directory: the archive is complete.
    func finish() throws {
        do {
            try writer.finish()
        } catch let e as ZipArchive.Damaged {
            throw PdfEngineError(message: e.description)
        }
    }
}

/// Inkvolt PDF's side of the shared package parts (PrintCore's `OpenXmlParts`, `XmlOut`): entries in its `ZipWriter`, its
/// name in docProps/app.xml, and its units.
extension OpenXmlParts {
    static func entry(_ zip: ZipWriter, _ name: String, _ write: (XmlOut) -> Void) throws {
        try zip.add(name, xml(write), compress: true)
    }

    static func appProperties(_ w: XmlOut) { appProperties(w, application: "Inkvolt PDF") }

    /// Points to twentieths of a point, rounded as .NET's `Math.Round` does.
    static func twips(_ pt: Double) -> String { String(bankersInt(pt * 20)) }

    /// Points to EMUs.
    static func emu(_ pt: Double) -> String { String(bankersInt(pt * 12700)) }
}
