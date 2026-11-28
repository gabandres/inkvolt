import Foundation
import Synchronization
import Testing
import TestTiming
@testable import PrintCore

/// Ported from ScannerSharingTests.cs. Sharing a scanner on the network (print/ROADMAP.md 3.1): the eSCL documents served
/// and read (ScanSettings as hostile input), the jobs (one scan at a time, a queue limit, each job only its device's,
/// expiry), who may connect, the certificate and the DNS-SD record, the switch (off by default, private networks only,
/// free, closing at once), and scans through the server's HTTP with our own eSCL client, page for page the same as the
/// direct scan. Adapted: the scanner is an ImageCaptureCore one (`ConnectedScanner` over a fake `ScanDevice`, Windows'
/// `FakeWiaScanner`), which scans color or grey (no black and white) and whose driver gets an area in inches
/// (`ScanArea`, Windows' `WiaCapabilities.Plan`); peers are IPv4 on networks with a private address (macOS has no
/// Private/Public setting); a request is a task the test cancels (Windows' token), answered 503; the HTTPS server, its
/// certificate in a keychain and Bonjour are PrintMac's (`ScannerShareServerTests`, on the Mac).
// On the cooperative pool, not `.offThePool`: its work is short and waits on the fake scanner with a time limit, and the
// utility queue the CPU-heavy suites share held it there for minutes on CI's runner (master's run 46107311430: "Timed out
// waiting" in disposedItAnswersNothingAndLetsTheScannerGo, after 224 s behind PageCleanupTests and CleanUpMarksTests).
@Suite
struct ScannerSharingTests {
    static let usb = SystemScanner(id: "0x00110000046d0a00", name: "Example Scan 300", usb: true)

    /// Glass and a feeder (both sides), 8.5 × 11.69 in glass, 8.5 × 14 in sheets, 75–1200 dpi, grey and color.
    static func mfp(platen: Bool = true, adf: Bool = true, duplex: Bool = true, resolutions: [Int] = [75, 100, 150, 200, 300, 400, 600, 1200])
        -> ScannerCapabilities {
        let glass = InputCaps(minWidth: 300, maxWidth: 2550, minHeight: 300, maxHeight: 3507, colorModes: ["RGB24", "Grayscale8"], resolutions: resolutions)
        let feeder = InputCaps(minWidth: 300, maxWidth: 2550, minHeight: 300, maxHeight: 4200, colorModes: ["RGB24", "Grayscale8"], resolutions: resolutions)
        return ScannerCapabilities(makeAndModel: "Example Scan 300", platen: platen ? glass : nil, adf: adf ? feeder : nil, adfDuplex: adf && duplex)
    }

    /// A scanner macOS would drive: the glass gives one page, the feeder three. Each page: a JPEG header (start of image, a
    /// 16 × 16 color frame) and what was asked of the driver with its number in the job, bytes a test compares. `hangs`: the
    /// driver never gives a page until the scan is cancelled; `failAtPage`: it stops with an error there.
    final class FakeScanner: ScanDevice, @unchecked Sendable {
        let caps: ScannerCapabilities
        private let lock = NSLock()
        private var hanging = false, failing: Int?
        private var asked: [String] = []

        init(_ caps: ScannerCapabilities = ScannerSharingTests.mfp()) { self.caps = caps }

        var hangs: Bool {
            get { lock.withLock { hanging } }
            set { lock.withLock { hanging = newValue } }
        }

        var failAtPage: Int? {
            get { lock.withLock { failing } }
            set { lock.withLock { failing = newValue } }
        }

        /// What the driver was asked for, page by page.
        var transfers: [String] {
            get { lock.withLock { asked } }
            set { lock.withLock { asked = newValue } }
        }

        static func page(_ asked: String) -> [UInt8] {
            [0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x11, 0x08, 0x00, 0x10, 0x00, 0x10, 0x03, 1, 0x11, 0, 2, 0x11, 0, 3, 0x11, 0] + Array(asked.utf8) + [0xFF, 0xD9]
        }

        func capabilities() async throws -> ScannerCapabilities? { caps }

        func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error> {
            let (hangs, failAt) = lock.withLock { (hanging, failing) }
            return AsyncThrowingStream { continuation in
                let task = Task {
                    if hangs {
                        while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
                        continuation.finish(throwing: CancellationError())
                        return
                    }
                    let side = self.caps.input(for: request.source)
                    let area = ScanArea.of(request, sourceWidth: Double(side?.maxWidth ?? 0) / 300, sourceHeight: Double(side?.maxHeight ?? 0) / 300)
                    let dpi = side.map { EsclXml.resolution(request, $0) } ?? request.resolution
                    for n in 0..<(request.source == .platen ? 1 : 3) {
                        if failAt == n {
                            continuation.finish(throwing: ScanError("Paper jam in the feeder."))
                            return
                        }
                        let asked = "\(request.source) \(request.color) \(dpi) \(area.x) \(area.y) \(area.width) \(area.height)|\(n)"
                        self.lock.withLock { self.asked.append(asked) }
                        continuation.yield(Self.page(asked))
                    }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    static func open(_ fake: FakeScanner, _ scanner: SystemScanner = usb) -> ConnectedScanner {
        ConnectedScanner(scanner, device: fake, capabilities: fake.caps)
    }

    /// Every page of a scan; throws when the scan stops or the task is cancelled.
    static func all(_ pages: AsyncThrowingStream<[UInt8], any Error>) async throws -> [[UInt8]] {
        var list: [[UInt8]] = []
        for try await p in pages { list.append(p) }
        try Task.checkCancellation()
        return list
    }

    static let identity = ShareIdentity("Example Scan 300", "Example", UUID(uuidString: "0f6b3d2a-7c1e-4c55-9a51-2b8e44d1c0aa")!)
    static let peer = "192.0.2.20", otherPeer = "192.0.2.21"

    static func settings(_ inner: String) -> [UInt8] {
        Array(("<?xml version=\"1.0\" encoding=\"UTF-8\"?><scan:ScanSettings xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\" "
            + "xmlns:pwg=\"http://www.pwg.org/schemas/2010/12/sm\"><pwg:Version>2.63</pwg:Version>" + inner + "</scan:ScanSettings>").utf8)
    }

    static func ask(_ s: SharedScanner, _ method: String, _ path: String, _ body: [UInt8] = [], peer: String = peer) async -> ShareReply {
        await s.handle(ShareRequest(method, path, body: body, peer: peer, authority: "192.0.2.10:9780"))
    }

    static func jobPath(_ reply: ShareReply) -> String { URL(string: reply.location ?? "")?.path ?? "" }

    static func xml(_ reply: ShareReply) throws -> XmlElement { try DeviceXml.load(reply.body ?? []) }

    static func values(_ e: XmlElement, _ name: String) -> [String] { e.all(name).map(\.value) }

    static func waitFor(_ condition: @Sendable () -> Bool) async {
        let until = Date().addingTimeInterval(Timing.limit(5.0))
        while !condition() {
            if Date() > until {
                Issue.record("Timed out waiting.")
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// A clock the test moves by hand (the sweep also runs on each request).
    final class ManualTime: Sendable {
        private let at = Mutex(Date(timeIntervalSince1970: 1_795_000_000))
        var now: @Sendable () -> Date { { self.at.withLock { $0 } } }
        func advance(_ seconds: TimeInterval) { at.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }

    // ---------------------------------------------------------------- the documents

    @Test func capabilitiesReadBackAsTheScannersOwn() throws {
        let own = Self.mfp()
        let read = ScannerCapabilities.parse(try DeviceXml.load(ShareXml.capabilities(own, Self.identity)))
        #expect(read.sources == own.sources)
        #expect(read.makeAndModel == "Example Scan 300")
        #expect(read.manufacturer == "Example")
        #expect(read.uuid == "0f6b3d2a-7c1e-4c55-9a51-2b8e44d1c0aa")
        for (mine, theirs) in [(own.platen!, read.platen!), (own.adf!, read.adf!)] {
            let sizes: [Int] = [mine.minWidth, mine.maxWidth, mine.minHeight, mine.maxHeight]
            let read: [Int] = [theirs.minWidth, theirs.maxWidth, theirs.minHeight, theirs.maxHeight]
            #expect(sizes == read)
            #expect(mine.colorModes == theirs.colorModes)
            #expect(mine.resolutions == theirs.resolutions)
            #expect(theirs.offersJpeg)
            #expect(theirs.documentFormats.contains("application/pdf"))
            #expect(theirs.hasDocumentFormatExt)
        }
        #expect(read.adfDuplex)
    }

    @Test func settingsOurClientWritesReadBackAsTheSameScan() throws {
        let caps = Self.mfp()
        for request in [ScanRequest(source: .platen, color: .color, resolution: 300), ScanRequest(source: .adf, color: .grayscale, resolution: 200),
                        ScanRequest(source: .adfDuplex, color: .grayscale, resolution: 600, intent: "Photo", width: 1200, height: 1500)] {
            let body = Array(try #require(EsclXml.buildScanSettings(request, caps)).utf8)
            let read = try ShareXml.readSettings(body, caps)
            let input = try #require(caps.input(for: request.source))
            #expect(read.request.source == request.source)
            #expect(read.request.color == request.color)
            #expect(read.request.resolution == request.resolution)
            #expect(read.request.width == (request.width ?? input.maxWidth))
            #expect(read.request.height == (request.height ?? input.maxHeight))
            #expect(read.format == "image/jpeg")
            // Planned for the driver, the same as the direct scan.
            let (w, h) = (Double(input.maxWidth) / 300, Double(input.maxHeight) / 300)
            #expect(ScanArea.of(request, sourceWidth: w, sourceHeight: h) == ScanArea.of(read.request, sourceWidth: w, sourceHeight: h))
        }
    }

    @Test func aRegionWithAnOffsetReachesTheDriver() throws {
        let caps = Self.mfp()
        let read = try ShareXml.readSettings(Self.settings(
            "<pwg:ScanRegions><pwg:ScanRegion><pwg:Height>900</pwg:Height><pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>"
                + "<pwg:Width>600</pwg:Width><pwg:XOffset>300</pwg:XOffset><pwg:YOffset>150</pwg:YOffset></pwg:ScanRegion></pwg:ScanRegions>"
                + "<pwg:InputSource>Platen</pwg:InputSource><scan:ColorMode>RGB24</scan:ColorMode><scan:XResolution>200</scan:XResolution>"
                + "<scan:YResolution>200</scan:YResolution><pwg:DocumentFormat>application/pdf</pwg:DocumentFormat>"), caps)
        #expect(read.format == "application/pdf")
        let area = ScanArea.of(read.request, sourceWidth: 8.5, sourceHeight: 3507.0 / 300)
        #expect(area == ScanArea(x: 1, y: 0.5, width: 2, height: 3)) // inches, as ImageCaptureCore takes them
        // An offset past the source is kept inside it, and the width shrinks to what's left.
        let far = ScanArea.of(ScanRequest(resolution: 300, width: 2550, xOffset: 2500), sourceWidth: 8.5, sourceHeight: 3507.0 / 300)
        #expect(abs(far.x - 2500.0 / 300) < 1e-9 && abs(far.width - 50.0 / 300) < 1e-9)
    }

    @Test(arguments: [
        ("<!DOCTYPE x [<!ENTITY a \"aaaa\">]>", 400), // a DTD: refused before anything is expanded
        ("<scan:Intent>&a;</scan:Intent>", 400), // an entity it never declared
        ("<pwg:InputSource>Camera</pwg:InputSource>", 409),
        ("<scan:ColorMode>CMYK32</scan:ColorMode>", 409),
        ("<scan:ColorMode>BlackAndWhite1</scan:ColorMode>", 409), // Mac: color or grey only
        ("<pwg:DocumentFormat>image/tiff</pwg:DocumentFormat>", 409),
        ("<scan:XResolution>-5</scan:XResolution>", 400),
        ("<scan:XResolution>99999999999</scan:XResolution>", 400),
        ("<scan:XResolution>3e2</scan:XResolution>", 400),
        ("<pwg:ScanRegions><pwg:ScanRegion><pwg:ContentRegionUnits>escl:Millimeters</pwg:ContentRegionUnits></pwg:ScanRegion></pwg:ScanRegions>", 400),
        ("<pwg:ScanRegions><pwg:ScanRegion><pwg:Width>0</pwg:Width></pwg:ScanRegion></pwg:ScanRegions>", 400),
    ])
    func hostileOrUnofferedSettingsAreRefused(_ inner: String, _ status: Int) {
        let body = inner.hasPrefix("<!DOCTYPE")
            ? Array(("<?xml version=\"1.0\"?>" + inner + "<scan:ScanSettings xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\">&a;</scan:ScanSettings>").utf8)
            : Self.settings(inner)
        #expect(throws: ShareRequestError.self) { try ShareXml.readSettings(body, Self.mfp()) }
        #expect((try? ShareXml.readSettings(body, Self.mfp())) == nil)
        do {
            _ = try ShareXml.readSettings(body, Self.mfp())
        } catch let e as ShareRequestError {
            #expect(e.status == status)
        } catch {
            Issue.record("\(error)")
        }
    }

    static func status(_ body: [UInt8], _ caps: ScannerCapabilities = mfp()) -> Int? {
        do {
            _ = try ShareXml.readSettings(body, caps)
            return nil
        } catch {
            return (error as? ShareRequestError)?.status
        }
    }

    @Test func settingsTooLongTooDeepOrTooManyAreRefusedUnread() {
        #expect(Self.status([UInt8](repeating: 0, count: ShareXml.maxSettingsBytes + 1)) == 400)
        #expect(Self.status([]) == 400)
        let deep = String(repeating: "<x>", count: 20) + String(repeating: "</x>", count: 20)
        #expect(Self.status(Self.settings(deep)) == 400)
        #expect(Self.status(Self.settings(String(repeating: "<x/>", count: ShareXml.maxElements + 1))) == 400)
        #expect(Self.status(Self.settings("<scan:Intent>\(String(repeating: "a", count: ShareXml.maxText + 1))</scan:Intent>")) == 400)
        #expect(Self.status(Array("<ScanSettings/>".utf8)) == 400) // no eSCL namespace
        #expect(Self.status(Array("<not xml".utf8)) == 400)
        // Duplex on a scanner without it.
        #expect(Self.status(Self.settings("<pwg:InputSource>Feeder</pwg:InputSource><scan:Duplex>true</scan:Duplex>"), Self.mfp(duplex: false)) == 409)
    }

    @Test func aFeederOnlyScannerScansItsFeederWhenNoSourceIsNamed() throws {
        #expect(try ShareXml.readSettings(Self.settings(""), Self.mfp(platen: false)).request.source == .adf)
    }

    // ---------------------------------------------------------------- the jobs

    @Test func aJobGivesItsPagesThen404AndOnlyToItsDevice() async throws {
        let share = SharedScanner(Self.open(FakeScanner()), Self.mfp(), Self.identity)
        defer { share.close() }
        let created = await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("<pwg:InputSource>Feeder</pwg:InputSource>"))
        #expect(created.status == 201)
        #expect(created.location?.hasPrefix("https://192.0.2.10:9780/eSCL/ScanJobs/") == true)
        let job = Self.jobPath(created)
        #expect(await Self.ask(share, "GET", job + "/NextDocument", peer: Self.otherPeer).status == 404) // not that device's job
        #expect(await Self.ask(share, "DELETE", job, peer: Self.otherPeer).status == 404)
        var pages: [[UInt8]] = []
        var reply = await Self.ask(share, "GET", job + "/NextDocument")
        while reply.status == 200 {
            #expect(reply.contentType == "image/jpeg")
            pages.append(reply.body ?? [])
            reply = await Self.ask(share, "GET", job + "/NextDocument")
        }
        #expect(pages.count == 3)
        #expect(await Self.ask(share, "GET", job + "/NextDocument").status == 404)
        let status = try Self.xml(await Self.ask(share, "GET", "/eSCL/ScannerStatus"))
        #expect(Self.values(status, "JobState") == ["Completed"])
        #expect(try Self.xml(await Self.ask(share, "GET", "/eSCL/ScannerStatus", peer: Self.otherPeer)).all("JobInfo").isEmpty)
        // The last page's size, for its device.
        let info = try Self.xml(await Self.ask(share, "GET", job + "/ScanImageInfo"))
        #expect(Self.values(info, "ActualWidth") == ["16"] && Self.values(info, "ActualBytesPerLine") == ["48"])
    }

    @Test(arguments: [("GET", "/eSCL/ScanJobs"), ("POST", "/eSCL/ScannerCapabilities"), ("PUT", "/eSCL/ScannerStatus")])
    func wrongMethodsAre405(_ method: String, _ path: String) async {
        let share = SharedScanner(Self.open(FakeScanner()), Self.mfp(), Self.identity)
        defer { share.close() }
        #expect(await Self.ask(share, method, path).status == 405)
    }

    @Test(arguments: ["/", "/eSCL/../../Windows/win.ini", "/eSCL/ScanJobs/..%2F..%2Fwin.ini/NextDocument", "/eSCL/ScanJobs/not-a-job/NextDocument",
                      "/eSCL/ScanJobs/00000000000000000000000000000000/NextDocument", "/escl/ScannerCapabilities", "/eSCL/ScannerIcon"])
    func anythingElseIs404(_ path: String) async {
        let share = SharedScanner(Self.open(FakeScanner()), Self.mfp(), Self.identity)
        defer { share.close() }
        #expect(await Self.ask(share, "GET", path).status == 404)
    }

    /// A scanner connected, then hanging in its driver: a job on it holds the scanner until it's cancelled.
    static func hung() -> (ConnectedScanner, FakeScanner) {
        let fake = FakeScanner()
        let scanner = open(fake)
        fake.hangs = true
        return (scanner, fake)
    }

    @Test func oneScanAtATimeAndAFullQueueIsToldToWait() async throws {
        let (scanner, _) = Self.hung() // the first job holds the scanner
        let share = SharedScanner(scanner, Self.mfp(), Self.identity, limits: ShareLimits(maxQueued: 2, maxJobsPerPeer: 10))
        defer { share.close() }
        let body = Self.settings("")
        for _ in 0..<3 { #expect(await Self.ask(share, "POST", "/eSCL/ScanJobs", body).status == 201) }
        let full = await Self.ask(share, "POST", "/eSCL/ScanJobs", body)
        #expect(full.status == 503)
        #expect(full.retryAfterSeconds != nil)
        #expect(share.activeJobs == 3)
        await Self.waitFor { scanner.isBusy }
        var status = try Self.xml(await Self.ask(share, "GET", "/eSCL/ScannerStatus"))
        let until = Date().addingTimeInterval(Timing.limit(5.0))
        while !Self.values(status, "JobState").contains("Processing") && Date() < until { // the first job's state follows its scan's start
            try await Task.sleep(for: .milliseconds(20))
            status = try Self.xml(await Self.ask(share, "GET", "/eSCL/ScannerStatus"))
        }
        #expect(status.kidValue("State") == "Processing")
        let states = Self.values(status, "JobState")
        #expect(states.filter { $0 == "Processing" }.count == 1) // one scans, two wait
        #expect(states.filter { $0 == "Pending" }.count == 2)
    }

    @Test func oneDeviceCanHoldOnlyAFewJobs() async {
        let (scanner, _) = Self.hung()
        let share = SharedScanner(scanner, Self.mfp(), Self.identity, limits: ShareLimits(maxQueued: 5, maxJobsPerPeer: 2))
        defer { share.close() }
        #expect(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")).status == 201)
        #expect(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")).status == 201)
        #expect(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")).status == 503)
        #expect(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings(""), peer: Self.otherPeer).status == 201)
    }

    @Test func aJobNobodyReadsExpiresAndLetsTheScannerGo() async {
        let (scanner, fake) = Self.hung()
        let time = ManualTime()
        let share = SharedScanner(scanner, Self.mfp(), Self.identity, limits: ShareLimits(idleLimit: 60, keepFinished: 5 * 60), now: time.now)
        defer { share.close() }
        let job = Self.jobPath(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")))
        #expect(share.activeJobs == 1)
        time.advance(59)
        _ = await Self.ask(share, "GET", "/eSCL/ScannerCapabilities")
        #expect(share.activeJobs == 1) // not yet
        time.advance(2)
        _ = await Self.ask(share, "GET", "/eSCL/ScannerCapabilities") // any request sweeps (and a timer, every few seconds)
        await Self.waitFor { share.activeJobs == 0 && !scanner.isBusy }
        #expect(await Self.ask(share, "GET", job + "/NextDocument").status == 404)
        time.advance(6 * 60)
        _ = await Self.ask(share, "GET", "/eSCL/ScannerCapabilities")
        #expect(share.keptJobs == 0) // forgotten
        fake.hangs = false // the scanner is free for the next job
        let next = Self.jobPath(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")))
        #expect(await Self.ask(share, "GET", next + "/NextDocument").status == 200)
    }

    @Test func deleteCancelsTheScan() async throws {
        let (scanner, fake) = Self.hung()
        let share = SharedScanner(scanner, Self.mfp(), Self.identity)
        defer { share.close() }
        let job = Self.jobPath(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")))
        #expect(await Self.ask(share, "DELETE", job).status == 200)
        await Self.waitFor { share.activeJobs == 0 && !scanner.isBusy }
        fake.hangs = false
        #expect(await Self.ask(share, "GET", job + "/NextDocument").status == 404)
        #expect(Self.values(try Self.xml(await Self.ask(share, "GET", "/eSCL/ScannerStatus")), "JobState") == ["Canceled"])
    }

    @Test func aScanThatFailsSaysSoAndTheServerGoesOn() async throws {
        let fake = FakeScanner()
        fake.failAtPage = 0
        let scanner = Self.open(fake)
        let share = SharedScanner(scanner, Self.mfp(), Self.identity)
        defer { share.close() }
        let job = Self.jobPath(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")))
        #expect(await Self.ask(share, "GET", job + "/NextDocument").status == 409)
        #expect(Self.values(try Self.xml(await Self.ask(share, "GET", "/eSCL/ScannerStatus")), "JobState") == ["Aborted"])
        fake.failAtPage = nil
        let next = Self.jobPath(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")))
        #expect(await Self.ask(share, "GET", next + "/NextDocument").status == 200)
    }

    @Test func aScanFromThisMacHoldsTheScannerAndTheNetworkWaits() async throws {
        let fake = FakeScanner()
        let scanner = Self.open(fake) // the app keeps one per scanner: the Scan tab and the share ask the same one
        fake.hangs = true
        let local = Task { try await Self.all(scanner.scan(ScanRequest())) } // this Mac's scan, hanging in the driver
        await Self.waitFor { scanner.isBusy }
        // The same scanner can't start a second job meanwhile...
        await #expect(throws: ScanError.self) { _ = try await Self.all(scanner.scan(ScanRequest())) }
        // ...and a device on the network is told to come back.
        let share = SharedScanner(scanner, Self.mfp(), Self.identity, busyElsewhere: { scanner.isBusy })
        defer { share.close() }
        #expect(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")).status == 503)
        #expect(try Self.xml(await Self.ask(share, "GET", "/eSCL/ScannerStatus")).kidValue("State") == "Processing")
        local.cancel()
        await #expect(throws: CancellationError.self) { _ = try await local.value }
        await Self.waitFor { !scanner.isBusy }
    }

    @Test func disposedItAnswersNothingAndLetsTheScannerGo() async {
        let (scanner, _) = Self.hung()
        let share = SharedScanner(scanner, Self.mfp(), Self.identity)
        _ = await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings(""))
        await Self.waitFor { scanner.isBusy }
        share.close()
        #expect(await Self.ask(share, "GET", "/eSCL/ScannerCapabilities").status == 503)
        #expect(share.keptJobs == 0)
        await Self.waitFor { !scanner.isBusy }
    }

    // ---------------------------------------------------------------- who may connect

    static let home = LocalNetwork("192.168.1.20", 24)
    /// A network whose address isn't a private one (a hotel's, a café's that hands out public addresses): not served.
    static let cafe = LocalNetwork("203.0.113.5", 24)

    @Test(arguments: [
        ("192.168.1.33", "192.168.1.20", true),
        ("::ffff:192.168.1.33", "::ffff:192.168.1.20", true), // IPv4 on a dual-stack socket
        ("127.0.0.1", "127.0.0.1", true), // this Mac
        ("::1", "::1", true),
        ("127.0.0.1", "192.168.1.20", false), // loopback arrives on loopback, nowhere else
        ("192.168.2.33", "192.168.1.20", false), // another subnet
        ("203.0.113.4", "203.0.113.5", false), // the public network's subnet
        ("203.0.113.4", "192.168.1.20", false),
        ("8.8.8.8", "192.168.1.20", false),
        ("fe80::2%en0", "fe80::1%en0", false), // Mac: IPv4 only
        ("fd00:1:2:3::99", "fd00:1:2:3::20", false),
        ("192.168.1.33", "192.168.1.21", false), // an address this Mac doesn't serve on
    ])
    func onlyThisMacAndPrivateSubnetsMayConnect(_ peer: String, _ local: String, _ allowed: Bool) {
        let served = SharePeers.served([Self.home, Self.cafe])
        #expect(!served.contains(Self.cafe))
        #expect(SharePeers.allows(peer, local: local, served) == allowed)
    }

    @Test func aPeerOnThePrivateSubnetThatCameInElsewhereIsRefused() {
        // A peer on the private subnet whose connection came in on another of this Mac's addresses (routed) isn't let in.
        let lab = LocalNetwork("10.1.0.2", 16)
        let served = SharePeers.served([Self.home, lab])
        #expect(!SharePeers.allows("192.168.1.33", local: "10.1.0.2", served))
        #expect(SharePeers.allows("192.168.1.33", local: "192.168.1.20", served))
        // Before TLS the arrival address isn't known yet: the peer alone is checked, then again once it is.
        #expect(SharePeers.allows("192.168.1.33", local: nil, served))
    }

    @Test func publicNetworksAndOddPrefixesAreNotServed() {
        #expect(SharePeers.served([Self.cafe, LocalNetwork("192.168.1.20", 0), LocalNetwork("192.168.1.20", 32), LocalNetwork("127.0.0.1", 8)]).isEmpty)
        #expect(!SharePeers.allows("192.168.1.33", local: "192.168.1.20", []))
    }

    // ---------------------------------------------------------------- the certificate and the announcement

    @Test func theCertificateIsSelfSignedForThisMacWithAFingerprintToCompare() {
        let point: [UInt8] = [4] + [UInt8](repeating: 0x22, count: 64)
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let tbs = PhoneCertificateDer.tbs(publicKey: point, hostName: "office-mac.local", serial: [1, 2, 3], now: now)
        func has(_ needle: [UInt8], _ hay: [UInt8]) -> Bool {
            guard hay.count >= needle.count else { return false }
            return (0...(hay.count - needle.count)).contains { Array(hay[$0..<($0 + needle.count)]) == needle }
        }
        #expect(PhoneCertificateDer.subject == "Inkvolt Print phone scan") // one certificate for the share and the phone scan (Mac: the phone's name)
        #expect(has(Array(PhoneCertificateDer.subject.utf8), tbs))
        #expect(has(Array("office-mac.local".utf8), tbs))
        #expect(PhoneCertificateDer.life <= 826 * 86_400)
        #expect(PhoneCertificateDer.usable(notBefore: now.addingTimeInterval(-86_400), notAfter: now.addingTimeInterval(PhoneCertificateDer.life), now: now))
        #expect(!PhoneCertificateDer.usable(notBefore: now, notAfter: now.addingTimeInterval(PhoneCertificateDer.life), now: now.addingTimeInterval(800 * 86_400)))
        let fingerprint = PhoneCertificateDer.fingerprint([UInt8](repeating: 0xAB, count: 32))
        #expect(fingerprint.count == 95 && fingerprint.split(separator: ":").allSatisfy { $0 == "AB" })
    }

    @Test func theAnnouncementIsUscansWithWhatClientsRead() throws {
        var caps = Self.mfp()
        caps.platen?.colorModes = ["BlackAndWhite1", "Grayscale8", "RGB24"] // what a driver might list (the Mac scans the last two)
        let advert = ShareDnssd.advert(Self.identity, caps, computerName: "OFFICE-MAC", port: 9780)
        #expect(ShareAdvert.service == "_uscans._tcp")
        #expect(advert.instance == "Example Scan 300 on OFFICE-MAC")
        #expect(advert.host == "OFFICE-MAC.local")
        #expect(advert.value("rs") == "eSCL")
        #expect(advert.value("UUID") == "0f6b3d2a-7c1e-4c55-9a51-2b8e44d1c0aa")
        #expect(advert.value("cs") == "binary,grayscale,color")
        #expect(advert.value("is") == "platen,adf")
        #expect(advert.value("duplex") == "T")
        #expect(advert.value("pdl") == "image/jpeg,application/pdf")
        // What Inkvolt Print's own discovery makes of it: the share's eSCL root over HTTPS.
        let txt = Dictionary(advert.txt.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let service = DnssdService(service: ShareAdvert.service, uuid: txt["uuid"], hostName: advert.host, ipv4: "192.0.2.10", port: advert.port, txt: txt)
        #expect(DnssdJoin.esclRoot(service, host: "192.0.2.10")?.absoluteString == "https://192.0.2.10:9780/eSCL/")
    }

    @Test(arguments: [("A.B\\C", "Mac", "A B C on Mac"), ("Scanner\u{7}", "Mac", "Scanner on Mac")])
    func instanceNamesHaveNoDotsOrControlCharacters(_ scanner: String, _ mac: String, _ expected: String) {
        #expect(ShareDnssd.instanceName(scanner, mac) == expected)
    }

    @Test func longNamesAreCutTo63BytesBetweenCharacters() {
        let name = ShareDnssd.instanceName(String(repeating: "é", count: 40) + "😀😀", "Mac")
        #expect(name.utf8.count <= 63)
        #expect(String(decoding: Array(name.utf8), as: UTF8.self) == name)
        #expect(ShareDnssd.hostName("my mac_1") == "my-mac-1.local")
        #expect(ShareDnssd.hostName("...") == "inkvolt-print.local")
    }

    // ---------------------------------------------------------------- the switch

    final class FakeNetworks: ShareNetworks, @unchecked Sendable {
        private let lock = NSLock()
        private var list = [ScannerSharingTests.home]
        private var watchers: [UUID: @Sendable () -> Void] = [:]

        var now: [LocalNetwork] {
            get { lock.withLock { list } }
            set { lock.withLock { list = newValue } }
        }

        func read() -> [LocalNetwork] { now }

        /// Who hears changes now (nothing is watched while no scanner is shared).
        var listeners: Int { lock.withLock { watchers.count } }

        func watch(_ changed: @escaping @Sendable () -> Void) -> any ShareWatch {
            let id = UUID()
            lock.withLock { watchers[id] = changed }
            return Stop { [weak self] in self?.lock.withLock { _ = self?.watchers.removeValue(forKey: id) } }
        }

        func raise() { for w in lock.withLock({ Array(watchers.values) }) { w() } }
    }

    struct Stop: ShareWatch {
        let action: @Sendable () -> Void
        func stop() async { action() }
    }

    final class Closer: ShareWatch, @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        var closed: Bool { lock.withLock { done } }
        func stop() async { lock.withLock { done = true } }
    }

    final class FakeAdvertiser: ShareAdvertiser, @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(advert: ShareAdvert, on: [LocalNetwork], closer: Closer)] = []

        var adverts: [(advert: ShareAdvert, on: [LocalNetwork], closer: Closer)] { lock.withLock { list } }

        func advertise(_ advert: ShareAdvert, on: [LocalNetwork]) async throws -> any ShareWatch {
            let closer = Closer()
            lock.withLock { list.append((advert, on, closer)) }
            return closer
        }

        var announced: Bool { adverts.last.map { !$0.closer.closed } ?? false }
    }

    /// Announces nothing until cancelled (DNS-SD that never confirms).
    final class HangingAdvertiser: ShareAdvertiser, @unchecked Sendable {
        private let lock = NSLock()
        private var gaveUp = false
        var cancelled: Bool { lock.withLock { gaveUp } }

        func advertise(_ advert: ShareAdvert, on: [LocalNetwork]) async throws -> any ShareWatch {
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
            lock.withLock { gaveUp = true }
            throw CancellationError()
        }
    }

    final class FakeListener: PhoneListener, @unchecked Sendable {
        let port: Int?
        private let lock = NSLock()
        private var done = false
        init(_ port: Int) { self.port = port }
        var closed: Bool { lock.withLock { done } }
        func close() async { lock.withLock { done = true } }
    }

    final class FakeHost: ShareHost, @unchecked Sendable {
        private let lock = NSLock()
        private var list: [(listen: ShareListen, listener: FakeListener)] = []
        private var taken = false

        var started: [(listen: ShareListen, listener: FakeListener)] { lock.withLock { list } }
        var portTaken: Bool {
            get { lock.withLock { taken } }
            set { lock.withLock { taken = newValue } }
        }

        func start(_ listen: ShareListen) async throws -> any PhoneListener {
            if portTaken { throw PhoneHostError.portInUse }
            let listener = FakeListener(listen.port)
            lock.withLock { list.append((listen, listener)) }
            return listener
        }

        var listening: Bool { started.last.map { !$0.listener.closed } ?? false }
    }

    struct FakeCertificate: PhoneCertificate {
        var fingerprint: String { String(repeating: "AB:", count: 31) + "CD" }
    }

    struct FakeCertificates: ShareCertificates {
        func get(hostName: String, now: Date) throws -> any PhoneCertificate { FakeCertificate() }
    }

    final class Saved: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [ScannerShareChoice] = []
        var all: [ScannerShareChoice] { lock.withLock { list } }
        func add(_ c: ScannerShareChoice) { lock.withLock { list.append(c) } }
    }

    static func makeSwitch(_ choice: ScannerShareChoice? = nil) -> (ScannerShare, FakeHost, FakeAdvertiser, FakeNetworks, Saved) {
        let host = FakeHost(), ads = FakeAdvertiser(), nets = FakeNetworks(), saved = Saved()
        let share = ScannerShare(ShareEnvironment(host: host, networks: nets, advertiser: ads, certificates: FakeCertificates()), computerName: "OFFICE-MAC",
                                 choice: choice, save: { saved.add($0) })
        return (share, host, ads, nets, saved)
    }

    static let offText = "Off. Turned on, phones, Macs and other computers on a private network can scan with this scanner while Inkvolt Print runs here."

    @Test func offByDefaultNothingListens() async {
        let (share, host, ads, _, _) = Self.makeSwitch()
        await share.offer(Self.usb.id, Self.open(FakeScanner()))
        #expect(share.state == .off)
        #expect(!share.isOn)
        #expect(host.started.isEmpty)
        #expect(ads.adverts.isEmpty)
        #expect(share.text(Self.usb.id) == Self.offText)
    }

    @Test func turnedOnItListensOnItsPortAnnouncesAndShowsTheFingerprint() async throws {
        let (share, host, ads, _, saved) = Self.makeSwitch()
        await share.share(Self.open(FakeScanner()))
        #expect(share.state == .on)
        #expect(host.listening)
        let listen = try #require(host.started.first?.listen)
        #expect(listen.port == ScannerShare.defaultPort)
        #expect(!listen.loopbackOnly)
        #expect(ads.announced)
        #expect(ads.adverts.first?.on == [Self.home])
        #expect(ads.adverts.first?.advert.port == ScannerShare.defaultPort)
        #expect(share.fingerprint == FakeCertificate().fingerprint)
        #expect(saved.all.last?.deviceId == Self.usb.id)
        #expect(saved.all.last?.uuid != nil)
        #expect(share.text(Self.usb.id).contains("9780"))
        // Who may connect follows the private networks.
        #expect(listen.allowPeer("192.168.1.40", Self.home.address))
        #expect(!listen.allowPeer("10.0.0.40", Self.home.address))
        await share.close()
    }

    @Test func turnedOffThePortClosesAndTheAnnouncementEndsAtOnce() async {
        let (share, host, ads, _, saved) = Self.makeSwitch()
        await share.share(Self.open(FakeScanner()))
        await share.stop()
        #expect(!host.listening)
        #expect(!ads.announced)
        #expect(share.state == .off)
        #expect(saved.all.last?.deviceId == nil)
        #expect(saved.all.first?.uuid == saved.all.last?.uuid) // kept for the next time
    }

    @Test func onAPublicNetworkOnlyNothingListensUntilAPrivateOneComes() async {
        let (share, host, ads, nets, _) = Self.makeSwitch()
        nets.now = [Self.cafe]
        await share.share(Self.open(FakeScanner()))
        #expect(share.state == .noPrivateNetwork)
        #expect(host.started.isEmpty)
        #expect(share.text(Self.usb.id)
            == "Not shared: this Mac isn't on a private network. Join your home or office Wi-Fi or Ethernet, and the scanner is shared at once.")
        nets.now = [Self.cafe, Self.home]
        await share.recheck()
        #expect(host.listening)
        #expect(ads.adverts.last?.on == [Self.home])
        // The private network goes (the laptop moved to the café): the port closes.
        nets.now = [Self.cafe]
        await share.recheck()
        #expect(!host.listening)
        #expect(!ads.announced)
        #expect(share.state == .noPrivateNetwork)
        await share.close()
    }

    @Test func aSecondPrivateNetworkIsAnnouncedOnWithoutReopeningThePort() async {
        let (share, host, ads, nets, _) = Self.makeSwitch()
        await share.share(Self.open(FakeScanner()))
        nets.now = [Self.home, LocalNetwork("10.0.5.2", 24)]
        await share.recheck()
        #expect(host.started.count == 1)
        #expect(host.listening)
        #expect(ads.adverts.count == 2)
        #expect(ads.adverts.first?.closer.closed == true)
        #expect(ads.adverts.last?.on.count == 2)
        await share.close()
    }

    @Test func sharingIsFreeNoKeyIsAsked() async {
        // The owner's decision of 2026-11-22: sharing a scanner is free. The share asks nothing of Inkvolt Pro, and Pro has no
        // such feature.
        let (share, host, _, _, _) = Self.makeSwitch()
        #expect(await share.turnOn(Self.open(FakeScanner())) == .on)
        #expect(share.state == .on)
        #expect(host.listening)
        #expect(!ProFeature.allCases.map { "\($0)" }.contains { $0.lowercased().contains("scanner") })
        await share.close()
    }

    @Test func keptOnItWaitsForTheScannerAndStopsWhenItGoes() async {
        let (share, host, _, _, _) = Self.makeSwitch(ScannerShareChoice(deviceId: Self.usb.id, name: Self.usb.name, uuid: UUID()))
        #expect(share.isOn)
        await share.recheck()
        #expect(share.state == .waitingForScanner)
        #expect(host.started.isEmpty)
        await share.offer("another-scanner", Self.open(FakeScanner()))
        #expect(host.started.isEmpty)
        await share.offer(Self.usb.id, Self.open(FakeScanner()))
        #expect(host.listening)
        await share.offer(Self.usb.id, nil) // unplugged
        #expect(!host.listening)
        #expect(share.state == .waitingForScanner)
        await share.close()
    }

    @Test func oneScannerAtATime() async {
        let (share, host, _, _, _) = Self.makeSwitch()
        await share.share(Self.open(FakeScanner()))
        let other = SystemScanner(id: "other", name: "Photo Scanner", usb: true)
        await share.share(Self.open(FakeScanner(), other))
        #expect(host.started.count == 2)
        #expect(host.started.first?.listener.closed == true)
        #expect(host.listening)
        #expect(share.isShared("other"))
        #expect(share.text(Self.usb.id) == "Photo Scanner is shared now. Turning this on shares this scanner instead: one scanner is shared at a time.")
        await share.close()
    }

    @Test func aTakenPortIsSaidAndNothingIsLeftOpen() async {
        let (share, host, ads, _, _) = Self.makeSwitch()
        host.portTaken = true
        await share.share(Self.open(FakeScanner()))
        #expect(share.state == .failed)
        #expect(share.text(Self.usb.id) == "Not shared: another program uses port 9780. Close it, then turn sharing off and on again.")
        #expect(ads.adverts.isEmpty)
        await share.close()
    }

    @Test func theAppClosingClosesThePortAndKeepsTheChoice() async {
        let (share, host, ads, nets, saved) = Self.makeSwitch()
        await share.share(Self.open(FakeScanner()))
        let count = saved.all.count
        await share.close()
        #expect(!host.listening)
        #expect(!ads.announced)
        #expect(saved.all.count == count)
        // Nothing starts again after it closed: not a network change, not the scanner coming back.
        nets.raise()
        await share.offer(Self.usb.id, Self.open(FakeScanner()))
        await share.recheck()
        #expect(host.started.count == 1)
    }

    // ---------------------------------------------------------------- through the server's HTTP, with our own eSCL client

    /// The shared scanner as our eSCL client reaches it: each request handed to its HTTP side as the server reads it off the
    /// wire (PrintMacTests do the same over HTTPS on loopback).
    struct ShareTransport: HttpTransport {
        let share: SharedScanner
        let peer: String

        func send(_ request: HttpRequest) async throws -> HttpResponse {
            var head = "\(request.method) \(request.url.path) HTTP/1.1\r\nHost: \(request.url.host ?? ""):\(request.url.port ?? 443)\r\n"
            let body = request.bodyBytes()
            if !body.isEmpty { head += "Content-Length: \(body.count)\r\n" }
            let io = Wire(Array((head + "\r\n").utf8) + body)
            await PhoneHttp.serve(io, peer: peer, service: share)
            return try Wire.response(io.sent)
        }
    }

    /// One connection's bytes: what the client sent, and what came back.
    final class Wire: PhoneConnectionIO, @unchecked Sendable {
        private let lock = NSLock()
        private var input: [UInt8]
        private var output: [UInt8] = []

        init(_ input: [UInt8]) { self.input = input }

        var sent: [UInt8] { lock.withLock { output } }

        func receive(max: Int, timeout: Duration) async -> [UInt8]? {
            lock.withLock {
                guard !input.isEmpty else { return nil }
                let n = Swift.min(max, input.count)
                defer { input.removeFirst(n) }
                return Array(input[..<n])
            }
        }

        func send(_ bytes: [UInt8]) async -> Bool {
            lock.withLock { output += bytes }
            return true
        }

        /// The first answer in `bytes`.
        static func response(_ bytes: [UInt8]) throws -> HttpResponse {
            guard let end = (0..<max(0, bytes.count - 3)).first(where: { bytes[$0] == 13 && bytes[$0 + 1] == 10 && bytes[$0 + 2] == 13 && bytes[$0 + 3] == 10 })
            else { throw DeviceNetworkError.failed("no answer") }
            let lines = String(decoding: bytes[..<end], as: UTF8.self).components(separatedBy: "\r\n")
            let status = Int(lines[0].split(separator: " ")[1]) ?? 0
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[String(line[..<colon])] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let length = Int(headers["Content-Length"] ?? "0") ?? 0
            return HttpResponse(status: status, headers: headers, body: Array(bytes[(end + 4)..<min(bytes.count, end + 4 + length)]))
        }
    }

    static func client(_ share: SharedScanner) -> EsclClient {
        EsclClient(DeviceHttp(host: "192.0.2.10", transport: ShareTransport(share: share, peer: peer)), root: URL(string: "https://192.0.2.10:9780/eSCL/")!)
    }

    @Test func ourClientScansThroughTheSharedEndpointIdenticalToTheDirectScan() async throws {
        let fake = FakeScanner()
        let scanner = Self.open(fake)
        let share = SharedScanner(scanner, Self.mfp(), Self.identity, busyElsewhere: { scanner.isBusy })
        defer { share.close() }
        let client = Self.client(share)
        let caps = try #require(try await client.capabilities())
        #expect(caps.sources == Self.mfp().sources)
        #expect(caps.platen?.resolutions == Self.mfp().platen?.resolutions)
        #expect(caps.adf?.colorModes == Self.mfp().adf?.colorModes)
        for request in [ScanRequest(source: .platen, color: .color, resolution: 300), ScanRequest(source: .adf, color: .grayscale, resolution: 200),
                        ScanRequest(source: .adfDuplex, color: .grayscale, resolution: 600),
                        ScanRequest(source: .platen, color: .color, resolution: 150, width: 1275, height: 1650)] {
            fake.transfers = []
            let mine = try await Self.all(scanner.scan(request))
            let asDriver = fake.transfers
            fake.transfers = []
            let theirs = try await Self.all(client.scan(request))
            #expect(mine.count == theirs.count)
            #expect(mine.count >= 1)
            #expect(mine == theirs)
            #expect(asDriver == fake.transfers) // the driver was asked the same, page for page
        }
        await Self.waitFor { share.activeJobs == 0 }
    }

    @Test func overHttpBigBodiesDtdsAndUnknownPathsAreRefused() async throws {
        let share = SharedScanner(Self.open(FakeScanner()), Self.mfp(), Self.identity)
        defer { share.close() }
        func send(_ head: String, _ body: [UInt8] = []) async throws -> (HttpResponse, String) {
            let io = Wire(Array((head + "\r\n\r\n").utf8) + body)
            await PhoneHttp.serve(io, peer: Self.peer, service: share)
            return (try Wire.response(io.sent), String(decoding: io.sent, as: UTF8.self))
        }
        let big = [UInt8](repeating: 0x41, count: ShareXml.maxSettingsBytes * 4)
        let (tooBig, raw) = try await send("POST /eSCL/ScanJobs HTTP/1.1\r\nHost: 192.0.2.10\r\nContent-Length: \(big.count)", big)
        #expect(tooBig.status == 413)
        #expect(raw.contains("Connection: close"))
        let dtd = Array("<?xml version=\"1.0\"?><!DOCTYPE l [<!ENTITY a \"a\">]><scan:ScanSettings xmlns:scan=\"http://schemas.hp.com/imaging/escl/2011/05/03\"/>".utf8)
        #expect(try await send("POST /eSCL/ScanJobs HTTP/1.1\r\nHost: 192.0.2.10\r\nContent-Length: \(dtd.count)", dtd).0.status == 400)
        #expect(try await send("GET /eSCL/..%2F..%2FWindows%2Fwin.ini HTTP/1.1\r\nHost: 192.0.2.10").0.status == 404)
        let (caps, text) = try await send("GET /eSCL/ScannerCapabilities HTTP/1.1\r\nHost: 192.0.2.10")
        #expect(caps.status == 200 && caps.header("Content-Type") == "text/xml")
        #expect(text.contains("Cache-Control: no-store") && !text.contains("Server:"))
        // A PDF page, as asked.
        let post = Self.settings("<pwg:InputSource>Platen</pwg:InputSource><pwg:DocumentFormat>application/pdf</pwg:DocumentFormat>")
        let (created, _) = try await send("POST /eSCL/ScanJobs HTTP/1.1\r\nHost: 192.0.2.10:9780\r\nContent-Length: \(post.count)", post)
        #expect(created.status == 201)
        let job = URL(string: created.header("Location") ?? "")?.path ?? ""
        let (page, _) = try await send("GET \(job)/NextDocument HTTP/1.1\r\nHost: 192.0.2.10:9780")
        #expect(page.header("Content-Type") == "application/pdf")
        #expect(page.body.starts(with: Array("%PDF-".utf8)))
    }

    // ---------------------------------------------------------------- review of 4bf7e6c0

    @Test func aDeviceWaitingOnASlowPageOrPollingStatusKeepsItsJob() async {
        let (scanner, _) = Self.hung() // a page that takes minutes (600 dpi on a slow flatbed)
        let time = ManualTime()
        let share = SharedScanner(scanner, Self.mfp(), Self.identity, limits: ShareLimits(idleLimit: 60, longPoll: .seconds(600)), now: time.now)
        defer { share.close() }
        let job = Self.jobPath(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")))
        let waiting = Task { await Self.ask(share, "GET", job + "/NextDocument") } // the long poll
        await Self.waitFor { share.isAsked(job) }
        time.advance(3 * 60)
        _ = await Self.ask(share, "GET", "/eSCL/ScannerCapabilities") // sweeps
        #expect(share.activeJobs == 1) // in flight counts as asked about, however long it takes
        waiting.cancel() // the device stops waiting...
        #expect(await waiting.value.status == 503)
        // ...but polls its status, as sane-airscan does between pages.
        for _ in 0..<4 {
            time.advance(50)
            _ = await Self.ask(share, "GET", "/eSCL/ScannerStatus")
        }
        #expect(share.activeJobs == 1)
        time.advance(61) // then silence: it's let go
        _ = await Self.ask(share, "GET", "/eSCL/ScannerCapabilities")
        await Self.waitFor { share.activeJobs == 0 }
        // Another device's status polls don't keep it.
        let other = Self.jobPath(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings(""), peer: Self.otherPeer))
        #expect(!other.isEmpty)
        time.advance(40)
        _ = await Self.ask(share, "GET", "/eSCL/ScannerStatus")
        time.advance(40)
        _ = await Self.ask(share, "GET", "/eSCL/ScannerStatus")
        await Self.waitFor { share.activeJobs == 0 }
    }

    @Test func aForgottenJobsCancellationIsDisposedOnceItsScanIsOver() async {
        let fake = FakeScanner()
        let scanner = Self.open(fake)
        let time = ManualTime()
        let share = SharedScanner(scanner, Self.mfp(), Self.identity, limits: ShareLimits(keepFinished: 5 * 60), now: time.now)
        let job = Self.jobPath(await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings("")))
        #expect(await Self.ask(share, "GET", job + "/NextDocument").status == 200)
        #expect(await Self.ask(share, "GET", job + "/NextDocument").status == 404)
        await Self.waitFor { share.activeJobs == 0 }
        #expect(share.releasedJobs == 0)
        time.advance(6 * 60)
        _ = await Self.ask(share, "GET", "/eSCL/ScannerCapabilities")
        #expect(share.releasedJobs == 1)
        // A job still scanning when the server stops is released once its scan has ended.
        fake.hangs = true
        _ = await Self.ask(share, "POST", "/eSCL/ScanJobs", Self.settings(""))
        await Self.waitFor { scanner.isBusy }
        share.close()
        await Self.waitFor { share.releasedJobs == 2 }
    }

    @Test func onlyAdvertisedResolutionsAreTakenAndPixelsAreBounded() throws {
        let caps = Self.mfp() // 75, 100, 150, 200, 300, 400, 600, 1200
        #expect(Self.status(Self.settings("<scan:XResolution>250</scan:XResolution>")) == 409)
        #expect(Self.status(Self.settings("<scan:XResolution>19200</scan:XResolution>")) == 409)
        #expect(Self.status(Self.settings("<scan:XResolution>300</scan:XResolution><scan:YResolution>600</scan:YResolution>")) == 409)
        #expect(try ShareXml.readSettings(Self.settings("<scan:XResolution>600</scan:XResolution><scan:YResolution>600</scan:YResolution>"), caps)
            .request.resolution == 600)
        // A driver that lists no resolution: 300 dpi is all that's offered, and all that's taken.
        let none = Self.mfp(resolutions: [])
        #expect(none.platen?.resolutions.isEmpty == true)
        #expect(String(decoding: ShareXml.capabilities(none, Self.identity), as: UTF8.self).contains("<scan:XResolution>300</scan:XResolution>"))
        #expect(try ShareXml.readSettings(Self.settings(""), none).request.resolution == 300)
        #expect(Self.status(Self.settings("<scan:XResolution>19200</scan:XResolution>"), none) == 409)
        // A region past the source is kept inside it before planning; a page too many pixels across is refused.
        let big = try ShareXml.readSettings(Self.settings("<pwg:ScanRegions><pwg:ScanRegion><pwg:Width>299999</pwg:Width><pwg:Height>299999</pwg:Height>"
            + "<pwg:XOffset>299999</pwg:XOffset></pwg:ScanRegion></pwg:ScanRegions>"), caps).request
        #expect(big.xOffset == 2549 && big.width == 1 && big.height == 3507)
        let huge = ScannerCapabilities(makeAndModel: "x", platen: InputCaps(minWidth: 0, maxWidth: 300 * 1000, minHeight: 0, maxHeight: 300 * 1000,
                                                                              colorModes: ["RGB24"], resolutions: [1200]), adf: nil, adfDuplex: false)
        #expect(Self.status(Self.settings(""), huge) == 409)
    }

    @Test func aSharedScannerThatIsntConnectedKeepsItsCardAndCanBeTurnedOff() async {
        let (share, host, _, _, saved) = Self.makeSwitch()
        await share.share(Self.open(FakeScanner()))
        // The entry knows its scanner but it's off now: the card stays, ticked, waiting.
        await share.offer(Self.usb.id, nil)
        let card = share.card(connected: nil, known: Self.usb)
        #expect(card.isShown)
        #expect(card.isOn)
        #expect(card.text == "Shared once the scanner answers. Check that it's on and plugged in.")
        // A scanner that isn't the shared one and isn't connected shows nothing; one macOS reaches over eSCL never shows.
        #expect(!share.card(connected: nil, known: SystemScanner(id: "other", name: "Other", usb: true)).isShown)
        #expect(!share.card(connected: SystemScanner(id: "escl", name: "Printer", usb: false), known: nil).isShown)
        // One a maker's driver reaches over the network is the Mac's own to share.
        #expect(share.card(connected: SystemScanner(id: "maker", name: "Printer", usb: false, makerDriver: true), known: nil).isShown)
        // Forgetting its entry turns sharing off, so re-adding it doesn't share it again.
        await share.forget([nil, "other", Self.usb.id])
        #expect(!share.isOn)
        #expect(saved.all.last?.deviceId == nil)
        #expect(!host.listening)
        #expect(!share.card(connected: nil, known: Self.usb).isShown)
        await share.close()
    }

    @Test func theCardShowsTheFingerprintOnlyWhileListening16BytesALine() async {
        let (share, _, _, nets, _) = Self.makeSwitch()
        let scanner = Self.open(FakeScanner())
        let off = share.card(connected: scanner.scanner, known: nil)
        #expect(off.isShown)
        #expect(!off.isOn)
        #expect(off.fingerprint == nil)
        await share.share(scanner)
        let on = share.card(connected: scanner.scanner, known: nil)
        #expect(on.fingerprint?.replacingOccurrences(of: "\n", with: "") == share.fingerprint)
        #expect(on.fingerprint?.split(separator: "\n").count == 2)
        nets.now = [Self.cafe]
        await share.recheck()
        #expect(share.card(connected: scanner.scanner, known: nil).fingerprint == nil)
        await share.close()
    }

    @Test func turningOnWithoutAConnectedScannerChangesNothing() async {
        let (share, host, _, _, saved) = Self.makeSwitch()
        #expect(await share.turnOn(nil) == .noScanner)
        #expect(await share.turnOn(Self.open(FakeScanner(), SystemScanner(id: "escl", name: "Printer", usb: false))) == .noScanner)
        #expect(!share.isOn)
        #expect(saved.all.isEmpty)
        #expect(host.started.isEmpty)
        #expect(await share.turnOn(Self.open(FakeScanner())) == .on)
        #expect(host.listening)
        await share.close()
    }

    @Test func networksAreWatchedOnlyWhileAScannerIsShared() async {
        let (share, _, _, nets, _) = Self.makeSwitch()
        #expect(nets.listeners == 0)
        await share.recheck()
        #expect(nets.listeners == 0)
        await share.share(Self.open(FakeScanner()))
        #expect(nets.listeners == 1)
        await share.stop()
        #expect(nets.listeners == 0)
        await share.share(Self.open(FakeScanner()))
        await share.close()
        #expect(nets.listeners == 0)
    }

    @Test func aNetworkChangeIsHeardAndCheckedAgain() async {
        let (share, host, _, nets, _) = Self.makeSwitch()
        await share.share(Self.open(FakeScanner()))
        nets.now = [Self.cafe]
        nets.raise() // checked again two seconds later (addresses come and go in bursts)
        await Self.waitFor { share.state == .noPrivateNetwork }
        #expect(!host.listening)
        await share.close()
    }

    @Test func closingCancelsAnAnnouncementUnderWayAtOnce() async throws {
        let host = FakeHost()
        let ads = HangingAdvertiser()
        let share = ScannerShare(ShareEnvironment(host: host, networks: FakeNetworks(), advertiser: ads, certificates: FakeCertificates()),
                                 computerName: "OFFICE-MAC", choice: nil, save: { _ in })
        let starting = Task { await share.share(Self.open(FakeScanner())) }
        await Self.waitFor { host.started.count == 1 }
        // The announcement never ends by itself: closing at all means it was cancelled, not waited out.
        let clock = ContinuousClock(), began = clock.now
        await share.close()
        #expect(clock.now - began < Timing.limit(.seconds(10)))
        await starting.value
        #expect(ads.cancelled)
        #expect(!host.listening)
    }

    @Test func anEntryWhoseScannerChangesWithdrawsTheOldOne() async throws {
        let (share, host, _, _, _) = Self.makeSwitch()
        await share.share(Self.open(FakeScanner()))
        let listening = try #require(host.started.last?.listen.scanner)
        // The entry's scanner is now B: A is offered as gone, and nothing serves A.
        await share.offer(Self.usb.id, nil)
        await share.offer("b", Self.open(FakeScanner(), SystemScanner(id: "b", name: "B", usb: true)))
        #expect(!host.listening)
        #expect(await listening.handle(ShareRequest("GET", "/eSCL/ScannerCapabilities", peer: Self.peer)).status == 503)
        #expect(share.state == .waitingForScanner)
        await share.close()
    }
}

extension SharedScanner {
    /// Whether a request for the job at `path` is under way now.
    func isAsked(_ path: String) -> Bool { jobAsked(path.split(separator: "/").last.map(String.init) ?? "") }
}
