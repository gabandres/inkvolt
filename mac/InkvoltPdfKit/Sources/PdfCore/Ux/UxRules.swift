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

/// The document window's toolbar (Inkvolt PDF for Mac): the command bar's groups (`CommandBar`, approved 2026-11-08) by
/// default, with the sidebar and Search, and the rest offered in View › Customize Toolbar…. Identifiers are the
/// NSToolbarItem identifiers' raw values; a group's is "bar." and its `CommandBar` id. The toolbar's own identifier
/// changed with the command bar, so a toolbar customized before it starts again from these defaults.
public enum ToolbarLayout {
    /// The NSToolbar's identifier (its saved customization's key).
    public static let toolbarIdentifier = "InkvoltPdfDocumentBar"
    public static let sidebar = "sidebar"
    public static let trackingSeparator = "sidebarSeparator"
    public static let zoom = "zoom"
    public static let markup = "markup"
    public static let share = "share"
    public static let search = "search"
    public static let rotate = "rotate"
    public static let print = "print"
    public static let inspector = "inspector"
    public static let commands = "commands"
    public static let pageNumber = "pageNumber"
    public static let flexibleSpace = "NSToolbarFlexibleSpaceItem"
    public static let space = "NSToolbarSpaceItem"

    /// A command bar group's identifier ("bar.Convert").
    public static func group(_ id: String) -> String { "bar." + id }
    /// The `CommandBar` group an identifier names, if it is one.
    public static func groupId(_ identifier: String) -> String? {
        identifier.hasPrefix("bar.") ? String(identifier.dropFirst(4)) : nil
    }

    /// The command bar's groups in their order, the pointer tools first.
    public static let groups: [String] = ["Pointer", "Edit", "Convert", "Comment", "FillSign", "Organize", "Protect", "ScanOcr"].map(group)

    /// What a new window shows: the sidebar, the command bar, Search on the trailing edge (HIG).
    public static let defaults: [String] = [sidebar, trackingSeparator] + groups + [flexibleSpace, search]

    /// Everything Customize Toolbar offers (the defaults included).
    public static let allowed: [String] = [sidebar, trackingSeparator] + groups + [
        zoom, pageNumber, markup, rotate, inspector, print, share, commands, search, flexibleSpace, space,
    ]

    /// Items the person may not remove because the window would lose its only way to them: none. Every item is also in
    /// a menu with a shortcut (View, Tools, File, Edit, Pages), and every group's commands are in the menu bar
    /// (`CommandBarTests`), so a toolbar customized down to nothing loses nothing.
    public static func menuEquivalentExists(for identifier: String) -> Bool {
        groupId(identifier) != nil || [sidebar, zoom, markup, share, search, rotate, print, inspector, commands, pageNumber].contains(identifier)
    }
}
