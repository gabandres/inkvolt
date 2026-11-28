import Foundation
import Testing
@testable import PrintCore

/// ImageCaptureCore scans' rules (PrintMac's `SystemScanDevice` drives them; no Windows test: WIA has no such session),
/// found with a network all-in-one on 2026-11-27: the unit isn't ready until it says its size and resolutions (right after
/// a session opens it says none, and a scan asked of it never ended); a scan that ends with no page and no error says so;
/// a scan that says nothing is given up; the session is opened for the first use and closed after the last (one left open
/// held the device for minutes).
struct ImageCaptureJobTests {
    @Test func aUnitIsReadyOnlyOnceItSaysItsSizeAndResolutions() {
        #expect(ImageCaptureJob.unitReady(width: 8.5, height: 11.69, resolutions: 3))
        #expect(!ImageCaptureJob.unitReady(width: 0, height: 0, resolutions: 0)) // as the HP's said right after the session opened
        #expect(!ImageCaptureJob.unitReady(width: 8.5, height: 11.69, resolutions: 0))
        #expect(!ImageCaptureJob.unitReady(width: .nan, height: 11, resolutions: 3))
        #expect(!ImageCaptureJob.unitReady(width: 8.5, height: .infinity, resolutions: 3))
    }

    /// What each event did, in order.
    private static func run(_ events: [ImageCaptureJob.Event], _ job: inout ImageCaptureJob) -> [[ImageCaptureJob.Action]] {
        events.map { job.handle($0) }
    }

    @Test func pagesAreHandedOnAndTheEndIsTheScansEnd() {
        var job = ImageCaptureJob()
        let did = Self.run([.page([1]), .page([2]), .completed(nil), .page([3]), .completed("late")], &job)
        #expect(did == [[.yield([1])], [.yield([2])], [.finish(nil)], [], []]) // nothing after the end
        #expect(job.pages == 2 && job.isOver)
    }

    @Test func aScanThatEndsWithoutAPageOrAnErrorSaysSo() {
        var job = ImageCaptureJob()
        #expect(Self.run([.completed(nil)], &job) == [[.finish(ImageCaptureJob.noPage)]])
        #expect(ImageCaptureJob.noPage.hasPrefix("The scanner finished without sending a page."))
    }

    @Test func theScannersErrorAPageThatCantBeReadAndTheScannerGoingEndTheScanWithAWord() {
        var failed = ImageCaptureJob(), unreadable = ImageCaptureJob(), large = ImageCaptureJob(), gone = ImageCaptureJob()
        #expect(Self.run([.completed("Paper jam")], &failed) == [[.finish("Paper jam")]])
        #expect(Self.run([.page([1]), .pageUnreadable], &unreadable) == [[.yield([1])], [.finish("The scanner sent a page that couldn't be read.")]])
        #expect(Self.run([.pageTooLarge], &large) == [[.finish("The scanner sent a page too large to read.")]])
        #expect(Self.run([.removed], &gone) == [[.finish("The scanner was disconnected.")]])
    }

    @Test func aScanThatSaysNothingIsGivenUpOnceAndSaidSo() {
        var job = ImageCaptureJob()
        let first = job.timedOut(), second = job.timedOut()
        #expect(first == [.finish("The scanner stopped answering during the scan. Check that it's on, then try again.")])
        #expect(second.isEmpty)
        #expect(Self.run([.completed(nil)], &job) == [[]])
        #expect(ImageCaptureJob.quietLimit == .seconds(180))
    }

    @Test func theSessionIsOpenedForTheFirstUseAndClosedAfterTheLast() {
        var use = ScannerSessionUse()
        let steps = [use.begin(), use.begin(), use.end(), use.end(), use.end()]
        // Reading what it offers opens it; a scan meanwhile finds it open; the last done closes it (so the device takes
        // the next session at once); an extra end changes nothing.
        #expect(steps == [true, false, false, true, false])
        #expect(use.users == 0)
        // Two scans in a row: each opens and closes its own.
        let twice = [use.begin(), use.end(), use.begin(), use.end()]
        #expect(twice == [true, true, true, true])
    }

    /// The pre-release review: a page file up to 1 GiB was read whole on the main thread, whatever the scan asked for. A page
    /// may hold the request's pixels at 3 bytes each and 4 MiB more, never more than an eSCL page.
    @Test func aPageFileMayHoldOnlyTheRequestsPixels() {
        let slack = 4 << 20
        // A letter page at 300 dpi: 2550 × 3300 pixels.
        #expect(ImageCaptureJob.pageLimit(width: 8.5, height: 11, dpi: 300) == 2550 * 3300 * 3 + slack)
        #expect(ImageCaptureJob.pageLimit(width: 8.5, height: 11, dpi: 300) < 30 << 20)
        // A scanner's huge size or resolution: an eSCL page's limit at most.
        #expect(ImageCaptureJob.pageLimit(width: 1e6, height: 1e6, dpi: 1200) == DeviceHttp.maxScanReplyBytes)
        #expect(ImageCaptureJob.pageLimit(width: .infinity, height: 11, dpi: 300) == slack)
        #expect(ImageCaptureJob.pageLimit(width: .nan, height: 11, dpi: 300) == slack)
        #expect(ImageCaptureJob.pageLimit(width: 8.5, height: 11, dpi: 0) == slack)
        #expect(ImageCaptureJob.pageLimit(width: -8.5, height: 11, dpi: 300) == slack)
    }
}
