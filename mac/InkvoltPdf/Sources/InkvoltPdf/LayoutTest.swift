import AppKit
import PdfCore
import PrintCore

/// The self-test's scenario for roadmap 4.19 (`--edit --only-layout`, on the synthetic text document): View › Rulers, a
/// guide dropped from a ruler, a rectangle and a Prepare Form field snapping to it (and not with Snap to Guides off), Grid
/// Spacing… and Ruler Units, guides following their pages through a page turned, and Clear Guides. Everything it did is
/// undone at the end; settings are the self-test's own suite.
@MainActor
struct LayoutTest {
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

    /// A menu command as a person chooses it: run only when the command table says it can.
    private func choose(_ action: Selector) -> Bool {
        guard let command = DocumentCommands.command(action: NSStringFromSelector(action)),
              command.isEnabled(in: controller.commandState(for: command)) else { return false }
        NSApp.sendAction(action, to: controller, from: nil)
        return true
    }

    private func mouse(_ type: NSEvent.EventType, _ p: PointD) -> NSEvent {
        let view = pages.viewPoint(p, pages.pageRects[0])
        return NSEvent.mouseEvent(with: type, location: pages.convert(view, to: nil), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func drag(_ a: PointD, _ b: PointD) async {
        pages.mouseDown(with: mouse(.leftMouseDown, a))
        pages.mouseDragged(with: mouse(.leftMouseDragged, PointD((a.x + b.x) / 2, (a.y + b.y) / 2)))
        pages.mouseDragged(with: mouse(.leftMouseDragged, b))
        pages.mouseUp(with: mouse(.leftMouseUp, b))
        await settle()
    }

    private func settle(_ ms: Int = 300) async {
        await pages.pendingEdit?.value
        await controller.design.settle()
        try? await Task.sleep(for: .milliseconds(ms))
    }

    private func shapes() -> [AnnotationInfo] { editor.comments.filter { $0.subtype == "Square" } }

    mutating func run() async {
        lines.append("== \(name): rulers, guides, grid and snapping")
        guard let session = controller.pdf.session else { return finish() }
        let start = session.data

        check(choose(#selector(DocumentWindowController.toggleRulers(_:))) && controller.scrollView.rulersVisible
                && controller.scrollView.horizontalRulerView is PageRuler, "View › Rulers shows the rulers")
        check(pages.testAddGuide(0, top: false, 100) && session.guides.on(0) == [Guide(0, .x, 100)],
              "a guide dragged from the left ruler lands as a line down the page")

        // A rectangle drawn from beside the guide starts on it.
        pages.tool = .rectangle
        let before = shapes().count
        await drag(PointD(103, 400), PointD(200, 450))
        let shape = shapes().last
        check(shapes().count == before + 1 && abs((shape?.rect.x ?? 0) - 100) < 1.5, "a rectangle's corner snaps to the guide: x \(shape.map { String($0.rect.x) } ?? "none")")

        // Prepare Form: a text field drawn from beside the guide.
        controller.togglePrepareForm(nil)
        for _ in 0..<200 where !controller.design.isDesigning { try? await Task.sleep(for: .milliseconds(10)) }
        await settle()
        controller.design.toolControl.selectedSegment = 1
        controller.design.toolControl.sendAction(controller.design.toolControl.action, to: controller.design.toolControl.target)
        await drag(PointD(98, 500), PointD(260, 522))
        let field = controller.design.model.selectedField
        check(field.map { abs($0.rect.x - 100) < 0.01 } == true, "a new field's corner snaps to the guide in Prepare Form: x \(field.map { String($0.rect.x) } ?? "none")")
        controller.startPrepareForm(false)
        for _ in 0..<200 where controller.design.isDesigning { try? await Task.sleep(for: .milliseconds(10)) }

        // Snap to Guides off (and to objects: the first rectangle's edge is there too): where the pointer is.
        _ = choose(#selector(DocumentWindowController.toggleSnapToGuides(_:)))
        _ = choose(#selector(DocumentWindowController.toggleSnapToObjects(_:)))
        pages.tool = .rectangle
        await drag(PointD(103, 600), PointD(200, 650))
        check(!AppSettings.snapToGuides && abs((shapes().last?.rect.x ?? 0) - 103) < 1.5, "with Snap to Guides off, no snapping")
        _ = choose(#selector(DocumentWindowController.toggleSnapToGuides(_:)))
        _ = choose(#selector(DocumentWindowController.toggleSnapToObjects(_:)))
        pages.tool = .text

        // Grid Spacing… (1 inch) shows the grid; Ruler Units goes on to inches.
        DocumentWindowController.testGridStep = 2
        _ = choose(#selector(DocumentWindowController.chooseGridSpacing(_:)))
        check(AppSettings.gridStep == 72 && AppSettings.showGrid, "Grid Spacing… sets a line every inch and shows the grid")
        _ = choose(#selector(DocumentWindowController.nextRulerUnit(_:)))
        check(AppSettings.rulerUnit == "in" && pages.rulerUnit(0) == .inches, "Ruler Units goes on to inches")

        // A page turned takes its guides with it; another page's stay.
        if controller.engine.pageCount > 1 {
            let size = controller.engine.page(1)
            session.guides.add(Guide(1, .y, 300), size.width, size.height)
            controller.guidesChanged()
            for _ in 0..<200 where controller.guideKeys == nil { try? await Task.sleep(for: .milliseconds(10)) }
            _ = await editor.run(loc("Rotate Right")) { d, pw in try PageEditor.rotate(d, pw, [0], 90) }
            for _ in 0..<200 where session.guides.on(0).count > 0 { try? await Task.sleep(for: .milliseconds(10)) }
            check(session.guides.on(0).isEmpty && session.guides.on(1) == [Guide(1, .y, 300)],
                  "a turned page's guides go; the next page's stay: \(session.guides.all.count) left")
        } else {
            lines.append("SKIP guides following pages: one page")
        }

        check(choose(#selector(DocumentWindowController.clearGuides(_:))) && session.guides.all.isEmpty
                && !choose(#selector(DocumentWindowController.clearGuides(_:))), "Clear Guides takes them all, then is off")
        _ = choose(#selector(DocumentWindowController.toggleRulers(_:)))
        _ = choose(#selector(DocumentWindowController.toggleGrid(_:)))
        check(!controller.scrollView.rulersVisible && !AppSettings.showGrid, "the rulers and the grid hide again")

        var steps = 0
        while controller.pdf.session?.data != start && steps < 50 {
            controller.pdf.undo()
            steps += 1
        }
        await settle()
        check(controller.pdf.session?.data == start, "\(steps) undo steps bring the document back")
        finish()
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
