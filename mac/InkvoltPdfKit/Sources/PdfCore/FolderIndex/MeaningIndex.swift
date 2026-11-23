import Foundation
import PrintCore

/// A piece of a page's text to embed: its file (as the folder index has it), page and piece number, and its text.
public struct MeaningPiece: Sendable, Equatable {
    public let relativePath: String
    public let size: Int64
    public let writeTicks: Int64
    public let page: Int
    public let piece: Int
    public let text: String

    public init(_ relativePath: String, _ size: Int64, _ writeTicks: Int64, _ page: Int, _ piece: Int, _ text: String) {
        self.relativePath = relativePath
        self.size = size
        self.writeTicks = writeTicks
        self.page = page
        self.piece = piece
        self.text = text
    }
}

/// A page close in meaning to a query: its best piece's closeness (cosine, about −1 to 1).
public struct MeaningHit: Sendable, Equatable {
    public let relativePath: String
    public let page: Int
    public let piece: Int
    public let score: Double
}

/// What a meaning index lacks against its folder index: the pieces to embed, files to forget, and pieces past the size
/// limit.
public struct MeaningPending: Sendable {
    public let pieces: [MeaningPiece]
    public let gone: [String]
    public let leftOut: Int

    public init(_ pieces: [MeaningPiece], _ gone: [String], _ leftOut: Int) {
        self.pieces = pieces
        self.gone = gone
        self.leftOut = leftOut
    }

    public var isEmpty: Bool { pieces.isEmpty && gone.isEmpty }

    /// "report.pdf: pages 1–3" for each file whose text would be sent, for the send window.
    public var listing: [String] {
        var order: [String] = []
        var pages: [String: [Int]] = [:]
        for p in pieces {
            if pages[p.relativePath] == nil { order.append(p.relativePath) }
            pages[p.relativePath, default: []].append(p.page)
        }
        return order.map { loc("{0}: {1}", $0, AiText.pagesText(pages[$0] ?? [])) }
    }
}

/// Search by meaning (roadmap 4.21, Pro; the Windows `MeaningIndex`, the same file): the embeddings of a folder's pages,
/// one file beside its `FolderIndex` (`.meaning`), made by the user's own endpoint and only once the user turns it on.
/// Each page's text, as the folder index keeps it, is cut into pieces (`maxPiecesPerPage` of `maxPieceChars` UTF-16 units
/// at most); each piece's vector is kept unit length in 8 bits a number with its scale. Bounded (`maxEntries`,
/// `maxBytes`), versioned (`version`), and thrown away when the model or the endpoint changes, or when the file doesn't
/// read back whole (a checksum at its end). Files are known by path, size and time, as the folder index knows them: a
/// changed file's pieces are embedded again. One thread at a time.
public final class MeaningIndex: @unchecked Sendable {
    public static let version = 1
    public static let maxPieceChars = 1000
    public static let maxPiecesPerPage = 3
    public static let maxEntries = 50_000
    public static let maxBytes: Int64 = 256 << 20
    private static let magic = Array("INKVOLT-MEANING".utf8)
    /// Why `discarded` may say the file wasn't used without it being wrong: it couldn't be read just now (kept, tried again).
    public static let unreadableReason = "unreadable"

    private struct Entry {
        let relativePath: String
        let size: Int64
        let writeTicks: Int64
        let page: Int
        let piece: Int
        let scale: Float
        let vector: [Int8]
    }

    private var entries: [Entry] = []
    /// About what the entries take in the file (`costOf` each).
    private var bytes: Int64 = 0
    /// The most the entries may take: `maxBytes`, smaller in tests.
    let byteLimit: Int64

    /// The embedding model the vectors came from.
    public let model: String
    /// The endpoint's identity (`AiEndpoint.key`) they came from.
    public let endpoint: String
    /// How long each vector is (0 while empty).
    public private(set) var dimensions = 0
    public var count: Int { entries.count }
    /// Why the file on disk wasn't used when it was there (another model, another version, damaged); nil otherwise.
    public private(set) var discarded: String?
    /// The file couldn't be read just now: it isn't wrong, so it is neither used nor deleted.
    public var unreadable: Bool { discarded == Self.unreadableReason }

    private init(_ model: String, _ endpoint: String, _ byteLimit: Int64) {
        self.model = model
        self.endpoint = endpoint
        self.byteLimit = byteLimit
    }

    /// What one entry takes in the file at most: its vector, its path, and its numbers (at most 36 bytes, some to spare).
    private static func costOf(_ path: String, _ dimensions: Int) -> Int64 { Int64(dimensions + path.utf8.count + 48) }

    /// The file beside a folder index's base path.
    public static func pathFor(_ indexBasePath: String) -> String { indexBasePath + ".meaning" }

    /// An empty index for `model` at `endpoint`.
    public static func empty(_ model: String, _ endpoint: String, byteLimit: Int64 = maxBytes) -> MeaningIndex {
        MeaningIndex(model, endpoint, byteLimit)
    }

    /// Reads the index at `path` when it was made by `model` at `endpoint` in this `version` and reads back whole; else an
    /// empty one (`discarded` says why).
    public static func load(_ path: String, _ model: String, _ endpoint: String, byteLimit: Int64 = maxBytes) -> MeaningIndex {
        let index = MeaningIndex(model, endpoint, byteLimit)
        var st = stat()
        guard stat(path, &st) == 0 else { return index }
        if Int64(st.st_size) > byteLimit + (1 << 20) {
            index.discarded = "too large"
            return index
        }
        guard let data = FileManager.default.contents(atPath: path) else {
            index.discarded = unreadableReason
            return index
        }
        index.discarded = index.read([UInt8](data))
        if index.discarded != nil {
            index.entries = []
            index.dimensions = 0
            index.bytes = 0
        }
        return index
    }

    private func read(_ data: [UInt8]) -> String? {
        let magic = Self.magic
        if data.count < magic.count + 8 || Array(data[0..<magic.count]) != magic { return "not a meaning index" }
        let body = data[0..<(data.count - 4)]
        if LE.get32(data, data.count - 4) != Crc32.of(body) { return "damaged" }
        do {
            var r = VarReader(body[magic.count...])
            if try r.int() != Self.version { return "another version" }
            if try r.string() != model { return "another model" }
            if try r.string() != endpoint { return "another model" }
            let dims = try r.int()
            let count = try r.int()
            if dims > AiEmbeddings.maxDimensions || count > Self.maxEntries || (dims == 0) != (count == 0) { return "damaged" }
            dimensions = dims
            entries.reserveCapacity(count)
            for _ in 0..<count {
                let path = try r.string()
                let size = try r.long()
                let ticks = try r.long()
                let page = try r.int()
                let piece = try r.int()
                let scale = Float(bitPattern: UInt32(truncatingIfNeeded: try r.int()))
                if piece >= Self.maxPiecesPerPage || !scale.isFinite || scale < 0 { return "damaged" }
                let vector = try r.bytes(dims).map { Int8(bitPattern: $0) }
                entries.append(Entry(relativePath: path, size: size, writeTicks: ticks, page: page, piece: piece, scale: scale, vector: vector))
                bytes += Self.costOf(path, dims)
            }
            return r.atEnd ? nil : "damaged"
        } catch {
            return "damaged"
        }
    }

    /// Writes the index to `path` whole or not at all (a new file moved over the old).
    /// - Throws: `FolderIndexIOError` when it can't be written.
    public func save(_ path: String) throws {
        var w = VarWriter()
        w.bytes(Self.magic)
        w.int(Self.version)
        w.string(model)
        w.string(endpoint)
        w.int(dimensions)
        w.int(entries.count)
        for e in entries {
            w.string(e.relativePath)
            w.long(e.size)
            w.long(e.writeTicks)
            w.int(e.page)
            w.int(e.piece)
            w.int(Int(e.scale.bitPattern))
            w.bytes(e.vector.map { UInt8(bitPattern: $0) })
        }
        var out = w.data
        var crc = [UInt8](repeating: 0, count: 4)
        LE.put32(&crc, 0, Crc32.of(out[...]))
        out += crc
        let temp = path + ".new"
        let file = try IndexFileHandle.create(temp)
        do {
            try file.write(out, at: 0)
            try file.sync()
            file.close()
        } catch {
            file.close()
            unlink(temp)
            throw error
        }
        guard rename(temp, path) == 0 else {
            let code = errno
            unlink(temp)
            throw FolderIndexIOError(loc("Couldn't create the index file"), code)
        }
    }

    /// The pieces of a file's pages, in order: each page's text cut at a paragraph, line, sentence or word into pieces of
    /// `maxPieceChars` at most, the first `maxPiecesPerPage` of them; pages without text have none.
    public static func piecesOf(_ file: IndexedFile, _ pageTexts: [String]) -> [MeaningPiece] {
        var out: [MeaningPiece] = []
        for (p, raw) in pageTexts.enumerated() {
            let text = AiText.clean(raw)
            if text.isEmpty { continue }
            for (n, piece) in cut(text, upTo: maxPiecesPerPage).enumerated() {
                out.append(MeaningPiece(file.relativePath, file.size, file.writeTicks, p, n, piece))
            }
        }
        return out
    }

    /// Piece `piece` of a page's text as `piecesOf` cuts it ("" past its last).
    public static func pieceText(_ pageText: String, _ piece: Int) -> String {
        let pieces = cut(AiText.clean(pageText), upTo: piece + 1)
        return piece < pieces.count ? pieces[piece] : ""
    }

    /// The first `upTo` pieces of `text` (UTF-16 units, as Windows counts them).
    private static func cut(_ text: String, upTo: Int) -> [String] {
        var units = Array(text.utf16)[...]
        var out: [String] = []
        let seps: [[UInt16]] = [Array("\n\n".utf16), Array("\n".utf16), Array(". ".utf16), Array(" ".utf16)]
        while units.count > maxPieceChars && out.count < upTo {
            let start = units.startIndex
            var cut = -1
            // .NET's LastIndexOf(sep, maxPieceChars - 1, maxPieceChars / 2): a start from maxPieceChars / 2 to maxPieceChars - 1
            // whose separator ends by maxPieceChars - 1.
            for sep in seps {
                var i = maxPieceChars - sep.count
                let lowest = maxPieceChars / 2
                while i >= lowest {
                    if Array(units[(start + i)..<(start + i + sep.count)]) == sep { break }
                    i -= 1
                }
                if i >= lowest && i > 0 {
                    cut = i + sep.count
                    break
                }
            }
            if cut <= 0 { cut = UTF16.isLeadSurrogate(units[start + maxPieceChars - 1]) ? maxPieceChars - 1 : maxPieceChars }
            out.append(AiText.trimEnd(String(decoding: units[start..<(start + cut)], as: UTF16.self)))
            units = units[(start + cut)...]
            while let first = units.first, AiText.isSpace(first) { units = units.dropFirst() }
        }
        if !units.isEmpty && out.count < upTo { out.append(String(decoding: units, as: UTF16.self)) }
        return out
    }

    /// What this index lacks against `folder`: the pieces of the files new or changed since they were embedded (their
    /// text read from the folder index), in path order up to the size limit, and the files gone or changed.
    /// - Throws: `FolderIndexDamaged` when a page's text doesn't read back; `CancellationError`.
    public func pending(_ folder: FolderIndex, cancel: CancelToken? = nil) throws -> MeaningPending {
        let files = folder.files
        var have: [String: (size: Int64, ticks: Int64)] = [:]
        for e in entries where have[e.relativePath] == nil { have[e.relativePath] = (e.size, e.writeTicks) }
        let gone = have.filter { key, value in
            guard let f = files[key] else { return true }
            return f.size != value.size || f.writeTicks != value.ticks
        }.map(\.key).sorted(by: FolderIndex.pathOrder)
        let goneSet = Set(gone)
        let kept = entries.filter { !goneSet.contains($0.relativePath) }
        var count = kept.count
        var bytes = kept.reduce(Int64(0)) { $0 + Self.costOf($1.relativePath, dimensions) }
        var pieces: [MeaningPiece] = []
        var leftOut = 0
        for f in files.values.sorted(by: { FolderIndex.pathOrder($0.relativePath, $1.relativePath) }) {
            try cancel.check()
            if f.state == .damaged || f.pages == 0 || f.textLength == 0 { continue }
            if let h = have[f.relativePath], h.size == f.size, h.ticks == f.writeTicks { continue }
            if count >= Self.maxEntries || (dimensions > 0 && bytes + Self.costOf(f.relativePath, dimensions) > byteLimit) {
                leftOut += f.pages // full: a page's pieces counted as one, an estimate of what isn't searched by meaning
                continue
            }
            let texts = try folder.pageTexts((0..<f.pages).map { (f.relativePath, $0) }, cancel: cancel)
            let mine = Self.piecesOf(f, texts)
            let cost = dimensions > 0 ? Int64(mine.count) * Self.costOf(f.relativePath, dimensions) : 0
            // A file goes whole or not at all: one cut short would be kept as if embedded, and never sent again.
            if count + mine.count > Self.maxEntries || bytes + cost > byteLimit {
                leftOut += mine.count
                continue
            }
            pieces += mine
            count += mine.count
            bytes += cost
        }
        return MeaningPending(pieces, gone, leftOut)
    }

    /// Forgets every piece of `paths`.
    public func forget(_ paths: Set<String>) {
        if paths.isEmpty { return }
        entries.removeAll { paths.contains($0.relativePath) }
        if entries.isEmpty { dimensions = 0 }
        bytes = entries.reduce(Int64(0)) { $0 + Self.costOf($1.relativePath, dimensions) }
    }

    static var lengthChanged: AiError { AiError(lengthChangedMessage) }

    /// What a vector of another length is refused with (the app forgets the folder's meaning index on it).
    public static var lengthChangedMessage: String {
        loc("The embedding model now answers with vectors of another length. Search by meaning will build its index again.")
    }

    /// Adds embedded pieces (their vectors in the same order) while they fit: `maxEntries`, and the size limit once the
    /// vectors' length is known. Returns how many were added, from the first.
    /// - Throws: `AiError` when a vector's length differs from the index's (the model changed its output).
    @discardableResult
    public func add(_ pieces: [MeaningPiece], _ vectors: [[Float]]) throws -> Int {
        precondition(pieces.count == vectors.count, "A vector for each piece.")
        var added = 0
        var i = 0
        while i < pieces.count && entries.count < Self.maxEntries {
            let v = vectors[i]
            if dimensions == 0 { dimensions = v.count }
            if v.count != dimensions {
                if entries.isEmpty { dimensions = 0 }
                throw Self.lengthChanged
            }
            let p = pieces[i]
            let cost = Self.costOf(p.relativePath, dimensions)
            if bytes + cost > byteLimit { break }
            let (scale, q) = Self.quantize(v)
            entries.append(Entry(relativePath: p.relativePath, size: p.size, writeTicks: p.writeTicks, page: p.page, piece: p.piece, scale: scale, vector: q))
            bytes += cost
            added += 1
            i += 1
        }
        if entries.isEmpty { dimensions = 0 }
        return added
    }

    /// A vector made unit length, then in 8 bits a number: the largest number is ±127, `scale` brings them back.
    static func quantize(_ v: [Float]) -> (scale: Float, vector: [Int8]) {
        let unit = normalized(v)
        let largest = unit.map { abs($0) }.max() ?? 0
        let scale: Float = largest == 0 ? 0 : largest / 127
        var q = [Int8](repeating: 0, count: unit.count)
        if scale > 0 {
            // .NET's Math.Round: to even.
            for i in 0..<unit.count { q[i] = Int8(max(-127, min(127, (unit[i] / scale).rounded(.toNearestOrEven)))) }
        }
        return (scale, q)
    }

    private static func normalized(_ v: [Float]) -> [Float] {
        var sum = 0.0
        for x in v { sum += Double(x) * Double(x) }
        let length = sum.squareRoot()
        return length == 0 ? [Float](repeating: 0, count: v.count) : v.map { Float(Double($0) / length) }
    }

    /// The pages closest in meaning to `query`'s vector, best first, each page once (its best piece), at most `count`. A
    /// query of another length than the index's finds nothing.
    public func nearest(_ query: [Float], _ count: Int) -> [MeaningHit] {
        if query.count != dimensions || dimensions == 0 || count <= 0 { return [] }
        let q = Self.normalized(query)
        var best: [String: MeaningHit] = [:]
        for e in entries {
            var dot: Float = 0
            let v = e.vector
            for i in 0..<v.count { dot += q[i] * Float(v[i]) }
            let score = Double(dot) * Double(e.scale)
            let key = "\(e.page)\u{0}\(e.relativePath)"
            if let had = best[key], had.score >= score { continue }
            best[key] = MeaningHit(relativePath: e.relativePath, page: e.page, piece: e.piece, score: score)
        }
        let sorted = best.values.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.relativePath != b.relativePath { return FolderIndex.pathOrder(a.relativePath, b.relativePath) }
            return a.page < b.page
        }
        return Array(sorted.prefix(count))
    }

    /// Embeds `pending`'s pieces a batch at a time through `embed` (forgetting its gone files first), saving to `path` every
    /// few batches and at the end, so a stop keeps what was done. `progress` gets the pieces done so far.
    /// - Returns: pieces left out because the index is full (their files whole: they are said, and not sent again while it
    ///   stays full).
    @discardableResult
    public func update(_ pending: MeaningPending, embed: ([String], CancelToken?) async throws -> [[Float]], path: String,
                       progress: ((Int) -> Void)? = nil, cancel: CancelToken? = nil) async throws -> Int {
        forget(Set(pending.gone))
        // A changed file's old pieces go too, before its new ones come.
        forget(Set(pending.pieces.map(\.relativePath)))
        var done = 0
        var unsaved = 0
        var failure: Error?
        do {
            var at = 0
            while at < pending.pieces.count {
                try cancel.check()
                let batch = Array(pending.pieces[at..<min(at + AiEmbeddings.batchSize, pending.pieces.count)])
                let vectors = try await embed(batch.map(\.text), cancel)
                if vectors.count != batch.count { throw AiEmbeddings.notEmbeddings }
                let added = try add(batch, vectors)
                done += added
                progress?(done)
                if added < batch.count { break } // full (a first answer's length can make it so): the rest is left out
                unsaved += 1
                if unsaved >= 16 {
                    try save(path)
                    unsaved = 0
                }
                at += AiEmbeddings.batchSize
            }
        } catch {
            failure = error
        }
        // A file half embedded is forgotten again, so the next update embeds it whole.
        forget(Set(pending.pieces.dropFirst(done).map(\.relativePath)))
        try save(path)
        if let failure { throw failure }
        var stored = Set<String>()
        for e in entries { stored.insert("\(e.page)\u{0}\(e.piece)\u{0}\(e.relativePath)") }
        return pending.pieces.filter { !stored.contains("\($0.page)\u{0}\($0.piece)\u{0}\($0.relativePath)") }.count
    }
}
