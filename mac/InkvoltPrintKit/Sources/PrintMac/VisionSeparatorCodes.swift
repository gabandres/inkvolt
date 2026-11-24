import CoreGraphics
import Foundation
import PrintCore
import Vision

/// The QR codes and Code 128 and Code 39 barcodes on a scanned page, read with Vision's barcode request
/// (`VNDetectBarcodesRequest`), for separator sheets saying PATCHT (`SeparatorCodes`, whose rules decide what counts).
/// Windows reads them with ZXing.Net. Vision reads a code in any direction; a page it can't make sense of has no code on it.
public struct VisionSeparatorCodes: SeparatorCodeReader {
    public init() {}

    public func codes(on page: GrayImage, qrCodes: Bool) -> [ReadCode] {
        guard let image = Self.cgImage(page) else { return [] }
        let request = VNDetectBarcodesRequest()
        var symbologies: [VNBarcodeSymbology] = [.code128, .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum]
        if qrCodes { symbologies.append(.qr) }
        request.symbologies = symbologies
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }
        let found: [VNBarcodeObservation] = request.results ?? []
        return found.map { (o: VNBarcodeObservation) -> ReadCode in ReadCode(Self.kind(o.symbology), o.payloadStringValue) }
    }

    private static func kind(_ s: VNBarcodeSymbology) -> ReadCode.Symbology {
        switch s {
        case .qr: .qrCode
        case .code128: .code128
        case .code39, .code39Checksum, .code39FullASCII, .code39FullASCIIChecksum: .code39
        default: .other
        }
    }

    /// The page as an 8-bit grey image; nil when its pixels don't match its size.
    static func cgImage(_ page: GrayImage) -> CGImage? {
        guard page.width > 0, page.height > 0, page.pixels.count == page.width * page.height,
              let provider = CGDataProvider(data: Data(page.pixels) as CFData) else { return nil }
        return CGImage(width: page.width, height: page.height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: page.width,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
