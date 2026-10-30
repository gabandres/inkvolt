import AppKit
import PdfCore

/// Tools › Prepare Form (the Windows app's `DocumentTab.FormDesign` and `PageViewer.FormDesign`): the field tools bar over the
/// pages, the properties panel on the right and field suggestions, around the page view's `Tool.prepareForm`. The rules of
/// clicks, drags, keys and typed values are PdfCore's `FormDesigner` and `FormDesignRules`; this class shows them and turns
/// each gesture into one edit through `DocumentEditor.run` (one undo step, signed files appended to with the usual question,
/// protected files kept protected). Free, as on Windows: no `Pro.allows`.
@MainActor
final class PrepareForm: NSObject, NSTextFieldDelegate, NSTextDelegate, NSTextViewDelegate {
    private(set) weak var controller: DocumentWindowController?
    private(set) var model = FormDesigner()
    /// The engine the shown fields were read from (positional ids refer to its bytes).
    private var readFrom: ObjectIdentifier?
    private var ticket = 0
    private var wasOn = false
    private var selectAfter: String?
    private var suggestionPages = -1
    private var nudgeTimer: Timer?
    /// The read and the edit in progress (the self-test awaits them).
    private var load: Task<Void, Never>?
    private var lastEdit: Task<Void, Never>?

    // The bar.
    let bar = PrepareFormBar()
    let toolControl = NSSegmentedControl()
    let detectButton = NSButton(title: "Detect Fields", target: nil, action: nil)
    let tabOrderButton = NSButton(title: "Tab Order", target: nil, action: nil)
    let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private static let tools: [(kind: DesignFieldKind?, label: String, symbol: String)] = [
        (nil, "Select", "cursorarrow"), (.text, "Text field", "character.textbox"), (.checkBox, "Check box", "checkmark.square"),
        (.radio, "Radio button", "smallcircle.filled.circle"), (.comboBox, "Dropdown", "chevron.down.square"), (.listBox, "List box", "list.bullet.rectangle"),
        (.signature, "Signature field", "signature"), (.button, "Button", "button.programmable"),
    ]

    // The panel.
    let panelController = NSViewController()
    private(set) var panelItem: NSSplitViewItem!
    let titleLabel = NSTextField(labelWithString: "Prepare Form")
    let hintLabel = NSTextField(wrappingLabelWithString: "Pick a field kind above, then drag on the page or click for the usual size. Click a field to select it: drag to move it, drag a handle to resize it, arrow keys nudge it (Shift: 10 pt), Tab goes from field to field, Delete removes it, ⌘D duplicates it, Return opens its properties, Esc lets go.")
    let errorLabel = NSTextField(wrappingLabelWithString: "")
    let fieldGroup = NSStackView()
    let nameField = NSTextField()
    let tooltipField = NSTextField()
    let requiredBox = NSButton(checkboxWithTitle: "Required", target: nil, action: nil)
    let readOnlyBox = NSButton(checkboxWithTitle: "Read-only", target: nil, action: nil)
    let textGroup = NSStackView()
    let multilineBox = NSButton(checkboxWithTitle: "Multi-line", target: nil, action: nil)
    let maxLengthField = NSTextField()
    let formatPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let choicesGroup = NSStackView()
    let choicesView = NSTextView()
    let editableBox = NSButton(checkboxWithTitle: "Typing a value of your own is allowed", target: nil, action: nil)
    let multiSelectBox = NSButton(checkboxWithTitle: "Several can be selected", target: nil, action: nil)
    let exportGroup = NSStackView()
    let exportField = NSTextField()
    let buttonGroup = NSStackView()
    let captionField = NSTextField()
    let actionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let defaultTextRow = NSStackView()
    let defaultField = NSTextField()
    let defaultChoiceRow = NSStackView()
    let defaultChoice = NSPopUpButton(frame: .zero, pullsDown: false)
    let defaultCheck = NSButton(checkboxWithTitle: "Checked by default", target: nil, action: nil)
    let sizeCombo = NSComboBox()
    let alignPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let borderPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let fillPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let earlierButton = NSButton(title: "Tab Earlier", target: nil, action: nil)
    let laterButton = NSButton(title: "Tab Later", target: nil, action: nil)
    let duplicateButton = NSButton(title: "Duplicate", target: nil, action: nil)
    let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    let suggestionGroup = NSStackView()
    let suggestionName = NSTextField()
    let suggestionKind = NSPopUpButton(frame: .zero, pullsDown: false)
    let suggestionSource = NSTextField(wrappingLabelWithString: "")
    let acceptButton = NSButton(title: "Add Field", target: nil, action: nil)
    let rejectButton = NSButton(title: "Skip", target: nil, action: nil)
    let allGroup = NSStackView()
    let suggestionCount = NSTextField(wrappingLabelWithString: "")
    let acceptAllButton = NSButton(title: "Add All", target: nil, action: nil)
    let rejectAllButton = NSButton(title: "Skip All", target: nil, action: nil)

    init(controller: DocumentWindowController) {
        self.controller = controller
        super.init()
        buildBar()
        buildPanel()
        panelItem = NSSplitViewItem(inspectorWithViewController: panelController)
        panelItem.minimumThickness = 260
        panelItem.maximumThickness = 340
        panelItem.isCollapsed = true
        bar.isHidden = true
    }

    private var pages: PagesView { controller!.pages }
    private var editor: DocumentEditor { controller!.editor }
    var isDesigning: Bool { controller?.pages.tool == .prepareForm }

    // MARK: Entering and leaving

    /// Enters (asks about a hybrid XFA form first) or leaves Prepare Form. False when it didn't enter.
    @discardableResult
    func setDesigning(_ on: Bool) async -> Bool {
        guard let controller else { return false }
        if !on {
            if isDesigning { pages.tool = .text }
            return true
        }
        if isDesigning { return true }
        guard let session = controller.pdf.session else { return false }
        if controller.organizerShown { controller.toggleOrganizer(nil) }
        let data = session.data, password = session.password
        let (hasXfa, xfaOnly) = await Task.detached { (try? FormEditor.hasXfa(data, password)) ?? (false, false) }.value
        if xfaOnly {
            controller.pdf.showError("This form uses XFA: its fields are an XFA form, which Inkvolt PDF can't edit. Adobe Acrobat (Pro) can convert or edit it.", nil)
            return false
        }
        if hasXfa {
            let question = NSAlert()
            question.messageText = "Edit this form's fields?"
            question.informativeText = "This form also carries an XFA version, which Adobe Acrobat shows instead of the fields. Changing the fields here removes the XFA version, so every viewer shows the fields as you prepare them."
            question.addButton(withTitle: "Edit Fields")
            question.addButton(withTitle: "Cancel")
            guard let window = controller.window, await question.beginSheetModal(for: window) == .alertFirstButtonReturn else { return false }
        }
        pages.tool = .prepareForm
        controller.window?.makeFirstResponder(pages)
        return true
    }

    /// The page view's tool changed: the bar and the panel follow.
    func toolChanged() {
        let on = isDesigning
        if on != wasOn {
            wasOn = on
            bar.isHidden = !on
            panelItem.isCollapsed = !on
            if on {
                controller?.form.clearFocus()
                reload()
            } else {
                pages.window?.makeFirstResponder(pages) // what's being typed in the panel applies first
                flushNudge()
                model.reset()
                suggestionPages = -1
                tabOrderButton.state = .off
            }
        }
        toolControl.selectedSegment = Self.tools.firstIndex { $0.kind == model.kind } ?? 0
        pages.window?.invalidateCursorRects(for: pages)
        pages.needsDisplay = true
    }

    /// An edit, undo, redo or reload replaced the document: read the fields again.
    func contentChanged() {
        if isDesigning { reload() }
    }

    /// Reads the fields off the main thread (the latest request wins).
    private func reload() {
        guard let session = controller?.pdf.session else { return }
        ticket += 1
        let current = ticket
        let data = session.data, password = session.password, version = ObjectIdentifier(session.engine)
        load = Task { @MainActor [weak self] in
            let fields = await Task.detached { (try? FormDesign.read(data, password)) ?? [] }.value
            guard let self, current == self.ticket, self.isDesigning else { return }
            self.readFrom = version
            if self.suggestionPages >= 0 && self.suggestionPages != self.controller?.engine.pageCount {
                self.model.setSuggestions([]) // pages moved: they'd be in the wrong places
            } else if !self.model.suggestions.isEmpty {
                self.model.setSuggestions(FormDesignRules.stillSuggested(self.model.suggestions, fields: fields))
            }
            self.model.setFields(fields)
            if let id = self.selectAfter {
                self.selectAfter = nil
                if fields.contains(where: { $0.id == id }) { self.model.select(id) }
            }
            self.changed()
        }
    }

    private func isCurrent() -> Bool {
        guard let session = controller?.pdf.session else { return false }
        if readFrom == ObjectIdentifier(session.engine) { return true }
        controller?.notify("The fields are still being refreshed after the last change. Try again in a moment.")
        reload()
        return false
    }

    /// What the page and the panel show changed.
    private func changed() {
        showSelection()
        pages.needsDisplay = true
        pages.window?.invalidateCursorRects(for: pages)
    }

    /// Waits for the edit and the read in progress (the self-test).
    func settle() async {
        while let edit = lastEdit {
            await edit.value
            if lastEdit == edit { lastEdit = nil }
        }
        await pages.pendingEdit?.value
        await load?.value
    }

    // MARK: Edits

    private func track(_ work: @escaping @MainActor () async -> Void) {
        let previous = lastEdit
        lastEdit = Task { @MainActor in
            await previous?.value
            await self.load?.value // the fields as the last edit left them
            await work()
        }
    }

    private func add(_ label: String, _ fields: [DesignField], select: String?) async -> Bool {
        selectAfter = select
        let ok = await editor.run(label, contentOnly: true) { d, pw in try FormDesign.add(d, pw, fields) }
        if !ok { selectAfter = nil }
        return ok
    }

    private final class NewIds: @unchecked Sendable {
        var ids: [String: String] = [:]
    }

    /// Writes changed fields; when it isn't made, the fields show as the document has them (a dragged field goes back).
    private func update(_ label: String, _ changes: [DesignField]) async {
        guard isCurrent() else { return }
        let selected = model.selectedId
        selectAfter = selected
        let made = NewIds()
        let ok = await editor.run(label, contentOnly: true) { d, pw in
            var ids: [String: String] = [:]
            let result = try FormDesign.update(d, pw, changes, newIds: &ids)
            made.ids = ids
            return result
        }
        if let selected, let renamed = made.ids[selected] { selectNow(renamed, ifStill: selected) }
        if !ok && editor.lastOutcome != .noChange {
            selectAfter = nil
            model.dropPending()
            changed()
        }
    }

    /// A widget that got its id during the edit: select it under the new one (the read may have finished already).
    private func selectNow(_ id: String, ifStill old: String) {
        if model.fields.contains(where: { $0.id == id }) {
            if selectAfter == old || model.selectedId == nil {
                selectAfter = nil
                model.select(id)
                changed()
            }
        } else if selectAfter == old {
            selectAfter = id
        }
    }

    /// Writes the arrow-key moves made so far.
    func flushNudge() {
        nudgeTimer?.invalidate()
        nudgeTimer = nil
        guard let moved = model.flushNudge() else { return }
        pages.needsDisplay = true
        track { [weak self] in await self?.update("Move field", [moved]) }
    }

    func deleteSelected() {
        flushNudge()
        guard let f = model.selectedField, !f.signed, isCurrent() else { return }
        let next = FormDesignRules.nextField(after: f, in: model.fields)
        selectAfter = next
        track { [weak self] in
            guard let self else { return }
            let ok = await self.editor.run("Delete \(DesignField.kindName(f.kind).lowercased())", contentOnly: true) { d, pw in try FormDesign.delete(d, pw, [f.id]) }
            if !ok { self.selectAfter = nil }
        }
    }

    /// False when no field can be duplicated (⌘D then goes on to the menu's Add Bookmark).
    @discardableResult
    func duplicateSelected() -> Bool {
        flushNudge()
        guard let f = model.selectedField, !f.signed, isCurrent() else { return false }
        let g = pages.engine.page(f.pageIndex)
        let copy = FormDesignRules.duplicated(f, fields: model.fields, pageWidth: g.width, pageHeight: g.height)
        track { [weak self] in _ = await self?.add("Duplicate \(DesignField.kindName(f.kind).lowercased())", [copy], select: copy.id) }
        return true
    }

    func acceptSuggestions(_ picked: [FieldSuggestion]) {
        guard !picked.isEmpty, isCurrent() else { return }
        let fields = FormDesignRules.acceptedFields(picked, fields: model.fields)
        let index = model.selectedSuggestionIndex
        let label = fields.count == 1 ? "Add \(DesignField.kindName(fields[0].kind).lowercased())" : "Add \(fields.count) fields"
        track { [weak self] in
            guard let self, await self.editor.run(label, contentOnly: true, { d, pw in try FormDesign.add(d, pw, fields) }) else { return }
            let rest = self.model.suggestions.filter { !picked.contains($0) }
            self.model.setSuggestions(rest)
            // Reviewing one by one: go on with the next suggestion.
            if !rest.isEmpty && picked.count == 1 {
                self.selectSuggestion(min(max(index, 0), rest.count - 1), reveal: true)
            } else if picked.count == 1 {
                self.selectAfter = fields[0].id
                self.reload()
            }
            self.changed()
        }
    }

    func rejectSuggestion() {
        guard let s = model.selectedSuggestion else { return }
        let i = model.selectedSuggestionIndex
        let rest = model.suggestions.filter { $0 != s }
        model.setSuggestions(rest)
        if !rest.isEmpty { selectSuggestion(min(i, rest.count - 1), reveal: true) }
        changed()
    }

    private func replaceSuggestion(_ old: FieldSuggestion, _ updated: FieldSuggestion) {
        var list = model.suggestions
        guard let i = list.firstIndex(of: old) else { return }
        list[i] = updated
        model.setSuggestions(list)
        model.selectSuggestion(i)
        changed()
    }

    /// For the self-test: suggestions as if found.
    func showSuggestions(_ list: [FieldSuggestion]) {
        suggestionPages = controller?.engine.pageCount ?? -1
        model.setSuggestions(list)
        changed()
    }

    func selectSuggestion(_ index: Int, reveal: Bool = false) {
        flushNudge()
        model.selectSuggestion(index)
        if reveal, let s = model.selectedSuggestion { self.reveal(s.pageIndex, s.rect) }
        changed()
    }

    private func reveal(_ page: Int, _ rect: RectD) {
        guard page < pages.pageRects.count else { return }
        pages.scrollToVisible(pages.viewRect(rect, pages.pageRects[page]).insetBy(dx: -40, dy: -40))
    }

    /// Looks for fields on every page (in the background, with Cancel) and shows what it finds as suggestions.
    func detectFields() async {
        guard let controller, isDesigning, controller.progressSheet == nil, isCurrent(), let session = controller.pdf.session else { return }
        let engine = session.engine, data = session.data, password = session.password
        let existing = model.fields
        let pageList = Array(0..<engine.pageCount)
        let sheet = ProgressSheet(title: "Detect Fields", text: "Looking for fields…")
        sheet.begin(on: controller.window)
        controller.progressSheet = sheet
        let token = sheet.token
        let result = await Task.detached { () -> Result<[FieldSuggestion], Error> in
            Result {
                try FieldDetection.suggest(engine, data, password, pageList, existing, cancel: token) { done, total in
                    Task { @MainActor in sheet.update("Looking at page \(done + 1) of \(total)…", Double(done) / Double(total)) }
                }
            }
        }.value
        sheet.end()
        controller.progressSheet = nil
        guard isDesigning, controller.pdf.session?.engine === engine else { return }
        let found: [FieldSuggestion]
        switch result {
        case .success(let list):
            found = list
        case .failure(let error):
            if !(error is CancellationError) { controller.notify("Couldn't look for fields: the document changed meanwhile. Try again.") }
            return
        }
        suggestionPages = engine.pageCount
        model.setSuggestions(found)
        changed()
        if found.isEmpty {
            controller.notify("No fields found. Inkvolt PDF looks for lines to write on, empty boxes, small squares and runs of underscores.")
            return
        }
        // Start on the current page's first suggestion, else the first one.
        selectSuggestion(found.firstIndex { $0.pageIndex >= pages.currentPage } ?? 0, reveal: true)
        controller.window?.makeFirstResponder(pages)
        controller.notify("Found \(found.count) possible field\(found.count == 1 ? "" : "s") (dashed): Return adds one, Delete skips it, or add them all from the panel.")
    }

    func moveInTabOrder(_ step: Int) {
        flushNudge()
        guard let f = model.selectedField, isCurrent() else { return }
        let ids: [String]
        switch FormDesignRules.tabOrder(moving: f, by: step, in: model.fields) {
        case .success(let order): ids = order
        case .failure(let refusal):
            controller?.notify(refusal.message)
            return
        }
        let page = f.pageIndex, made = NewIds()
        selectAfter = f.id
        track { [weak self] in
            guard let self else { return }
            let ok = await self.editor.run("Change tab order", contentOnly: true) { d, pw in
                var fresh: [String: String] = [:]
                let result = try FormDesign.setTabOrder(d, pw, page, ids, newIds: &fresh)
                made.ids = fresh
                return result
            }
            if let renamed = made.ids[f.id] { self.selectNow(renamed, ifStill: f.id) }
            if !ok { self.selectAfter = nil }
            self.tabOrderButton.state = .on
            self.model.showTabOrder = true
            self.pages.needsDisplay = true
        }
    }

    // MARK: The page view's gestures

    private var reach: Double { Double(5 + 3) * Double(pages.onePixel) }

    /// A press on the page. `.pan` starts scrolling, which the page view does.
    func press(_ page: Int, _ p: PointD, clicks: Int) -> DesignPress {
        flushNudge()
        let before = model.selectedId
        let g = pages.engine.page(page)
        let result = model.press(page, p, clicks: clicks, reach: reach, pageWidth: g.width, pageHeight: g.height)
        if model.selectedId != before { selectAfter = nil } // the click chose; an edit under way doesn't choose again
        changed()
        switch result {
        case .properties:
            focusProperties()
        case .accept:
            if let s = model.selectedSuggestion { acceptSuggestions([s]) }
        case .none, .pan:
            break
        }
        return result
    }

    func dragged(_ point: NSPoint, shift: Bool) {
        guard let page = model.pressPage else { return }
        model.dragged(to: pages.pagePoint(point, on: page), shift: shift, threshold: 2 * Double(pages.onePixel))
        pages.needsDisplay = true
    }

    func released() {
        switch model.release() {
        case .placed(let placement):
            guard isCurrent() else { break }
            let field = FormDesignRules.placedField(placement, fields: model.fields, selected: model.selectedField)
            model.kind = nil // back to selecting: the new field's properties show
            toolChanged()
            track { [weak self] in _ = await self?.add("Add \(DesignField.kindName(placement.kind).lowercased())", [field], select: field.id) }
        case .moved(let field):
            track { [weak self] in await self?.update("Move field", [field]) }
        case nil:
            break
        }
        changed()
    }

    /// Prepare Form's keys; false when it isn't one of them.
    func handleKey(_ event: NSEvent) -> Bool {
        let mods = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let plain = mods.isEmpty, shiftOnly = mods == .shift
        let field = model.selectedField, suggestion = model.selectedSuggestion
        switch event.keyCode {
        case 48 where plain || shiftOnly: // Tab
            flushNudge()
            if let shown = model.step(shiftOnly ? -1 : 1) { reveal(shown.page, shown.rect) }
            changed()
            return true
        case 51 where plain, 117 where plain: // Delete
            guard field?.signed == false || suggestion != nil else { return false }
            if field != nil { deleteSelected() } else { rejectSuggestion() }
            return true
        case 36 where plain, 76 where plain: // Return
            guard field != nil || suggestion != nil else { return false }
            flushNudge()
            if field != nil {
                focusProperties()
            } else if let suggestion {
                acceptSuggestions([suggestion])
            }
            return true
        case 123 where plain || shiftOnly, 124 where plain || shiftOnly, 125 where plain || shiftOnly, 126 where plain || shiftOnly: // Arrows
            guard let field, !field.signed else { return false }
            let step = shiftOnly ? 10.0 : 1.0
            let move: (Double, Double) = event.keyCode == 123 ? (-step, 0) : event.keyCode == 124 ? (step, 0) : event.keyCode == 126 ? (0, -step) : (0, step)
            let g = pages.engine.page(field.pageIndex)
            model.nudge(move.0, move.1, pageWidth: g.width, pageHeight: g.height)
            nudgeTimer?.invalidate()
            nudgeTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.flushNudge() }
            }
            pages.needsDisplay = true
            return true
        case 53 where plain: // Esc
            flushNudge()
            if model.escape() == .leave { pages.tool = .text } else { toolChanged() }
            changed()
            return true
        default:
            return false
        }
    }

    // MARK: Drawing on the page

    private static let suggestionColor = NSColor(srgbRed: 0.85, green: 0.42, blue: 0, alpha: 1)

    /// Every field as a named box, suggestions dashed, the box being drawn, handles and Tab numbers (all the same size at any zoom).
    func draw(_ page: Int, _ r: NSRect) {
        let px = pages.onePixel
        let accent = NSColor.controlAccentColor
        let fill = NSColor(srgbRed: 0.125, green: 0.44, blue: 0.88, alpha: 0.15)
        let labelSize = min(max(9 / px, 8), 12) * px

        for f in model.fields(onPage: page) {
            let box = pages.viewRect(model.shownRect(f), r)
            let selected = f.id == model.selectedId
            let path = f.kind == .radio ? NSBezierPath(ovalIn: box) : NSBezierPath(rect: box)
            fill.setFill()
            path.fill()
            accent.setStroke()
            path.lineWidth = (selected ? 2 : 1) * px
            path.stroke()
            if f.kind == .radio {
                let frame = NSBezierPath(rect: box)
                frame.lineWidth = (selected ? 2 : 1) * px
                frame.stroke()
            }
            let toggle = f.kind == .checkBox || f.kind == .radio
            // Small boxes are named only when selected (their names would cover the page's text).
            if !toggle {
                label(f.name, box, accent, labelSize, inside: true)
            } else if selected {
                label(f.kind == .radio ? "\(f.name): \(f.exportValue)" : f.name, box, accent, labelSize, inside: false)
            }
            if model.showTabOrder { tabBadge(f.tabIndex + 1, box, accent, px) }
            guard selected, !f.signed else { continue }
            let frame = RectD(Double(box.minX), Double(box.minY), Double(box.width), Double(box.height))
            let size = 7 * px
            for i in 0..<8 {
                let h = DrawingGeometry.handlePoint(frame, i)
                let handle = NSBezierPath(roundedRect: NSRect(x: CGFloat(h.x) - size / 2, y: CGFloat(h.y) - size / 2, width: size, height: size), xRadius: 2 * px, yRadius: 2 * px)
                NSColor.textBackgroundColor.setFill()
                handle.fill()
                accent.setStroke()
                handle.lineWidth = 1.5 * px
                handle.stroke()
            }
        }

        for (i, s) in model.suggestions.enumerated() where s.pageIndex == page {
            let box = pages.viewRect(s.rect, r)
            let selected = i == model.selectedSuggestionIndex
            Self.suggestionColor.withAlphaComponent(0.19).setFill()
            box.fill(using: .sourceOver)
            Self.suggestionColor.setStroke()
            let path = NSBezierPath(rect: box)
            path.lineWidth = (selected ? 2.5 : 1.5) * px
            if !selected { path.setLineDash([4 * px, 3 * px], count: 2, phase: 0) }
            path.stroke()
            let toggle = s.kind == .checkBox || s.kind == .radio
            if !toggle || selected { label(s.name, box, Self.suggestionColor, labelSize, inside: !toggle) }
        }

        if let new = model.newBox, new.page == page {
            let box = pages.viewRect(new.rect, r)
            accent.withAlphaComponent(0.15).setFill()
            box.fill(using: .sourceOver)
            accent.setStroke()
            let path = NSBezierPath(rect: box)
            path.lineWidth = px
            path.stroke()
        }
    }

    /// A field's name: inside its box at the top-left when it fits, else just above it.
    private func label(_ text: String, _ box: NSRect, _ color: NSColor, _ size: CGFloat, inside: Bool) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size), .foregroundColor: color, .paragraphStyle: style]
        let height = ceil(("Ag" as NSString).size(withAttributes: attributes).height)
        let width = max(20 * size / 9, inside ? box.width - 4 * size / 9 : 200 * size / 9)
        let y = inside && height <= box.height - size / 9 ? box.minY + size / 9 : box.minY - height - size / 9
        let x = inside && height <= box.height - size / 9 ? box.minX + 2 * size / 9 : box.minX
        (text as NSString).draw(in: NSRect(x: x, y: y, width: width, height: height), withAttributes: attributes)
    }

    private func tabBadge(_ n: Int, _ box: NSRect, _ accent: NSColor, _ px: CGFloat) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10 * px, weight: .semibold), .foregroundColor: NSColor.white]
        let text = String(n) as NSString
        let size = text.size(withAttributes: attributes)
        // Left of the field's top-left corner, clear of the selection handles.
        let d = max(16 * px, size.width + 8 * px)
        let center = NSPoint(x: box.minX - d / 2 - 3 * px, y: box.minY + min(8 * px, box.height / 2))
        accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: center.x - d / 2, y: center.y - 8 * px, width: d, height: 16 * px), xRadius: 8 * px, yRadius: 8 * px).fill()
        text.draw(at: NSPoint(x: center.x - size.width / 2, y: center.y - size.height / 2), withAttributes: attributes)
    }

    /// What the pointer shows over the fields (cursor rectangles for the page view's `resetCursorRects`).
    func addCursorRects(to view: PagesView) {
        for r in view.pageRects { view.addCursorRect(r, cursor: model.kind != nil ? .crosshair : .arrow) }
        if model.kind == nil {
            for s in model.suggestions where s.pageIndex < view.pageRects.count {
                view.addCursorRect(view.viewRect(s.rect, view.pageRects[s.pageIndex]), cursor: .pointingHand)
            }
            for f in model.fields where f.pageIndex < view.pageRects.count && !f.signed {
                view.addCursorRect(view.viewRect(model.shownRect(f), view.pageRects[f.pageIndex]), cursor: .openHand)
            }
        }
        guard let f = model.selectedField, !f.signed, f.pageIndex < view.pageRects.count else { return }
        let positions: [NSCursor.FrameResizePosition] = [.topLeft, .top, .topRight, .right, .bottomRight, .bottom, .bottomLeft, .left]
        let frame = model.shownRect(f)
        let page = view.pageRects[f.pageIndex]
        let reach = CGFloat(self.reach)
        for (i, position) in positions.enumerated() {
            let h = view.viewPoint(DrawingGeometry.handlePoint(frame, i), page)
            view.addCursorRect(NSRect(x: h.x - reach, y: h.y - reach, width: 2 * reach, height: 2 * reach), cursor: NSCursor.frameResize(position: position, directions: .all))
        }
    }

    // MARK: The bar

    private func buildBar() {
        toolControl.segmentStyle = .automatic
        toolControl.trackingMode = .selectOne
        toolControl.segmentCount = Self.tools.count
        for (i, tool) in Self.tools.enumerated() {
            if let image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: tool.label) {
                toolControl.setImage(image, forSegment: i)
            } else {
                toolControl.setLabel(tool.label, forSegment: i)
            }
            toolControl.setToolTip(tool.kind == nil ? "Select and move fields" : "Add a \(tool.label.lowercased()): drag on the page, or click for the usual size", forSegment: i)
        }
        toolControl.selectedSegment = 0
        toolControl.setAccessibilityLabel("Prepare form tools")
        toolControl.target = self
        toolControl.action = #selector(toolPicked(_:))
        detectButton.toolTip = "Look at every page for lines to write on, empty boxes, small squares and runs of underscores"
        detectButton.target = self
        detectButton.action = #selector(detectClicked(_:))
        tabOrderButton.setButtonType(.pushOnPushOff)
        tabOrderButton.toolTip = "Number each field with its place in the order Tab fills them"
        tabOrderButton.target = self
        tabOrderButton.action = #selector(tabOrderClicked(_:))
        doneButton.toolTip = "Leave Prepare Form"
        doneButton.keyEquivalent = ""
        doneButton.target = self
        doneButton.action = #selector(doneClicked(_:))
        for b in [detectButton, tabOrderButton, doneButton] { b.bezelStyle = .rounded }
        let title = NSTextField(labelWithString: "Prepare Form")
        title.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let stack = NSStackView(views: [title, toolControl, detectButton, tabOrderButton, spacer, doneButton])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10)
        stack.translatesAutoresizingMaskIntoConstraints = false
        bar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: bar.leadingAnchor), stack.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
            stack.topAnchor.constraint(equalTo: bar.topAnchor), stack.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        ])
    }

    @objc func toolPicked(_ sender: NSSegmentedControl) {
        model.kind = Self.tools[max(sender.selectedSegment, 0)].kind
        toolChanged()
        controller?.window?.makeFirstResponder(pages)
    }

    @objc func detectClicked(_ sender: Any?) { track { [weak self] in await self?.detectFields() } }

    @objc func tabOrderClicked(_ sender: NSButton) {
        model.showTabOrder = sender.state == .on
        pages.needsDisplay = true
    }

    @objc func doneClicked(_ sender: Any?) { pages.tool = .text }

    // MARK: The panel

    private func small(_ title: String) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func column(_ views: [NSView], spacing: CGFloat = 8, in stack: NSStackView = NSStackView()) -> NSStackView {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        for v in views { stack.addArrangedSubview(v) }
        return stack
    }

    /// A control with its small title above it, as wide as the panel.
    private func row(_ title: String, _ control: NSView, in stack: NSStackView = NSStackView()) -> NSStackView {
        control.setAccessibilityLabel(title)
        let r = column([small(title), control], spacing: 3, in: stack)
        control.widthAnchor.constraint(equalTo: r.widthAnchor).isActive = true
        return r
    }

    private func wire(_ field: NSTextField, _ action: Selector) {
        field.target = self
        field.action = action
        field.delegate = self
        field.cell?.sendsActionOnEndEditing = true
        field.lineBreakMode = .byTruncatingTail
    }

    private func wire(_ control: NSControl, _ action: Selector) {
        control.target = self
        control.action = action
    }

    private func buildPanel() {
        titleLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        hintLabel.textColor = .secondaryLabelColor
        hintLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.textColor = .systemRed
        errorLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        errorLabel.isHidden = true
        suggestionSource.textColor = .secondaryLabelColor
        suggestionSource.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        suggestionCount.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        wire(nameField, #selector(nameChanged))
        wire(tooltipField, #selector(tooltipChanged))
        wire(maxLengthField, #selector(maxLengthChanged))
        wire(exportField, #selector(exportChanged))
        wire(captionField, #selector(captionChanged))
        wire(defaultField, #selector(defaultChanged))
        wire(suggestionName, #selector(suggestionNameChanged))
        wire(requiredBox, #selector(requiredChanged))
        wire(readOnlyBox, #selector(readOnlyChanged))
        wire(multilineBox, #selector(multilineChanged))
        wire(editableBox, #selector(editableChanged))
        wire(multiSelectBox, #selector(multiSelectChanged))
        wire(defaultCheck, #selector(defaultCheckChanged))
        wire(formatPopup, #selector(formatChanged))
        wire(actionPopup, #selector(actionChanged))
        wire(defaultChoice, #selector(defaultChoiceChanged))
        wire(alignPopup, #selector(alignChanged))
        wire(borderPopup, #selector(borderChanged))
        wire(fillPopup, #selector(fillChanged))
        wire(suggestionKind, #selector(suggestionKindChanged))
        wire(earlierButton, #selector(earlierClicked))
        wire(laterButton, #selector(laterClicked))
        wire(duplicateButton, #selector(duplicateClicked))
        wire(deleteButton, #selector(deleteClicked))
        wire(acceptButton, #selector(acceptClicked))
        wire(rejectButton, #selector(rejectClicked))
        wire(acceptAllButton, #selector(acceptAllClicked))
        wire(rejectAllButton, #selector(rejectAllClicked))
        sizeCombo.addItems(withObjectValues: FormDesignRules.sizes)
        sizeCombo.target = self
        sizeCombo.action = #selector(sizeChanged)
        sizeCombo.cell?.sendsActionOnEndEditing = true
        alignPopup.addItems(withTitles: ["Left", "Center", "Right"])
        suggestionKind.addItems(withTitles: FormDesignRules.suggestionKinds.map(\.label))

        choicesView.isRichText = false
        choicesView.isAutomaticQuoteSubstitutionEnabled = false
        choicesView.isAutomaticDashSubstitutionEnabled = false
        choicesView.isAutomaticTextReplacementEnabled = false
        choicesView.font = .systemFont(ofSize: NSFont.systemFontSize)
        choicesView.delegate = self
        choicesView.isVerticallyResizable = true
        choicesView.textContainer?.widthTracksTextView = true
        choicesView.autoresizingMask = .width
        let choicesScroll = NSScrollView()
        choicesScroll.documentView = choicesView
        choicesScroll.hasVerticalScroller = true
        choicesScroll.borderType = .bezelBorder
        choicesScroll.heightAnchor.constraint(equalToConstant: 90).isActive = true

        _ = column([
            row("Choices: one per line, \"Shown text = value\" when they differ", choicesScroll), editableBox, multiSelectBox,
        ], in: choicesGroup)
        _ = column([
            multilineBox, row("Most characters (0: no limit)", maxLengthField), row("Format", formatPopup),
        ], in: textGroup)
        _ = row("Value when on", exportField, in: exportGroup)
        _ = column([row("Label", captionField), row("When clicked", actionPopup)], in: buttonGroup)
        _ = row("Default value", defaultField, in: defaultTextRow)
        _ = row("Selected by default", defaultChoice, in: defaultChoiceRow)
        let tabRow = NSStackView(views: [earlierButton, laterButton])
        let commandRow = NSStackView(views: [duplicateButton, deleteButton])
        _ = column([
            row("Name (dots group fields: address.city)", nameField), row("Tooltip", tooltipField), requiredBox, readOnlyBox,
            textGroup, choicesGroup, exportGroup, buttonGroup, defaultTextRow, defaultChoiceRow, defaultCheck,
            row("Text size", sizeCombo), row("Alignment", alignPopup), row("Border", borderPopup), row("Fill", fillPopup),
            tabRow, commandRow,
        ], in: fieldGroup)
        let suggestionRow = NSStackView(views: [acceptButton, rejectButton])
        _ = column([row("Name", suggestionName), row("Kind", suggestionKind), suggestionSource, suggestionRow], in: suggestionGroup)
        let allRow = NSStackView(views: [acceptAllButton, rejectAllButton])
        _ = column([suggestionCount, allRow], in: allGroup)

        let stack = column([titleLabel, errorLabel, hintLabel, fieldGroup, suggestionGroup, allGroup], spacing: 12)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        for group in [fieldGroup, suggestionGroup, allGroup, textGroup, choicesGroup, exportGroup, buttonGroup, defaultTextRow, defaultChoiceRow] {
            group.translatesAutoresizingMaskIntoConstraints = false
        }
        for group in [fieldGroup, suggestionGroup, allGroup] { group.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24).isActive = true }
        for group in [textGroup, choicesGroup, exportGroup, buttonGroup, defaultTextRow, defaultChoiceRow] {
            group.widthAnchor.constraint(equalTo: fieldGroup.widthAnchor).isActive = true
        }
        for text in [hintLabel, errorLabel, suggestionSource, suggestionCount] { text.preferredMaxLayoutWidth = 236 }

        let document = FlippedView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        let scroll = NSScrollView()
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        document.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor), stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor), stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
        ])
        panelController.view = scroll
        scroll.setAccessibilityLabel("Field properties")
        for group in [fieldGroup, suggestionGroup, allGroup] { group.isHidden = true }
    }

    private final class FlippedView: NSView {
        override var isFlipped: Bool { true }
    }

    /// Enter's or a double-click's properties: the name, selected, ready to type.
    func focusProperties() {
        controller?.window?.makeFirstResponder(nameField)
        nameField.selectText(nil)
    }

    /// Esc in a text box goes back to the page (the field stays selected).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        controller?.window?.makeFirstResponder(pages)
        return true
    }

    private func announce(_ message: String) {
        guard let window = controller?.window else { return }
        NSAccessibility.post(element: window, notification: .announcementRequested,
                             userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    /// Applies one property change of the selected field as an edit (nothing when it changes nothing).
    private func change(_ label: String, _ make: (DesignField) throws -> DesignField) {
        guard let f = model.selectedField, !f.signed else { return }
        do {
            let updated = try make(f)
            errorLabel.isHidden = true
            if FormDesignRules.differs(updated, f) { track { [weak self] in await self?.update(label, [updated]) } }
        } catch let refusal as DesignRefusal {
            errorLabel.stringValue = refusal.message
            errorLabel.isHidden = false
            announce(refusal.message)
        } catch {}
    }

    @objc func nameChanged() {
        let typed = nameField.stringValue, fields = model.fields
        change("Rename field") { try FormDesignRules.renamed($0, to: typed, fields: fields) }
    }

    @objc func tooltipChanged() {
        let typed = tooltipField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        change("Change tooltip") { $0.with { $0.tooltip = typed } }
    }

    @objc func maxLengthChanged() {
        let typed = maxLengthField.stringValue
        change("Change length limit") { try FormDesignRules.withMaxLength($0, typed) }
    }

    @objc func exportChanged() {
        let typed = exportField.stringValue, fields = model.fields
        change("Change value") { try FormDesignRules.withExportValue($0, typed, fields: fields) }
    }

    @objc func captionChanged() {
        let typed = captionField.stringValue
        change("Change label") { $0.with { $0.caption = typed } }
    }

    @objc func defaultChanged() {
        let typed = defaultField.stringValue
        change("Change default") { $0.with { $0.defaultValue = typed } }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard notification.object as? NSTextView === choicesView else { return }
        choicesCommitted()
    }

    /// The choices editor applies when focus leaves it (Return makes a new line).
    func choicesCommitted() {
        let typed = choicesView.string
        change("Change choices") { try FormDesignRules.withChoices($0, typed) }
    }

    @objc func requiredChanged() {
        let on = requiredBox.state == .on
        change("Change required") { $0.with { $0.required = on } }
    }

    @objc func readOnlyChanged() {
        let on = readOnlyBox.state == .on
        change("Change read-only") { $0.with { $0.readOnly = on } }
    }

    @objc func multilineChanged() {
        let on = multilineBox.state == .on
        change("Change multi-line") { $0.with { $0.multiline = on } }
    }

    @objc func editableChanged() {
        let on = editableBox.state == .on
        change("Change dropdown") { $0.with { $0.editable = on } }
    }

    @objc func multiSelectChanged() {
        let on = multiSelectBox.state == .on
        change("Change list box") { $0.with { $0.multiSelect = on } }
    }

    @objc func defaultCheckChanged() {
        let on = defaultCheck.state == .on
        change("Change default") { FormDesignRules.withDefaultOn($0, on) }
    }

    @objc func formatChanged() {
        let i = formatPopup.indexOfSelectedItem
        guard FormDesignRules.formats.indices.contains(i) else { return }
        change("Change format") { $0.with { $0.format = FormDesignRules.formats[i].format } }
    }

    @objc func actionChanged() {
        let i = actionPopup.indexOfSelectedItem
        guard i >= 0 && i < 3 else { return }
        change("Change button action") { $0.with { $0.action = i == 1 ? .resetForm : i == 2 ? .print : .none } }
    }

    @objc func defaultChoiceChanged() {
        let i = defaultChoice.indexOfSelectedItem
        change("Change default") { f in f.with { $0.defaultValue = i > 0 && i <= f.options.count ? f.options[i - 1] : "" } }
    }

    @objc func alignChanged() {
        let i = alignPopup.indexOfSelectedItem
        change("Change alignment") { $0.with { $0.alignment = max(i, 0) } }
    }

    @objc func borderChanged() {
        let i = borderPopup.indexOfSelectedItem
        guard FormDesignRules.borderColors.indices.contains(i) else { return }
        change("Change border") { $0.with { $0.borderColor = FormDesignRules.borderColors[i].color } }
    }

    @objc func fillChanged() {
        let i = fillPopup.indexOfSelectedItem
        guard FormDesignRules.fillColors.indices.contains(i) else { return }
        change("Change fill") { $0.with { $0.fillColor = FormDesignRules.fillColors[i].color } }
    }

    @objc func sizeChanged() {
        guard let size = FormDesignRules.parseSize(sizeCombo.stringValue) else { return }
        change("Change text size") { $0.with { $0.fontSize = size } }
    }

    @objc func suggestionNameChanged() {
        guard let s = model.selectedSuggestion else { return }
        let name = suggestionName.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == s.name || name.isEmpty { return }
        var updated = s
        updated.name = name
        replaceSuggestion(s, updated)
    }

    @objc func suggestionKindChanged() {
        guard let s = model.selectedSuggestion, FormDesignRules.suggestionKinds.indices.contains(suggestionKind.indexOfSelectedItem) else { return }
        let picked = FormDesignRules.suggestionKinds[suggestionKind.indexOfSelectedItem]
        var updated = s
        updated.kind = picked.kind
        updated.multiline = picked.multiline
        replaceSuggestion(s, updated)
    }

    @objc func earlierClicked() { moveInTabOrder(-1) }
    @objc func laterClicked() { moveInTabOrder(1) }
    @objc func duplicateClicked() { duplicateSelected() }
    @objc func deleteClicked() { deleteSelected() }

    @objc func acceptClicked() {
        if let s = model.selectedSuggestion { acceptSuggestions([s]) }
    }

    @objc func rejectClicked() { rejectSuggestion() }
    @objc func acceptAllClicked() { acceptSuggestions(model.suggestions) }

    @objc func rejectAllClicked() {
        model.setSuggestions([])
        changed()
        controller?.window?.makeFirstResponder(pages)
    }

    private func setText(_ field: NSTextField, _ text: String) {
        if field.currentEditor() == nil && field.stringValue != text { field.stringValue = text }
    }

    private func fill(_ popup: NSPopUpButton, _ titles: [String], selected: Int) {
        popup.removeAllItems()
        popup.addItems(withTitles: titles)
        popup.selectItem(at: selected)
    }

    private func selectColor(_ popup: NSPopUpButton, _ choices: [(label: String, color: AnnotColor?)], _ color: AnnotColor?) {
        var titles = choices.map(\.label)
        let at = FormDesignRules.colorIndex(choices, color)
        if at == nil { titles.append("Custom (kept)") }
        fill(popup, titles, selected: at ?? titles.count - 1)
    }

    /// Fills the panel from the selection: a field's properties, a suggestion, or the hint.
    func showSelection() {
        let f = model.selectedField
        let s = f == nil ? model.selectedSuggestion : nil
        let count = model.suggestions.count
        fieldGroup.isHidden = f == nil
        suggestionGroup.isHidden = s == nil
        allGroup.isHidden = count == 0
        hintLabel.isHidden = f != nil || s != nil
        errorLabel.isHidden = true
        suggestionCount.stringValue = "\(count) suggested field\(count == 1 ? "" : "s") (dashed on the page)."
        let title = FormDesignRules.panelTitle(f, s)
        let titleChanged = titleLabel.stringValue != title
        titleLabel.stringValue = title
        if let f { showField(f) }
        if let s {
            setText(suggestionName, s.name)
            suggestionKind.selectItem(at: FormDesignRules.suggestionKinds.firstIndex { $0.kind == s.kind && $0.multiline == s.multiline } ?? 0)
            suggestionSource.stringValue = FormDesignRules.sourceText(s.source)
        }
        if titleChanged || f != nil || s != nil {
            announce(f.map { "\($0.describe()) selected, page \($0.pageIndex + 1)" }
                ?? s.map { "Suggested \(DesignField.kindName($0.kind).lowercased()) \($0.name), page \($0.pageIndex + 1)" } ?? title)
        }
    }

    private func showField(_ f: DesignField) {
        let text = f.kind == .text, choice = f.kind == .comboBox || f.kind == .listBox
        let onOff = f.kind == .checkBox || f.kind == .radio, button = f.kind == .button
        setText(nameField, f.name)
        setText(tooltipField, f.tooltip)
        requiredBox.state = f.required ? .on : .off
        readOnlyBox.state = f.readOnly ? .on : .off
        requiredBox.isHidden = button

        textGroup.isHidden = !text
        if text {
            multilineBox.state = f.multiline ? .on : .off
            setText(maxLengthField, String(f.maxLength))
            let formats = FormDesignRules.formatChoices(f)
            fill(formatPopup, formats.labels, selected: formats.selected)
            formatPopup.isEnabled = !f.customFormat
        }
        choicesGroup.isHidden = !choice
        if choice {
            if controller?.window?.firstResponder !== choicesView { choicesView.string = FormDesignRules.choicesText(f) }
            editableBox.isHidden = f.kind != .comboBox
            multiSelectBox.isHidden = f.kind != .listBox
            editableBox.state = f.editable ? .on : .off
            multiSelectBox.state = f.multiSelect ? .on : .off
        }
        exportGroup.isHidden = !onOff
        if onOff { setText(exportField, f.exportValue) }
        buttonGroup.isHidden = !button
        if button {
            setText(captionField, f.caption)
            let actions = ["Nothing", "Reset the form", "Print"] + (f.action == .other ? ["The form's own action (kept)"] : [])
            fill(actionPopup, actions, selected: f.action == .resetForm ? 1 : f.action == .print ? 2 : f.action == .other ? 3 : 0)
        }

        defaultTextRow.isHidden = !text
        defaultChoiceRow.isHidden = !choice
        if text { setText(defaultField, f.defaultValue) }
        if choice { fill(defaultChoice, ["(none)"] + f.shownOptions, selected: (f.options.firstIndex(of: f.defaultValue) ?? -1) + 1) }
        defaultCheck.isHidden = !onOff
        defaultCheck.state = onOff && !f.defaultValue.isEmpty && f.defaultValue == f.exportValue ? .on : .off
        defaultCheck.title = f.kind == .radio ? "Selected by default" : "Checked by default"

        let hasText = !onOff && f.kind != .signature
        sizeCombo.isEnabled = hasText
        alignPopup.isEnabled = hasText
        if sizeCombo.currentEditor() == nil { sizeCombo.stringValue = FormDesignRules.sizeText(f.fontSize) }
        alignPopup.selectItem(at: min(max(f.alignment, 0), 2))
        selectColor(borderPopup, FormDesignRules.borderColors, f.borderColor)
        selectColor(fillPopup, FormDesignRules.fillColors, f.fillColor)
        let editable = !f.signed
        for control in [nameField, tooltipField, maxLengthField, exportField, captionField, defaultField] { control.isEnabled = editable }
        for control in [requiredBox, readOnlyBox, multilineBox, editableBox, multiSelectBox, defaultCheck, duplicateButton, deleteButton, earlierButton, laterButton] { control.isEnabled = editable }
        for control in [formatPopup, actionPopup, defaultChoice, borderPopup, fillPopup] where control !== formatPopup || !f.customFormat { control.isEnabled = editable }
        choicesView.isEditable = editable
        if !editable {
            sizeCombo.isEnabled = false
            alignPopup.isEnabled = false
        }
    }
}

/// The bar over the pages while preparing a form.
final class PrepareFormBar: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}

extension DocumentWindowController {
    /// Tools › Prepare Form (⌥⌘F): in or out.
    @objc func togglePrepareForm(_ sender: Any?) {
        startPrepareForm(!design.isDesigning)
    }

    func startPrepareForm(_ on: Bool) {
        Task { await design.setDesigning(on) }
    }

    /// Tools › Detect Form Fields: enters Prepare Form first.
    @objc func detectFormFields(_ sender: Any?) {
        startLongTask { [weak self] in
            guard let self, await self.design.setDesigning(true) else { return }
            await self.design.settle()
            await self.design.detectFields()
        }
    }
}
