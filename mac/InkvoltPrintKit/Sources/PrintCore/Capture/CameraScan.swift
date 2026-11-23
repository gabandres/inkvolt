import Foundation

/// A camera macOS lists (a FaceTime camera, a webcam, a document camera, an iPhone as Continuity Camera): its id and name.
public struct CameraInfo: Equatable, Hashable, Sendable {
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// One way a camera can stream: its frame size, frames a second and pixel format (as AVFoundation names it: 420v, BGRA…).
public struct CameraFormat: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var framesPerSecond: Double
    public var subtype: String

    public init(_ width: Int, _ height: Int, _ framesPerSecond: Double, _ subtype: String) {
        self.width = width
        self.height = height
        self.framesPerSecond = framesPerSecond
        self.subtype = subtype
    }
}

/// This Mac's cameras (PrintMac's AVFoundation capture session in the app; a made-up one in demo mode).
public protocol Cameras: Sendable {
    func list() async -> [CameraInfo]

    /// Starts `camera` at the format `CameraFormats.choose` picks. Throws `CameraError` with words to show.
    func open(_ camera: CameraInfo) async throws -> any CameraFeed
}

/// A frame taken in full for a page: upright RGB, and the camera's count of it (two captures of one frame have the same).
public struct CameraFrame: Sendable {
    public var picture: Picture
    public var number: Int64

    public init(_ picture: Picture, _ number: Int64) {
        self.picture = picture
        self.number = number
    }
}

/// A camera streaming (the Windows Core's `ICameraFeed`). Its live picture is the app's (AVFoundation draws it); only a frame
/// taken is copied: `capture` copies the next frame in full. `close` stops the camera (its light goes off).
public protocol CameraFeed: AnyObject, Sendable {
    /// The frames' size (0 × 0 before the first).
    var size: (width: Int, height: Int) { get }

    /// The next frame in full; nil when none comes (the camera stopped, or the task was cancelled first).
    func capture() async -> CameraFrame?

    func close() async
}

/// A camera couldn't be started; `message` says why in plain words.
public struct CameraError: Error, Equatable, Sendable {
    public var message: String

    public init(_ message: String) { self.message = message }
}

/// Which of a camera's formats a scan uses (roadmap 4.12; the Windows Core's `CameraFormats`), and its frames as pictures.
public enum CameraFormats {
    /// A frame of BGRA pixels (rows of `bytesPerRow`, at least `width` × 4 bytes: AVFoundation's 32BGRA) as an RGB picture;
    /// nil when it isn't that size.
    public static func rgb(_ bgra: UnsafeBufferPointer<UInt8>, _ width: Int, _ height: Int, bytesPerRow: Int? = nil) -> Picture? {
        let row = bytesPerRow ?? width * 4
        guard width >= 1, height >= 1, width * height <= CapturedPhotoInput.maxPixels, row >= width * 4, bgra.count >= row * (height - 1) + width * 4 else { return nil }
        var rgb = [UInt8](repeating: 0, count: width * height * 3)
        rgb.withUnsafeMutableBufferPointer { out in
            let into = out
            try? cleanupRows(height, nil) { y in
                var i = y * row, o = y * width * 3
                for _ in 0..<width {
                    into[o] = bgra[i + 2]
                    into[o + 1] = bgra[i + 1]
                    into[o + 2] = bgra[i]
                    i += 4
                    o += 3
                }
            }
        }
        return Picture(rgb, width, height, 3)
    }

    public static func rgb(_ bgra: [UInt8], _ width: Int, _ height: Int) -> Picture? {
        guard bgra.count == width * height * 4 else { return nil }
        return bgra.withUnsafeBufferPointer { rgb($0, width, height) }
    }

    /// A preview slower than this (frames a second) is too slow to aim the page by.
    public static let minFramesPerSecond = 5.0

    /// The format with the most pixels within `CapturedPhotoInput`'s limits that streams at least `minFramesPerSecond` (a document
    /// camera's 4K at 15, not its 13 megapixels at 2), the faster of two the same size; none that fast: the largest within the
    /// limits. Nil when there's none at all (every format larger than the limits, or under its smallest side).
    public static func choose(_ formats: [CameraFormat]) -> CameraFormat? {
        let usable = formats.filter {
            $0.width >= CapturedPhotoInput.minSide && $0.height >= CapturedPhotoInput.minSide && $0.width <= CapturedPhotoInput.maxSide && $0.height <= CapturedPhotoInput.maxSide
                && $0.width * $0.height <= CapturedPhotoInput.maxPixels && $0.framesPerSecond.isFinite
        }
        let smooth = usable.filter { $0.framesPerSecond >= minFramesPerSecond }
        let list = smooth.isEmpty ? usable : smooth
        var best: CameraFormat?
        for f in list {
            guard let b = best else {
                best = f
                continue
            }
            if (f.width * f.height, f.framesPerSecond) > (b.width * b.height, b.framesPerSecond) { best = f }
        }
        return best
    }
}

/// One camera scan (roadmap 4.12; the Windows Core's `CameraSession`): each Capture takes the camera's next frame in full and
/// hands it to the scan as a photo (`CaptureScanner` makes it a page), one capture at a time, never the same frame twice, at
/// most `waiting` frames held while the Mac makes pages of earlier ones (Capture is off past that) and `maxPages` in all;
/// Done (or the window closing) ends it.
public final class CameraSession: @unchecked Sendable {
    public static let maxPages = 100

    /// Full frames held before they're made pages (each tens of megabytes at 4K).
    public static let waiting = 2

    public let photos = PhotoChannel(capacity: CameraSession.waiting)
    private let lock = NSLock()
    private var taken = 0
    private var lastFrame: Int64 = -1
    private var finished = false
    private var capturing = false

    public init() {}

    public var pagesTaken: Int { lock.withLock { taken } }

    public var isFinished: Bool { lock.withLock { finished } }

    /// A capture may start now: the scan is on, under `maxPages`, no capture under way and fewer than `waiting` frames
    /// waiting to be made pages.
    public var canCapture: Bool { lock.withLock { !finished && taken < Self.maxPages && !capturing && photos.count < Self.waiting } }

    /// Takes `feed`'s next frame as the next page. False when it can't now (`canCapture`), no frame came, the frame is the
    /// one taken last, or the scan ended meanwhile.
    public func capture(_ feed: (any CameraFeed)?) async -> Bool {
        guard let feed else { return false }
        let start: Bool = lock.withLock {
            if finished || taken >= Self.maxPages || capturing || photos.count >= Self.waiting { return false }
            capturing = true
            return true
        }
        guard start else { return false }
        let frame = await feed.capture()
        lock.withLock { capturing = false }
        guard let frame else { return false }
        return lock.withLock {
            if finished || taken >= Self.maxPages || frame.number == lastFrame { return false }
            // Counted only once it's in, under the lock, so finish can't come between.
            guard photos.tryWrite(CapturedPhoto(frame: frame.picture)) else { return false }
            taken += 1
            lastFrame = frame.number
            return true
        }
    }

    /// Done: the frames taken go on to be pages, nothing more is taken.
    public func finish() {
        let first: Bool = lock.withLock {
            if finished { return false }
            finished = true
            return true
        }
        if first { photos.finish() }
    }

    /// The line under the picture: how many pages were taken, when the Mac is catching up, and when no more can be.
    public func statusText() -> String {
        let (n, held) = lock.withLock { (taken, photos.count) }
        return n >= Self.maxPages ? loc("That's the most pages one scan takes: press Done, then start another.")
            : held >= Self.waiting ? loc("Wait a moment: the Mac is making pages of the last captures.")
            : n == 0 ? loc("Put a page under the camera, then Capture page. Each capture is a page.")
            : n == 1 ? loc("1 page captured. Put the next one under the camera, or Done.")
            : loc("{0} pages captured. Put the next one under the camera, or Done.", CoreLanguage.number(n))
    }
}
