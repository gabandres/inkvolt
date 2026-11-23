import Foundation

/// The kinds of photo a capture source may hand in.
public enum PhotoKind: Sendable { case jpeg, png }

/// What a photo's header says, read before anything is decoded (the Windows Core's `PhotoHeader`): its kind, its size in
/// pixels and (JPEG) the EXIF orientation a camera wrote (1 to 8; 1 when there is none).
public struct PhotoHeader: Equatable, Sendable {
    public var kind: PhotoKind
    public var width: Int
    public var height: Int
    public var orientation: Int

    public init(_ kind: PhotoKind, _ width: Int, _ height: Int, _ orientation: Int = 1) {
        self.kind = kind
        self.width = width
        self.height = height
        self.orientation = orientation
    }

    /// Its size once turned the way the EXIF orientation says (5 to 8 swap width and height).
    public var upright: (width: Int, height: Int) { (5...8).contains(orientation) ? (height, width) : (width, height) }
}

/// A photo from a capture source (a phone over the network, a camera) checked as hostile input before it is decoded
/// (roadmap 4.6, 4.12; the Windows Core's `PhotoInput`, named apart from Print Photos' `PhotoInput`): only JPEG or PNG by their first bytes (whatever a request's content
/// type says), at most `maxBytes`, at least `minSide` and at most `maxSide` pixels a side and `maxPixels` in all, so a small
/// file that would decode to gigabytes is refused unread. Every read is bounded by the bytes there are.
public enum CapturedPhotoInput {
    /// The largest photo taken (bytes): a 50-megapixel phone photo at its finest JPEG is about 25 MB.
    public static let maxBytes = 32 * 1024 * 1024
    /// The longest side taken (pixels).
    public static let maxSide = 12_000
    /// The most pixels taken (a 50-megapixel camera's full size).
    public static let maxPixels = 52_000_000
    /// The shortest side taken: anything smaller holds no readable page.
    public static let minSide = 200

    /// The header of a JPEG or PNG within the limits, or nil (not a photo, or too large or small).
    public static func inspect(_ data: [UInt8]) -> PhotoHeader? {
        data.withUnsafeBufferPointer { inspect($0) }
    }

    public static func inspect(_ data: UnsafeBufferPointer<UInt8>) -> PhotoHeader? {
        guard (24...maxBytes).contains(data.count) else { return nil }
        guard let header = data[0] == 0xFF && data[1] == 0xD8 ? jpeg(data) : png(data) else { return nil }
        let (w, h) = (header.width, header.height)
        return w < minSide || h < minSide || w > maxSide || h > maxSide || w * h > maxPixels ? nil : header
    }

    private static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    private static func u16(_ d: UnsafeBufferPointer<UInt8>, _ at: Int, little: Bool = false) -> Int {
        little ? Int(d[at]) | Int(d[at + 1]) << 8 : Int(d[at]) << 8 | Int(d[at + 1])
    }

    private static func u32(_ d: UnsafeBufferPointer<UInt8>, _ at: Int, little: Bool = false) -> UInt32 {
        let b = (UInt32(d[at]), UInt32(d[at + 1]), UInt32(d[at + 2]), UInt32(d[at + 3]))
        return little ? b.0 | b.1 << 8 | b.2 << 16 | b.3 << 24 : b.0 << 24 | b.1 << 16 | b.2 << 8 | b.3
    }

    private static func png(_ d: UnsafeBufferPointer<UInt8>) -> PhotoHeader? {
        // The signature, then IHDR first: its length (13), its type, width and height (big-endian).
        guard Array(d[0..<8]) == pngSignature, u32(d, 8) == 13, Array(d[12..<16]) == Array("IHDR".utf8) else { return nil }
        let (w, h) = (u32(d, 16), u32(d, 20))
        return w > UInt32(maxSide) || h > UInt32(maxSide) ? nil : PhotoHeader(.png, Int(w), Int(h))
    }

    /// The markers up to the first frame header (SOF): its size, and the orientation from an EXIF block before it.
    private static func jpeg(_ d: UnsafeBufferPointer<UInt8>) -> PhotoHeader? {
        var orientation = 1
        var at = 2
        while at + 4 <= d.count {
            if d[at] != 0xFF { return nil }
            let marker = d[at + 1]
            if marker == 0xFF { at += 1; continue } // fill byte
            if marker == 0x01 || (0xD0...0xD7).contains(marker) { at += 2; continue } // no length
            if marker == 0xD8 || marker == 0xD9 || marker == 0xDA { return nil } // a second start, the end or the scan before any frame header
            let length = u16(d, at + 2)
            if length < 2 || at + 2 + length > d.count { return nil }
            let start = at + 4, count = length - 2
            let isFrame = (0xC0...0xC3).contains(marker) || (0xC5...0xC7).contains(marker) || (0xC9...0xCB).contains(marker)
                || (0xCD...0xCF).contains(marker)
            if isFrame {
                if count < 6 { return nil }
                return PhotoHeader(.jpeg, u16(d, start + 3), u16(d, start + 1), orientation)
            }
            if marker == 0xE1 && count > 14 && Array(d[start..<(start + 6)]) == [0x45, 0x78, 0x69, 0x66, 0, 0] {
                orientation = exifOrientation(UnsafeBufferPointer(rebasing: d[(start + 6)..<(start + count)]))
            }
            at += 2 + length
        }
        return nil
    }

    /// Tag 0x0112 of a TIFF block's first directory (1 to 8), or 1 when it isn't there or doesn't read.
    static func exifOrientation(_ tiff: UnsafeBufferPointer<UInt8>) -> Int {
        if tiff.count < 8 { return 1 }
        let little: Bool
        if tiff[0] == 0x49 && tiff[1] == 0x49 { little = true } else if tiff[0] == 0x4D && tiff[1] == 0x4D { little = false } else { return 1 }
        if u16(tiff, 2, little: little) != 42 { return 1 }
        let ifd = Int(u32(tiff, 4, little: little))
        if ifd < 8 || ifd > tiff.count - 2 { return 1 }
        let count = u16(tiff, ifd, little: little)
        for i in 0..<count {
            let entry = ifd + 2 + i * 12
            if entry + 12 > tiff.count { return 1 }
            if u16(tiff, entry, little: little) != 0x0112 { continue }
            // SHORT (3), one value, held in the entry itself.
            if u16(tiff, entry + 2, little: little) != 3 || u32(tiff, entry + 4, little: little) != 1 { return 1 }
            let value = u16(tiff, entry + 8, little: little)
            return (1...8).contains(value) ? value : 1
        }
        return 1
    }
}
