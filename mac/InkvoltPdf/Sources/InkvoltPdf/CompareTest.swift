import AppKit
import PdfCore

/// The self-test's scenario for E3 (`--edit`, after `SignTest`, once): two versions of a small contract made here (a
/// changed amount, a drawing that moved, an inserted page) compared in the Compare window: the summary and the list,
/// the pages drawn, stepping through the changes, Visual with its regions, the Annotated Copy opened as a new document
/// with the changes as comments. Only counts are written.
@MainActor
struct CompareTest {
    /// Running: the annotated copy it opens gets no self-test of its own.
    private(set) static var isActive = false
    private var lines: [String] = []
    private var failures = 0

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[compare] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    /// A PDF whose pages show the given lines in Helvetica, or (an empty list) a drawing: a box, at `box` from the left.
    static func pdf(_ pages: [[String]], box: Double) -> [UInt8] {
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", "", "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>"]
        var kids: [String] = []
        for lines in pages {
            var content = ""
            if lines.isEmpty {
                content = "3 w 0 G 72 300 468 300 re S \(box) 380 120 90 re S\n"
            } else {
                for (i, l) in lines.enumerated() { content += "BT /F1 14 Tf 72 \(720 - i * 24) Td (\(l)) Tj ET\n" }
            }
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R >> >> /Contents \(objects.count + 2) 0 R >>")
            kids.append("\(objects.count) 0 R")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream")
        }
        objects[1] = "<< /Type /Pages /Kids [\(kids.joined(separator: " "))] /Count \(pages.count) >>"
        var out = Array("%PDF-1.7\n".utf8)
        var offsets: [Int] = []
        for (i, o) in objects.enumerated() {
            offsets.append(out.count)
            out += Array("\(i + 1) 0 obj\n\(o)\nendobj\n".utf8)
        }
        let xref = out.count
        var table = "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for o in offsets { table += String(format: "%010d 00000 n \n", o) }
        table += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        return out + Array(table.utf8)
    }

    private func wait(_ seconds: Double = 10, _ done: () -> Bool) async -> Bool {
        let end = Date() + seconds
        while !done() && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        return done()
    }

    mutating func run() async {
        Self.isActive = true
        defer { Self.isActive = false }
        lines.append("== Compare Files (two versions made here)")
        let old = Self.pdf([["Service agreement", "The fee is 100 dollars per month."], ["Scope of work"], []], box: 330)
        let new = Self.pdf([["Service agreement", "The fee is 150 dollars per month."], ["Scope of work"], [], ["Appendix B"]], box: 360)
        let c = CompareWindowController.show(old: CompareSide(name: "old.pdf", data: old, password: nil),
                                             new: CompareSide(name: "new.pdf", data: new, password: nil))
        await c.finished()
        let r = c.result
        check(r?.changed == 1 && r?.pagesInserted == 1 && r?.rows.count == 4, "compared: \(c.summary.stringValue)")
        check(c.items.contains { $0.kind == "Changed" && $0.text == "100 → 150" } && c.visuallyDifferent.count == 1,
              "the list: the changed amount, the inserted page, the drawing that looks different (\(c.items.count) items)")
        c.window?.layoutIfNeeded()
        c.rowsView.layoutRows(width: Double(c.rowsView.enclosingScrollView?.contentView.bounds.width ?? 900))
        c.rowsView.display()
        c.step(1)
        check(c.selected == 0 && c.rowsView.selected != nil, "Next selects the first change")
        c.step(-1)
        check(c.selected == c.items.count - 1, "Previous from the first goes round to the last")
        c.setVisual(true)
        c.rowsView.want(rows: [0, 2])
        let first = await wait { c.rowsView.overlayRegions[0]?.isEmpty == false }
        let drawing = await wait(20) { c.rowsView.overlayRegions[2]?.isEmpty == false }
        check(first, "Visual: the changed amount is boxed on page 1 (\(c.rowsView.overlayRegions[0]?.count ?? -1) regions)")
        check(drawing, "Visual: the drawing's moved box is boxed (\(c.rowsView.overlayRegions[2]?.count ?? -1) regions)")
        c.setVisual(false)
        let copy = c.makeAnnotatedCopy()
        let notes = (copy?.session?.data).flatMap { try? Annotations.read($0, nil) } ?? []
        check(notes.contains { $0.kind == .highlight && $0.contents.contains("“100”") } && notes.contains { $0.kind == .text },
              "Annotated Copy: a new document with the change highlighted and the summary note (\(notes.count) comments)")
        copy?.close()
        c.close()
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
