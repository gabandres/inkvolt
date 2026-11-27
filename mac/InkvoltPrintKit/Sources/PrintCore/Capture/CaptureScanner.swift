import Foundation

/// One photo from a capture source (the Windows Core's `CapturedPhoto`): a file's bytes as sent (a phone's JPEG or PNG,
/// checked by `CapturedPhotoInput` before it's decoded), or a camera's frame already as pixels (`frame`, upright).
public struct CapturedPhoto: Sendable {
    public var data: [UInt8]?
    public var frame: Picture?

    public init(data: [UInt8]? = nil, frame: Picture? = nil) {
        self.data = data
        self.frame = frame
    }
}

/// The photos between a capture source and its scan.
public typealias PhotoChannel = BoundedChannel<CapturedPhoto>

/// Items between one writer and one reader (the Mac's counterpart of the bounded `Channel` Windows uses: a capture's photos,
/// a shared scanner's pages): at most `capacity` held, one reader. `tryWrite` refuses when full (a camera's Capture), `write`
/// waits for room (a phone's upload, while the Mac makes pages of earlier ones; a scanner's next page, while the client
/// reads the last); `finish` ends it: what's held is still read, then `read` gives nil, and writes are refused.
public final class BoundedChannel<Item: Sendable>: @unchecked Sendable {
    public let capacity: Int
    private let lock = NSLock()
    private var items: [Item] = []
    private var finished = false
    private var reader: (id: Int, continuation: CheckedContinuation<Item?, Never>)?
    private var writers: [(id: Int, photo: Item, continuation: CheckedContinuation<Bool, Never>)] = []
    private var nextId = 0

    public init(capacity: Int) { self.capacity = max(1, capacity) }

    /// What a write does, decided under the lock.
    private enum WriteThen { case kept, refused, handed(CheckedContinuation<Item?, Never>), waits }

    /// Photos held now.
    public var count: Int { lock.withLock { items.count } }

    public var isFinished: Bool { lock.withLock { finished } }

    /// Holds `photo` when there's room and it isn't finished; false otherwise.
    public func tryWrite(_ photo: Item) -> Bool {
        let then: WriteThen = lock.withLock {
            if finished || items.count >= capacity { return .refused }
            if let r = reader {
                reader = nil
                return .handed(r.continuation) // the reader takes it now, as a channel's would
            }
            items.append(photo)
            return .kept
        }
        switch then {
        case .refused, .waits: return false
        case .kept: return true
        case .handed(let r):
            r.resume(returning: photo)
            return true
        }
    }

    /// Holds `photo`, waiting while the channel is full; false when it's finished (before or while waiting) or the task is
    /// cancelled.
    public func write(_ photo: Item) async -> Bool {
        let id = lock.withLock { () -> Int in
            nextId += 1
            return nextId
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
                let then: WriteThen = lock.withLock {
                    if finished || Task.isCancelled { return .refused }
                    if let r = reader {
                        reader = nil
                        return .handed(r.continuation)
                    }
                    if items.count < capacity {
                        items.append(photo)
                        return .kept
                    }
                    writers.append((id, photo, c))
                    return .waits
                }
                switch then {
                case .kept: c.resume(returning: true)
                case .refused: c.resume(returning: false)
                case .handed(let r):
                    r.resume(returning: photo)
                    c.resume(returning: true)
                case .waits: break
                }
            }
        } onCancel: {
            let waiting = lock.withLock { () -> CheckedContinuation<Bool, Never>? in
                guard let i = writers.firstIndex(where: { $0.id == id }) else { return nil }
                return writers.remove(at: i).continuation
            }
            waiting?.resume(returning: false)
        }
    }

    /// The next photo without waiting, or nil.
    public func tryRead() -> Item? {
        let (photo, woken): (Item?, CheckedContinuation<Bool, Never>?) = lock.withLock {
            guard !items.isEmpty else { return (nil, nil) }
            let photo = items.removeFirst()
            return (photo, admitWriter())
        }
        woken?.resume(returning: true)
        return photo
    }

    /// The next photo, waiting for one; nil once it's finished and everything held was read, or the task is cancelled.
    public func read() async -> Item? {
        let id = lock.withLock { () -> Int in
            nextId += 1
            return nextId
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Item?, Never>) in
                let (photo, woken, done): (Item?, CheckedContinuation<Bool, Never>?, Bool) = lock.withLock {
                    if !items.isEmpty {
                        let photo = items.removeFirst()
                        return (photo, admitWriter(), false)
                    }
                    if finished || Task.isCancelled { return (nil, nil, true) }
                    if let w = writers.first {
                        writers.removeFirst()
                        return (w.photo, w.continuation, false)
                    }
                    reader = (id, c)
                    return (nil, nil, false)
                }
                woken?.resume(returning: true)
                if let photo { c.resume(returning: photo) } else if done { c.resume(returning: nil) }
            }
        } onCancel: {
            let waiting = lock.withLock { () -> CheckedContinuation<Item?, Never>? in
                guard let r = reader, r.id == id else { return nil }
                reader = nil
                return r.continuation
            }
            waiting?.resume(returning: nil)
        }
    }

    /// No more photos: the reader gets what's held, then nil; waiting writers are refused.
    public func finish() {
        let (r, ws): (CheckedContinuation<Item?, Never>?, [CheckedContinuation<Bool, Never>]) = lock.withLock {
            guard !finished else { return (nil, []) }
            finished = true
            let ws = writers.map(\.continuation)
            writers = []
            let r = items.isEmpty ? reader?.continuation : nil
            if r != nil { reader = nil }
            return (r, ws)
        }
        r?.resume(returning: nil)
        ws.forEach { $0.resume(returning: false) }
    }

    /// A writer waiting for room takes the place just freed (under the lock); its continuation to resume after.
    private func admitWriter() -> CheckedContinuation<Bool, Never>? {
        guard !writers.isEmpty, items.count < capacity else { return nil }
        let w = writers.removeFirst()
        items.append(w.photo)
        return w.continuation
    }
}

/// A capture source as a scanner (roadmap 4.6, 4.12; the Windows Core's `CaptureScanner`): each photo that comes in is made
/// into a page (`PhotoPage`) at the scan's resolution and color, and handed to the scan review like a scanner's page, so the
/// review, the cleanup, OCR and the presets are the scanner's own. One scan job lasts until the source is done (the phone's
/// Done, the camera window closed): the photos' channel finishes. A photo that isn't one (or doesn't decode) is left out and
/// `leftOut` told why, in plain words; nothing it holds reaches the log.
public final class CaptureScanner: ScanDevice, @unchecked Sendable {
    private let photos: PhotoChannel
    private let codec: any PhotoCodec
    private let leftOut: (@Sendable (String) -> Void)?
    private let name: String
    private let lock = NSLock()
    private var made = 0, left = 0

    public init(_ photos: PhotoChannel, codec: any PhotoCodec, name: String = "", leftOut: (@Sendable (String) -> Void)? = nil) {
        self.photos = photos
        self.codec = codec
        self.name = name
        self.leftOut = leftOut
    }

    /// What a capture source offers: a "glass" of up to Legal size, color or grey, `PhotoPage.resolutions` (the Mac scans no
    /// black and white).
    public static func capabilities(_ name: String) -> ScannerCapabilities {
        ScannerCapabilities(makeAndModel: name, platen: InputCaps(minWidth: 300, maxWidth: Int(8.5 * 300), minHeight: 300, maxHeight: 14 * 300,
                                                                   colorModes: ["RGB24", "Grayscale8"], resolutions: PhotoPage.resolutions),
                            adf: nil, adfDuplex: false)
    }

    /// Pages made so far, and photos left out.
    public var pagesMade: Int { lock.withLock { made } }
    public var photosLeftOut: Int { lock.withLock { left } }

    public func capabilities() async throws -> ScannerCapabilities? { Self.capabilities(name) }

    public func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error> {
        let gray = request.color != .color
        let dpi = request.resolution
        return AsyncThrowingStream { continuation in
            let stop = BatchStop()
            let task = Task {
                while let photo = await photos.read() {
                    if Task.isCancelled { break }
                    let jpeg: [UInt8]? = await offPool { [codec] in
                        try? Self.make(photo, dpi: dpi, gray: gray, codec: codec, stop: stop)
                    }
                    if Task.isCancelled { break }
                    guard let jpeg else {
                        lock.withLock { left += 1 }
                        leftOut?(loc("A photo was left out: it isn't a JPEG or PNG photo the size of a page, or it didn't open."))
                        continue
                    }
                    lock.withLock { made += 1 }
                    continuation.yield(jpeg)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                stop.stop()
                task.cancel()
            }
        }
    }

    static func make(_ photo: CapturedPhoto, dpi: Int, gray: Bool, codec: any PhotoCodec, stop: BatchStop) throws -> [UInt8]? {
        var picture: Picture
        var orientation = 1
        if let frame = photo.frame {
            guard frame.width >= CapturedPhotoInput.minSide, frame.height >= CapturedPhotoInput.minSide, frame.width <= CapturedPhotoInput.maxSide,
                  frame.height <= CapturedPhotoInput.maxSide, frame.width * frame.height <= CapturedPhotoInput.maxPixels else { return nil }
            picture = frame
        } else if let data = photo.data, let header = CapturedPhotoInput.inspect(data) {
            picture = try codec.decode(data, header)
            // The decoder's size must be the header's: anything else is a file that says one thing and holds another.
            guard picture.width == header.width && picture.height == header.height else { return nil }
            orientation = header.orientation
        } else {
            return nil
        }
        let page = try PhotoPage.make(picture, orientation: orientation, dpi: dpi, gray: gray, stop: stop)
        picture = page.image
        return try codec.encodeJpeg(picture, dpi: page.dpi)
    }
}
