import Foundation
import PdfCore

/// Roadmap 3.6's targets, in the units the measures use (Windows' `Targets`).
enum Targets {
    static let firstPageMs = 1000.0
    static let pageMs = 200.0
    static let findMs = 5000.0
    static let commentsMs = 2000.0
    static let memoryMb = 1536.0
}

/// One run of the measures over one file, in one process (the harness starts a process per run, so the peak is the
/// file's own and every open is cold).
struct Measured: Codable {
    var file: String
    var bytes: Int
    var pages: Int
    var readMs, openMs, firstRenderMs: Double
    var pageMs: [Double]
    var pageAgainMs: [Double]
    var findWord: String
    var findMs: Double
    var findHits: Int
    var findThreads: Int
    /// A second search (another word) on the same engine: what the first one remembered.
    var findAgainMs: Double = 0
    var commentsMs: Double
    var comments: Int
    var peakMb: Double

    var firstPageMs: Double { readMs + openMs + firstRenderMs }
    var pageMsAverage: Double { pageMs.isEmpty ? 0 : pageMs.reduce(0, +) / Double(pageMs.count) }
    var pageMsMax: Double { pageMs.max() ?? 0 }
    var pagesOver200: Int { pageMs.filter { $0 > Targets.pageMs }.count }
    var pageAgainMsAverage: Double { pageAgainMs.isEmpty ? 0 : pageAgainMs.reduce(0, +) / Double(pageAgainMs.count) }
}

enum Measures {
    /// The render scale: 100% zoom on a Retina display (2 px per point) for ordinary pages, fit to 1,200 px for wide sheets.
    static func scaleFor(_ g: PageGeometry) -> Double { min(2.0, 1200 / g.width) }

    static func run(_ path: String, findWord: String, scrollPages: Int = 20) throws -> Measured {
        let clock = ContinuousClock()
        // As the app opens a file: its bytes read whole, then the engine over them.
        var t = clock.now
        let bytes = try PdfEngine.readFile(path)
        let readMs = ms(clock.now - t)
        trace("read")

        t = clock.now
        var engine = try PdfEngine.open(bytes)
        let openMs = ms(clock.now - t)
        let pages = engine.pageCount
        let scale = scaleFor(engine.page(0))
        t = clock.now
        _ = try engine.render(0, scale: scale)
        let firstRenderMs = ms(clock.now - t)
        trace("open + first render")
        engine.close()

        // Scrolling proxy: a fresh engine renders the first pages one after another, as a scroll from the top does; then
        // the same pages again while it still holds them.
        engine = try PdfEngine.open(bytes)
        var pageMs: [Double] = [], again: [Double] = []
        for p in 0..<min(scrollPages, pages) {
            t = clock.now
            _ = try engine.render(p, scale: scale)
            pageMs.append(ms(clock.now - t))
        }
        trace("scroll")
        for p in 0..<min(scrollPages, pages) {
            t = clock.now
            _ = try engine.render(p, scale: scale)
            again.append(ms(clock.now - t))
        }
        trace("scroll again")

        // Find: every page searched as the app's search does.
        t = clock.now
        let (hits, threads) = try BenchFind.findAll(engine, findWord)
        let findMs = ms(clock.now - t)
        trace("find")
        t = clock.now
        _ = try BenchFind.findAll(engine, "harbor")
        let findAgainMs = ms(clock.now - t)
        engine.close()

        // The comment list: every annotation read, as the Comments pane does when a file opens.
        t = clock.now
        let comments = try Annotations.read(bytes, nil).count
        let commentsMs = ms(clock.now - t)
        trace("comments")

        return Measured(file: (path as NSString).lastPathComponent, bytes: bytes.count, pages: pages, readMs: readMs, openMs: openMs,
                        firstRenderMs: firstRenderMs, pageMs: pageMs, pageAgainMs: again, findWord: findWord, findMs: findMs, findHits: hits,
                        findThreads: threads, findAgainMs: findAgainMs, commentsMs: commentsMs, comments: comments, peakMb: peakMb())
    }

    /// The first `pages` pages drawn by a fresh engine at the proxy's scale, then again: ms a page, cold and warm.
    static func paint(_ bytes: [UInt8], pages: Int) throws -> (cold: Double, warm: Double) {
        let engine = try PdfEngine.open(bytes)
        defer { engine.close() }
        let n = min(pages, engine.pageCount)
        let clock = ContinuousClock()
        var t = clock.now
        for p in 0..<n { _ = try engine.render(p, scale: scaleFor(engine.page(p))) }
        let cold = ms(clock.now - t) / Double(n)
        t = clock.now
        for p in 0..<n { _ = try engine.render(p, scale: scaleFor(engine.page(p))) }
        return (cold, ms(clock.now - t) / Double(n))
    }

    /// `INKVOLT_BENCH_TRACE=1`: the peak so far after each step, on stderr.
    static func trace(_ step: String) {
        guard ProcessInfo.processInfo.environment["INKVOLT_BENCH_TRACE"] == "1" else { return }
        FileHandle.standardError.write(Data("\(step): peak \(Int(peakMb())) MB\n".utf8))
    }

    /// The process's peak resident memory (macOS reports ru_maxrss in bytes).
    static func peakMb() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }

    static func ms(_ d: Duration) -> Double {
        let c = d.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }
}
