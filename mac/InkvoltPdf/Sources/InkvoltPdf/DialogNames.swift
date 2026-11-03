import AppKit
import PdfCore

/// Names every dialog control for VoiceOver from the label a sighted person reads beside it (UX review, round 2: the
/// audit of the sheets and alerts found 88 controls VoiceOver couldn't name, mostly fields and pop-ups after a
/// "Label:" in a grid or a row, and controls named on themselves but not on the cell AppKit reports). Runs whenever a
/// window or sheet becomes key, so every alert, sheet and panel is covered without each one naming its controls; a name
/// a control already has is kept.
@MainActor
enum DialogNames {
    private static var observer: NSObjectProtocol?

    static func start() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { note in
            let window = note.object as? NSWindow
            MainActor.assumeIsolated { fill(window?.contentView) }
        }
    }

    /// The text of a label (not a field a person types in), without its colon; nil for anything else.
    static func labelText(_ view: NSView?) -> String? {
        guard let f = view as? NSTextField, !f.isEditable, !(f is NSSecureTextField) else { return nil }
        return AxAudit.labelName(f.stringValue)
    }

    static func name(of control: NSControl) -> String? {
        // A pop-up's title is its choice, not its name.
        let title = control is NSPopUpButton ? nil : (control as? NSButton)?.title
        for s in [control.accessibilityLabel(), control.cell?.accessibilityLabel(), title] {
            if let s, !s.trimmingCharacters(in: .whitespaces).isEmpty { return s }
        }
        return nil
    }

    /// The first control under `view` (itself included) that a person acts on and has no name.
    private static func unnamed(_ view: NSView) -> NSControl? {
        if let c = view as? NSControl, labelText(c) == nil, !(c is NSTextField && !(c as! NSTextField).isEditable) {
            return name(of: c) == nil ? c : nil
        }
        if view is NSGridView { return nil }
        for sub in view.subviews where !sub.isHidden { if let c = unnamed(sub) { return c } }
        return nil
    }

    static func fill(_ root: NSView?) {
        guard let root else { return }
        func walk(_ view: NSView) {
            if let grid = view as? NSGridView {
                for r in 0..<grid.numberOfRows {
                    let row = grid.row(at: r)
                    guard row.numberOfCells >= 2, let title = labelText(row.cell(at: 0).contentView),
                          let content = row.cell(at: 1).contentView, let control = unnamed(content) else { continue }
                    control.setAccessibleName(title)
                }
            }
            if let stack = view as? NSStackView {
                let views = stack.arrangedSubviews
                for (i, v) in views.enumerated() where i + 1 < views.count {
                    guard let title = labelText(v), let control = views[i + 1] as? NSControl, labelText(control) == nil,
                          name(of: control) == nil else { continue }
                    control.setAccessibleName(title)
                }
            }
            // Named on the control only: AppKit reports the cell, so the cell gets the name too.
            if let c = view as? NSControl, let given = c.accessibilityLabel(), !given.isEmpty,
               c.cell?.accessibilityLabel()?.isEmpty ?? true {
                c.cell?.setAccessibilityLabel(given)
            }
            for sub in view.subviews { walk(sub) }
        }
        walk(root)
    }
}
