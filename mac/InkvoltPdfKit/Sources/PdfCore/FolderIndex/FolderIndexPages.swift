import Foundation

/// A page the index proposes for a question: where it is, and how many of the question's words it holds.
public struct RankedPage: Sendable, Equatable {
    /// From the indexed folder.
    public let relativePath: String
    /// The page, from 0.
    public let page: Int
    /// How many of the question's distinct words are on the page.
    public let words: Int

    public init(_ relativePath: String, _ page: Int, _ words: Int) {
        self.relativePath = relativePath
        self.page = page
        self.words = words
    }
}

extension FolderIndex {
    /// Most distinct words a question is ranked by (a question is a sentence, not a document).
    public static let maxRankWords = 32

    /// The pages holding the most of `words` (any of them, not all, as a search needs), best first and then in path and
    /// page order, at most `maxPages`: what Ask Across Folders reads before it picks the passages to send (roadmap 4.11).
    /// A word counts where a term holds it, as in `search`; words with no letter or digit count for nothing.
    /// - Throws: `CancellationError`; `FolderIndexDamaged` when the list of terms doesn't read back.
    public func rank(_ words: [String], _ maxPages: Int, cancel: CancelToken? = nil) throws -> [RankedPage] {
        var terms: [String] = []
        var seen = Set<String>()
        for word in words {
            for term in IndexTerms.of(word) where seen.insert(term).inserted && terms.count < Self.maxRankWords { terms.append(term) }
        }
        if terms.isEmpty || maxPages <= 0 { return [] }
        let state = try acquire()
        defer { state.store.release() }
        let map = state.pages
        var counts = [UInt8](repeating: 0, count: map.total)
        var bits = [UInt64](repeating: 0, count: (map.total + 64) / 64)
        for term in terms {
            for i in 0..<bits.count { bits[i] = 0 }
            try Self.markPages(state, map, IndexTerms.lookup(term), &bits, cancel)
            for w in 0..<bits.count {
                var b = bits[w]
                while b != 0 {
                    let page = w * 64 + b.trailingZeroBitCount
                    if page < counts.count { counts[page] &+= 1 }
                    b &= b - 1
                }
            }
        }
        // Best first: by words held, then in path and page order (the bits' order).
        var best: [(bit: Int, words: Int)] = []
        for p in 0..<counts.count where counts[p] > 0 { best.append((p, Int(counts[p]))) }
        best.sort { $0.words != $1.words ? $0.words > $1.words : $0.bit < $1.bit }
        let chosen = best.prefix(maxPages).sorted { $0.bit < $1.bit }
        var result: [RankedPage] = []
        var file = 0
        for (bit, n) in chosen {
            while file + 1 < map.first.count && map.first[file + 1] <= bit { file += 1 }
            while file > 0 && map.first[file] > bit { file -= 1 }
            guard file < map.files.count else { break }
            let page = bit - map.first[file]
            if page < map.files[file].pages { result.append(RankedPage(map.files[file].relativePath, page, n)) }
        }
        // Stable: equal counts keep path and page order.
        return result.enumerated().sorted { $0.element.words != $1.element.words ? $0.element.words > $1.element.words : $0.offset < $1.offset }.map(\.element)
    }

    /// The kept text of each page asked for, in the order asked; "" for a page the index doesn't have (its file gone, or the
    /// page past its end).
    /// - Throws: `CancellationError`; `FolderIndexDamaged` when a page's text doesn't read back.
    public func pageTexts(_ pages: [(relativePath: String, page: Int)], cancel: CancelToken? = nil) throws -> [String] {
        let state = try acquire()
        defer { state.store.release() }
        let reader = PageReader(state.store.file)
        var texts: [String] = []
        texts.reserveCapacity(pages.count)
        for (path, page) in pages {
            try cancel.check()
            if let f = state.byPath[path], f.state != .damaged, page >= 0, page < f.pages {
                texts.append(try reader.page(f, page))
            } else {
                texts.append("")
            }
        }
        return texts
    }
}
