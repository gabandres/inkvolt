import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for E3 (`--edit`, after `SignTest`, once): two versions of a small contract made here (a
/// changed amount, a drawing that moved, an inserted page) compared in the Compare window: the summary and the list,
/// the pages drawn, stepping through the changes, Visual with its regions, zoom (+, −, Fit), the Annotated Copy opened as a new document
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
        check(c.items.contains { $0.kind == loc("Changed", context: "a change") && $0.text == "100 → 150" } && c.visuallyDifferent.count == 1,
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
        // Zoom: + from Fit (the first row's scale × 1.25), the rows wider than the window; − back; Fit (⌘0) fits again.
        let viewWidth = Double(c.rowsView.enclosingScrollView?.contentView.bounds.width ?? 900)
        let fitScale = c.rowsView.scale(at: 0)
        c.zoomIn.performClick(nil)
        let zoomed = abs(c.rowsView.zoom - fitScale * 1.25) < 0.001 && c.zoomFit.title.hasSuffix("%")
        c.setZoom(2)
        let wide = Double(c.rowsView.frame.width) > viewWidth + 1 && abs(c.rowsView.scale(at: 0) - 2) < 0.001
        c.zoomOut.performClick(nil)
        let out = abs(c.rowsView.zoom - 1.6) < 0.001
        c.zoomFit.performClick(nil)
        let fits = c.rowsView.zoom == 0 && abs(Double(c.rowsView.frame.width) - viewWidth) < 1 && c.zoomFit.title == loc("Fit")
        check(zoomed && wide && out && fits && c.zoomIn.keyEquivalent == "=" && c.zoomFit.keyEquivalent == "0",
              "zoom: + from Fit (×1.25), 200 % wider than the window, − (160 %), Fit (⌘0) back to the window's width")
        let copy = c.makeAnnotatedCopy()
        let notes = (copy?.session?.data).flatMap { try? Annotations.read($0, nil) } ?? []
        let had = Shown.tail(loc("Changed. {0} has: “{1}”", Shown.gap, "100"))
        check(notes.contains { $0.kind == .highlight && $0.contents.contains(had) } && notes.contains { $0.kind == .text },
              "Annotated Copy: a new document with the change highlighted and the summary note (\(notes.count) comments)")
        copy?.close()
        c.close()
        await formatting()
        await scanned()
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }

    /// One page whose lines are runs of Helvetica (`false`) and Helvetica-Bold (`true`).
    static func styledPdf(_ lines: [[(String, Bool)]]) -> [UInt8] {
        var content = ""
        for (i, runs) in lines.enumerated() {
            content += "BT 72 \(720 - i * 24) Td"
            for (text, bold) in runs { content += " /F\(bold ? 2 : 1) 14 Tf (\(text)) Tj" }
            content += " ET\n"
        }
        let font = "<< /Type /Font /Subtype /Type1 /BaseFont /%@ /Encoding /WinAnsiEncoding >>"
        let objects = ["<< /Type /Catalog /Pages 2 0 R >>", "<< /Type /Pages /Kids [5 0 R] /Count 1 >>",
                       String(format: font, "Helvetica"), String(format: font, "Helvetica-Bold"),
                       "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 3 0 R /F2 4 0 R >> >> /Contents 6 0 R >>",
                       "<< /Length \(content.utf8.count) >>\nstream\n\(content)\nendstream"]
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

    /// Roadmap 3.3: a word set in bold and an amount changed: the formatting change listed apart from the wording, each
    /// kind's box hiding it, and the annotated copy saying what changed in the look.
    private mutating func formatting() async {
        lines.append("== Compare: formatting apart from wording")
        let old = Self.styledPdf([[("Service agreement", false)], [("The fee is 100 dollars per month.", false)]])
        let new = Self.styledPdf([[("Service agreement", false)], [("The ", false), ("fee", true), (" is 150 dollars per month.", false)]])
        let c = CompareWindowController.show(old: CompareSide(name: "plain.pdf", data: old, password: nil),
                                             new: CompareSide(name: "bold.pdf", data: new, password: nil))
        await c.finished()
        let r = c.result
        let bold = c.items.first { $0.kind == loc("Formatting") }
        check(r?.formatted == 1 && r?.changed == 1 && bold?.text == loc("bold added") + ": fee",
              "a word set in bold is one formatting change, apart from the changed amount: \(c.summary.stringValue)")
        let all = c.items.count
        let boxes = c.groupBoxes[.formatting].map { !$0.isHidden } == true && c.groupBoxes[.wording].map { !$0.isHidden } == true
        c.showGroup(.formatting, false)
        let hidden = c.items.count == all - 1 && !c.items.contains { $0.kind == loc("Formatting") } && c.rowsView.hiddenKinds.contains(.formatted)
        c.showGroup(.formatting, true)
        check(boxes && hidden && c.items.count == all, "the kinds' boxes: Formatting off hides its entry and its marks, on shows them again")
        let copy = c.makeAnnotatedCopy()
        let notes = (copy?.session?.data).flatMap { try? Annotations.read($0, nil) } ?? []
        check(notes.contains { $0.kind == .highlight && $0.contents == loc("Formatting: {0}", loc("bold added")) },
              "Annotated Copy: the bold word highlighted with what changed (\(notes.count) comments)")
        copy?.close()
        c.close()
    }

    /// A PDF whose one page is a picture (200 dpi) of `pdf`'s first page, as a scanner makes one.
    static func scanOf(_ pdf: [UInt8]) -> [UInt8]? {
        guard let engine = try? PdfEngine.open(pdf) else { return nil }
        defer { engine.close() }
        let g = engine.page(0)
        guard let image = try? engine.render(0, scale: 200.0 / 72), let cg = PageRenderer.cgImage(image) else { return nil }
        let rep = NSBitmapImageRep(cgImage: cg)
        rep.size = NSSize(width: g.width, height: g.height) // 200 dpi in the PNG
        guard let png = rep.representation(using: .png, properties: [:]) else { return nil }
        return try? ImageImport.imagesToPdf([(bytes: Array(png), name: "scan.png")])
    }

    /// Roadmap 3.3: the changed version a scan (a picture of the page, no text): its words recognized with Vision first,
    /// the changed amount listed as read from the scan, and no formatting said about it.
    private mutating func scanned() async {
        lines.append("== Compare: a scanned page")
        let old = Self.styledPdf([[("Scope of work", false)], [("The supplier delivers 12 monthly reports.", false)]])
        guard let new = Self.scanOf(Self.styledPdf([[("Scope of work", false)], [("The supplier delivers 15 monthly reports.", false)]])) else {
            return check(false, "the scan couldn't be made")
        }
        let c = CompareWindowController.show(old: CompareSide(name: "typed.pdf", data: old, password: nil),
                                             new: CompareSide(name: "scan.pdf", data: new, password: nil))
        await c.finished()
        let r = c.result
        let amount = r?.changes.first { $0.kind == .changed && $0.oldText == "12" }
        check(c.scanNote == loc("The words on scanned pages were recognized, so some differences may be misreadings."),
              "the scan's words were recognized: \(c.scanNote ?? "no note")")
        check(amount?.newText == "15" && amount?.readFromScan == true && r?.formatted == 0 && r?.pairsWithoutText == 0,
              "the changed amount on the scan is listed as read from it, no formatting said: \(c.summary.stringValue)")
        c.close()
    }
}
