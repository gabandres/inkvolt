import Foundation

/// Reads a PNG into pixels (the Windows app's `PngDecoder`): what `PngEncoder` writes and the common kinds besides it
/// (gray, gray with alpha, RGB, RGBA, palette with or without transparency; 1 to 16 bits a sample, 16 kept as its high
/// byte). Interlaced files aren't read (nil).
enum PngDecoder {
    static func decode(_ png: [UInt8]) -> StampImage? {
        guard png.count > 8, Array(png[0..<8]) == [0x89, 0x50, 0x4E, 0x47, 13, 10, 26, 10] else { return nil }
        var i = 8
        var width = 0, height = 0, depth = 0, colorType = 0, interlace = 0
        var idat: [UInt8] = []
        var palette: [UInt8] = []
        var transparency: [UInt8] = []
        var sawHeader = false
        while i + 8 <= png.count {
            let length = Int(be32(png, i))
            let type = String(decoding: png[(i + 4)..<(i + 8)], as: UTF8.self)
            let start = i + 8
            guard length >= 0, start + length <= png.count else { return nil }
            let data = png[start..<(start + length)]
            switch type {
            case "IHDR":
                guard length == 13 else { return nil }
                width = Int(be32(png, start))
                height = Int(be32(png, start + 4))
                depth = Int(png[start + 8])
                colorType = Int(png[start + 9])
                interlace = Int(png[start + 12])
                sawHeader = true
            case "PLTE": palette = Array(data)
            case "tRNS": transparency = Array(data)
            case "IDAT": idat += data
            case "IEND": i = png.count
            default: break
            }
            i = start + length + 4
        }
        guard sawHeader, width > 0, height > 0, width <= 16384, height <= 16384, interlace == 0, [1, 2, 4, 8, 16].contains(depth) else { return nil }
        let channels: Int
        switch colorType {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: return nil
        }
        if colorType != 0 && colorType != 3 && depth < 8 { return nil }
        guard idat.count > 6, let raw = inflate(Array(idat[2..<(idat.count - 4)])) else { return nil }
        let bitsPerPixel = channels * depth
        let stride = (width * bitsPerPixel + 7) / 8
        guard raw.count >= height * (stride + 1) else { return nil }

        // Unfilter, row by row.
        var rows = [UInt8](repeating: 0, count: height * stride)
        let bpp = max(1, bitsPerPixel / 8)
        var prior = [UInt8](repeating: 0, count: stride)
        for y in 0..<height {
            let filter = raw[y * (stride + 1)]
            let from = y * (stride + 1) + 1
            var line = Array(raw[from..<(from + stride)])
            for x in 0..<stride {
                let a = x >= bpp ? Int(line[x - bpp]) : 0
                let b = Int(prior[x])
                let c = x >= bpp ? Int(prior[x - bpp]) : 0
                switch filter {
                case 1: line[x] = UInt8((Int(line[x]) + a) & 255)
                case 2: line[x] = UInt8((Int(line[x]) + b) & 255)
                case 3: line[x] = UInt8((Int(line[x]) + (a + b) / 2) & 255)
                case 4:
                    let p = a + b - c
                    let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
                    let pred = pa <= pb && pa <= pc ? a : pb <= pc ? b : c
                    line[x] = UInt8((Int(line[x]) + pred) & 255)
                default: break
                }
            }
            rows.replaceSubrange((y * stride)..<((y + 1) * stride), with: line)
            prior = line
        }

        // Samples to 8-bit RGB and alpha.
        let n = width * height
        var rgb = [UInt8](repeating: 0, count: n * 3)
        var alpha = [UInt8](repeating: 255, count: n)
        var anyAlpha = false
        func sample(_ row: Int, _ index: Int) -> Int {
            // The `index`th sample of the row, scaled to 0...255.
            let base = row * stride
            switch depth {
            case 8: return Int(rows[base + index])
            case 16: return Int(rows[base + index * 2])
            default:
                let bit = index * depth
                let byte = rows[base + bit / 8]
                let v = Int(byte >> (8 - depth - bit % 8)) & ((1 << depth) - 1)
                return colorType == 3 ? v : v * 255 / ((1 << depth) - 1)
            }
        }
        for y in 0..<height {
            for x in 0..<width {
                let o = y * width + x
                switch colorType {
                case 0:
                    let g = sample(y, x)
                    (rgb[o * 3], rgb[o * 3 + 1], rgb[o * 3 + 2]) = (UInt8(g), UInt8(g), UInt8(g))
                    if transparency.count >= 2, g == Int(transparency[depth == 16 ? 0 : 1]) {
                        alpha[o] = 0
                        anyAlpha = true
                    }
                case 2:
                    (rgb[o * 3], rgb[o * 3 + 1], rgb[o * 3 + 2]) = (UInt8(sample(y, x * 3)), UInt8(sample(y, x * 3 + 1)), UInt8(sample(y, x * 3 + 2)))
                case 3:
                    let index = sample(y, x)
                    guard index * 3 + 2 < palette.count else { return nil }
                    (rgb[o * 3], rgb[o * 3 + 1], rgb[o * 3 + 2]) = (palette[index * 3], palette[index * 3 + 1], palette[index * 3 + 2])
                    if index < transparency.count {
                        alpha[o] = transparency[index]
                        anyAlpha = true
                    }
                case 4:
                    let g = sample(y, x * 2)
                    (rgb[o * 3], rgb[o * 3 + 1], rgb[o * 3 + 2]) = (UInt8(g), UInt8(g), UInt8(g))
                    alpha[o] = UInt8(sample(y, x * 2 + 1))
                    anyAlpha = true
                default:
                    (rgb[o * 3], rgb[o * 3 + 1], rgb[o * 3 + 2]) = (UInt8(sample(y, x * 4)), UInt8(sample(y, x * 4 + 1)), UInt8(sample(y, x * 4 + 2)))
                    alpha[o] = UInt8(sample(y, x * 4 + 3))
                    anyAlpha = true
                }
            }
        }
        return StampImage(width, height, rgb, anyAlpha ? alpha : nil)
    }

    private static func be32(_ b: [UInt8], _ at: Int) -> UInt32 {
        UInt32(b[at]) << 24 | UInt32(b[at + 1]) << 16 | UInt32(b[at + 2]) << 8 | UInt32(b[at + 3])
    }

    /// Raw deflate data (the zlib header and checksum already stripped) inflated.
    private static func inflate(_ data: [UInt8]) -> [UInt8]? {
        guard let out = try? (Data(data) as NSData).decompressed(using: .zlib) as Data else { return nil }
        return Array(out)
    }
}
