import Foundation
import PdfCore

/// Find as the app runs it, and the thread-scaling measure PLAN.md's E16 asks for first.
enum BenchFind {
    /// Every page searched as the app's Find does (`PdfEngine.findAll`); the hits and how many threads may read text.
    /// `INKVOLT_BENCH_SERIAL=1` measures what Find did before E16: one page after another on the engine's text instance.
    static func findAll(_ engine: PdfEngine, _ word: String) throws -> (hits: Int, threads: Int) {
        if ProcessInfo.processInfo.environment["INKVOLT_BENCH_SERIAL"] == "1" {
            var hits = 0
            for p in 0..<engine.pageCount { hits += try engine.text(p).find(word, matchCase: false, wholeWord: false).count }
            return (hits, 1)
        }
        let pages = try engine.findAll(word, matchCase: false, wholeWord: false, keepText: false)
        return (pages.reduce(0) { $0 + $1.hits.count }, min(PdfEngine.findThreads, max(1, engine.pageCount / 8)))
    }

    /// `threads` engines of their own (each its own MuPDF context and document), reading every `threads`-th page.
    /// The time to read every page's text and find `word` in it, and the hits (which must equal one thread's).
    static func scaling(_ bytes: [UInt8], _ word: String, threads: Int) throws -> (ms: Double, hits: Int) {
        let engines = try (0..<threads).map { _ in try PdfEngine.open(bytes) }
        defer { for e in engines { e.close() } }
        let pages = engines[0].pageCount
        let counts = Counts(threads)
        let failed = Flag()
        let clock = ContinuousClock()
        let started = clock.now
        DispatchQueue.concurrentPerform(iterations: threads) { k in
            var n = 0
            var p = k
            while p < pages {
                do {
                    n += try engines[k].text(p, cache: false).find(word, matchCase: false, wholeWord: false).count
                } catch {
                    failed.set()
                }
                p += threads
            }
            counts.set(k, n)
        }
        if failed.isSet { throw BenchError("a page's text couldn't be read") }
        return (Measures.ms(clock.now - started), counts.total)
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

final class Counts: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int]
    init(_ n: Int) { values = Array(repeating: 0, count: n) }
    func set(_ i: Int, _ v: Int) { lock.withLock { values[i] = v } }
    var total: Int { lock.withLock { values.reduce(0, +) } }
}
