import Foundation

/// The rules of the Mac app's accessibility audit (the `--ux-shots` dev step), here so they are tested: which controls a
/// screen reader must be able to name, and what counts as a name.
public enum AxAudit {
    /// The roles (NSAccessibility.Role raw values) of controls a person acts on: each needs a name VoiceOver can say.
    public static let actionRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton", "AXTextField", "AXSearchField",
        "AXComboBox", "AXSlider", "AXSegmentedControl", "AXIncrementor", "AXColorWell", "AXDisclosureTriangle",
        "AXTextArea", "AXLink", "AXToolbar", "AXTable", "AXOutline", "AXList",
    ]

    /// Why a control fails the audit, or nil when it passes. A control is named by its label, its title, or (for a
    /// field) its placeholder; a value alone isn't a name (it changes), nor is a tooltip alone. Hidden and disabled
    /// controls are left out by the caller.
    /// The name a control takes from the label beside it ("Save to folder:" names the field "Save to folder"); nil when
    /// the text isn't a label: empty, or a sentence (a note under the controls, a long caption) rather than a few words.
    public static func labelName(_ text: String) -> String? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix(":") { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t.count <= 40, !t.hasSuffix("."), t.split(separator: " ").count <= 6 else { return nil }
        return t
    }

    public static func problem(role: String, label: String?, title: String?, placeholder: String? = nil) -> String? {
        guard actionRoles.contains(role) else { return nil }
        func has(_ s: String?) -> Bool { !(s ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if has(label) || has(title) { return nil }
        if ["AXTextField", "AXSearchField", "AXComboBox", "AXTextArea"].contains(role) && has(placeholder) {
            return "named only by its placeholder (gone once typed in)"
        }
        return "no name"
    }
}

/// The document window's toolbar (Inkvolt PDF for Mac): a short default set, as Preview's, and the rest offered in
/// View › Customize Toolbar…. Identifiers are the NSToolbarItem identifiers' raw values.
public enum ToolbarLayout {
    public static let sidebar = "sidebar"
    public static let trackingSeparator = "sidebarSeparator"
    public static let zoom = "zoom"
    public static let highlight = "highlight"
    public static let markup = "markup"
    public static let fillSign = "fillSign"
    public static let share = "share"
    public static let search = "search"
    public static let rotate = "rotate"
    public static let print = "print"
    public static let organize = "organize"
    public static let editContent = "editContent"
    public static let redact = "redact"
    public static let inspector = "inspector"
    public static let commands = "commands"
    public static let pageNumber = "pageNumber"
    public static let flexibleSpace = "NSToolbarFlexibleSpaceItem"
    public static let space = "NSToolbarSpaceItem"

    /// What a new window shows: the sidebar, zoom, the two tools people reach for most (highlight; the markup tools
    /// shown on demand), Share and Search. Seven places, Preview's count.
    public static let defaults: [String] = [sidebar, trackingSeparator, zoom, flexibleSpace, highlight, markup, fillSign, share, search]

    /// Everything Customize Toolbar offers (the defaults included).
    public static let allowed: [String] = [
        sidebar, trackingSeparator, zoom, pageNumber, highlight, markup, fillSign, editContent, redact, organize, rotate,
        inspector, print, share, commands, search, flexibleSpace, space,
    ]

    /// Items the person may not remove because the window would lose its only way to them: none. Every default item
    /// is also in a menu with a shortcut (View, Tools, File, Edit), so a toolbar customized down to nothing loses nothing.
    public static func menuEquivalentExists(for identifier: String) -> Bool {
        [sidebar, zoom, highlight, markup, fillSign, share, search, rotate, print, organize, editContent, redact, inspector,
         commands, pageNumber].contains(identifier)
    }
}
