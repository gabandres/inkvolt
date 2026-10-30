import AppKit
import PdfCore

/// The self-test's scenario for E5 (`--edit`, on the synthetic text document before `SignTest` signs it;
/// `--only-prepare-form` runs it alone): Prepare Form from its menu command, each field kind placed through the page view's
/// own mouse handling, the panel's controls through their own actions, moving, resizing and nudging, the keys, undo and
/// redo, suggestions, and the saved bytes read back by PdfCore and filled. It undoes everything at the end. A copy of the
/// form is kept in the temporary folder for checks in other apps. Only counts, names and values it made are written.
@MainActor
struct PrepareFormTest {
    let controller: DocumentWindowController
    let name: String
    private var lines: [String] = []
    private var failures = 0

    init(controller: DocumentWindowController, name: String) {
        self.controller = controller
        self.name = name
    }

    private var pages: PagesView { controller.pages }
    private var design: PrepareForm { controller.design }
    private var editor: DocumentEditor { controller.editor }

    private mutating func check(_ ok: Bool, _ what: String) {
        lines.append("\(ok ? "PASS" : "FAIL") \(what)")
        Report.progress("[\(controller.pdf.recoveryId.prefix(4))] \(lines[lines.count - 1])")
        if !ok { failures += 1 }
    }

    private func mouse(_ type: NSEvent.EventType, _ p: PointD, clicks: Int = 1) -> NSEvent {
        let view = pages.viewPoint(p, pages.pageRects[0])
        return NSEvent.mouseEvent(with: type, location: pages.convert(view, to: nil), modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: controller.window?.windowNumber ?? 0,
                                  context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func click(_ p: PointD, clicks: Int = 1) async {
        pages.mouseDown(with: mouse(.leftMouseDown, p, clicks: clicks))
        pages.mouseUp(with: mouse(.leftMouseUp, p, clicks: clicks))
        await design.settle()
    }

    private func drag(_ a: PointD, _ b: PointD) async {
        pages.mouseDown(with: mouse(.leftMouseDown, a))
        pages.mouseDragged(with: mouse(.leftMouseDragged, PointD((a.x + b.x) / 2, (a.y + b.y) / 2)))
        pages.mouseDragged(with: mouse(.leftMouseDragged, b))
        pages.mouseUp(with: mouse(.leftMouseUp, b))
        await design.settle()
    }

    private func key(_ code: UInt16, _ chars: String = "", _ flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                         windowNumber: controller.window?.windowNumber ?? 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: code)!
    }

    private func press(_ code: UInt16, _ flags: NSEvent.ModifierFlags = []) async {
        pages.keyDown(with: key(code, "", flags))
        await design.settle()
    }

    private func pick(_ segment: Int) {
        design.toolControl.selectedSegment = segment
        design.toolControl.sendAction(design.toolControl.action, to: design.toolControl.target)
    }

    private func type(_ field: NSTextField, _ text: String) async {
        field.stringValue = text
        field.sendAction(field.action, to: field.target)
        await design.settle()
    }

    private func toggle(_ box: NSButton) async {
        box.state = box.state == .on ? .off : .on
        box.sendAction(box.action, to: box.target)
        await design.settle()
    }

    private func choose(_ popup: NSPopUpButton, _ index: Int) async {
        popup.selectItem(at: index)
        popup.sendAction(popup.action, to: popup.target)
        await design.settle()
    }

    /// With `--snapshots`: a PNG of the window, as AppKit draws it.
    private func snapshot(_ file: String) {
        guard let dir = Report.snapshots, let view = controller.window?.contentView else { return }
        view.layoutSubtreeIfNeeded()
        pages.displayIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(file))
    }

    private func saved() -> [DesignField] {
        guard let s = controller.pdf.session else { return [] }
        return (try? FormDesign.read(s.data, s.password)) ?? []
    }

    private func widgets() -> [FormWidget] {
        guard let s = controller.pdf.session else { return [] }
        return (try? FormEditor.read(s.data, s.password)) ?? []
    }

    private func field(_ name: String) -> DesignField? { saved().first { $0.name == name } }

    mutating func run() async {
        lines.append("== prepare form \(name)")
        guard let start = controller.pdf.session?.data else { return finish() }
        let window = controller.window

        // In, through the menu's command.
        controller.togglePrepareForm(nil)
        for _ in 0..<200 where !design.isDesigning { try? await Task.sleep(for: .milliseconds(10)) }
        await design.settle()
        check(design.isDesigning && !design.bar.isHidden && !design.panelItem.isCollapsed && !design.hintLabel.isHidden,
              "Tools › Prepare Form shows the bar, the panel and the hint")
        snapshot("prepare-form-hint.png")

        // Each kind. A drag with the Text tool, a click for the others; each is one undo step, then back to selecting.
        let edits = editor.finishedEdits
        pick(1)
        await drag(PointD(72, 72), PointD(272, 94))
        check(design.toolControl.selectedSegment == 0 && field("Text1")?.rect.width.rounded() == 200 && design.model.selectedField?.name == "Text1"
                && design.titleLabel.stringValue == "Text field · page 1" && !design.fieldGroup.isHidden,
              "a drag places a text field, selects it and fills the panel")
        pick(2)
        await click(PointD(72, 110))
        pick(3)
        await click(PointD(72, 140))
        pick(3) // with a radio button selected, the next one joins its group
        await click(PointD(100, 140))
        pick(4)
        await click(PointD(72, 170))
        pick(5)
        await click(PointD(72, 200))
        pick(6)
        await click(PointD(72, 270))
        pick(7)
        await click(PointD(300, 270))
        let all = saved()
        check(all.count == 8 && editor.finishedEdits == edits + 8, "eight fields in eight edits: \(all.map(\.name).joined(separator: ", "))")
        let group = all.filter { $0.kind == .radio }
        check(group.count == 2 && group[0].name == group[1].name && group[0].exportValue != group[1].exportValue, "the second radio button joined the group with its own value")
        let sizes = field("Signature1")?.rect
        check(sizes?.width == 180 && sizes?.height == 40 && field("Check Box1")?.rect.width == 14, "a click makes the kind's usual size")

        // The panel: a text field.
        await click(PointD(150, 80))
        check(design.model.selectedField?.name == "Text1", "a click selects a field")
        snapshot("prepare-form-text.png")
        await type(design.nameField, "Full name")
        check(field("Full name") != nil && design.model.selectedField?.name == "Full name", "Name renames it, and it stays selected")
        await type(design.tooltipField, "Your name")
        await toggle(design.requiredBox)
        await toggle(design.multilineBox)
        await type(design.maxLengthField, "40")
        await choose(design.formatPopup, 3) // currency
        await type(design.defaultField, "1234.5")
        var f = field("Full name")
        let currency = FieldFormat(.number, decimals: 2, currency: "$", currencyPrepend: true)
        check(f?.tooltip == "Your name" && f?.required == true && f?.multiline == true && f?.maxLength == 40 && f?.format == currency && f?.defaultValue == "1234.5",
              "tooltip, required, multi-line, most characters, format and default reach the file")
        check(widgets().first { $0.fieldName == "Full name" }?.displayValue == "$1,234.50", "the format shows in what a filler reads")
        await choose(design.formatPopup, 0)
        await type(design.defaultField, "")
        await toggle(design.multilineBox)
        await choose(design.alignPopup, 2)
        await choose(design.borderPopup, 3)
        await choose(design.fillPopup, 4)
        design.sizeCombo.stringValue = "14"
        design.sizeCombo.sendAction(design.sizeCombo.action, to: design.sizeCombo.target)
        await design.settle()
        f = field("Full name")
        check(f?.alignment == 2 && f?.fontSize == 14 && f?.borderColor == AnnotColor(0.1, 0.35, 0.8) && f?.fillColor == AnnotColor(1, 0.98, 0.8) && f?.format == nil,
              "alignment, size, border and fill reach the file; the format is gone")

        // What the panel refuses.
        let before = editor.finishedEdits
        await type(design.nameField, "Check Box1")
        check(!design.errorLabel.isHidden && editor.finishedEdits == before && field("Full name") != nil, "a name in use is refused in the panel, no edit: \(design.errorLabel.stringValue)")
        design.nameField.stringValue = "Full name"
        await type(design.maxLengthField, "many")
        check(!design.errorLabel.isHidden && editor.finishedEdits == before, "a length that isn't a number is refused")
        design.maxLengthField.stringValue = "40"

        // Choices, a dropdown's default.
        await click(PointD(100, 180))
        check(design.model.selectedField?.kind == .comboBox && !design.choicesGroup.isHidden && !design.editableBox.isHidden && design.multiSelectBox.isHidden, "a dropdown shows its choices")
        design.choicesView.string = "Gold = g\nSilver = s\nBronze"
        design.choicesCommitted()
        await design.settle()
        f = field("Dropdown1")
        check(f?.options == ["g", "s", "Bronze"] && f?.shownOptions == ["Gold", "Silver", "Bronze"] && design.defaultChoice.numberOfItems == 4, "choices with their shown text")
        await choose(design.defaultChoice, 2)
        await toggle(design.editableBox)
        snapshot("prepare-form-dropdown.png")
        f = field("Dropdown1")
        check(f?.defaultValue == "s" && f?.editable == true && widgets().first { $0.fieldName == "Dropdown1" }?.value == "s", "its default is what the form starts with")

        // A list box.
        await click(PointD(100, 220))
        await toggle(design.multiSelectBox)
        check(field("List Box1")?.multiSelect == true, "a list box takes several")

        // A push button.
        await click(PointD(320, 280))
        check(!design.buttonGroup.isHidden && design.requiredBox.isHidden, "a button shows its label and action")
        await type(design.captionField, "Print it")
        await choose(design.actionPopup, 2)
        snapshot("prepare-form-button.png")
        check(field("Button1")?.caption == "Print it" && field("Button1")?.action == .print && widgets().first { $0.fieldName == "Button1" }?.triggers.contains(.up) == true, "the label and the print action")

        // A check box and a radio button.
        await click(PointD(78, 116))
        check(!design.exportGroup.isHidden && design.defaultCheck.title == "Checked by default", "a check box shows its value")
        await type(design.exportField, "Agreed")
        await toggle(design.defaultCheck)
        f = field("Check Box1")
        check(f?.exportValue == "Agreed" && f?.defaultValue == "Agreed" && widgets().first { $0.fieldName == "Check Box1" }?.value == "Agreed", "its value, checked by default")
        await click(PointD(78, 146))
        let other = saved().first { $0.kind == .radio && $0.id != design.model.selectedId }?.exportValue ?? ""
        let clash = editor.finishedEdits
        await type(design.exportField, other)
        check(!design.errorLabel.isHidden && editor.finishedEdits == clash, "a radio button can't take another's value")
        await type(design.exportField, "First")
        await toggle(design.defaultCheck)
        check(widgets().first { $0.onState == "First" }?.value == "First", "a radio button selected by default")

        // Moving and resizing: one edit each.
        await click(PointD(150, 80))
        var moves = editor.finishedEdits
        await drag(PointD(150, 80), PointD(160, 100))
        var r = field("Full name")?.rect
        check(editor.finishedEdits == moves + 1 && r?.x.rounded() == 82 && r?.y.rounded() == 92, "a drag moves the field in one edit")
        moves = editor.finishedEdits
        await drag(PointD(282, 114), PointD(322, 134)) // the bottom-right handle
        r = field("Full name")?.rect
        check(editor.finishedEdits == moves + 1 && r?.width.rounded() == 240 && r?.height.rounded() == 42, "a handle resizes the field: \(r.map { "\($0.width)x\($0.height)" } ?? "none")")

        // Keys: nudges are written once, Tab goes on, Return opens the properties, Esc lets go.
        moves = editor.finishedEdits
        await press(126) // up
        await press(124) // right
        await press(124, .shift)
        check(editor.finishedEdits == moves, "the arrows wait for the keys to rest")
        design.flushNudge()
        await design.settle()
        r = field("Full name")?.rect
        check(editor.finishedEdits == moves + 1 && r?.x.rounded() == 93 && r?.y.rounded() == 91, "then write one move (1 up, 1 right, 10 right)")
        let selected = design.model.selectedId
        await press(48)
        check(design.model.selectedId != selected && design.model.selectedId != nil, "Tab goes to the next field")
        await press(48, .shift)
        check(design.model.selectedId == selected, "Shift-Tab comes back")
        await press(36)
        check(design.nameField.currentEditor() != nil, "Return opens the properties, the name ready to type")
        window?.makeFirstResponder(pages)

        // ⌘D and Delete.
        let count = saved().count
        check(pages.performKeyEquivalent(with: key(2, "d", .command)), "⌘D is Prepare Form's while a field is selected")
        await design.settle()
        check(saved().count == count + 1 && field("Full name_2") != nil && design.model.selectedField?.name == "Full name_2", "⌘D duplicates and selects the copy")
        await press(51)
        check(saved().count == count && field("Full name_2") == nil, "Delete removes it")

        // Tab order.
        await click(PointD(320, 280))
        let tab = design.model.selectedField?.tabIndex ?? 0
        design.earlierButton.performClick(nil)
        await design.settle()
        check(design.model.selectedField?.tabIndex == tab - 1 && design.model.showTabOrder && design.tabOrderButton.state == .on, "Tab Earlier moves it in the fill order and shows the numbers")

        // Undo and redo, one step each.
        controller.pdf.undo()
        await design.settle()
        check(design.model.selectedField?.tabIndex == tab, "undo takes back the last edit, and the fields follow")
        controller.pdf.redo()
        await design.settle()
        check(design.model.selectedField?.tabIndex == tab - 1, "redo brings it back")

        // Suggestions, as found (the document needn't have blanks), then a real look at every page.
        await design.detectFields()
        await design.settle()
        lines.append("note: Detect Fields found \(design.model.suggestions.count) on this document")
        func suggestion(_ name: String, _ y: Double, _ kind: DesignFieldKind = .text) -> FieldSuggestion {
            FieldSuggestion(pageIndex: 0, rect: RectD(72, y, 150, 20), kind: kind, name: name, multiline: false, source: "line")
        }
        design.showSuggestions([suggestion("Alpha", 330), suggestion("Beta", 360), suggestion("Gamma", 390), suggestion("Delta", 420)])
        check(!design.allGroup.isHidden && design.suggestionCount.stringValue.hasPrefix("4 suggested"), "suggestions show in the panel")
        design.selectSuggestion(0)
        snapshot("prepare-form-suggestions.png")
        design.selectSuggestion(-1)
        await click(PointD(100, 340))
        check(design.model.selectedSuggestion?.name == "Alpha" && !design.suggestionGroup.isHidden && design.suggestionSource.stringValue == "Found from a line to write on.", "a click selects one")
        await type(design.suggestionName, "Alpha two")
        await choose(design.suggestionKind, 1)
        check(design.model.selectedSuggestion?.name == "Alpha two" && design.model.selectedSuggestion?.multiline == true, "its name and kind can change")
        await press(36) // Return adds it and goes on
        check(field("Alpha two")?.multiline == true && design.model.suggestions.count == 3 && design.model.selectedSuggestion?.name == "Beta", "Return adds it and goes on with the next")
        await press(51) // Delete skips it
        check(field("Beta") == nil && design.model.suggestions.count == 2 && design.model.selectedSuggestion?.name == "Gamma", "Delete skips one")
        let adds = editor.finishedEdits
        design.acceptAllButton.performClick(nil)
        await design.settle()
        check(field("Gamma") != nil && field("Delta") != nil && design.model.suggestions.isEmpty && editor.finishedEdits == adds + 1 && design.allGroup.isHidden, "Add All takes the rest as one edit")

        // The saved bytes, filled, and a copy kept for other apps.
        if let s = controller.pdf.session {
            let values = ["Full name": "Ada Lovelace", "Check Box1": "Agreed", "Dropdown1": "g"]
            let text = (try? FormEditor.setValues(s.data, s.password, values)).map { filled -> String in
                let read = (try? FormEditor.read(filled, s.password)) ?? []
                return read.filter { values[$0.fieldName] != nil }.map(\.value).sorted().joined(separator: "|")
            }
            check(text == "Ada Lovelace|Agreed|g", "the form fills: \(text ?? "failed")")
            let copy = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("inkvolt-prepared-form.pdf")
            try? Data(s.data).write(to: copy)
            lines.append("note: a copy of the form is at \(copy.path)")
        }

        // Esc lets go step by step; Done leaves.
        pick(1)
        await press(53)
        check(design.model.kind == nil && design.isDesigning, "Esc drops the field tool")
        await click(PointD(150, 100))
        await press(53)
        check(design.model.selectedId == nil && design.isDesigning, "then lets go of the field")
        await press(53)
        check(!design.isDesigning && design.bar.isHidden && design.panelItem.isCollapsed, "then leaves Prepare Form")

        // Back as it was.
        var steps = 0
        while controller.pdf.session?.data != start && steps < 300 {
            controller.pdf.undo()
            steps += 1
        }
        check(controller.pdf.session?.data == start, "\(steps) undo steps bring the document back")
        finish()
    }

    private mutating func finish() {
        lines.append("RESULT: \(failures == 0 ? "PASS" : "FAIL") (\(lines.filter { $0.hasPrefix("PASS") }.count) passed, \(failures) failed)")
        Report.write(lines.joined(separator: "\n"))
    }
}
