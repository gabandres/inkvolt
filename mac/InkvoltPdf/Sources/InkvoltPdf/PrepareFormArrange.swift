import AppKit
import PdfCore
import PrintCore

/// What Arrange Fields does to several selected fields (`FormDesignRules`' aligned, sizedAlike and spread).
enum FieldArrange: CaseIterable {
    case alignLeft, alignCenter, alignRight, alignTop, alignMiddle, alignBottom, sameWidth, sameHeight, sameSize, spaceAcross, spaceDown

    var spaces: Bool { self == .spaceAcross || self == .spaceDown }
}

/// Prepare Form, roadmap 4.12 (the Windows app's `DocumentTab.FormArrange`): a text field's or dropdown's Calculate section
/// (sum, product, average, minimum, maximum of ticked fields, or simplified field notation; a custom script kept), the
/// form's calculation order, and several fields (⌘-click) aligned, sized alike and spaced evenly. The rules are PdfCore's
/// `FormDesignRules` and `FormCalculations`; this fills the panel and runs the edits.
extension PrepareForm {
    // MARK: Calculate

    func buildCalculation() {
        wire(calcPopup, #selector(calcKindChanged))
        wire(calcNotationField, #selector(calcNotationChanged))
        wire(calcOrderButton, #selector(calcOrderClicked))
        calcOrderButton.toolTip = loc("Which calculated fields work out first")
        calcNotationField.placeholderString = loc("Price * Quantity")
        calcNotationField.setAccessibilityLabel(loc("Simplified field notation"))
        calcFieldsList.orientation = .vertical
        calcFieldsList.alignment = .leading
        calcFieldsList.spacing = 2
        let document = FlippedStack()
        document.translatesAutoresizingMaskIntoConstraints = false
        calcFieldsList.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(calcFieldsList)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = false
        NSLayoutConstraint.activate([
            scroll.heightAnchor.constraint(equalToConstant: 96),
            calcFieldsList.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 4),
            calcFieldsList.trailingAnchor.constraint(lessThanOrEqualTo: document.trailingAnchor, constant: -4),
            calcFieldsList.topAnchor.constraint(equalTo: document.topAnchor, constant: 3),
            calcFieldsList.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -3),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        scroll.setAccessibilityLabel(loc("Of these fields"))
        _ = row(loc("Of these fields"), scroll, in: calcFieldsRow)
        _ = row(loc("Calculation (as Price * Quantity)"), calcNotationField, in: calcNotationRow)
        _ = column([row(loc("Calculate"), calcPopup), calcFieldsRow, calcNotationRow, calcOrderButton], in: calcGroup)
    }

    private final class FlippedStack: NSView {
        override var isFlipped: Bool { true }
    }

    /// The kind the Calculate list shows (nil: the custom script's "kept" entry).
    private var calcKindShown: CalcKind? {
        let i = calcPopup.indexOfSelectedItem
        return FormDesignRules.calcKinds.indices.contains(i) ? FormDesignRules.calcKinds[i] : nil
    }

    private var calcPicked: [String] {
        calcFieldsList.arrangedSubviews.compactMap { ($0 as? NSButton).flatMap { $0.state == .on ? $0.title : nil } }
    }

    private func showCalcParts(_ kind: CalcKind?) {
        let list: Set<CalcKind> = [.sum, .product, .average, .minimum, .maximum]
        calcFieldsRow.isHidden = !(kind.map(list.contains) ?? false)
        calcNotationRow.isHidden = kind != .notation
    }

    /// The Calculate section for the selected field (text fields and dropdowns; hidden for the others).
    func showCalculation(_ f: DesignField) {
        let shows = f.kind == .text || f.kind == .comboBox
        calcGroup.isHidden = !shows
        guard shows else { return }
        var labels = FormDesignRules.calcLabels
        let at = FormDesignRules.calcIndex(f)
        if at < 0 { labels.append(loc("Custom script (kept)")) }
        fill(calcPopup, labels, selected: at >= 0 ? at : labels.count - 1)
        calcPopup.isEnabled = at >= 0 && !f.signed
        let sources = FormDesignRules.calcSources(f, model.fields)
        if sources != calcSourcesShown {
            calcSourcesShown = sources
            for v in calcFieldsList.arrangedSubviews { v.removeFromSuperview() }
            for name in sources {
                let box = NSButton(checkboxWithTitle: name, target: self, action: #selector(calcFieldsChanged))
                box.lineBreakMode = .byTruncatingTail
                calcFieldsList.addArrangedSubview(box)
            }
        }
        let picked = Set(f.calculation?.fields ?? [])
        for case let box as NSButton in calcFieldsList.arrangedSubviews { box.state = picked.contains(box.title) ? .on : .off }
        setText(calcNotationField, f.calculation?.kind == .notation ? f.calculation?.notation ?? "" : "")
        showCalcParts(f.calculation?.kind)
    }

    @objc func calcKindChanged() {
        guard let kind = calcKindShown else { return }
        showCalcParts(kind)
        pinPanel()
        // Nothing picked or typed yet: wait for it (an empty notation would be refused).
        let typed = calcNotationField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if kind == .notation && typed.isEmpty && calcPicked.isEmpty { return }
        if kind != .notCalculated && kind != .notation && calcPicked.isEmpty { return }
        changeCalculation(kind)
    }

    @objc func calcFieldsChanged() {
        guard let kind = calcKindShown, kind != .notCalculated, kind != .notation else { return }
        changeCalculation(kind)
    }

    @objc func calcNotationChanged() {
        if calcKindShown == .notation { changeCalculation(.notation) }
    }

    private func changeCalculation(_ kind: CalcKind) {
        let picked = calcPicked, notation = calcNotationField.stringValue, fields = model.fields
        change(loc("Change calculation")) { try FormDesignRules.withCalculation($0, kind, picked, notation, fields) }
    }

    /// The self-test's pick, made as a person makes it (kind, then fields or notation; Windows' DevSetCalculation).
    func testSetCalculation(_ kind: CalcKind, fields: [String] = [], notation: String = "") {
        if kind == .notation { calcNotationField.stringValue = notation }
        for case let box as NSButton in calcFieldsList.arrangedSubviews { box.state = fields.contains(box.title) ? .on : .off }
        calcPopup.selectItem(at: FormDesignRules.calcKinds.firstIndex(of: kind) ?? 0)
        calcKindChanged()
    }

    /// The panel's rows after some showed or hid.
    private func pinPanel() { pinRowWidths() }

    @objc func calcOrderClicked() { track { [weak self] in await self?.editCalculationOrder() } }

    /// Tools › Forms › Calculation Order…: the calculated fields in the order they work out, moved up or down.
    func editCalculationOrder() async {
        guard let session = controller?.pdf.session else { return }
        let data = session.data, password = session.password, engine = ObjectIdentifier(session.engine)
        let order: [String]
        do {
            order = try await Task.detached { try FormDesign.calculationOrder(data, password) }.value
        } catch {
            controller?.pdf.showError(loc("The form's calculation order can't be read."), error)
            return
        }
        guard let now = controller?.pdf.session, ObjectIdentifier(now.engine) == engine else { return }
        if order.count < 2 {
            controller?.notify(order.isEmpty ? loc("No field in this form is calculated.") : loc("Only one field is calculated: there's no order to set."))
            return
        }
        let picked: [String]?
        if let test = testCalcOrder {
            testCalcOrder = nil
            picked = test
        } else {
            picked = await askCalculationOrder(order)
        }
        guard let picked, picked != order else { return }
        selectAfter = model.selectedId
        _ = await editor.run(loc("Change calculation order"), contentOnly: true) { d, pw in try FormDesign.setCalculationOrder(d, pw, picked) }
    }

    private func askCalculationOrder(_ order: [String]) async -> [String]? {
        guard let window = controller?.window else { return nil }
        let sheet = CalculationOrderList(order)
        let alert = NSAlert()
        alert.messageText = loc("Calculation order")
        alert.informativeText = loc("Fields calculate from the top down when the form is filled. Put a field after the fields it uses (⌥↑ and ⌥↓ move the selected one).")
        alert.accessoryView = sheet.view
        alert.addButton(withTitle: loc("OK"))
        alert.addButton(withTitle: loc("Cancel"))
        let response = await withCheckedContinuation { (done: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            alert.beginSheetModal(for: window) { done.resume(returning: $0) }
        }
        return response == .alertFirstButtonReturn ? sheet.order : nil
    }

    // MARK: Several fields

    func buildSeveral() {
        severalHint.textColor = .secondaryLabelColor
        severalHint.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let titles: [(FieldArrange, String)] = [
            (.alignLeft, loc("Left")), (.alignCenter, loc("Centers")), (.alignRight, loc("Right")),
            (.alignTop, loc("Top")), (.alignMiddle, loc("Middles")), (.alignBottom, loc("Bottom")),
            (.sameWidth, loc("Width")), (.sameHeight, loc("Height")), (.sameSize, loc("Both")),
            (.spaceAcross, loc("Across")), (.spaceDown, loc("Down")),
        ]
        arrangeButtons = titles.map { how, title in
            let b = NSButton(title: title, target: self, action: #selector(arrangeClicked(_:)))
            b.bezelStyle = .rounded
            b.controlSize = .small
            return (b, how)
        }
        func buttons(_ range: ClosedRange<Int>) -> NSStackView { Self.buttons(arrangeButtons[range].map(\.button)) }
        wire(severalDelete, #selector(severalDeleteClicked))
        severalDelete.toolTip = loc("Delete the selected fields")
        _ = column([
            severalHint,
            column([small(loc("Align")), buttons(0...2), buttons(3...5)], spacing: 3),
            column([small(loc("Same size")), buttons(6...8)], spacing: 3),
            column([small(loc("Space evenly")), buttons(9...10)], spacing: 3),
            severalDelete,
        ], in: severalGroup)
    }

    @objc func arrangeClicked(_ sender: NSButton) {
        guard let how = arrangeButtons.first(where: { $0.button === sender })?.how else { return }
        arrange(how)
    }

    @objc func severalDeleteClicked() { deleteSelected() }

    /// The panel when several fields are selected.
    func showSeveral(_ selected: [DesignField]) {
        for (button, how) in arrangeButtons where how.spaces { button.isEnabled = selected.count >= 3 }
        severalDelete.isEnabled = selected.contains { !$0.signed }
    }

    /// Whether Arrange Fields' `how` can run: Prepare Form with two fields selected (three to space them).
    func canArrange(_ how: FieldArrange) -> Bool { isDesigning && model.selectedIds.count >= (how.spaces ? 3 : 2) }

    /// Lines up, sizes or spaces the selected fields (one undo step), the first one picked staying put.
    func arrange(_ how: FieldArrange) {
        flushNudge()
        let selected = model.selectedFields
        guard isDesigning, let first = selected.first, isCurrent() else { return }
        let g = pages.engine.page(first.pageIndex)
        let page = DesignPage(g.width, g.height, rotation: pages.viewRotation)
        let moved: [DesignField]
        do {
            switch how {
            case .alignLeft: moved = try FormDesignRules.aligned(selected, .left, page)
            case .alignCenter: moved = try FormDesignRules.aligned(selected, .center, page)
            case .alignRight: moved = try FormDesignRules.aligned(selected, .right, page)
            case .alignTop: moved = try FormDesignRules.aligned(selected, .top, page)
            case .alignMiddle: moved = try FormDesignRules.aligned(selected, .middle, page)
            case .alignBottom: moved = try FormDesignRules.aligned(selected, .bottom, page)
            case .sameWidth: moved = try FormDesignRules.sizedAlike(selected, .width, page)
            case .sameHeight: moved = try FormDesignRules.sizedAlike(selected, .height, page)
            case .sameSize: moved = try FormDesignRules.sizedAlike(selected, .both, page)
            case .spaceAcross: moved = try FormDesignRules.spread(selected, .across, page)
            case .spaceDown: moved = try FormDesignRules.spread(selected, .down, page)
            }
        } catch let refusal as DesignRefusal {
            controller?.notify(refusal.message)
            return
        } catch {
            return
        }
        if moved.isEmpty {
            controller?.notify(loc("The fields are already that way."))
            return
        }
        let label: String
        switch how {
        case .sameWidth, .sameHeight, .sameSize: label = loc("Size fields alike")
        case .spaceAcross, .spaceDown: label = loc("Space fields evenly")
        default: label = loc("Align fields")
        }
        track { [weak self] in await self?.update(label, moved) }
    }
}

/// The Calculation Order sheet's list: the names in order, the selected one moved up or down (⌥↑ ⌥↓ or the buttons).
@MainActor
final class CalculationOrderList: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private(set) var order: [String]
    let view: NSView
    private let table = OrderTable()
    private let problem = NSTextField(labelWithString: "")

    init(_ order: [String]) {
        self.order = order
        view = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 250))
        super.init()
        let column = NSTableColumn(identifier: .init("name"))
        column.width = 280
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel(loc("Calculation order"))
        table.onMove = { [weak self] step in self?.move(step) }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 56, width: 300, height: 194))
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let up = NSButton(title: loc("Move Up"), target: self, action: #selector(upClicked))
        let down = NSButton(title: loc("Move Down"), target: self, action: #selector(downClicked))
        up.frame = NSRect(x: 0, y: 24, width: 145, height: 28)
        down.frame = NSRect(x: 155, y: 24, width: 145, height: 28)
        problem.frame = NSRect(x: 0, y: 0, width: 300, height: 18)
        problem.textColor = .systemRed
        problem.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        for v in [scroll, up, down, problem] { view.addSubview(v) }
        table.reloadData()
        table.selectRowIndexes([0], byExtendingSelection: false)
    }

    func numberOfRows(in tableView: NSTableView) -> Int { order.count }

    func tableView(_ tableView: NSTableView, objectValueFor tableColumn: NSTableColumn?, row: Int) -> Any? { order[row] }

    func tableView(_ tableView: NSTableView, shouldEdit tableColumn: NSTableColumn?, row: Int) -> Bool { false }

    @objc private func upClicked() { move(-1) }
    @objc private func downClicked() { move(1) }

    private func move(_ step: Int) {
        let i = table.selectedRow
        do {
            order = try FormDesignRules.movedInOrder(order, i, step) // refuses a move past either end
            table.reloadData()
            table.selectRowIndexes([i + step], byExtendingSelection: false)
            table.scrollRowToVisible(i + step)
            problem.stringValue = ""
        } catch let refusal as DesignRefusal {
            problem.stringValue = refusal.message
        } catch {}
    }

    /// ⌥↑ and ⌥↓ move the selected name (Windows' Alt+Up and Alt+Down).
    private final class OrderTable: NSTableView {
        var onMove: ((Int) -> Void)?

        override func keyDown(with event: NSEvent) {
            if event.modifierFlags.intersection([.command, .control, .option, .shift]) == .option,
               event.specialKey == .upArrow || event.specialKey == .downArrow {
                onMove?(event.specialKey == .upArrow ? -1 : 1)
                return
            }
            super.keyDown(with: event)
        }
    }
}

extension DocumentWindowController {
    /// Tools › Forms › Calculation Order….
    @objc func editCalculationOrder(_ sender: Any?) {
        Task {
            guard await design.setDesigning(true) else { return }
            await design.settle()
            await design.editCalculationOrder()
        }
    }

    @objc func alignFieldsLeft(_ sender: Any?) { design.arrange(.alignLeft) }
    @objc func alignFieldsCenter(_ sender: Any?) { design.arrange(.alignCenter) }
    @objc func alignFieldsRight(_ sender: Any?) { design.arrange(.alignRight) }
    @objc func alignFieldsTop(_ sender: Any?) { design.arrange(.alignTop) }
    @objc func alignFieldsMiddle(_ sender: Any?) { design.arrange(.alignMiddle) }
    @objc func alignFieldsBottom(_ sender: Any?) { design.arrange(.alignBottom) }
    @objc func sameFieldWidth(_ sender: Any?) { design.arrange(.sameWidth) }
    @objc func sameFieldHeight(_ sender: Any?) { design.arrange(.sameHeight) }
    @objc func sameFieldSize(_ sender: Any?) { design.arrange(.sameSize) }
    @objc func spaceFieldsAcross(_ sender: Any?) { design.arrange(.spaceAcross) }
    @objc func spaceFieldsDown(_ sender: Any?) { design.arrange(.spaceDown) }
}
