import Foundation
import Testing
@testable import PrintCore

/// Ported from PhoneScanTests.cs. Phone as a scanner (roadmap 4.6) and the photo-to-page step it shares with a camera
/// (4.12): the photo's header read as hostile input, the page found, warped and sized. Adapted: pictures are RGB (Windows'
/// BGR); the channel is the Mac's `PhotoChannel`; a picture that isn't the size it says throws `PhotoPage.NotAPicture`.
struct PhoneScanTests {
    // ---------------------------------------------------------------- photos as hostile input

    /// A JPEG's first bytes: SOI, an EXIF block with `orientation` (none when nil), then a frame header.
    static func jpegHeader(_ width: Int, _ height: Int, _ orientation: Int? = nil, bigEndian: Bool = false) -> [UInt8] {
        var b: [UInt8] = [0xFF, 0xD8]
        if let o = orientation {
            var tiff: [UInt8] = []
            func u16(_ v: Int) { if bigEndian { tiff += [UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] } else { tiff += [UInt8(v & 0xFF), UInt8(v >> 8 & 0xFF)] } }
            func u32(_ v: Int) { if bigEndian { u16(v >> 16); u16(v & 0xFFFF) } else { u16(v & 0xFFFF); u16(v >> 16) } }
            tiff += bigEndian ? Array("MM".utf8) : Array("II".utf8)
            u16(42)
            u32(8)
            u16(2) // two entries: something else, then the orientation
            u16(0x010F); u16(2); u32(4); u32(0)
            u16(0x0112); u16(3); u32(1); u16(o); u16(0)
            u32(0)
            let app1 = Array("Exif".utf8) + [0, 0] + tiff
            b += [0xFF, 0xE1, UInt8((app1.count + 2) >> 8), UInt8((app1.count + 2) & 0xFF)]
            b += app1
        }
        b += [0xFF, 0xC0, 0x00, 0x11, 0x08, UInt8(height >> 8 & 0xFF), UInt8(height & 0xFF), UInt8(width >> 8 & 0xFF), UInt8(width & 0xFF), 0x03,
              0x01, 0x22, 0x00, 0x02, 0x11, 0x01, 0x03, 0x11, 0x01]
        b += [0xFF, 0xDA, 0x00, 0x0C, 0x03, 0x01, 0x00, 0x02, 0x11, 0x03, 0x11, 0x00, 0x3F, 0x00, 0xFF, 0xD9]
        return b
    }

    static func pngHeader(_ width: UInt32, _ height: UInt32) -> [UInt8] {
        var b: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13] + Array("IHDR".utf8)
        for v in [width, height] { b += [UInt8(v >> 24), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)] }
        b += [8, 2, 0, 0, 0, 0, 0, 0, 0]
        return b
    }

    @Test func aPhotoIsKnownByItsFirstBytesWithItsSizeAndOrientation() {
        #expect(CapturedPhotoInput.inspect(Self.jpegHeader(4032, 3024)) == PhotoHeader(.jpeg, 4032, 3024))
        #expect(CapturedPhotoInput.inspect(Self.jpegHeader(4032, 3024, 6)) == PhotoHeader(.jpeg, 4032, 3024, 6))
        #expect(CapturedPhotoInput.inspect(Self.jpegHeader(4032, 3024, 8, bigEndian: true)) == PhotoHeader(.jpeg, 4032, 3024, 8))
        #expect(CapturedPhotoInput.inspect(Self.jpegHeader(4032, 3024, 6))!.upright == (3024, 4032))
        #expect(CapturedPhotoInput.inspect(Self.pngHeader(1200, 1600)) == PhotoHeader(.png, 1200, 1600))
        // An orientation out of range is none.
        #expect(CapturedPhotoInput.inspect(Self.jpegHeader(1000, 1000, 9))?.orientation == 1)
    }

    @Test func anythingElseAndPhotosTooLargeOrSmallAreRefusedUnread() {
        #expect(CapturedPhotoInput.inspect(Array("<html><body>not a photo at all</body></html>".utf8)) == nil)
        #expect(CapturedPhotoInput.inspect(Array("GIF89a................................".utf8)) == nil)
        #expect(CapturedPhotoInput.inspect(Array(Self.jpegHeader(4032, 3024).prefix(10))) == nil) // cut off before its frame header
        #expect(CapturedPhotoInput.inspect(Self.jpegHeader(20_000, 1000)) == nil) // a side past the limit
        #expect(CapturedPhotoInput.inspect(Self.jpegHeader(10_000, 10_000)) == nil) // 100 megapixels
        #expect(CapturedPhotoInput.inspect(Self.jpegHeader(100, 3000)) == nil) // too narrow to hold a page
        #expect(CapturedPhotoInput.inspect(Self.jpegHeader(0, 3000)) == nil) // height given later (DNL): not taken
        #expect(CapturedPhotoInput.inspect(Self.pngHeader(UInt32.max, 5)) == nil)
        // The scan's data before any frame header, or a segment longer than the file.
        #expect(CapturedPhotoInput.inspect([0xFF, 0xD8, 0xFF, 0xDA, 0, 4, 0, 0] + [UInt8](repeating: 0, count: 30)) == nil)
        #expect(CapturedPhotoInput.inspect([0xFF, 0xD8, 0xFF, 0xE1, 0xFF, 0xFF] + [UInt8](repeating: 0, count: 30)) == nil)
        // An EXIF block that points past its end reads as no orientation.
        let tiff: [UInt8] = [0x49, 0x49, 42, 0, 0xF0, 0xFF, 0xFF, 0x7F]
        #expect(tiff.withUnsafeBufferPointer { CapturedPhotoInput.exifOrientation($0) } == 1)
        #expect(CapturedPhotoInput.inspect([UInt8](repeating: 0, count: CapturedPhotoInput.maxBytes + 1)) == nil)
    }

    // ---------------------------------------------------------------- photo to page

    @Test(arguments: [
        (1100.0, 850.0, "Letter", 11.0), (1414, 1000, "A4", 11.69), (1400, 850, "Legal", 14), (4032, 3024, "Letter", 11), // a 4:3 photo of the whole frame
        (3000, 3000, "Photo", 11), (3000, 1500, "Narrow", 17), (3000, 800, "Receipt", 11.81),
    ])
    func aPageIsTakenForThePaperItsProportionsSay(_ longSide: Double, _ shortSide: Double, _ name: String, _ inches: Double) {
        let paper = PhotoPage.paper(longSide, shortSide)
        #expect(paper.name == name)
        #expect(abs(paper.longInches - inches) < 0.05)
        #expect(PhotoPage.paper(shortSide, longSide) == paper)
        #expect(PhotoPage.paper(.nan, 5).name == "Letter")
    }

    @Test(arguments: [(1, 0, 0), (2, 2, 0), (3, 2, 1), (4, 0, 1), (5, 0, 0), (6, 0, 1), (7, 2, 1), (8, 2, 0)])
    func aPhotoIsTurnedTheWayTheCameraHeldIt(_ orientation: Int, _ cornerX: Int, _ cornerY: Int) throws {
        // 3 × 2, each pixel its own value: the shown top left is the stored pixel the EXIF orientation says.
        let p = Picture([0, 1, 2, 3, 4, 5], 3, 2, 1)
        let turned = try PhotoPage.orient(p, orientation)
        #expect((turned.width, turned.height) == (orientation >= 5 ? (2, 3) : (3, 2)))
        #expect(Int(turned.pixels[0]) == cornerY * 3 + cornerX)
        #expect(turned.pixels.sorted() == p.pixels.sorted())
    }

    /// A white page with a few dark lines on a dark desk, photographed at an angle: its corners clockwise from the top left.
    static func pageOnDesk(_ w: Int, _ h: Int, _ corners: [(Double, Double)], channels: Int = 3) -> Picture {
        var px = [UInt8](repeating: 0, count: w * h * channels)
        func inside(_ x: Double, _ y: Double) -> Bool {
            for i in 0..<4 {
                let (a, b) = (corners[i], corners[(i + 1) % 4])
                if (b.0 - a.0) * (y - a.1) - (b.1 - a.1) * (x - a.0) < 0 { return false }
            }
            return true
        }
        let (cx, cy) = ((corners[0].0 + corners[2].0) / 2, (corners[0].1 + corners[2].1) / 2)
        for y in 0..<h {
            for x in 0..<w {
                var v: UInt8 = 60
                if inside(Double(x) + 0.5, Double(y) + 0.5) {
                    v = 235
                    // Lines of "text" across the page's middle.
                    if abs(Double(x) - cx) < Double(w) * 0.12 && Int(Double(y) - cy + 1000) % 24 < 3 && abs(Double(y) - cy) < Double(h) * 0.2 { v = 30 }
                }
                for c in 0..<channels { px[(y * w + x) * channels + c] = v }
            }
        }
        return Picture(px, w, h, channels)
    }

    @Test func aPagePhotographedAtAnAngleIsWarpedFlatAndSizedAsItsPaper() throws {
        // A page seen from one side: wider at the bottom.
        let photo = Self.pageOnDesk(900, 1200, [(250, 150), (650, 150), (760, 1050), (140, 1050)])
        let page = try PhotoPage.make(photo, orientation: 1, dpi: 150, gray: false)
        #expect(page.straightened)
        #expect(page.image.channels == 3)
        #expect(page.dpi == 150)
        // Its long side is the paper's at 150 dpi; the page fills the result (its middle and its corners just inside are paper, not desk).
        #expect(Int((page.paper.longInches * 150).rounded(.toNearestOrEven)) == max(page.image.width, page.image.height))
        func at(_ fx: Double, _ fy: Double) -> UInt8 {
            page.image.pixels[(Int(fy * Double(page.image.height)) * page.image.width + Int(fx * Double(page.image.width))) * 3]
        }
        for (fx, fy) in [(0.04, 0.04), (0.96, 0.04), (0.96, 0.96), (0.04, 0.96), (0.5, 0.05)] { #expect(at(fx, fy) > 200, "desk at \(fx),\(fy)") }
    }

    @Test func aPhotoWithoutAPageOnADeskIsKeptWholeInGreyWhenAsked() throws {
        let photo = Self.pageOnDesk(800, 600, [(0, 0), (800, 0), (800, 600), (0, 600)]) // all paper: nothing to warp
        let page = try PhotoPage.make(photo, orientation: 6, dpi: 200, gray: true)
        #expect(!page.straightened)
        #expect(page.image.isGray)
        // Turned upright first (EXIF 6: a quarter clockwise): taller than wide, 11 inches at 200 dpi.
        #expect(page.image.height == 2200)
        #expect(page.image.width == 1650)
        #expect(throws: PhotoPage.NotAPicture.self) { try PhotoPage.make(Picture([UInt8](repeating: 0, count: 10), 4, 4, 3), orientation: 1, dpi: 150, gray: false) }
    }

    // ---------------------------------------------------------------- a capture source as a scanner

    /// "Decodes" any photo to a grey page of the header's size (or `size`); "encodes" as a few bytes saying its size.
    final class FakeCodec: PhotoCodec, @unchecked Sendable {
        let size: (Int, Int)?
        private let lock = NSLock()
        private var list: [(w: Int, h: Int, channels: Int, dpi: Int)] = []

        init(size: (Int, Int)? = nil) { self.size = size }

        var encoded: [(w: Int, h: Int, channels: Int, dpi: Int)] { lock.withLock { list } }

        func decode(_ data: [UInt8], _ header: PhotoHeader) throws -> Picture {
            let (w, h) = size ?? (header.width, header.height)
            return Picture([UInt8](repeating: 200, count: w * h * 3), w, h, 3)
        }

        func encodeJpeg(_ page: Picture, dpi: Int) throws -> [UInt8] {
            lock.withLock { list.append((page.width, page.height, page.channels, dpi)) }
            return Array("\(page.width)x\(page.height)".utf8)
        }
    }

    private final class Notes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String] = []
        func add(_ s: String) { lock.withLock { list.append(s) } }
        var all: [String] { lock.withLock { list } }
    }

    @Test func photosComeOutAsPagesAtTheScansResolutionAndOthersAreLeftOut() async throws {
        let channel = PhotoChannel(capacity: 8)
        let codec = FakeCodec()
        let notes = Notes()
        let scanner = CaptureScanner(channel, codec: codec, leftOut: { notes.add($0) })
        #expect(channel.tryWrite(CapturedPhoto(data: Self.jpegHeader(800, 600))))
        #expect(channel.tryWrite(CapturedPhoto(data: Array("<html>".utf8))))
        #expect(channel.tryWrite(CapturedPhoto(frame: Picture([UInt8](repeating: 0, count: 600 * 800), 600, 800, 1))))
        #expect(channel.tryWrite(CapturedPhoto(frame: Picture([UInt8](repeating: 0, count: 10 * 10), 10, 10, 1)))) // too small to be a page
        channel.finish()
        var pages: [String] = []
        for try await jpeg in scanner.scan(ScanRequest(source: .platen, color: .grayscale, resolution: 150)) { pages.append(String(decoding: jpeg, as: UTF8.self)) }
        #expect(pages == ["1650x1238", "1238x1650"]) // a 4:3 photo is taken for Letter: 11 inches the long way at 150 dpi, either way round
        #expect(codec.encoded.allSatisfy { $0.channels == 1 && $0.dpi == 150 })
        #expect(scanner.photosLeftOut == 2)
        let notAPhoto = "A photo was left out: it isn't a JPEG or PNG photo the size of a page, or it didn't open."
        #expect(notes.all == [notAPhoto, notAPhoto])

        // A file whose pixels aren't the size its header says is left out.
        let lying = PhotoChannel(capacity: 2)
        #expect(lying.tryWrite(CapturedPhoto(data: Self.jpegHeader(800, 600))))
        lying.finish()
        var none: [[UInt8]] = []
        for try await jpeg in CaptureScanner(lying, codec: FakeCodec(size: (4000, 3000))).scan(ScanRequest()) { none.append(jpeg) }
        #expect(none.isEmpty)
        #expect(CaptureScanner.capabilities("Phone").platen?.resolutions == PhotoPage.resolutions)
    }
}
