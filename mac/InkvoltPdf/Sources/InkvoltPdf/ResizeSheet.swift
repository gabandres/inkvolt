import AppKit
import PdfCore
import PrintCore

/// Pages › Resize Pages… (Windows' `Organize.Resize`, roadmap 4.7): Letter, Legal, Tabloid, A3, A4, A5 or a size typed,
/// the content scaled to fit or kept with margins, for the pages chosen; `PageEditor.resize` does it, as one undo step.
extension DocumentWindowController {
    /// The paper sizes Resize Pages offers (points, upright), in its list's order (Windows' `Organize.PaperSizes`).
    static var paperSizes: [(name: String, width: Double, height: Double)] {
        [(loc("Letter (8.5 × 11 in)"), 612, 792), (loc("Legal (8.5 × 14 in)"), 612, 1008), (loc("Tabloid (11 × 17 in)"), 792, 1224),
         ("A3 (297 × 420 mm)", 842, 1191), ("A4 (210 × 297 mm)", 595, 842), ("A5 (148 × 210 mm)", 420, 595)]
    }

    @objc func resizePages(_ sender: Any?) {
        guard let window, pdf.session != nil else { return NSSound.beep() }
        let chosen = selectedPages
        guard !chosen.isEmpty else { return NSSound.beep() }
        Task { await askResize(chosen, window) }
    }

    private func askResize(_ chosen: [Int], _ window: NSWindow) async {
        let count = engine.pageCount
        let current = engine.page(chosen[0])
        let sizes = Self.paperSizes
        // A4 where the metric system is used, Letter elsewhere (as the printer's paper usually is).
        let metric = Locale.current.measurementSystem == .metric
        let size = NSPopUpButton(frame: .zero, pullsDown: false)
        size.addItems(withTitles: sizes.map(\.name) + [loc("Custom size")])
        size.selectItem(at: sizes.firstIndex { $0.width == (metric ? 595 : 612) && $0.height == (metric ? 842 : 792) } ?? 0)
        size.setAccessibilityLabel(loc("Page size"))
        let units = NSPopUpButton(frame: .zero, pullsDown: false)
        units.addItems(withTitles: [loc("Inches"), loc("Millimeters")])
        units.setAccessibilityLabel(loc("Units"))
        func inches(_ points: Double) -> String { PdfNum.f((points / 72 * 100).rounded() / 100) }
        let widthField = NSTextField(string: inches(min(current.width, current.height)))
        widthField.setAccessibilityLabel(loc("Width"))
        let heightField = NSTextField(string: inches(max(current.width, current.height)))
        heightField.setAccessibilityLabel(loc("Height"))
        for f in [widthField, heightField] { f.widthAnchor.constraint(equalToConstant: 90).isActive = true }
        let fit = NSPopUpButton(frame: .zero, pullsDown: false)
        fit.addItems(withTitles: [loc("Scale it to fit the paper"), loc("Keep its size and add margins (shrunk only if it doesn't fit)")])
        fit.setAccessibilityLabel(loc("The content"))
        let range = NSTextField(string: chosen.count > 1 ? PageRange.format(chosen) : "1-\(count)")
        range.setAccessibilityLabel(loc("Pages"))
        range.widthAnchor.constraint(equalToConstant: 220).isActive = true
        let note = NSTextField(wrappingLabelWithString: loc("A page that shows landscape gets the paper sideways. Comments and form fields move with the content."))
        note.preferredMaxLayoutWidth = 380
        let problem = NSTextField(wrappingLabelWithString: "")
        problem.textColor = .systemRed
        problem.preferredMaxLayoutWidth = 380
        problem.isHidden = true
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: loc("Page size:")), size],
            [NSTextField(labelWithString: loc("Units:")), units],
            [NSTextField(labelWithString: loc("Width:")), widthField],
            [NSTextField(labelWithString: loc("Height:")), heightField],
            [NSTextField(labelWithString: loc("The content:")), fit],
            [NSTextField(labelWithString: loc("Pages:")), range],
        ])
        grid.column(at: 0).xPlacement = .trailing
        let stack = NSStackView(views: [grid, note, problem])
        stack.orientation = .vertical
        stack.alignment = .leading
        let custom = sizes.count
        let enable = PopUpAction {
            let on = size.indexOfSelectedItem == custom
            for c in [units, widthField, heightField] as [NSControl] { c.isEnabled = on }
        }
        var millimeters = false
        let convert = PopUpAction {
            // The sizes typed stay the same length in the other unit.
            let toMm = units.indexOfSelectedItem == 1
            guard toMm != millimeters else { return }
            millimeters = toMm
            for f in [widthField, heightField] {
                guard let v = TypedNumber.parse(f.stringValue), v >= 0, v <= 1e6 else { continue }
                f.stringValue = toMm ? String(Int((v * 25.4).rounded())) : PdfNum.f((v / 25.4 * 100).rounded() / 100) // bounded: v checked 0...1e6 above
            }
        }
        size.target = enable
        size.action = #selector(PopUpAction.changed(_:))
        units.target = convert
        units.action = #selector(PopUpAction.changed(_:))
        enable.changed(nil)
        defer { withExtendedLifetime((enable, convert)) {} }

        var pages: [Int] = []
        var (w, h) = (0.0, 0.0)
        while true {
            let alert = NSAlert()
            alert.messageText = loc("Resize Pages")
            alert.addButton(withTitle: loc("Resize"))
            alert.addButton(withTitle: loc("Cancel"))
            stack.layoutSubtreeIfNeeded()
            stack.frame.size = stack.fittingSize
            alert.accessoryView = stack
            guard await alert.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
            let r = PageRange.tryParse(range.stringValue, count)
            var wrong = r.ok ? nil : r.error
            if wrong == nil {
                if size.indexOfSelectedItem < custom {
                    (w, h) = (sizes[size.indexOfSelectedItem].width, sizes[size.indexOfSelectedItem].height)
                } else {
                    let factor = units.indexOfSelectedItem == 1 ? 72 / 25.4 : 72.0
                    let typed = (TypedNumber.parse(widthField.stringValue) ?? -1, TypedNumber.parse(heightField.stringValue) ?? -1)
                    (w, h) = (typed.0 * factor, typed.1 * factor)
                    let bounds = (PageEditor.minPaper - 0.5)...(PageEditor.maxPaper + 0.5)
                    if !bounds.contains(w) || !bounds.contains(h) {
                        wrong = loc("Enter a width and a height between 1 and 200 inches (25 and 5080 mm).")
                    }
                }
            }
            if let wrong {
                problem.stringValue = wrong
                problem.isHidden = false
                continue
            }
            pages = r.pages
            break
        }
        guard engine.pageCount == count else { return } // the document changed meanwhile
        w = min(max(w, PageEditor.minPaper), PageEditor.maxPaper)
        h = min(max(h, PageEditor.minPaper), PageEditor.maxPaper)
        await resize(pages, width: w, height: h, fit: fit.indexOfSelectedItem == 0 ? .scale : .margins)
    }

    // MARK: The edit (the sheet and the self-test call it)

    @discardableResult
    func resize(_ chosen: [Int], width: Double, height: Double, fit: ResizeFit) async -> Bool {
        let label = chosen.count == 1 ? loc("Resize 1 page") : loc("Resize {0} pages", CoreLanguage.number(chosen.count))
        let ok = await editor.run(label) { d, pw in try PageEditor.resize(d, pw, chosen, width, height, fit) }
        if ok { reselect(chosen) }
        return ok
    }
}
