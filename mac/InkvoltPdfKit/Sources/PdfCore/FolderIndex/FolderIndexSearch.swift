import Foundation

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
        guard !isDisposed else { throw FolderIndexIOError("The index is closed", EBADF) }
        let state = acquire()
        do {
            let terms = IndexTerms.of(query)
            if terms.isEmpty { return Self.finished(state, false) }
            let map = state.pages
            var found: [UInt64]?
            var seen = Set<String>()
            for term in terms where seen.insert(term).inserted {
                var bits = [UInt64](repeating: 0, count: (map.total + 64) / 64)
                try Self.markPages(state, map, Array(term.utf8), &bits, cancel)
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
    private static func markPages(_ state: Snapshot, _ map: PageMap, _ word: [UInt8], _ bits: inout [UInt64], _ cancel: CancelToken?) throws {
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
                    guard id < first.count else { throw FolderIndexDamaged(message: "A posting out of range.") }
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
    /// needs no asking.
    static func sideBySide(_ text: String, _ terms: [String]) -> Bool {
        guard let head = terms.first else { return false }
        // Every count of terms matched so far that ends at the word before this one: a phrase can start again inside itself.
        var ends: [Int] = []
        var next: [Int] = []
        var found = false
        IndexTerms.read(PageText.searchTextOf(text)) { word in
            if found { return }
            next.removeAll(keepingCapacity: true)
            for at in ends where fits(word, terms, at) {
                if at + 1 == terms.count { found = true } else { next.append(at + 1) }
            }
            if word.hasSuffix(head) {
                if terms.count == 1 { found = true } else { next.append(1) }
            }
            swap(&ends, &next)
        }
        return found
    }

    private static func fits(_ word: String, _ terms: [String], _ at: Int) -> Bool {
        at == terms.count - 1 ? word.utf16.starts(with: terms[at].utf16) : word.utf16.elementsEqual(terms[at].utf16)
    }
}

/// Pages looked at together, on several threads; their results then come out in order.
private let confirmRound = 128

/// Threads confirming pages: a search is what the person is waiting for, but the Mac has other work too.
private let confirmThreads = max(1, min(6, ProcessInfo.processInfo.activeProcessorCount / 2))

/// Runs Find on each proposed page's text, in order of path and page, a round of pages at a time on several threads. The
/// words of a phrase being on a page says little about their being side by side, so a phrase's pages go through
/// `sideBySide` first: a page's words in order are read in a tenth of the time Find takes.
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

    init(_ state: FolderIndex.Snapshot, _ map: FolderIndex.PageMap, _ bits: [UInt64], _ query: String,
         _ options: FolderSearchOptions, _ terms: [String]) {
        self.state = state
        self.map = map
        self.bits = bits
        self.query = query
        self.options = options
        filter = terms.count > 1 && terms.allSatisfy({ $0.utf16.count < IndexTerms.maxChars }) ? terms : nil
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

    /// The next round of pages (up to `confirmRound`) asked of Find on several threads.
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
        let results = RoundResults(round.count)
        let threads = min(confirmThreads, round.count)
        var pool = readers
        while pool.count < threads { pool.append(PageReader(state.store.file)) }
        readers = pool
        let nextIndex = Counter()
        let todo = round
        let readersNow = pool
        DispatchQueue.concurrentPerform(iterations: threads) { t in
            let reader = readersNow[t]
            while true {
                let i = nextIndex.take()
                if i >= todo.count || cancel?.isCancelled == true || results.failed { return }
                do {
                    results.set(i, try self.check(reader, self.map.files[todo[i].file], todo[i].page))
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
        let text = try reader.page(f, page)
        if let filter, !FolderIndex.sideBySide(text, filter) { return nil }
        let hits = PageText.findIn(text, query, matchCase: options.matchCase, wholeWord: options.wholeWord, ignoreAccents: options.ignoreAccents)
        guard let first = hits.first else { return nil }
        let before = max(0, first.start - 40)
        return FolderHit(relativePath: f.relativePath, page: page, hits: hits.count, excerpt: PageText.excerptOf(text, first.start, first.end),
                         matchStart: (before > 0 ? 1 : 0) + first.start - before, matchLength: first.end - first.start)
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

/// Reads one page's kept text, holding on to the last file's list of pages. One thread at a time.
private final class PageReader: @unchecked Sendable {
    private let cursor: Cursor
    private var id = -1
    private var packed: [Int] = []
    private var plain: [Int] = []
    private var crcs: [UInt32] = []
    private var blobs: Int64 = 0

    init(_ file: IndexFileHandle) { cursor = Cursor(file) }

    func page(_ f: IndexedFile, _ page: Int) throws -> String {
        if f.textLength == 0 { return "" }
        if f.id != id { try readDirectory(f) }
        guard page < packed.count else { throw FolderIndexDamaged(message: "A page out of range.") }
        if packed[page] == 0 { return "" }
        var at = blobs
        for i in 0..<page { at += Int64(packed[i]) }
        guard at + Int64(packed[page]) <= f.textOffset + f.textLength else { throw FolderIndexDamaged(message: "A page out of range.") }
        let body = Array(try cursor.read(at, packed[page]))
        return try FolderIndex.unpack(body, plainLength: plain[page], crc: crcs[page])
    }

    private func readDirectory(_ f: IndexedFile) throws {
        let head = try cursor.read(f.textOffset, Int(min(f.textLength, 1 << 20)))
        var r = VarReader(head)
        let pages = try r.int()
        guard pages == f.pages else { throw FolderIndexDamaged(message: "A file's pages out of range.") }
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
        let used = Int64(try Self.directoryLength(head, pages))
        guard used + total <= f.textLength else { throw FolderIndexDamaged(message: "A file's text out of range.") }
        self.packed = packed
        self.plain = plain
        self.crcs = crcs
        blobs = f.textOffset + used
        id = f.id
    }

    /// Bytes the directory of `pages` pages takes at the start of `head`.
    private static func directoryLength(_ head: ArraySlice<UInt8>, _ pages: Int) throws -> Int {
        var at = head.startIndex
        for _ in 0..<(1 + FolderIndex.directoryFields * pages) {
            while true {
                guard at < head.endIndex else { throw FolderIndexDamaged(message: "A number cut short.") }
                let b = head[at]
                at += 1
                if b < 0x80 { break }
            }
        }
        return at - head.startIndex
    }
}
