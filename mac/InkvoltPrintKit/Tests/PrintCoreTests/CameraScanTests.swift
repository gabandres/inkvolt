import Foundation
import Testing
@testable import PrintCore

/// Ported from CameraScanTests.cs. A webcam or document camera as a scan source (roadmap 4.12): the format chosen, frames
/// made pages, captures counted and bounded. Adapted: the Mac's frames come as AVFoundation's BGRA and become RGB (Windows
/// keeps BGR), rows may be padded; the feed has no preview frames of its own (AVFoundation draws the live picture), so
/// the fake only captures.
struct CameraScanTests {
    @Test func theLargestFormatThatStillMovesIsChosen() {
        let hd = CameraFormat(1280, 720, 30, "420v"), fullHd = CameraFormat(1920, 1080, 30, "420v"), fullHdSlow = CameraFormat(1920, 1080, 15, "BGRA"),
            uhd = CameraFormat(3840, 2160, 15, "420v"), still = CameraFormat(4208, 3120, 2, "420v"), huge = CameraFormat(13_000, 9_000, 30, "420v"),
            tiny = CameraFormat(160, 120, 30, "420v")
        #expect(CameraFormats.choose([hd, fullHdSlow, fullHd, uhd, still, huge, tiny]) == uhd)
        #expect(CameraFormats.choose([fullHdSlow, fullHd, hd]) == fullHd)
        // Nothing streams fast enough: the largest within the limits all the same.
        #expect(CameraFormats.choose([still, CameraFormat(1280, 720, 1, "420v")]) == still)
        #expect(CameraFormats.choose([huge, tiny]) == nil)
        #expect(CameraFormats.choose([]) == nil)
        #expect(CameraFormats.choose([CameraFormat(1920, 1080, .nan, "420v")]) == nil)
    }

    @Test func aFrameIsItsPixelsWithoutAlphaAndOnlyAtItsSize() {
        var bgra = [UInt8](repeating: 0, count: 300 * 200 * 4)
        for i in bgra.indices { bgra[i] = UInt8(i % 4 == 3 ? 255 : i % 251) }
        let rgb = CameraFormats.rgb(bgra, 300, 200)!
        #expect((rgb.width, rgb.height, rgb.channels) == (300, 200, 3))
        #expect(Array(rgb.pixels[3..<6]) == [bgra[6], bgra[5], bgra[4]]) // blue, green, red became red, green, blue
        #expect(CameraFormats.rgb(bgra, 301, 200) == nil)
        #expect(CameraFormats.rgb([], 0, 0) == nil)
        // Rows padded to 1216 bytes (AVFoundation's bytes per row): each row read from its own start.
        var padded = [UInt8](repeating: 9, count: 1216 * 200)
        for y in 0..<200 { for x in 0..<300 { padded[y * 1216 + x * 4] = UInt8(y % 256) } }
        let fromPadded = padded.withUnsafeBufferPointer { CameraFormats.rgb($0, 300, 200, bytesPerRow: 1216) }!
        #expect(fromPadded.pixels[(199 * 300 + 299) * 3 + 2] == 199)
        #expect(padded.withUnsafeBufferPointer { CameraFormats.rgb($0, 300, 200, bytesPerRow: 1000) } == nil)
    }

    /// A camera whose every frame is `picture`, numbered in turn (or always `fixedNumber`).
    private final class FakeFeed: CameraFeed, @unchecked Sendable {
        private let picture: Picture?
        private let fixedNumber: Int64?
        private let lock = NSLock()
        private var number: Int64 = 0

        init(_ picture: Picture?, fixedNumber: Int64? = nil) {
            self.picture = picture
            self.fixedNumber = fixedNumber
        }

        var size: (width: Int, height: Int) { (picture?.width ?? 0, picture?.height ?? 0) }

        func capture() async -> CameraFrame? {
            guard let picture else { return nil }
            let n = fixedNumber ?? lock.withLock {
                number += 1
                return number
            }
            return CameraFrame(picture, n)
        }

        func close() async {}
    }

    private struct SizeCodec: PhotoCodec {
        func decode(_ data: [UInt8], _ header: PhotoHeader) throws -> Picture { throw CameraError("Frames aren't decoded.") }
        func encodeJpeg(_ page: Picture, dpi: Int) throws -> [UInt8] { Array("\(page.width)x\(page.height)@\(dpi)".utf8) }
    }

    private static func gray(_ w: Int, _ h: Int) -> Picture { Picture([UInt8](repeating: 230, count: w * h * 3), w, h, 3) }

    @Test func eachCaptureIsAPageUntilDone() async throws {
        let session = CameraSession()
        #expect(session.statusText() == "Put a page under the camera, then Capture page. Each capture is a page.")
        #expect(await !session.capture(nil))
        #expect(await !session.capture(FakeFeed(nil))) // no frame came
        let frame = FakeFeed(Self.gray(1920, 1080))
        #expect(await session.capture(frame))
        let reading = Task { () -> [String] in
            var pages: [String] = []
            for try await page in CaptureScanner(session.photos, codec: SizeCodec()).scan(ScanRequest(source: .platen, color: .color, resolution: 200)) {
                pages.append(String(decoding: page, as: UTF8.self))
            }
            return pages
        }
        for _ in 0..<100 where session.photos.count > 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await session.capture(frame))
        #expect(session.pagesTaken == 2)
        session.finish()
        #expect(await !session.capture(frame))
        #expect(!session.canCapture)
        let pages = try await reading.value
        // A frame with no page found in it: 16:9 is the camera's, not a paper's, so a page 11 inches the long way at 200 dpi.
        #expect(pages == ["2200x1238@200", "2200x1238@200"])
        #expect(PhotoPage.paper(1920, 1080, foundPage: false) == PaperGuess("Photo", 11))
        #expect(PhotoPage.paper(1920, 1080).name == "Narrow") // a page found that long and narrow is one
        #expect(PhotoPage.paper(1414, 1000, foundPage: false).name == "A4")
    }

    @Test func theSameFrameIsNeverTakenTwice() async {
        let session = CameraSession()
        let still = FakeFeed(Self.gray(640, 480), fixedNumber: 7) // a held key, or a camera that sent nothing new
        #expect(await session.capture(still))
        #expect(await !session.capture(still))
        #expect(session.pagesTaken == 1)
    }

    @Test func framesWaitAtMostTwoAndCaptureIsOffTillThePCCatchesUp() async {
        let session = CameraSession()
        let feed = FakeFeed(Self.gray(640, 480))
        for _ in 0..<CameraSession.waiting { #expect(await session.capture(feed)) }
        #expect(!session.canCapture)
        #expect(session.statusText() == "Wait a moment: the Mac is making pages of the last captures.")
        #expect(await !session.capture(feed)) // refused, and not counted
        #expect(session.pagesTaken == CameraSession.waiting)
        #expect(session.photos.tryRead() != nil)
        #expect(session.canCapture)
        #expect(await session.capture(feed))
        #expect(session.pagesTaken == CameraSession.waiting + 1)
    }

    @Test func aScanTakesAtMostItsLimitOfPages() async {
        let session = CameraSession()
        let feed = FakeFeed(Picture([UInt8](repeating: 0, count: 640 * 480 * 3), 640, 480, 3))
        for _ in 0..<CameraSession.maxPages {
            #expect(await session.capture(feed))
            #expect(session.photos.tryRead() != nil)
        }
        #expect(await !session.capture(feed))
        #expect(!session.canCapture)
        #expect(session.statusText() == "That's the most pages one scan takes: press Done, then start another.")
    }

    // ---------------------------------------------------------------- Mac only: the channel between them

    @Test func theChannelHandsPhotosOverInOrderAndEndsAtFinish() async {
        let channel = PhotoChannel(capacity: 1)
        #expect(channel.tryWrite(CapturedPhoto(data: [1])))
        #expect(!channel.tryWrite(CapturedPhoto(data: [2]))) // full
        let writer = Task { await channel.write(CapturedPhoto(data: [3])) } // waits for room
        #expect(await channel.read()?.data == [1])
        #expect(await channel.read()?.data == [3])
        #expect(await writer.value)
        channel.finish()
        #expect(await channel.read() == nil)
        #expect(await !channel.write(CapturedPhoto(data: [4])))
        // A reader waiting when it ends is told; a cancelled one too.
        let other = PhotoChannel(capacity: 2)
        let waiting = Task { await other.read() }
        try? await Task.sleep(for: .milliseconds(20))
        other.finish()
        #expect(await waiting.value == nil)
        let third = PhotoChannel(capacity: 2)
        let cancelled = Task { await third.read() }
        cancelled.cancel()
        #expect(await cancelled.value == nil)
    }
}
