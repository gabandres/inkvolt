import CoreGraphics
import Foundation
import PrintCore

/// The pictures Join with the Next Page… works on (roadmap 4.8, PrintCore's `HalvesJoin`): each half as it is saved (its
/// straightening, crop, clean up and turn) in RGB at full size, and the joined page back as a JPEG or a picture to show. A
/// page too large to edit (`PageCleanup.tooLarge`) isn't decoded (`ScanImaging.decode` refuses it). Call through `offPool`.
public enum JoinImages {
    public struct Half: Sendable {
        public let rgb: [UInt8]
        public let width: Int
        public let height: Int
    }

    /// The page `jpeg` with `edits` (scanned at `dpi`), as RGB pixels.
    /// - Throws: when it can't be read, or `CancellationError` when `stop` fires.
    public static func half(_ jpeg: [UInt8], _ edits: PageEdits, dpi: Int, stop: BatchStop? = nil) throws -> Half {
        let image = try ScanImaging.render(jpeg, edits, dpi: dpi, stop: stop)
        return Half(rgb: try ScanImaging.pixels(image, channels: 3), width: image.width, height: image.height)
    }

    /// RGB pixels as a JPEG page.
    public static func jpeg(_ rgb: [UInt8], width: Int, height: Int) throws -> [UInt8] {
        try ScanImaging.jpeg(ScanImaging.picture(rgb, width: width, height: height, channels: 3))
    }

    /// RGB pixels as a picture (the join's preview).
    public static func picture(_ rgb: [UInt8], width: Int, height: Int) throws -> CGImage {
        try ScanImaging.picture(rgb, width: width, height: height, channels: 3)
    }
}
