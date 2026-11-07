import AppKit
import PdfCore
import PrintCore

/// Draws pages through the engine off the main thread and keeps the latest image of each page: one render at a time
/// per renderer, a newer request for a page cancelling the older one (MuPDF stops midway), pages no longer wanted
/// cancelled and their images dropped. At a zoom where a whole page would be a giant bitmap, the page view asks for
/// tiles instead: squares of `tilePixels` pixels covering only what is shown, kept in a small cache.
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

    /// A tile: a square of a page drawn at one scale (its column and row in that scale's grid).
    struct TileKey: Hashable {
        var page: Int
        var scaleKey: Int
        var col: Int
        var row: Int
    }

    /// A tile's part of the page (page space) and its picture; `fresh` is false once the content changed.
    struct Tile {
        var rect: RectD
        var image: CGImage
        var fresh: Bool
    }

    static let tilePixels = 512
    /// At most this many tiles are kept (about 0.8 MB each).
    var maxTiles = 160
    private var tiles: [TileKey: Tile] = [:]
    private var tileUse: [TileKey: Int] = [:]
    private var useClock = 0
    private var pendingTiles: [TileKey: CancelToken] = [:]
    /// Called on the main thread when a tile arrived (its page and page-space rectangle).
    var onTile: ((Int, RectD) -> Void)?

    init(engine: PdfEngine, label: String, qos: DispatchQoS, keepAtMost: Int) {
        self.engine = engine
        queue = DispatchQueue(label: label, qos: qos)
        self.keepAtMost = keepAtMost
    }

    func image(_ page: Int) -> Image? { cache[page] }

    /// Dark pages (night reading) as set, unless macOS already inverts the screen's colors (Accessibility › Display ›
    /// Invert colors; Windows: not in a high-contrast theme). Pictures drawn while it is on are mapped by `NightColors`.
    static var nightReading: Bool {
        AppSettings.darkPages && !NSWorkspace.shared.accessibilityDisplayShouldInvertColors
    }

    /// Posted when dark pages are turned on or off: every page view, thumbnail list and organizer draws again.
    static let darkPagesChanged = Notification.Name("InkvoltDarkPagesChanged")

    /// A render with dark pages applied when asked.
    nonisolated private static func night(_ rendered: RenderedImage?, _ dark: Bool, _ token: CancelToken) -> RenderedImage? {
        guard dark, var image = rendered else { return rendered }
        do { try NightColors.apply(&image.pixels, cancel: token) } catch { return nil }
        return image
    }

    /// Pages the engine refused (reading them took too long, or a picture on them is too large): they aren't asked for
    /// again, and the view says so in their place (Windows' viewer). Cleared with the engine (`invalidate`).
    private(set) var refused: [Int: PageRefused] = [:]

    /// Called on the main thread when a page was refused.
    var onRefused: ((Int) -> Void)?

    /// What the view shows in a refused page's place.
    func refusal(_ page: Int) -> String? {
        guard let r = refused[page] else { return nil }
        return r.tooSlow ? loc("This page took too long to read and isn't shown") : loc("This page can't be displayed")
    }

    /// A render, or why the engine refused the page (nil for both when it failed otherwise or was cancelled).
    nonisolated private static func draw(_ work: () throws -> RenderedImage) -> (RenderedImage?, PageRefused?) {
        do {
            return (try work(), nil)
        } catch let r as PageRefused {
            return (nil, r)
        } catch {
            return (nil, nil)
        }
    }

    /// Asks for the page at `scale` pixels per point unless it is there already or on its way.
    func request(_ page: Int, scale: Double) {
        if refused[page] != nil { return }
        if let c = cache[page], abs(c.scale - scale) < 0.001 { return }
        if let p = pending[page], abs(p.scale - scale) < 0.001 { return }
        if let a = aheadRun, a.page == page, abs(a.scale - scale) < 0.001 {
            // Drawn ahead, now shown: it goes on as the page's request.
            pending[page] = (scale, a.token)
            aheadRun = nil
            return
        }
        stopAhead()
        pending[page]?.token.cancel()
        let token = CancelToken()
        pending[page] = (scale, token)
        render(page, scale, token)
    }

    private func render(_ page: Int, _ scale: Double, _ token: CancelToken) {
        let engine = engine
        let dark = Self.nightReading
        queue.async {
            let (drawn, refusal) = Self.draw { try engine.render(page, scale: scale, cancel: token) }
            let rendered = Self.night(drawn, dark, token)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.arrived(page, scale, token, rendered, refusal) }
            }
        }
    }

    // MARK: A page ahead

    /// The page the view wants drawn ahead of those shown (roadmap 3.6), and its render on its way. It shares the queue
    /// with what is shown but never holds it up: it starts only once nothing shown is waiting (no page, no tile), and a
    /// request for what is shown cancels it (MuPDF stops within milliseconds) and starts it again after.
    private var wantedAhead: (page: Int, scale: Double)?
    private var aheadRun: (page: Int, scale: Double, token: CancelToken)?

    /// Draws `page` at `scale` once nothing shown is waiting; nil: no page ahead.
    func requestAhead(_ page: Int?, scale: Double) {
        guard let page else {
            wantedAhead = nil
            stopAhead()
            return
        }
        if let a = aheadRun, a.page != page || abs(a.scale - scale) >= 0.001 { stopAhead() }
        wantedAhead = (page, scale)
        startAhead()
    }

    private func stopAhead() {
        aheadRun?.token.cancel()
        aheadRun = nil
    }

    private func startAhead() {
        guard let w = wantedAhead, aheadRun == nil, pending.isEmpty, pendingTiles.isEmpty, refused[w.page] == nil else { return }
        if let c = cache[w.page], abs(c.scale - w.scale) < 0.001 { return }
        let token = CancelToken()
        aheadRun = (w.page, w.scale, token)
        render(w.page, w.scale, token)
    }

    /// Keeps a refusal, unless its request was cancelled: `invalidate` cancels those of the engine before an edit, whose
    /// refusals say nothing of the new one's pages.
    private func refuse(_ page: Int, _ refusal: PageRefused, _ token: CancelToken) {
        guard !token.isCancelled, refused[page] == nil else { return }
        refused[page] = refusal
        cache[page] = nil
        onRefused?(page)
    }

    private func arrived(_ page: Int, _ scale: Double, _ token: CancelToken, _ rendered: RenderedImage?, _ refusal: PageRefused?) {
        if pending[page]?.token === token { pending[page] = nil }
        if aheadRun?.token === token { aheadRun = nil }
        defer { startAhead() }
        if let refusal {
            refuse(page, refusal, token)
            return
        }
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
        if let w = wantedAhead, !wanted.contains(w.page) { requestAhead(nil, scale: 0) }
        guard cache.count > keepAtMost else { return }
        let far = cache.keys.sorted { distance($0, wanted) > distance($1, wanted) }
        for page in far.prefix(cache.count - keepAtMost) where !wanted.contains(page) { cache[page] = nil }
    }

    /// The content changed: every page is drawn again, its old picture shown until the new one arrives.
    func invalidate() {
        requestAhead(nil, scale: 0)
        for p in pending.values { p.token.cancel() }
        pending = [:]
        refused = [:] // the new engine reads its pages afresh (Windows checks an edit's pages again)
        for (page, entry) in cache { cache[page] = Image(scale: -1, image: entry.image) }
        for t in pendingTiles.values { t.cancel() }
        pendingTiles = [:]
        for (key, tile) in tiles { tiles[key] = Tile(rect: tile.rect, image: tile.image, fresh: false) }
    }

    func cancelAll() {
        requestAhead(nil, scale: 0)
        for p in pending.values { p.token.cancel() }
        pending = [:]
        for t in pendingTiles.values { t.cancel() }
        pendingTiles = [:]
    }

    // MARK: Tiles

    static func scaleKey(_ scale: Double) -> Int { Int((scale * 1000).rounded()) } // bounded: the view's zoom times the screen's scale

    /// A tile's side in page points at `scale`.
    static func tileSide(_ scale: Double) -> Double { Double(tilePixels) / scale }

    /// The tiles of `page` at `scale` that cover `region` (page space) on a page of `size`: the missing ones (or those
    /// drawn before the content changed) are asked for. Their keys come back (for `keepTiles`).
    func requestTiles(_ page: Int, scale: Double, region: RectD, size: (width: Double, height: Double)) -> [TileKey] {
        let side = Self.tileSide(scale)
        guard side > 0, region.width > 0, region.height > 0, refused[page] == nil else { return [] }
        let key = Self.scaleKey(scale)
        let c0 = max(Int(region.x / side), 0), r0 = max(Int(region.y / side), 0)
        let c1 = min(Int((region.right - 0.001) / side), max(Int((size.width - 0.001) / side), 0))
        let r1 = min(Int((region.bottom - 0.001) / side), max(Int((size.height - 0.001) / side), 0))
        guard c0 <= c1, r0 <= r1 else { return [] }
        var keys: [TileKey] = []
        for row in r0...r1 {
            for col in c0...c1 {
                let k = TileKey(page: page, scaleKey: key, col: col, row: row)
                keys.append(k)
                useClock += 1
                tileUse[k] = useClock
                if tiles[k]?.fresh == true || pendingTiles[k] != nil { continue }
                let x = Double(col) * side, y = Double(row) * side
                let rect = RectD(x, y, min(side, size.width - x), min(side, size.height - y))
                renderTile(k, rect, scale)
            }
        }
        return keys
    }

    private func renderTile(_ key: TileKey, _ rect: RectD, _ scale: Double) {
        stopAhead()
        let token = CancelToken()
        pendingTiles[key] = token
        let engine = engine
        let dark = Self.nightReading
        queue.async {
            let (drawn, refusal) = Self.draw { try engine.render(key.page, scale: scale, region: rect, cancel: token) }
            let rendered = Self.night(drawn, dark, token)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.tileArrived(key, rect, token, rendered, refusal) }
            }
        }
    }

    private func tileArrived(_ key: TileKey, _ rect: RectD, _ token: CancelToken, _ rendered: RenderedImage?, _ refusal: PageRefused?) {
        if pendingTiles[key] === token { pendingTiles[key] = nil }
        defer { startAhead() }
        if let refusal {
            refuse(key.page, refusal, token)
            return
        }
        guard !token.isCancelled, let rendered, let image = Self.cgImage(rendered) else { return }
        tiles[key] = Tile(rect: rect, image: image, fresh: true)
        onTile?(key.page, rect)
    }

    /// The tiles of `page` drawn at `scale` (fresh or not), to draw over the page's picture.
    func tiles(_ page: Int, scale: Double) -> [Tile] {
        let key = Self.scaleKey(scale)
        return tiles.filter { $0.key.page == page && $0.key.scaleKey == key }.map(\.value)
    }

    /// How many of `keys` have a fresh tile (the self-test waits for all of them).
    func freshTiles(_ keys: [TileKey]) -> Int { keys.filter { tiles[$0]?.fresh == true }.count }

    /// The largest tile kept, in pixels (the self-test checks no giant bitmap is made).
    var largestTilePixels: Int { tiles.values.map { $0.image.width * $0.image.height }.max() ?? 0 }

    /// Cancels tiles on their way that aren't `wanted` and drops the least recently wanted beyond `maxTiles`.
    func keepTiles(_ wanted: Set<TileKey>) {
        for (key, token) in pendingTiles where !wanted.contains(key) {
            token.cancel()
            pendingTiles[key] = nil
        }
        guard tiles.count > maxTiles else { return }
        let old = tiles.keys.filter { !wanted.contains($0) }.sorted { (tileUse[$0] ?? 0) < (tileUse[$1] ?? 0) }
        for key in old.prefix(tiles.count - maxTiles) {
            tiles[key] = nil
            tileUse[key] = nil
        }
    }

    private func distance(_ page: Int, _ range: ClosedRange<Int>) -> Int {
        page < range.lowerBound ? range.lowerBound - page : max(0, page - range.upperBound)
    }

    /// The engine's RGB pixels as an image (any thread).
    nonisolated static func cgImage(_ r: RenderedImage) -> CGImage? {
        guard r.width > 0, r.height > 0, let provider = CGDataProvider(data: Data(r.pixels) as CFData) else { return nil }
        return CGImage(width: r.width, height: r.height, bitsPerComponent: 8, bitsPerPixel: 24, bytesPerRow: r.width * 3,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
