import AppKit
import PrintCore

/// Both Mac apps' accessibility audit of one window, sheet or alert from inside the app (no permission asked: an app may
/// read its own accessibility tree and send its own windows key events; outside inspection and screencapture don't work
/// over SSH). Walks what VoiceOver would walk and applies `AxAudit`'s rules to each element: a control's name, a
/// picture's description, a slider's or progress bar's value, a name that is code or a raw key, English in a window shown
/// in Spanish, a control VoiceOver can't reach, the dialog's title; then presses Tab round the window as a keyboard would
/// and lists where focus went, what it never reached and where it jumped back up. Inkvolt PDF's `UxShots` and Inkvolt
/// Print's `--report … --ax-audit` write `lines` into their reports. What it can't hear: whether the words make sense
/// read aloud, the order VoiceOver's own cursor takes inside SwiftUI, announcements as things change.
@MainActor
public struct AxWalk {
    public private(set) var lines: [String] = []
    public private(set) var findings = 0
    public private(set) var windows = 0
    /// The catalogs' English → Spanish when the interface is in Spanish; empty in English (no English check then).
    public let spanish: [String: String]

    public init(spanish: [String: String]) { self.spanish = spanish }

    private static func has(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A value as VoiceOver says it, or nil when there is none.
    private static func text(_ value: Any?) -> String? {
        switch value {
        case nil: return nil
        case let s as String: return s
        case let a as NSAttributedString: return a.string
        case let n as NSNumber: return n.stringValue
        default: return String(describing: value!)
        }
    }

    /// The window's own buttons, scroller parts and the toolbar's view: AppKit names them for VoiceOver outside this
    /// process's view, so they aren't this app's to name.
    private static func isSystems(_ element: Any) -> Bool {
        let kind = String(describing: type(of: element))
        if kind == "NSButtonCell", let owner = (element as? NSCell)?.controlView, String(describing: type(of: owner)) == "NSTabBarNewTabButton" {
            return true
        }
        return kind.hasPrefix("_NSTheme") || kind == "NSAccessibilityScrollerPart" || kind == "NSToolbarView" || kind.hasPrefix("NSWindow")
            || element is NSScroller
    }

    /// Audits `window` as `name` (the report's name for it); `tab` also walks its Tab order.
    public mutating func audit(_ window: NSWindow?, _ name: String, tab: Bool = true) {
        guard let window, let root = window.contentView?.superview ?? window.contentView else {
            lines.append("AX \(name): no window")
            findings += 1
            return
        }
        windows += 1
        root.layoutSubtreeIfNeeded()
        var problems: [String] = []
        var reached = Set<ObjectIdentifier>()
        var controls = 0
        var elements = 0
        var heading: String?

        let height = root.bounds.height
        func say(_ what: String, _ element: Any, _ shown: String?, _ why: String) {
            let owner = (element as? NSCell)?.controlView.map { " in \(type(of: $0))" } ?? ""
            let words = shown.map { " \"\($0.prefix(60))\"" } ?? ""
            // Where it is, so two alike are told apart (top-left origin, points).
            var place = ""
            if let view = (element as? NSView) ?? (element as? NSCell)?.controlView, view.window != nil {
                let r = view.convert(view.bounds, to: nil)
                place = " at \(Int(r.minX)),\(Int(height - r.maxY))" // bounded: a laid-out view's frame
                if let tip = view.toolTip ?? view.superview?.toolTip { place += " tip \"\(tip.prefix(40))\"" }
                if let id = view.identifier?.rawValue, !id.hasPrefix("_") { place += " id \(id)" }
                place += " under \(type(of: view.superview ?? view))"
            }
            problems.append("\(what) \(type(of: element))\(owner)\(words)\(place): \(why)")
        }

        func walk(_ element: Any, _ depth: Int) {
            guard depth < 50, let e = element as? NSAccessibilityProtocol else { return }
            if let v = element as? NSView, v.isHiddenOrHasHiddenAncestor { return }
            if let o = element as? NSObject { reached.insert(ObjectIdentifier(o)) }
            if let owner = (element as? NSCell)?.controlView { reached.insert(ObjectIdentifier(owner)) }
            let role = e.accessibilityRole()?.rawValue ?? ""
            if e.isAccessibilityElement() && !Self.isSystems(element) {
                elements += 1
                let label = e.accessibilityLabel(), title = e.accessibilityTitle()
                let shown = Self.has(label) ? label : Self.has(title) ? title : nil
                let value = Self.text(e.accessibilityValue())
                if AxAudit.actionRoles.contains(role) {
                    controls += 1
                    let placeholder = (element as? NSTextField)?.placeholderString
                    if let why = AxAudit.problem(role: role, label: label, title: title, placeholder: placeholder) { say(role, element, placeholder, why) }
                }
                if let why = AxAudit.imageProblem(role: role, label: label, title: title) { say(role, element, nil, why) }
                if let why = AxAudit.valueProblem(role: role, value: value) { say(role, element, shown, why) }
                if let shown {
                    if let why = AxAudit.rawText(shown) { say(role, element, shown, why) }
                    if let why = AxAudit.english(shown, spanish: spanish) { say(role, element, nil, why) }
                }
                if role == "AXStaticText", let words = value ?? shown {
                    if heading == nil, Self.has(words) { heading = words }
                    if let why = AxAudit.rawText(words, isName: false) { say(role, element, words, why) }
                    if let why = AxAudit.english(words, spanish: spanish) { say(role, element, nil, why) }
                }
                if let help = e.accessibilityHelp(), let why = AxAudit.english(help, spanish: spanish) { say(role + " help", element, nil, why) }
            }
            for child in e.accessibilityChildren() ?? [] { walk(child, depth + 1) }
        }
        walk(root, 0)

        // A control a person sees and acts on that VoiceOver never comes to (left out of the tree, or under an element
        // that hides its children).
        func hidden(_ view: NSView) {
            guard !view.isHidden else { return }
            // A search field's own buttons are its parts; a picture left out of the tree is decoration, said so on purpose.
            if view is NSSearchField { return }
            if let c = view as? NSControl, c.isEnabled, !(c is NSScroller), !(c is NSImageView), !Self.isSystems(c),
               !((c as? NSTextField).map { !$0.isEditable } ?? false), !reached.contains(ObjectIdentifier(c)),
               !(c.cell.map { reached.contains(ObjectIdentifier($0)) } ?? false), c.frame.width > 1, c.frame.height > 1 {
                say("hidden", c, (c as? NSButton)?.title ?? c.accessibilityLabel(), "VoiceOver can't reach it (not in the accessibility tree)")
            }
            for sub in view.subviews { hidden(sub) }
        }
        if let content = window.contentView { hidden(content) }

        let title = AxAudit.dialogTitle(title: window.title, label: window.accessibilityLabel(), heading: heading)
        if let title {
            if let why = AxAudit.english(title, spanish: spanish) { problems.append("title: \(why)") }
            if let why = AxAudit.rawText(title, isName: false) { problems.append("title \"\(title)\": \(why)") }
        } else {
            problems.append("title: none (VoiceOver says only \"window\" or \"sheet\" as it opens)")
        }
        let unique = Array(Set(problems)).sorted()
        lines.append("AX \(name): \"\(title ?? "")\", \(elements) elements, \(controls) controls, \(unique.count) findings\(window.isKeyWindow ? "" : " (not key)")")
        for p in unique { lines.append("  FINDING \(name): \(p)") }
        findings += unique.count
        if tab { tabOrder(window, name) }
    }

    /// What VoiceOver and the report call a stop: its role and name.
    private static func describe(_ view: NSView) -> String {
        // A field's role is its cell's (the view says AXUnknown).
        let own = view.accessibilityRole()?.rawValue
        let raw = own == nil || own == "AXUnknown" ? (view as? NSControl)?.cell?.accessibilityRole()?.rawValue : own
        let role = raw?.replacingOccurrences(of: "AX", with: "") ?? "\(type(of: view))"
        let words = [view.accessibilityLabel(), view.accessibilityTitle(), (view as? NSButton)?.title, (view as? NSTextField)?.placeholderString,
                     (view as? NSControl)?.cell?.accessibilityLabel()].compactMap { $0 }.first { has($0) }
        return words.map { "\(role) \"\($0.prefix(30))\"" } ?? role
    }

    /// The view that has the keyboard: a field's own view while its field editor types in it.
    private static func focused(_ window: NSWindow) -> NSView? {
        guard let responder = window.firstResponder else { return nil }
        if let editor = responder as? NSTextView, editor.isFieldEditor { return (editor.delegate as? NSView) ?? editor }
        return responder as? NSView
    }

    /// Presses Tab round `window` (at most 80 times, until focus comes back to where it started) and lists the stops.
    private mutating func tabOrder(_ window: NSWindow, _ name: String) {
        guard let root = window.contentView?.superview ?? window.contentView else { return }
        let height = root.bounds.height
        func box(_ v: NSView) -> AxAudit.Box {
            let r = v.convert(v.bounds, to: nil)
            return AxAudit.Box(x: Double(r.minX), y: Double(height - r.maxY), width: Double(r.width), height: Double(r.height))
        }
        // What Tab may stop on with the Mac's keyboard setting as it is (Full Keyboard Access off: fields and lists only).
        var focusable: [NSView] = []
        func collect(_ v: NSView) {
            guard !v.isHidden else { return }
            if v.canBecomeKeyView, !(v is NSClipView), !Self.isSystems(v), (v as? NSControl)?.isEnabled ?? true, v.frame.width > 1 {
                focusable.append(v)
            }
            for sub in v.subviews { collect(sub) }
        }
        if let content = window.contentView { collect(content) }

        let start = Self.focused(window)
        // The control that has the keyboard as the window opens is the order's first stop (the window itself isn't one).
        var stops: [NSView] = []
        if let start, start.canBecomeKeyView, start !== window.contentView { stops.append(start) }
        var stuck = 0
        for _ in 0..<80 {
            guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
                                           isARepeat: false, keyCode: 48) else { break }
            window.sendEvent(e)
            guard let now = Self.focused(window) else { stuck += 1; if stuck > 2 { break }; continue }
            if let first = stops.first, now === first { break }
            if let last = stops.last, now === last { stuck += 1; if stuck > 2 { break }; continue }
            stops.append(now)
        }
        if let start { window.makeFirstResponder(start) }
        let ids = stops.map { ObjectIdentifier($0) }
        let missed = focusable.filter { v in !ids.contains(ObjectIdentifier(v)) && !stops.contains { v.isDescendant(of: $0) || $0.isDescendant(of: v) } }
        let back = AxAudit.backwardSteps(stops.map(box))
        let keyboard = NSApp.isFullKeyboardAccessEnabled ? "Full Keyboard Access on" : "Full Keyboard Access off: fields and lists only"
        lines.append("  TAB \(name): \(stops.count) stops (\(keyboard)): " + (stops.isEmpty ? "none" : stops.map(Self.describe).joined(separator: " → ")))
        if !missed.isEmpty {
            lines.append("  FINDING \(name): Tab never reaches " + missed.map(Self.describe).joined(separator: ", "))
            findings += 1
        }
        for i in back {
            lines.append("  FINDING \(name): Tab goes back up from \(Self.describe(stops[i - 1])) to \(Self.describe(stops[i]))")
            findings += 1
        }
    }

    /// A line of the walk's own (a dialog that didn't show), counted as a finding when `finding`.
    public mutating func note(_ line: String, finding: Bool) {
        lines.append(finding ? "  FINDING " + line : "  " + line)
        if finding { findings += 1 }
    }

    /// The report's closing line.
    public var summary: String { "AX RESULT: \(windows) windows, \(findings) findings" }

    /// The catalogs' English → Spanish of a compiled table in the app's bundle (`es.lproj/<table>.strings`), for
    /// `spanish`: only its translated sentences.
    public static func table(_ name: String, _ language: String = "es", bundle: Bundle = .main) -> [String: String] {
        guard let url = bundle.url(forResource: name, withExtension: "strings", subdirectory: nil, localization: language),
              let dictionary = NSDictionary(contentsOf: url) as? [String: String] else { return [:] }
        return dictionary
    }
}
