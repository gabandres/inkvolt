import Foundation
import MuPDFShim
import PrintCore

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

    /// The file's bytes, one copy for all of an engine's instances: MuPDF reads them in place (each instance once copied
    /// the whole file, so a 600 MB drawing set took 1.2 GB for an engine and 600 MB more for each thread of a search).
    final class SharedBytes: @unchecked Sendable {
        let base: UnsafeMutableRawPointer
        let count: Int

        init(_ data: [UInt8]) {
            count = data.count
            base = .allocate(byteCount: max(count, 1), alignment: 16)
            data.withUnsafeBytes { if let from = $0.baseAddress { base.copyMemory(from: from, byteCount: count) } }
        }

        deinit { base.deallocate() }
    }

    /// One MuPDF context and its document. Used only under its engine's lock.
    private final class Instance {
        let ctx: UnsafeMutableRawPointer
        let doc: OpaquePointer
        /// The bytes the document reads in place: released only after the document is dropped (deinit runs first).
        private let bytes: SharedBytes?

        init(ctx: UnsafeMutableRawPointer, doc: OpaquePointer, bytes: SharedBytes?) {
            self.ctx = ctx
            self.doc = doc
            self.bytes = bytes
        }

        deinit {
            inkv_drop_doc(ctx, doc)
            inkv_drop_context(ctx)
        }

        /// Opens the source in a new context of `store` bytes; with `password` when it needs one.
        static func open(_ source: Source, store: Int, password: String?) throws -> Instance {
            guard let ctx = inkv_new_context(store) else { throw PdfEngineError(message: "MuPDF couldn't start.") } // English: the engine's own failure, for a developer
            var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
            let doc: OpaquePointer?
            var shared: SharedBytes?
            switch source {
            case .bytes(let data):
                shared = data
                doc = inkv_open_pdf_shared(ctx, data.base.assumingMemoryBound(to: UInt8.self), data.count, Int32(PdfEngine.loadedPagesKept), &err)
            case .path(let path):
                doc = inkv_open_path(ctx, path, Int32(PdfEngine.loadedPagesKept), &err)
            }
            guard let doc else {
                inkv_drop_context(ctx)
                throw PdfEngineError(message: PdfEngine.message(err))
            }
            let instance = Instance(ctx: ctx, doc: doc, bytes: shared)
            if inkv_needs_password(ctx, doc) != 0 {
                guard let password, !password.isEmpty else { throw PasswordRequired(wrongPassword: false) }
                guard inkv_authenticate(ctx, doc, password) != 0 else { throw PasswordRequired(wrongPassword: true) }
            }
            return instance
        }
    }

    enum Source {
        case bytes(SharedBytes)
        case path(String)
    }

    // Lock order: gate before textGate (only close and the loadedCounts test hook take both).
    private let gate = NSLock()
    private let textGate = NSLock()
    private var main: Instance?             // nil once closed; under gate
    private var textInstance: Instance?     // under textGate
    /// What the instances open; nil once closed, so a closed engine no longer holds the file's bytes. Read under gate or
    /// textGate (close changes it holding both).
    private var source: Source?
    private let password: String?
    private let pages: [PageGeometry]
    private var closed = false              // set under both locks
    private var textCache: [Int: PageText] = [:]
    private var textLru: [Int] = []
    private var linkCache: [Int: [PageLink]] = [:]
    /// What `findAll` remembers of each page's text between searches.
    private let findMemo: FindMemo
    private var outlineCache: [OutlineNode]?

    public var pageCount: Int { pages.count }
    public let isEncrypted: Bool

    /// Seconds a call may spend reading a page's content (the page check's limit on Windows, 10 s); tests shorten it.
    public static var defaultPageBudget: Double { budgetForTests ?? 10 }
    @TaskLocal static var budgetForTests: Double?

    /// This engine's budget for reading a page (0: no limit).
    public var pageBudget: Double {
        get { verdicts.budget }
        set { verdicts.budget = newValue }
    }

    private let verdicts = PageVerdicts()

    /// What reading the page found so far.
    public func verdictOf(_ page: Int) -> PageVerdict { verdicts[page] }

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
        findMemo = FindMemo(pages.count)
    }

    /// A file's bytes read straight into one array: `Data(contentsOf:)` then `[UInt8]` held two copies at once (a 428 MB
    /// scan peaked at 2.2 GB just reading).
    public static func readFile(_ path: String) throws -> [UInt8] {
        let fd = Darwin.open(path, O_RDONLY)
        guard fd >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: path]) }
        defer { Darwin.close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path]) }
        let size = Int(st.st_size)
        var failed = false
        let bytes = [UInt8](unsafeUninitializedCapacity: size) { buf, count in
            var done = 0
            while done < size {
                let n = Darwin.read(fd, buf.baseAddress! + done, size - done)
                if n <= 0 {
                    if n < 0 && errno == EINTR { continue }
                    failed = n < 0
                    break
                }
                done += n
            }
            count = done
        }
        if failed { throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: path]) }
        return bytes
    }

    /// Opens a PDF from its bytes; `password` opens an encrypted one (ignored when it needs none).
    /// - Throws: `PasswordRequired` when the document is encrypted and the password is missing or wrong.
    public static func open(_ data: [UInt8], password: String? = nil) throws -> PdfEngine {
        // MuPDF's resource store (decoded images, fonts) at 128 MB keeps re-renders fast without letting several open
        // tabs balloon.
        let source = Source.bytes(SharedBytes(data))
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

    /// The page's geometry, or `PdfEngineError` when there is no such page (a caller's stale index must not crash).
    private func geometry(_ page: Int) throws -> PageGeometry {
        guard pages.indices.contains(page) else { throw PdfEngineError(message: loc("There is no page {0}.", CoreLanguage.number(page + 1))) }
        return pages[page]
    }

    /// Renders a page (or a region of it, in page points) at `scale` pixels per point.
    /// - Throws: `CancellationError` when `cancel` fires (MuPDF stops mid-render); `PdfEngineError` when the image would
    ///   exceed `maxPixels`.
    /// - Parameter annotations: false draws the page's own content only (no comments or form fields).
    public func render(_ page: Int, scale: Double, region: RectD? = nil, cancel: CancelToken? = nil, annotations: Bool = true) throws -> RenderedImage {
        try cancel.check()
        gate.lock()
        defer { gate.unlock() }
        guard let main else { throw PdfEngineClosed() }
        try cancel.check()
        let g = try geometry(page)
        let r = region ?? RectD(0, 0, g.width, g.height)
        try Self.checkSize(r.width * scale, r.height * scale)
        return try reading(page, cancel) { cookie in
            var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
            var pixels: UnsafeMutablePointer<UInt8>?
            var width: Int32 = 0, height: Int32 = 0
            let draw = annotations ? inkv_render_rgb : inkv_render_rgb_contents
            let result = draw(main.ctx, main.doc, Int32(page), Float(scale), Float(g.originX + r.x), Float(g.originY + r.y),
                              Float(g.originX + r.right), Float(g.originY + r.bottom), cookie, &pixels, &width, &height, &err)
            defer { inkv_free(pixels) }
            if result == 2 { throw CancellationError() }
            guard result == 1, let pixels else { throw PdfEngineError(message: Self.message(err)) }
            try cancel.check()
            return RenderedImage(Int(width), Int(height), Array(UnsafeBufferPointer(start: pixels, count: Int(width) * Int(height) * 3)))
        }
    }

    /// Renders a page straight to a PNG or JPEG file at the given resolution.
    /// - Throws: `CancellationError` when `cancel` fired; `PdfEngineError` when the image would exceed `maxPixels`;
    ///   `PageRefused` (no file written).
    public func saveImage(_ page: Int, dpi: Double, path: String, jpeg: Bool, cancel: CancelToken? = nil) throws {
        try cancel.check()
        gate.lock()
        defer { gate.unlock() }
        guard let main else { throw PdfEngineClosed() }
        try cancel.check()
        let scale = dpi / 72
        let g = try geometry(page)
        try Self.checkSize((g.width * scale).rounded(.up), (g.height * scale).rounded(.up))
        try reading(page, cancel) { cookie in
            var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
            let result = inkv_save_image(main.ctx, main.doc, Int32(page), Float(scale), path, jpeg ? 1 : 0, cookie, &err)
            if result == 2 { throw CancellationError() }
            guard result == 1 else { throw PdfEngineError(message: Self.message(err)) }
        }
    }

    /// Largest picture MuPDF may decode, width × height: 268 million pixels (16,384 × 16,384), where Windows' page check
    /// refuses one (half its 2 GB process at 4 bytes a pixel, `PageChecks.OutOfResources`). A 600 dpi scan of a D-size
    /// sheet (311 M) or the 20,000 × 20,000 picture that took 9 s a draw on Windows is larger. A page with a larger one is
    /// refused before MuPDF decodes any of it; MuPDF decodes all of a picture for every draw, whatever the zoom, a
    /// second or more for the largest allowed, and the time is looked at between pictures.
    public static let maxPicturePixels = 268_435_456.0

    /// Test hook: each read of the file's bytes waits `seconds` while a page is read (a slow share or iCloud).
    func slowReadsForTests(_ seconds: Double) {
        gate.lock()
        defer { gate.unlock() }
        if let main { inkv_test_slow_reads(main.doc, seconds) }
    }

    /// Test hook: objects the stream checks of the engine's main instance resolved so far, and how often its document's
    /// stream read the CPU clock.
    func countsForTests() -> (walked: Int, clockReads: Int) {
        gate.lock()
        defer { gate.unlock() }
        guard let main else { return (0, 0) }
        var walked: Int64 = 0, reads: Int64 = 0
        inkv_test_counts(main.doc, &walked, &reads)
        return (Int(walked), Int(reads))
    }

    /// Runs `body`, a call that reads `page`'s content, with a cookie bounding it (Windows' page check, in process): the
    /// engine's `pageBudget` for the reading and again for the drawing, the largest picture, `cancel` and closing the
    /// engine. What the call found is kept as the page's verdict; a page refused once is refused at once from then on.
    /// - Throws: `PageRefused`; `CancellationError` when `cancel` fired; `PdfEngineClosed` when the engine was closed.
    private func reading<T>(_ page: Int, _ cancel: CancelToken?, _ body: (OpaquePointer) throws -> T) throws -> T {
        let known = verdicts[page]
        if known.refuses { throw PageRefused(page: page, tooSlow: known == .tooSlow) }
        guard let cookie = inkv_new_cookie() else { throw PdfEngineError(message: "MuPDF couldn't start.") } // English: the engine's own failure, for a developer
        defer { inkv_drop_cookie(cookie) }
        inkv_cookie_limit(cookie, verdicts.budget, Self.maxPicturePixels)
        let watched = verdicts.watch(cookie)
        defer { verdicts.unwatch(watched) }
        let handler = cancel?.register { inkv_cookie_abort(cookie) }
        defer { cancel?.unregister(handler) }
        do {
            let result = try body(cookie)
            try settle(page, cookie)
            verdicts.set(page, .fine)
            return result
        } catch {
            try settle(page, cookie)
            throw error
        }
    }

    /// Why a call stopped, as an error, the page's verdict kept; nothing when it wasn't stopped.
    private func settle(_ page: Int, _ cookie: OpaquePointer) throws {
        switch inkv_cookie_stopped(cookie) {
        case 1:
            if verdicts.closed { throw PdfEngineClosed() }
            throw CancellationError()
        case 2:
            verdicts.set(page, .tooSlow)
            throw PageRefused(page: page, tooSlow: true)
        case 3, 4: // a picture too large; a stream decompressed more than twice
            verdicts.set(page, .failed)
            throw PageRefused(page: page, tooSlow: false)
        default:
            return
        }
    }

    private static func checkSize(_ width: Double, _ height: Double) throws {
        // Not a number is too large too (a page or a zoom of infinity), and is shown without its size.
        if !(width * height <= maxPixels) {
            if let w = Int(exactly: width.rounded()), let h = Int(exactly: height.rounded()) {
                throw PdfEngineError(message: loc("The image would be too large ({0} x {1} pixels). Use a lower zoom or resolution.", CoreLanguage.number(w), CoreLanguage.number(h)))
            }
            throw PdfEngineError(message: loc("The image would be too large. Use a lower zoom or resolution."))
        }
    }

    /// The text instance, opened on first use. Call under textGate.
    private func text() throws -> Instance {
        if closed { throw PdfEngineClosed() }
        if let textInstance { return textInstance }
        let instance: Instance
        do {
            // Under textGate: close() clears source holding both locks, so it is read here without gate (gate before
            // textGate is the lock order; taking gate now could deadlock with close).
            guard let source else { throw PdfEngineClosed() }
            instance = try Instance.open(source, store: 32 << 20, password: password ?? "")
        } catch is PasswordRequired {
            throw PasswordRequired(wrongPassword: true)
        }
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        if Int(inkv_count_pages(instance.ctx, instance.doc, &err)) != pages.count {
            throw PdfEngineError(message: loc("The document changed while open."))
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
        if let kept = findMemo.known(page).1 { return kept } // a search kept it whole
        if let hit = textCache[page] {
            textLru.removeAll { $0 == page }
            textLru.insert(page, at: 0)
            return hit
        }
        let text = try extractText(instance, page, cancel)
        if cache {
            textCache[page] = text
            textLru.insert(page, at: 0)
            while textLru.count > Self.textCacheSize { textCache[textLru.removeLast()] = nil }
        }
        return text
    }

    private func extractText(_ instance: Instance, _ page: Int, _ cancel: CancelToken?) throws -> PageText {
        let g = try geometry(page)
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        var lines: UnsafeMutablePointer<inkv_line>?
        var chars: UnsafeMutablePointer<inkv_char>?
        var lineCount: Int32 = 0, charCount: Int32 = 0
        defer {
            inkv_free(lines)
            inkv_free(chars)
        }
        try reading(page, cancel) { cookie in
            findMemo.countExtraction()
            let result = inkv_page_chars(instance.ctx, instance.doc, Int32(page), &lines, &lineCount, &chars, &charCount, cookie, &err)
            if result == 2 { throw CancellationError() }
            guard result == 1 else { throw PdfEngineError(message: Self.message(err)) }
        }
        var result: [[(String, RectD)]] = []
        var directions: [(Double, Double)] = []
        var invisible: [[Bool]] = []
        for li in 0..<Int(lineCount) {
            let line = lines![li]
            var list: [(String, RectD)] = []
            var unseen: [Bool] = []
            list.reserveCapacity(Int(line.count))
            for ci in Int(line.first)..<Int(line.first + line.count) {
                let c = chars![ci]
                unseen.append(c.flags & (16 | 32) == 0) // neither filled nor stroked: drawn invisibly
                let ch = Unicode.Scalar(UInt32(bitPattern: c.c)).map { String(Character($0)) } ?? "\u{FFFD}"
                list.append((ch, RectD.fromEdges(Double(c.x0) - g.originX, Double(c.y0) - g.originY,
                                                 Double(c.x1) - g.originX, Double(c.y1) - g.originY)))
            }
            result.append(list)
            invisible.append(unseen)
            directions.append((Double(line.dx), Double(line.dy))) // the baseline's direction (sideways text: vertical)
        }
        return PageText(result, directions: directions, invisible: invisible)
    }

    /// A line of text as MuPDF reads it, in MuPDF page space (the page's origin not taken off): its text, its box and
    /// each character with its box.
    struct TextLine {
        var text: String
        var box: RectD
        var chars: [(ch: String, box: RectD)]
    }

    /// The page's text lines, with its annotations and widgets drawn in when asked (what MuPDFCore reads with
    /// `includeAnnotations`; `text` reads the page's own content only). Not cached.
    func textLines(_ page: Int, annotations: Bool) throws -> [TextLine] {
        try enterText(nil)
        defer { textGate.unlock() }
        let instance = try text()
        _ = try geometry(page)
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        var lines: UnsafeMutablePointer<inkv_line>?
        var chars: UnsafeMutablePointer<inkv_char>?
        var lineCount: Int32 = 0, charCount: Int32 = 0
        defer {
            inkv_free(lines)
            inkv_free(chars)
        }
        let read = annotations ? inkv_page_chars_annots : inkv_page_chars
        try reading(page, nil) { cookie in
            let result = read(instance.ctx, instance.doc, Int32(page), &lines, &lineCount, &chars, &charCount, cookie, &err)
            if result == 2 { throw CancellationError() }
            guard result == 1 else { throw PdfEngineError(message: Self.message(err)) }
        }
        var result: [TextLine] = []
        for li in 0..<Int(lineCount) {
            let line = lines![li]
            var list: [(ch: String, box: RectD)] = []
            var box = RectD.zero
            for ci in Int(line.first)..<Int(line.first + line.count) {
                let c = chars![ci]
                let ch = Unicode.Scalar(UInt32(bitPattern: c.c)).map { String(Character($0)) } ?? "\u{FFFD}"
                let r = RectD.fromEdges(Double(c.x0), Double(c.y0), Double(c.x1), Double(c.y1))
                box = list.isEmpty ? r : RectD.fromEdges(min(box.x, r.x), min(box.y, r.y), max(box.right, r.right), max(box.bottom, r.bottom))
                list.append((ch, r))
            }
            result.append(TextLine(text: list.map(\.ch).joined(), box: box, chars: list))
        }
        return result
    }

    /// - Throws: `CancellationError` when `cancel` fired before the links were read.
    public func links(_ page: Int, cancel: CancelToken? = nil) throws -> [PageLink] {
        try cancel.check()
        try enterText(cancel)
        defer { textGate.unlock() }
        let instance = try text()
        if let cached = linkCache[page] { return cached }
        let g = try geometry(page)
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

    /// Closes the document; later calls throw `PdfEngineClosed`. Safe while another thread reads text. A page being read
    /// now stops at once (a hostile one would otherwise hold the locks until its budget ran out).
    public func close() {
        verdicts.close()
        gate.lock()
        textGate.lock()
        closed = true
        textInstance = nil
        main = nil
        source = nil
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

    // ---- export (D5c; the rest of GetExportPage is in Export/EngineExport.swift) ----

    /// What a lone accent draws, per font, text and size (the Windows engine's `_drawnAs`).
    let drawnAs = DrawnAsCache()

    /// A page read for export, before its glyphs become lines: each MuPDF line's glyphs with their look and direction,
    /// the pictures (encoded; empty data when MuPDF couldn't encode one) and the vector paths' bounds (page space).
    struct ExportRead {
        var geometry: PageGeometry
        var lines: [(glyphs: [ExportGlyph], turn: Int, sideways: Bool)]
        var images: [ExportImage]
        var paths: [(box: RectD, stroked: Bool, color: UInt32)]
    }

    /// The structured text of a page with its annotations, its pictures (when `images`) and vector paths (the Windows
    /// engine's `GetStructuredTextPage(page, true, CollectVectors | PreserveImages)` and `ReadGlyphs`). Not cached.
    /// - Throws: `CancellationError` when `cancel` fired before the page was read; `PdfEngineError` when MuPDF can't.
    func exportRead(_ page: Int, images: Bool, boxesOnly: Bool = false, jpegAbovePixels: Int, cancel: CancelToken?) throws -> ExportRead {
        try cancel.check()
        try enterText(cancel)
        defer { textGate.unlock() }
        let instance = try text()
        let g = try geometry(page)
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        var raw = inkv_export()
        defer { inkv_free_export(&raw) }
        let mode: Int32 = images ? (boxesOnly ? 2 : 1) : 0
        try reading(page, cancel) { cookie in
            let result = inkv_export_page(instance.ctx, instance.doc, Int32(page), mode, Int64(jpegAbovePixels), &raw, cookie, &err)
            if result == 2 { throw CancellationError() }
            guard result == 1 else { throw PdfEngineError(message: Self.message(err)) }
        }
        func box(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float) -> RectD {
            RectD.fromEdges(Double(x0) - g.originX, Double(y0) - g.originY, Double(x1) - g.originX, Double(y1) - g.originY)
        }
        // Each font's look once: name, bold and italic from its flags or its name, serif, monospaced.
        var looks: [ExportSpan] = []
        for k in 0..<Int(raw.font_count) {
            let f = raw.fonts[k]
            let name = f.name.map { String(cString: $0) } ?? ""
            var look = ExportSpan("", name, 0, f.bold != 0 || FontNames.looksBold(name), f.italic != 0 || FontNames.looksItalic(name), 0, .zero)
            look.serif = f.serif != 0
            look.mono = f.mono != 0
            looks.append(look)
        }
        let plain = ExportSpan("", "", 0, false, false, 0, .zero)
        var read = ExportRead(geometry: g, lines: [], images: [], paths: [])
        read.lines.reserveCapacity(Int(raw.line_count))
        for li in 0..<Int(raw.line_count) {
            let line = raw.lines[li]
            var glyphs: [ExportGlyph] = []
            glyphs.reserveCapacity(Int(line.count))
            for ci in Int(line.first)..<Int(line.first + line.count) {
                let c = raw.chars[ci]
                let ch = Unicode.Scalar(UInt32(bitPattern: c.c)).map { String(Character($0)) } ?? "\u{FFFD}"
                let rect = box(c.x0, c.y0, c.x1, c.y1)
                var look = c.font >= 0 ? looks[Int(c.font)] : plain
                look.size = Double(c.size)
                look.color = c.argb & 0xFFFFFF
                look.box = rect
                glyphs.append(ExportGlyph(ch, rect, look))
            }
            let dx = Double(line.dx), dy = Double(line.dy)
            read.lines.append((glyphs, ExportLine.turnOf(dx, dy), abs(dy) > 0.1 || dx <= 0))
        }
        for k in 0..<Int(raw.image_count) {
            let i = raw.images[k]
            guard i.width > 0 && i.height > 0 else { continue }
            let data = i.data.map { Array(UnsafeBufferPointer(start: $0, count: i.length)) } ?? []
            read.images.append(ExportImage(data, i.jpeg != 0 ? "jpeg" : "png", Int(i.width), Int(i.height), box(i.x0, i.y0, i.x1, i.y1)))
        }
        read.paths.reserveCapacity(Int(raw.vector_count))
        for k in 0..<Int(raw.vector_count) {
            let v = raw.vectors[k]
            read.paths.append((box(v.x0, v.y0, v.x1, v.y1), v.stroked != 0, UInt32(v.argb) & 0xFFFFFF))
        }
        return read
    }

    /// A region of a page (page space) drawn on transparency as straight RGBA at `scale` pixels per point; nil when MuPDF
    /// can't draw it or it has no pixels.
    /// - Throws: `CancellationError` when `cancel` fired; `PageRefused`.
    func renderRegionRgba(_ page: Int, _ region: RectD, scale: Double, cancel: CancelToken?) throws -> (rgba: [UInt8], width: Int, height: Int)? {
        try cancel.check()
        gate.lock()
        defer { gate.unlock() }
        guard let main else { throw PdfEngineClosed() }
        let g = try geometry(page)
        var err = [CChar](repeating: 0, count: Int(INKV_ERR_SIZE))
        var pixels: UnsafeMutablePointer<UInt8>?
        var width: Int32 = 0, height: Int32 = 0
        defer { inkv_free(pixels) }
        let x0 = Float(g.originX + region.x), y0 = Float(g.originY + region.y)
        let x1 = Float(g.originX + region.right), y1 = Float(g.originY + region.bottom)
        let ok = try reading(page, cancel) { cookie in
            let result = inkv_render_region_rgba(main.ctx, main.doc, Int32(page), Float(scale), x0, y0, x1, y1, &pixels, &width, &height, cookie, &err)
            if result == 2 { throw CancellationError() }
            return result == 1
        }
        guard ok, let pixels, width > 0, height > 0 else { return nil }
        return (Array(UnsafeBufferPointer(start: pixels, count: Int(width) * Int(height) * 4)), Int(width), Int(height))
    }

    static func message(_ err: [CChar]) -> String {
        let bytes = err.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return bytes.isEmpty ? "MuPDF failed." : String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - Find across the document (roadmap 3.6, the Mac's half: E16)

extension PdfEngine {
    /// One page's outcome in `findAll`: its matches (and its text when there are any), or why it couldn't be read.
    public struct PageMatches: @unchecked Sendable {
        public let page: Int
        public let text: PageText?
        public let hits: [(start: Int, end: Int)]
        public let error: String?
        /// Set when the page was refused (its reading took too long, or a picture on it is too large): skipped.
        public var refused: PageRefused? = nil
    }

    /// Threads `findAll` reads pages on, each with its own MuPDF instance over the engine's one copy of the bytes: every
    /// core but one (the view keeps one to draw on), at most 8. No lock stands between instances here (Windows'
    /// MuPDFCore made its threads wait on each other and needed worker processes). Measured on the M1 Air
    /// (`mac/tools/bench`): a 5,000-page text in 2.36 s on one thread, 1.22 s on two, 0.65 s on four, 0.52 s on eight; a
    /// 400-sheet drawing set in 33.5 s on one, 9.8 s on four, 7.6 s on eight.
    nonisolated(unsafe) public static var findThreads: Int = max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 1))

    /// Pages to read for each thread a search may use: a short document is read on the engine's own text instance.
    static let findPagesPerThread = 8

    /// Characters of whole page texts kept for the engine's lifetime (about 40 MB with their boxes): a drawing set's
    /// sheets keep theirs; a long book keeps its strings only. Windows' `KeptTextChars`; tests lower it.
    nonisolated(unsafe) static var keptTextChars = 1_000_000

    /// Page text remembered as strings across all pages (about 128 MB): beyond it, pages are read again.
    static let maxRememberedChars = 64_000_000

    /// `PageText.find` on every page, as one search (Windows' `FindAll`): pages are read on up to `findThreads` threads
    /// (each with its own MuPDF instance) and come back in page order, through `onPage` as soon as each page and those
    /// before it are done (called on a search thread), then all together. A page whose text was read before (by any
    /// call) and can't match is not read again, nor one whose whole text is kept. A page that can't be read comes back
    /// with its `error`.
    /// - Throws: `CancellationError` when `cancel` fired; `PdfEngineClosed` when the engine is closed.
    @discardableResult
    /// - Parameter keepText: return each matching page's text with its hits; a caller that needs only the hits' places
    ///   (the app, which draws them from the view's own text) passes false, so 5,000 pages of text aren't held at once.
    public func findAll(_ query: String, matchCase: Bool, wholeWord: Bool, ignoreAccents: Bool = false, keepText: Bool = true,
                        cancel: CancelToken? = nil, onPage: ((PageMatches) -> Void)? = nil) throws -> [PageMatches] {
        try checkOpen()
        let count = pages.count
        if count == 0 { return [] }
        let results = FindResults(count, onPage)
        // Every page goes through the threads, what is known of it too: checking 5,000 remembered strings on one thread
        // took longer (1.3 s) than reading them all again on seven (0.55 s).
        let threads = min(Self.findThreads, max(1, count / Self.findPagesPerThread))
        let next = FindCounter()
        let failure = FindFailure()
        let memo = findMemo
        let source = threads > 1 ? currentSource() : nil
        let password = password
        @Sendable func work(_ own: Bool) {
            // This thread's MuPDF instance, opened when it first has a page to read; without one (a short document, or
            // one that couldn't be opened) pages are read on the engine's own text instance.
            var instance: Instance?
            var tried = !own
            while true {
                if cancel?.isCancelled == true || failure.value != nil { return }
                let p = next.take()
                if p >= count { return }
                if let known = findKnown(p, query, matchCase, wholeWord, ignoreAccents) {
                    results.set(p, keepText ? known : PageMatches(page: p, text: nil, hits: known.hits, error: nil))
                    continue
                }
                if !tried, let source {
                    tried = true
                    instance = try? Instance.open(source, store: 16 << 20, password: password ?? "")
                }
                do {
                    let text: PageText
                    if let instance { text = try extractText(instance, p, cancel) } else { text = try self.text(p, cache: false, cancel: cancel) }
                    memo.remember(p, text)
                    let hits = text.find(query, matchCase: matchCase, wholeWord: wholeWord, ignoreAccents: ignoreAccents)
                    results.set(p, PageMatches(page: p, text: hits.isEmpty || !keepText ? nil : text, hits: hits, error: nil))
                } catch is CancellationError {
                    return
                } catch let e as PdfEngineClosed {
                    failure.set(e)
                    return
                } catch let refused as PageRefused {
                    // Skipped: the rest is found (a refused page answers at once from then on).
                    results.set(p, PageMatches(page: p, text: nil, hits: [], error: refused.message, refused: refused))
                } catch {
                    results.set(p, PageMatches(page: p, text: nil, hits: [], error: (error as? PdfEngineError)?.message ?? "\(error)"))
                }
            }
        }
        if threads <= 1 {
            work(false)
        } else {
            if source == nil { throw PdfEngineClosed() }
            DispatchQueue.concurrentPerform(iterations: threads) { _ in work(true) }
        }
        if let e = failure.value { throw e }
        try cancel.check()
        try checkOpen()
        return results.all()
    }

    /// Test hook: pages whose text was read from MuPDF so far (Windows' `Extractions`).
    var extractions: Int { findMemo.extractions }

    private func currentSource() -> Source? {
        gate.lock()
        defer { gate.unlock() }
        return source
    }

    private func checkOpen() throws {
        gate.lock()
        defer { gate.unlock() }
        if closed { throw PdfEngineClosed() }
    }

    /// A page's matches from what is already known of it, without reading it; nil if it has to be read.
    private func findKnown(_ page: Int, _ query: String, _ matchCase: Bool, _ wholeWord: Bool, _ ignoreAccents: Bool) -> PageMatches? {
        let (string, kept) = findMemo.known(page)
        if let string, !PageText.matches(string, query, matchCase: matchCase, wholeWord: wholeWord, ignoreAccents: ignoreAccents) {
            return PageMatches(page: page, text: nil, hits: [], error: nil)
        }
        var text = kept
        if text == nil, textGate.lock(before: Date(timeIntervalSinceNow: 0.002)) { // a moment: another reader may be passing through
            if !closed { text = textCache[page] }
            textGate.unlock()
        }
        guard let text else { return nil }
        let hits = text.find(query, matchCase: matchCase, wholeWord: wholeWord, ignoreAccents: ignoreAccents)
        return PageMatches(page: page, text: hits.isEmpty ? nil : text, hits: hits, error: nil)
    }
}

/// What `findAll` keeps of the pages it read: whole texts up to `keptTextChars`, strings up to `maxRememberedChars`.
final class FindMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var strings: [String?]
    private var texts: [PageText?]
    private var keptChars = 0, rememberedChars = 0, extractionCount = 0

    init(_ count: Int) {
        strings = Array(repeating: nil, count: count)
        texts = Array(repeating: nil, count: count)
    }

    var extractions: Int { lock.withLock { extractionCount } }

    func countExtraction() { lock.withLock { extractionCount += 1 } }

    /// What is known of `page`; nothing for a page that isn't there (the caller's own check throws for it).
    func known(_ page: Int) -> (String?, PageText?) {
        lock.withLock { page >= 0 && page < strings.count ? (strings[page], texts[page]) : (nil, nil) }
    }

    func remember(_ page: Int, _ text: PageText) {
        let length = text.length
        lock.withLock {
            guard page >= 0 && page < strings.count else { return }
            if texts[page] == nil && keptChars + length <= PdfEngine.keptTextChars {
                texts[page] = text
                keptChars += length
            }
            if strings[page] == nil && rememberedChars + length <= PdfEngine.maxRememberedChars {
                strings[page] = text.text
                rememberedChars += length
            }
        }
    }
}

/// The search's pages as they finish, handed on in page order.
private final class FindResults: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [PdfEngine.PageMatches?]
    private var delivered = 0
    private let onPage: ((PdfEngine.PageMatches) -> Void)?

    init(_ count: Int, _ onPage: ((PdfEngine.PageMatches) -> Void)?) {
        slots = Array(repeating: nil, count: count)
        self.onPage = onPage
    }

    func set(_ page: Int, _ m: PdfEngine.PageMatches) {
        lock.lock()
        defer { lock.unlock() }
        slots[page] = m
        while delivered < slots.count, let ready = slots[delivered] {
            onPage?(ready)
            delivered += 1
        }
    }

    func all() -> [PdfEngine.PageMatches] { lock.withLock { slots.compactMap { $0 } } }
}

private final class FindCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func take() -> Int {
        lock.withLock {
            let v = value
            value += 1
            return v
        }
    }
}

private final class FindFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var error: Error?
    var value: Error? { lock.withLock { error } }
    func set(_ e: Error) { lock.withLock { if error == nil { error = e } } }
}
