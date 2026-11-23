import CoreGraphics
import Foundation
import ImageIO
import PrintCore
import UniformTypeIdentifiers

/// Photos from a capture source decoded and pages written through Image I/O (roadmap 4.6, 4.12; Windows' `PhotoCodec`): a
/// photo whose header `CapturedPhotoInput` checked is decoded as stored (its EXIF orientation not applied: `PhotoPage` turns it) to
/// RGB at its own size, and a page is written as a JPEG with its resolution.
public struct ImageIOPhotoCodec: PhotoCodec {
    public init() {}

    public struct NotDecoded: Error {}

    public func decode(_ data: [UInt8], _ header: PhotoHeader) throws -> PrintCore.Picture {
        guard let source = CGImageSourceCreateWithData(Data(data) as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) >= 1, let size = ScanImaging.size(of: source),
              size.width == header.width, size.height == header.height,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw NotDecoded() }
        return PrintCore.Picture(try ScanImaging.pixels(image, channels: 3), image.width, image.height, 3)
    }

    /// A picture as an image (the camera window's still frame in demo mode).
    public static func image(_ p: PrintCore.Picture) -> CGImage? { try? ScanImaging.picture(p.pixels, width: p.width, height: p.height, channels: p.channels) }

    public func encodeJpeg(_ page: PrintCore.Picture, dpi: Int) throws -> [UInt8] {
        let image = try ScanImaging.picture(page.pixels, width: page.width, height: page.height, channels: page.channels)
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw NotDecoded() }
        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: ScanImaging.quality, kCGImagePropertyDPIWidth: dpi,
                                        kCGImagePropertyDPIHeight: dpi]
        CGImageDestinationAddImage(destination, image, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw NotDecoded() }
        return [UInt8](data as Data)
    }
}
