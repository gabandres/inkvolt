import AppKit
import PdfCore

/// Round 2 of the UX review: every sheet, panel and alert the document window puts up, drawn to PNG in light and dark,
/// then cancelled. Each command is sent as a person would (its menu action); the step waits for the sheet, the modal
/// alert or the new window it opens, shoots and audits it, then takes its Cancel button (or ends it as cancelled), so
/// nothing is changed or saved. A dialog with a second state (an error, a disclosed section) is driven into it and shot
/// again. Save and open panels are the system's own and aren't drawn.
extension UxShots {
    /// One state of a dialog: its shot's name and what to do to it afterwards (nil: cancel it).
    struct Step {
        let name: String
        let then: (@MainActor (NSWindow) -> Void)?
        /// The same window again, after `then` of the step before changed it (More Options opened).
        let same: Bool
        init(_ name: String, same: Bool = false, then: (@MainActor (NSWindow) -> Void)? = nil) {
            self.name = name
            self.same = same
            self.then = then
        }

        /// Shoots the dialog closed, then with its More Options open (and closes them again).
        static func more(_ name: String, _ look: String) -> [Step] {
            [Step("\(name)-\(look)") { w in UxShots.disclosure(w)?.performClick(nil) }, Step("\(name)-more-\(look)", same: true)]
        }
    }

    /// The sheet over `parent`, the app's modal window, or a window that wasn't showing before.
    static func dialogWindow(_ parent: NSWindow?, _ before: Set<ObjectIdentifier>) -> NSWindow? {
        if let modal = NSApp.modalWindow { return modal.attachedSheet ?? modal }
        if let sheet = parent?.attachedSheet { return sheet.attachedSheet ?? sheet }
        let fresh = NSApp.windows.first { w in
            w.isVisible && !before.contains(ObjectIdentifier(w)) && w.styleMask.contains(.titled) && w.className != "NSToolbarFullScreenWindow"
        }
        return fresh.map { $0.attachedSheet ?? $0 }
    }

    static func buttons(in view: NSView?) -> [NSButton] {
        guard let view else { return [] }
        var found: [NSButton] = []
        // Push buttons (macOS 26 reports a plain NSButton(title:) as .automatic); not pop-ups, checkboxes or triangles.
        if let b = view as? NSButton, !(b is NSPopUpButton), !b.isHidden, !b.title.isEmpty,
           b.bezelStyle.rawValue == 0 || b.bezelStyle == .push || b.bezelStyle == .flexiblePush {
            found.append(b)
        }
        for sub in view.subviews { found += buttons(in: sub) }
        return found
    }

    static func button(_ window: NSWindow, _ title: String) -> NSButton? {
        buttons(in: window.contentView).first { $0.title == title }
    }

    /// Cancel, else Close/Not Now/Done, else the only button; failing that the sheet or modal session is ended as
    /// cancelled, and a window is closed.
    static func dismiss(_ window: NSWindow) {
        let all = buttons(in: window.contentView).filter(\.isEnabled)
        let safe = ["Cancel", "Close", "Not Now", "Done", "Don't Save"]
        if let b = all.first(where: { safe.contains($0.title) }) ?? all.first(where: { $0.keyEquivalent == "\u{1b}" }) ?? (all.count == 1 ? all.first : nil) {
            b.performClick(nil)
            if !window.isVisible { return }
        }
        if NSApp.modalWindow === window {
            NSApp.stopModal(withCode: .cancel)
            if let wake = NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                                             windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0) {
                NSApp.postEvent(wake, atStart: true)
            }
        } else if let parent = window.sheetParent {
            parent.endSheet(window, returnCode: .cancel)
        } else {
            window.orderOut(nil)
        }
    }

    private func visibleWindows() -> Set<ObjectIdentifier> {
        Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    }

    /// Sends `trigger` (on the next turn of the run loop, so a modal alert doesn't block this step), then shoots each of
    /// `steps` as its dialog shows.
    mutating func dialog(_ steps: [Step], audits: Bool, wait: Int = 700, _ trigger: @escaping @MainActor () -> Void) async {
        let parent = controller.window
        let before = visibleWindows()
        // From the run loop, not the main queue: a modal alert's loop can't run main-queue work (this step) while a
        // main-queue block is the one waiting in it.
        RunLoop.main.perform(inModes: [.default]) { MainActor.assumeIsolated { trigger() } }
        var previous: NSWindow?
        for step in steps {
            var found: NSWindow? = step.same ? previous : nil
            for _ in 0..<(step.same ? 0 : 60) {
                await settle(100)
                if let w = Self.dialogWindow(parent, before), w !== previous {
                    found = w
                    break
                }
            }
            guard let window = found else {
                lines.append("FAIL \(step.name): no dialog showed"); failures += 1
                return
            }
            await settle(wait)
            window.contentView?.layoutSubtreeIfNeeded()
            shoot(window, step.name)
            lines.append("  \(step.name): \"\(window.title)\" \(Int(window.frame.width)) x \(Int(window.frame.height)) pt, buttons: "
                         + Self.buttons(in: window.contentView).map(\.title).joined(separator: " | "))
            if audits { audit(window, step.name) }
            if let then = step.then {
                then(window)
                previous = window
            } else {
                if step.same { Self.disclosure(window)?.performClick(nil) }
                Self.dismiss(window)
            }
        }
        // Whatever a step left up (a follow-up sheet) is cancelled too.
        for _ in 0..<20 {
            await settle(150)
            guard let w = Self.dialogWindow(parent, before) else { break }
            Self.dismiss(w)
        }
        await settle(300)
    }

    /// The document window's dialogs, in `look` (light or dark).
    mutating func dialogs(_ look: String) async {
        let c = controller
        let audits = look == "light"
        func send(_ action: Selector) -> @MainActor () -> Void {
            { [weak c] in
                c?.window?.makeKeyAndOrderFront(nil)
                NSApp.sendAction(action, to: c, from: nil)
            }
        }
        func one(_ name: String, _ action: Selector) async {
            await dialog([Step("\(name)-\(look)")], audits: audits, send(action))
        }
        c.window?.makeKeyAndOrderFront(nil)
        c.go(0)

        await dialog([Step("go-to-page-\(look)") { w in
            w.contentView.flatMap(Self.field)?.stringValue = "99"
            Self.button(w, "Go")?.performClick(nil)
        }, Step("go-to-page-error-\(look)")], audits: audits, send(NSSelectorFromString("goToPage:")))
        await one("properties", NSSelectorFromString("showDocumentProperties:"))
        await one("protect", NSSelectorFromString("protectDocument:"))
        await dialog(Step.more("reduce", look), audits: audits, send(NSSelectorFromString("reduceFileSize:")))
        await dialog(Step.more("flatten", look), audits: audits, send(NSSelectorFromString("flattenDocument:")))
        await dialog(Step.more("header-footer", look), audits: audits, send(NSSelectorFromString("addHeaderFooter:")))
        await dialog(Step.more("watermark", look), audits: audits, send(NSSelectorFromString("addWatermark:")))
        await one("crop", NSSelectorFromString("cropPages:"))
        await one("extract", NSSelectorFromString("extractPages:"))
        await dialog(Step.more("split", look), audits: audits, send(NSSelectorFromString("splitDocument:")))
        await dialog(Step.more("redact-pattern", look), audits: audits, send(NSSelectorFromString("redactByPattern:")))
        await one("sanitize", NSSelectorFromString("sanitizeDocument:"))
        await dialog(Step.more("ocr", look), audits: audits, send(NSSelectorFromString("recognizeText:")))
        await one("export-word", NSSelectorFromString("exportWord:"))
        await one("export-text", NSSelectorFromString("exportText:"))
        await one("signature-draw", NSSelectorFromString("drawSignature:"))
        await one("signature-type", NSSelectorFromString("typeSignature:"))
        await dialog(Step.more("sign-digitally", look), audits: audits, send(NSSelectorFromString("signDigitally:")))
        await one("ai-settings", NSSelectorFromString("aiSettings:"))
        await one("ai-summarize-not-set-up", NSSelectorFromString("aiSummarize:"))
        ScanWindowController.useDemoScanners()
        await dialog([Step("scanner-\(look)")], audits: audits, wait: 1500, send(NSSelectorFromString("insertFromScanner:")))
        await dialog([Step("compare-\(look)")], audits: audits) { CompareWindowController.pick() }
        await dialog(Step.more("batch", look), audits: audits, wait: 1000) { BatchWindowController.show() }
        await dialog([Step("combine-empty-\(look)")], audits: audits, wait: 1000) { _ = CombineWindowController.show() }
        await dialog([Step("report-problem-\(look)")], audits: audits, wait: 1000) { ReportProblemWindowController.show() }
        await dialog([Step("web-page-\(look)")], audits: audits) { Converting.fromWebPage() }
        await dialog([Step("password-open-\(look)")], audits: audits) { _ = PasswordPrompt.ask(file: "Synthetic.pdf", wrong: false) }
        await dialog([Step("password-wrong-\(look)")], audits: audits) { _ = PasswordPrompt.ask(file: "Synthetic.pdf", wrong: true) }
        await dialog([Step("password-permissions-\(look)")], audits: audits) { _ = AppPrompts().askOwnerPassword(wrong: false) }
        await dialog([Step("error-save-\(look)")], audits: audits) { [weak c] in
            c?.pdf.showError("The document couldn't be saved.", CocoaError(.fileWriteNoPermission))
        }
        await dialog([Step("progress-\(look)")], audits: audits) { [weak c] in
            guard let c else { return }
            let sheet = ProgressSheet(title: "Recognize Text", text: "Reading page 2 of 3…")
            sheet.update("Reading page 2 of 3…", 0.45)
            UxShots.keep = sheet
            sheet.begin(on: c.window)
        }
        UxShots.keep = nil
    }

    /// The progress sheet drawn above lives until its shot is taken.
    @MainActor static var keep: ProgressSheet?

    /// The window's disclosure triangle (More Options).
    static func disclosure(_ window: NSWindow) -> NSButton? {
        func find(_ v: NSView) -> NSButton? {
            if let b = v as? NSButton, b.bezelStyle == .disclosure, !b.isHidden { return b }
            for sub in v.subviews { if let b = find(sub) { return b } }
            return nil
        }
        return window.contentView.flatMap(find)
    }

    /// The first editable text field under `view`.
    static func field(_ view: NSView) -> NSTextField? {
        if let f = view as? NSTextField, f.isEditable { return f }
        for sub in view.subviews { if let f = field(sub) { return f } }
        return nil
    }
}
