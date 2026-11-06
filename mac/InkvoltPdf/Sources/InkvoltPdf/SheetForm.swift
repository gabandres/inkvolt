import AppKit
import PdfCore
import PrintCore

/// The controls of a dialog (an alert's accessory view), laid out as the HIG's sheets are: one column of labels, right
/// aligned with a colon, then the controls; the settings most people change in sight, the rest behind a "More Options"
/// disclosure triangle that remembers whether it was open (UX review, round 2). It sizes itself to what it holds, so
/// nothing is clipped and nothing leaves a blank band, and grows or shrinks the alert when the triangle turns.
@MainActor
final class SheetForm: NSObject {
    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private var advanced: [NSGridRow] = []
    private let toggle = NSButton()
    private let toggleLabel = NSTextField(labelWithString: loc("More Options"))
    private weak var alert: NSAlert?
    /// The UserDefaults key that keeps the triangle open or closed (each dialog its own).
    private let key: String
    /// The widest a wrapping note may be.
    let width: CGFloat
    /// Runs after the triangle turns (a dialog that hides rows of its own keeps them hidden).
    var onToggle: (() -> Void)?

    init(_ id: String, width: CGFloat = 420) {
        key = "MoreOptions." + id
        self.width = width
        super.init()
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        grid.column(at: 0).xPlacement = .trailing
        grid.rowAlignment = .firstBaseline
    }

    var isOpen: Bool { AppSettings.defaults.bool(forKey: key) }

    private func add(_ label: String?, _ views: [NSView], advanced more: Bool) -> NSGridRow {
        let content: NSView = views.count == 1 ? views[0] : Self.line(views)
        let title: NSView = label.map { NSTextField(labelWithString: $0.isEmpty ? "" : $0 + ":") } ?? NSGridCell.emptyContentView
        let row = grid.addRow(with: [title, content])
        if more { advanced.append(row) }
        return row
    }

    /// A labelled row ("Pages:" then the controls); nil label: the controls under the previous ones, no label.
    @discardableResult
    func row(_ label: String?, _ views: NSView..., advanced more: Bool = false) -> NSGridRow {
        add(label, views, advanced: more)
    }

    /// A short grey note under the controls (what a choice does), wrapping at the form's width.
    @discardableResult
    func note(_ text: String, advanced more: Bool = false) -> NSTextField {
        let label = Self.caption(text, width: width - 100)
        _ = add(nil, [label], advanced: more)
        return label
    }

    /// A view across both columns (a list, a drawing area).
    @discardableResult
    func wide(_ view: NSView, advanced more: Bool = false) -> NSGridRow {
        let row = grid.addRow(with: [view, NSGridCell.emptyContentView])
        row.mergeCells(in: NSRange(location: 0, length: 2))
        row.cell(at: 0).xPlacement = .leading
        if more { advanced.append(row) }
        return row
    }

    /// Puts the form in `alert` (the triangle first, when some rows are advanced) at its size.
    func install(in alert: NSAlert) {
        self.alert = alert
        // A dialog asked again (after a problem) installs the same form again: the triangle goes in once.
        if !advanced.isEmpty && toggle.superview == nil {
            toggle.bezelStyle = .disclosure
            toggle.setButtonType(.pushOnPushOff)
            toggle.title = ""
            toggle.state = isOpen ? .on : .off
            toggle.target = self
            toggle.action = #selector(toggled)
            toggle.setAccessibilityLabel(loc("More Options"))
            toggleLabel.textColor = .secondaryLabelColor
            let click = NSClickGestureRecognizer(target: self, action: #selector(labelClicked))
            toggleLabel.addGestureRecognizer(click)
            let first = (0..<grid.numberOfRows).first { grid.row(at: $0) === advanced[0] } ?? grid.numberOfRows
            let row = grid.insertRow(at: first, with: [NSGridCell.emptyContentView, Self.line([toggle, toggleLabel])])
            row.topPadding = 4
        }
        apply()
        alert.accessoryView = grid
        objc_setAssociatedObject(alert, &Self.formKey, self, .OBJC_ASSOCIATION_RETAIN)
    }

    private static var formKey = 0

    @objc private func labelClicked() {
        toggle.state = toggle.state == .on ? .off : .on
        toggled()
    }

    @objc private func toggled() {
        AppSettings.defaults.set(toggle.state == .on, forKey: key)
        apply()
        alert?.layout()
    }

    /// Opens or closes the triangle (the UX shots' second state).
    func setOpen(_ open: Bool) {
        toggle.state = open ? .on : .off
        toggled()
    }

    /// Shows or hides an advanced row of a dialog's own choosing too, then fits again.
    func refit() {
        grid.layoutSubtreeIfNeeded()
        grid.setFrameSize(NSSize(width: max(fullWidth, grid.fittingSize.width), height: grid.fittingSize.height))
        alert?.layout()
    }

    /// The width with every row shown: the alert keeps it when More Options opens (it grows only in height then).
    private var fullWidth: CGFloat = 0

    private func apply() {
        if fullWidth == 0 {
            for row in advanced { row.isHidden = false }
            grid.layoutSubtreeIfNeeded()
            fullWidth = grid.fittingSize.width
        }
        let open = toggle.state == .on
        for row in advanced { row.isHidden = !open }
        onToggle?()
        grid.layoutSubtreeIfNeeded()
        grid.setFrameSize(NSSize(width: max(fullWidth, grid.fittingSize.width), height: grid.fittingSize.height))
    }

    static func line(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.spacing = 8
        stack.alignment = .firstBaseline
        return stack
    }

    static func caption(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        label.preferredMaxLayoutWidth = width
        label.widthAnchor.constraint(lessThanOrEqualToConstant: width).isActive = true
        return label
    }

    static func number(_ text: String, width: CGFloat = 60, label: String) -> NSTextField {
        let field = NSTextField(string: text)
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.setAccessibleName(label)
        return field
    }
}

/// Runs a closure when a control acts (a pop-up's choice that shows or hides another control).
@MainActor
final class ControlAction: NSObject {
    private let action: () -> Void
    init(_ control: NSControl, _ action: @escaping () -> Void) {
        self.action = action
        super.init()
        control.target = self
        control.action = #selector(fire)
        objc_setAssociatedObject(control, &Self.key, self, .OBJC_ASSOCIATION_RETAIN)
    }

    private static var key = 0
    @objc private func fire() { action() }
}

extension NSAlert {
    /// An error's words for a person: the app's own message, else the system's description; never a type name or
    /// a debug dump (UX review, round 2: "The document couldn't be saved." showed `Error Domain=NSCocoaErrorDomain…`).
    static func plainText(_ error: Error) -> String {
        if let e = error as? PdfEditError { return e.message }
        if let e = error as? PdfEngineError { return e.message }
        let ns = error as NSError
        let text = ErrorWords.plain(description: ns.localizedDescription, reason: ns.localizedFailureReason,
                                    suggestion: ns.localizedRecoverySuggestion, isCocoa: ns.domain == NSCocoaErrorDomain || ns.domain == NSPOSIXErrorDomain)
        return text
    }
}
