import AppKit
import PdfCore

/// The self-test's scenario for roadmap 1.3 (`--edit`, on the synthetic text document; `--only-accessibility` runs it
/// alone): Tools › Accessibility Check… from its menu item, the sidebar's pane through its own controls, a finding chosen
/// and outlined on its page, a tick on the checklist, the report saved and read back with that tick, Check Again keeping
/// it, and Batch offering the action. Only counts and condition numbers are written.
@MainActor
struct AccessibilityTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private var pane: AccessibilityPane { controller.sidebar.accessibility }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func snapshot(_ file: String) {
        guard let dir = Report.snapshots, let view = controller.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        controller.pages.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
    }

    private func menuItem(_ title: String) -> NSMenuItem? {
        func find(_ menu: NSMenu?) -> NSMenuItem? {
            for item in menu?.items ?? [] {
                if item.title == title { return item }
                if let hit = find(item.submenu) { return hit }
            }
            return nil
        }
        return find(NSApp.mainMenu)
    }

    /// Waits for the check to end (the long task the command starts).
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
        for _ in 0..<2400 where controller.longTask != nil { try? await Task.sleep(for: .milliseconds(25)) }
        try? await Task.sleep(for: .milliseconds(30))
    }

    mutating func run() async {
        lines.append("== accessibility check")
        let item = menuItem("Accessibility Check…")
        check(item?.action == #selector(DocumentWindowController.checkAccessibility(_:)), "Tools has Accessibility Check…")
        check(item.map { controller.validateMenuItem($0) } == true, "the command is enabled on a document")
        check(controller.sidebar.segmentCount == 4, "the sidebar has no Accessibility segment before the first check")

        NSApp.sendAction(#selector(DocumentWindowController.checkAccessibility(_:)), to: controller, from: nil)
        await settle()
        guard let report = pane.report else {
            check(false, "the check ran")
            return finish()
        }
        check(controller.sidebar.segmentCount == 5 && controller.sidebar.shownSegment == 4, "the check opens the pane in its own sidebar segment")
        check(!report.passed && report.failedConditions.contains("UA 7.1"), "the untagged synthetic document fails: \(report.failedConditions.joined(separator: " "))")
        check(pane.summary.hasPrefix("Fails ") && pane.failuresTitle == "Fails (\(report.failures.count))", "the pane says what fails (\(pane.failuresTitle))")
        check(pane.shownFailures == report.failures.count && !pane.showsChecklist, "the list has a row per failure")
        snapshot("accessibility-fails.png")

        // Choosing a failure with a place goes there and outlines it.
        if let row = report.failures.firstIndex(where: { $0.page >= 0 && !$0.box.isEmpty }) {
            let f = report.failures[row]
            pane.choose(row: row)
            check(controller.pages.flashed?.page == f.page && controller.pages.flashed?.box == f.box, "choosing \(f.condition) outlines it on page \(f.page + 1)")
            controller.pages.displayIfNeeded()
            snapshot("accessibility-chosen.png")
        } else {
            check(false, "a failure has a place")
        }

        // The checklist: a tick goes into the saved report and outlasts another check.
        pane.showTab(1)
        check(pane.showsChecklist, "Checklist shows the person's checks")
        pane.tick("title")
        check(pane.done == ["title"], "a tick is kept")
        snapshot("accessibility-checklist.png")
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkvolt-a11y-\(UUID().uuidString.prefix(8)).html")
        defer { try? FileManager.default.removeItem(at: file) }
        check(controller.writeAccessibilityReport(to: file), "Save Report writes the file")
        let html = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        check(html.contains("1 of 15 done") && html.contains("<strong>Fails.</strong>") && html.contains("UA 7.1"), "the report has the tick and the result")
        check(pane.saved == file, "Open Report is offered for what was saved")

        pane.press(again: true)
        await settle()
        check(pane.done == ["title"] && pane.report != nil && !pane.showsChecklist, "Check Again keeps the tick and shows the failures")

        // Back to the thumbnails and to the pane; Show Pages still works with the extra segment.
        controller.sidebar.show(0)
        check(controller.sidebar.shownSegment == 0 && pane.isHidden, "the thumbnails come back")
        controller.sidebar.show(4)
        check(!pane.isHidden, "the segment brings the pane back")
        controller.sidebar.show(0)

        check(BatchWindowController.offered.contains { $0.title == "Check accessibility" }, "Batch offers the action")
        finish()
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
