import Foundation

/// Inkvolt Print's command palette (⌘K; the Windows app's Ctrl+K `PrintPalette`): every command of the sidebar, the
/// printer's toolbar, tabs and menus, then each printer to switch to and each scan preset to run, so everything is a few
/// keys away without the mouse. `build` lists what applies right now (a tab the printer doesn't have isn't offered); the app
/// runs an entry by its `id`. Mac differences: the tabs are the Mac's (Status, Scan, Printer settings: Print, Copy and Photos
/// are the Print menu's, not tabs), Set up in macOS, ⌘1…⌘9 and ⌘? for the shortcuts, SF Symbols for the icons, and no
/// What's new (the App Store shows it).
public enum PrintPalette {
    /// One line of the palette. `id`: "app:…", "section:n", "printer:…", "show:n" (a printer), "preset:n", "on:n:…".
    public struct Entry: Equatable, Sendable {
        public let id: String
        public let name: String
        public let category: String
        public let gesture: String
        /// An SF Symbol's name.
        public let glyph: String

        public init(_ id: String, _ name: String, _ category: String, _ gesture: String, _ glyph: String) {
            self.id = id
            self.name = name
            self.category = category
            self.gesture = gesture
            self.glyph = glyph
        }
    }

    /// What a printer offers.
    public struct Printer: Equatable, Sendable {
        public var name: String
        public var canPrint, canScan, canCopy, hasSettings, needsSetup, canFix, isNetwork: Bool
        public var snmpAccess: Bool

        public init(_ name: String, canPrint: Bool, canScan: Bool, canCopy: Bool, hasSettings: Bool, needsSetup: Bool, canFix: Bool,
                    isNetwork: Bool, snmpAccess: Bool = false) {
            self.name = name
            self.canPrint = canPrint
            self.canScan = canScan
            self.canCopy = canCopy
            self.hasSettings = hasSettings
            self.needsSetup = needsSetup
            self.canFix = canFix
            self.isNetwork = isNetwork
            self.snmpAccess = snmpAccess
        }
    }

    /// The Mac's tabs, in their order: Status, Scan, Printer settings (the section numbers the app's tabs go by).
    public static var sections: [String] { [loc("Status"), loc("Scan"), loc("Printer settings")] }

    /// "Go to …" for each of `sections`.
    private static func goTo(_ section: Int) -> String {
        switch section {
        case 0: loc("Go to Status")
        case 1: loc("Go to Scan")
        default: loc("Go to Printer settings")
        }
    }

    /// The printer menu's commands, in its order, as far as `p` offers them: (id after "printer:", name, glyph).
    private static func menu(_ p: Printer) -> [(id: String, name: String, glyph: String)] {
        var list: [(id: String, name: String, glyph: String)] = [("reconnect", loc("Reconnect"), "arrow.clockwise")]
        if p.canPrint { list.append(("photos", loc("Print photos…"), "photo")) }
        if p.canPrint { list.append(("batch", loc("Batch print: many files…"), "square.stack")) }
        if p.canFix { list.append(("fix", loc("Fix printing problems…"), "wrench.and.screwdriver")) }
        if p.isNetwork { list.append(("maintenance", loc("Printer maintenance…"), "wrench.and.screwdriver")) }
        if p.snmpAccess { list.append(("snmp", loc("SNMP access…"), "key")) }
        list.append(("remove", loc("Remove from Inkvolt Print…"), "trash"))
        return list
    }

    /// Every command the printer menu can have (the ids after "printer:").
    public static let menuIds: Set<String> = ["reconnect", "photos", "batch", "fix", "maintenance", "snmp", "remove"]

    /// The category of another printer's menu commands ("Name: command" entries, id "on:index:command").
    public static var otherPrinters: String { loc("Other printers") }

    /// The palette's entries: the selected printer's (`selectedIndex` in `printers`, -1 for none), the app's, the other
    /// printers, the scan presets; and, given `every` (each printer's offer, in `printers`' order), every other printer's menu
    /// commands as "Name: command", run on that printer without showing it first. Those wait for a word typed
    /// (`shownWhenEmpty`), so the list ⌘K opens on stays short.
    public static func build(_ selected: Printer?, _ selectedIndex: Int, _ printers: [String], _ presets: [String], every: [Printer]? = nil) -> [Entry] {
        var list: [Entry] = []
        if let p = selected {
            let category = p.name
            if p.canPrint { list.append(Entry("printer:print", loc("Print a PDF…"), category, "", "printer")) }
            if p.canScan { list.append(Entry("printer:scan", loc("Scan"), category, "", "scanner")) }
            if p.canPrint { list.append(Entry("printer:clipboard", loc("Print what's on the clipboard"), category, "⇧⌘V", "doc.on.clipboard")) }
            if p.canScan { list.append(Entry("printer:recent", loc("Recent scans…"), category, "", "clock")) }
            if p.needsSetup { list.append(Entry("printer:setup", loc("Set up in macOS"), category, "", "plus.circle")) }
            let has = [true, p.canScan, p.hasSettings]
            for i in sections.indices where has[i] { list.append(Entry("section:\(i)", goTo(i), category, "", "arrow.right.circle")) }
            for m in menu(p) { list.append(Entry("printer:\(m.id)", m.name, category, "", m.glyph)) }
        }
        list.append(Entry("app:add", loc("Add a printer…"), "", "⌘N", "plus"))
        list.append(Entry("app:setupwifi", loc("Set up a new printer's Wi-Fi…"), "", "", "wifi"))
        list.append(Entry("app:fleet", loc("Show the Fleet page (every printer)"), "", "⇧⌘F", "square.grid.2x2"))
        list.append(Entry("app:search", loc("Search again for printers"), "", "", "arrow.clockwise"))
        list.append(Entry("app:printlog", loc("Print log…"), "", "⌥⌘L", "list.bullet.rectangle"))
        list.append(Entry("app:settings", loc("Settings"), "", "⌘,", "gearshape"))
        list.append(Entry("app:help", loc("Help and shortcuts"), "", "⌘?", "questionmark.circle"))
        list.append(Entry("app:report", loc("Report a problem…"), "", "", "exclamationmark.bubble"))
        list.append(Entry("app:about", loc("About Inkvolt Print"), "", "", "info.circle"))
        for (i, name) in printers.enumerated() where i != selectedIndex {
            list.append(Entry("show:\(i)", loc("Show {0}", name), loc("Printers"), "", "printer"))
        }
        if let every {
            for (i, p) in every.enumerated() where i != selectedIndex {
                for m in menu(p) { list.append(Entry("on:\(i):\(m.id)", "\(p.name): \(m.name)", otherPrinters, "", m.glyph)) }
            }
        }
        if selected?.canScan == true {
            for (i, name) in presets.enumerated() {
                list.append(Entry("preset:\(i)", loc("Scan with {0}", name), loc("Scan presets"), i < 9 ? "⌘\(i + 1)" : "", "scanner"))
            }
        }
        return list
    }

    /// Listed before anything is typed: everything but other printers' commands.
    public static func shownWhenEmpty(_ e: Entry) -> Bool { !e.id.hasPrefix("on:") }

    /// "on:index:command": which printer and which of its menu commands; nil for any other id.
    public static func onOther(_ id: String) -> (index: Int, command: String)? {
        let parts = id.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 3, parts[0] == "on", let index = Int(parts[1]), index >= 0, menuIds.contains(parts[2]) else { return nil }
        return (index, parts[2])
    }

    /// The index after "section:", "show:" or "preset:" in `id`; nil for any other id or a number that isn't one.
    public static func number(_ id: String, after prefix: String) -> Int? {
        guard id.hasPrefix(prefix), let n = Int(id.dropFirst(prefix.count)), n >= 0 else { return nil }
        return n
    }

    /// The printer an entry's index means: the one at `index` in the list the palette was built from, while it's still on
    /// the list. The list moves while the palette is open (a queue comes, discovery answers, one is removed), and an index
    /// into the list as it is now would run Remove or Fix on another printer than the one the entry named. Nil when it's gone.
    public static func target<T: AnyObject>(_ index: Int, _ asBuilt: [T], _ now: [T]) -> T? {
        guard index >= 0, index < asBuilt.count else { return nil }
        let meant = asBuilt[index]
        return now.contains { $0 === meant } ? meant : nil
    }

    /// The palette's words when nothing matches: what to try next.
    public static func noMatch(_ query: String) -> String {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = q.count > 40 ? String(q.prefix(40)) + "…" : q
        return loc("Nothing matches “{0}”. Try another word, a printer's name or a scan preset.", shown)
    }
}
