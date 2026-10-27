import Foundation

/// Minimal PNG writer for rendered pixels: 8-bit RGB or RGBA (straight alpha), no filtering (the Windows `PngEncoder`;
/// zlib through `Deflate`).
enum PngEncoder {
    /// - Parameter pixels: rows of `width` pixels, 3 (RGB) or 4 (RGBA) bytes each, tightly packed.
    static func encode(_ width: Int, _ height: Int, _ pixels: [UInt8], alpha: Bool) -> [UInt8] {
        let channels = alpha ? 4 : 3
        precondition(pixels.count >= width * height * channels, "Too few pixels for the size.")
        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let ihdr = be32(UInt32(width)) + be32(UInt32(height)) + [8, alpha ? 6 : 2, 0, 0, 0] // 8 bits, RGBA or RGB
        chunk(&png, "IHDR", ihdr)
        let stride = width * channels
        var raw = [UInt8]()
        raw.reserveCapacity((stride + 1) * height)
        for y in 0..<height {
            raw.append(0) // no filter
            raw += pixels[y * stride..<(y + 1) * stride]
        }
        chunk(&png, "IDAT", Deflate.zlib(raw))
        chunk(&png, "IEND", [])
        return png
    }

    private static func chunk(_ png: inout [UInt8], _ type: String, _ data: [UInt8]) {
        let head = Array(type.utf8)
        png += be32(UInt32(data.count)) + head + data
        png += be32(Crc32.update(Crc32.update(0xFFFF_FFFF, head), data) ^ 0xFFFF_FFFF)
    }

    private static func be32(_ v: UInt32) -> [UInt8] { [UInt8(v >> 24), UInt8((v >> 16) & 255), UInt8((v >> 8) & 255), UInt8(v & 255)] }
}
