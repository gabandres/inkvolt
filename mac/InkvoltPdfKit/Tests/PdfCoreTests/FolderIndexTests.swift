import Foundation
import Testing
@testable import PdfCore

/// Ported from FolderIndexTests.cs: the index file by itself. What goes in comes out as Find would find it, and a crash at
/// any point loses nothing committed. Adapted: paths are "/"-separated and kept as written (the Mac's volumes may tell
/// case apart: `Paths_are_kept_as_the_file_system_lists_them` replaces Windows' case-insensitive check); a folder's name
/// is hashed as written after resolving "..", "." and links, not upper-cased.
final class FolderIndexTests {
    private let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-index-\(UUID().uuidString)")
    private var base: String { (dir as NSString).appendingPathComponent("test") }

    init() { try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true) }

    deinit { try? FileManager.default.removeItem(atPath: dir) }

    private func add(_ batch: IndexBatch, _ path: String, _ pages: String?...) { add(batch, path, pages) }

    private func add(_ batch: IndexBatch, _ path: String, _ pages: [String?]) {
        let hasText = pages.contains { !($0 ?? "").isEmpty }
        batch.add(path, size: 100, writeTicks: 5, state: hasText ? .indexed : .noText, pageCount: pages.count, failedPages: 0,
                  packed: FolderIndex.packPages(pages), pages: pages)
    }

    private func commit(_ index: FolderIndex, _ fill: (IndexBatch) -> Void) throws {
        let batch = index.newBatch()
        fill(batch)
        try index.commit(batch)
    }

    private func search(_ index: FolderIndex, _ query: String, _ options: FolderSearchOptions = FolderSearchOptions()) throws -> [FolderHit] {
        let run = try index.search(query, options: options)
        defer { run.close() }
        return try run.all()
    }

    private func at(_ index: FolderIndex, _ query: String, _ options: FolderSearchOptions = FolderSearchOptions()) throws -> [String] {
        try search(index, query, options).map { "\($0.relativePath)#\($0.page + 1)" }
    }

    private func indexFiles(_ prefix: String = "test.") -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
            .filter { $0.hasPrefix(prefix) && $0.hasSuffix(".idx") }
            .map { (dir as NSString).appendingPathComponent($0) }
    }

    private func bytes(_ path: String) -> [UInt8] { [UInt8](FileManager.default.contents(atPath: path) ?? Data()) }

    private func write(_ path: String, _ bytes: [UInt8]) { FileManager.default.createFile(atPath: path, contents: Data(bytes)) }

    private func firstIndex(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard needle.count <= hay.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    @Test func A_word_is_found_with_its_page_and_context() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { b in
            add(b, "a/one.pdf", "nothing here", "the Lantern shines over the bay", nil)
            add(b, "b/two.pdf", "a lantern and another LANTERN on one page")
            add(b, "three.pdf", "no such word")
        }
        let hits = try search(index, "lantern")
        #expect(hits.map { "\($0.relativePath)#\($0.page + 1)" } == ["a/one.pdf#2", "b/two.pdf#1"])
        #expect(hits[0].hits == 1)
        #expect(hits[1].hits == 2)
        #expect(hits[0].excerpt.contains("the Lantern shines"))
        #expect(hits[0].match == "Lantern")
    }

    @Test func The_excerpt_marks_the_hit_where_text_was_cut_before_it() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "a.pdf", String(repeating: "x", count: 100) + " target " + String(repeating: "y", count: 100)) }
        let hits = try search(index, "target")
        #expect(hits.count == 1)
        #expect(hits[0].excerpt.hasPrefix("…"))
        #expect(hits[0].excerpt.hasSuffix("…"))
        #expect(hits[0].match == "target")
    }

    @Test(arguments: [("resume", "Résumé attached"), ("RÉSUMÉ", "resume attached"), ("straße", "STRASSE 5"), ("strasse", "Hauptstraße 5"),
                      ("final", "the ﬁnal page"), ("example", "an exam-\nple broken over two lines"), ("soft", "so\u{AD}ft hyphen")])
    func Accents_case_and_hyphens_are_read_as_Find_reads_them(_ c: (query: String, page: String)) throws {
        #expect(!PageText.findIn(c.page, c.query, matchCase: false, wholeWord: false, ignoreAccents: true).isEmpty) // Find finds it...
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "a.pdf", c.page) }
        #expect(try search(index, c.query).count == 1) // ...and so does the index
    }

    /// Windows' "Ærø" / "aero" case: Foundation's Find reads "æ" and "ø" as letters of their own, so the index files them
    /// as Windows does (it may fold more than Find, never less) and Find decides.
    @Test func Letters_only_Windows_reads_as_Latin_are_proposed_and_Find_decides() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "a.pdf", "aero") }
        let run = try index.search("Ærø")
        defer { run.close() }
        #expect(run.candidatePages == 1)
        let found = try run.all().count
        let find = PageText.findIn("aero", "Ærø", matchCase: false, wholeWord: false, ignoreAccents: true).count
        #expect(found == min(find, 1))
    }

    @Test(arguments: ["ntern", "lant", "LANTERN", "brass lantern", "brass   lantern"])
    func What_Find_finds_inside_words_and_across_spaces(_ query: String) throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "a.pdf", "an old brass\nlantern hung here") }
        #expect(try search(index, query).count == 1)
    }

    @Test func A_phrase_needs_its_words_side_by_side_and_options_are_Finds() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { b in
            add(b, "apart.pdf", "brass and a lantern")
            add(b, "whole.pdf", "Brass Lantern")
            add(b, "accent.pdf", "brâss lantern")
        }
        #expect(try at(index, "brass lantern") == ["accent.pdf#1", "whole.pdf#1"])
        #expect(try at(index, "brass lantern", FolderSearchOptions(ignoreAccents: false)) == ["whole.pdf#1"])
        #expect(try at(index, "brass lantern", FolderSearchOptions(matchCase: true, ignoreAccents: false)).isEmpty)
        #expect(try at(index, "Brass Lantern", FolderSearchOptions(matchCase: true)) == ["whole.pdf#1"])
        #expect(try at(index, "bras", FolderSearchOptions(wholeWord: true)).isEmpty)
    }

    @Test(arguments: [("the lantern", "by the lantern", true), ("the lantern", "other lanterns", false), ("he lant", "by the lantern", true),
                      ("big red dog", "a big red dogs", true), ("big red dog", "a big redder dog", false),
                      ("big red dog", "a big blue red dog", false), ("foo-bar baz", "foo bar  baz", true), ("東京 都", "東京 都", true),
                      ("the the", "and the the end", true)])
    func Side_by_side_reads_a_phrase_as_terms(_ c: (query: String, page: String, expected: Bool)) {
        #expect(FolderIndex.sideBySide(c.page, IndexTerms.of(c.query)) == c.expected)
    }

    @Test(arguments: [("bye bye baby", "bye bye bye baby"), ("a a b", "x a a a b y"), ("big big big dog", "big big big big dog"),
                      ("a b a c", "a b a b a c")])
    func A_phrase_that_starts_again_inside_itself_is_found(_ c: (query: String, page: String)) {
        #expect(!PageText.findIn(c.page, c.query, matchCase: false, wholeWord: false, ignoreAccents: true).isEmpty)
        #expect(FolderIndex.sideBySide(c.page, IndexTerms.of(c.query)))
    }

    @Test(arguments: [("a a b", "a a c a b"), ("a b a c", "a b a a c")])
    func A_phrase_starting_again_doesn_t_join_what_isn_t_side_by_side(_ c: (query: String, page: String)) {
        #expect(!FolderIndex.sideBySide(c.page, IndexTerms.of(c.query)))
    }

    private static func varint(_ value: Int64) -> [UInt8] {
        var out: [UInt8] = []
        var v = UInt64(bitPattern: value)
        while v >= 0x80 {
            out.append(UInt8(truncatingIfNeeded: v) | 0x80)
            v >>= 7
        }
        out.append(UInt8(v))
        return out
    }

    @Test(arguments: [(Int64(Int32.max), true), (-50, true), (Int64(Int32.max) + 5, false), (-5, false)])
    func Postings_out_of_range_are_damage(_ c: (difference: Int64, file: Bool)) {
        // A file number past what there can be, once added to the last; below zero; a page past what there can be; below zero.
        let list = Self.varint((5 << 1) | 1) + [3] + Self.varint(c.file ? (c.difference << 1) | 1 : c.difference << 1) + [0]
        #expect(throws: FolderIndexDamaged.self) {
            var reader = PostingReader(list)
            while try reader.next() != nil {}
        }
    }

    @Test(arguments: [Int64(-5), Int64(Int32.min) * 4])
    func A_damaged_posting_in_a_file_rebuilds_rather_than_stopping_a_search(_ difference: Int64) throws {
        let pages: [String?] = (0..<40).map { "hello page\($0)" }
        do {
            let index = try FolderIndex.open(base)
            try commit(index) { add($0, "a.pdf", pages) }
            index.dispose()
        }
        let path = try #require(indexFiles().first)
        var data = bytes(path)
        // "hello" on all 40 pages: file 0, page 0, then a step of one page each. The checksums cover neither postings nor text.
        let postings: [UInt8] = [1, 0] + [UInt8](repeating: 2, count: 39)
        let at = try #require(firstIndex(of: postings, in: data))
        let bad = Self.varint((difference << 1) | 1)
        data.replaceSubrange(at..<(at + bad.count), with: bad)
        write(path, data)
        let damaged = try FolderIndex.open(base)
        defer { damaged.dispose() }
        #expect(throws: FolderIndexDamaged.self) { _ = try self.search(damaged, "hello") }
        #expect(throws: FolderIndexDamaged.self) { try damaged.compact() }
    }

    @Test(arguments: ["the the", "big big dog", "exam-\nple page"])
    func A_phrase_Find_finds_passes_side_by_side(_ phrase: String) {
        let query = phrase.replacingOccurrences(of: "-\n", with: "")
        let page = "before " + phrase + " after"
        #expect(!PageText.findIn(page, query, matchCase: false, wholeWord: false, ignoreAccents: true).isEmpty)
        #expect(FolderIndex.sideBySide(page, IndexTerms.of(query)))
    }

    @Test(arguments: [("東京", "東京都の地図", true), ("京", "東京都の地図", true), ("都の地", "東京都の地図", true), ("大阪", "東京都の地図", false),
                      ("ค้นหา", "การค้นหาเอกสาร", true)])
    func Text_without_spaces_is_found(_ c: (query: String, page: String, found: Bool)) throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "a.pdf", c.page) }
        #expect((try search(index, c.query).count == 1) == c.found)
    }

    @Test func A_query_of_only_punctuation_says_so() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "a.pdf", "a + b") }
        let run = try index.search("+")
        defer { run.close() }
        #expect(!run.hasWords)
        #expect(try run.all().isEmpty)
    }

    @Test func Results_come_in_order_of_path_and_page_across_rounds_of_pages() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { b in
            for f in 0..<200 { add(b, String(format: "f%03d.pdf", 199 - f), "shared word", "nothing", "shared again") }
        }
        let hits = try at(index, "shared", FolderSearchOptions(maxPages: 10_000))
        #expect(hits.count == 400)
        #expect(hits == (0..<200).flatMap { [String(format: "f%03d.pdf#1", $0), String(format: "f%03d.pdf#3", $0)] })
    }

    @Test func A_phrase_is_found_when_many_pages_have_its_words_apart() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { b in
            for f in 0..<300 { add(b, String(format: "f%03d.pdf", f), f == 250 ? "the brass lantern" : "lantern and the brass") }
        }
        #expect(try at(index, "brass lantern") == ["f250.pdf#1"])
    }

    @Test func Candidates_are_counted_and_the_listing_stops_at_the_limit() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { b in
            for f in 0..<10 { add(b, "f\(f).pdf", "common word", "common word", "other") }
        }
        let run = try index.search("common", options: FolderSearchOptions(maxPages: 3))
        defer { run.close() }
        #expect(run.candidatePages == 20)
        #expect(run.candidateFiles == 10)
        #expect(try run.all().count == 3)
    }

    @Test func A_changed_or_removed_file_drops_out() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { b in
            add(b, "keep.pdf", "alpha")
            add(b, "change.pdf", "alpha")
            add(b, "remove.pdf", "alpha")
        }
        #expect(try search(index, "alpha").count == 3)
        let files = index.files
        try commit(index) { b in
            b.remove(files["change.pdf"]!)
            b.remove(files["remove.pdf"]!)
            add(b, "change.pdf", "beta")
        }
        #expect(try at(index, "alpha") == ["keep.pdf#1"])
        #expect(try at(index, "beta") == ["change.pdf#1"])
        #expect(index.hasDeadText)
        #expect(index.files["remove.pdf"] == nil)
    }

    @Test func Paths_are_kept_as_the_file_system_lists_them() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "Dir/File.pdf", "alpha") }
        #expect(index.files["Dir/File.pdf"] != nil)
        #expect(try at(index, "alpha") == ["Dir/File.pdf#1"])
    }

    @Test func It_comes_back_the_same_after_closing() throws {
        do {
            let index = try FolderIndex.open(base)
            try commit(index) { add($0, "one.pdf", "alpha", "beta") }
            try commit(index) { add($0, "two.pdf", "gamma") }
            let one = index.files["one.pdf"]!
            try commit(index) { $0.remove(one) }
            index.dispose()
        }
        let again = try FolderIndex.open(base)
        defer { again.dispose() }
        #expect(try at(again, "alpha").isEmpty)
        #expect(try at(again, "gamma") == ["two.pdf#1"])
        #expect(Array(again.files.keys) == ["two.pdf"])
        #expect(again.files["two.pdf"]?.pages == 1)
        #expect(again.files["two.pdf"]?.size == 100)
        #expect(again.files["two.pdf"]?.writeTicks == 5)
        #expect(again.hasDeadText)
    }

    @Test func Skipped_files_are_remembered_with_why() throws {
        do {
            let index = try FolderIndex.open(base)
            try commit(index) { $0.add("locked.pdf", size: 7, writeTicks: 8, state: .password, pageCount: 0, failedPages: 0,
                                       packed: FolderIndex.packPages([]), pages: []) }
            index.dispose()
        }
        let again = try FolderIndex.open(base)
        defer { again.dispose() }
        #expect(again.files["locked.pdf"]?.state == .password)
    }

    @Test func A_second_open_is_refused_while_the_first_holds_it() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        #expect(throws: FolderIndexBusy.self) { _ = try FolderIndex.open(self.base) }
    }

    /// A file cut at any byte, as a crash can leave it, opens at its last whole commit: everything before is there,
    /// nothing after is. Commits are flushed before their footer is written, so a cut is all a crash can do to the order
    /// of what reaches the disk.
    @Test func A_file_cut_anywhere_opens_at_its_last_whole_commit() throws {
        var lengths: [Int64] = []
        let names = ["alpha", "beta", "gamma"]
        do {
            let index = try FolderIndex.open(base)
            lengths.append(index.fileBytes)
            for name in names {
                try commit(index) { add($0, name + ".pdf", "the word \(name) on a page", "and another page") }
                lengths.append(index.fileBytes)
            }
            index.dispose()
        }
        let whole = bytes(try #require(indexFiles().first))
        let cut = (dir as NSString).appendingPathComponent("cut")
        var length = 0
        while length <= whole.count {
            for f in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] where f.hasPrefix("cut.") {
                try? FileManager.default.removeItem(atPath: (dir as NSString).appendingPathComponent(f))
            }
            write(cut + ".1.idx", Array(whole[0..<length]))
            let index = try FolderIndex.open(cut)
            let commits = lengths.filter { $0 <= Int64(length) }.count - 1
            for (n, name) in names.enumerated() {
                #expect(try search(index, name).count == (n < commits ? 1 : 0), "cut at \(length)")
            }
            #expect(index.files.count == max(0, commits))
            // And it goes on working: a new commit lands after the last whole one.
            try commit(index) { add($0, "later.pdf", "afterwards") }
            #expect(try search(index, "afterwards").count == 1)
            index.dispose()
            length += Int64(length) < lengths[1] ? 1 : 7
        }
    }

    /// A flipped byte in the part that says what the file holds stops the reading there; in terms it is found when searching.
    @Test func A_damaged_footer_or_file_list_loses_that_commit_and_those_after() throws {
        var firstEnd: Int64 = 0
        do {
            let index = try FolderIndex.open(base)
            try commit(index) { add($0, "one.pdf", "alpha") }
            firstEnd = index.fileBytes
            try commit(index) { add($0, "two.pdf", "beta") }
            index.dispose()
        }
        let file = try #require(indexFiles().first)
        var data = bytes(file)
        data[data.count - 10] ^= 0x40 // in the last footer
        write(file, data)
        let again = try FolderIndex.open(base)
        defer { again.dispose() }
        #expect(Array(again.files.keys) == ["one.pdf"])
        #expect(again.fileBytes == firstEnd)
    }

    @Test func A_damaged_header_starts_over() throws {
        do {
            let index = try FolderIndex.open(base)
            try commit(index) { add($0, "one.pdf", "alpha") }
            index.dispose()
        }
        let file = try #require(indexFiles().first)
        var data = bytes(file)
        data[3] ^= 1
        write(file, data)
        let again = try FolderIndex.open(base)
        defer { again.dispose() }
        #expect(again.files.isEmpty)
        try commit(again) { add($0, "two.pdf", "beta") }
        #expect(try search(again, "beta").count == 1)
    }

    @Test func Damaged_terms_are_reported_not_believed() throws {
        do {
            let index = try FolderIndex.open(base)
            try commit(index) { add($0, "one.pdf", "alpha uniqueword") }
            index.forgetCaches()
            index.dispose()
        }
        let file = try #require(indexFiles().first)
        var data = bytes(file)
        // The last time it is there: in the list of terms, after the page's text (kept as it is, too short to pack).
        let word = Array("uniqueword".utf8)
        let at = try #require((0...(data.count - word.count)).last { Array(data[$0..<($0 + word.count)]) == word })
        data[at] ^= 1
        write(file, data)
        let again = try FolderIndex.open(base)
        defer { again.dispose() }
        #expect(throws: FolderIndexDamaged.self) { _ = try again.search("alpha") }
    }

    @Test func A_damaged_page_is_reported_from_the_threads_that_read_it() throws {
        var textAt: Int64 = 0
        do {
            let index = try FolderIndex.open(base)
            try commit(index) { add($0, "one.pdf", "alpha " + (0..<500).map { "w\($0)" }.joined(separator: " ")) }
            textAt = index.files["one.pdf"]!.textOffset
            index.dispose()
        }
        let file = try #require(indexFiles().first)
        var data = bytes(file)
        for i in 8..<40 { data[Int(textAt) + i] ^= 0x5A }
        write(file, data)
        let again = try FolderIndex.open(base)
        defer { again.dispose() }
        let run = try again.search("alpha")
        defer { run.close() }
        #expect(throws: FolderIndexDamaged.self) { _ = try run.all() }
    }

    /// A page's text is whatever a PDF says it is: nothing in it may break the reading of words, the filing or the search.
    @Test func Any_text_at_all_can_be_filed() throws {
        var random = SeededRandom(7)
        var units = (0..<0x10000).map { UInt16($0) }
        for _ in 0..<4000 { units.append(UInt16(random.next() % 0x10000)) }
        let all = String(decoding: units, as: UTF16.self)
        var shuffled = units
        for i in stride(from: shuffled.count - 1, to: 0, by: -1) { shuffled.swapAt(i, Int(random.next() % UInt64(i + 1))) }
        let mixed = String(decoding: shuffled, as: UTF16.self)
        let supplementary = String(String.UnicodeScalarView((0..<3000).compactMap { _ in Unicode.Scalar(UInt32(0x10000 + random.next() % 0xFFFFF)) }))
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "any.pdf", all, mixed, supplementary, String(repeating: "\u{FFFD}", count: 100), String(repeating: "x", count: 200_000)) }
        try commit(index) { add($0, "two.pdf", "ordinary words") }
        try index.compact()
        #expect(try search(index, "ordinary").count == 1)
        let allUnits = Array(all.utf16)
        for query in [String(decoding: allUnits[1000..<1040], as: UTF16.self), String(mixed.prefix(30)), String(supplementary.prefix(20)),
                      String(decoding: [0xD83D], as: UTF16.self), String(decoding: [0xDC00, 0x78], as: UTF16.self)] {
            let run = try index.search(query)
            _ = try run.all()
            run.close()
        }
    }

    @Test func Compacting_keeps_what_is_live_and_lets_go_of_what_is_not() throws {
        let index = try FolderIndex.open(base)
        try commit(index) { b in
            add(b, "keep.pdf", "alpha keepword", "second page alpha")
            add(b, "gone.pdf", "alpha secretword")
        }
        try commit(index) { add($0, "later.pdf", "alpha laterword") }
        let gone = index.files["gone.pdf"]!
        try commit(index) { $0.remove(gone) }
        let before = index.fileBytes
        #expect(index.segments == 2)

        // Until compacted, the word is still in the file, though no search shows it...
        #expect(try at(index, "secretword").isEmpty)
        #expect(fileHas("secretword"))

        try index.compact()

        // ...afterwards it isn't.
        #expect(!fileHas("secretword"))
        #expect(index.segments == 1)
        #expect(!index.hasDeadText)
        #expect(index.fileBytes < before)
        #expect(try at(index, "alpha") == ["keep.pdf#1", "keep.pdf#2", "later.pdf#1"])
        #expect(try at(index, "laterword") == ["later.pdf#1"])
        #expect(indexFiles().count == 1)

        // It goes on from there, and opens again.
        try commit(index) { add($0, "after.pdf", "alpha afterword") }
        index.dispose()
        let again = try FolderIndex.open(base)
        defer { again.dispose() }
        #expect(try at(again, "alpha") == ["after.pdf#1", "keep.pdf#1", "keep.pdf#2", "later.pdf#1"])
    }

    /// The word anywhere in the newest index file's bytes: its commit's list of terms has it as it is (and so does a short
    /// page's text, kept unpacked when packing doesn't make it smaller).
    private func fileHas(_ word: String) -> Bool {
        guard let file = indexFiles().sorted().last else { return false }
        return firstIndex(of: Array(word.utf8), in: bytes(file)) != nil
    }

    @Test func A_search_under_way_finishes_on_the_file_it_began_with() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { b in
            for i in 0..<20 { add(b, String(format: "f%02d.pdf", i), "alpha") }
        }
        try commit(index) { add($0, "z.pdf", "alpha") }
        let run = try index.search("alpha")
        defer { run.close() }
        #expect(try run.next() != nil)

        try index.compact()
        let z = index.files["z.pdf"]!
        try commit(index) { $0.remove(z) }
        try index.compact()

        var count = 1
        while try run.next() != nil { count += 1 }
        #expect(count == 21)
    }

    @Test func Compacting_stops_when_cancelled_and_nothing_changes() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "a.pdf", "alpha") }
        let cancel = CancelToken()
        cancel.cancel()
        #expect(throws: CancellationError.self) { try index.compact(cancel: cancel) }
        #expect(try search(index, "alpha").count == 1)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func A_crash_during_compaction_leaves_the_old_file_in_charge() throws {
        do {
            let index = try FolderIndex.open(base)
            try commit(index) { add($0, "a.pdf", "alpha") }
            index.dispose()
        }
        write(base + ".2.idx.tmp", [1, 2, 3]) // what a compaction leaves when the power goes
        let again = try FolderIndex.open(base)
        defer { again.dispose() }
        #expect(try search(again, "alpha").count == 1)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasSuffix(".tmp") }.isEmpty)
    }

    @Test func An_unreadable_newer_file_gives_way_to_the_one_before() throws {
        do {
            let index = try FolderIndex.open(base)
            try commit(index) { add($0, "a.pdf", "alpha") }
            index.dispose()
        }
        write(base + ".9.idx", [1, 2, 3])
        let again = try FolderIndex.open(base)
        defer { again.dispose() }
        #expect(try search(again, "alpha").count == 1)
    }

    @Test func Clearing_empties_it_and_the_old_file_goes() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "a.pdf", "alpha") }
        try index.clear()
        #expect(index.files.isEmpty)
        #expect(try search(index, "alpha").isEmpty)
        #expect(indexFiles().count == 1)
        try commit(index) { add($0, "b.pdf", "beta") }
        #expect(try search(index, "beta").count == 1)
    }

    @Test func Deleting_removes_every_trace() throws {
        let index = try FolderIndex.open(base)
        try commit(index) { add($0, "a.pdf", "alpha") }
        index.disposeAndDelete()
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []).filter { $0.hasPrefix("test") }.isEmpty)
    }

    @Test func Every_commit_is_searched_and_many_words_stay_in_order() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        for round in 0..<5 {
            try commit(index) { b in
                for f in 0..<40 {
                    let words = (0..<200).map { "w\($0)x\((f + $0) % 37)" }.joined(separator: " ")
                    add(b, String(format: "c%df%02d.pdf", round, f), words, "page two shared\(round)")
                }
            }
        }
        #expect(index.segments == 5)
        #expect(try search(index, "shared3").count == 40)
        #expect(try search(index, "shared").count == 200)
        try index.compact()
        #expect(index.segments == 1)
        #expect(try search(index, "shared3").count == 40)
        #expect(try search(index, "shared").count == 200)
        #expect(try search(index, "w5x7").contains { $0.relativePath == "c0f02.pdf" }) // (2 + 5) % 37
    }

    /// Mac addition (review): the excerpt says where its match starts, so nothing else works it out again.
    @Test(arguments: [0, 5, 39, 40, 41, 100])
    func The_excerpt_says_where_its_match_starts(_ before: Int) {
        let text = String(repeating: "x", count: before) + "target\nafter"
        let shown = PageText.excerptOf(text, before, before + 6)
        let units = Array(shown.excerpt.utf16)
        #expect(String(decoding: units[shown.matchStart..<(shown.matchStart + 6)], as: UTF16.self) == "target")
        #expect(shown.excerpt.hasPrefix("…") == (before > 40))
    }

    /// Mac addition (review): a search takes no lock that writing holds, so a long commit or a compaction doesn't hold it up.
    @Test func A_search_doesn_t_wait_for_a_commit_or_a_compaction() throws {
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { add($0, "a.pdf", "lantern") }
        let held = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            index.holdingWrites {
                held.signal()
                Thread.sleep(forTimeInterval: 2)
            }
            released.signal()
        }
        held.wait()
        let started = Date()
        #expect(try at(index, "lantern") == ["a.pdf#1"])
        #expect(Date().timeIntervalSince(started) < 1)
        released.wait()
    }

    /// Mac addition (review): a run longer than a term (48) is filed in overlapping pieces, so its end is found as Find
    /// finds it inside the run; a long word of a query looks up its start.
    @Test func The_end_of_a_long_run_is_found_as_Find_finds_it() throws {
        let short = String(repeating: "k", count: 50) + "endmarker9"
        let long = String(repeating: "x", count: 260) + "abcdefghijklmnopqrstuvwxyz0123456789abcd"
        let index = try FolderIndex.open(base)
        defer { index.dispose() }
        try commit(index) { b in
            add(b, "a.pdf", "intro \(short) outro", "other \(long) text")
            add(b, "b.pdf", "endmarker nothing abcdefghijklmnopqrstuvw")
        }
        #expect(try at(index, "endmarker9") == ["a.pdf#1"])
        #expect(try at(index, String(short.suffix(10))) == ["a.pdf#1"])
        #expect(try at(index, "kkkkkendmarker") == ["a.pdf#1"])
        #expect(try at(index, String(long.suffix(40))) == ["a.pdf#2"])
        #expect(try at(index, String(long.dropFirst(100).prefix(48))) == ["a.pdf#2"])
        #expect(try at(index, "endmarker") == ["a.pdf#1", "b.pdf#1"])
    }

    @Test func A_folder_name_gives_one_index_however_it_is_written() {
        let a = FolderIndex.basePathFor(dir, "/Users/someone/Papers/")
        #expect(a == FolderIndex.basePathFor(dir, "/Users/someone/Papers"))
        #expect(a == FolderIndex.basePathFor(dir, "/Users/someone/Other/../Papers"))
        #expect(a != FolderIndex.basePathFor(dir, "/Users/someone/Other"))
        #expect(!(a as NSString).lastPathComponent.lowercased().contains("papers"))
    }
}

/// A small generator with a seed, so a test's "random" text is the same on every run.
struct SeededRandom {
    private var state: UInt64

    init(_ seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
