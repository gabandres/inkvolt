import AppKit
import PdfCore

/// The measuring tools' state the window keeps: the scales of the version shown (read once per version), and the scale
/// sheet while it is open (the self-test fills it in and presses its button).
@MainActor
final class MeasureState {
    var scales: (engine: ObjectIdentifier, scales: MeasureScales)?
    var sheet: ScaleSheet?
}

/// Set Measuring Scale and Calibrate's sheet: an NSAlert with the lengths, units, decimals and pages.
@MainActor
final class ScaleSheet {
    let alert = NSAlert()
    /// Set Measuring Scale only: the length on the page and its unit.
    let pageValue = NSTextField(string: "1")
    let pageUnit = NSPopUpButton(frame: .zero, pullsDown: false)
    let realValue = NSTextField(string: "")
    let realUnit = NSPopUpButton(frame: .zero, pullsDown: false)
    let decimals = NSPopUpButton(frame: .zero, pullsDown: false)
    let pages = NSPopUpButton(frame: .zero, pullsDown: false)

    init(unit: String, decimals current: Int, page: Int) {
        for (popup, label) in [(pageUnit, "Unit on the page"), (realUnit, "Real unit")] {
            popup.addItems(withTitles: MeasureScale.units)
            popup.setAccessibilityLabel(label)
        }
        pageUnit.selectItem(withTitle: "in")
        realUnit.selectItem(withTitle: MeasureScale.units.contains(unit) ? unit : "ft")
        pageValue.setAccessibilityLabel("Length on the page")
        realValue.setAccessibilityLabel("Real length")
        for f in [pageValue, realValue] { f.widthAnchor.constraint(equalToConstant: 80).isActive = true }
        decimals.addItems(withTitles: ["0", "1", "2", "3", "4"])
        decimals.selectItem(at: min(max(current, 0), 4))
        decimals.setAccessibilityLabel("Decimals")
        pages.addItems(withTitles: ["This page (\(page + 1))", "All pages"])
        pages.setAccessibilityLabel("Use it for")
    }

    var allPages: Bool { pages.indexOfSelectedItem == 1 }
}

/// Tools › Measure (the Windows app's Review › Measure, `DocumentTab.Measure`): distance, perimeter and area at the
/// page's scale (its viewport where the document has one, else real size), saved as measurement comments; Set Measuring
/// Scale writes a page's scale into the document, and Calibrate works one out from a line of known length. Free, as on
/// Windows.
extension DocumentWindowController {
    func wireMeasuring() {
        pages.measureScaleAt = { [weak self] page, at in self?.scaleAt(page, at) ?? .default }
        pages.onMeasured = { [weak self] tool, page, points in
            guard let self else { return false }
            if tool == .calibrate {
                self.askCalibration(page, points)
                return true
            }
            return await self.addMeasurement(tool.kind, page: page, points: points)
        }
    }

    /// The scale at a point (the document's viewport there, else real size), from the scales read once per version.
    func scaleAt(_ page: Int, _ at: PointD) -> MeasureScale {
        guard let session = pdf.session else { return .default }
        let version = ObjectIdentifier(session.engine)
        if measure.scales?.engine != version {
            measure.scales = (version, MeasureScales(session.data, session.password))
        }
        return measure.scales!.scales.scaleAt(page, at)
    }

    /// A finished measurement saved as a comment (one undo step), and said in the notice bar.
    @discardableResult
    func addMeasurement(_ kind: MeasureKind, page: Int, points: [PointD]) async -> Bool {
        let scale = scaleAt(page, points[0])
        let author = editor.author
        let name = kind == .distance ? "distance" : kind == .perimeter ? "perimeter" : "area"
        let ok = await editor.run("Measure \(name)") { d, pw in
            try Measurements.add(d, pw, page, kind, points, scale, author: author)
        }
        if ok { notify(scale.announcement(kind, points), canUndo: true) }
        return ok
    }

    // MARK: Menu commands

    /// Tools › Measure › Set Measuring Scale…: "1 in = 10 ft" for this page or all pages, saved in the document.
    @objc func setMeasuringScale(_ sender: Any?) {
        guard let window, pdf.session != nil else { return }
        let page = pages.currentPage
        let current = scaleAt(page, PointD(1, 1))
        let sheet = ScaleSheet(unit: current.unit == "units" ? "ft" : current.unit, decimals: current.decimals, page: page)
        sheet.realValue.stringValue = "1"
        let alert = sheet.alert
        alert.messageText = "Set Measuring Scale"
        alert.informativeText = "What a length on the page stands for, as drawings say it (1 in = 10 ft, 1 cm = 1 m). Now: \(current.ratio).\n\n"
            + "The scale is saved in the document, as Acrobat does, so later measurements here or in other apps use it. Measurements already "
            + "made keep theirs. Parts of a page with a scale of their own (a detail) keep it."
        let equals = NSTextField(labelWithString: "=")
        equals.font = .systemFont(ofSize: 16)
        let lengths = NSStackView(views: [sheet.pageValue, sheet.pageUnit, equals, sheet.realValue, sheet.realUnit])
        lengths.spacing = 6
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "On the page = real:"), lengths],
            [NSTextField(labelWithString: "Decimals:"), sheet.decimals],
            [NSTextField(labelWithString: "Use it for:"), sheet.pages],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 440, height: 90)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Set Scale")
        alert.addButton(withTitle: "Cancel")
        measure.sheet = sheet
        alert.layout()
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                self.measure.sheet = nil
                guard response == .alertFirstButtonReturn else { return }
                guard let dv = MeasureScale.number(sheet.pageValue.stringValue, 1e-9, 1e9),
                      let rv = MeasureScale.number(sheet.realValue.stringValue, 1e-9, 1e12),
                      let pageUnit = sheet.pageUnit.titleOfSelectedItem, let realUnit = sheet.realUnit.titleOfSelectedItem,
                      let scale = try? MeasureScale.from(dv, pageUnit, rv, realUnit, decimals: sheet.decimals.indexOfSelectedItem) else {
                    return self.pdf.showError("Type both lengths as numbers more than 0.", nil)
                }
                Task { await self.setScale(scale, page: sheet.allPages ? nil : page) }
            }
        }
        alert.window.makeFirstResponder(sheet.realValue)
    }

    /// Calibrate: the line just drawn is given its real length, which sets the scale.
    func askCalibration(_ page: Int, _ points: [PointD]) {
        guard let window, let first = points.first, let last = points.last else { return }
        let current = scaleAt(page, first)
        let length = MeasureGeometry.distance(first, last) * current.userUnit // in points, whatever the page's unit
        if length < 1 {
            notify("That line is too short to calibrate from. Click two points further apart.")
            return
        }
        let sheet = ScaleSheet(unit: current.unit, decimals: current.decimals, page: page)
        let alert = sheet.alert
        alert.messageText = "Calibrate Scale"
        alert.informativeText = "The line you drew is \(MeasureScale.trimmedInches(length)) in long on the page. How long is it really?"
        let real = NSStackView(views: [sheet.realValue, sheet.realUnit])
        real.spacing = 6
        let grid = NSGridView(views: [
            [NSTextField(labelWithString: "Real length:"), real],
            [NSTextField(labelWithString: "Decimals:"), sheet.decimals],
            [NSTextField(labelWithString: "Use it for:"), sheet.pages],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.frame = NSRect(x: 0, y: 0, width: 340, height: 90)
        alert.accessoryView = grid
        alert.addButton(withTitle: "Set Scale")
        alert.addButton(withTitle: "Cancel")
        measure.sheet = sheet
        alert.layout()
        alert.beginSheetModal(for: window) { response in
            MainActor.assumeIsolated {
                self.measure.sheet = nil
                guard response == .alertFirstButtonReturn else { return }
                guard let rv = MeasureScale.number(sheet.realValue.stringValue, 1e-9, 1e12), let unit = sheet.realUnit.titleOfSelectedItem,
                      let scale = try? MeasureScale.calibrate(length, rv, unit, decimals: sheet.decimals.indexOfSelectedItem) else {
                    return self.pdf.showError("Type the real length, a number more than 0.", nil)
                }
                Task { await self.setScale(scale, page: sheet.allPages ? nil : page) }
            }
        }
        alert.window.makeFirstResponder(sheet.realValue)
    }

    /// Writes `scale` for one page, or every page with nil (one undo step).
    @discardableResult
    func setScale(_ scale: MeasureScale, page: Int?) async -> Bool {
        let all = Array(0..<engine.pageCount)
        let chosen = page.map { [$0] } ?? all
        let ok = await editor.run("Set measuring scale") { d, pw in try Measurements.setPageScale(d, pw, chosen, scale) }
        if ok {
            let which = page.map { "page \($0 + 1)" } ?? "all pages"
            notify("Scale \(scale.ratio) set for \(which). Measure with Tools › Measure.", canUndo: true)
        }
        return ok
    }

    /// For the self-test (the Windows dev script's `measurements`): the current page's measurements and its scale.
    func measurementsReport() -> String {
        guard let session = pdf.session else { return "no document" }
        let page = pages.currentPage
        let list = (try? Measurements.read(session.data, session.password, page)) ?? []
        let items = list.map { "\($0.kind) \($0.text) @ \($0.scale.ratio)" }.joined(separator: " | ")
        var s = "measurements p\(page + 1): \(list.count) [\(items)] scale here \(scaleAt(page, PointD(1, 1)).ratio)"
        if let live = pages.measureInProgress { s += "; in progress \(live)" }
        return s
    }
}

extension MeasureScale {
    /// A length in points as inches with up to three decimals (Windows' "0.###").
    static func trimmedInches(_ points: Double) -> String {
        var s = String(format: "%.3f", points / 72)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
}
