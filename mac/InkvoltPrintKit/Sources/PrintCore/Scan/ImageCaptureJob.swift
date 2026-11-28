import Foundation

/// One scan through ImageCaptureCore as PrintMac's `SystemScanDevice` drives it, the rules without the framework (so they're
/// tested on the PC): when the selected unit is ready to scan, what each word from the scanner does to the scan, and when
/// a scan that says nothing is given up. Found with a network all-in-one on 2026-11-27: right after a session opens the
/// selected unit is still empty (no size, no resolution), and a scan asked of it never ends; and a scan that ends with no
/// page and no error must say so, never look like an empty success.
public struct ImageCaptureJob: Sendable {
    /// What the scanner said.
    public enum Event: Equatable, Sendable {
        /// A page's file, read (`SystemScanDevice.pageFile`).
        case page([UInt8])
        case pageTooLarge
        case pageUnreadable
        /// The scan is over (ImageCaptureCore's error in plain words, or nil).
        case completed(String?)
        /// The scanner was unplugged or turned off.
        case removed
    }

    /// What to do: hand a page on, or end the scan (with the reason in words, or none) and close the session.
    public enum Action: Equatable, Sendable {
        case yield([UInt8])
        case finish(String?)
    }

    /// How long a scan may go without a page or its end before it's given up (a page at a high resolution on a slow
    /// flatbed takes a minute or two; eSCL's client waits as long).
    public static let quietLimit: Duration = .seconds(180)

    public private(set) var pages = 0
    public private(set) var isOver = false

    public init() {}

    /// The most bytes a page file of this scan may hold before it's refused unread (the pre-release review: any file up to
    /// 1 GiB was read on the main thread): its area in inches at `dpi`, 3 bytes a pixel (RGB, as uncompressed as a JPEG gets)
    /// and 4 MiB for headers and a JPEG's worst case, never more than an eSCL page's `DeviceHttp.maxScanReplyBytes`. A size or
    /// resolution that isn't a positive number gives the 4 MiB alone.
    public static func pageLimit(width: Double, height: Double, dpi: Double) -> Int {
        let slack = 4 << 20, most = DeviceHttp.maxScanReplyBytes
        guard width.isFinite, height.isFinite, dpi.isFinite, width > 0, height > 0, dpi > 0 else { return slack }
        let bytes = (width * dpi) * (height * dpi) * 3 + Double(slack)
        guard bytes.isFinite, bytes < Double(most) else { return most }
        return Int(bytes.rounded(.up)) // bounded: under `most` above
    }

    /// A unit is ready to scan once it says its size and at least one resolution.
    public static func unitReady(width: Double, height: Double, resolutions: Int) -> Bool {
        width.isFinite && height.isFinite && width > 0 && height > 0 && resolutions > 0
    }

    /// What `event` does. Nothing once the scan is over (a late page, a second end).
    public mutating func handle(_ event: Event) -> [Action] {
        guard !isOver else { return [] }
        switch event {
        case .page(let bytes):
            pages += 1
            return [.yield(bytes)]
        case .pageTooLarge:
            return end(loc("The scanner sent a page too large to read."))
        case .pageUnreadable:
            // Never one page short without a word: the scan ends and says so.
            return end(loc("The scanner sent a page that couldn't be read."))
        case .completed(let error?):
            return end(error)
        case .completed(nil):
            return end(pages == 0 ? Self.noPage : nil)
        case .removed:
            return end(loc("The scanner was disconnected."))
        }
    }

    /// The scan said nothing for `quietLimit`: it's given up (the scanner is asked to stop) and said so.
    public mutating func timedOut() -> [Action] {
        guard !isOver else { return [] }
        return end(loc("The scanner stopped answering during the scan. Check that it's on, then try again."))
    }

    /// A scan that ended without a page and without an error.
    public static var noPage: String {
        loc("The scanner finished without sending a page. Check that it's on and that the page is on the glass or in the feeder, then try again.")
    }

    private mutating func end(_ reason: String?) -> [Action] {
        isOver = true
        return [.finish(reason)]
    }
}

/// Who is using a scanner's ImageCaptureCore session (reading what it offers, scanning): it's opened for the first and
/// closed after the last, so the device takes another app's session (or ours again) at once. A network all-in-one
/// refused new sessions for minutes after an app left one open (ImageCaptureCore's -21345).
public struct ScannerSessionUse: Sendable {
    public private(set) var users = 0

    public init() {}

    /// One more user; true when the session must be opened for it.
    public mutating func begin() -> Bool {
        users += 1
        return users == 1
    }

    /// One user done; true when the session must be closed now.
    public mutating func end() -> Bool {
        guard users > 0 else { return false }
        users -= 1
        return users == 0
    }
}
