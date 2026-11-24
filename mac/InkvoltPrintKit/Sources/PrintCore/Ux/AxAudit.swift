import Foundation

/// The rules of both Mac apps' accessibility audit (Inkvolt PDF's `--ux-shots` and `--ax-audit`, Inkvolt Print's
/// `--report … --ax-audit`; the walk itself is PrintMac's `AxWalk`), here so they are tested on the PC: which elements a
/// screen reader must be able to name, what counts as a name, a name that is a raw key, code or English in a Spanish
/// window, a value a slider or progress bar must say, a dialog's title, and the order Tab moves in. A Mac addition, no
/// Windows counterpart.
public enum AxAudit {
    /// The roles (NSAccessibility.Role raw values) of controls a person acts on: each needs a name VoiceOver can say.
    public static let actionRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXSearchField",
        "AXComboBox", "AXSlider", "AXSegmentedControl", "AXIncrementor", "AXColorWell", "AXDisclosureTriangle",
        "AXTextArea", "AXLink", "AXToolbar", "AXTable", "AXOutline", "AXList",
    ]

    /// The roles whose value is what VoiceOver says after the name ("Scale, 80 percent"): each must expose one.
    public static let valueRoles: Set<String> = [
        "AXSlider", "AXIncrementor", "AXProgressIndicator", "AXLevelIndicator", "AXValueIndicator",
    ]

    /// The roles of a field a person types in: a placeholder there is gone once typed in, so it isn't a name.
    static let fieldRoles: Set<String> = ["AXTextField", "AXSearchField", "AXComboBox", "AXTextArea"]

    /// The name a control takes from the label beside it ("Save to folder:" names the field "Save to folder"); nil when
    /// the text isn't a label: empty, or a sentence (a note under the controls, a long caption) rather than a few words.
    public static func labelName(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(":") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 40, !t.hasSuffix("."), t.split(separator: " ").count <= 6 else { return nil }
        return t
    }

    private static func has(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Why a control fails the naming rule, or nil when it passes. A control is named by its label, its title, or (for a
    /// field) its placeholder; a value alone isn't a name (it changes), nor is a tooltip alone. Hidden and disabled
    /// controls are left out by the caller.
    public static func problem(role: String, label: String?, title: String?, placeholder: String? = nil) -> String? {
        guard actionRoles.contains(role) else { return nil }
        if has(label) || has(title) { return nil }
        if fieldRoles.contains(role) && has(placeholder) {
            return "named only by its placeholder (gone once typed in)"
        }
        return "no name"
    }

    /// A picture VoiceOver stops on (an accessibility element) must say what it shows; one that only decorates is left
    /// out of the accessibility tree instead.
    public static func imageProblem(role: String, label: String?, title: String?) -> String? {
        guard role == "AXImage", !has(label), !has(title) else { return nil }
        return "a picture with no description (describe it, or leave it out of accessibility if it only decorates)"
    }

    /// A slider, stepper, level or progress bar must say where it stands.
    public static func valueProblem(role: String, value: String?) -> String? {
        guard valueRoles.contains(role), !has(value) else { return nil }
        return "no value (VoiceOver can't say where it stands)"
    }

    /// Why `name` (a label, a title, a static text's words) reads as code rather than words: a `{0}` or `%@` never
    /// filled in, a catalog key's context (`Black [ink]`), an SF Symbol's name (`square.and.arrow.up`), an identifier
    /// (`aiSettings`, `scan_backs`). Nil for words. `isName`: a control's or picture's name, where a symbol's name or
    /// an identifier is code; a static text may hold a file's or a host's name, so only the first three apply there.
    public static func rawText(_ name: String, isName: Bool = true) -> String? {
        let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        // Not a regular expression's count (`\d{4}`, `[0-9]{2}`).
        if t.range(of: #"(?<![\w\\\])}])\{[0-9]+\}"#, options: .regularExpression) != nil { return "a {n} placeholder left in" }
        if t.range(of: #"%(\d+\$)?(@|l{0,2}[dui]|f|s)(?![A-Za-z])"#, options: .regularExpression) != nil { return "a % format left in" }
        if t.range(of: #"\S \[[a-z][a-z ]*\]$"#, options: .regularExpression) != nil { return "a catalog key's [context] left in" }
        guard isName else { return nil }
        let fileTypes: Set<String> = ["pdf", "jpg", "jpeg", "png", "tiff", "heic", "docx", "xlsx", "pptx", "txt", "csv", "json", "html",
                                      "m4a", "wav", "zip", "local"]
        if t.range(of: #"^[a-z0-9]+(\.[a-z0-9]+)+$"#, options: .regularExpression) != nil, t.rangeOfCharacter(from: .letters) != nil,
           !fileTypes.contains(String(t.split(separator: ".").last ?? "")) {
            return "a symbol's or key's name, not words"
        }
        let brands: Set<String> = ["iPhone", "iPad", "iPod", "iCloud", "iOS", "macOS", "iPadOS", "eSCL", "iMac"]
        if !brands.contains(t), t.range(of: #"^[a-z]+([A-Z][a-z0-9]*)+$"#, options: .regularExpression) != nil
            || t.range(of: #"^[a-z]+(_[a-z0-9]+)+$"#, options: .regularExpression) != nil {
            return "an identifier, not words"
        }
        return nil
    }

    /// English in a window shown in Spanish: `name`, or one of its parts between ", ", ": ", " · " and " — ", is an
    /// English sentence of `spanish` (the catalogs' English → Spanish) whose Spanish differs. Nil when it reads as
    /// Spanish, or isn't one of the catalogs' sentences (a file name, a printer's name, a number).
    public static func english(_ name: String, spanish: [String: String]) -> String? {
        let whole = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !whole.isEmpty, !spanish.isEmpty else { return nil }
        var parts = [whole]
        for separator in [", ", ": ", " · ", " — ", "\n"] {
            parts = parts.flatMap { $0.components(separatedBy: separator) }
        }
        var candidates = [whole] + parts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        // "Copies:" is the label of the catalog's "Copies:"; the audit's own label names drop the colon.
        candidates += candidates.map { $0 + ":" } + candidates.map { $0 + "…" }
        for c in candidates where c.count > 1 {
            guard let es = spanish[c], !es.isEmpty, es != c, es.lowercased() != c.lowercased() else { continue }
            return "English in Spanish: \"\(c)\" (catalog: \"\(es)\")"
        }
        return nil
    }

    /// A dialog's title for VoiceOver (it says it as the window or sheet opens): the window's title, else its
    /// first words (an alert's message, a sheet's heading), else its accessibility label (AppKit's "alert" for an
    /// NSAlert's window is its kind, not its title, so it comes last). Nil when it has none.
    public static func dialogTitle(title: String?, label: String?, heading: String?) -> String? {
        for s in [title, heading, label] where has(s) { return s!.trimmingCharacters(in: .whitespacesAndNewlines) }
        return nil
    }

    /// A rectangle in a window, in points, its origin top-left (so y grows downward, as a person reads).
    public struct Box: Sendable, Equatable {
        public let x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            (self.x, self.y, self.width, self.height) = (x, y, width, height)
        }
        var maxX: Double { x + width }
        var maxY: Double { y + height }
    }

    /// The steps of a Tab order that go back up the window: `stops[i]` follows `stops[i - 1]` but sits above it (its
    /// top above the other's middle) without being in a column to its right. Reading order (left to right, then down)
    /// and columns (down one column, then the next) both pass; the step from the last stop back to the first is the
    /// loop closing, not checked. Answers the indexes of the stops reached that way.
    public static func backwardSteps(_ stops: [Box]) -> [Int] {
        guard stops.count > 2 else { return [] }
        var out: [Int] = []
        for i in 1..<stops.count {
            let (a, b) = (stops[i - 1], stops[i])
            let above = b.y + 4 < a.y + a.height / 2 && b.maxY <= a.y + 4
            let nextColumn = b.x >= a.maxX - 4
            if above && !nextColumn { out.append(i) }
        }
        return out
    }

    /// The stops of `focusable` that Tab never reached in `reached` (each an element's id), in `focusable`'s order.
    public static func unreached(_ focusable: [String], _ reached: [String]) -> [String] {
        let seen = Set(reached)
        return focusable.filter { !seen.contains($0) }
    }
}
