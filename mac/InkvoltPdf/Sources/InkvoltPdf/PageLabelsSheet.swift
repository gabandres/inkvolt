import AppKit
import PdfCore
import PrintCore

/// Pages › Page Labels… (Windows' `Organize.EditPageLabels`, roadmap 4.14): a numbering, prefix and first number for a
/// range of pages, with what they will show; the pages after can be numbered from 1 again, or every label removed
/// (`PageLabels`). One undo step.
extension DocumentWindowController {
    /// The numberings Page Labels offers, in its list's order.
    private static var numberings: [(numbering: PageNumbering, name: String)] {
        [(.decimal, "1, 2, 3"), (.lowerRoman, "i, ii, iii"), (.upperRoman, "I, II, III"), (.lowerLetters, "a, b, c"),
         (.upperLetters, "A, B, C"), (.none, loc("No number (the prefix only)"))]
    }

    @objc func editPageLabels(_ sender: Any?) {
        guard let window, let session = pdf.session else { return NSSound.beep() }
        let chosen = selectedPages
        guard !chosen.isEmpty else { return NSSound.beep() }
        let current = chosen[0]
        let at = (try? PageLabels.at(session.data, session.password, current)) ?? PageLabelStyle(.decimal, "", current + 1)
        let hasLabels = ((try? DocumentFeatures.pageLabels(session.data, session.password)) ?? nil) != nil
        Task { await askPageLabels(chosen, at: at, hasLabels: hasLabels, window) }
    }

    private func askPageLabels(_ chosen: [Int], at: PageLabelStyle, hasLabels: Bool, _ window: NSWindow) async {
        let count = engine.pageCount
        let range = NSTextField(string: PageRange.format(chosen))
        range.setAccessibilityLabel(loc("Pages"))
        range.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let numbering = NSPopUpButton(frame: .zero, pullsDown: false)
        numbering.addItems(withTitles: Self.numberings.map(\.name))
        numbering.selectItem(at: max(0, Self.numberings.firstIndex { $0.numbering == at.numbering } ?? 0))
        numbering.setAccessibilityLabel(loc("Numbering"))
        let prefix = NSTextField(string: at.prefix)
        prefix.setAccessibilityLabel(loc("Prefix"))
        let start = NSTextField(string: String(at.start))
        start.setAccessibilityLabel(loc("Start at"))
        start.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let restart = NSButton(checkboxWithTitle: loc("Number the pages after them 1, 2, 3…"), target: nil, action: nil)
        restart.state = !hasLabels && chosen[0] == 0 && count > 1 ? .on : .off
        let note = NSTextField(wrappingLabelWithString: loc("A page's label is what the page box, the thumbnails and Go to Page show for it, such as i, ii for a preface and then 1, 2."))
        note.preferredMaxLayoutWidth = 360
        let preview = NSTextField(wrappingLabelWithString: "")
        preview.preferredMaxLayoutWidth = 360
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.isHidden = true
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: loc("Pages:")), range],
            [NSTextField(labelWithString: loc("Numbering:")), numbering],
            [NSTextField(labelWithString: loc("Prefix:")), prefix],
            [NSTextField(labelWithString: loc("Start at:")), start],
        ])
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [note, grid, restart, preview, problem])
        stack.orientation = .vertical
        stack.alignment = .leading

        func style() -> (PageLabelStyle?, String?) {
            guard let first = Int(start.stringValue.trimmingCharacters(in: .whitespaces)), first >= 1, first <= PageLabels.maxStart else {
                return (nil, loc("Enter the first number, from 1 to {0}.", CoreLanguage.number(PageLabels.maxStart)))
            }
            let s = PageLabelStyle(Self.numberings[max(0, numbering.indexOfSelectedItem)].numbering, prefix.stringValue, first)
            do {
                try PageLabels.check(s)
                return (s, nil)
            } catch {
                return (nil, (error as? PdfEditError)?.message ?? error.localizedDescription)
            }
        }
        let update = PageLabelsPreview {
            let (s, error) = style()
            preview.stringValue = s.map { s in loc("These pages will show: {0}", (0..<4).map { s.format($0) }.joined(separator: ", ") + "…") } ?? error ?? ""
        }
        numbering.target = update
        numbering.action = #selector(PageLabelsPreview.changed(_:))
        prefix.delegate = update
        start.delegate = update
        update.changed(nil)
        // The fields hold their delegate and target weakly: kept until the sheet is done.
        defer { withExtendedLifetime(update) {} }

        var pages: [Int] = []
        var chosenStyle: PageLabelStyle?
        while true {
            let alert = NSAlert()
            alert.messageText = loc("Page Labels")
            alert.addButton(withTitle: loc("Apply"))
            alert.addButton(withTitle: loc("Cancel"))
            if hasLabels { alert.addButton(withTitle: loc("Use Plain Numbers")) }
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            alert.window.initialFirstResponder = range
            let response = await alert.beginSheetModal(for: window)
            if response == .alertThirdButtonReturn {
                guard engine.pageCount == count else { return }
                await removePageLabels()
                return
            }
            guard response == .alertFirstButtonReturn else { return }
            let r = PageRange.tryParse(range.stringValue, count)
            let (s, error) = style()
            if let wrong = !r.ok ? r.error : error {
                problem.stringValue = wrong
                problem.isHidden = false
                continue
            }
            pages = r.pages
            chosenStyle = s
            break
        }
        guard let chosenStyle, engine.pageCount == count else { return } // the document changed meanwhile
        await setPageLabels(pages, chosenStyle, restartAfter: restart.state == .on)
    }

    // MARK: The edits (the sheet and the self-test call these)

    @discardableResult
    func setPageLabels(_ chosen: [Int], _ style: PageLabelStyle, restartAfter: Bool) async -> Bool {
        let ok = await editor.run(loc("Set page labels")) { d, pw in try PageLabels.write(d, pw, chosen, style, restartAfter: restartAfter) }
        if ok { reselect(chosen) }
        return ok
    }

    @discardableResult
    func removePageLabels() async -> Bool {
        await editor.run(loc("Remove page labels")) { d, pw in try PageLabels.remove(d, pw) }
    }
}

/// Redraws Page Labels' preview as its fields change.
@MainActor
private final class PageLabelsPreview: NSObject, NSTextFieldDelegate {
    private let update: () -> Void

    init(_ update: @escaping () -> Void) { self.update = update }

    @objc func changed(_ sender: Any?) { update() }

    func controlTextDidChange(_ obj: Notification) { update() }
}
