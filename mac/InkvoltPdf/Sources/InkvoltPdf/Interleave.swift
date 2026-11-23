import AppKit
import PdfCore
import PrintCore

/// Pages › Interleave Pages… and File › Scan the Backs… (Windows' `Organize.Interleave` and Scan the Backs, roadmap 4.3):
/// the fronts and backs of two-sided sheets scanned one side at a time put back in order, as two ranges of this document
/// or as this document (the fronts) and another PDF (the backs), the backs reversed (a stack turned over) or not; uneven
/// counts are asked about and the pages left over follow (`PageEditor.interleaveOrder`). One undo step.
extension DocumentWindowController {
    @objc func interleavePages(_ sender: Any?) {
        guard let window, pdf.session != nil, engine.pageCount > 0 else { return NSSound.beep() }
        Task { await askInterleave(window) }
    }

    /// File › Scan the Backs…: the Scan window, the backs it scans going after their fronts (this document's pages).
    @objc func scanBacks(_ sender: Any?) {
        guard pdf.session != nil, engine.pageCount > 0 else { return NSSound.beep() }
        ScanWindowController.showBacks(into: self)
    }

    private func askInterleave(_ window: NSWindow) async {
        let count = engine.pageCount
        let half = (count + 1) / 2
        let from = NSPopUpButton(frame: .zero, pullsDown: false)
        from.addItems(withTitles: [loc("Pages of this document"), loc("In another PDF (this document has the fronts)")])
        from.selectItem(at: count > 1 ? 0 : 1)
        from.setAccessibilityLabel(loc("The backs are"))
        let frontField = NSTextField(string: half > 1 ? "1-\(half)" : "1")
        frontField.setAccessibilityLabel(loc("Fronts (pages)"))
        let backField = NSTextField(string: count > half + 1 ? "\(half + 1)-\(count)" : String(count))
        backField.setAccessibilityLabel(loc("Backs (pages)"))
        for f in [frontField, backField] { f.widthAnchor.constraint(equalToConstant: 200).isActive = true }
        let reversed = NSButton(checkboxWithTitle: loc("The backs are in reverse order (the stack was turned over to scan them)"), target: nil, action: nil)
        reversed.state = .on
        let note = NSTextField(wrappingLabelWithString: loc("For two-sided sheets scanned one side at a time: the fronts, then the backs. The pages become front 1, back 1, front 2, back 2, and so on."))
        note.preferredMaxLayoutWidth = 380
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 380
        problem.isHidden = true
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: loc("The backs are:")), from],
            [NSTextField(labelWithString: loc("Fronts (pages):")), frontField],
            [NSTextField(labelWithString: loc("Backs (pages):")), backField],
        ])
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [note, grid, reversed, problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        let enable = PopUpAction {
            frontField.isEnabled = from.indexOfSelectedItem == 0
            backField.isEnabled = frontField.isEnabled
        }
        from.target = enable
        from.action = #selector(PopUpAction.changed(_:))
        enable.changed(nil)
        defer { withExtendedLifetime(enable) {} }

        var fronts: [Int] = [], backs: [Int] = []
        while true {
            let alert = NSAlert()
            alert.messageText = loc("Interleave Pages")
            alert.addButton(withTitle: loc("Interleave"))
            alert.addButton(withTitle: loc("Cancel"))
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            if from.indexOfSelectedItem == 1 { break }
            let f = PageRange.tryParse(frontField.stringValue, count), b = PageRange.tryParse(backField.stringValue, count)
            var wrong = !f.ok ? f.error : !b.ok ? b.error : nil
            if wrong == nil {
                do { _ = try PageEditor.interleaveOrder(count, f.pages, b.pages, reverseBacks: reversed.state == .on) } catch {
                    wrong = (error as? PdfEditError)?.message ?? error.localizedDescription
                }
            }
            if let wrong {
                problem.stringValue = wrong
                problem.isHidden = false
                continue
            }
            (fronts, backs) = (f.pages, b.pages)
            break
        }
        let reverse = reversed.state == .on
        if from.indexOfSelectedItem == 0 {
            guard engine.pageCount == count, await confirmUneven(fronts: fronts.count, backs: backs.count) else { return }
            await interleave(fronts: fronts, backs: backs, reversed: reverse)
            return
        }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
        panel.message = loc("Choose the PDF with the backs")
        guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url, let source = loadSource([url]) else { return }
        guard let backCount = try? PdfEngine.open(source.data, password: source.password) else {
            return pdf.showError(loc("Those pages couldn't be read."), nil)
        }
        let n = backCount.pageCount
        backCount.close()
        guard await confirmUneven(fronts: engine.pageCount, backs: n) else { return }
        await interleaveWith(source, reversed: reverse, label: loc("Interleave pages"))
    }

    /// Fronts and backs of different counts are allowed (what is left over follows), after the user says so.
    func confirmUneven(fronts: Int, backs: Int) async -> Bool {
        if fronts == backs || Report.skipsDialogs { return true }
        guard let window else { return false }
        let alert = NSAlert()
        alert.messageText = loc("The two sides don't match")
        alert.informativeText = loc("There are {0} fronts and {1} backs. The pages left over go after the others.", CoreLanguage.number(fronts), CoreLanguage.number(backs))
        alert.addButton(withTitle: loc("Interleave Anyway"))
        alert.addButton(withTitle: loc("Cancel"))
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
    }

    // MARK: The edits (the sheet, Scan the Backs and the self-test call these)

    @discardableResult
    func interleave(fronts: [Int], backs: [Int], reversed: Bool) async -> Bool {
        let ok = await editor.run(loc("Interleave pages")) { d, pw in try PageEditor.interleave(d, pw, fronts, backs, reverseBacks: reversed) }
        if ok, let first = (fronts + backs).min() { reselect(Array(first..<(first + fronts.count + backs.count))) }
        return ok
    }

    /// This document's pages are the fronts, `source`'s pages the backs.
    @discardableResult
    func interleaveWith(_ source: PdfSource, reversed: Bool, label: String) async -> Bool {
        await editor.run(label) { d, pw in try PageEditor.interleaveWith(d, pw, source, reverseBacks: reversed) }
    }
}

/// Runs a closure when a pop-up (or any control) changes: for sheets built in code.
@MainActor
final class PopUpAction: NSObject {
    private let run: () -> Void

    init(_ run: @escaping () -> Void) { self.run = run }

    @objc func changed(_ sender: Any?) { run() }
}
