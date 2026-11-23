import AppKit
import PdfCore

/// Two documents side by side (roadmap 4.9) on the Mac. AppKit owns the tabs: a document's window is a tab, Window ›
/// Move Tab to New Window, a tab dragged out of the bar or onto another window's bar, and Merge All Windows are its own.
/// This keeps PdfCore's `DocumentWindows` (Windows' rules, one window = one group of tabs) in step with what AppKit did
/// and asks it: a file open once (asked for again, in any case or through a link, its tab comes forward, and one on its
/// way isn't read twice), the window in use (a document opened from Finder, Open Recent, the start page or another
/// window joins the group of tabs used last, not whichever window happens to be in front), and File › New Window (the
/// next document opened gets a window of its own). What is remembered for the next start is macOS's window restoration
/// (PLAN, "Mac differences"); a tab carries its sheets and running work with it, so no move is refused as busy.
@MainActor
final class WindowHub {
    static let shared = WindowHub()

    let rules = DocumentWindows()
    /// File › New Window (or the Dock menu's): the next document opened gets a window of its own.
    private(set) var wantsNewWindow = false
    /// The document windows placed (shown at least once and not closed), by controller, each with its tab number in
    /// `rules`. Keyed by the controller, not its window: a closed window's address can come back as a new window's.
    private var placed: [ObjectIdentifier: (controller: DocumentWindowController, tab: Int64)] = [:]

    private func entry(_ window: NSWindow) -> (controller: DocumentWindowController, tab: Int64)? {
        placed.values.first { $0.controller.window === window }
    }
    private var nextTab: Int64 = 1

    /// The path a file is compared by: absolute, without `.` or `..`, links followed (/var is /private/var).
    static func fullPath(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }

    // MARK: What AppKit did

    /// Brings `rules` in step with the groups of tabs AppKit shows: tabs closed are removed, new ones added, a tab dragged
    /// to another group (or out into a window of its own) moved there, and the order within each group kept.
    func sync() {
        let used = rules.active.flatMap { rules.tabs(of: $0).first }
        // A window whose document went without windowWillClose reaching here.
        for (key, e) in placed where e.controller.window == nil || e.controller.document == nil { placed[key] = nil }
        // Windows shown without showWindow (macOS's window restoration at launch): counted as they are, not re-tabbed. A
        // window not yet on screen is left to `place`, which showWindow calls before it shows.
        for case let c as DocumentWindowController in NSApp.windows.compactMap(\.windowController)
        where placed[ObjectIdentifier(c)] == nil && c.document != nil && c.window?.isVisible == true {
            placed[ObjectIdentifier(c)] = (c, nextTab)
            nextTab += 1
        }
        // AppKit's groups, each its document windows in the tab bar's order.
        var groups: [[(controller: DocumentWindowController, tab: Int64)]] = []
        var grouped: Set<ObjectIdentifier> = []
        for first in placed.values.sorted(by: { $0.tab < $1.tab }) {
            guard let window = first.controller.window, !grouped.contains(ObjectIdentifier(window)) else { continue }
            let members = (window.tabbedWindows ?? [window]).compactMap { w in entry(w) }
            for m in members { if let w = m.controller.window { grouped.insert(ObjectIdentifier(w)) } }
            if !members.isEmpty { groups.append(members) }
        }
        // Tabs gone (their window closed without telling, which windowWillClose does).
        let present = Set(groups.flatMap { $0.map(\.tab) })
        for window in rules.windows {
            for tab in rules.tabs(of: window) where !present.contains(tab) { rules.remove(tab) }
        }
        // Each group keeps the window that holds most of its tabs, larger groups choosing first; the rest open new ones.
        var claimed: Set<Int> = []
        for group in groups.sorted(by: { $0.count > $1.count }) {
            var counts: [Int: Int] = [:]
            for m in group { if let w = rules.window(of: m.tab) { counts[w, default: 0] += 1 } }
            // Most of the group's tabs; on a tie, the window opened first.
            let free = counts.filter { !claimed.contains($0.key) }.sorted { a, b in a.value != b.value ? a.value > b.value : a.key < b.key }
            let target = free.first?.key ?? rules.open()
            claimed.insert(target)
            for (i, m) in group.enumerated() {
                let path = m.controller.pdf.fileURL.map(Self.fullPath)
                if rules.window(of: m.tab) == nil {
                    try? rules.add(target, m.tab, path, at: i)
                } else {
                    rules.setPath(m.tab, path)
                    if rules.window(of: m.tab) != target || rules.tabs(of: target).firstIndex(of: m.tab) != i {
                        _ = try? rules.move(m.tab, to: target, at: i)
                    }
                }
            }
        }
        for window in rules.windows where !claimed.contains(window) { rules.close(window) }
        // Moves made the window they went to the one in use; the one in use is the main document window's, else as it was.
        if let main = NSApp.mainWindow, let tab = entry(main)?.tab, let w = rules.window(of: tab) {
            rules.activate(w)
        } else if let used, let w = rules.window(of: used) {
            rules.activate(w)
        }
    }

    /// The document window showing `path` (a full path), in any group.
    func controller(showing path: String) -> DocumentWindowController? {
        sync()
        guard let found = rules.findFile(path) else { return nil }
        return placed.values.first { $0.tab == found.tab }?.controller
    }

    /// The document windows of the group of tabs used last, in the tab bar's order.
    var activeGroup: [DocumentWindowController] { group(rules.active) }

    func group(_ window: Int?) -> [DocumentWindowController] {
        guard let window else { return [] }
        return rules.tabs(of: window).compactMap { tab in placed.values.first { $0.tab == tab }?.controller }
    }

    /// The window number in `rules` of `controller`'s group of tabs.
    func window(of controller: DocumentWindowController) -> Int? {
        sync()
        guard let tab = placed[ObjectIdentifier(controller)]?.tab else { return nil }
        return rules.window(of: tab)
    }

    // MARK: The windows' calls

    /// A document window is about to show for the first time: it joins the group of tabs used last, or gets a window of
    /// its own after File › New Window. Later calls (the document asked for again) do nothing.
    func place(_ controller: DocumentWindowController) {
        guard let window = controller.window, placed[ObjectIdentifier(controller)] == nil else { return }
        sync()
        let host = activeGroup.compactMap(\.window).first { $0 !== window }
        placed[ObjectIdentifier(controller)] = (controller, nextTab)
        nextTab += 1
        if wantsNewWindow {
            wantsNewWindow = false
            // Not tabbed when it is shown; then it takes and gives tabs as any other.
            window.tabbingMode = .disallowed
            DispatchQueue.main.async { MainActor.assumeIsolated { window.tabbingMode = .preferred } }
        } else if let host, window.tabbedWindows == nil {
            host.addTabbedWindow(window, ordered: .above)
        }
    }

    /// The window became the main one: its group is the one in use.
    func activated(_ controller: DocumentWindowController) {
        sync()
        guard let tab = placed[ObjectIdentifier(controller)]?.tab, let w = rules.window(of: tab) else { return }
        rules.activate(w)
    }

    /// The document window closed.
    func closed(_ controller: DocumentWindowController) {
        guard let gone = placed.removeValue(forKey: ObjectIdentifier(controller)) else { return }
        rules.remove(gone.tab)
        sync()
    }

    /// File › New Window (and the Dock menu's): the start page, and the next document opened gets a window of its own.
    /// With no document open, any document gets one anyway.
    func newWindow() {
        wantsNewWindow = !placed.isEmpty
        StartWindowController.show()
    }

    /// The start page closed without opening anything: New Window is forgotten.
    func startPageClosed() { wantsNewWindow = false }

    // MARK: Opening

    /// Opens `url` once: a file open in any group comes forward (true), and one on its way isn't read again (true, nothing
    /// done). False: open it (`finish(path)` after, whether it opened or not).
    func alreadyOpen(_ url: URL) -> (handled: Bool, document: PdfDocument?, path: String) {
        let path = Self.fullPath(url)
        if let open = controller(showing: path) {
            open.window?.makeKeyAndOrderFront(nil) // selects its tab; becoming key checks the file on disk
            return (true, open.pdf, path)
        }
        return (!rules.beginOpening(path), nil, path)
    }

    func finishOpening(_ path: String) { rules.endOpening(path) }
}
