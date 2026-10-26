import CoreGraphics
import Foundation
import ImageIO
import PrintCore
import UniformTypeIdentifiers

/// Scanned pages as images (the Windows app's `ScanImaging`): the downscaled grey copy the page check reads, the page with its
/// edits (straightened, cropped, turned), thumbnails, and JPEG out. ImageIO and Core Graphics; call through `offPool`.
public enum ScanImaging {
    /// Longest side of the analysis copy: about 100 dpi for a letter page.
    static let analysisSize = 1100

    /// JPEG quality for edited pages (unedited pages keep the scanner's own JPEG).
    static let quality = 0.92

    public struct ImageError: Error {}

    /// The page check's copy: grey, at most `analysisSize` pixels on its longest side.
    public static func analysis(_ jpeg: [UInt8]) throws -> GrayImage {
        let image = try decode(jpeg, maxPixels: analysisSize)
        let (w, h) = (image.width, image.height)
        var pixels = [UInt8](repeating: 255, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ImageError() }
        return GrayImage(width: w, height: h, pixels: pixels)
    }

    /// The page with its edits: straightened by `deskew` degrees, cropped, turned. `maxPixels`: decoded at most that many pixels
    /// on its longest side first (thumbnails); nil: full size.
    public static func render(_ jpeg: [UInt8], _ edits: PageEdits, maxPixels: Int? = nil) throws -> CGImage {
        var image = try decode(jpeg, maxPixels: maxPixels)
        if edits.deskew != 0 { image = try straightened(image, by: edits.deskew) }
        if let crop = edits.crop, !crop.isFull {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let x = (crop.x * w).rounded(), y = (crop.y * h).rounded()
            let rect = CGRect(x: x, y: y, width: min(max((crop.width * w).rounded(), 1), w - x), height: min(max((crop.height * h).rounded(), 1), h - y))
            guard let cropped = image.cropping(to: rect) else { throw ImageError() } // CGImage's crop is top-left based, as CropBox is
            image = cropped
        }
        let turns = ((edits.quarterTurns % 4) + 4) % 4
        if turns != 0 { image = try turned(image, turns) }
        return image
    }

    /// The page as saved: the scanner's JPEG when it has no edits, else the edited page encoded once.
    public static func jpeg(_ original: [UInt8], _ edits: PageEdits) throws -> [UInt8] {
        edits.isEmpty ? original : try jpeg(render(original, edits))
    }

    public static func jpeg(_ image: CGImage) throws -> [UInt8] {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ImageError() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError() }
        return [UInt8](data as Data)
    }

    /// Width and height in pixels without decoding the page.
    public static func size(_ jpeg: [UInt8]) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (w, h)
    }

    static func decode(_ jpeg: [UInt8], maxPixels: Int?) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(Data(jpeg) as CFData, nil) else { throw ImageError() }
        if let maxPixels {
            let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                            kCGImageSourceCreateThumbnailWithTransform: true]
            if let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) { return image }
        }
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ImageError() }
        return image
    }

    /// Turned `degrees` anticlockwise as the page check measured the skew (the Windows app turns the pixels by −deskew,
    /// clockwise positive), same size, the uncovered corners white: PrintCore's `PageRotate`, so both apps straighten alike.
    static func straightened(_ image: CGImage, by degrees: Double) throws -> CGImage {
        let (w, h) = (image.width, image.height)
        let stride = w * 4
        var pixels = [UInt8](repeating: 255, count: stride * h)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        let drawn: Bool = pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride, space: space,
                                          bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { throw ImageError() }
        let turned = PageRotate.rotate(pixels, width: w, height: h, stride: stride, channels: 4, degrees: -degrees)
        guard let provider = CGDataProvider(data: Data(turned) as CFData),
              let result = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: space,
                                   bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true,
                                   intent: .defaultIntent) else { throw ImageError() }
        return result
    }

    /// Turned `quarters` quarter turns clockwise.
    static func turned(_ image: CGImage, _ quarters: Int) throws -> CGImage {
        let (w, h) = (image.width, image.height)
        let (outW, outH) = quarters % 2 == 0 ? (w, h) : (h, w)
        guard let context = CGContext(data: nil, width: outW, height: outH, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ImageError() }
        // Core Graphics is y-up: a clockwise turn on screen is a negative rotation here.
        context.translateBy(x: CGFloat(outW) / 2, y: CGFloat(outH) / 2)
        context.rotate(by: -CGFloat(quarters) * .pi / 2)
        context.draw(image, in: CGRect(x: -CGFloat(w) / 2, y: -CGFloat(h) / 2, width: CGFloat(w), height: CGFloat(h)))
        guard let result = context.makeImage() else { throw ImageError() }
        return result
    }
}
