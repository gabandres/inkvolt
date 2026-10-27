import Foundation
import MuPDFShim

/// A document needs a password to open (the Windows app's `PasswordRequiredException`); `wrongPassword` when one was
/// given and didn't open it.
public struct PasswordRequired: Error, Equatable, Sendable {
    public var wrongPassword: Bool
}

/// MuPDF couldn't do it, or the engine refused (an image too large): the reason in words.
public struct PdfEngineError: Error, Equatable, Sendable, CustomStringConvertible {
    public var message: String
    public var description: String { message }
}

/// The engine was closed (.NET's `ObjectDisposedException`).
public struct PdfEngineClosed: Error, Equatable, Sendable {}

/// A bookmark; `targetY`: where on the page it leads (page space, points from the top), when the destination says.
public struct OutlineNode: Equatable, Sendable {
    public var title: String
    public var pageIndex: Int
    public var children: [OutlineNode]
    public var targetY: Double?
}

/// A clickable area on a page: an internal jump (`pageIndex`, plus `targetY` in the target page's space when the
/// destination names a position) or an external `uri` (`pageIndex` -1).
public struct PageLink: Equatable, Sendable {
    public var area: RectD
    public var pageIndex: Int
    public var uri: String?
    public var targetY: Double?
}

/// Pixels from a render: RGB, three bytes a pixel, rows packed (the Windows `RenderedImage` is BGR).
public struct RenderedImage: Equatable, Sendable {
    public var width: Int
    public var height: Int
    public var pixels: [UInt8]

    public init(_ width: Int, _ height: Int, _ pixels: [UInt8]) {
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var stride: Int { width * 3 }

    /// The image turned clockwise by `rotation` (0, 90, 180 or 270); itself for 0.
    public func rotated(_ rotation: Int, cancel: CancelToken? = nil) throws -> RenderedImage {
        let rotation = RotatedView.normalize(rotation)
        if rotation == 0 { return self }
        let (w, h) = rotation == 180 ? (width, height) : (height, width)
        var dst = [UInt8](repeating: 0, count: pixels.count)
        let sw = width, sh = height, dstStride = w * 3
        try pixels.withUnsafeBufferPointer { src in
            try dst.withUnsafeMutableBufferPointer { out in
                for y in 0..<sh {
                    if y & 63 == 0 { try cancel.check() }
                    var s = y * sw * 3
                    for x in 0..<sw {
                        // Clockwise: 90 sends (x, y) to (h' - 1 - y, x); 180 to (w - 1 - x, h - 1 - y); 270 to (y, w - 1 - x).
                        let (dx, dy): (Int, Int)
                        switch rotation {
                        case 90: (dx, dy) = (sh - 1 - y, x)
                        case 180: (dx, dy) = (sw - 1 - x, sh - 1 - y)
                        default: (dx, dy) = (y, sw - 1 - x)
                        }
                        let d = dy * dstStride + dx * 3
                        out[d] = src[s]
                        out[d + 1] = src[s + 1]
                        out[d + 2] = src[s + 2]
                        s += 3
                    }
                }
            }
        }
        return RenderedImage(w, h, dst)
    }
}

/// One open document in MuPDF (the Windows app's `PdfEngine`). A MuPDF document is used by one thread at a time, so
/// every call takes a lock; callers may use it from any thread. Text, links and outline come from a second MuPDF
/// instance of the same file with its own lock, so the text never waits behind a render. Each instance keeps only its
/// most recently used pages loaded (`loadedPagesKept`), so memory stays bounded however far a long document is scrolled.
public final class PdfEngine: @unchecked Sendable {
    static let textCacheSize = 48
    /// MuPDF pages (with their display lists) kept loaded per instance; older ones are freed.
    static let loadedPagesKept = 32
    /// Largest render or image export allowed, in pixels (200 MP is 600 MB of RGB).
    public static let maxPixels = 200_000_000.0

    /// One MuPDF context and its document. Used only under its engine's lock.
    private final class Instance {
        let ctx: UnsafeMutableRawPointer
        let doc: OpaquePointer

        init(ctx: UnsafeMutableRawPointer, doc: OpaquePointer) {
            self.ctx = ctx
            self.doc = doc
        }

        deinit {
            inkv_drop_doc(ctx, doc)
            inkv_drop_context(ctx)
        }

        /// Opens the source in a new context of `store` bytes; with `password` when it needs one.
        static func open(_ source: Source, store: Int, password: String?) throws -> Instance {
            guard let ctx = inkv_new_context(store) else { throw PdfEngineError(message: "MuPDF couldn't start.") }
            var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
            let doc: OpaquePointer?
            switch source {
            case .bytes(let data):
                doc = data.withUnsafeBufferPointer { inkv_open_pdf(ctx, $0.baseAddress, $0.count, Int32(PdfEngine.loadedPagesKept), &err) }
            case .path(let path):
                doc = inkv_open_path(ctx, path, Int32(PdfEngine.loadedPagesKept), &err)
            }
            guard let doc else {
                inkv_drop_context(ctx)
                throw PdfEngineError(message: PdfEngine.message(err))
            }
            let instance = Instance(ctx: ctx, doc: doc)
            if inkv_needs_password(ctx, doc) != 0 {
                guard let password, !password.isEmpty else { throw PasswordRequired(wrongPassword: false) }
                guard inkv_authenticate(ctx, doc, password) != 0 else { throw PasswordRequired(wrongPassword: true) }
            }
            return instance
        }
    }

    enum Source {
        case bytes([UInt8])
        case path(String)
    }

    // Lock order: gate before textGate (only close and the loadedCounts test hook take both).
    private let gate = NSLock()
    private let textGate = NSLock()
    private var main: Instance?             // nil once closed; under gate
    private var textInstance: Instance?     // under textGate
    private let source: Source
    private let password: String?
    private let pages: [PageGeometry]
    private var closed = false              // set under both locks
    private var textCache: [Int: PageText] = [:]
    private var textLru: [Int] = []
    private var linkCache: [Int: [PageLink]] = [:]
    private var outlineCache: [OutlineNode]?

    public var pageCount: Int { pages.count }
    public let isEncrypted: Bool

    private init(_ main: Instance, source: Source, password: String?) throws {
        self.main = main
        self.source = source
        self.password = password
        // Needs a password to open, as MuPDF says (a document that only restricts printing, copying or editing is not).
        isEncrypted = inkv_needs_password(main.ctx, main.doc) != 0
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        let count = inkv_count_pages(main.ctx, main.doc, &err)
        guard count >= 0 else { throw PdfEngineError(message: Self.message(err)) }
        var pages: [PageGeometry] = []
        pages.reserveCapacity(Int(count))
        var b = [Float](repeating: 0, count: 4)
        for i in 0..<Int(count) {
            guard inkv_page_bounds(main.ctx, main.doc, Int32(i), &b, &err) != 0 else { throw PdfEngineError(message: Self.message(err)) }
            pages.append(PageGeometry(Double(b[0]), Double(b[1]), Double(b[2] - b[0]), Double(b[3] - b[1])))
        }
        self.pages = pages
    }

    /// Opens a PDF from its bytes; `password` opens an encrypted one (ignored when it needs none).
    /// - Throws: `PasswordRequired` when the document is encrypted and the password is missing or wrong.
    public static func open(_ data: [UInt8], password: String? = nil) throws -> PdfEngine {
        // MuPDF's resource store (decoded images, fonts) at 128 MB keeps re-renders fast without letting several open
        // tabs balloon.
        let source = Source.bytes(data)
        return try PdfEngine(Instance.open(source, store: 128 << 20, password: password), source: source, password: password)
    }

    /// Opens a file in place (MuPDF reads only what it needs), e.g. for a quick preview; nil when it's encrypted.
    public static func openPreview(path: String) throws -> PdfEngine? {
        let source = Source.path(path)
        do {
            return try PdfEngine(Instance.open(source, store: 32 << 20, password: nil), source: source, password: nil)
        } catch is PasswordRequired {
            return nil
        }
    }

    public func page(_ index: Int) -> PageGeometry { pages[index] }

    /// Renders a page (or a region of it, in page points) at `scale` pixels per point.
    /// - Throws: `CancellationError` when `cancel` fires (MuPDF stops mid-render); `PdfEngineError` when the image would
    ///   exceed `maxPixels`.
    public func render(_ page: Int, scale: Double, region: RectD? = nil, cancel: CancelToken? = nil) throws -> RenderedImage {
        try cancel.check()
        gate.lock()
        defer { gate.unlock() }
        guard let main else { throw PdfEngineClosed() }
        try cancel.check()
        let g = pages[page]
        let r = region ?? RectD(0, 0, g.width, g.height)
        try Self.checkSize(r.width * scale, r.height * scale)
        let cookie = cancel == nil ? nil : inkv_new_cookie()
        defer { inkv_drop_cookie(cookie) }
        let handler = cookie.flatMap { c in cancel?.register { inkv_cookie_abort(c) } }
        defer { cancel?.unregister(handler) }
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        var pixels: UnsafeMutablePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0
        let result = inkv_render_rgb(main.ctx, main.doc, Int32(page), Float(scale), Float(g.originX + r.x), Float(g.originY + r.y),
                                     Float(g.originX + r.right), Float(g.originY + r.bottom), cookie, &pixels, &width, &height, &err)
        defer { inkv_free(pixels) }
        if result == 2 { throw CancellationError() }
        guard result == 1, let pixels else { throw PdfEngineError(message: Self.message(err)) }
        try cancel.check()
        return RenderedImage(Int(width), Int(height), Array(UnsafeBufferPointer(start: pixels, count: Int(width) * Int(height) * 3)))
    }

    /// Renders a page straight to a PNG or JPEG file at the given resolution.
    /// - Throws: `CancellationError` when `cancel` fired before the render started; `PdfEngineError` when the image
    ///   would exceed `maxPixels`.
    public func saveImage(_ page: Int, dpi: Double, path: String, jpeg: Bool, cancel: CancelToken? = nil) throws {
        try cancel.check()
        gate.lock()
        defer { gate.unlock() }
        guard let main else { throw PdfEngineClosed() }
        try cancel.check()
        let scale = dpi / 72
        let g = pages[page]
        try Self.checkSize((g.width * scale).rounded(.up), (g.height * scale).rounded(.up))
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        guard inkv_save_image(main.ctx, main.doc, Int32(page), Float(scale), path, jpeg ? 1 : 0, &err) != 0 else {
            throw PdfEngineError(message: Self.message(err))
        }
    }

    private static func checkSize(_ width: Double, _ height: Double) throws {
        if width * height > maxPixels {
            throw PdfEngineError(message: "The image would be too large (\(Int(width.rounded())) x \(Int(height.rounded())) pixels). Use a lower zoom or resolution.")
        }
    }

    /// The text instance, opened on first use. Call under textGate.
    private func text() throws -> Instance {
        if closed { throw PdfEngineClosed() }
        if let textInstance { return textInstance }
        let instance: Instance
        do {
            instance = try Instance.open(source, store: 32 << 20, password: password ?? "")
        } catch is PasswordRequired {
            throw PasswordRequired(wrongPassword: true)
        }
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        if Int(inkv_count_pages(instance.ctx, instance.doc, &err)) != pages.count {
            throw PdfEngineError(message: "The document changed while open.")
        }
        textInstance = instance
        return instance
    }

    /// Takes the text lock. While another page's text is being read it waits, but gives up as soon as `cancel` fires
    /// (a cancelled job doesn't queue up behind a long extraction).
    private func enterText(_ cancel: CancelToken?) throws {
        guard let cancel else {
            textGate.lock()
            return
        }
        while !textGate.lock(before: Date(timeIntervalSinceNow: 0.02)) { try cancel.check() }
        if cancel.isCancelled {
            textGate.unlock()
            throw CancellationError()
        }
    }

    /// The page's text layer (cached; cheap to call again from the UI).
    /// - Throws: `CancellationError` when `cancel` fired before the page was read.
    public func text(_ page: Int, cache: Bool = true, cancel: CancelToken? = nil) throws -> PageText {
        try cancel.check()
        try enterText(cancel)
        defer { textGate.unlock() }
        let instance = try text()
        if let hit = textCache[page] {
            textLru.removeAll { $0 == page }
            textLru.insert(page, at: 0)
            return hit
        }
        let text = try extractText(instance, page)
        if cache {
            textCache[page] = text
            textLru.insert(page, at: 0)
            while textLru.count > Self.textCacheSize { textCache[textLru.removeLast()] = nil }
        }
        return text
    }

    private func extractText(_ instance: Instance, _ page: Int) throws -> PageText {
        let g = pages[page]
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        var lines: UnsafeMutablePointer<inkv_line>?
        var chars: UnsafeMutablePointer<inkv_char>?
        var lineCount: Int32 = 0, charCount: Int32 = 0
        guard inkv_page_chars(instance.ctx, instance.doc, Int32(page), &lines, &lineCount, &chars, &charCount, &err) != 0 else {
            throw PdfEngineError(message: Self.message(err))
        }
        defer {
            inkv_free(lines)
            inkv_free(chars)
        }
        var result: [[(String, RectD)]] = []
        var directions: [(Double, Double)] = []
        for li in 0..<Int(lineCount) {
            let line = lines![li]
            var list: [(String, RectD)] = []
            list.reserveCapacity(Int(line.count))
            for ci in Int(line.first)..<Int(line.first + line.count) {
                let c = chars![ci]
                let ch = Unicode.Scalar(UInt32(bitPattern: c.c)).map { String(Character($0)) } ?? "\u{FFFD}"
                list.append((ch, RectD.fromEdges(Double(c.x0) - g.originX, Double(c.y0) - g.originY,
                                                 Double(c.x1) - g.originX, Double(c.y1) - g.originY)))
            }
            result.append(list)
            directions.append((Double(line.dx), Double(line.dy))) // the baseline's direction (sideways text: vertical)
        }
        return PageText(result, directions: directions)
    }

    /// - Throws: `CancellationError` when `cancel` fired before the links were read.
    public func links(_ page: Int, cancel: CancelToken? = nil) throws -> [PageLink] {
        try cancel.check()
        try enterText(cancel)
        defer { textGate.unlock() }
        let instance = try text()
        if let cached = linkCache[page] { return cached }
        let g = pages[page]
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        var raw: UnsafeMutablePointer<inkv_link>?
        var count: Int32 = 0
        guard inkv_page_links(instance.ctx, instance.doc, Int32(page), &raw, &count, &err) != 0 else {
            throw PdfEngineError(message: Self.message(err))
        }
        defer { inkv_free_links(raw, count) }
        var list: [PageLink] = []
        for i in 0..<Int(count) {
            let l = raw![i]
            let area = RectD.fromEdges(Double(l.x0) - g.originX, Double(l.y0) - g.originY, Double(l.x1) - g.originX, Double(l.y1) - g.originY)
            if let uri = l.uri {
                let text = String(cString: uri)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    list.append(PageLink(area: area, pageIndex: -1, uri: text, targetY: nil))
                }
            } else if l.page >= 0 && Int(l.page) < pages.count {
                list.append(PageLink(area: area, pageIndex: Int(l.page), uri: nil, targetY: targetY(Int(l.page), l.y)))
            }
        }
        linkCache[page] = list
        return list
    }

    /// The bookmarks; a broken outline is none (it must not stop the document from opening).
    public func outline() throws -> [OutlineNode] {
        textGate.lock()
        defer { textGate.unlock() }
        let instance = try text()
        if let outlineCache { return outlineCache }
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        var raw: UnsafeMutablePointer<inkv_outline_item>?
        var count: Int32 = 0
        var flat: [(depth: Int, node: OutlineNode)] = []
        if inkv_outline(instance.ctx, instance.doc, &raw, &count, &err) != 0 {
            for i in 0..<Int(count) {
                let item = raw![i]
                let title = item.title.map { String(cString: $0) } ?? ""
                flat.append((Int(item.depth), OutlineNode(title: title, pageIndex: Int(item.page), children: [],
                                                          targetY: targetY(Int(item.page), item.y))))
            }
            inkv_free_outline(raw, count)
        }
        var index = 0
        let tree = Self.nest(flat, depth: 0, &index)
        outlineCache = tree
        return tree
    }

    /// The flattened outline's entries from `index` on at `depth`, with their children.
    private static func nest(_ flat: [(depth: Int, node: OutlineNode)], depth: Int, _ index: inout Int) -> [OutlineNode] {
        var nodes: [OutlineNode] = []
        while index < flat.count && flat[index].depth >= depth {
            var node = flat[index].node
            let own = flat[index].depth
            index += 1
            node.children = nest(flat, depth: own + 1, &index)
            nodes.append(node)
        }
        return nodes
    }

    /// A destination's y (MuPDF page space) in our page space, or nil when the destination names no position.
    private func targetY(_ page: Int, _ y: Float) -> Double? {
        guard page >= 0 && page < pages.count && y.isFinite else { return nil }
        return min(max(Double(y) - pages[page].originY, 0), pages[page].height)
    }

    /// Closes the document; later calls throw `PdfEngineClosed`. Safe while another thread reads text.
    public func close() {
        gate.lock()
        textGate.lock()
        closed = true
        textInstance = nil
        main = nil
        textGate.unlock()
        gate.unlock()
    }

    /// Test hook: MuPDF pages and display lists the render and text instances hold loaded.
    func loadedCounts() -> (render: (pages: Int, lists: Int), text: (pages: Int, lists: Int)) {
        gate.lock()
        textGate.lock()
        defer {
            textGate.unlock()
            gate.unlock()
        }
        func held(_ i: Instance?) -> (Int, Int) {
            guard let i else { return (0, 0) }
            var p: Int32 = 0, l: Int32 = 0
            inkv_loaded(i.doc, &p, &l)
            return (Int(p), Int(l))
        }
        return (held(main), held(textInstance))
    }

    /// The document written out whole with MuPDF's write options (D2's saving builds on this; the tests encrypt with it).
    func write(options: String) throws -> [UInt8] {
        gate.lock()
        defer { gate.unlock() }
        guard let main else { throw PdfEngineClosed() }
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        var out: UnsafeMutablePointer<UInt8>?
        var length = 0
        guard inkv_write_pdf(main.ctx, main.doc, options, &out, &length, &err) != 0, let out else {
            throw PdfEngineError(message: Self.message(err))
        }
        defer { inkv_free(out) }
        return Array(UnsafeBufferPointer(start: out, count: length))
    }

    static func message(_ err: [CChar]) -> String {
        let bytes = err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? "MuPDF failed." : String(decoding: bytes, as: UTF8.self)
    }
}
