import AppKit
import PdfCore

/// The self-test's scenario for E6 (`--edit`, on the synthetic text document; `--only-measure` runs it alone): the
/// measuring tools chosen from Tools › Measure and used through the page view's own mouse and key handling (clicks, the
/// pointer's moves, a double-click, Return, Delete, Esc), Set Measuring Scale and Calibrate through their sheets, a
/// measurement reshaped, undo, and the saved bytes read back by PdfCore and MuPDF. Only counts and values are written.
@MainActor
struct MeasureTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private var pages: PagesView { controller.pages }
    private var editor: DocumentEditor { controller.editor }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func mouse(_ type: NSEvent.EventType, _ p: PointD, page: Int = 0, clicks: Int = 1) -> NSEvent {
        let view = pages.viewPoint(p, pages.pageRects[page])
        return NSEvent.mouseEvent(with: type, location: pages.convert(view, to: nil), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    /// A click at `p` (page space), as the mouse makes it; waits for an edit it starts.
    private func click(_ p: PointD, page: Int = 0, clicks: Int = 1) async {
        pages.mouseDown(with: mouse(.leftMouseDown, p, page: page, clicks: clicks))
        pages.mouseUp(with: mouse(.leftMouseUp, p, page: page, clicks: clicks))
        await settle()
    }

    private func key(_ characters: String, code: UInt16) async {
        let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                 windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: characters,
                                 charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        pages.keyDown(with: e)
        await settle()
    }

    private func settle() async {
        await pages.pendingEdit?.value
        try? await Task.sleep(for: .milliseconds(30))
    }

    private func choose(_ tool: Tool) {
        let item = NSMenuItem()
        item.tag = tool.rawValue
        controller.chooseTool(item)
    }

    /// Waits until `count` edits have ended (a sheet's edit runs in a task of its own).
    private func waitEdits(_ count: Int) async -> Bool {
        let end = Date() + 10
        while editor.finishedEdits < count && Date() < end { try? await Task.sleep(for: .milliseconds(50)) }
        return editor.finishedEdits >= count
    }

    private func measurements(_ page: Int = 0) -> [MeasurementInfo] {
        guard let s = controller.pdf.session else { return [] }
        return (try? Measurements.read(s.data, s.password, page)) ?? []
    }

    /// Presses a scale sheet's first button after filling it in (the alert's own completion runs, as for a click).
    private func answer(_ fill: (ScaleSheet) -> Void) async -> Bool {
        for _ in 0..<40 where controller.measure.sheet == nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard let sheet = controller.measure.sheet, let window = controller.window else { return false }
        fill(sheet)
        let edits = editor.finishedEdits
        window.endSheet(sheet.alert.window, returnCode: .alertFirstButtonReturn)
        return await waitEdits(edits + 1)
    }

    mutating func run() async {
        guard controller.pdf.session != nil else {
            Report.write("== \(name): measure\nRESULT: FAIL (no session)")
            return
        }
        lines.append("== \(name): measure (\(controller.engine.pageCount) pages)")
        controller.closePopovers()
        controller.setZoom(1)
        controller.go(0)
        controller.window?.makeFirstResponder(pages)
        let before = measurements().count

        // Distance: two clicks, at real size.
        choose(.measureDistance)
        check(pages.tool == .measureDistance && pages.measureInProgress == nil, "Tools › Measure › Measure Distance picks the tool")
        await click(PointD(72, 500))
        let pending = pages.measureInProgress ?? ""
        await click(PointD(216, 500))
        var found = measurements()
        check(pending.hasPrefix("1 point(s)") && found.count == before + 1 && found.last?.text == "2.00 in" && found.last?.kind == .distance
              && editor.comments.contains { $0.subtype == "Line" && $0.contents == "2.00 in" },
              "two clicks measure a distance at real size: \(found.last?.text ?? "none")")

        // Area: three corners, the pointer's move shows the value so far, Return ends it.
        choose(.measureArea)
        for p in [PointD(300, 300), PointD(372, 300), PointD(372, 372)] { await click(p) }
        pages.mouseMoved(with: mouse(.mouseMoved, PointD(300, 372)))
        let live = pages.measureInProgress ?? ""
        let shown = pages.measuring?.hover == PointD(300, 372)
        await key("\r", code: 36)
        found = measurements()
        check(live.hasPrefix("3 point(s)") && shown && found.last?.kind == .area && found.last?.text == "0.50 sq in",
              "corners, the pointer's move and Return measure an area: \(found.last?.text ?? "none")")

        // Perimeter: a double-click ends it.
        choose(.measurePerimeter)
        await click(PointD(72, 600))
        await click(PointD(144, 600))
        await click(PointD(144, 672))
        await click(PointD(144, 672), clicks: 2)
        found = measurements()
        check(found.last?.kind == .perimeter && found.last?.text == "2.00 in" && found.last?.points.count == 3,
              "a double-click ends a perimeter: \(found.last?.text ?? "none")")

        // Delete takes a corner back, Esc drops what is under way; nothing is saved.
        let count = measurements().count
        choose(.measureArea)
        await click(PointD(100, 100))
        await click(PointD(150, 100))
        await key("\u{7f}", code: 51)
        let afterDelete = pages.measureInProgress ?? ""
        await key("\u{1b}", code: 53)
        check(afterDelete.hasPrefix("1 point(s)") && pages.measureInProgress == nil && measurements().count == count && pages.tool == .measureArea,
              "Delete takes a corner back, Esc drops it (the tool stays)")

        // Set Measuring Scale through its sheet, for all pages.
        controller.setMeasuringScale(nil)
        let set = await answer { s in
            s.pageValue.stringValue = "1"
            s.pageUnit.selectItem(withTitle: "in")
            s.realValue.stringValue = "10"
            s.realUnit.selectItem(withTitle: "ft")
            s.pages.selectItem(at: 1)
        }
        let pageCount = controller.engine.pageCount
        let ratios = (0..<pageCount).map { controller.scaleAt($0, PointD(1, 1)).ratio }
        check(set && ratios.allSatisfy { $0 == "1 in = 10 ft" }, "Set Measuring Scale… for all pages: \(Set(ratios).sorted())")
        // Measurements already made keep theirs; a new one uses the new scale.
        choose(.measureDistance)
        await click(PointD(72, 450))
        await click(PointD(216, 450))
        found = measurements()
        check(found.first?.text == "2.00 in" && found.last?.text == "20.00 ft", "the next distance is at the new scale: \(found.last?.text ?? "none")")

        // Reshaped, it is measured again.
        if let id = found.last?.id {
            await editor.setGeometry(id, AnnotGeometry(paths: [[PointD(72, 450), PointD(288, 450)]]), label: "Reshape")
            check(measurements().last?.text == "30.00 ft" && editor.comment(id)?.contents == "30.00 ft", "reshaped, the value follows: 30.00 ft")
        } else {
            check(false, "reshaped, the value follows: no id")
        }

        // Calibrate: a line of known length sets this page's scale; undo takes it back.
        choose(.measureCalibrate)
        await click(PointD(100, 200))
        await click(PointD(244, 200))
        let calibrated = await answer { s in
            s.realValue.stringValue = "25"
            s.realUnit.selectItem(withTitle: "ft")
            s.pages.selectItem(at: 0)
        }
        let here = controller.scaleAt(0, PointD(1, 1)).ratio
        let other = pageCount > 1 ? controller.scaleAt(1, PointD(1, 1)).ratio : "1 in = 10 ft"
        check(calibrated && here == "1 in = 12.5 ft" && other == "1 in = 10 ft", "Calibrate from a 2 in line of 25 ft: \(here) here, \(other) elsewhere")
        let undo = controller.window?.undoManager
        let title = undo?.undoMenuItemTitle ?? ""
        undo?.undo()
        check(controller.scaleAt(0, PointD(1, 1)).ratio == "1 in = 10 ft" && title == "Undo Set measuring scale", "“\(title)” takes it back")

        // The saved bytes: the values are drawn into the page, and the scale is a viewport another app reads.
        if let s = controller.pdf.session, let engine = try? PdfEngine.open(s.data) {
            let text = ((try? engine.textLines(0, annotations: true)) ?? []).map(\.text).joined(separator: "\n")
            engine.close()
            let viewport = (try? Measurements.pageScale(s.data, s.password, 0, PointD(300, 300)))?.ratio
            check(text.contains("30.00 ft") && text.contains("0.50 sq in") && viewport == "1 in = 10 ft",
                  "the labels are on the page and the scale is a viewport (\(viewport ?? "none"))")
        } else {
            check(false, "the saved bytes open")
        }
        lines.append("note: \(controller.measurementsReport())")
        choose(.text)
        finish()
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
