import Foundation
import Testing
@testable import PdfCore

/// Ported from FolderIndexerTests.cs: the indexer on real PDFs, keeping up, skipping what can't be read, pause and stop.
/// Adapted: the Mac reads in process on reading threads (no index workers), so a worker's faults are the test's
/// `readFault` on the reading thread: "die" throws (A_file_that_kills_the_reader…), "hang" sleeps through its token, "spin"
/// keeps the processor busy until it is cancelled. Windows' tests of starting workers, their memory limit, their
/// arguments, a killed writer process and Cloud Files sync roots have no counterpart (mac/docs/PLAN.md); a file being
/// written can be opened on the Mac, so the wait for a finished file is the quiet time's, and a file that can't be opened
/// is one without read permission. Mac additions: a bomb page is refused by its budget, a file that was being read when
/// the app ended twice is left alone, iCloud's dataless files, the limits on files and on the index's size.
@Suite(.serialized)
final class FolderIndexerTests {
    private let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-indexer-\(UUID().uuidString)")
    private var indexers: [FolderIndexer] = []
    private var folder: String { (dir as NSString).appendingPathComponent("folder") }
    private var base: String { (dir as NSString).appendingPathComponent("index/folder") }

    init() { try? FileManager.default.createDirectory(atPath: (dir as NSString).appendingPathComponent("folder"), withIntermediateDirectories: true) }

    deinit {
        for i in indexers { i.stop() }
        try? FileManager.default.removeItem(atPath: dir)
    }

    /// Quick to notice and to look again, with no waiting for a file to settle (each test's files are complete when it writes them).
    private static func quick() -> FolderIndexerOptions {
        var o = FolderIndexerOptions()
        o.quiet = 0
        o.debounce = 0.1
        o.rescan = 30
        o.commitEvery = 0.2
        o.maxReaders = 2
        return o
    }

    private func start(_ options: FolderIndexerOptions = quick(), paused: Bool = false) -> FolderIndexer {
        let indexer = FolderIndexer(folder: folder, basePath: base, options: options, startPaused: paused)
        indexers.append(indexer)
        indexer.start()
        return indexer
    }

    private func waitUntil(_ what: String, seconds: Double = 120, about: FolderIndexer? = nil, _ condition: () throws -> Bool) rethrows {
        let end = Date(timeIntervalSinceNow: seconds)
        while try !condition() {
            if Date() > end {
                Issue.record("Waited \(seconds) s for \(what). \(about?.status.text ?? "")")
                return
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
    }

    private func upToDate(_ indexer: FolderIndexer, _ searchable: Int) {
        waitUntil("\(searchable) files up to date", about: indexer) { indexer.status.phase == .upToDate && indexer.status.searchable == searchable }
    }

    private func search(_ indexer: FolderIndexer, _ query: String, _ options: FolderSearchOptions = FolderSearchOptions()) throws -> [FolderHit] {
        guard let index = indexer.currentIndex else { return [] }
        let run = try index.search(query, options: options)
        defer { run.close() }
        return try run.all()
    }

    @discardableResult
    private func put(_ name: String, _ marker: String, pages: Int = 1) -> String {
        put(name, TestPdf.make(pages, marker: marker))
    }

    @discardableResult
    private func put(_ name: String, _ bytes: [UInt8]) -> String {
        let path = (folder as NSString).appendingPathComponent(name)
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(bytes))
        return path
    }

    @Test func A_folder_is_indexed_with_its_subfolders_and_opened_at_the_hit() throws {
        put("one.pdf", "alpha", pages: 2)
        put("sub/deep/two.pdf", "bravo", pages: 3)
        FileManager.default.createFile(atPath: (folder as NSString).appendingPathComponent("notes.txt"), contents: Data("alpha in a file that is no PDF".utf8))
        put(".hidden/three.pdf", "alpha")
        let indexer = start()
        upToDate(indexer, 2)

        let alpha = try search(indexer, "alpha")
        #expect(Set(alpha.map(\.relativePath)) == ["one.pdf"])
        #expect(alpha.map(\.page) == [0, 1])
        #expect(alpha[1].excerpt.contains("Page 2 alpha"))
        #expect(Set(try search(indexer, "bravo").map(\.relativePath)) == ["sub/deep/two.pdf"])
        #expect(indexer.skipped().isEmpty)
    }

    @Test func Accents_and_case_are_ignored_as_Find_does_on_a_real_pdf() throws {
        // "Le RÉSUMÉ du Café" in WinAnsi: É is \311, é \351.
        put("fr.pdf", "Le R\\311SUM\\311 du Caf\\351")
        let indexer = start()
        upToDate(indexer, 1)
        #expect(try search(indexer, "resume").count == 1)
        #expect(try search(indexer, "CAFE").count == 1)
        #expect(try search(indexer, "resume", FolderSearchOptions(ignoreAccents: false)).isEmpty)
    }

    @Test func A_text_layer_from_OCR_is_found() throws {
        // A page with the recognizer's invisible text over it, as Recognize Text leaves it.
        let bytes = try TextLayer.addInvisibleText(TestPdf.make(1, marker: "visible"), nil,
                                                   [0: [OcrWord("invisibleword", RectD.fromEdges(72, 100, 192, 114))]])
        put("scan.pdf", bytes)
        let indexer = start()
        upToDate(indexer, 1)
        #expect(try search(indexer, "invisibleword").count == 1)
    }

    @Test func A_changed_file_is_found_again_and_its_old_words_are_gone() throws {
        let path = put("doc.pdf", "oldword")
        // No regular look in the time this test takes: FSEvents' notice is what finds it.
        var options = Self.quick()
        options.rescan = 3600
        let indexer = start(options)
        upToDate(indexer, 1)
        #expect(try search(indexer, "oldword").count == 1)

        FileManager.default.createFile(atPath: path, contents: Data(TestPdf.make(1, marker: "newword")))
        try waitUntil("the new word") { try search(indexer, "newword").count == 1 }
        #expect(try search(indexer, "oldword").isEmpty)
        #expect(indexer.currentIndex?.files.count == 1)
    }

    @Test func A_new_file_and_a_removal_and_a_rename_are_all_noticed() throws {
        let keep = put("keep.pdf", "keepword")
        let gone = put("gone.pdf", "goneword")
        let indexer = start()
        upToDate(indexer, 2)

        put("new.pdf", "freshword")
        try waitUntil("a new file") { try search(indexer, "freshword").count == 1 }
        try FileManager.default.removeItem(atPath: gone)
        try waitUntil("a removal") { try search(indexer, "goneword").isEmpty }
        try FileManager.default.moveItem(atPath: keep, toPath: (folder as NSString).appendingPathComponent("renamed.pdf"))
        try waitUntil("a rename") { try search(indexer, "keepword").first?.relativePath == "renamed.pdf" }
        #expect(indexer.currentIndex?.files.count == 2)
    }

    @Test func Without_change_notices_the_regular_look_finds_a_change() throws {
        let path = put("doc.pdf", "firstword")
        var options = Self.quick()
        options.rescan = 0.3
        let indexer = start(options)
        upToDate(indexer, 1)
        FileManager.default.createFile(atPath: path, contents: Data(TestPdf.make(1, marker: "secondword")))
        try waitUntil("the change") { try search(indexer, "secondword").count == 1 }
    }

    /// The Mac lets a file being written be opened (Windows refuses it while the writer holds it): a file changed less
    /// than `quiet` ago waits for the next look instead, so a copy under way isn't read half done.
    @Test func A_file_still_being_written_waits_until_it_is_finished() throws {
        let path = (folder as NSString).appendingPathComponent("copying.pdf")
        let bytes = TestPdf.make(1, marker: "lateword")
        var options = Self.quick()
        options.quiet = 1.5
        options.rescan = 0.2
        let started = Date()
        FileManager.default.createFile(atPath: path, contents: Data(bytes[0..<(bytes.count / 2)]))
        let indexer = start(options)
        waitUntil("the first look", about: indexer) { indexer.status.phase == .upToDate }
        if Date().timeIntervalSince(started) < 1 { #expect(indexer.currentIndex?.files.isEmpty == true) } // not recorded as damaged
        let handle = try #require(FileHandle(forWritingAtPath: path))
        handle.seekToEndOfFile()
        handle.write(Data(bytes[(bytes.count / 2)...]))
        try handle.close()
        try waitUntil("the finished file") { try search(indexer, "lateword").count == 1 }
        #expect(indexer.skipped().isEmpty)
    }

    @Test func A_file_that_cant_be_opened_just_now_is_tried_again() throws {
        let path = put("locked-away.pdf", "awayword")
        chmod(path, 0)
        var options = Self.quick()
        options.rescan = 0.2
        let indexer = start(options)
        waitUntil("it to say it couldn't open the file", about: indexer) { indexer.status.phase == .upToDate && indexer.status.unavailable == 1 }
        #expect(indexer.currentIndex?.files.isEmpty == true) // not recorded as damaged
        #expect(indexer.status.text.contains("couldn't be opened just now"))
        chmod(path, 0o644)
        try waitUntil("the file") { try search(indexer, "awayword").count == 1 }
    }

    @Test func Damaged_password_protected_and_too_big_files_are_skipped_counted_and_said() throws {
        put("good.pdf", "goodword")
        put("damaged.pdf", Array("%PDF-1.7\nnot really a PDF".utf8))
        put("empty.pdf", [])
        let whole = TestPdf.make(4, marker: "cutword")
        put("cut.pdf", Array(whole[0..<(whole.count / 2)]))
        put("locked.pdf", TestPdf.encrypted(2, "secret"))
        put("bigfile.pdf", [UInt8](repeating: 0, count: 1024 * 1024 + 1))
        var options = Self.quick()
        options.maxFileBytes = 1024 * 1024
        let indexer = start(options)
        waitUntil("everything looked at", about: indexer) { indexer.status.phase == .upToDate && indexer.currentIndex?.files.count == 6 }

        #expect(try search(indexer, "goodword").count == 1)
        let skipped = Dictionary(uniqueKeysWithValues: indexer.skipped().map { ($0.relativePath, $0.why) })
        #expect(skipped["damaged.pdf"] == .damaged)
        #expect(skipped["empty.pdf"] == .damaged)
        #expect(skipped["locked.pdf"] == .password)
        #expect(skipped["bigfile.pdf"] == .tooBig)
        let status = indexer.status
        #expect(status.skipped[.password] == 1)
        #expect(status.skipped[.tooBig] == 1)
        #expect(status.text.contains("password protected"))
        #expect(status.text.contains("too big"))
        #expect(status.text.contains("skipped"))
    }

    @Test func A_file_with_no_text_is_counted_and_nothing_runs_on_it() throws {
        put("blank.pdf", Core1TestPdf.build([1: "<< /Type /Catalog /Pages 2 0 R >>", 2: "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
                                             3: "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>"]))
        let indexer = start()
        waitUntil("the file", about: indexer) { indexer.status.phase == .upToDate && indexer.currentIndex?.files.count == 1 }
        #expect(indexer.currentIndex?.files["blank.pdf"]?.state == .noText)
        #expect(indexer.status.text.contains("no text yet"))
    }

    @Test func A_file_that_kills_the_reader_is_skipped_and_the_rest_are_indexed() throws {
        put("a.pdf", "aword")
        put("killer.pdf", "killword")
        put("z.pdf", "zword")
        var options = Self.quick()
        options.maxReaders = 1
        let tries = Tally()
        options.readFault = { path, _ in
            if path.hasSuffix("/killer.pdf") {
                tries.add()
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        let indexer = start(options)
        upToDate(indexer, 2)
        #expect(try search(indexer, "aword").count == 1)
        #expect(try search(indexer, "zword").count == 1)
        #expect(try search(indexer, "killword").isEmpty)
        #expect(indexer.currentIndex?.files["killer.pdf"]?.state == .crashed)
        #expect(indexer.status.text.contains("ended the app"))

        // Not read again until it changes: a hostile file costs two tries, once.
        let seen = indexer.currentIndex?.files["killer.pdf"]?.id
        indexer.refresh()
        Thread.sleep(forTimeInterval: 0.5)
        #expect(indexer.currentIndex?.files["killer.pdf"]?.id == seen)
        #expect(tries.count == 2)
    }

    /// The Mac's own crash test: the app ending while a file is read leaves it in the journal beside the index; the next
    /// start counts it, and the second time it is `crashed`, never read again until it changes.
    @Test func A_file_being_read_when_the_app_ended_twice_is_left_alone() throws {
        put("a.pdf", "aword")
        let bad = put("bad.pdf", "badword")
        var st = stat()
        stat(bad, &st)
        let ticks = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        try FileManager.default.createDirectory(atPath: (base as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        // What two launches that ended while reading it leave: one counted already, one in the journal.
        try "\(ticks)\t1\tbad.pdf".write(toFile: base + ".crashes", atomically: true, encoding: .utf8)
        try "\(ticks)\t0\tbad.pdf".write(toFile: base + ".reading", atomically: true, encoding: .utf8)
        let indexer = start()
        waitUntil("both files", about: indexer) { indexer.status.phase == .upToDate && indexer.currentIndex?.files.count == 2 }
        #expect(indexer.currentIndex?.files["bad.pdf"]?.state == .crashed)
        #expect(try search(indexer, "badword").isEmpty)
        #expect(try search(indexer, "aword").count == 1)
        #expect(!FileManager.default.fileExists(atPath: base + ".reading"))
    }

    @Test func A_file_that_never_ends_is_given_up_and_the_rest_are_indexed() throws {
        put("a.pdf", "aword")
        put("sleeper.pdf", "sleepword")
        put("z.pdf", "zword")
        var options = Self.quick()
        options.maxReaders = 1
        options.stall = 2
        options.pauseGrace = 0.5
        options.readFault = { path, _ in
            // Deaf to its token, as a call stuck outside MuPDF's checks would be; it ends by itself long after.
            if path.hasSuffix("/sleeper.pdf") { Thread.sleep(forTimeInterval: 20) }
        }
        let indexer = start(options)
        upToDate(indexer, 2)
        #expect(indexer.currentIndex?.files["sleeper.pdf"]?.state == .tooSlow)
        #expect(indexer.status.text.contains("too slow"))
    }

    @Test func A_file_that_keeps_the_processor_busy_is_given_up_by_the_time_it_took() throws {
        put("a.pdf", "aword")
        put("spinner.pdf", "spinword")
        var options = Self.quick()
        options.maxReaders = 1
        options.fileDeadline = 1
        options.readFault = { path, cancel in
            guard path.hasSuffix("/spinner.pdf") else { return }
            var x = 0
            while !cancel.isCancelled { x &+= 1 }
            if x == -1 { print(x) }
            throw CancellationError()
        }
        let indexer = start(options)
        upToDate(indexer, 1)
        #expect(indexer.currentIndex?.files["spinner.pdf"]?.state == .tooSlow)
    }

    /// The bounded engine's page check on the way: a page that would inflate to gigabytes is refused at its budget, counted
    /// as unread, and the file's other pages are searchable.
    @Test func A_bomb_page_is_refused_by_its_budget_and_the_rest_of_the_file_is_indexed() throws {
        put("bomb.pdf", PageCheckTests.bomb("7 KB, Flate twice to 4 GB"))
        put("a.pdf", "aword")
        var options = Self.quick()
        options.pageBudget = PageCheckTests.limit
        let started = Date()
        let indexer = start(options)
        upToDate(indexer, 2)
        #expect(Date().timeIntervalSince(started) < 30)
        let bomb = indexer.currentIndex?.files["bomb.pdf"]
        #expect(bomb?.state == .indexed && bomb?.pages == 3 && bomb?.failedPages == 1)
        #expect(try search(indexer, "visit notes").map(\.page) == [0, 2])
        #expect(indexer.skipped().first { $0.relativePath == "bomb.pdf" }?.reason.contains("1 of 3 pages") == true)
    }

    @Test func A_folder_that_goes_away_keeps_its_index_until_it_is_back() throws {
        put("doc.pdf", "stayword")
        let moved = folder + "-away"
        var options = Self.quick()
        options.rescan = 0.2
        let indexer = start(options)
        upToDate(indexer, 1)
        indexer.pause()
        waitUntil("the pause") { indexer.status.phase == .paused }
        indexer.resume()
        try FileManager.default.moveItem(atPath: folder, toPath: moved)
        waitUntil("it to notice", about: indexer) { indexer.status.phase == .problem }
        #expect(indexer.status.text.contains("isn't there"))
        #expect(try search(indexer, "stayword").count == 1)
        try FileManager.default.moveItem(atPath: moved, toPath: folder)
        upToDate(indexer, 1)
        #expect(try search(indexer, "stayword").count == 1)
    }

    @Test func Pausing_stops_reading_and_resuming_finishes() throws {
        for i in 0..<40 { put(String(format: "f%02d.pdf", i), String(format: "w%02dx", i), pages: 2) }
        var options = Self.quick()
        options.pauseGrace = 0.2
        let indexer = start(options)
        waitUntil("the first files") { indexer.status.done > 0 || indexer.status.phase == .upToDate }
        indexer.pause()
        waitUntil("the pause", seconds: 60) { indexer.status.phase == .paused }
        let atPause = indexer.currentIndex?.files.count
        Thread.sleep(forTimeInterval: 0.6)
        #expect(indexer.currentIndex?.files.count == atPause)
        indexer.resume()
        upToDate(indexer, 40)
    }

    @Test func Started_paused_it_reads_nothing_until_resumed() throws {
        put("doc.pdf", "wordhere")
        let indexer = start(paused: true)
        waitUntil("the pause") { indexer.status.phase == .paused }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(indexer.currentIndex?.files.isEmpty == true)
        indexer.resume()
        upToDate(indexer, 1)
    }

    @Test func Stopping_ends_the_readings_and_what_was_read_is_there_next_time() throws {
        for i in 0..<60 { put(String(format: "f%02d.pdf", i), String(format: "w%02dx", i), pages: 2) }
        let indexer = start()
        waitUntil("some files") { indexer.status.done >= 5 }
        let started = Date()
        indexer.stop()
        #expect(Date().timeIntervalSince(started) < 30)

        let index = try FolderIndex.open(base) // the lock is free, and what was read is kept
        let count = index.files.count
        index.dispose()
        #expect(count >= 1)

        let again = start()
        upToDate(again, 60)
    }

    @Test func Nothing_is_read_twice() throws {
        put("doc.pdf", "wordhere")
        let first = start()
        upToDate(first, 1)
        let id = first.currentIndex?.files["doc.pdf"]?.id
        first.stop()
        let second = start()
        upToDate(second, 1)
        #expect(second.currentIndex?.files["doc.pdf"]?.id == id)
    }

    @Test func Rebuilding_reads_everything_again_and_gives_skipped_files_another_chance() throws {
        put("good.pdf", "goodword")
        put("bad.pdf", "badword")
        var options = Self.quick()
        options.readFault = { path, _ in if path.hasSuffix("/bad.pdf") { throw CocoaError(.fileReadCorruptFile) } }
        let first = start(options)
        upToDate(first, 1)
        #expect(first.currentIndex?.files["bad.pdf"]?.state == .crashed)
        first.stop()
        let second = start()
        upToDate(second, 1)
        second.rebuild()
        upToDate(second, 2)
        #expect(try search(second, "badword").count == 1)
    }

    @Test func Removing_the_folder_deletes_its_index_file() throws {
        put("doc.pdf", "wordhere")
        let indexer = start()
        upToDate(indexer, 1)
        indexer.stopAndDelete()
        let left = (try? FileManager.default.contentsOfDirectory(atPath: (base as NSString).deletingLastPathComponent)) ?? []
        #expect(left.isEmpty, "\(left)")
    }

    @Test func Two_indexers_on_one_folder_the_second_says_so() throws {
        put("doc.pdf", "wordhere")
        let first = start()
        upToDate(first, 1)
        let second = start()
        waitUntil("the second to say so") { second.status.phase == .problem }
        #expect(second.status.text.contains("Another Inkvolt PDF"))
    }

    /// iCloud Drive's files whose bytes are only in the cloud carry `SF_DATALESS`: reading them would download them.
    @Test func A_cloud_only_file_is_told_apart_from_a_file_on_this_mac() {
        #expect(FolderIndexer.isCloudOnly(0x40000000))
        #expect(FolderIndexer.isCloudOnly(0x40000000 | UInt32(UF_HIDDEN)))
        #expect(!FolderIndexer.isCloudOnly(0))
        #expect(!FolderIndexer.isCloudOnly(UInt32(UF_HIDDEN)))
    }

    @Test func A_link_out_of_the_folder_isn_t_followed() throws {
        put("inside.pdf", "wordinside")
        let outside = (dir as NSString).appendingPathComponent("outside")
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: (outside as NSString).appendingPathComponent("beyond.pdf"), contents: Data(TestPdf.make(1, marker: "wordbeyond")))
        try FileManager.default.createSymbolicLink(atPath: (folder as NSString).appendingPathComponent("linked"), withDestinationPath: outside)
        try FileManager.default.createSymbolicLink(atPath: (folder as NSString).appendingPathComponent("alias.pdf"),
                                                   withDestinationPath: (outside as NSString).appendingPathComponent("beyond.pdf"))
        let indexer = start()
        upToDate(indexer, 1)
        #expect(try search(indexer, "wordbeyond").isEmpty)
    }

    @Test func No_reader_runs_once_it_is_up_to_date() throws {
        put("doc.pdf", "wordhere")
        let indexer = start()
        upToDate(indexer, 1)
        Thread.sleep(forTimeInterval: 0.2)
        #expect(indexer.liveReadings == 0)
    }

    @Test func Files_past_the_limit_are_counted_and_not_read() throws {
        for i in 0..<5 { put("f\(i).pdf", "w\(i)x") }
        var options = Self.quick()
        options.maxFiles = 3
        let indexer = start(options)
        upToDate(indexer, 3)
        #expect(indexer.status.overLimit == 2)
        #expect(indexer.status.text.contains("at most 3 PDFs"))
    }

    @Test func The_index_stops_growing_at_its_size_limit() throws {
        for i in 0..<12 { put(String(format: "f%02d.pdf", i), String(format: "w%02dx", i), pages: 3) }
        var options = Self.quick()
        options.maxReaders = 1
        options.commitEvery = 0
        options.maxIndexBytes = 2_000
        let indexer = start(options)
        waitUntil("the limit", about: indexer) { indexer.status.phase == .problem }
        #expect(indexer.status.text.contains("size limit"))
        let files = indexer.currentIndex?.files.count ?? 0
        #expect(files >= 1 && files < 12, "\(files) files")
        #expect((indexer.currentIndex?.fileBytes ?? 0) < 2_000 + 64 * 1024)
    }
}

/// A count the test's fault keeps across threads.
final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func add() { lock.withLock { n += 1 } }

    var count: Int { lock.withLock { n } }
}
