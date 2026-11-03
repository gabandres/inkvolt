import Foundation

/// Dark pages for night reading (the Windows viewer's `NightColors`): flips lightness but keeps hue (red stays red,
/// blue stays blue), then softens the range so white paper becomes dark grey (26) and black text light grey (226) rather
/// than harsh pure white on black. Each channel is shifted by 255 - max - min (which keeps it within 0...255), then
/// mapped through `levels`. Works on 8-bit pixels of three channels in any order (RGB here, BGR on Windows): the map
/// treats the channels alike.
public enum NightColors {
    /// The paper's color once dark (Windows' `DarkPageBrush`).
    public static let paper: UInt8 = 26

    /// `26 + v * 200 / 255` for every v in 0...255.
    public static let levels: [UInt8] = (0...255).map { UInt8(26 + $0 * 200 / 255) }

    /// Maps `pixels` (3 bytes each) in place; stops with `CancellationError` when `cancel` fires (checked every 64K
    /// pixels).
    public static func apply(_ pixels: inout [UInt8], cancel: CancelToken? = nil) throws {
        let band = 3 * 65536
        let count = pixels.count - pixels.count % 3
        try pixels.withUnsafeMutableBufferPointer { px in
            try levels.withUnsafeBufferPointer { lv in
                var start = 0
                while start < count {
                    if cancel?.isCancelled == true { throw CancellationError() }
                    let end = min(count, start + band)
                    var i = start
                    while i < end {
                        let a = Int(px[i]), b = Int(px[i + 1]), c = Int(px[i + 2])
                        let hi = max(a, b, c), lo = min(a, b, c)
                        let shift = 255 - hi - lo
                        px[i] = lv[a + shift]
                        px[i + 1] = lv[b + shift]
                        px[i + 2] = lv[c + shift]
                        i += 3
                    }
                    start = end
                }
            }
        }
    }
}
