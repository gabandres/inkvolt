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

    /// The page with its edits: straightened by `deskew` degrees, cropped, cleaned up by its filters (PrintCore's
    /// `PageCleanup`, on the page scanned at `dpi`), turned. `maxPixels`: decoded at most that many pixels on its longest side
    /// first (thumbnails, previews: the filters then go by that copy's own resolution); nil: full size.
    /// - Throws: `CancellationError` when `stop` fires.
    public static func render(_ jpeg: [UInt8], _ edits: PageEdits, maxPixels: Int? = nil, dpi: Int = 300, stop: BatchStop? = nil) throws -> CGImage {
        var image = try decode(jpeg, maxPixels: maxPixels)
        let grey = image.colorSpace?.model == .monochrome
        let copyDpi = maxPixels == nil ? dpi : self.copyDpi(dpi, jpeg, decodedWidth: image.width)
        try stop?.check()
        if edits.deskew != 0 { image = try straightened(image, by: edits.deskew) }
        if let crop = edits.crop, !crop.isFull {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let x = (crop.x * w).rounded(), y = (crop.y * h).rounded()
            let rect = CGRect(x: x, y: y, width: min(max((crop.width * w).rounded(), 1), w - x), height: min(max((crop.height * h).rounded(), 1), h - y))
            guard let cropped = image.cropping(to: rect) else { throw ImageError() } // CGImage's crop is top-left based, as CropBox is
            image = cropped
        }
        image = try cleaned(image, edits.filters, dpi: copyDpi, grey: grey, stop: stop)
        let turns = ((edits.quarterTurns % 4) + 4) % 4
        if turns != 0 { image = try turned(image, turns) }
        return image
    }

    /// The page as saved: the scanner's JPEG when it has no edits (filters on a page too large to clean up are none), else
    /// the edited page encoded once.
    public static func jpeg(_ original: [UInt8], _ edits: PageEdits, dpi: Int = 300, stop: BatchStop? = nil) throws -> [UInt8] {
        let size = Self.size(original)
        let fitting = size.map { edits.for(width: $0.width, height: $0.height) } ?? edits
        return fitting.isEmpty ? original : try jpeg(render(original, fitting, dpi: dpi, stop: stop))
    }

    /// The sheet as a crop of the page straightened by `deskew` degrees (`PaperEdge.find` on the analysis copy, whose
    /// resolution is its width × `dpi` ÷ the scan's), or nil when its edge can't be told from the lid.
    public static func paperEdge(_ jpeg: [UInt8], dpi: Int, deskew: Double = 0) -> CropBox? {
        guard let gray = try? analysis(jpeg) else { return nil }
        return PaperEdge.find(gray, ppi: ppi(of: gray, jpeg, dpi: dpi), deskew: deskew)
    }

    /// The analysis copy's pixels an inch, for a page scanned at `dpi`.
    public static func ppi(of gray: GrayImage, _ jpeg: [UInt8], dpi: Int) -> Double {
        Double(gray.width) * Double(dpi) / Double(max(size(jpeg)?.width ?? gray.width, 1))
    }

    /// A smaller copy holds its inch in fewer pixels: the filters' sizes go by this, not the scan's.
    static func copyDpi(_ dpi: Int, _ jpeg: [UInt8], decodedWidth: Int) -> Int {
        guard let full = size(jpeg)?.width, full > 0 else { return dpi }
        let share = Double(min(max(decodedWidth, 0), full)) / Double(full)
        return max(1, Int((Double(dpi) * share).rounded())) // bounded: dpi times a share of at most 1, over a width above 0
    }

    /// The picture through PrintCore's `PageCleanup` (grey as one channel, colour as three); the same picture when no filter
    /// changes pixels or it is too large to clean up.
    static func cleaned(_ image: CGImage, _ filters: PageFilters, dpi: Int, grey: Bool, stop: BatchStop?) throws -> CGImage {
        let (w, h) = (image.width, image.height)
        if filters.isDisjoint(with: .pixelFilters) || PageCleanup.tooLarge(w, h) { return image }
        let channels = grey ? 1 : 3
        let packed = try pixels(image, channels: channels)
        let done = try PageCleanup.apply(packed, width: w, height: h, channels: channels, dpi: dpi, filters, stop: stop)
        if done.done.isEmpty { return image }
        return try picture(done.pixels, width: w, height: h, channels: channels)
    }

    /// The image's pixels as rows of width × `channels` bytes, no padding (1: grey, 3: RGB).
    static func pixels(_ image: CGImage, channels: Int) throws -> [UInt8] {
        let (w, h) = (image.width, image.height)
        let stride = channels == 1 ? w : w * 4
        var drawn = [UInt8](repeating: 255, count: stride * h)
        let space = channels == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        let info = channels == 1 ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue
        let ok: Bool = drawn.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride, space: space,
                                          bitmapInfo: info) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw ImageError() }
        if channels == 1 { return drawn }
        var packed = [UInt8](repeating: 0, count: w * h * 3)
        packed.withUnsafeMutableBufferPointer { out in
            drawn.withUnsafeBufferPointer { src in
                for i in 0..<(w * h) {
                    out[i * 3] = src[i * 4]
                    out[i * 3 + 1] = src[i * 4 + 1]
                    out[i * 3 + 2] = src[i * 4 + 2]
                }
            }
        }
        return packed
    }

    /// Rows of width × `channels` bytes (1: grey, 3: RGB) as an image.
    static func picture(_ pixels: [UInt8], width: Int, height: Int, channels: Int) throws -> CGImage {
        let space = channels == 1 ? CGColorSpaceCreateDeviceGray() : CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8 * channels, bytesPerRow: width * channels,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue), provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { throw ImageError() }
        return image
    }

    public static func jpeg(_ image: CGImage) throws -> [UInt8] {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ImageError() }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ImageError() }
        return [UInt8](data as Data)
    }

    /// One photo found on the glass, cut out of the full-size scan straight (`GlassPhotoCrop`: only the pixels around it are
    /// turned), cleaned up by what of `filters` suits a print (descreen, restore colors: no paper to crop to or whiten) and
    /// given its quarter turns, as a JPEG.
    public static func photo(_ jpeg: [UInt8], _ box: PhotoBox, filters: PageFilters = [], dpi: Int = 300, stop: BatchStop? = nil) throws -> [UInt8] {
        try Self.jpeg(photoImage(jpeg, box, filters: filters, maxPixels: nil, dpi: dpi, stop: stop))
    }

    /// One photo cut out and cleaned up, from the scan decoded at most `maxPixels` on its longest side, for the clean up view.
    public static func photoPreview(_ jpeg: [UInt8], _ box: PhotoBox, filters: PageFilters, maxPixels: Int, dpi: Int, stop: BatchStop? = nil) throws -> CGImage {
        try photoImage(jpeg, box, filters: filters, maxPixels: maxPixels, dpi: dpi, stop: stop)
    }

    static func photoImage(_ jpeg: [UInt8], _ box: PhotoBox, filters: PageFilters, maxPixels: Int?, dpi: Int, stop: BatchStop?) throws -> CGImage {
        let image = try decode(jpeg, maxPixels: maxPixels)
        let grey = image.colorSpace?.model == .monochrome
        let copyDpi = maxPixels == nil ? dpi : self.copyDpi(dpi, jpeg, decodedWidth: image.width)
        let r = GlassPhotoCrop.bounds(box, width: image.width, height: image.height)
        guard let part = image.cropping(to: CGRect(x: r.x, y: r.y, width: r.width, height: r.height)) else { throw ImageError() }
        let stride = r.width * 4
        var region = [UInt8](repeating: 255, count: stride * r.height)
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.noneSkipLast.rawValue
        let drawn: Bool = region.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: r.width, height: r.height, bitsPerComponent: 8, bytesPerRow: stride,
                                          space: space, bitmapInfo: info) else { return false }
            context.draw(part, in: CGRect(x: 0, y: 0, width: r.width, height: r.height))
            return true
        }
        guard drawn else { throw ImageError() }
        let cut = GlassPhotoCrop.straighten(region, regionWidth: r.width, regionHeight: r.height, stride: stride, channels: 4, box: box,
                                            scanWidth: image.width, regionX: r.x, regionY: r.y)
        guard let provider = CGDataProvider(data: Data(cut.pixels) as CFData),
              var photo = CGImage(width: cut.width, height: cut.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: cut.stride, space: space,
                                  bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil, shouldInterpolate: true,
                                  intent: .defaultIntent) else { throw ImageError() }
        photo = try cleaned(photo, filters.intersection([.descreen, .restoreColors]), dpi: copyDpi, grey: grey, stop: stop)
        let turns = ((box.quarterTurns % 4) + 4) % 4
        if turns != 0 { photo = try turned(photo, turns) }
        return photo
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
