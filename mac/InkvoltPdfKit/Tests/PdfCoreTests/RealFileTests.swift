import Foundation
import PDFKit
import Testing
@testable import PdfCore

/// Not a port: the page edits (D3), the comments, drawings, stamps and images (D4), and form filling and Fill & Sign (D5)
/// run on real documents, copied by
/// hand into /tmp/inkvolt-d3-real (skipped when the folder isn't there; real files never go into the repo). Each result
/// must open in PdfEngine and in Apple's PDFKit with the expected page count; page edits must leave the expected source
/// pages in the expected order (compared as small renders); annotations must be read back and the page must render in
/// both. Prints one "REAL file<n> <edit> PASS|FAIL|SKIP" line per check (files are numbered, never named) and nothing
/// from the documents themselves.
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
            let label = "file\(i + 1)"
            print("REAL \(label) pages \(n)")
            report(label, "rotate") {
                try check(PageEditor.rotate(doc.data, nil, [0], 90), original, turned: [0])
            }
            let other = docs[(i + 1) % docs.count]
            let otherPages = try pages(other.data)
            // The comparison tells this file's first page from the next file's (so a wrong order would fail).
            report(label, "control") { !same(original[0], otherPages[0]) }
            report(label, "delete") {
                if n >= 2 { return try check(PageEditor.delete(doc.data, nil, [0]), Array(original.dropFirst())) }
                // A one-page file: its page deleted from it combined with the next file.
                let merged = try PageEditor.merge([PdfSource(doc.data, nil, doc.name), PdfSource(other.data, nil, other.name)], false)
                return try check(PageEditor.delete(merged, nil, [0]), otherPages)
            }
            report(label, "extract") {
                let keep = Set([n - 1, 0]).sorted()
                return try check(PageEditor.extract(doc.data, nil, [n - 1, 0]), keep.map { original[$0] })
            }
            report(label, "duplicate") {
                try check(PageEditor.duplicate(doc.data, nil, [0]), [original[0]] + original)
            }
            report(label, "merge") {
                try check(PageEditor.merge([PdfSource(doc.data, nil, doc.name), PdfSource(other.data, nil, other.name)], true), original + otherPages)
            }
            report(label, "insert") {
                let at = min(1, n)
                let expected = Array(original[..<at]) + otherPages + Array(original[at...])
                return try check(PageEditor.insert(doc.data, nil, PdfSource(other.data, nil, other.name), nil, at), expected)
            }
            report(label, "bookmark") {
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

    /// The page opens in both readers with the page count it had, renders in both, and PDFKit sees at least `annots`
    /// annotations on it.
    private func opensAndRenders(_ result: [UInt8], pages: Int, annots: Int) throws -> Bool {
        let e = try PdfEngine.open(result)
        defer { e.close() }
        guard e.pageCount == pages else { return false }
        let img = try e.render(0, scale: 0.5)
        guard img.width > 0, img.pixels.count == img.width * img.height * 3 else { return false }
        guard let kit = PDFDocument(data: Data(result)), kit.pageCount == pages, let page = kit.page(at: 0) else { return false }
        let thumb = page.thumbnail(of: NSSize(width: 120, height: 120), for: .mediaBox)
        return thumb.size.width > 0 && page.annotations.count >= annots
    }

    @Test(.enabled(if: !files.isEmpty)) func annotationsOnRealFiles() throws {
        var failures = 0
        for (k, name) in Self.files.enumerated() {
            let label = "file\(k + 1)"
            var data = Array(try Data(contentsOf: URL(fileURLWithPath: "\(Self.folder)/\(name)")))
            let engine = try PdfEngine.open(data)
            let n = engine.pageCount
            let g = engine.page(0)
            let text = try engine.text(0)
            engine.close()
            let (w, h) = (g.width, g.height)
            var added = 0

            /// Runs one edit on the running document; `found` reads the result back.
            func step(_ edit: String, _ run: ([UInt8]) throws -> [UInt8]?, _ found: ([UInt8]) throws -> Bool) {
                let outcome: String
                do {
                    if let result = try run(data) {
                        added += 1
                        if try found(result), try opensAndRenders(result, pages: n, annots: added) {
                            data = result
                            outcome = "PASS"
                        } else {
                            outcome = "FAIL"
                            failures += 1
                        }
                    } else {
                        outcome = "SKIP"
                    }
                } catch {
                    outcome = "FAIL (\(type(of: error)))"
                    failures += 1
                }
                print("REAL \(label) \(edit) \(outcome)")
            }
            func has(_ result: [UInt8], _ id: String, _ kind: AnnotationKind) throws -> Bool {
                try Annotations.read(result, nil).contains { $0.id == id && $0.kind == kind && $0.pageIndex == 0 }
            }

            let ids = (0..<6).map { _ in Annotations.newId() }
            step("highlight", { d in
                // The first word of three letters or more on the first page (a page without text skips).
                guard let word = text.text.split(whereSeparator: { !$0.isLetter }).first(where: { $0.count >= 3 }),
                      let hit = text.find(String(word), matchCase: true, wholeWord: false).first else { return nil }
                return try Annotations.addTextMarkup(d, nil, 0, .highlight, text.rects(hit.start, hit.end), .yellow, note: "Inkvolt check",
                                                     author: "Inkvolt", id: ids[0])
            }, { try has($0, ids[0], .highlight) })
            step("note", { try Annotations.addNote($0, nil, 0, w * 0.8, h * 0.05, "Inkvolt note", author: "Inkvolt", id: ids[1]) },
                 { try has($0, ids[1], .text) })
            step("freetext", { try Annotations.addFreeText($0, nil, 0, RectD(w * 0.1, h * 0.1, w * 0.4, 40), "Inkvolt free text Ελληνικά",
                                                          .textBox(), author: "Inkvolt", id: ids[2]) },
                 { try has($0, ids[2], .freeText) && Core2Pdf.allText($0).contains("Ελληνικά") })
            step("ink", { try Annotations.addInk($0, nil, 0, [[PointD(w * 0.1, h * 0.3), PointD(w * 0.3, h * 0.35), PointD(w * 0.5, h * 0.3)]],
                                                .pen(AnnotColor(0.1, 0.2, 0.9), width: 3), author: "Inkvolt", id: ids[3]) },
                 { try has($0, ids[3], .ink) })
            step("rectangle", { try Annotations.addShape($0, nil, 0, .rectangle, RectD(w * 0.6, h * 0.3, w * 0.2, h * 0.1), .pen(.red),
                                                        author: "Inkvolt", id: ids[4]) },
                 { try has($0, ids[4], .square) })
            step("arrow", { try Annotations.addLine($0, nil, 0, PointD(w * 0.1, h * 0.5), PointD(w * 0.4, h * 0.55), .arrow(.red),
                                                    author: "Inkvolt", id: ids[5]) },
                 { try has($0, ids[5], .line) })
            step("rubberstamp", { d in
                let design = RubberStamps.builtIn[0]
                let size = RubberStamps.naturalSize(design)
                return try RubberStamps.put(d, nil, 0, RectD(w * 0.5, h * 0.6, size.width, size.height), design, author: "Inkvolt")
            }, { try SignatureStamps.read($0, nil).contains { $0.kind == .stamp && $0.pageIndex == 0 } && Core2Pdf.allText($0).contains("APPROVED") })
            step("textstamp", { try TextStamps.put($0, nil, 0, RectD(w * 0.1, h * 0.7, w * 0.5, 20), .text, "Inkvolt שלום stamp", 12) },
                 { try TextStamps.read($0, nil).contains { $0.text == "Inkvolt שלום stamp" } && Core2Pdf.allText($0).contains("שלום") })
            step("image", { d in
                let img = StampImage(20, 20, Array([[UInt8]](repeating: [20, 40, 200], count: 400).joined()), nil)
                return try SignatureStamps.putImage(d, nil, 0, RectD(w * 0.7, h * 0.75, 60, 60), img, label: "Inkvolt image")
            }, { try SignatureStamps.read($0, nil).contains { $0.kind == .image && $0.pageIndex == 0 } })
        }
        #expect(failures == 0)
    }

    /// PDFKit's annotations on page 1.
    private func kitAnnotations(_ data: [UInt8]) -> Int { PDFDocument(data: Data(data))?.page(at: 0)?.annotations.count ?? -1 }

    @Test(.enabled(if: !files.isEmpty)) func formsAndFillAndSignOnRealFiles() throws {
        var failures = 0
        func report(_ file: String, _ check: String, _ run: () throws -> Bool?) {
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
            print("REAL \(file) \(check) \(outcome)")
        }

        for (k, name) in Self.files.enumerated() {
            let label = "file\(k + 1)"
            let data = Array(try Data(contentsOf: URL(fileURLWithPath: "\(Self.folder)/\(name)")))
            let engine = try PdfEngine.open(data)
            let n = engine.pageCount
            let g = engine.page(0)
            engine.close()
            let widgets = (try? FormEditor.read(data, nil)) ?? []
            let texts = widgets.filter { $0.kind == .text && !$0.readOnly }
            let boxes = widgets.filter { $0.kind == .checkBox && !$0.readOnly }
            print("REAL \(label) widgets \(widgets.count) fields \(Set(widgets.map(\.fieldName)).count) text \(Set(texts.map(\.fieldName)).count) checkboxes \(Set(boxes.map(\.fieldName)).count)")

            report(label, "fill") {
                if texts.isEmpty && boxes.isEmpty { return nil }
                var values: [String: String] = [:]
                for (i, w) in texts.enumerated() where values[w.fieldName] == nil {
                    let v = "Inkvolt \(i + 1)"
                    values[w.fieldName] = w.maxLength > 0 ? String(v.prefix(w.maxLength)) : v
                }
                let box = boxes.first
                if let box { values[box.fieldName] = box.value == "Off" ? box.onState ?? "Yes" : "Off" }
                let r = try FormEditor.fill(data, nil, values)
                let back = try FormEditor.read(r.data, nil)
                let rejected = Set(r.rejected.map(\.fieldName))
                var ok = 0
                for (field, v) in values where !rejected.contains(field) && field != box?.fieldName {
                    if back.first(where: { $0.fieldName == field })?.value == v { ok += 1 }
                }
                let expectedText = values.count - (box == nil ? 0 : 1) - rejected.subtracting([box?.fieldName ?? ""]).count
                var toggled = true
                if let box, !rejected.contains(box.fieldName) {
                    toggled = back.first { $0.fieldName == box.fieldName }?.value != box.value
                }
                print("REAL \(label) filled \(ok) of \(values.count - (box == nil ? 0 : 1)) text, \(rejected.count) refused by the form's scripts, checkbox toggled \(box == nil ? "-" : String(toggled))")
                let opens = try opensAndRenders(r.data, pages: n, annots: 0)
                return ok == expectedText && toggled && opens
            }

            report(label, "fill&sign") {
                let before = kitAnnotations(data)
                var d = try TextStamps.put(data, nil, 0, RectD(g.width * 0.1, g.height * 0.85, g.width * 0.5, 18), .text, "Inkvolt Fill and Sign", 12)
                d = try TextStamps.put(d, nil, 0, RectD(g.width * 0.65, g.height * 0.85, 14, 14), .check, "", 12)
                // A drawn signature: a dark stroke on a transparent 120 x 40 image.
                let (iw, ih) = (120, 40)
                var rgb: [UInt8] = []
                var alpha: [UInt8] = []
                for y in 0..<ih {
                    for x in 0..<iw {
                        let curve = Int(20 + 12 * sin(Double(x) / 10))
                        rgb += [10, 20, 90]
                        alpha.append(abs(y - curve) <= 1 ? 255 : 0)
                    }
                }
                d = try SignatureStamps.put(d, nil, 0, RectD(g.width * 0.1, g.height * 0.9, 120, 40), StampImage(iw, ih, rgb, alpha))
                let stamps = try TextStamps.read(d, nil).filter { $0.pageIndex == 0 }
                let signatures = try SignatureStamps.read(d, nil).filter { $0.pageIndex == 0 && $0.kind == .signature }
                let drawn = try Core2Pdf.allText(d).contains("Inkvolt Fill and Sign")
                let found = stamps.contains { $0.kind == .text && $0.text == "Inkvolt Fill and Sign" } && stamps.contains { $0.kind == .check }
                    && !signatures.isEmpty && drawn
                let opens = try opensAndRenders(d, pages: n, annots: max(0, before) + 3)
                return found && opens
            }
        }
        #expect(failures == 0)
    }
}
