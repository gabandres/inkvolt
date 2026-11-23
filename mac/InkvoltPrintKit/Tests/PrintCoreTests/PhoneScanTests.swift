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

    // ---------------------------------------------------------------- the phone session

    private static let phone = "192.0.2.20", other = "192.0.2.21"

    /// Counts the bodies read.
    private final class Reads: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.withLock { n += 1 } }
        var count: Int { lock.withLock { n } }
    }

    private static func ask(_ s: PhoneSession, _ method: String, _ path: String, peer: String = phone, cookie: String? = nil, fromPage: Bool = true,
                            body: [UInt8] = [], reads: Reads? = nil) async -> PhoneReply {
        await s.handle(PhoneRequest(method, path, peer: peer, cookie: cookie, fromPage: fromPage)) { max in
            reads?.bump()
            return body.count > max ? nil : body
        }
    }

    private static func cookie(of reply: PhoneReply) -> String {
        String(reply.setCookie!.split(separator: ";")[0].split(separator: "=", maxSplits: 1)[1])
    }

    private static func text(_ reply: PhoneReply) -> String { String(decoding: reply.body ?? [], as: UTF8.self) }

    @Test func onlyTheTokenReachesThePageAndNothingElseIsThere() async {
        let s = PhoneSession("<OFFICE-MAC>")
        #expect(s.token.count == 43)
        #expect(s.token != PhoneSession("x").token)
        let page = await Self.ask(s, "GET", s.pagePath, fromPage: false)
        #expect(page.status == 200)
        let html = Self.text(page)
        #expect(html.contains("&lt;OFFICE-MAC&gt;"))
        #expect(!html.contains("<OFFICE-MAC>"))
        #expect(html.contains("capture=\"environment\""))
        let csp = page.contentSecurityPolicy ?? ""
        let nonce = csp.components(separatedBy: "'nonce-")[1].components(separatedBy: "'")[0]
        #expect(html.contains("<script nonce=\"\(nonce)\">"))
        #expect(csp.contains("default-src 'none'"))
        let again = await Self.ask(s, "GET", s.pagePath).contentSecurityPolicy ?? ""
        #expect(nonce != again.components(separatedBy: "'nonce-")[1].components(separatedBy: "'")[0])

        let paths = ["/", "/p/", "/p", "/p/" + String(s.token.dropLast()), "/p/" + s.token + "x", "/p/" + s.token.uppercased(), s.pagePath + "/other",
                     s.pagePath + "/../", "/favicon.ico", "/p/" + String(repeating: "a", count: 500)]
        for path in paths { #expect(await Self.ask(s, "GET", path).status == 404, "\(path)") }
        #expect(await Self.ask(s, "POST", s.pagePath).status == 405)
        #expect(await Self.ask(s, "GET", s.pagePath + "/photo").status == 405)
        #expect(s.state == .waiting)
    }

    @Test func theFirstPhoneToPairIsTheOnlyOneThatCanSend() async {
        let s = PhoneSession("Mac")
        // Not the page's script (a form from elsewhere): refused, and nothing paired.
        #expect(await Self.ask(s, "POST", s.pagePath + "/pair", fromPage: false).status == 403)
        let paired = await Self.ask(s, "POST", s.pagePath + "/pair")
        #expect(paired.status == 200)
        let set = paired.setCookie ?? ""
        #expect(set.contains("HttpOnly") && set.contains("Secure") && set.contains("SameSite=Strict") && set.contains("Path=\(s.pagePath)"))
        let cookie = Self.cookie(of: paired)
        #expect(s.state == .paired)

        // Another device that scanned the same code: told it's used, can't send; nor can the phone's cookie from another address.
        #expect(await Self.ask(s, "POST", s.pagePath + "/pair", peer: Self.other).status == 403)
        let reads = Reads()
        let photo = Self.jpegHeader(800, 600)
        let wrong = String(cookie.dropLast()) + (cookie.last == "A" ? "B" : "A")
        #expect(await Self.ask(s, "POST", s.pagePath + "/photo", peer: Self.other, cookie: cookie, body: photo, reads: reads).status == 403)
        #expect(await Self.ask(s, "POST", s.pagePath + "/photo", cookie: wrong, body: photo, reads: reads).status == 403)
        #expect(await Self.ask(s, "POST", s.pagePath + "/photo", cookie: nil, body: photo, reads: reads).status == 403)
        #expect(await Self.ask(s, "POST", s.pagePath + "/photo", cookie: cookie, fromPage: false, body: photo, reads: reads).status == 403)
        #expect(await Self.ask(s, "POST", s.pagePath + "/done", peer: Self.other, cookie: cookie).status == 403)
        #expect(reads.count == 0) // none of their bodies was read
        #expect(s.received == 0)

        // The phone pairs again on a reload, and sends.
        #expect(await Self.ask(s, "POST", s.pagePath + "/pair", cookie: cookie).status == 200)
        let sent = await Self.ask(s, "POST", s.pagePath + "/photo", cookie: cookie, body: photo)
        #expect(sent.status == 200)
        #expect(Self.text(sent).contains("\"pages\":1"))
        #expect(s.photos.tryRead()?.data == photo)
    }

    @Test func photosAreBoundedInSizeKindAndCountAndDoneEndsTheScan() async {
        let s = PhoneSession("Mac", limits: PhoneLimits(maxPhotos: 2, maxPhotoBytes: 1000, waiting: 4))
        let cookie = Self.cookie(of: await Self.ask(s, "POST", s.pagePath + "/pair"))
        func send(_ body: [UInt8]) async -> Int { await Self.ask(s, "POST", s.pagePath + "/photo", cookie: cookie, body: body).status }
        #expect(await send(Self.jpegHeader(800, 600) + [UInt8](repeating: 0, count: 1000)) == 413)
        #expect(await send(Array("<html>not a photo</html>..........".utf8)) == 415)
        #expect(await send(Self.jpegHeader(20_000, 600)) == 415)
        #expect(await send(Self.jpegHeader(800, 600)) == 200)
        #expect(await send(Self.pngHeader(600, 800)) == 200)
        #expect(await send(Self.jpegHeader(800, 600)) == 429)
        #expect(s.received == 2)

        let changed = Reads()
        s.onChange { changed.bump() }
        let done = await Self.ask(s, "POST", s.pagePath + "/done", cookie: cookie)
        #expect(done.status == 200)
        #expect(s.state == .finished)
        #expect(changed.count == 1)
        // The photos sent before Done are still read, then the scan ends.
        var left = 0
        while await s.photos.read() != nil { left += 1 }
        #expect(left == 2)
        #expect(await Self.ask(s, "POST", s.pagePath + "/pair", cookie: cookie).status == 410)
    }

    @Test func endingTheScanOnTheMacRefusesWhatThePhoneSendsNext() async {
        let s = PhoneSession("Mac")
        let cookie = Self.cookie(of: await Self.ask(s, "POST", s.pagePath + "/pair"))
        s.finish()
        s.finish()
        #expect(await Self.ask(s, "POST", s.pagePath + "/photo", cookie: cookie, body: Self.jpegHeader(800, 600)).status == 410)
        #expect(s.photos.isFinished)
        // A code no phone paired with, once ended, pairs nobody.
        let unpaired = PhoneSession("Mac")
        unpaired.finish()
        #expect(await Self.ask(unpaired, "POST", unpaired.pagePath + "/pair").status == 410)
    }

    @Test func theMacSaysWhereThePhoneStands() {
        #expect(PhoneScan.statusText(.waiting, 0) == "Waiting for your phone: point its camera at the code and open the link it shows.")
        #expect(PhoneScan.statusText(.paired, 0) == "Phone connected. Take a photo of each page; tap Done on the phone, or Done here, when you've finished.")
        #expect(PhoneScan.statusText(.paired, 1) == "Phone connected: 1 page in. Tap Done on the phone, or Done here, when you've finished.")
        #expect(PhoneScan.statusText(.paired, 3) == "Phone connected: 3 pages in. Tap Done on the phone, or Done here, when you've finished.")
        #expect(PhoneScan.statusText(.finished, 0) == "Done: 0 pages came from the phone.")
    }

    /// Adapted: macOS has no Private/Public network setting, so a served network is a private (RFC 1918) IPv4 one with a
    /// real subnet; the address is the first macOS lists (Ethernet and Wi-Fi first).
    @Test func theAddressIsThePrivateNetworksIPv4One() {
        let all = [LocalNetwork("203.0.113.5", 24), LocalNetwork("10.0.0.4", 24), LocalNetwork("192.168.1.30", 24), LocalNetwork("10.9.9.9", 32)]
        let served = PhonePeers.served(all)
        #expect(served.map(\.address) == ["10.0.0.4", "192.168.1.30"])
        #expect(PhoneScan.address(for: served) == "10.0.0.4")
        #expect(PhoneScan.address(for: []) == nil)
        let s = PhoneSession("Mac")
        #expect(PhoneScan.url("10.0.0.4", PhoneScan.defaultPort, s) == "https://10.0.0.4:9781/p/\(s.token)")
    }

    // ---------------------------------------------------------------- opening a scan

    private struct FakeNetworks: PhoneNetworks {
        let networks: [LocalNetwork]
        func read() -> [LocalNetwork] { networks }
    }

    private struct FakeCertificate: PhoneCertificate {
        var fingerprint: String { "AB:CD" }
    }

    private struct FakeCertificates: PhoneCertificates {
        func get(hostName: String, now: Date) throws -> any PhoneCertificate { FakeCertificate() }
    }

    /// A host whose listener can't say its port, and says whether it was closed.
    private final class BrokenHost: PhoneHost, @unchecked Sendable {
        private let lock = NSLock()
        private var wasClosed = false
        var closed: Bool { lock.withLock { wasClosed } }

        func start(_ listen: PhoneListen) async throws -> any PhoneListener { Listener(host: self) }

        func close() { lock.withLock { wasClosed = true } }

        struct Listener: PhoneListener {
            let host: BrokenHost
            var port: Int? { nil }
            func close() async { host.close() }
        }
    }

    /// A host that starts on the port asked, or says it's taken.
    private struct TakenHost: PhoneHost {
        func start(_ listen: PhoneListen) async throws -> any PhoneListener { throw PhoneHostError.portInUse }
    }

    @Test func aFailureAfterTheServerStartedLeavesNothingListening() async {
        let host = BrokenHost()
        let opening = await PhoneScan.open(.thisMacOnly(host, certificates: FakeCertificates()), macName: "Mac")
        #expect(opening.link == nil)
        #expect(opening.problem == "Scanning with your phone couldn't start. Try again; if it still doesn't start, restart Inkvolt Print.")
        #expect(host.closed)
        let taken = await PhoneScan.open(PhoneEnvironment(host: TakenHost(), networks: FakeNetworks(networks: [LocalNetwork("192.168.1.30", 24)]),
                                                          certificates: FakeCertificates()), macName: "Mac")
        #expect(taken.problem == "Another app uses port 9781, which scanning with your phone needs. Quit it and try again.")
    }

    @Test func thePageSaysTheCertificateWarningWasExpected() async {
        let s = PhoneSession("OFFICE-MAC")
        let html = Self.text(await Self.ask(s, "GET", s.pagePath))
        #expect(html.contains(PhonePage.html("The warning before this page was expected: OFFICE-MAC made its own certificate for it.")))
    }

    @Test func noPrivateNetworkOpensNothing() async {
        let env = PhoneEnvironment(host: BrokenHost(), networks: FakeNetworks(networks: [LocalNetwork("203.0.113.5", 24)]), certificates: FakeCertificates())
        let opening = await PhoneScan.open(env, macName: "Mac")
        #expect(opening.link == nil)
        #expect(opening.problem == "Your phone can send pages only over a private network, and this Mac isn't on one. Join your home or office Wi-Fi or Ethernet, then try again.")
    }

    // ---------------------------------------------------------------- Mac only: who may connect, HTTP, the certificate

    @Test func onlyDevicesOnAServedSubnetOrThisMacMayConnect() {
        let served = [LocalNetwork("192.168.1.30", 24)]
        #expect(PhonePeers.allows("192.168.1.20", local: nil, served))
        #expect(PhonePeers.allows("::ffff:192.168.1.20", local: "192.168.1.30", served))
        #expect(!PhonePeers.allows("192.168.1.20", local: "10.0.0.4", served)) // came in on another address
        #expect(!PhonePeers.allows("192.168.2.20", local: nil, served))
        #expect(!PhonePeers.allows("192.168.1.30", local: nil, served)) // this Mac's own address isn't a phone
        #expect(!PhonePeers.allows("fe80::1%en0", local: nil, served))
        #expect(!PhonePeers.allows("not an address", local: nil, served))
        #expect(PhonePeers.allows("127.0.0.1", local: "127.0.0.1", []))
        #expect(!PhonePeers.allows("127.0.0.1", local: "192.168.1.30", served))
        let counted = PhoneConnections()
        for _ in 0..<PhoneConnections.maxPerPeer { #expect(counted.enter("192.168.1.20")) }
        #expect(!counted.enter("::ffff:192.168.1.20"))
        counted.leave("192.168.1.20")
        #expect(counted.enter("192.168.1.20"))
        for i in 0..<(PhoneConnections.maxConnections - PhoneConnections.maxPerPeer) { #expect(counted.enter("192.168.1.\(40 + i)")) }
        #expect(!counted.enter("192.168.1.99"))
        #expect(counted.open == PhoneConnections.maxConnections)
    }

    /// Mac only (the review): as Kestrel, the idle minute is for a head's first byte; from it, the whole head has
    /// `headTimeout`, so a head trickled a byte at a time can't hold a connection for the minute.
    @Test func aTrickledHeadHasFifteenSecondsFromItsFirstByte() async {
        final class Trickle: PhoneConnectionIO, @unchecked Sendable {
            private let lock = NSLock()
            private var left: [UInt8] = Array("GET /x HTTP/1.1\r\nHost: a\r\n\r\n".utf8)
            private(set) var timeouts: [Duration] = []
            func receive(max: Int, timeout: Duration) async -> [UInt8]? {
                lock.withLock {
                    timeouts.append(timeout)
                    return left.isEmpty ? nil : [left.removeFirst()]
                }
            }
            func send(_ bytes: [UInt8]) async -> Bool { true }
        }
        let io = Trickle()
        var buffer: [UInt8] = []
        guard case .head = await PhoneHttp.readHead(io, &buffer, timeout: PhoneHttp.idleTimeout) else {
            Issue.record("the head wasn't read")
            return
        }
        let seen: [Duration] = io.timeouts
        #expect(seen.first! > PhoneHttp.headTimeout)
        #expect(seen.dropFirst().allSatisfy { (t: Duration) -> Bool in t <= PhoneHttp.headTimeout })
    }

    /// A connection fed from a script: what the phone sends, in the pieces given, and what the server wrote.
    private final class FakeConnection: PhoneConnectionIO, @unchecked Sendable {
        private let lock = NSLock()
        private var incoming: [[UInt8]]
        private var out: [UInt8] = []
        init(_ pieces: [[UInt8]]) { incoming = pieces }

        func receive(max: Int, timeout: Duration) async -> [UInt8]? {
            lock.withLock {
                guard !incoming.isEmpty else { return nil }
                var piece = incoming.removeFirst()
                if piece.count > max {
                    incoming.insert(Array(piece[max...]), at: 0)
                    piece = Array(piece[..<max])
                }
                return piece
            }
        }

        func send(_ bytes: [UInt8]) async -> Bool {
            lock.withLock { out += bytes }
            return true
        }

        var written: String { lock.withLock { String(decoding: out, as: UTF8.self) } }
        var statuses: [Int] {
            written.components(separatedBy: "HTTP/1.1 ").dropFirst().compactMap { Int($0.prefix(3)) }
        }
    }

    private static func request(_ method: String, _ path: String, _ headers: [String] = [], body: [UInt8] = []) -> [UInt8] {
        let lines = ["\(method) \(path) HTTP/1.1", "Host: 192.168.1.30:9781"] + headers + (body.isEmpty ? [] : ["Content-Length: \(body.count)"])
        return Array((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8) + body
    }

    @Test func aPhoneWalksThroughPairPhotoAndDoneOverOneConnection() async {
        let s = PhoneSession("Mac")
        let pairing = FakeConnection([Self.request("GET", s.pagePath + "?x=1"), Self.request("POST", s.pagePath + "/pair", ["X-Inkvolt-Phone: 1"])])
        await PhoneHttp.serve(pairing, peer: Self.phone, session: s)
        #expect(pairing.statuses == [200, 200])
        #expect(pairing.written.contains("Content-Security-Policy: default-src 'none'"))
        #expect(pairing.written.contains("X-Content-Type-Options: nosniff") && pairing.written.contains("Referrer-Policy: no-referrer"))
        let setCookie = pairing.written.components(separatedBy: "Set-Cookie: \(PhoneSession.cookieName)=")[1]
        let cookie = String(setCookie.prefix { $0 != ";" })
        // The photo in pieces, a head split across reads; then Done.
        let photo = Self.jpegHeader(1600, 1200)
        let send = Self.request("POST", s.pagePath + "/photo", ["X-Inkvolt-Phone: 1", "Cookie: other=1; \(PhoneSession.cookieName)=\(cookie)"], body: photo)
        let done = Self.request("POST", s.pagePath + "/done", ["x-inkvolt-phone: 1", "Cookie: \(PhoneSession.cookieName)=\(cookie)"])
        let sending = FakeConnection([Array(send[..<10]), Array(send[10..<60]), Array(send[60...]), done])
        await PhoneHttp.serve(sending, peer: Self.phone, session: s)
        #expect(sending.statuses == [200, 200])
        #expect(s.received == 1)
        #expect(s.state == .finished)
        #expect(s.photos.tryRead()?.data == photo)
    }

    @Test func aHeadThatIsntHttpIsRefusedAndTheConnectionClosed() async throws {
        let s = PhoneSession("Mac")
        let cases: [([UInt8], Int)] = [
            (Array("GET http://evil.example/p/x HTTP/1.1\r\n\r\n".utf8), 400),
            (Array("GET /p/x HTTP/2.0\r\n\r\n".utf8), 505),
            (Array("get /p/x HTTP/1.1\r\n\r\n".utf8), 400),
            (Array("GET /p/x HTTP/1.1\r\nHost: a\r\n folded\r\n\r\n".utf8), 400),
            (Array("GET /p/x HTTP/1.1\r\nNo colon\r\n\r\n".utf8), 400),
            (Array("GET /p/\u{7F}x HTTP/1.1\r\n\r\n".utf8), 400),
            ([0x47, 0x45, 0x54, 0x20, 0x2F, 0x00, 0x20] + Array("HTTP/1.1\r\n\r\n".utf8), 400),
            (Array("POST /p/x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8), 411),
            (Array("POST /p/x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 6\r\n\r\n".utf8), 400),
            (Array("POST /p/x HTTP/1.1\r\nContent-Length: -5\r\n\r\n".utf8), 400),
            (Array(("GET /" + String(repeating: "a", count: PhoneHttp.maxRequestLine) + " HTTP/1.1\r\n\r\n").utf8), 414),
            (Array(("GET /p/x HTTP/1.1\r\n" + String(repeating: "A: b\r\n", count: PhoneHttp.maxHeaders + 1) + "\r\n").utf8), 431),
            (Array(("GET /p/x HTTP/1.1\r\nA: " + String(repeating: "b", count: PhoneHttp.maxHead) + "\r\n\r\n").utf8), 431),
        ]
        for (bytes, status) in cases {
            let c = FakeConnection([bytes, Self.request("GET", s.pagePath)])
            await PhoneHttp.serve(c, peer: Self.phone, session: s)
            #expect(c.statuses == [status], "\(String(decoding: bytes.prefix(60), as: UTF8.self))")
            #expect(c.written.contains("Connection: close"))
        }
        // A head that never ends: the connection closes once nothing more comes.
        let cut = FakeConnection([Array("GET /p/x HTTP/1.1\r\nHost:".utf8)])
        await PhoneHttp.serve(cut, peer: Self.phone, session: s)
        #expect(cut.statuses == [408])
        let head = try PhoneHttp.parse(Array("GET /p/a?b HTTP/1.1\r\nCookie: a=1; inkvolt-phone=xyz\r\nCookie: c=2".utf8))
        #expect(head.path == "/p/a" && head.cookie("inkvolt-phone") == "xyz" && head.cookie("c") == "2" && head.cookie("d") == nil)
    }

    @Test func aBodyRefusedOrTooLongIsNeverReadAndClosesTheConnection() async {
        let s = PhoneSession("Mac", limits: PhoneLimits(maxPhotoBytes: 1000))
        let pair = FakeConnection([Self.request("POST", s.pagePath + "/pair", ["X-Inkvolt-Phone: 1"])])
        await PhoneHttp.serve(pair, peer: Self.phone, session: s)
        let cookie = String(pair.written.components(separatedBy: "\(PhoneSession.cookieName)=")[1].prefix { $0 != ";" })
        // Declared past the limit: 413 before a byte is read, and the next request on the connection isn't taken.
        let big = Array("POST \(s.pagePath)/photo HTTP/1.1\r\nX-Inkvolt-Phone: 1\r\nCookie: \(PhoneSession.cookieName)=\(cookie)\r\nContent-Length: 5000\r\n\r\n".utf8)
        let tooLong = FakeConnection([big, Self.request("GET", s.pagePath)])
        await PhoneHttp.serve(tooLong, peer: Self.phone, session: s)
        #expect(tooLong.statuses == [413])
        // From another device: refused unread, and closed (its body isn't taken for a request).
        let stranger = FakeConnection([Self.request("POST", s.pagePath + "/photo", ["X-Inkvolt-Phone: 1"], body: Self.jpegHeader(800, 600)),
                                       Self.request("GET", s.pagePath)])
        await PhoneHttp.serve(stranger, peer: Self.other, session: s)
        #expect(stranger.statuses == [403])
        #expect(stranger.written.contains("Connection: close"))
        // A body cut off: nothing is answered, nothing is taken.
        let cut = FakeConnection([Array(Self.request("POST", s.pagePath + "/photo", ["X-Inkvolt-Phone: 1", "Cookie: \(PhoneSession.cookieName)=\(cookie)"],
                                                     body: Self.jpegHeader(800, 600)).dropLast(5))])
        await PhoneHttp.serve(cut, peer: Self.phone, session: s)
        #expect(cut.statuses.isEmpty)
        #expect(s.received == 0)
        // HEAD: the headers, no body.
        let head = FakeConnection([Self.request("HEAD", s.pagePath)])
        await PhoneHttp.serve(head, peer: Self.phone, session: s)
        #expect(head.statuses == [200] && head.written.hasSuffix("Content-Length: 0\r\n\r\n"))
    }

    @Test func theCertificateIsAnX509ServerCertificateForThisMacsName() {
        let point: [UInt8] = [4] + [UInt8](repeating: 0x11, count: 64)
        let now = Date(timeIntervalSince1970: 1_795_000_000) // 2026-11
        let tbs = PhoneCertificateDer.tbs(publicKey: point, hostName: PhoneScan.hostName("Ana's MacBook Air"), serial: [0xFF, 1, 2], now: now)
        let cert = PhoneCertificateDer.certificate(tbs: tbs, signature: [0x30, 0x06, 0x02, 0x01, 0x01, 0x02, 0x01, 0x01])
        #expect(cert.first == 0x30 && tbs.first == 0x30)
        func has(_ needle: [UInt8], _ hay: [UInt8]) -> Bool {
            guard hay.count >= needle.count else { return false }
            return (0...(hay.count - needle.count)).contains { Array(hay[$0..<($0 + needle.count)]) == needle }
        }
        #expect(has([0xA0, 0x03, 0x02, 0x01, 0x02], tbs)) // v3
        #expect(has([0x02, 0x03, 0x7F, 0x01, 0x02], tbs)) // the serial, made positive
        #expect(has(Array("Ana-s-MacBook-Air.local".utf8), tbs))
        #expect(has([0x17, 0x0D] + Array("261117".utf8), tbs) && has([0x17, 0x0D] + Array("290220".utf8), tbs)) // a day before, 825 days after
        #expect(has([0x03, 0x42, 0x00] + point, tbs))
        #expect(has([0x06, 0x08, 0x2B, 0x06, 0x01, 0x05, 0x05, 0x07, 0x03, 0x01], tbs)) // serverAuth
        #expect(has(tbs, cert))
        #expect(PhoneCertificateDer.usable(notBefore: now.addingTimeInterval(-86_400), notAfter: now.addingTimeInterval(PhoneCertificateDer.life), now: now))
        #expect(!PhoneCertificateDer.usable(notBefore: now, notAfter: now.addingTimeInterval(20 * 86_400), now: now))
        #expect(PhoneCertificateDer.fingerprint([0xAB, 0x01]) == "AB:01")
        #expect(PhoneScan.hostName("") == "mac.local")
    }
}
