import AppKit
import PdfCore

/// Draws pages through the engine off the main thread and keeps the latest image of each page: one render at a time
/// per renderer, a newer request for a page cancelling the older one (MuPDF stops midway), pages no longer wanted
/// cancelled and their images dropped.
@MainActor
final class PageRenderer {
    struct Image {
        var scale: Double
        var image: CGImage
    }

    /// Replaced after an edit, undo, redo or reload (call `invalidate` then).
    var engine: PdfEngine
    private let queue: DispatchQueue
    private let keepAtMost: Int
    private var cache: [Int: Image] = [:]
    private var pending: [Int: (scale: Double, token: CancelToken)] = [:]

    /// Called on the main thread when a page's image arrived.
    var onRendered: ((Int, Image) -> Void)?

    init(engine: PdfEngine, label: String, qos: DispatchQoS, keepAtMost: Int) {
        self.engine = engine
        queue = DispatchQueue(label: label, qos: qos)
        self.keepAtMost = keepAtMost
    }

    func image(_ page: Int) -> Image? { cache[page] }

    /// Asks for the page at `scale` pixels per point unless it is there already or on its way.
    func request(_ page: Int, scale: Double) {
        if let c = cache[page], abs(c.scale - scale) < 0.001 { return }
        if let p = pending[page], abs(p.scale - scale) < 0.001 { return }
        pending[page]?.token.cancel()
        let token = CancelToken()
        pending[page] = (scale, token)
        let engine = engine
        queue.async {
            let rendered = try? engine.render(page, scale: scale, cancel: token)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.arrived(page, scale, token, rendered) }
            }
        }
    }

    private func arrived(_ page: Int, _ scale: Double, _ token: CancelToken, _ rendered: RenderedImage?) {
        if pending[page]?.token === token { pending[page] = nil }
        guard !token.isCancelled, let rendered, let image = Self.cgImage(rendered) else { return }
        let entry = Image(scale: scale, image: image)
        cache[page] = entry
        onRendered?(page, entry)
    }

    /// Cancels what isn't in `wanted` and drops the images of pages furthest from it beyond the cache's size.
    func keep(_ wanted: ClosedRange<Int>) {
        for (page, p) in pending where !wanted.contains(page) {
            p.token.cancel()
            pending[page] = nil
        }
        guard cache.count > keepAtMost else { return }
        let far = cache.keys.sorted { distance($0, wanted) > distance($1, wanted) }
        for page in far.prefix(cache.count - keepAtMost) where !wanted.contains(page) { cache[page] = nil }
    }

    /// The content changed: every page is drawn again, its old picture shown until the new one arrives.
    func invalidate() {
        for p in pending.values { p.token.cancel() }
        pending = [:]
        for (page, entry) in cache { cache[page] = Image(scale: -1, image: entry.image) }
    }

    func cancelAll() {
        for p in pending.values { p.token.cancel() }
        pending = [:]
    }

    private func distance(_ page: Int, _ range: ClosedRange<Int>) -> Int {
        page < range.lowerBound ? range.lowerBound - page : max(0, page - range.upperBound)
    }

    /// The engine's RGB pixels as an image.
    static func cgImage(_ r: RenderedImage) -> CGImage? {
        guard r.width > 0, r.height > 0, let provider = CGDataProvider(data: Data(r.pixels) as CFData) else { return nil }
        return CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: r.width * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
