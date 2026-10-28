import AppKit
import PdfCore
import UniformTypeIdentifiers

/// Filling a document's form on the pages (the Windows app's PageViewer.Forms and FormActions.Tab): the fields are
/// outlined; a click (or Tab, then Space or Return) toggles a check box, picks a radio button, opens a choice's menu or
/// puts an editor over a text field. Typing runs the field's keystroke script live (characters refused or rewritten as
/// on Windows); Return, Tab or a click elsewhere writes the value through the session's edit transaction (one undo step,
/// the form's validate, calculate and format scripts run by `FormEditor.fill`). Field and button actions run through
/// `FormEditor.runAction`, outward steps through `AppFormHost`, which asks first.
@MainActor
final class FormFiller: NSObject, NSTextFieldDelegate, NSComboBoxDelegate {
    private(set) weak var controller: DocumentWindowController?
    /// The form's widgets as last read (in tab order).
    private(set) var widgets: [FormWidget] = []
    /// The widget with the keyboard focus (Tab moves it), and the one whose editor is open.
    private(set) var focused: FormWidget?
    private(set) var editing: FormWidget?
    /// The open text editor (a text field or an editable combo box).
    private(set) var editorView: NSTextField?
    private var lastText = ""
    private var keystrokes: FieldKeystrokes?
    private var keystrokesLoad: Task<Void, Never>?
    /// Values waiting to be written, and the write in progress (the self-test awaits it).
    private var queue: [String: String] = [:]
    private(set) var pendingWrite: Task<Void, Never>?
    private(set) var pendingAction: Task<Void, Never>?
    /// What the last write's scripts said (the self-test reads it).
    private(set) var lastResult: FormFillResult?
    let host: AppFormHost

    init(controller: DocumentWindowController) {
        self.controller = controller
        host = AppFormHost()
        super.init()
        host.filler = self
    }

    private var pages: PagesView? { controller?.pages }
    private var editor: DocumentEditor? { controller?.editor }

    /// Fields a person can fill or press, in tab order.
    var fillable: [FormWidget] { widgets.filter { !$0.readOnly && !$0.calculated } }
    var hasFields: Bool { !fillable.isEmpty }

    static func same(_ a: FormWidget?, _ b: FormWidget?) -> Bool {
        guard let a, let b else { return false }
        return a.fieldName == b.fieldName && a.pageIndex == b.pageIndex && a.annotIndex == b.annotIndex && a.rect == b.rect
    }

    /// Reads the widgets of the current bytes; an open editor stays on its field.
    func reload() {
        guard let session = editor?.session else { return }
        widgets = (try? FormEditor.read(session.data, session.password)) ?? []
        if let f = focused { focused = widgets.first { $0.fieldName == f.fieldName && $0.pageIndex == f.pageIndex && $0.annotIndex == f.annotIndex } }
        if let e = editing, !widgets.contains(where: { $0.fieldName == e.fieldName && $0.annotIndex == e.annotIndex }) { closeEditor() }
        layoutEditor()
        if let pages { pages.window?.invalidateCursorRects(for: pages) }
    }

    func value(_ name: String) -> String? { widgets.first { $0.fieldName == name }?.value }

    /// The widget under a page point (fields to fill, push buttons, signature fields).
    func widget(page: Int, _ p: PointD) -> FormWidget? {
        fillable.last { $0.pageIndex == page && $0.rect.contains(p.x, p.y) }
    }

    // MARK: Drawing

    /// Outlines the fields to fill on a page, the focused one with the focus ring.
    func draw(_ page: Int, _ r: NSRect) {
        guard let pages else { return }
        let px = pages.onePixel
        for w in fillable where w.pageIndex == page && w.kind != .pushButton {
            let rect = pages.viewRect(w.rect, r)
            NSColor.systemBlue.withAlphaComponent(0.07).setFill()
            rect.fill(using: .multiply)
            let path = NSBezierPath(rect: rect)
            path.lineWidth = px
            NSColor.systemBlue.withAlphaComponent(0.35).setStroke()
            path.stroke()
        }
        if let f = focused, f.pageIndex == page, editing == nil {
            let ring = NSBezierPath(rect: pages.viewRect(f.rect, r).insetBy(dx: -2 * px, dy: -2 * px))
            ring.lineWidth = 2 * px
            NSColor.keyboardFocusIndicatorColor.setStroke()
            ring.stroke()
        }
    }

    // MARK: Activating

    /// A click (or Space and Return on the focused field): what the field's kind does.
    func activate(_ w: FormWidget) {
        commitEditor()
        focus(w, open: false)
        switch w.kind {
        case .checkBox:
            guard let on = w.onState else {
                controller?.notify("This check box can't be changed: the form doesn't define its checked look.")
                return
            }
            write(w.fieldName, w.value == on ? "Off" : on)
        case .radio:
            if let on = w.onState, w.value != on { write(w.fieldName, on) }
        case .text:
            openEditor(w)
            return // its actions run when the editor opens and closes
        case .choice:
            if w.editable && !w.multiSelect {
                openEditor(w)
                return
            }
            showChoices(w)
        case .pushButton:
            break
        case .signature:
            controller?.notify("Signing a signature field digitally comes in a later version of Inkvolt PDF for Mac.")
            return
        }
        if !w.triggers.intersection([.down, .up]).isEmpty { runAction(w, .click) }
    }

    /// Moves the keyboard focus to `w` (shown with a ring), opening its editor when asked.
    func focus(_ w: FormWidget, open: Bool) {
        focused = w
        if let pages, w.pageIndex < pages.pageRects.count {
            let rect = pages.viewRect(w.rect, pages.pageRects[w.pageIndex]).insetBy(dx: -30, dy: -30)
            pages.scrollToVisible(rect)
            NSAccessibility.post(element: pages, notification: .announcementRequested,
                                 userInfo: [.announcement: Self.spoken(w)])
        }
        pages?.needsDisplay = true
        if open && (w.kind == .text || (w.kind == .choice && w.editable && !w.multiSelect)) { openEditor(w) }
    }

    /// Tab and Shift-Tab: the next (or previous) field in the form's tab order, its editor opened for text.
    @discardableResult
    func focusNext(_ by: Int) -> Bool {
        let list = fillable
        guard !list.isEmpty else { return false }
        commitEditor()
        let index = list.firstIndex { Self.same($0, focused) }
        let start = index ?? (by > 0 ? -1 : list.count)
        let next = ((start + by) % list.count + list.count) % list.count
        focus(list[next], open: true)
        return true
    }

    func clearFocus() {
        commitEditor()
        focused = nil
        pages?.needsDisplay = true
    }

    /// Space or Return on the focused field (no editor open).
    func handleKey(_ event: NSEvent) -> Bool {
        guard let f = focused, editing == nil else { return false }
        if event.charactersIgnoringModifiers == " " || event.specialKey == .carriageReturn || event.specialKey == .enter {
            activate(f)
            return true
        }
        if event.keyCode == 53 { // Esc
            clearFocus()
            return true
        }
        return false
    }

    static func spoken(_ w: FormWidget) -> String {
        let kind: String
        switch w.kind {
        case .text: kind = "text field"
        case .checkBox: kind = w.value == w.onState ? "check box, checked" : "check box, not checked"
        case .radio: kind = w.value == w.onState ? "radio button, selected" : "radio button"
        case .choice: kind = "choice"
        case .pushButton: kind = "button"
        case .signature: kind = "signature field"
        }
        return "\(w.fieldName), \(kind)"
    }

    // MARK: Choices

    /// Option texts shown: the display labels when the field has them, else the export values.
    static func labels(_ w: FormWidget) -> [String] {
        if let l = w.optionLabels, l.count == w.options.count { return l }
        return w.options
    }

    /// A choice field's options as a menu under it; a multi-select list toggles the option chosen.
    private func showChoices(_ w: FormWidget) {
        // A menu's tracking loop would hold the self-test (nobody at the screen): it picks with `choose`.
        guard let pages, w.pageIndex < pages.pageRects.count, !Report.isRunning else { return }
        let menu = NSMenu(title: w.fieldName)
        let selected = Set(w.value.components(separatedBy: "\n"))
        for (i, label) in Self.labels(w).enumerated() {
            let item = NSMenuItem(title: label.isEmpty ? " " : label, action: #selector(choicePicked(_:)), keyEquivalent: "")
            item.target = self
            item.tag = i
            item.state = selected.contains(w.options[i]) ? .on : .off
            menu.addItem(item)
        }
        let rect = pages.viewRect(w.rect, pages.pageRects[w.pageIndex])
        menu.popUp(positioning: nil, at: NSPoint(x: rect.minX, y: rect.maxY + 2), in: pages)
    }

    @objc private func choicePicked(_ sender: NSMenuItem) {
        guard let w = focused, w.kind == .choice else { return }
        choose(w, sender.tag)
    }

    /// Picks option `index` (a multi-select list toggles it).
    func choose(_ w: FormWidget, _ index: Int) {
        guard index >= 0 && index < w.options.count else { return }
        let option = w.options[index]
        if w.multiSelect {
            var chosen = w.value.isEmpty ? [] : w.value.components(separatedBy: "\n")
            if let at = chosen.firstIndex(of: option) { chosen.remove(at: at) } else { chosen.append(option) }
            let ordered = w.options.filter { chosen.contains($0) }
            write(w.fieldName, ordered.joined(separator: "\n"))
        } else {
            write(w.fieldName, option)
        }
    }

    // MARK: The text editor

    func openEditor(_ w: FormWidget) {
        guard let pages, w.pageIndex < pages.pageRects.count else { return }
        closeEditor()
        focused = w
        editing = w
        let field: NSTextField
        if w.kind == .choice {
            let combo = NSComboBox()
            combo.addItems(withObjectValues: Self.labels(w))
            combo.completes = true
            combo.delegate = self
            field = combo
        } else if w.password {
            field = NSSecureTextField()
        } else {
            field = NSTextField()
        }
        let shown = w.kind == .choice ? (Self.labels(w).indices.first { w.options[$0] == w.value }.map { Self.labels(w)[$0] } ?? w.value) : w.value
        field.stringValue = shown
        lastText = shown
        field.delegate = self
        field.isBordered = true
        field.focusRingType = .exterior
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        let size: CGFloat = w.multiline ? 10 : CGFloat(max(min(w.rect.height * 0.62, 13), 7))
        field.font = .systemFont(ofSize: size)
        if w.multiline {
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
        } else {
            field.cell?.isScrollable = true
        }
        field.setAccessibilityLabel(w.fieldName)
        editorView = field
        pages.addSubview(field)
        layoutEditor()
        pages.window?.makeFirstResponder(field)
        if w.triggers.contains(.focus) { runAction(w, .focus) }
        // The keystroke script, read off the main thread; typing before it is ready goes through as is.
        keystrokes = nil
        keystrokesLoad?.cancel()
        if w.triggers.contains(.keystroke), let session = editor?.session {
            let data = session.data, pw = session.password, name = w.fieldName
            keystrokesLoad = Task { [weak self] in
                let k = await Task.detached { FieldKeystrokes.open(data, pw, name) }.value
                guard let self, !Task.isCancelled, self.editing?.fieldName == name else { return }
                self.keystrokes = k
            }
        }
        pages.needsDisplay = true
    }

    /// The keystroke script is ready (the self-test waits for it).
    func keystrokesReady() async { await keystrokesLoad?.value }

    /// Keeps the editor over its field (zoom, layout changes).
    func layoutEditor() {
        guard let field = editorView, let w = editing, let pages, w.pageIndex < pages.pageRects.count else { return }
        var rect = pages.viewRect(w.rect, pages.pageRects[w.pageIndex])
        if rect.height < 18 && !w.multiline { rect = rect.insetBy(dx: 0, dy: (rect.height - 18) / 2) }
        field.frame = rect
    }

    /// Writes what the editor holds (when it changed) and closes it.
    func commitEditor() {
        guard let w = editing, let field = editorView else { return }
        var text = field.stringValue
        if w.kind == .choice, let i = Self.labels(w).firstIndex(of: text) { text = w.options[i] }
        closeEditor()
        if text != w.value { write(w.fieldName, text) }
        if w.triggers.contains(.blur) { runAction(w, .blur) }
    }

    /// Closes the editor without writing (Esc).
    func cancelEditor() {
        closeEditor()
        if let pages { pages.window?.makeFirstResponder(pages) }
    }

    private func closeEditor() {
        guard let field = editorView else {
            editing = nil
            return
        }
        editorView = nil
        editing = nil
        keystrokes = nil
        keystrokesLoad?.cancel()
        let hadFocus = field.currentEditor() != nil
        field.delegate = nil
        field.removeFromSuperview()
        if hadFocus, let pages { pages.window?.makeFirstResponder(pages) }
        pages?.needsDisplay = true
    }

    /// Typing: the field's length limit, then its keystroke script (refused characters taken back, rewritten ones
    /// replaced), as Windows' inline editor does.
    func controlTextDidChange(_ obj: Notification) {
        guard let field = editorView, let w = editing else { return }
        let now = field.stringValue
        guard now != lastText else { return }
        let d = FieldKeystrokes.diff(lastText, now)
        var change = d.change
        if w.maxLength > 0 { change = FieldKeystrokes.fit(lastText, d.start, d.end, change, w.maxLength) }
        var result = Self.replacing(lastText, d.start, d.end, change)
        if let k = keystrokes, let verdict = k.run(lastText, change, d.start, d.end) {
            for alert in verdict.alerts { controller?.notify(alert) }
            if !verdict.accepted {
                NSSound.beep()
                result = lastText
            } else {
                result = Self.replacing(lastText, verdict.selStart, verdict.selEnd, verdict.change)
            }
        }
        if result != now {
            field.stringValue = result
            field.currentEditor()?.selectedRange = NSRange(location: (result as NSString).length, length: 0)
        }
        lastText = result
    }

    /// `text` with UTF-16 range [start, end) replaced by `change`.
    static func replacing(_ text: String, _ start: Int, _ end: Int, _ change: String) -> String {
        let s = text as NSString
        let a = min(max(start, 0), s.length), b = min(max(end, a), s.length)
        return s.replacingCharacters(in: NSRange(location: a, length: b - a), with: change)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if editing?.multiline == true {
                textView.insertNewlineIgnoringFieldEditor(nil)
                return true
            }
            commitEditor()
            return true
        case #selector(NSResponder.insertTab(_:)):
            focusNext(1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            focusNext(-1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancelEditor()
            return true
        default:
            return false
        }
    }

    /// A click elsewhere (the editor lost the keyboard): what it holds is written.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, field === editorView else { return }
        commitEditor()
    }

    // MARK: Writing

    /// Queues a field value; values are written one batch at a time (one undo step each), so quick clicks and typing
    /// never lose a change.
    func write(_ name: String, _ value: String) {
        queue[name] = value
        for i in widgets.indices where widgets[i].fieldName == name { widgets[i].value = value }
        pages?.needsDisplay = true
        guard pendingWrite == nil else { return }
        pendingWrite = Task { [weak self] in
            await self?.flush()
            self?.pendingWrite = nil
        }
    }

    private func flush() async {
        var busyTries = 0
        while !queue.isEmpty, let editor {
            let batch = queue
            queue = [:]
            let (ok, result) = await editor.fillForm(batch, host: host)
            if editor.lastOutcome == .busy && busyTries < 50 {
                busyTries += 1
                for (k, v) in batch where queue[k] == nil { queue[k] = v }
                try? await Task.sleep(for: .milliseconds(100))
                continue
            }
            if let result { report(result) }
            if !ok && editor.lastOutcome != .noChange {
                queue = [:]
                reload() // the fields show the document's values again
            }
        }
    }

    /// What the scripts said about a write: refused values (the field shows the document's value again), alerts.
    func report(_ result: FormFillResult) {
        lastResult = result
        for r in result.rejected where !r.message.isEmpty { controller?.notify(r.message) }
        for a in Array(Set(result.alerts)).prefix(3) { controller?.notify(a) }
        if !result.rejected.isEmpty { reload() }
        if let name = result.focusField, editing == nil, let w = fillable.first(where: { $0.fieldName == name }) { focus(w, open: true) }
    }

    /// Runs a widget's actions (after the values before it are written: its scripts read them).
    func runAction(_ w: FormWidget, _ trigger: FormTrigger) {
        let before = pendingAction
        pendingAction = Task { [weak self] in
            await before?.value
            await self?.pendingWrite?.value
            guard let self, let editor = self.editor else { return }
            guard let r = await editor.formAction(w, trigger, host: self.host) else { return }
            for a in Array(Set(r.alerts)).prefix(3) { self.controller?.notify(a) }
            if r.needsPermission { self.controller?.notify("This form is protected: its buttons can't change fields until the permissions password is entered.") }
            if let name = r.focusField, let target = self.fillable.first(where: { $0.fieldName == name }) { self.focus(target, open: true) }
        }
    }

    /// Waits for the writes and actions started so far (the self-test).
    func settle() async {
        await pendingWrite?.value
        await pendingAction?.value
        await pendingWrite?.value
    }

    // MARK: Form data

    @objc func resetForm(_ sender: Any?) {
        guard hasFields || !widgets.isEmpty else { return NSSound.beep() }
        if !Report.isRunning {
            let alert = NSAlert()
            alert.messageText = "Reset the form?"
            alert.informativeText = "Every field goes back to its default value. You can undo this."
            alert.addButton(withTitle: "Reset")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        commitEditor()
        pendingWrite = Task { [weak self] in
            guard let self, let editor = self.editor else { return }
            if await editor.resetForm() { self.controller?.notify("The form was reset.") }
            self.pendingWrite = nil
        }
    }

    /// Export Form Data: the values as XFDF or FDF, to `url` (the save panel's choice).
    func exportData(to url: URL, _ format: FormDataFormat) -> Bool {
        guard let session = editor?.session else { return false }
        do {
            let bytes = try FormEditor.exportData(session.data, session.password, format, file: session.displayName)
            try Data(bytes).write(to: url, options: .atomic)
            controller?.notify("Form data exported to \(url.lastPathComponent).")
            return true
        } catch {
            controller?.pdf.showError("The form data couldn't be exported.", error)
            return false
        }
    }

    /// Import Form Data from an FDF or XFDF file's bytes.
    func importData(_ bytes: [UInt8]) async -> Bool {
        commitEditor()
        await settle()
        guard let editor else { return false }
        let (ok, result) = await editor.importFormData(bytes, host: host)
        if let result { report(result) }
        if ok { controller?.notify("Form data imported.") }
        return ok
    }
}

/// What a form's actions may do outside the document, for the app: every outward step asks first (the self-test
/// declines them and answers alerts with OK, noting what was asked). Called on the worker a form runs on; dialogs are
/// shown on the main thread meanwhile.
final class AppFormHost: FormActionHost, @unchecked Sendable {
    weak var filler: FormFiller?
    private let lock = NSLock()
    private var asked: [String] = []

    /// What the form asked for during the self-test.
    var testLog: [String] { lock.withLock { asked } }

    private func note(_ s: String) { lock.withLock { asked.append(s) } }

    private func onMainSync<T: Sendable>(_ f: @escaping @MainActor () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated { f() } }
        return DispatchQueue.main.sync { MainActor.assumeIsolated { f() } }
    }

    /// Asks the user (never during the self-test, which declines).
    private func confirm(_ message: String, _ detail: String, _ button: String) -> Bool {
        note("asked: \(message)")
        return onMainSync {
            if Report.isRunning { return false }
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = detail
            alert.addButton(withTitle: button)
            alert.addButton(withTitle: "Don't Allow")
            return alert.runModal() == .alertFirstButtonReturn
        }
    }

    var currentPage: Int {
        let f = filler
        return onMainSync { f?.controllerPage ?? 0 }
    }

    func goToPage(_ page: Int, _ y: Double?) {
        let f = filler
        DispatchQueue.main.async { MainActor.assumeIsolated { f?.go(page, y) } }
    }

    func openUrl(_ url: String) -> Bool {
        guard let u = URL(string: url), ["http", "https", "mailto"].contains(u.scheme?.lowercased() ?? "") else { return false }
        guard confirm("This form wants to open a web address.", url, "Open") else { return false }
        return onMainSync { NSWorkspace.shared.open(u) }
    }

    func submit(_ submission: FormSubmission) -> Bool {
        guard let u = URL(string: submission.url), ["http", "https"].contains(u.scheme?.lowercased() ?? "") else { return false }
        let what = submission.fieldCount == 1 ? "1 field" : "\(submission.fieldCount) fields"
        guard confirm("This form wants to send its data (\(what)).", "To \(submission.url)", "Send") else { return false }
        var request = URLRequest(url: u)
        request.httpMethod = submission.method
        request.setValue(submission.contentType, forHTTPHeaderField: "Content-Type")
        if submission.method == "POST" { request.httpBody = Data(submission.body) }
        URLSession.shared.dataTask(with: request).resume()
        return true
    }

    func mail(_ mail: FormMail) -> Bool {
        guard confirm("This form wants to start an email.", "To \(mail.to.isEmpty ? "(nobody yet)" : mail.to)", "Write Email") else { return false }
        var parts = URLComponents()
        parts.scheme = "mailto"
        parts.path = mail.to
        var query: [URLQueryItem] = []
        if !mail.cc.isEmpty { query.append(URLQueryItem(name: "cc", value: mail.cc)) }
        if !mail.subject.isEmpty { query.append(URLQueryItem(name: "subject", value: mail.subject)) }
        if !mail.message.isEmpty { query.append(URLQueryItem(name: "body", value: mail.message)) }
        parts.queryItems = query.isEmpty ? nil : query
        guard let url = parts.url else { return false }
        return onMainSync { NSWorkspace.shared.open(url) }
    }

    /// A form's print action: File > Print's panel (never during the self-test, which notes it).
    func print(_ fromPage: Int?, _ toPage: Int?) {
        note("print")
        let f = filler
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                if Report.isRunning { return }
                f?.controller?.pdf.printDocument(nil)
            }
        }
    }

    func alert(_ alert: FormAlert) -> Int {
        note("alert")
        return onMainSync {
            if Report.isRunning { return 1 }
            let a = NSAlert()
            a.messageText = alert.title.isEmpty ? "The form says:" : alert.title
            a.informativeText = alert.message
            a.alertStyle = alert.icon == 0 ? .critical : alert.icon == 1 ? .warning : .informational
            switch alert.buttons {
            case 1:
                a.addButton(withTitle: "OK")
                a.addButton(withTitle: "Cancel")
                return a.runModal() == .alertFirstButtonReturn ? 1 : 2
            case 2, 3:
                a.addButton(withTitle: "Yes")
                a.addButton(withTitle: "No")
                if alert.buttons == 3 { a.addButton(withTitle: "Cancel") }
                let r = a.runModal()
                return r == .alertFirstButtonReturn ? 4 : r == .alertSecondButtonReturn ? 3 : 2
            default:
                a.addButton(withTitle: "OK")
                a.runModal()
                return 1
            }
        }
    }

    func response(_ prompt: FormPrompt) -> String? {
        note("response")
        return onMainSync {
            if Report.isRunning { return nil }
            let a = NSAlert()
            a.messageText = prompt.title.isEmpty ? "The form asks:" : prompt.title
            a.informativeText = prompt.question
            let field: NSTextField = prompt.password ? NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
                : NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
            field.stringValue = prompt.defaultText
            a.accessoryView = field
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Cancel")
            a.window.initialFirstResponder = field
            return a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
        }
    }

    func openRemote(_ path: String, _ page: Int) -> Bool {
        guard let url = resolve(path), url.pathExtension.lowercased() == "pdf" else { return false }
        guard confirm("This form wants to open another PDF.", url.lastPathComponent, "Open") else { return false }
        return onMainSync {
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
            return true
        }
    }

    func launch(_ path: String) -> Bool {
        guard let url = resolve(path) else { return false }
        // Never a program: only documents, opened in their own app.
        let refused = ["app", "command", "sh", "tool", "pkg", "dmg", "terminal", "scpt", "workflow"]
        if refused.contains(url.pathExtension.lowercased()) || FileManager.default.isExecutableFile(atPath: url.path) { return false }
        guard confirm("This form wants to open a file.", url.lastPathComponent, "Open") else { return false }
        return onMainSync { NSWorkspace.shared.open(url) }
    }

    func named(_ name: String) {
        let f = filler
        DispatchQueue.main.async { MainActor.assumeIsolated { f?.named(name) } }
    }

    func importData(_ suggestedPath: String?) -> [UInt8]? {
        guard confirm("This form wants to import form data from a file.", "You choose the file.", "Choose File") else { return nil }
        return onMainSync {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = FormDataPanel.types
            guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return nil }
            return [UInt8](data)
        }
    }

    func beep(_ type: Int) {
        DispatchQueue.main.async { NSSound.beep() }
    }

    /// A path from the form: absolute, or relative to the document's folder.
    private func resolve(_ path: String) -> URL? {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        let f = filler
        let base: String? = onMainSync { f?.documentFolder }
        guard let base else { return nil }
        return URL(fileURLWithPath: base).appendingPathComponent(path).standardizedFileURL
    }
}

extension FormFiller {
    var controllerPage: Int { pages?.currentPage ?? 0 }
    var documentFolder: String? { editor?.session?.filePath.map { ($0 as NSString).deletingLastPathComponent } }

    func go(_ page: Int, _ y: Double?) { controller?.go(page, targetY: y) }

    /// Named actions a form may take.
    func named(_ name: String) {
        guard let controller else { return }
        switch name {
        case "NextPage": controller.nextPage(nil)
        case "PrevPage": controller.previousPage(nil)
        case "FirstPage": controller.firstPage(nil)
        case "LastPage": controller.lastPage(nil)
        case "Find": controller.showFind(nil)
        case "FullScreen": controller.window?.toggleFullScreen(nil)
        default: NSSound.beep()
        }
    }
}

/// The file types Import Form Data accepts.
enum FormDataPanel {
    static var types: [UTType] {
        [UTType(filenameExtension: "xfdf"), UTType(filenameExtension: "fdf")].compactMap { $0 }
    }
}
