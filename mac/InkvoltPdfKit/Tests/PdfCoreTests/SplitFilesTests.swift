import Foundation
import Testing
@testable import PdfCore

/// Split Document's and Extract Pages' file per page plan, names and writing. Windows has no tests for these (its
/// `Organize.Split` validation and `PdfFiles.UniquePath` and `WriteBatch` live in the app): a Mac addition, with
/// Windows' messages.
struct SplitFilesTests {
    private static func folder() throws -> String {
        let dir = (NSTemporaryDirectory() as NSString).appendingPathComponent("splitfiles-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func splitsByCountRangesAndBookmarks() {
        let byCount = SplitFiles.parts(.pageCount, pageCount: 5, pagesPerFile: " 2 ", ranges: "", outline: [])
        #expect(byCount.parts.map(\.pages) == [[0, 1], [2, 3], [4]])
        #expect(SplitFiles.parts(.pageCount, pageCount: 5, pagesPerFile: "6", ranges: "", outline: []).error == "Enter a page count from 1 to 5.")
        #expect(SplitFiles.parts(.pageCount, pageCount: 5, pagesPerFile: "x", ranges: "", outline: []).error == "Enter a page count from 1 to 5.")

        let byRanges = SplitFiles.parts(.ranges, pageCount: 5, pagesPerFile: "", ranges: "1-2; 3, 5 ;", outline: [])
        #expect(byRanges.parts.map(\.pages) == [[0, 1], [2, 4]])
        #expect(SplitFiles.parts(.ranges, pageCount: 5, pagesPerFile: "", ranges: "1-9", outline: []).error != nil)
        #expect(SplitFiles.parts(.ranges, pageCount: 5, pagesPerFile: "", ranges: " ; ", outline: []).error == "Nothing to split.")

        // Bookmarks start parts; the pages before the first bookmark are a part of their own, with no title.
        let outline = [OutlineNode(title: "Intro", pageIndex: 1, children: []), OutlineNode(title: "Body", pageIndex: 3, children: []),
                       OutlineNode(title: "Gone", pageIndex: 9, children: [])]
        let byBookmarks = SplitFiles.parts(.bookmarks, pageCount: 5, pagesPerFile: "", ranges: "", outline: outline)
        #expect(byBookmarks.parts == [SplitPart(pages: [0]), SplitPart(pages: [1, 2], label: "Intro"), SplitPart(pages: [3, 4], label: "Body")])
        #expect(SplitFiles.parts(.bookmarks, pageCount: 5, pagesPerFile: "", ranges: "", outline: []).error == "This document has no bookmarks.")
    }

    @Test func namesEveryPartBeforeWriting() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        FileManager.default.createFile(atPath: (dir as NSString).appendingPathComponent("Report (part 1).pdf"), contents: Data())
        let parts = [SplitPart(pages: [0]), SplitPart(pages: [1], label: "A/B: C")]
        let named = SplitFiles.targets(parts, mode: .bookmarks, folder: dir, pattern: "{name} (part {n})", name: "Report")
        #expect(named.paths.map { ($0 as NSString).lastPathComponent } == ["Report (part 1) (2).pdf", "Report (part 2) - A_B_ C.pdf"])
        // Without {n}, bookmark parts are named by their titles; a part without one by the pattern, numbered if taken.
        let titled = SplitFiles.targets(parts, mode: .bookmarks, folder: dir, pattern: "{name}", name: "Report")
        #expect(titled.paths.map { ($0 as NSString).lastPathComponent } == ["Report.pdf", "Report - A_B_ C.pdf"])
        #expect(SplitFiles.targets(parts, mode: .pageCount, folder: dir, pattern: "{name}", name: "Report").error
                == "The file name must include {n} so each part gets its own file.")
        #expect(SplitFiles.targets(parts, mode: .pageCount, folder: dir + "/missing", pattern: "{n}", name: "R").error == "Choose an existing folder.")

        var reserved = Set<String>()
        let long = SplitFiles.uniquePath(dir, String(repeating: "é", count: 300) + ".pdf", &reserved)
        let name = (long as NSString).lastPathComponent
        #expect(name.hasSuffix(".pdf") && name.utf8.count <= 255 - 6 && name.count <= 124)
        #expect((SplitFiles.uniquePath(dir, " ... .pdf", &reserved) as NSString).lastPathComponent == "Untitled.pdf")
        #expect((SplitFiles.uniquePath(dir, "untitled.PDF", &reserved) as NSString).lastPathComponent == "untitled (2).PDF")
    }

    @Test func aBatchStopsAtTheFirstFailureAndSaysWhatItWrote() throws {
        let dir = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let a = (dir as NSString).appendingPathComponent("a.pdf"), b = (dir as NSString).appendingPathComponent("b.pdf")
        let c = (dir as NSString).appendingPathComponent("c.pdf")
        FileManager.default.createFile(atPath: c, contents: Data([1]))
        do {
            try SplitFiles.writeBatch([(a, { [1, 2] }), (b, { throw PdfEditError("No pages.") }), (c, { [3] })])
            Issue.record("the batch should have failed")
        } catch let e as BatchWriteError {
            #expect(e.written == [a] && e.failedPath == b)
            #expect(e.message == "Couldn't write b.pdf: No pages. These files were written before it stopped: a.pdf.")
        }
        #expect(FileManager.default.contents(atPath: a) == Data([1, 2]))
        #expect(!FileManager.default.fileExists(atPath: b))
        // A file already there is never replaced, nor removed.
        #expect(throws: BatchWriteError.self) { try SplitFiles.writeBatch([(c, { [9] })]) }
        #expect(FileManager.default.contents(atPath: c) == Data([1]))
    }
}
