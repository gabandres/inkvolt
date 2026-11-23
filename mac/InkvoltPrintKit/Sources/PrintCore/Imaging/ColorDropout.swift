import Foundation

/// A pen or form color that Clean up's "Drop a color" turns white (roadmap 4.7, the Windows app's `DropColor`, as Epson Scan
/// 2's dropout): red, green or blue, or a color picked off the page. Stored as `hex` ("#RRGGBB").
public struct DropColor: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var r: UInt8, g: UInt8, b: UInt8

    public init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r
        self.g = g
        self.b = b
    }

    public static let red = DropColor(0xD2, 0x2B, 0x2B)
    public static let green = DropColor(0x2E, 0x9E, 0x4F)
    public static let blue = DropColor(0x2B, 0x55, 0xC8)

    /// The least colorfulness (the largest of R, G and B less the smallest) a picked color needs: grey and black have no hue
    /// to drop.
    public static let minPickChroma = 40

    public var chroma: Int { Int(max(r, g, b)) - Int(min(r, g, b)) }

    /// Colorful enough to be dropped by its hue (a pen's ink, a form's lines), not a grey, a black or the paper.
    public var isColorful: Bool { chroma >= Self.minPickChroma }

    /// The hue, 0 to 360 degrees (red 0, green 120, blue 240).
    public var hue: Double { ColorDropout.hueOf(r, g, b) }

    public var hex: String { String(format: "#%02X%02X%02X", r, g, b) }

    /// Red, green or blue (the three named choices); false for a color picked off a page.
    public var isNamed: Bool { self == .red || self == .green || self == .blue }

    /// "red", "green", "blue", or "picked color", in the interface's words.
    public var name: String {
        self == .red ? loc("red") : self == .green ? loc("green") : self == .blue ? loc("blue") : loc("picked color")
    }

    /// "#RRGGBB" (or "RRGGBB") as a color; nil for anything else, so a hand-edited setting can't be misread.
    public static func parse(_ hex: String?) -> DropColor? {
        var s = (hex ?? "").trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let rgb = Int(s, radix: 16) else { return nil }
        return DropColor(UInt8(rgb >> 16 & 0xFF), UInt8(rgb >> 8 & 0xFF), UInt8(rgb & 0xFF))
    }

    public var description: String { hex }
}

/// Drops one color to white (the Windows app's `ColorDropout`): every pixel whose hue is the color's (within `hueFull`°,
/// fading out by `hueNone`°) and colorful enough goes white, the more colorful the whiter, so a red form's lines, a blue pen's
/// notes or a stamp vanish and the black print over them stays. Greys, black and the paper have no hue and are left as they
/// are. Color scans only (a grey scan has no color to tell apart). Pixels are RGB on the Mac (Windows: BGR), rows packed.
public enum ColorDropout {
    /// Hues this close to the color are dropped fully; past `hueNone` not at all.
    public static let hueFull = 25.0, hueNone = 45.0

    /// Colorfulness below `chromaNone` is grey (paper, black print, JPEG noise): kept. From `chromaFull` up: dropped fully.
    public static let chromaNone = 14, chromaFull = 40

    /// Drops `color` in place; true when any pixel changed. Grey pages (1 channel) are left as they are.
    /// - Throws: `CancellationError` when `stop` fires.
    public static func apply(_ pixels: inout [UInt8], _ width: Int, _ height: Int, _ channels: Int, _ color: DropColor, stop: BatchStop? = nil) throws -> Bool {
        guard channels == 3, width >= 1, height >= 1, color.isColorful, pixels.count >= width * height * 3 else { return false }
        let target = color.hue
        let changed = Shared(false)
        try pixels.withUnsafeMutableBufferPointer { buffer in
            let p = buffer
            try cleanupRows(height, stop) { y in
                let row = y * width * 3
                var any = false
                for x in 0..<width {
                    let i = row + x * 3
                    let (r, g, b) = (p[i], p[i + 1], p[i + 2])
                    let w = weight(r, g, b, target)
                    if w <= 0 { continue }
                    p[i] = lift(r, w)
                    p[i + 1] = lift(g, w)
                    p[i + 2] = lift(b, w)
                    any = true
                }
                if any { changed.withLock { $0 = true } }
            }
        }
        return changed.withLock { $0 }
    }

    /// How much of the way to white a pixel goes: 0 (kept) to 1 (white).
    static func weight(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ targetHue: Double) -> Double {
        let chroma = Int(max(r, g, b)) - Int(min(r, g, b))
        if chroma <= chromaNone { return 0 }
        var distance = abs(hueOf(r, g, b) - targetHue)
        if distance > 180 { distance = 360 - distance }
        if distance >= hueNone { return 0 }
        let byHue = distance <= hueFull ? 1 : (hueNone - distance) / (hueNone - hueFull)
        let byChroma = chroma >= chromaFull ? 1 : Double(chroma - chromaNone) / Double(chromaFull - chromaNone)
        return byHue * byChroma
    }

    private static func lift(_ value: UInt8, _ weight: Double) -> UInt8 {
        UInt8(min(255, max(0, (Double(value) + (255 - Double(value)) * weight).rounded(.toNearestOrEven))))
    }

    /// The hue of an RGB color, 0 to 360 degrees; 0 for a grey.
    public static func hueOf(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        let (rr, gg, bb) = (Double(r), Double(g), Double(b))
        let mx = max(r, g, b), mn = min(r, g, b)
        let c = Double(mx) - Double(mn)
        if c == 0 { return 0 }
        var h = mx == r ? (gg - bb) / c : mx == g ? 2 + (bb - rr) / c : 4 + (rr - gg) / c
        h *= 60
        return h < 0 ? h + 360 : h
    }
}
