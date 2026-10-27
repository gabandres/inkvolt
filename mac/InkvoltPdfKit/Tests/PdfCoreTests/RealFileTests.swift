import Foundation
import PDFKit
import Testing
@testable import PdfCore

/// Not a port: the page edits run on real documents, copied by hand into /tmp/inkvolt-d3-real (skipped when the folder
/// isn't there; real files never go into the repo). Each result must open in PdfEngine and in Apple's PDFKit with the
/// expected page count, and its pages must be the expected source pages in the expected order (compared as small
/// renders). Prints one "REAL <file> <edit> PASS|FAIL|SKIP" line per check and nothing from the documents themselves.
struct RealFileTests {
    static let folder = "/tmp/inkvolt-d3-real"

    static var files: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { $0.lowercased().hasSuffix(".pdf") }.sorted()
    }

    /// Each page drawn small, to tell pages apart.
    private struct Page {
        var width: Double, height: Double
        var image: RenderedImage
    }

    private func pages(_ data: [UInt8], password: String? = nil) throws -> [Page] {
        let e = try PdfEngine.open(data, password: password)
        defer { e.close() }
        return try (0..<e.pageCount).map { i in
            let g = e.page(i)
            return Page(width: g.width, height: g.height, image: try e.render(i, scale: 24 / max(g.width, g.height, 1)))
        }
    }

    private func same(_ a: Page, _ b: Page) -> Bool {
        guard abs(a.width - b.width) < 0.5, abs(a.height - b.height) < 0.5, a.image.width == b.image.width,
              a.image.height == b.image.height else { return false }
        var diff = 0
        for (x, y) in zip(a.image.pixels, b.image.pixels) { diff += abs(Int(x) - Int(y)) }
        return Double(diff) / Double(max(a.image.pixels.count, 1)) < 3
    }

    /// The result opens in both readers with the expected pages: `expected[k]` is the page result page k must look like.
    private func check(_ result: [UInt8], _ expected: [Page], turned: Set<Int> = []) throws -> Bool {
        let got = try pages(result)
        guard got.count == expected.count, let kit = PDFDocument(data: Data(result)), kit.pageCount == expected.count else { return false }
        for (k, page) in got.enumerated() {
            if turned.contains(k) {
                if abs(page.width - expected[k].height) > 0.5 || abs(page.height - expected[k].width) > 0.5 { return false }
            } else if !same(page, expected[k]) {
                return false
            }
        }
        return true
    }

    @Test(.enabled(if: !files.isEmpty)) func pageEditsOnRealFiles() throws {
        let docs = try Self.files.map { (name: $0, data: Array(try Data(contentsOf: URL(fileURLWithPath: "\(Self.folder)/\($0)")))) }
        var failures = 0
        func report(_ file: String, _ edit: String, _ run: () throws -> Bool?) {
            let outcome: String
            do {
                switch try run() {
                case true?: outcome = "PASS"
                case false?: outcome = "FAIL"
                    failures += 1
                case nil: outcome = "SKIP"
                }
            } catch {
                outcome = "FAIL (\(type(of: error)))"
                failures += 1
            }
            print("REAL \(file) \(edit) \(outcome)")
        }

        for (i, doc) in docs.enumerated() {
            let original = try pages(doc.data)
            let n = original.count
            print("REAL \(doc.name) pages \(n)")
            report(doc.name, "rotate") {
                try check(PageEditor.rotate(doc.data, nil, [0], 90), original, turned: [0])
            }
            let other = docs[(i + 1) % docs.count]
            let otherPages = try pages(other.data)
            // The comparison tells this file's first page from the next file's (so a wrong order would fail).
            report(doc.name, "control") { !same(original[0], otherPages[0]) }
            report(doc.name, "delete") {
                if n >= 2 { return try check(PageEditor.delete(doc.data, nil, [0]), Array(original.dropFirst())) }
                // A one-page file: its page deleted from it combined with the next file.
                let merged = try PageEditor.merge([PdfSource(doc.data, nil, doc.name), PdfSource(other.data, nil, other.name)], false)
                return try check(PageEditor.delete(merged, nil, [0]), otherPages)
            }
            report(doc.name, "extract") {
                let keep = Set([n - 1, 0]).sorted()
                return try check(PageEditor.extract(doc.data, nil, [n - 1, 0]), keep.map { original[$0] })
            }
            report(doc.name, "duplicate") {
                try check(PageEditor.duplicate(doc.data, nil, [0]), [original[0]] + original)
            }
            report(doc.name, "merge") {
                try check(PageEditor.merge([PdfSource(doc.data, nil, doc.name), PdfSource(other.data, nil, other.name)], true), original + otherPages)
            }
            report(doc.name, "insert") {
                let at = min(1, n)
                let expected = Array(original[..<at]) + otherPages + Array(original[at...])
                return try check(PageEditor.insert(doc.data, nil, PdfSource(other.data, nil, other.name), nil, at), expected)
            }
            report(doc.name, "bookmark") {
                let before = try Bookmarks.read(doc.data, nil)
                let added = try Bookmarks.setOutline(doc.data, nil, before + [Bookmark("Inkvolt test mark", n - 1)])
                var read = try Bookmarks.read(added, nil)
                guard read.count == before.count + 1, read.last?.title == "Inkvolt test mark", read.last?.pageIndex == n - 1 else { return false }
                read[read.count - 1].title = "Inkvolt renamed mark"
                let renamed = try Bookmarks.setOutline(added, nil, read)
                let after = try Bookmarks.read(renamed, nil)
                guard after.map(\.title) == before.map(\.title) + ["Inkvolt renamed mark"] else { return false }
                return try check(renamed, original)
            }
        }
        #expect(failures == 0)
    }
}
