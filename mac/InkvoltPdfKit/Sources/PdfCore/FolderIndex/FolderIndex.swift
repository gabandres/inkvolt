import Compression
import CryptoKit
import Darwin
import Foundation
import PrintCore

/// What became of a file when it was read for the index.
public enum IndexedState: Int, Sendable, CaseIterable {
    /// Its text is in the index (a page that couldn't be read counts in `IndexedFile.failedPages`).
    case indexed
    /// Read, and no page has text: a scan nobody has recognized yet.
    case noText
    /// Needs a password to open. Never asked, never in the index.
    case password
    /// Not a PDF that can be opened.
    case damaged
    /// Over the size or page limit, or more text than a file may keep; what was read before the limit is searchable.
    case tooBig
    /// Took too long and was given up; what was read before that is searchable.
    case tooSlow
    /// Was being read when the app ended without finishing it, twice (Windows: brought its reading process down, twice);
    /// what was read before that is searchable.
    case crashed
}

/// One file in a folder index.
public struct IndexedFile: Sendable, Equatable {
    public let id: Int
    /// From the indexed folder, "/" between folders.
    public let relativePath: String
    public let size: Int64
    /// Its modification time when read (nanoseconds since 1970): with the size, how a change is noticed.
    public let writeTicks: Int64
    public let state: IndexedState
    public let pages: Int
    /// Pages that couldn't be read (a refused page, a damaged one).
    public let failedPages: Int
    let textOffset: Int64
    let textLength: Int64

    init(id: Int, relativePath: String, size: Int64, writeTicks: Int64, state: IndexedState, pages: Int, failedPages: Int,
         textOffset: Int64, textLength: Int64) {
        self.id = id
        self.relativePath = relativePath
        self.size = size
        self.writeTicks = writeTicks
        self.state = state
        self.pages = pages
        self.failedPages = failedPages
        self.textOffset = textOffset
        self.textLength = textLength
    }

    func moved(to offset: Int64) -> IndexedFile {
        IndexedFile(id: id, relativePath: relativePath, size: size, writeTicks: writeTicks, state: state, pages: pages,
                    failedPages: failedPages, textOffset: offset, textLength: textLength)
    }
}

/// The index file can't be used (a damaged block found while searching): it is built again.
public struct FolderIndexDamaged: Error, CustomStringConvertible {
    /// What was found, for a developer: the app says only that the index is built again.
    public let why: String
    public var description: String { why }
}

/// Another Inkvolt PDF has this index open.
public struct FolderIndexBusy: Error, CustomStringConvertible {
    public var description: String { loc("Another Inkvolt PDF has this folder's index open.") }
}

/// Reading or writing the index file failed (the disk is full, the folder can't be written).
public struct FolderIndexIOError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }

    init(_ what: String, _ code: Int32 = errno) {
        message = "\(what): \(String(cString: strerror(code)))"
    }
}

/// The search index of one folder, in one local file (Windows' `FolderIndex`, the same layout). Words (`IndexTerms`) lead
/// to the pages they are on, and each page's text is kept compressed, so a search gets its results and their context
/// without opening a single PDF. `search` reads a snapshot and takes no lock, so it runs while the indexer commits.
///
/// The file is written only at its end: a header, then transactions, each a block of page texts, a block of postings
/// (term to pages), the sorted terms, what files came and went, and last a footer with checksums. A transaction counts
/// once its footer is on disk, written after everything before it was flushed (`F_FULLFSYNC`), so a crash leaves the last
/// commit readable and the torn end is cut off at the next open. `compact` writes the live contents to a new file under
/// the next generation number and renames it into place; the highest complete generation wins. An index can always be
/// built again from the PDFs, so a file that fails its checks is thrown away, never trusted.
public final class FolderIndex: @unchecked Sendable {
    static let formatVersion: Int32 = 1
    static let fileExtension = ".idx"
    static let magic = Array("INKVIDX\n".utf8)
    static let headerSize = 32
    static let txHeaderSize = 16
    static let footerSize = 32
    static let txMagic: UInt32 = 0x58544B49     // "IKTX"
    static let footerMagic: UInt32 = 0x54464B49 // "IKFT"

    private let basePath: String
    private let lockFd: Int32
    private let writeGate = NSLock()
    private let stateGate = NSLock()
    private var current: Snapshot
    private var length: Int64        // committed bytes in the current file; what is past it is thrown away (under writeGate)
    private var generation: Int      // under writeGate
    /// Set under both gates, so writing reads it under `writeGate` and a search under `stateGate`, which is only ever held
    /// for a moment: a search never waits behind a commit or a compaction, which hold `writeGate` for their whole run.
    private var disposed = false

    private init(basePath: String, lockFd: Int32, state: Snapshot, length: Int64, generation: Int) {
        self.basePath = basePath
        self.lockFd = lockFd
        current = state
        self.length = length
        self.generation = generation
    }

    deinit { dispose() }

    private var state: Snapshot { stateGate.withLock { current } }

    /// The files in the index now, by relative path.
    public var files: [String: IndexedFile] { state.byPath }

    /// Commits since the last compaction that brought their own words: each is searched on its own.
    public var segments: Int { state.segments.count }

    /// Text of files since changed or removed is still in the file (until `compact`), though no search shows it.
    public var hasDeadText: Bool { state.hasDead }

    /// The index file's size on disk.
    public var fileBytes: Int64 { stateGate.withLock { committedLength } }
    private var committedLength: Int64 = 0

    /// Opens the index at `basePath` (a path without extension), or a new empty one; recovers from a crash.
    /// - Throws: `FolderIndexBusy` when another Inkvolt PDF has it open; `FolderIndexIOError`.
    public static func open(_ basePath: String) throws -> FolderIndex {
        let dir = (basePath as NSString).deletingLastPathComponent
        let name = (basePath as NSString).lastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        } catch {
            throw FolderIndexIOError(loc("Couldn't make {0}", dir), EACCES)
        }
        let lock = try takeLock(basePath + ".lock")
        do {
            let entries = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            for entry in entries where entry.hasPrefix(name + ".") && entry.hasSuffix(".tmp") {
                unlink((dir as NSString).appendingPathComponent(entry)) // a compaction that never finished
            }
            let gens = generations(entries, name)
            let stamp = IndexTerms.stamp
            for g in gens {
                let path = pathOf(basePath, g)
                guard let found = recover(path, stamp) else {
                    unlink(path)
                    continue
                }
                for older in gens where older < g { unlink(pathOf(basePath, older)) }
                let index = FolderIndex(basePath: basePath, lockFd: lock, state: found.state, length: found.length, generation: g)
                index.committedLength = found.length
                return index
            }
            let first = (gens.first ?? 0) + 1
            let store = try createStore(pathOf(basePath, first), stamp)
            let index = FolderIndex(basePath: basePath, lockFd: lock, state: Snapshot(store, [:], [], 0, false),
                                    length: Int64(headerSize), generation: first)
            index.committedLength = Int64(headerSize)
            return index
        } catch {
            releaseLock(basePath + ".lock", lock, delete: true)
            throw error
        }
    }

    /// The lock that keeps one app on one index: `flock` on a file beside it, checked to still be that file (another
    /// app may have deleted it on closing between our open and our lock).
    private static func takeLock(_ path: String) throws -> Int32 {
        for _ in 0..<5 {
            let fd = Darwin.open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw FolderIndexIOError(loc("Couldn't open the index's lock")) }
            if flock(fd, LOCK_EX | LOCK_NB) != 0 {
                let code = errno
                Darwin.close(fd)
                if code == EWOULDBLOCK { throw FolderIndexBusy() }
                throw FolderIndexIOError(loc("Couldn't lock the index"), code)
            }
            var a = stat(), b = stat()
            if fstat(fd, &a) == 0 && stat(path, &b) == 0 && a.st_ino == b.st_ino && a.st_dev == b.st_dev { return fd }
            Darwin.close(fd) // deleted under us: try the new one
        }
        throw FolderIndexBusy()
    }

    private static func releaseLock(_ path: String, _ fd: Int32, delete: Bool) {
        if delete { unlink(path) }
        Darwin.close(fd)
    }

    /// The name a folder's index goes by in `directory`: a hash, so any path fits and no folder name is on show.
    public static func basePathFor(_ directory: String, _ folder: String) -> String {
        var full = URL(fileURLWithPath: folder).standardizedFileURL.resolvingSymlinksInPath().path
        while full.count > 1 && full.hasSuffix("/") { full.removeLast() }
        let hash = SHA256.hash(data: Data(full.utf8))
        let hex = hash.prefix(16).map { String(format: "%02x", $0) }.joined()
        return (directory as NSString).appendingPathComponent(hex)
    }

    /// Starts a batch of changes for one `commit`.
    public func newBatch() -> IndexBatch { IndexBatch(firstId: state.nextId) }

    /// Makes the batch part of the index, all of it or none: when this returns it is on disk and searches see it. A
    /// failure (the disk is full) leaves the index as it was, and the next commit overwrites what was written.
    public func commit(_ batch: IndexBatch) throws {
        try writeGate.withLock {
            guard !disposed else { throw FolderIndexIOError(loc("The index is closed"), EBADF) }
            let state = self.state
            let file = state.store.file
            try file.truncate(length)
            let start = length
            let bodyStart = start + Int64(Self.txHeaderSize)
            let (terms, dict) = batch.sortedTerms()
            let textBytes = Int64(batch.textBytes)
            let postingsStart = bodyStart + textBytes
            var postingBytes: Int64 = 0
            for t in terms { postingBytes += Int64(t.list.count) }
            let dictStart = postingsStart + postingBytes
            let segment = terms.isEmpty ? nil : SegmentInfo(dictOffset: dictStart, dictLength: Int64(dict.count), dictCrc: Crc32.of(dict),
                                                            termCount: terms.count, postingsOffset: postingsStart, postingsLength: postingBytes)
            let meta = batch.writeMeta(textStart: bodyStart, segment: segment)
            let metaStart = dictStart + Int64(dict.count)

            let writer = FileWriter(file, start)
            try writer.write(Self.txHeader(Int64(meta.count) + Int64(dict.count) + postingBytes + textBytes))
            try writer.write(batch.texts)
            for t in terms { try writer.write(t.list) }
            try writer.write(dict)
            try writer.write(meta)
            try writer.flush()
            try file.sync()
            try writer.write(Self.footer(metaStart - start, Int64(meta.count), Crc32.of(meta)))
            try writer.flush()
            try file.sync()

            let next = try Self.apply(state, meta)
            length = writer.position
            stateGate.withLock {
                current = next
                committedLength = writer.position
            }
        }
    }

    /// Writes what is live to a new file and swaps it in, one list of terms and no text of files that are gone. Searches
    /// under way finish on the old file, which is deleted then.
    /// - Throws: `CancellationError` when `cancel` fired (the index stays as it was); `FolderIndexDamaged`; `FolderIndexIOError`.
    public func compact(cancel: CancelToken? = nil) throws {
        try writeGate.withLock {
            guard !disposed else { throw FolderIndexIOError(loc("The index is closed"), EBADF) }
            let state = self.state
            let next = generation + 1
            let final = Self.pathOf(basePath, next)
            let tmp = final + ".tmp"
            do {
                let file = try IndexFileHandle.create(tmp)
                defer { file.close() }
                try file.write(Self.header(IndexTerms.stamp), at: 0)
                let writer = FileWriter(file, Int64(Self.headerSize))
                try writer.write([UInt8](repeating: 0, count: Self.txHeaderSize)) // filled in below
                let bodyStart = writer.position

                // The texts, as they are.
                let ordered = state.byPath.values.sorted { $0.id < $1.id }
                var moved: [IndexedFile] = []
                moved.reserveCapacity(ordered.count)
                let reader = Cursor(state.store.file)
                for f in ordered {
                    try cancel.check()
                    let at = writer.position
                    var left = f.textLength
                    var from = f.textOffset
                    while left > 0 {
                        let chunk = Int(min(left, 1 << 20))
                        try writer.write(reader.read(from, chunk))
                        from += Int64(chunk)
                        left -= Int64(chunk)
                    }
                    moved.append(f.moved(to: at))
                }

                // The terms of every list merged, in order, without the files that are gone.
                let postingsStart = writer.position
                let (dict, count) = try Self.mergeTerms(state, writer, cancel)
                let postingBytes = writer.position - postingsStart
                let dictStart = writer.position
                try writer.write(dict)
                let segment = count == 0 ? nil : SegmentInfo(dictOffset: dictStart, dictLength: Int64(dict.count), dictCrc: Crc32.of(dict),
                                                              termCount: count, postingsOffset: postingsStart, postingsLength: postingBytes)
                let meta = IndexBatch.writeMeta(nextId: state.nextId, removed: [], added: moved, segment: segment)
                let metaStart = writer.position
                try writer.write(meta)
                try writer.flush()
                try file.write(Self.txHeader(metaStart + Int64(meta.count) - bodyStart), at: Int64(Self.headerSize))
                try writer.write(Self.footer(metaStart - Int64(Self.headerSize), Int64(meta.count), Crc32.of(meta)))
                try writer.flush()
                try file.sync()
                try cancel.check()
                guard rename(tmp, final) == 0 else { throw FolderIndexIOError(loc("Couldn't put the tidied index in place")) }
            } catch {
                unlink(tmp)
                throw error
            }
            do {
                // The new name on disk before the old generation is retired (deleted once its searches end).
                try IndexFileHandle.syncDirectory(of: final)
            } catch {
                unlink(final)
                throw error
            }

            guard let found = Self.recover(final, IndexTerms.stamp) else {
                throw FolderIndexDamaged(why: "The compacted index doesn't read back.")
            }
            generation = next
            length = found.length
            stateGate.withLock {
                current = found.state
                committedLength = found.length
            }
            state.store.retire() // deleted when the last search on it ends
        }
    }

    /// Empties the index, as a new file: what the old one held is gone with it once searches on it end.
    public func clear() throws {
        try writeGate.withLock {
            guard !disposed else { throw FolderIndexIOError(loc("The index is closed"), EBADF) }
            let state = self.state
            let next = generation + 1
            let store = try Self.createStore(Self.pathOf(basePath, next), IndexTerms.stamp)
            generation = next
            length = Int64(Self.headerSize)
            stateGate.withLock {
                current = Snapshot(store, [:], [], state.nextId, false)
                committedLength = Int64(Self.headerSize)
            }
            state.store.retire()
        }
    }

    /// Forgets the terms kept in memory for searching; the next search reads them again.
    public func forgetCaches() {
        for segment in state.segments { segment.forget() }
    }

    /// Closes the index (its file stays).
    public func dispose() {
        writeGate.withLock {
            guard markDisposed() else { return }
            state.store.release()
            Self.releaseLock(basePath + ".lock", lockFd, delete: true)
        }
    }

    /// Closes the index and deletes its file.
    public func disposeAndDelete() {
        writeGate.withLock {
            guard markDisposed() else { return }
            state.store.retire()
            Self.releaseLock(basePath + ".lock", lockFd, delete: true)
        }
    }

    // ---- Opening ----

    static func pathOf(_ basePath: String, _ generation: Int) -> String { "\(basePath).\(generation)\(fileExtension)" }

    /// The generations there are, highest first.
    private static func generations(_ entries: [String], _ name: String) -> [Int] {
        var list: [Int] = []
        for entry in entries where entry.hasPrefix(name + ".") && entry.hasSuffix(fileExtension) {
            let middle = entry.dropFirst(name.count + 1).dropLast(fileExtension.count)
            if let g = Int(middle), g > 0 { list.append(g) }
        }
        return list.sorted(by: >)
    }

    private static func createStore(_ path: String, _ stamp: Int64) throws -> Store {
        let file = try IndexFileHandle.create(path)
        do {
            try file.write(header(stamp), at: 0)
            try file.sync()
            try IndexFileHandle.syncDirectory(of: path) // its name on disk before an older generation is retired
        } catch {
            file.close()
            unlink(path)
            throw error
        }
        return Store(path, file)
    }

    static func header(_ stamp: Int64) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: headerSize)
        h.replaceSubrange(0..<8, with: magic)
        LE.put32(&h, 8, UInt32(bitPattern: formatVersion))
        LE.put64(&h, 12, UInt64(bitPattern: stamp))
        LE.put32(&h, headerSize - 4, Crc32.of(h[0..<(headerSize - 4)]))
        return h
    }

    static func txHeader(_ bodyLength: Int64) -> [UInt8] {
        var h = [UInt8](repeating: 0, count: txHeaderSize)
        LE.put32(&h, 0, txMagic)
        LE.put64(&h, 8, UInt64(bitPattern: bodyLength))
        return h
    }

    /// `metaOffset`: where the file list starts, from the start of the transaction's header.
    static func footer(_ metaOffset: Int64, _ metaLength: Int64, _ metaCrc: UInt32) -> [UInt8] {
        var f = [UInt8](repeating: 0, count: footerSize)
        LE.put32(&f, 0, footerMagic)
        LE.put32(&f, 4, metaCrc)
        LE.put64(&f, 8, UInt64(bitPattern: metaOffset))
        LE.put64(&f, 16, UInt64(bitPattern: metaLength))
        LE.put32(&f, footerSize - 4, Crc32.of(f[0..<(footerSize - 4)]))
        return f
    }

    /// Reads a file's transactions to the last whole one and cuts off the rest. Nil: this file can't be used.
    private static func recover(_ path: String, _ stamp: Int64) -> (state: Snapshot, length: Int64)? {
        guard let file = try? IndexFileHandle.openExisting(path) else { return nil }
        do {
            let size = try file.size()
            guard size >= Int64(headerSize), try file.read(headerSize, at: 0) == header(stamp) else {
                file.close()
                return nil
            }
            let store = Store(path, file)
            var state = Snapshot(store, [:], [], 0, false)
            var position = Int64(headerSize)
            let fixed = Int64(txHeaderSize + footerSize)
            while position + fixed <= size {
                guard let tx = try? file.read(txHeaderSize, at: position), LE.get32(tx, 0) == txMagic else { break }
                let body = Int64(bitPattern: LE.get64(tx, 8))
                if body < 0 || body > size - position - fixed { break }
                let footerAt = position + Int64(txHeaderSize) + body
                guard let footer = try? file.read(footerSize, at: footerAt), LE.get32(footer, 0) == footerMagic,
                      Crc32.of(footer[0..<(footerSize - 4)]) == LE.get32(footer, footerSize - 4) else { break }
                let metaOffset = Int64(bitPattern: LE.get64(footer, 8))
                let metaLength = Int64(bitPattern: LE.get64(footer, 16))
                if metaLength < 0 || metaLength > Int64(Int32.max) || metaOffset < Int64(txHeaderSize)
                    || metaOffset + metaLength != Int64(txHeaderSize) + body { break }
                guard let meta = try? file.read(Int(metaLength), at: position + metaOffset),
                      Crc32.of(meta[...]) == LE.get32(footer, 4) else { break }
                guard let next = try? apply(state, meta) else { break }
                state = next
                position = footerAt + Int64(footerSize)
            }
            if position < size {
                try file.truncate(position)
                try file.sync()
            }
            return (state, position)
        } catch {
            file.close()
            return nil
        }
    }

    /// The state after one transaction's file list. Everything in it is checked: a file's contents are data.
    private static func apply(_ state: Snapshot, _ meta: [UInt8]) throws -> Snapshot {
        var r = VarReader(meta)
        let nextId = try r.int()
        let removed = try r.int()
        var byPath = state.byPath
        var dead = state.hasDead
        if removed > 0 {
            var byId: [Int: String] = [:]
            for f in state.byPath.values { byId[f.id] = f.relativePath }
            for _ in 0..<removed {
                if let gone = byId[try r.int()] { byPath[gone] = nil }
                dead = true
            }
        }
        let added = try r.int()
        for _ in 0..<added {
            let id = try r.int()
            let path = try r.string()
            let size = try r.long()
            let ticks = try r.long()
            let fileState = IndexedState(rawValue: try r.int())
            let pages = try r.int()
            let failed = try r.int()
            let offset = try r.long()
            let length = try r.long()
            guard let fileState, id < nextId, !path.isEmpty, offset >= 0, length >= 0, offset <= Int64.max - length else {
                throw FolderIndexDamaged(why: "A file entry out of range.")
            }
            // One entry per path: a path the index has already (a commit that didn't take it out first) is replaced, and
            // the text it had is dead, for compaction to take out.
            if byPath[path] != nil { dead = true }
            byPath[path] = IndexedFile(id: id, relativePath: path, size: size, writeTicks: ticks, state: fileState, pages: pages,
                                       failedPages: failed, textOffset: offset, textLength: length)
        }
        var segments = state.segments
        if try r.int() != 0 {
            let info = SegmentInfo(dictOffset: try r.long(), dictLength: try r.long(), dictCrc: UInt32(truncatingIfNeeded: try r.long()),
                                   termCount: try r.int(), postingsOffset: try r.long(), postingsLength: try r.long())
            segments.append(Segment(info))
        }
        guard r.atEnd else { throw FolderIndexDamaged(why: "More than a file list.") }
        return Snapshot(state.store, byPath, segments, nextId, dead)
    }

    // ---- What a search reads ----

    /// Takes the current state for a search: its file stays open until `Store.release`. Takes no lock that writing holds.
    /// - Throws: `FolderIndexIOError` once the index is closed.
    func acquire() throws -> Snapshot {
        try stateGate.withLock {
            guard !disposed else { throw FolderIndexIOError(loc("The index is closed"), EBADF) }
            current.store.addRef()
            return current
        }
    }

    /// Closes the index for searches too (under `writeGate`).
    private func markDisposed() -> Bool {
        stateGate.withLock {
            if disposed { return false }
            disposed = true
            return true
        }
    }

    /// Test hook: runs `body` holding the lock writing holds.
    func holdingWrites(_ body: () -> Void) { writeGate.withLock(body) }

    /// One generation's open file; closed when the index and the last search are done with it.
    final class Store: @unchecked Sendable {
        private let lock = NSLock()
        private var refs = 1
        private var retired = false
        let path: String
        let file: IndexFileHandle

        init(_ path: String, _ file: IndexFileHandle) {
            self.path = path
            self.file = file
        }

        func addRef() { lock.withLock { refs += 1 } }

        func release() {
            let last: Bool = lock.withLock {
                refs -= 1
                return refs == 0
            }
            guard last else { return }
            file.close()
            if lock.withLock({ retired }) { unlink(path) }
        }

        /// The index has moved on: this file goes as soon as nothing reads it.
        func retire() {
            lock.withLock { retired = true }
            release()
        }
    }

    /// One moment of the index. Never changes; a commit makes a new one.
    final class Snapshot: @unchecked Sendable {
        let store: Store
        let byPath: [String: IndexedFile]
        let segments: [Segment]
        let nextId: Int
        let hasDead: Bool
        private let lock = NSLock()
        private var map: PageMap?

        init(_ store: Store, _ byPath: [String: IndexedFile], _ segments: [Segment], _ nextId: Int, _ hasDead: Bool) {
            self.store = store
            self.byPath = byPath
            self.segments = segments
            self.nextId = nextId
            self.hasDead = hasDead
        }

        var pages: PageMap {
            lock.withLock {
                if let map { return map }
                let made = PageMap(self)
                map = made
                return made
            }
        }
    }

    /// Every page of the files in a snapshot numbered in order of path, so a set of pages is a set of bits and a search's
    /// results come out sorted.
    final class PageMap: @unchecked Sendable {
        let files: [IndexedFile]
        let first: [Int]          // the first page's number, by position in files
        let firstById: [Int]      // the same by id; -1: no longer there
        let countById: [Int]
        let total: Int

        init(_ state: Snapshot) {
            files = state.byPath.values.sorted { FolderIndex.pathOrder($0.relativePath, $1.relativePath) }
            var first = [Int](repeating: 0, count: files.count)
            var firstById = [Int](repeating: -1, count: state.nextId)
            var countById = [Int](repeating: 0, count: state.nextId)
            var total = 0
            for (i, f) in files.enumerated() {
                first[i] = total
                if f.id < firstById.count {
                    firstById[f.id] = total
                    countById[f.id] = f.pages
                }
                total = min(total + f.pages, Int(Int32.max) / 2)
            }
            self.first = first
            self.firstById = firstById
            self.countById = countById
            self.total = total
        }
    }

    /// Paths in the order Finder lists them by name: case ignored, then as written.
    static func pathOrder(_ a: String, _ b: String) -> Bool {
        let order = a.compare(b, options: [.caseInsensitive, .literal])
        if order != .orderedSame { return order == .orderedAscending }
        return a < b
    }

    /// Where one commit's list of terms and postings are.
    struct SegmentInfo: Sendable {
        let dictOffset: Int64
        let dictLength: Int64
        let dictCrc: UInt32
        let termCount: Int
        let postingsOffset: Int64
        let postingsLength: Int64
    }

    /// One commit's terms, read from the file when first searched and kept until `forget`.
    final class Segment: @unchecked Sendable {
        let info: SegmentInfo
        private let lock = NSLock()
        private var table: TermTable?

        init(_ info: SegmentInfo) { self.info = info }

        func table(_ file: IndexFileHandle) throws -> TermTable {
            if let kept = lock.withLock({ table }) { return kept }
            let read = try TermTable.read(file, info)
            lock.withLock { table = read }
            return read
        }

        func forget() { lock.withLock { table = nil } }
    }

    /// Sorted terms as one block of UTF-8 ("term\n" each), where finding a word inside any of them is one fast scan, and
    /// where each one's postings start.
    final class TermTable: @unchecked Sendable {
        let text: [UInt8]
        let starts: [Int]           // count + 1, the last at the end of the text
        let postings: [Int64]       // count + 1, offsets in the file

        var count: Int { starts.count - 1 }

        private init(text: [UInt8], starts: [Int], postings: [Int64]) {
            self.text = text
            self.starts = starts
            self.postings = postings
        }

        func term(_ i: Int) -> ArraySlice<UInt8> { text[starts[i]..<(starts[i + 1] - 1)] }

        static func read(_ file: IndexFileHandle, _ info: SegmentInfo) throws -> TermTable {
            guard info.dictLength >= 0, info.dictLength <= Int64(Int32.max), info.termCount >= 0 else {
                throw FolderIndexDamaged(why: "A list of terms out of range.")
            }
            let block: [UInt8]
            do {
                block = try file.read(Int(info.dictLength), at: info.dictOffset)
            } catch {
                throw FolderIndexDamaged(why: "A list of terms doesn't read back.")
            }
            guard Crc32.of(block[...]) == info.dictCrc else { throw FolderIndexDamaged(why: "A list of terms doesn't read back.") }
            var r = VarReader(block)
            let textLength = try r.int()
            let text = Array(try r.bytes(textLength))
            guard info.termCount <= text.count else { throw FolderIndexDamaged(why: "A list of terms cut short.") }
            var starts = [Int](repeating: 0, count: info.termCount + 1)
            var postings = [Int64](repeating: 0, count: info.termCount + 1)
            var at = 0
            for i in 0..<info.termCount {
                starts[i] = at
                guard let end = text[at...].firstIndex(of: 10) else { throw FolderIndexDamaged(why: "A list of terms cut short.") }
                at = end + 1
            }
            starts[info.termCount] = at
            guard at == text.count else { throw FolderIndexDamaged(why: "A list of terms too long.") }
            var offset = info.postingsOffset
            for i in 0..<info.termCount {
                postings[i] = offset
                let length = try r.long()
                guard length >= 0, length <= Int64(Int32.max) else { throw FolderIndexDamaged(why: "Postings out of range.") }
                offset += length
            }
            postings[info.termCount] = offset
            guard offset == info.postingsOffset + info.postingsLength else { throw FolderIndexDamaged(why: "Postings out of range.") }
            return TermTable(text: text, starts: starts, postings: postings)
        }

        /// The numbers of the terms with `word` anywhere in them, as Find finds a word inside a longer one.
        func containing(_ word: [UInt8]) -> [Int] {
            var found: [Int] = []
            if word.isEmpty || text.isEmpty { return found }
            text.withUnsafeBytes { hay in
                word.withUnsafeBytes { needle in
                    var at = 0
                    while at < hay.count {
                        guard let hit = memmem(hay.baseAddress! + at, hay.count - at, needle.baseAddress!, needle.count) else { break }
                        let offset = hay.baseAddress!.distance(to: UnsafeRawPointer(hit))
                        // The term holding the hit: the last start at or before it.
                        var lo = 0, hi = starts.count - 1
                        while lo < hi {
                            let mid = (lo + hi + 1) / 2
                            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
                        }
                        found.append(lo)
                        at = starts[lo + 1]
                    }
                }
            }
            return found
        }
    }

    /// The block of a term table: its text, then each term's postings length.
    static func buildDictionary(_ text: [UInt8], _ lengths: [Int64]) -> [UInt8] {
        var w = VarWriter()
        w.int(text.count)
        w.bytes(text)
        for length in lengths { w.long(length) }
        return w.data
    }

    /// Merges every segment's terms into `writer`'s postings; returns the dictionary and the terms kept.
    private static func mergeTerms(_ state: Snapshot, _ writer: FileWriter, _ cancel: CancelToken?) throws -> ([UInt8], Int) {
        let map = state.pages
        let tables = try state.segments.map { try $0.table(state.store.file) }
        let cursors = tables.map { _ in Cursor(state.store.file) }
        var at = [Int](repeating: 0, count: tables.count)
        var text: [UInt8] = []
        var lengths: [Int64] = []
        var output = VarWriter()
        while true {
            // The smallest term not done yet; a handful of tables, so a look at each is fine.
            var least = -1
            for t in 0..<tables.count where at[t] < tables[t].count {
                if least < 0 || tables[t].term(at[t]).lexicographicallyPrecedes(tables[least].term(at[least])) { least = t }
            }
            if least < 0 { break }
            if lengths.count & 1023 == 0 { try cancel.check() }
            let term = Array(tables[least].term(at[least]))

            output.clear()
            var lastId = 0, lastPage = -1
            var first = true
            for t in 0..<tables.count { // oldest first: ids only grow from one commit to the next
                guard at[t] < tables[t].count, tables[t].term(at[t]).elementsEqual(term) else { continue }
                let i = at[t]
                at[t] += 1
                let count = tables[t].postings[i + 1] - tables[t].postings[i]
                let list = try cursors[t].read(tables[t].postings[i], Int(count))
                var reader = PostingReader(list)
                while let posting = try reader.next() {
                    let (id, page) = posting
                    if id >= map.firstById.count || map.firstById[id] < 0 { continue }
                    if first || id != lastId {
                        output.long((Int64(id - (first ? 0 : lastId)) << 1) | 1)
                        output.int(page)
                    } else {
                        output.long(Int64(page - lastPage) << 1)
                    }
                    first = false
                    lastId = id
                    lastPage = page
                }
            }
            if output.count == 0 { continue } // only in files that are gone
            try writer.write(output.data)
            text += term
            text.append(10)
            lengths.append(Int64(output.count))
        }
        return (buildDictionary(text, lengths), lengths.count)
    }

    // ---- The text of one file ----

    /// The text of one file for the index: how many pages; each page's packed and plain length (UTF-8 bytes) and the
    /// plain text's CRC-32; then each page packed (raw DEFLATE, the Compression framework). Windows keeps neither (its
    /// zlib stream ends and checks itself): here they bound what unpacking a damaged block may make and catch damage.
    static func packPages(_ pages: [String?]) -> [UInt8] {
        var head = VarWriter()
        head.int(pages.count)
        var blobs: [UInt8] = []
        for page in pages {
            guard let page, !page.isEmpty else {
                head.int(0)
                head.int(0)
                head.int(0)
                continue
            }
            let plain = Array(page.utf8)
            // Stored as it is when packing doesn't help: a packed length equal to the plain one says so.
            let body = Deflate.compress(plain) ?? plain
            head.int(body.count)
            head.int(plain.count)
            head.long(Int64(Crc32.of(plain)))
            blobs += body
        }
        return head.data + blobs
    }

    /// Varints in a file's page directory per page: packed length, plain length, CRC.
    static let directoryFields = 3

    /// One page's text from what `packPages` wrote.
    static func unpack(_ body: [UInt8], plainLength: Int, crc: UInt32) throws -> String {
        let damaged = FolderIndexDamaged(why: "A page's text doesn't read back.")
        var plain = body
        if body.count != plainLength {
            guard plainLength > 0, plainLength <= 1 << 28, body.count < plainLength else { throw damaged }
            // One byte more than it should make: a damaged stream that runs on is caught by its length.
            var out = [UInt8](repeating: 0, count: plainLength + 1)
            let n = body.withUnsafeBufferPointer { src in
                out.withUnsafeMutableBufferPointer { dst in
                    compression_decode_buffer(dst.baseAddress!, plainLength + 1, src.baseAddress!, src.count, nil, COMPRESSION_ZLIB)
                }
            }
            guard n == plainLength else { throw damaged }
            out.removeLast()
            plain = out
        }
        guard Crc32.of(plain) == crc else { throw damaged }
        return String(decoding: plain, as: UTF8.self)
    }
}

/// Changes on their way into a `FolderIndex`, all kept in memory until `FolderIndex.commit`: files to add with their
/// words filed, files to take out. Not safe to share between threads: the indexer holds a lock. One path is one entry:
/// a path added again replaces what this batch had for it (its text and terms stay behind as dead text, so compaction
/// takes them out).
public final class IndexBatch: @unchecked Sendable {
    private let firstId: Int
    private var terms: [String: PostingList] = [:]
    private(set) var texts: [UInt8] = []
    private var added: [IndexedFile] = []
    private var latest: [String: Int] = [:]      // path → its entry in `added`
    private var replaced = Set<Int>()            // entries in `added` a later one for the same path replaced
    private var removed: [Int] = []
    private var postingBytes = 0

    init(firstId: Int) { self.firstId = firstId }

    /// Bytes this batch holds on to (and will write): the indexer commits when it has enough.
    public var bytes: Int { texts.count + postingBytes }

    public var termCount: Int { terms.count }

    /// Files this batch adds, one per path.
    public var addedCount: Int { added.count - replaced.count }

    /// The files this batch adds, one per path, in the order they were added.
    var liveAdded: [IndexedFile] { added.indices.filter { !replaced.contains($0) }.map { added[$0] } }

    public var isEmpty: Bool { added.isEmpty && removed.isEmpty }

    var textBytes: Int { texts.count }

    /// Takes `file` out when this commits.
    public func remove(_ file: IndexedFile) { removed.append(file.id) }

    /// The batch that follows this one once it is committed: its files' numbers go on from here.
    func following() -> IndexBatch { IndexBatch(firstId: firstId + added.count) }

    /// Adds a file. `packed` comes from `FolderIndex.packPages`; `pages` by page number, nil for no text.
    public func add(_ relativePath: String, size: Int64, writeTicks: Int64, state: IndexedState, pageCount: Int, failedPages: Int,
                    packed: [UInt8], pages: [String?]) {
        add(relativePath, size: size, writeTicks: writeTicks, state: state, pageCount: pageCount, failedPages: failedPages,
            packed: packed, words: Self.fileWords(pages))
    }

    /// A file's words, each with the pages it is on in order: the slow part of adding a file, done by any thread before
    /// `add`, outside whatever lock guards the batch.
    public static func fileWords(_ pages: [String?]) -> [String: [Int]] {
        var words: [String: [Int]] = [:]
        for (page, text) in pages.enumerated() {
            guard let text, !text.isEmpty else { continue }
            IndexTerms.file(PageText.searchTextOf(text)) { term in
                if words[term]?.last == page { return }
                words[term, default: []].append(page)
            }
        }
        return words
    }

    /// Adds a file whose words `fileWords` filed.
    public func add(_ relativePath: String, size: Int64, writeTicks: Int64, state: IndexedState, pageCount: Int, failedPages: Int,
                    packed: [UInt8], words: [String: [Int]]) {
        let id = firstId + added.count
        if let earlier = latest[relativePath] {
            // Read again before this was written: the later reading is the file, the earlier one's text is dead.
            replaced.insert(earlier)
            removed.append(added[earlier].id)
        }
        latest[relativePath] = added.count
        added.append(IndexedFile(id: id, relativePath: relativePath, size: size, writeTicks: writeTicks, state: state, pages: pageCount,
                                 failedPages: failedPages, textOffset: Int64(texts.count), textLength: Int64(packed.count)))
        texts += packed
        for (term, pages) in words {
            let list: PostingList
            if let had = terms[term] {
                list = had
            } else {
                list = PostingList()
                terms[term] = list
            }
            for page in pages { postingBytes += list.add(id, page) }
        }
    }

    /// Terms in the order of their UTF-8 bytes, with the block that lists them.
    func sortedTerms() -> ([(term: [UInt8], list: [UInt8])], [UInt8]) {
        var sorted = terms.map { (term: Array($0.key.utf8), list: $0.value.bytes.data) }
        sorted.sort { $0.term.lexicographicallyPrecedes($1.term) }
        var text: [UInt8] = []
        text.reserveCapacity(sorted.count * 8)
        var lengths: [Int64] = []
        lengths.reserveCapacity(sorted.count)
        for s in sorted {
            text += s.term
            text.append(10)
            lengths.append(Int64(s.list.count))
        }
        return (sorted, FolderIndex.buildDictionary(text, lengths))
    }

    /// The file list this batch's transaction ends with, with offsets now known.
    func writeMeta(textStart: Int64, segment: FolderIndex.SegmentInfo?) -> [UInt8] {
        let live = liveAdded.map { $0.moved(to: $0.textOffset + textStart) }
        return Self.writeMeta(nextId: firstId + added.count, removed: removed, added: live, segment: segment)
    }

    static func writeMeta(nextId: Int, removed: [Int], added: [IndexedFile], segment: FolderIndex.SegmentInfo?) -> [UInt8] {
        var w = VarWriter()
        w.int(nextId)
        w.int(removed.count)
        for id in removed { w.int(id) }
        w.int(added.count)
        for f in added {
            w.int(f.id)
            w.string(f.relativePath)
            w.long(f.size)
            w.long(f.writeTicks)
            w.int(f.state.rawValue)
            w.int(f.pages)
            w.int(f.failedPages)
            w.long(f.textOffset)
            w.long(f.textLength)
        }
        if let segment {
            w.int(1)
            w.long(segment.dictOffset)
            w.long(segment.dictLength)
            w.long(Int64(segment.dictCrc))
            w.int(segment.termCount)
            w.long(segment.postingsOffset)
            w.long(segment.postingsLength)
        } else {
            w.int(0)
        }
        return w.data
    }

    private final class PostingList {
        var bytes = VarWriter()
        private var id = -1
        private var page = -1

        /// Files the page once, however often the word is on it. Returns the bytes added.
        func add(_ id: Int, _ page: Int) -> Int {
            if id == self.id && page == self.page { return 0 }
            let before = bytes.count
            if id != self.id {
                bytes.long((Int64(id - max(self.id, 0)) << 1) | 1)
                bytes.int(page)
            } else {
                bytes.long(Int64(page - self.page) << 1)
            }
            self.id = id
            self.page = page
            return bytes.count - before
        }
    }
}

// ---- Small tools ----

/// An index file opened for reading and writing at positions (POSIX: `pread`, `pwrite`, `F_FULLFSYNC`).
final class IndexFileHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32

    private init(_ fd: Int32) { self.fd = fd }

    static func create(_ path: String) throws -> IndexFileHandle {
        let fd = Darwin.open(path, O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw FolderIndexIOError(loc("Couldn't create the index file")) }
        return IndexFileHandle(fd)
    }

    static func openExisting(_ path: String) throws -> IndexFileHandle {
        let fd = Darwin.open(path, O_RDWR | O_CLOEXEC)
        guard fd >= 0 else { throw FolderIndexIOError(loc("Couldn't open the index file")) }
        return IndexFileHandle(fd)
    }

    private var handle: Int32 { lock.withLock { fd } }

    func close() {
        let old: Int32 = lock.withLock {
            let had = fd
            fd = -1
            return had
        }
        if old >= 0 { Darwin.close(old) }
    }

    func size() throws -> Int64 {
        var st = stat()
        guard fstat(handle, &st) == 0 else { throw FolderIndexIOError(loc("Couldn't read the index file")) }
        return Int64(st.st_size)
    }

    /// Exactly `count` bytes at `offset`. - Throws: `FolderIndexDamaged` when the file ends too soon.
    func read(_ count: Int, at offset: Int64) throws -> [UInt8] {
        if count == 0 { return [] }
        let fd = handle
        var failed: Int32 = 0
        let bytes = [UInt8](unsafeUninitializedCapacity: count) { buf, done in
            done = 0
            while done < count {
                let n = pread(fd, buf.baseAddress! + done, count - done, off_t(offset) + off_t(done))
                if n < 0 && errno == EINTR { continue }
                if n <= 0 {
                    failed = n < 0 ? errno : 0
                    break
                }
                done += n
            }
        }
        if failed != 0 { throw FolderIndexIOError(loc("Couldn't read the index file"), failed) }
        if bytes.count < count { throw FolderIndexDamaged(why: "The index file ends too soon.") }
        return bytes
    }

    func write(_ bytes: [UInt8], at offset: Int64) throws {
        try write(bytes[...], at: offset)
    }

    func write(_ bytes: ArraySlice<UInt8>, at offset: Int64) throws {
        let fd = handle
        try bytes.withUnsafeBytes { buf in
            var done = 0
            while done < buf.count {
                let n = pwrite(fd, buf.baseAddress! + done, buf.count - done, off_t(offset) + off_t(done))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw FolderIndexIOError(loc("Couldn't write the index file")) }
                done += n
            }
        }
    }

    func truncate(_ length: Int64) throws {
        guard ftruncate(handle, off_t(length)) == 0 else { throw FolderIndexIOError(loc("Couldn't write the index file")) }
    }

    /// To the disk itself, not only its cache (`F_FULLFSYNC`; `fsync` where the file system can't).
    func sync() throws {
        let fd = handle
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw FolderIndexIOError(loc("Couldn't write the index file")) }
    }

    /// The folder's entries to the disk (a file made or renamed in it), so a crash can't lose the new name after the old
    /// file is gone.
    static func syncDirectory(of path: String) throws {
        let dir = (path as NSString).deletingLastPathComponent
        let fd = Darwin.open(dir, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { throw FolderIndexIOError(loc("Couldn't write the index file")) }
        defer { Darwin.close(fd) }
        if fcntl(fd, F_FULLFSYNC) == 0 { return }
        guard fsync(fd) == 0 else { throw FolderIndexIOError(loc("Couldn't write the index file")) }
    }
}

/// Reads through a file in order with one buffer (and back, which reads again).
final class Cursor {
    private let file: IndexFileHandle
    private var buffer: [UInt8] = []
    private var start: Int64 = Int64.min / 2

    init(_ file: IndexFileHandle) { self.file = file }

    func read(_ offset: Int64, _ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, offset >= 0 else { throw FolderIndexDamaged(why: "A block out of range.") }
        if offset >= start && offset + Int64(count) <= start + Int64(buffer.count) {
            let at = Int(offset - start)
            return buffer[at..<(at + count)]
        }
        let size = try file.size()
        let want = Int(min(Int64(max(count, 1 << 20)), max(0, size - offset)))
        if want < count { throw FolderIndexDamaged(why: "The index file ends too soon.") }
        buffer = try file.read(want, at: offset)
        start = offset
        return buffer[0..<count]
    }
}

/// Writes at a position in a file through a buffer.
final class FileWriter {
    private let file: IndexFileHandle
    private var buffer: [UInt8] = []
    private var written: Int64

    init(_ file: IndexFileHandle, _ position: Int64) {
        self.file = file
        written = position
        buffer.reserveCapacity(1 << 20)
    }

    var position: Int64 { written + Int64(buffer.count) }

    func write(_ bytes: [UInt8]) throws { try write(bytes[...]) }

    func write(_ bytes: ArraySlice<UInt8>) throws {
        if buffer.count + bytes.count > 1 << 20 {
            try flush()
            if bytes.count >= 1 << 20 {
                try file.write(bytes, at: written)
                written += Int64(bytes.count)
                return
            }
        }
        buffer += bytes
    }

    func flush() throws {
        if buffer.isEmpty { return }
        try file.write(buffer, at: written)
        written += Int64(buffer.count)
        buffer.removeAll(keepingCapacity: true)
    }
}

/// The pages a term is on: (file id, page) in order. A new file is its id's difference from the last, shifted, with the
/// low bit set, then its page; another page of the same file is the difference, shifted.
struct PostingReader {
    private var r: VarReader
    private var id = 0
    private var page = 0

    init(_ list: ArraySlice<UInt8>) { r = VarReader(list) }
    init(_ list: [UInt8]) { r = VarReader(list[...]) }

    mutating func next() throws -> (Int, Int)? {
        if r.atEnd { return nil }
        let v = try r.long()
        if v & 1 != 0 {
            id = try Self.inRange(Int64(id), v >> 1)
            page = try r.int()
        } else {
            page = try Self.inRange(Int64(page), v >> 1)
        }
        return (id, page)
    }

    /// No checksum covers postings: what they say is checked here, so damage reads as damage.
    private static func inRange(_ base: Int64, _ step: Int64) throws -> Int {
        let (sum, overflow) = base.addingReportingOverflow(step)
        guard !overflow, sum >= 0, sum <= Int64(Int32.max) else { throw FolderIndexDamaged(why: "A posting out of range.") }
        return Int(sum)
    }
}

/// Little-endian base-128 numbers: the file's small numbers in few bytes. What it reads comes from a file, so it is checked.
struct VarReader {
    private let data: ArraySlice<UInt8>
    private var at: Int

    init(_ data: [UInt8]) { self.init(data[...]) }

    init(_ data: ArraySlice<UInt8>) {
        self.data = data
        at = data.startIndex
    }

    var atEnd: Bool { at >= data.endIndex }

    mutating func long() throws -> Int64 {
        var value: UInt64 = 0
        var shift: UInt64 = 0
        while shift < 64 {
            guard at < data.endIndex else { throw FolderIndexDamaged(why: "A number cut short.") }
            let b = data[at]
            at += 1
            value |= UInt64(b & 0x7F) << shift
            if b < 0x80 { return Int64(bitPattern: value) }
            shift += 7
        }
        throw FolderIndexDamaged(why: "A number too long.")
    }

    mutating func int() throws -> Int {
        let v = try long()
        guard v >= 0, v <= Int64(Int32.max) else { throw FolderIndexDamaged(why: "A number out of range.") }
        return Int(v)
    }

    mutating func bytes(_ count: Int) throws -> ArraySlice<UInt8> {
        guard count >= 0, count <= data.endIndex - at else { throw FolderIndexDamaged(why: "A block cut short.") }
        let slice = data[at..<(at + count)]
        at += count
        return slice
    }

    mutating func string() throws -> String { String(decoding: try bytes(try int()), as: UTF8.self) }
}

/// Writes what `VarReader` reads.
struct VarWriter {
    private(set) var data: [UInt8] = []

    var count: Int { data.count }

    mutating func clear() { data.removeAll(keepingCapacity: true) }

    mutating func long(_ value: Int64) {
        var v = UInt64(bitPattern: value)
        while v >= 0x80 {
            data.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        data.append(UInt8(v))
    }

    mutating func int(_ value: Int) { long(Int64(value)) }

    mutating func bytes(_ bytes: [UInt8]) { data += bytes }

    mutating func string(_ value: String) {
        let bytes = Array(value.utf8)
        int(bytes.count)
        data += bytes
    }
}

/// Little-endian fixed-size numbers in the headers and footers.
enum LE {
    static func put32(_ a: inout [UInt8], _ at: Int, _ v: UInt32) {
        for i in 0..<4 { a[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt32(i))) }
    }

    static func put64(_ a: inout [UInt8], _ at: Int, _ v: UInt64) {
        for i in 0..<8 { a[at + i] = UInt8(truncatingIfNeeded: v >> (8 * UInt64(i))) }
    }

    static func get32(_ a: [UInt8], _ at: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(a[at + i]) << (8 * UInt32(i)) }
        return v
    }

    static func get64(_ a: [UInt8], _ at: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v |= UInt64(a[at + i]) << (8 * UInt64(i)) }
        return v
    }
}

/// The suite's CRC-32 (PrintCore), for the blocks that decide what an index file holds.
extension Crc32 {
    static func of(_ data: ArraySlice<UInt8>) -> UInt32 { update(0xFFFF_FFFF, data) ^ 0xFFFF_FFFF }
}
