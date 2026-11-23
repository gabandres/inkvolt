import Foundation

// Ported from pdf/src/InkvoltPdf.Core/DocumentWindows.cs (roadmap 4.9, two documents side by side). On the Mac a "window"
// is a group of NSWindow tabs and a "tab" one document's window: AppKit draws the tabs, drags them out and merges them,
// so the app keeps this in step with what AppKit did (WindowHub) and asks it the rules: a file open once, the window in
// use, what may move. TabDrag is ported with its tests for the rules' sake; the Mac's tab dragging is AppKit's.

/// Whether a tab can go to another window (`DocumentWindows.canMove`).
public enum TabMoveCheck: Sendable {
    /// It can: the tab leaves its window for the target.
    case moves
    /// The target is the window the tab is already in.
    case sameWindow
    /// Printing, exporting or another job holds the document: it stays where its work was started.
    case busy
    /// The tab or the window isn't open (any more).
    case unknown
}

/// Whether a tab can become a window of its own (`DocumentWindows.canTearOff`).
public enum TearOffCheck: Sendable {
    case tearsOff
    /// The window's only tab: it already has a window to itself (drag the window by its title bar instead).
    case onlyTab
    case busy
    case unknown
}

/// What a tab move did (`DocumentWindows.move`): the window the tab left, and whether it has no tab left (a window
/// emptied by a move closes: the tab went on in another).
public struct TabMoved: Equatable, Sendable {
    public let from: Int
    public let fromEmptied: Bool

    public init(from: Int, fromEmptied: Bool) {
        self.from = from
        self.fromEmptied = fromEmptied
    }
}

public enum DocumentWindowsError: Error, Equatable {
    case noWindow(Int)
    case noTab(Int64)
    case tabAlreadyOpen(Int64)
}

/// A launch's arguments as far as windows go: `--new-window` (Windows' jump list's New Window; the Mac's Dock menu
/// asks for it without a launch) asks for a window of its own; the rest are files to open.
public struct WindowLaunch: Equatable, Sendable {
    public static let newWindowSwitch = "--new-window"

    public let newWindow: Bool
    public let files: [String]

    public static func parse(_ args: [String]) -> WindowLaunch {
        let isSwitch = { (a: String) in a.caseInsensitiveCompare(newWindowSwitch) == .orderedSame }
        return WindowLaunch(newWindow: args.contains(where: isSwitch), files: args.filter { !isSwitch($0) })
    }
}

/// Inkvolt PDF's main windows and the tabs each owns (roadmap 4.9). A document is open in one tab of one window at a
/// time; a file asked for again goes to the tab that has it, in whichever window. Windows are numbered as they open; the
/// one used last (`active`) takes files opened from elsewhere. A tab moves to another window unless its document is
/// busy; a window's only tab doesn't tear off; a window a move emptied closes. Which files are remembered for the next
/// start (`remember`) is decided here too. The app's windows are adapters: each tells this what it opened, closed, moved
/// and activated. Paths are compared ignoring case, as Windows does (the Mac's disks ignore it too, by default).
public final class DocumentWindows {
    private final class Entry {
        let id: Int
        var tabs: [Int64] = []
        init(_ id: Int) { self.id = id }
    }

    private var entries: [Entry] = [] // in the order they opened
    private var used: [Int] = [] // most recently activated first
    private var paths: [Int64: String?] = [:]
    private var opening: Set<String> = []
    private var next = 1
    private var sessionRemembered = false

    public init() {}

    /// The open windows, in the order they opened.
    public var windows: [Int] { entries.map(\.id) }

    public var count: Int { entries.count }

    /// The window used last (activated, or opened when none was activated since): where files from elsewhere go.
    public var active: Int? { used.first }

    /// A new window, with no tab yet; it counts as the one used last.
    @discardableResult
    public func open() -> Int {
        let id = next
        next += 1
        entries.append(Entry(id))
        used.insert(id, at: 0)
        return id
    }

    /// The window closed: it and its tabs are gone.
    public func close(_ window: Int) {
        guard let entry = find(window) else { return }
        for tab in entry.tabs { paths[tab] = nil }
        entries.removeAll { $0 === entry }
        used.removeAll { $0 == window }
    }

    public func activate(_ window: Int) {
        guard find(window) != nil else { return }
        used.removeAll { $0 == window }
        used.insert(window, at: 0)
    }

    /// A tab opened in `window` (at `index`, else at the end), showing `path` (nil: never saved).
    public func add(_ window: Int, _ tab: Int64, _ path: String?, at index: Int? = nil) throws {
        guard let entry = find(window) else { throw DocumentWindowsError.noWindow(window) }
        if paths.keys.contains(tab) { throw DocumentWindowsError.tabAlreadyOpen(tab) }
        entry.tabs.insert(tab, at: Self.clamp(index ?? entry.tabs.count, entry.tabs.count))
        paths[tab] = .some(path)
    }

    /// The tab's document now has this file (Save As, a reload).
    public func setPath(_ tab: Int64, _ path: String?) {
        if paths.keys.contains(tab) { paths[tab] = .some(path) }
    }

    /// The tab closed.
    public func remove(_ tab: Int64) {
        windowEntry(of: tab)?.tabs.removeAll { $0 == tab }
        paths[tab] = nil
    }

    public func window(of tab: Int64) -> Int? { windowEntry(of: tab)?.id }

    public func tabs(of window: Int) -> [Int64] { find(window)?.tabs ?? [] }

    /// The tab showing `path`, in any window (nil: none). The caller gives full paths.
    public func findFile(_ path: String) -> (window: Int, tab: Int64)? {
        for w in entries {
            for tab in w.tabs {
                if let open = paths[tab] ?? nil, Self.same(open, path) { return (w.id, tab) }
            }
        }
        return nil
    }

    /// A window starts reading `path` (a full path) into a new tab. False when that file is already on its way in any
    /// window (opened twice from Finder, or asked for in two windows) or open in a tab: it isn't read again. Each true is
    /// followed by `endOpening`, whether the tab opened or not.
    public func beginOpening(_ path: String) -> Bool {
        findFile(path) == nil && opening.insert(Self.key(path)).inserted
    }

    /// The file asked for in `beginOpening` opened as a tab (`add` came first), or didn't.
    public func endOpening(_ path: String) { opening.remove(Self.key(path)) }

    /// Whether `tab` can go to `target`; `busy`: a job holds its document.
    public func canMove(_ tab: Int64, to target: Int, busy: Bool) -> TabMoveCheck {
        guard let from = windowEntry(of: tab), find(target) != nil else { return .unknown }
        if from.id == target { return .sameWindow }
        return busy ? .busy : .moves
    }

    /// Whether `tab` can become a window of its own.
    public func canTearOff(_ tab: Int64, busy: Bool) -> TearOffCheck {
        guard let from = windowEntry(of: tab) else { return .unknown }
        if from.tabs.count < 2 { return .onlyTab }
        return busy ? .busy : .tearsOff
    }

    /// Moves `tab` to `target` at `index` (clamped; past the end: last), after `canMove` said `.moves`; the target becomes
    /// the window used last. Moving within a window reorders its tabs.
    @discardableResult
    public func move(_ tab: Int64, to target: Int, at index: Int) throws -> TabMoved {
        guard let from = windowEntry(of: tab) else { throw DocumentWindowsError.noTab(tab) }
        guard let to = find(target) else { throw DocumentWindowsError.noWindow(target) }
        let at = from.tabs.firstIndex(of: tab)!
        from.tabs.remove(at: at)
        var index = index
        if from === to && index > at { index -= 1 } // the tab's own place no longer counts
        to.tabs.insert(tab, at: Self.clamp(index, to.tabs.count))
        activate(target)
        return TabMoved(from: from.id, fromEmptied: from !== to && from.tabs.isEmpty)
    }

    /// Every window is about to close at once (Quit, the Mac logging out): see `remember`.
    public func closeAllStarting() { sessionRemembered = false }

    /// The files to reopen next time, as `closing` closes; nil leaves what was remembered. Closing one of several windows
    /// forgets its files (they were closed on purpose); the last window remembers its own. When every window goes at once
    /// (`everyWindow`: Quit, the Mac logging out), the first to close remembers all windows' files, in window order, and the
    /// others leave that alone until `closeAllStarting`.
    public func remember(closing: Int, everyWindow: Bool) -> [String]? {
        if everyWindow {
            if sessionRemembered { return nil }
            sessionRemembered = true
            return files(entries)
        }
        if entries.contains(where: { $0.id != closing }) { return nil }
        return find(closing).map { files([$0]) } ?? []
    }

    private func files(_ windows: [Entry]) -> [String] {
        var seen: Set<String> = []
        var list: [String] = []
        for tab in windows.flatMap(\.tabs) {
            guard let path = paths[tab] ?? nil, seen.insert(Self.key(path)).inserted else { continue }
            list.append(path)
        }
        return list
    }

    private func find(_ window: Int) -> Entry? { entries.first { $0.id == window } }

    private func windowEntry(of tab: Int64) -> Entry? { entries.first { $0.tabs.contains(tab) } }

    private static func clamp(_ index: Int, _ count: Int) -> Int { min(max(index, 0), count) }

    /// A path as it is compared: case folded, as .NET's OrdinalIgnoreCase.
    private static func key(_ path: String) -> String { path.folding(options: .caseInsensitive, locale: nil) }

    private static func same(_ a: String, _ b: String) -> Bool { key(a) == key(b) }
}

/// Where a tab dragged out of its strip lands (`TabDrag.drop`).
public enum TabDropKind: Sendable {
    /// Nowhere: the tab stays as it was.
    case none
    /// Back on its own strip, at `TabDrop.index`.
    case reorder
    /// On another window's strip: the tab moves there, at `TabDrop.index`.
    case moveToWindow
    /// Away from every strip: the tab becomes a window of its own, where it was let go.
    case tearOff
}

public struct TabDrop: Equatable, Sendable {
    public let kind: TabDropKind
    public let window: Int
    public let index: Int

    public init(_ kind: TabDropKind, window: Int = 0, index: Int = 0) {
        self.kind = kind
        self.window = window
        self.index = index
    }
}

/// A window's tab strip on the screen: its bounds and the middle of each tab, left to right (screen pixels).
public struct TabStripArea: Sendable {
    public let window: Int
    public let bounds: RectD
    public let tabMiddles: [Double]

    public init(window: Int, bounds: RectD, tabMiddles: [Double]) {
        self.window = window
        self.bounds = bounds
        self.tabMiddles = tabMiddles
    }
}

/// Dragging a title-bar tab (roadmap 4.9): when a press becomes a drag, and where the tab lands. A strip catches a tab
/// let go within `catchMargin` above or below it, as Edge's and Explorer's do; strips are given front window first, so
/// the window on top wins where they overlap. Let go anywhere else, a tab tears off into a new window, unless it is its
/// window's only one. (Windows' rules; the Mac's tabs are dragged by AppKit.)
public enum TabDrag {
    /// How far above or below a strip (in points, times the screen's scale) a tab let go still lands on it (Windows'
    /// `Catch`).
    public static let catchMargin: Double = 24

    /// A press that moved this far (either way) is a drag.
    public static func started(pressed: PointD, now: PointD, minX: Double, minY: Double) -> Bool {
        abs(now.x - pressed.x) >= minX || abs(now.y - pressed.y) >= minY
    }

    /// Where a tab of `source` (which has `sourceTabs` tabs) let go at `at` lands; `strips` front window first, `scale`
    /// the screen's pixels per point.
    public static func drop(source: Int, sourceTabs: Int, at: PointD, strips: [TabStripArea], scale: Double = 1) -> TabDrop {
        let margin = catchMargin * scale
        for strip in strips {
            let b = strip.bounds
            let caught = at.x >= b.x && at.x <= b.right && at.y >= b.y - margin && at.y <= b.bottom + margin
            if !caught { continue }
            let i = index(strip.tabMiddles, at.x)
            return strip.window == source ? TabDrop(.reorder, window: source, index: i) : TabDrop(.moveToWindow, window: strip.window, index: i)
        }
        return sourceTabs > 1 ? TabDrop(.tearOff, window: source) : TabDrop(.none, window: source)
    }

    /// The place a tab let go at `x` takes: before the first tab whose middle is right of it.
    public static func index(_ middles: [Double], _ x: Double) -> Int {
        var i = 0
        while i < middles.count && middles[i] < x { i += 1 }
        return i
    }
}
