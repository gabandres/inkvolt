import Foundation
import PrintCore

/// What a folder search looks for, as Find's options; case and accents are ignored unless asked otherwise.
public struct FolderSearchOptions: Sendable {
    public var matchCase = false
    public var wholeWord = false
    public var ignoreAccents = true
    /// Pages to list at most.
    public var maxPages = 500

    public init(matchCase: Bool = false, wholeWord: Bool = false, ignoreAccents: Bool = true, maxPages: Int = 500) {
        self.matchCase = matchCase
        self.wholeWord = wholeWord
        self.ignoreAccents = ignoreAccents
        self.maxPages = maxPages
    }
}

/// One page a search found.
public struct FolderHit: Sendable, Equatable {
    /// From the indexed folder.
    public let relativePath: String
    /// The page, from 0.
    public let page: Int
    /// How often it is on the page.
    public let hits: Int
    /// The first hit with the text around it, on one line.
    public let excerpt: String
    /// Where the hit is in the excerpt (UTF-16 units).
    public let matchStart: Int
    public let matchLength: Int

    public init(relativePath: String, page: Int, hits: Int, excerpt: String, matchStart: Int, matchLength: Int) {
        self.relativePath = relativePath
        self.page = page
        self.hits = hits
        self.excerpt = excerpt
        self.matchStart = matchStart
        self.matchLength = matchLength
    }

    /// The hit itself, as the excerpt has it.
    public var match: String {
        let units = Array(excerpt.utf16)
        let s = min(max(matchStart, 0), units.count), e = min(s + max(matchLength, 0), units.count)
        return String(decoding: units[s..<e], as: UTF16.self)
    }
}

/// One search under way on a snapshot of a `FolderIndex`: the index has narrowed it to the pages that have every word,
/// and `next` asks Find, on the kept text, about each of them in order. Holds the snapshot's file until `close`.
public final class FolderSearchRun: @unchecked Sendable {
    private let lock = NSLock()
    private var confirm: Confirmer?
    private let release: () -> Void
    private var released = false

    /// Pages with all the query's words: what a word found on many pages is counted by, before they are listed.
    public let candidatePages: Int
    public let candidateFiles: Int
    /// False: nothing in the query is a letter or digit, and the index files only those.
    public let hasWords: Bool

    fileprivate init(candidatePages: Int, candidateFiles: Int, hasWords: Bool, confirm: Confirmer?, release: @escaping () -> Void) {
        self.candidatePages = candidatePages
        self.candidateFiles = candidateFiles
        self.hasWords = hasWords
        self.confirm = confirm
        self.release = release
    }

    deinit { close() }

    /// The next page Find confirms, in path order, up to the search's limit; nil at the end.
    /// - Throws: `CancellationError` when `cancel` fired; `FolderIndexDamaged` when a page's text doesn't read back (the
    ///   index should be built again).
    public func next(cancel: CancelToken? = nil) throws -> FolderHit? {
        guard let confirm = lock.withLock({ released ? nil : self.confirm }) else { return nil }
        return try confirm.next(cancel)
    }

    /// Every page left, to the limit.
    public func all(cancel: CancelToken? = nil) throws -> [FolderHit] {
        var hits: [FolderHit] = []
        while let hit = try next(cancel: cancel) { hits.append(hit) }
        return hits
    }

    public func close() {
        let first: Bool = lock.withLock {
            if released { return false }
            released = true
            confirm = nil
            return true
        }
        if first { release() }
    }
}

extension FolderIndex {
    /// Starts a search. Each word of the query narrows the pages: every term with the word inside it counts, as Find finds
    /// a word inside a longer one; then `FolderSearchRun.next` runs Find itself on what is left, so a result here is what
    /// Find would say on that page. A phrase's words are next to each other only if Find says so.
    /// - Throws: `CancellationError`; `FolderIndexDamaged` when the list of terms doesn't read back.
    public func search(_ query: String, options: FolderSearchOptions = FolderSearchOptions(), cancel: CancelToken? = nil) throws -> FolderSearchRun {
        let state = try acquire()
        do {
            let terms = IndexTerms.of(query)
            if terms.isEmpty { return Self.finished(state, false) }
            let map = state.pages
            var found: [UInt64]?
            var seen = Set<String>()
            for term in terms where seen.insert(term).inserted {
                var bits = [UInt64](repeating: 0, count: (map.total + 64) / 64)
                try Self.markPages(state, map, IndexTerms.lookup(term), &bits, cancel)
                if var had = found {
                    for i in 0..<had.count { had[i] &= bits[i] }
                    found = had
                } else {
                    found = bits
                }
            }
            let bits = found ?? []
            let pages = bits.reduce(0) { $0 + $1.nonzeroBitCount }
            if pages == 0 { return Self.finished(state, true) }
            var files = 0
            for f in 0..<map.files.count where Self.anyPage(bits, map.first[f], map.files[f].pages) { files += 1 }
            let confirm = Confirmer(state, map, bits, query, options, terms)
            return FolderSearchRun(candidatePages: pages, candidateFiles: files, hasWords: true, confirm: confirm, release: state.store.release)
        } catch {
            state.store.release()
            throw error
        }
    }

    private static func finished(_ state: Snapshot, _ hasWords: Bool) -> FolderSearchRun {
        FolderSearchRun(candidatePages: 0, candidateFiles: 0, hasWords: hasWords, confirm: nil, release: state.store.release)
    }

    /// Sets the bit of every page with `word` in one of its terms.
    static func markPages(_ state: Snapshot, _ map: PageMap, _ word: [UInt8], _ bits: inout [UInt64], _ cancel: CancelToken?) throws {
        let cursor = Cursor(state.store.file)
        let first = map.firstById
        let count = map.countById
        for segment in state.segments {
            try cancel.check()
            let table = try segment.table(state.store.file)
            let matches = table.containing(word)
            for (m, i) in matches.enumerated() {
                if m & 255 == 0 { try cancel.check() }
                let list = try cursor.read(table.postings[i], Int(table.postings[i + 1] - table.postings[i]))
                var reader = PostingReader(list)
                while let posting = try reader.next() {
                    let (id, page) = posting
                    guard id < first.count else { throw FolderIndexDamaged(why: "A posting out of range.") }
                    if first[id] < 0 || page >= count[id] { continue } // a file that is gone
                    let bit = first[id] + page
                    bits[bit >> 6] |= 1 << UInt64(bit & 63)
                }
            }
        }
    }

    private static func anyPage(_ bits: [UInt64], _ first: Int, _ count: Int) -> Bool {
        var p = first
        while p < first + count {
            if p & 63 == 0 && first + count - p >= 64 {
                if bits[p >> 6] != 0 { return true }
                p += 64
                continue
            }
            if bits[p >> 6] & (1 << UInt64(p & 63)) != 0 { return true }
            p += 1
        }
        return false
    }

    /// Whether a page has a phrase's terms one right after the other: the first the end of a word, the last the start of
    /// one, those between whole. Whatever Find finds has that (they are the same words, folded), so a page without it
    /// needs no asking. A query's word longer than a term was cut to its first `maxChars` units (a page's words are read
    /// whole to `maxRun`): such a term between is the start of its word, and the first is somewhere in its word, whose
    /// end the cut lost. A page's run longer than `maxRun` may end in any first term (only its start is read).
    static func sideBySide(_ text: String, _ terms: [String]) -> Bool {
        guard let head = terms.first else { return false }
        let headCut = head.utf16.count >= IndexTerms.maxChars
        // Every count of terms matched so far that ends at the word before this one: a phrase can start again inside itself.
        var ends: [Int] = []
        var next: [Int] = []
        var found = false
        IndexTerms.words(PageText.searchTextOf(text)) { word in
            if found { return }
            next.removeAll(keepingCapacity: true)
            for at in ends where fits(word, terms, at) {
                if at + 1 == terms.count { found = true } else { next.append(at + 1) }
            }
            // A run longer than is read (its first maxRun units) may end in the head: its end is unknown here, so it may.
            if word.utf16.count >= IndexTerms.maxRun - 1 || (headCut ? word.contains(head) : word.hasSuffix(head)) {
                if terms.count == 1 { found = true } else { next.append(1) }
            }
            swap(&ends, &next)
        }
        return found
    }

    private static func fits(_ word: String, _ terms: [String], _ at: Int) -> Bool {
        let term = terms[at].utf16
        if at == terms.count - 1 || term.count >= IndexTerms.maxChars { return word.utf16.starts(with: term) }
        return word.utf16.elementsEqual(term)
    }

    /// `sideBySide` on a page's UTF-8 when it is quick to tell: the page and the terms plain ASCII (letters and digits are
    /// then words as `IndexTerms` reads them, lowercased), no word broken at a line's end ("-\n", which Find joins) and no
    /// term that may be a word cut short. The last term is looked for (`memmem`) where a word starts, and the words before
    /// it read backwards. Nil when it can't say: ask `sideBySide`. `lowered`: a buffer to reuse, grown to the page.
    static func sideBySideAscii(_ text: [UInt8], _ terms: [String], _ lowered: inout [UInt8]) -> Bool? {
        if terms.count < 2 || !text.allSatisfy({ $0 < 0x80 }) { return nil }
        for t in terms where mayBeCut(t) || t.isEmpty || !t.utf8.allSatisfy({ $0 < 0x80 }) { return nil }
        let n = text.count
        var hyphenBreak = false
        if n >= 2 {
            for i in 0..<(n - 1) where text[i] == 0x2D && text[i + 1] == 0x0A {
                hyphenBreak = true
                break
            }
        }
        if hyphenBreak { return nil }
        if lowered.count < n { lowered = [UInt8](repeating: 0, count: max(n, lowered.count * 2)) }
        for i in 0..<n {
            let b = text[i]
            lowered[i] = b >= 0x41 && b <= 0x5A ? b + 32 : b
        }
        let terms = terms.map { Array($0.utf8) }
        let last = terms[terms.count - 1]
        func isWordByte(_ b: UInt8) -> Bool { (b >= 0x61 && b <= 0x7A) || (b >= 0x30 && b <= 0x39) }
        return lowered.withUnsafeBufferPointer { page -> Bool in
            last.withUnsafeBufferPointer { needle -> Bool in
                guard let base = page.baseAddress, let want = needle.baseAddress else { return false }
                var from = 0
                while from < n {
                    guard let hit = memmem(base + from, n - from, want, needle.count) else { return false }
                    let at: Int = UnsafeRawPointer(base).distance(to: UnsafeRawPointer(hit))
                    from = at + 1
                    if at > 0 && isWordByte(page[at - 1]) { continue } // not where a word starts
                    var end = at
                    var ok = true
                    var k = terms.count - 2
                    while k >= 0 && ok {
                        while end > 0 && !isWordByte(page[end - 1]) { end -= 1 } // what breaks the words
                        var start = end
                        while start > 0 && isWordByte(page[start - 1]) { start -= 1 }
                        let term = terms[k]
                        let length = end - start
                        if length == 0 {
                            ok = false
                        } else if k == 0 {
                            // The first term: the end of its word.
                            ok = length >= term.count && Self.same(page, end - term.count, term)
                        } else {
                            ok = length == term.count && Self.same(page, start, term)
                        }
                        end = start
                        k -= 1
                    }
                    if ok { return true }
                }
                return false
            }
        }
    }

    private static func same(_ page: UnsafeBufferPointer<UInt8>, _ at: Int, _ term: [UInt8]) -> Bool {
        for (i, b) in term.enumerated() where page[at + i] != b { return false }
        return true
    }

    /// A query's term this long may be its word cut (to `IndexTerms.maxChars`, a unit less to keep a pair whole).
    private static func mayBeCut(_ term: String) -> Bool { term.utf16.count >= IndexTerms.maxChars - 1 }

    /// Most pages of one file a thread takes at a time.
    static let confirmChunk = 32

    /// Fewest pages of one file a thread takes at a time, unless the file has fewer in the round.
    static let confirmChunkMin = 4

    /// Where each chunk of a round starts, and the round's end last: a chunk is pages of one file, at most `confirmChunk`.
    /// In a round of fewer files than `threads`, a file's pages are shared among them (at least `confirmChunkMin` each), so
    /// a round of one big PDF keeps every thread at work.
    static func chunks(_ round: [(file: Int, page: Int)], _ starts: inout [Int], _ threads: Int) {
        starts.removeAll(keepingCapacity: true)
        // A round of as many files as threads keeps them at work file by file: a file is cut only into confirmChunk pages.
        var files = 0
        for i in round.indices where i == 0 || round[i].file != round[i - 1].file { files += 1 }
        var i = 0
        while i < round.count {
            var end = i + 1
            while end < round.count && round[end].file == round[i].file { end += 1 }
            let shared = (end - i + threads - 1) / max(1, threads)
            let size = files >= threads ? confirmChunk : min(max(shared, confirmChunkMin), confirmChunk)
            for at in stride(from: i, to: end, by: size) { starts.append(at) }
            i = end
        }
        starts.append(round.count)
    }
}

/// Pages looked at together, on several threads; their results then come out in order.
private let confirmRound = 256

/// Threads confirming pages: a search is what the person is waiting for, so all but two of the processors (twelve at
/// most), the two left for the window and the Mac's other work. A phrase of common words reads every page (inflating each
/// is most of it).
private let confirmThreads = max(1, min(12, ProcessInfo.processInfo.activeProcessorCount - 2))

/// Runs Find on each proposed page's text, in order of path and page, a round of pages at a time on several threads. The
/// words of a phrase being on a page says little about their being side by side, so a phrase's pages go through
/// `sideBySideAscii` (a plain-ASCII page, on its bytes) or `sideBySide` first: a page's words in order are read in a tenth
/// of the time Find takes. A file's pages in a round go to the threads in chunks (`FolderIndex.chunks`), its list of pages
/// read once for them all: a folder of one big PDF keeps every thread at work.
private final class Confirmer: @unchecked Sendable {
    private let state: FolderIndex.Snapshot
    private let map: FolderIndex.PageMap
    private let bits: [UInt64]
    private let query: String
    private let options: FolderSearchOptions
    private let filter: [String]?
    private let lock = NSLock()
    private var word = 0          // the next word of bits to look at
    private var pending: UInt64
    private var file = 0
    private var ready: [FolderHit] = []
    private var listed = 0
    private var done = false
    private var readers: [PageReader] = []
    private var starts: [Int] = []
    /// The round's files' lists of pages, read once by whichever thread asks first.
    private let directories = PageDirectories()

    init(_ state: FolderIndex.Snapshot, _ map: FolderIndex.PageMap, _ bits: [UInt64], _ query: String,
         _ options: FolderSearchOptions, _ terms: [String]) {
        self.state = state
        self.map = map
        self.bits = bits
        self.query = query
        self.options = options
        filter = terms.count > 1 ? terms : nil // a word cut to a term too (sideBySide)
        pending = bits.first ?? 0
    }

    func next(_ cancel: CancelToken?) throws -> FolderHit? {
        try lock.withLock {
            while ready.isEmpty && !done { try round(cancel) }
            if ready.isEmpty || listed >= options.maxPages { return nil }
            listed += 1
            if listed >= options.maxPages { done = true }
            return ready.removeFirst()
        }
    }

    /// The next round of pages (up to `confirmRound`) asked of Find on several threads, a chunk of a file's pages at a time.
    private func round(_ cancel: CancelToken?) throws {
        var round: [(file: Int, page: Int)] = []
        while round.count < confirmRound && word < bits.count {
            if pending == 0 {
                word += 1
                if word < bits.count { pending = bits[word] }
                continue
            }
            let bit = word * 64 + pending.trailingZeroBitCount
            pending &= pending - 1
            while file + 1 < map.first.count && map.first[file + 1] <= bit { file += 1 }
            let page = bit - map.first[file]
            if page >= map.files[file].pages { continue } // a file of no pages sharing its number with the next
            round.append((file, page))
        }
        if round.isEmpty {
            done = true
            return
        }
        try cancel.check()
        FolderIndex.chunks(round, &starts, confirmThreads)
        directories.clear()
        let results = RoundResults(round.count)
        let chunks = starts.count - 1
        let threads = min(confirmThreads, chunks)
        var pool = readers
        while pool.count < threads { pool.append(PageReader(state.store.file, directories)) }
        readers = pool
        let nextChunk = Counter()
        let todo = round
        let bounds = starts
        let readersNow = pool
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            let reader = readersNow[t]
            while true {
                let c = nextChunk.take()
                if c >= chunks || cancel?.isCancelled == true || results.failed { return }
                do {
                    for i in bounds[c]..<bounds[c + 1] {
                        results.set(i, try self.check(reader, self.map.files[todo[i].file], todo[i].page))
                    }
                } catch {
                    results.fail(error)
                    return
                }
            }
        }
        if let failure = results.failure { throw failure }
        try cancel.check()
        ready += results.hits
    }

    private func check(_ reader: PageReader, _ f: IndexedFile, _ page: Int) throws -> FolderHit? {
        let bytes = try reader.pageBytes(f, page)
        // A phrase: told on the bytes of a page of plain ASCII, without making it a string; Find on what is left.
        let quick: Bool? = filter.flatMap { FolderIndex.sideBySideAscii(bytes, $0, &reader.lowered) }
        if quick == false { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        if let filter, quick == nil, !FolderIndex.sideBySide(text, filter) { return nil }
        let hits = PageText.findIn(text, query, matchCase: options.matchCase, wholeWord: options.wholeWord, ignoreAccents: options.ignoreAccents)
        guard let first = hits.first else { return nil }
        let shown = PageText.excerptOf(text, first.start, first.end)
        return FolderHit(relativePath: f.relativePath, page: page, hits: hits.count, excerpt: shown.excerpt,
                         matchStart: shown.matchStart, matchLength: first.end - first.start)
    }
}

/// One round's answers, set by the threads.
private final class RoundResults: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [FolderHit?]
    private var error: Error?

    init(_ count: Int) { slots = [FolderHit?](repeating: nil, count: count) }

    func set(_ i: Int, _ hit: FolderHit?) { lock.withLock { slots[i] = hit } }

    func fail(_ e: Error) { lock.withLock { if error == nil { error = e } } }

    var failed: Bool { lock.withLock { error != nil } }

    var failure: Error? { lock.withLock { error } }

    /// The pages Find confirmed, in the round's order.
    var hits: [FolderHit] { lock.withLock { slots.compactMap { $0 } } }
}

/// A counter threads take numbers from.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func take() -> Int {
        lock.withLock {
            value += 1
            return value - 1
        }
    }
}

/// Where a file's pages' packed texts are in the index file: each page's place (from running sums), packed and plain
/// lengths and CRC.
struct PageDirectory: Sendable {
    let offsets: [Int64]
    let packed: [Int]
    let plain: [Int]
    let crcs: [UInt32]

    /// Bytes a directory of `pages` pages takes at most: the count, and per page two lengths and a CRC (5 bytes each).
    static func maxLength(_ pages: Int) -> Int { 5 + 15 * pages }

    /// The list of pages at the start of a file's text.
    static func read(_ head: ArraySlice<UInt8>, _ f: IndexedFile) throws -> PageDirectory {
        var r = VarReader(head)
        let pages = try r.int()
        guard pages == f.pages else { throw FolderIndexDamaged(why: "A file's pages out of range.") }
        var packed = [Int](repeating: 0, count: pages)
        var plain = [Int](repeating: 0, count: pages)
        var crcs = [UInt32](repeating: 0, count: pages)
        var total: Int64 = 0
        for i in 0..<pages {
            packed[i] = try r.int()
            plain[i] = try r.int()
            crcs[i] = UInt32(truncatingIfNeeded: try r.long())
            total += Int64(packed[i])
        }
        let used = Int64(r.consumed)
        guard used + total <= f.textLength else { throw FolderIndexDamaged(why: "A file's text out of range.") }
        var offsets = [Int64](repeating: 0, count: pages)
        var at = f.textOffset + used
        for i in 0..<pages {
            offsets[i] = at
            at += Int64(packed[i])
        }
        return PageDirectory(offsets: offsets, packed: packed, plain: plain, crcs: crcs)
    }
}

/// The lists of pages of a round's files, by file id, shared among the threads.
final class PageDirectories: @unchecked Sendable {
    private let lock = NSLock()
    private var known: [Int: PageDirectory] = [:]

    func get(_ id: Int) -> PageDirectory? { lock.withLock { known[id] } }

    /// `directory`, or the one another thread put there first.
    func add(_ id: Int, _ directory: PageDirectory) -> PageDirectory {
        lock.withLock {
            if let first = known[id] { return first }
            known[id] = directory
            return directory
        }
    }

    func clear() { lock.withLock { known.removeAll(keepingCapacity: true) } }
}

/// Reads pages' kept text. A file's list of pages is read once a round, whichever thread asks first (`directories`,
/// shared); a thread reads a file's text from where it starts, 256 KB at a time, as its pages of a file come one after
/// another. One thread at a time.
final class PageReader: @unchecked Sendable {
    private let cursor: Cursor
    private let directories: PageDirectories
    /// Lowercase ASCII of the page last read, for `FolderIndex.sideBySideAscii`; as long as the page.
    var lowered: [UInt8] = []

    /// What a miss reads of a file's text at most: a chunk's pages are mostly read in one go.
    private static let ahead = 256 << 10

    init(_ file: IndexFileHandle, _ directories: PageDirectories) {
        cursor = Cursor(file)
        self.directories = directories
    }

    /// A page's kept text as a string.
    func page(_ f: IndexedFile, _ page: Int) throws -> String { String(decoding: try pageBytes(f, page), as: UTF8.self) }

    /// A page's kept text as UTF-8.
    func pageBytes(_ f: IndexedFile, _ page: Int) throws -> [UInt8] {
        if f.textLength == 0 { return [] }
        var directory = directories.get(f.id)
        if directory == nil {
            // Read with the file's text after it (256 KB at most): this thread's pages of the file are then in hand.
            let head = try cursor.read(f.textOffset, Int(min(f.textLength, Int64(PageDirectory.maxLength(f.pages)))),
                                       ahead: Int(min(f.textLength, Int64(Self.ahead))))
            directory = directories.add(f.id, try PageDirectory.read(head, f))
        }
        guard let directory, page < directory.packed.count else { throw FolderIndexDamaged(why: "A page out of range.") }
        if directory.packed[page] == 0 { return [] }
        let at = directory.offsets[page]
        guard at + Int64(directory.packed[page]) <= f.textOffset + f.textLength else { throw FolderIndexDamaged(why: "A page out of range.") }
        // On a miss, the rest of the file's text, 256 KB at most.
        let rest = Int(min(max(0, f.textOffset + f.textLength - at), Int64(Self.ahead)))
        let body = Array(try cursor.read(at, directory.packed[page], ahead: rest))
        return try FolderIndex.unpackBytes(body, plainLength: directory.plain[page], crc: directory.crcs[page])
    }
}
