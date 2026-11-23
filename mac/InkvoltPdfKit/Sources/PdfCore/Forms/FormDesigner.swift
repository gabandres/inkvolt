import Foundation
import PrintCore

/// A field drawn with a field tool of Prepare Form (page space).
public struct DesignPlacement: Equatable, Sendable {
    public var kind: DesignFieldKind
    public var pageIndex: Int
    public var rect: RectD

    public init(kind: DesignFieldKind, pageIndex: Int, rect: RectD) {
        self.kind = kind
        self.pageIndex = pageIndex
        self.rect = rect
    }
}

/// What a press on the page asks of the window.
public enum DesignPress: Equatable, Sendable {
    /// Nothing more than what the designer did itself (selected, started a drag, or nothing).
    case none
    /// A double-click on a field: open its properties.
    case properties
    /// A double-click on a suggestion: add it.
    case accept
    /// An empty spot: scroll with the pointer, as with the hand tool.
    case pan
}

/// What a finished press hands over: a new field, or a field with its new `rect`.
public enum DesignRelease: Equatable, Sendable {
    case placed(DesignPlacement)
    case moved(DesignField)
    /// Several selected fields dragged together: each with its new rect (the one pressed first).
    case movedAll([DesignField])
}

/// What the pointer shows.
public enum DesignCursor: Equatable, Sendable {
    case arrow, crosshair, move, pointingHand
    /// A handle of the selected field (0-7, `DrawingGeometry`).
    case resize(Int)
}

/// What Esc does.
public enum DesignEscape: Equatable, Sendable { case droppedTool, deselected, leave }

/// Prepare Form's state on top of the page view (the rules of the Windows app's `PageViewer.FormDesign`, kept in PdfCore so
/// they are tested; the Mac's view only draws it and passes on the mouse and keys): every form field shows as a named box;
/// with a field tool (`kind`) a drag (or a click, for the kind's usual size) places a new field; with none, a click selects
/// a field, a drag moves it, its handles resize it, arrow keys nudge it (written once the keys rest), Tab goes through the
/// fields and suggestions. Suggested fields show dashed until accepted. The window turns each gesture into an edit.
/// ⌘-click (Windows' Ctrl+click, roadmap 4.12) adds a field to the selection or takes it out: the first one picked is the
/// anchor that Align, Same Size and Space Evenly (`FormDesignRules.aligned`) go by; a drag of any of them, or the arrow
/// keys, move them all. Several fields are selected on one page only, and show no resize handles.
public struct FormDesigner: Equatable, Sendable {
    /// The smallest side a resize leaves, and a drawn box must have to be kept (else the kind's usual size).
    public static let minSize = 6.0

    private struct Drag: Equatable, Sendable {
        var field: DesignField
        var handle: Int
        var press: PointD
        var offset: PointD
        var rect: RectD
        var dragged = false
        var pageWidth: Double
        var pageHeight: Double
        /// The other selected fields moved along with `field`, and how far they all went.
        var group: [DesignField] = []
        var shift = PointD(0, 0)
    }

    private struct NewBox: Equatable, Sendable {
        var page: Int
        var start: PointD
        var end: PointD
        var dragged = false
        var pageWidth: Double
        var pageHeight: Double
    }

    /// The fields in fill order, page by page.
    public private(set) var fields: [DesignField] = []
    public private(set) var suggestions: [FieldSuggestion] = []
    public private(set) var selectedId: String?
    private var suggestionIndex = -1
    /// The field tool; nil selects and moves fields.
    public var kind: DesignFieldKind?
    /// Numbers each field with its place in the fill (Tab) order.
    public var showTabOrder = false

    private var byPage: [Int: [DesignField]] = [:]
    /// Where moved fields show until the document catches up.
    private var pending: [String: RectD] = [:]
    private var nudged = PointD(0, 0)
    private var drag: Drag?
    private var box: NewBox?
    /// The other selected fields, in the order picked (`selectedId` is the anchor).
    private var also: [String] = []

    public init() {}

    public var selectedField: DesignField? { selectedId.flatMap { id in fields.first { $0.id == id } } }

    /// The selected fields, the anchor first (empty: none).
    public var selectedIds: [String] { selectedId.map { [$0] + also } ?? [] }

    /// The selected fields as read, the anchor first.
    public var selectedFields: [DesignField] { selectedIds.compactMap { id in fields.first { $0.id == id } } }

    /// More than one field is selected.
    public var hasSeveral: Bool { selectedId != nil && !also.isEmpty }

    public func isSelected(_ id: String) -> Bool { id == selectedId || also.contains(id) }

    /// Delete has something to take: a selected field that isn't signed (a signed anchor among several doesn't stop it).
    public var canDelete: Bool { selectedFields.contains { !$0.signed } }
    public var selectedSuggestion: FieldSuggestion? { suggestions.indices.contains(suggestionIndex) ? suggestions[suggestionIndex] : nil }
    public var selectedSuggestionIndex: Int { selectedSuggestion == nil ? -1 : suggestionIndex }
    public var isDragging: Bool { drag != nil || box != nil }
    public var hasNudge: Bool { nudged != PointD(0, 0) }
    /// The page of the press under way.
    public var pressPage: Int? { box?.page ?? drag?.field.pageIndex }

    /// The rectangle being drawn for a new field, on its page.
    public var newBox: (page: Int, rect: RectD)? {
        box.map { ($0.page, RectD.fromEdges($0.start.x, $0.start.y, $0.end.x, $0.end.y)) }
    }

    public func fields(onPage page: Int) -> [DesignField] { byPage[page] ?? [] }

    public mutating func setFields(_ list: [DesignField]) {
        byPage = Dictionary(grouping: list, by: \.pageIndex)
        fields = list.enumerated().sorted { a, b in
            let ka = (a.element.pageIndex, a.element.tabIndex, a.offset), kb = (b.element.pageIndex, b.element.tabIndex, b.offset)
            return ka < kb
        }.map(\.element)
        pending.removeAll()
        also.removeAll { a in !list.contains { $0.id == a } }
        if let id = selectedId, !list.contains(where: { $0.id == id }) { selectedId = also.isEmpty ? nil : also.removeFirst() }
        // A move under way goes on from the fields as now read (the document caught up with an earlier move); when the
        // pressed field is gone, the press ends.
        if var d = drag {
            if let now = list.first(where: { $0.id == d.field.id }) {
                d.field = now
                d.group = d.group.compactMap { g in list.first { $0.id == g.id } }
                drag = d
            } else {
                drag = nil
            }
        }
    }

    public mutating func setSuggestions(_ list: [FieldSuggestion]) {
        let selected = selectedSuggestion
        suggestions = list
        suggestionIndex = selected.flatMap { list.firstIndex(of: $0) } ?? -1
    }

    /// Selects a field (nil: none); the caller flushes any nudge first.
    public mutating func select(_ id: String?) {
        selectedId = id
        also.removeAll()
        suggestionIndex = -1
    }

    /// Selects these fields (the first the anchor; only those on its page); the caller flushes any nudge first.
    public mutating func selectAll(_ ids: [String]) {
        select(ids.first { id in fields.contains { $0.id == id } })
        guard let anchor = selectedField else { return }
        for id in ids where id != anchor.id && !also.contains(id) {
            if let f = fields.first(where: { $0.id == id }), f.pageIndex == anchor.pageIndex { also.append(id) }
        }
    }

    /// ⌘-click: adds the field to the selection, or takes it out (the anchor's place goes to the next one picked). A field
    /// on another page than the selection starts a new one. The caller flushes any nudge first.
    public mutating func toggle(_ id: String) {
        guard let f = fields.first(where: { $0.id == id }) else { return }
        if id == selectedId {
            selectedId = also.isEmpty ? nil : also.removeFirst()
        } else if let i = also.firstIndex(of: id) {
            also.remove(at: i)
        } else if let anchor = selectedField, anchor.pageIndex == f.pageIndex {
            also.append(id)
        } else {
            select(id)
        }
        suggestionIndex = -1
    }

    public mutating func selectSuggestion(_ index: Int) {
        suggestionIndex = suggestions.indices.contains(index) ? index : -1
        if suggestionIndex >= 0 {
            selectedId = nil
            also.removeAll()
        }
    }

    /// Leaving Prepare Form: nothing stays selected, no tool, no suggestions, no numbers.
    public mutating func reset() {
        drag = nil
        box = nil
        nudged = PointD(0, 0)
        kind = nil
        selectedId = nil
        also.removeAll()
        suggestionIndex = -1
        suggestions = []
        showTabOrder = false
    }

    /// Where a field shows: its rect, or the one it was just moved to (until the document catches up).
    public func shownRect(_ f: DesignField) -> RectD {
        var r = startRect(f)
        if let d = drag, d.field.id == f.id {
            r = d.rect
        } else if let d = drag, d.group.contains(where: { $0.id == f.id }) {
            r.x += d.shift.x
            r.y += d.shift.y
        }
        // A signed field never shows moved (it doesn't move with the others).
        if isSelected(f.id), hasNudge, !f.signed {
            r.x += nudged.x
            r.y += nudged.y
        }
        return r
    }

    /// A field's rect as last written (or being written).
    private func startRect(_ f: DesignField) -> RectD { pending[f.id] ?? f.rect }

    /// The selected fields that can move (unsigned), as read.
    private var movableSelection: [DesignField] { selectedFields.filter { !$0.signed } }

    /// A move of every field in `group` by (dx, dy), cut short so all of them stay on a `width` × `height` page.
    private func clampGroup(_ group: [DesignField], _ dx: Double, _ dy: Double, _ width: Double, _ height: Double) -> (dx: Double, dy: Double) {
        guard let first = group.first else { return (0, 0) }
        let union = group.dropFirst().reduce(startRect(first)) { $0.union(startRect($1)) }
        return DrawingGeometry.clampMove(union, dx, dy, width, height)
    }

    /// The smallest field under a point of a page.
    public func fieldAt(_ page: Int, _ p: PointD) -> DesignField? {
        var best: DesignField?
        for f in fields(onPage: page) where shownRect(f).inflate(2).contains(p.x, p.y) {
            if let b = best, b.rect.width * b.rect.height <= f.rect.width * f.rect.height { continue }
            best = f
        }
        return best
    }

    /// The last suggestion under a point of a page, or -1.
    public func suggestionAt(_ page: Int, _ p: PointD) -> Int {
        suggestions.lastIndex { $0.pageIndex == page && $0.rect.inflate(2).contains(p.x, p.y) } ?? -1
    }

    /// The resize handle of the selected field under a point (0-7, `DrawingGeometry`), or -1. `reach`: how near counts, in
    /// page points (what a handle's size is at the zoom shown).
    public func handleAt(_ page: Int, _ p: PointD, reach: Double) -> Int {
        guard let f = selectedField, f.pageIndex == page, !f.signed, !hasSeveral else { return -1 }
        let frame = shownRect(f)
        for i in 0..<8 {
            let h = DrawingGeometry.handlePoint(frame, i)
            if abs(h.x - p.x) <= reach && abs(h.y - p.y) <= reach { return i }
        }
        return -1
    }

    public func cursor(_ page: Int, _ p: PointD, reach: Double) -> DesignCursor {
        let h = handleAt(page, p, reach: reach)
        if h >= 0 { return .resize(h) }
        if kind != nil { return .crosshair }
        if let f = fieldAt(page, p) { return f.signed ? .arrow : .move }
        return suggestionAt(page, p) >= 0 ? .pointingHand : .arrow
    }

    // MARK: Mouse

    /// What snapping (roadmap 4.19) takes on a page without the fields named (the ones being moved): a function the window
    /// passes with each press and drag (Windows' `FormDesigner.SnapFor`), or nil for none.
    public typealias SnapFor = (_ page: Int, _ without: Set<String>) -> Snapper?

    /// What the press under way snapped to, for the view to show (empty: nothing).
    public private(set) var snapLines: [SnapLine] = []

    private mutating func snapPoint(_ page: Int, _ p: PointD, _ snap: SnapFor?) -> PointD {
        guard let snapper = snap?(page, []) else {
            snapLines = []
            return p
        }
        let q = snapper.point(p)
        snapLines = snapper.lines
        return q
    }

    /// A press at `p` of a `pageWidth` × `pageHeight` page: selects, starts moving or resizing, or starts a new field.
    /// `toggle` (⌘): a field joins the selection or leaves it, and nothing moves. A press on one of several selected fields
    /// keeps them selected and moves them together. `snap`: what a new box's first corner snaps to. The caller flushes any
    /// nudge first.
    public mutating func press(_ page: Int, _ p: PointD, clicks: Int, reach: Double, pageWidth: Double, pageHeight: Double,
                               toggle: Bool = false, snap: SnapFor? = nil) -> DesignPress {
        let h = handleAt(page, p, reach: reach)
        if h >= 0, let f = selectedField {
            startDrag(f, h, p, pageWidth, pageHeight)
            return .none
        }
        if kind == nil, let hit = fieldAt(page, p) {
            if toggle {
                self.toggle(hit.id)
                return .none
            }
            if hasSeveral && isSelected(hit.id) && clicks < 2 {
                if !hit.signed { startDrag(hit, -1, p, pageWidth, pageHeight) }
                return .none
            }
            select(hit.id)
            if clicks >= 2 { return .properties }
            if !hit.signed { startDrag(hit, -1, p, pageWidth, pageHeight) }
            return .none
        }
        if kind == nil {
            let s = suggestionAt(page, p)
            if s >= 0 {
                selectSuggestion(s)
                return clicks >= 2 ? .accept : .none
            }
        }
        if kind != nil {
            let q = snapPoint(page, p, snap)
            let start = PointD(min(max(q.x, 0), pageWidth), min(max(q.y, 0), pageHeight))
            box = NewBox(page: page, start: start, end: start, pageWidth: pageWidth, pageHeight: pageHeight)
            return .none
        }
        select(nil)
        return .pan
    }

    private mutating func startDrag(_ f: DesignField, _ handle: Int, _ p: PointD, _ pageWidth: Double, _ pageHeight: Double) {
        var offset = PointD(0, 0)
        if handle >= 0 {
            // The handle sits on the frame: keep the pointer's offset from it, so the frame doesn't jump.
            let h = DrawingGeometry.handlePoint(shownRect(f), handle)
            offset = PointD(h.x - p.x, h.y - p.y)
        }
        var d = Drag(field: f, handle: handle, press: p, offset: offset, rect: shownRect(f), pageWidth: pageWidth, pageHeight: pageHeight)
        if handle < 0 && hasSeveral && isSelected(f.id) { d.group = movableSelection.filter { $0.id != f.id } }
        drag = d
    }

    /// The pointer dragged to `p` (`threshold`: how far it must go, in page points, to count as a drag). True when it was
    /// the designer's press. `snap`: what a drawn box's corner, a moved field's (or group's) edges and centers and a
    /// resized field's moving edges snap to.
    @discardableResult
    public mutating func dragged(to p: PointD, shift: Bool, threshold: Double, snap: SnapFor? = nil) -> Bool {
        if var b = box {
            let q = snapPoint(b.page, p, snap)
            b.end = PointD(min(max(q.x, 0), b.pageWidth), min(max(q.y, 0), b.pageHeight))
            if abs(b.end.x - b.start.x) + abs(b.end.y - b.start.y) > threshold { b.dragged = true }
            box = b
            return true
        }
        guard var d = drag else { return false }
        if !d.dragged && abs(p.x - d.press.x) + abs(p.y - d.press.y) <= threshold { return true }
        d.dragged = true
        let start = startRect(d.field)
        if d.handle < 0 {
            let all = [d.field] + d.group
            var rawX = p.x - d.press.x, rawY = p.y - d.press.y
            if let snapper = snap?(d.field.pageIndex, Set(all.map(\.id))) {
                // The field (or the group's outline) where the pointer takes it, moved onto the nearest line.
                let outline = all.dropFirst().reduce(startRect(all[0])) { $0.union(startRect($1)) }
                let moved = RectD(outline.x + rawX, outline.y + rawY, outline.width, outline.height)
                let snapped = snapper.move(moved)
                rawX += snapped.x - moved.x
                rawY += snapped.y - moved.y
                snapLines = snapper.lines
            } else {
                snapLines = []
            }
            let move = d.group.isEmpty
                ? DrawingGeometry.clampMove(start, rawX, rawY, d.pageWidth, d.pageHeight)
                : clampGroup(all, rawX, rawY, d.pageWidth, d.pageHeight)
            d.rect = RectD(start.x + move.dx, start.y + move.dy, start.width, start.height)
            d.shift = PointD(move.dx, move.dy)
        } else {
            let to = PointD(min(max(p.x + d.offset.x, 0), d.pageWidth), min(max(p.y + d.offset.y, 0), d.pageHeight))
            let toggle = d.field.kind == .checkBox || d.field.kind == .radio
            d.rect = DrawingGeometry.resize(start, d.handle, to, minSize: Self.minSize, keepAspect: toggle || shift)
            // The moving edges snap (not while keeping proportions: a snapped edge would break them).
            if !toggle && !shift, let snapper = snap?(d.field.pageIndex, [d.field.id]) {
                d.rect = snapper.resize(start, d.rect, min: Self.minSize)
                snapLines = snapper.lines
            } else {
                snapLines = []
            }
        }
        drag = d
        return true
    }

    /// The press ended: the new field or the moved one to write, if any. A short press with a field tool places the kind's
    /// usual size, its top-left at the pointer, kept on the page.
    public mutating func release() -> DesignRelease? {
        snapLines = []
        if let b = box {
            box = nil
            let tool = kind ?? .text
            var rect = RectD.fromEdges(b.start.x, b.start.y, b.end.x, b.end.y)
            if !b.dragged || rect.width < 6 || rect.height < 6 {
                let size = Self.defaultSize(tool)
                rect = RectD(min(max(b.start.x, 0), max(0, b.pageWidth - size.width)), min(max(b.start.y, 0), max(0, b.pageHeight - size.height)), size.width, size.height)
            } else if tool == .checkBox || tool == .radio {
                let side = min(rect.width, rect.height)
                rect = RectD(rect.x, rect.y, side, side)
            }
            return .placed(DesignPlacement(kind: tool, pageIndex: b.page, rect: rect))
        }
        guard let d = drag else { return nil }
        drag = nil
        let before = startRect(d.field)
        guard d.dragged, d.rect != before else { return nil }
        if !d.group.isEmpty {
            var all = [d.field.with { $0.rect = d.rect }]
            for other in d.group {
                let r = startRect(other)
                all.append(other.with { $0.rect = RectD(r.x + d.shift.x, r.y + d.shift.y, r.width, r.height) })
            }
            for f in all { pending[f.id] = f.rect }
            return .movedAll(all)
        }
        pending[d.field.id] = d.rect
        return .moved(d.field.with { $0.rect = d.rect })
    }

    public mutating func cancelDrag() {
        drag = nil
        box = nil
        snapLines = []
    }

    /// A new field's size when placed with a click (points).
    public static func defaultSize(_ kind: DesignFieldKind) -> (width: Double, height: Double) {
        switch kind {
        case .checkBox, .radio: (14, 14)
        case .comboBox: (140, 20)
        case .listBox: (140, 60)
        case .signature: (180, 40)
        case .button: (80, 24)
        case .text: (160, 20)
        }
    }

    // MARK: Keys

    /// Tab order of the selection: fields in fill order within a page, then that page's suggestions. Returns where the new
    /// selection is, to bring it into view. The caller flushes any nudge first.
    public mutating func step(_ by: Int) -> (page: Int, rect: RectD)? {
        enum Item {
            case field(DesignField)
            case suggestion(Int)
        }
        var items: [Item] = []
        let pages = Set(fields.map(\.pageIndex)).union(suggestions.map(\.pageIndex)).sorted()
        for page in pages {
            items += fields.filter { $0.pageIndex == page }.map { .field($0) }
            items += suggestions.indices.filter { suggestions[$0].pageIndex == page }.map { .suggestion($0) }
        }
        if items.isEmpty { return nil }
        let at = items.firstIndex { item in
            switch item {
            case .field(let f): f.id == selectedId
            case .suggestion(let i): selectedId == nil && i == suggestionIndex
            }
        }
        let next = at.map { ($0 + by + items.count) % items.count } ?? (by > 0 ? 0 : items.count - 1)
        switch items[next] {
        case .field(let f):
            select(f.id)
            return (f.pageIndex, f.rect)
        case .suggestion(let i):
            selectSuggestion(i)
            return (suggestions[i].pageIndex, suggestions[i].rect)
        }
    }

    /// Arrow keys move the selected fields (the unsigned ones), kept on the page; the move is written once the keys rest
    /// (`flushNudgeAll`).
    public mutating func nudge(_ dx: Double, _ dy: Double, pageWidth: Double, pageHeight: Double) {
        let group = movableSelection
        if group.isEmpty { return }
        let move = clampGroup(group, nudged.x + dx, nudged.y + dy, pageWidth, pageHeight)
        nudged = PointD(move.dx, move.dy)
    }

    /// The arrow-key moves made so far, as the field to write (called before anything else acts on the selection); with
    /// several selected, the first moved (`flushNudgeAll` gives them all).
    public mutating func flushNudge() -> DesignField? { flushNudgeAll().first }

    /// The arrow-key moves made so far, as the fields to write, the anchor first (empty: none).
    public mutating func flushNudgeAll() -> [DesignField] {
        let moved = nudged
        nudged = PointD(0, 0)
        guard moved != PointD(0, 0), selectedField != nil else { return [] }
        return movableSelection.map { f in
            let start = startRect(f)
            let r = RectD(start.x + moved.x, start.y + moved.y, start.width, start.height)
            pending[f.id] = r
            return f.with { $0.rect = r }
        }
    }

    public mutating func escape() -> DesignEscape {
        if kind != nil {
            kind = nil
            return .droppedTool
        }
        if selectedField != nil || selectedSuggestion != nil {
            select(nil)
            return .deselected
        }
        return .leave
    }

    /// Forgets where a field was shown after an edit that wasn't made (a dragged field goes back).
    public mutating func dropPending() { pending.removeAll() }
}

/// A property change the panel refused, with what to say.
public struct DesignRefusal: Error, Equatable, Sendable {
    public var message: String
    public init(_ message: String) { self.message = message }
}

/// The properties panel's and the field commands' rules (the Windows app's `DocumentTab.FormDesign`, kept in PdfCore so they
/// are tested): what each choice offers, what a typed value does to a field, and which fields an action makes.
public enum FormDesignRules {
    /// The format list, its labels in the interface's language (computed, so a language installed at launch shows).
    public static var formats: [(label: String, format: FieldFormat?)] {
        [
            (loc("None"), nil),
            (loc("Number (1,234.56)"), FieldFormat(.number, decimals: 2)),
            (loc("Whole number (1,234)"), FieldFormat(.number, decimals: 0)),
            (loc("Currency ($1,234.56)"), FieldFormat(.number, decimals: 2, currency: "$", currencyPrepend: true)),
            // Roadmap 4.12: Windows' three more AFNumber_Format choices.
            (loc("Number, negatives in brackets ((1,234.56))"), FieldFormat(.number, decimals: 2, negativeStyle: 2)),
            (loc("Number (1.234,56)"), FieldFormat(.number, decimals: 2, separatorStyle: 2)),
            (loc("Euro (1.234,56 €)"), FieldFormat(.number, decimals: 2, separatorStyle: 2, currency: " €", currencyPrepend: false)),
            (loc("Percent (12.50%)"), FieldFormat(.percent, decimals: 2)),
            (loc("Date (mm/dd/yyyy)"), FieldFormat(.date, datePattern: "mm/dd/yyyy")),
            (loc("Date (dd/mm/yyyy)"), FieldFormat(.date, datePattern: "dd/mm/yyyy")),
            (loc("Date (yyyy-mm-dd)"), FieldFormat(.date, datePattern: "yyyy-mm-dd")),
            (loc("ZIP code"), FieldFormat(.special, special: 0)),
            (loc("ZIP+4"), FieldFormat(.special, special: 1)),
            (loc("Phone number"), FieldFormat(.special, special: 2)),
            (loc("Social Security number"), FieldFormat(.special, special: 3)),
        ]
    }

    public static var borderColors: [(label: String, color: AnnotColor?)] {
        [
            (loc("None"), nil), (loc("Black"), AnnotColor(0, 0, 0)), (loc("Gray"), AnnotColor(0.45, 0.45, 0.45)),
            (loc("Blue"), AnnotColor(0.1, 0.35, 0.8)), (loc("Red"), AnnotColor(0.8, 0.1, 0.1)),
        ]
    }

    public static var fillColors: [(label: String, color: AnnotColor?)] {
        [
            (loc("None"), nil), (loc("White"), AnnotColor(1, 1, 1)), (loc("Light gray"), AnnotColor(0.85, 0.85, 0.85)),
            (loc("Light blue"), AnnotColor(0.88, 0.93, 1)), (loc("Light yellow"), AnnotColor(1, 0.98, 0.8)),
        ]
    }

    // English: "Auto" is Windows' Spanish too (FormDesign_SizeAuto), and parseSize reads it back.
    public static let sizes = ["Auto", "8", "9", "10", "11", "12", "14", "16", "18", "24"]

    public static var suggestionKinds: [(label: String, kind: DesignFieldKind, multiline: Bool)] {
        [
            (loc("Text field"), .text, false), (loc("Multi-line text field"), .text, true), (loc("Check box"), .checkBox, false),
            (loc("Radio button"), .radio, false), (loc("Dropdown"), .comboBox, false), (loc("List box"), .listBox, false),
            (loc("Signature field"), .signature, false),
        ]
    }

    /// The index in `choices` of a color (within 0.02 each), or nil when it is none of them ("Custom (kept)").
    public static func colorIndex(_ choices: [(label: String, color: AnnotColor?)], _ color: AnnotColor?) -> Int? {
        choices.firstIndex { c in
            guard let a = c.color, let b = color else { return c.color == nil && color == nil }
            return abs(a.r - b.r) < 0.02 && abs(a.g - b.g) < 0.02 && abs(a.b - b.b) < 0.02
        }
    }

    /// The format list for a field: `formats`' labels, one more when it holds something else, and which one is chosen.
    public static func formatChoices(_ f: DesignField) -> (labels: [String], selected: Int) {
        var labels = formats.map(\.label)
        let at = formats.firstIndex { $0.format == f.format }
        if f.customFormat {
            labels.append(loc("Custom script (kept)"))
        } else if at == nil {
            labels.append(loc("Other ({0}, kept)", f.format.map { String(describing: $0.kind) } ?? "format"))
        }
        return (labels, !f.customFormat ? at ?? labels.count - 1 : labels.count - 1)
    }

    public static func panelTitle(_ f: DesignField?, _ s: FieldSuggestion?) -> String {
        if let f {
            let kind = DesignField.kindName(f.kind)
            return f.signed ? loc("{0} · page {1} · signed", kind, CoreLanguage.number(f.pageIndex + 1)) : loc("{0} · page {1}", kind, CoreLanguage.number(f.pageIndex + 1))
        }
        if let s { return loc("Suggested {0} · page {1}", DesignField.kindName(s.kind).lowercased(), CoreLanguage.number(s.pageIndex + 1)) }
        return loc("Prepare Form")
    }

    public static func sourceText(_ source: String) -> String {
        switch source {
        case "underscores": loc("Found from a run of underscores.")
        case "line": loc("Found from a line to write on.")
        case "box": loc("Found from an empty box.")
        case "square": loc("Found from a small square.")
        default: loc("Found from a box character.")
        }
    }

    // MARK: Fields the commands make

    /// The field a drag or click with a field tool makes. A radio button drawn with a radio button selected joins its group.
    public static func placedField(_ p: DesignPlacement, fields: [DesignField], selected: DesignField?) -> DesignField {
        var f: DesignField
        if p.kind == .radio, let selected, selected.kind == .radio {
            f = FormDesign.duplicate(selected, fields, 0, 0)
            f.pageIndex = p.pageIndex
            f.rect = p.rect
            f.defaultValue = selected.defaultValue
        } else {
            f = FormDesign.newField(p.kind, p.pageIndex, p.rect, fields.map(\.name))
        }
        if p.kind == .text && p.rect.height >= 36 { f.multiline = true }
        return f
    }

    /// A copy of `f` beside it: below it if that stays on the page, else to its right.
    public static func duplicated(_ f: DesignField, fields: [DesignField], pageWidth: Double, pageHeight: Double) -> DesignField {
        let below = f.rect.bottom + 8 + f.rect.height <= pageHeight
        let dx = below ? 0 : min(f.rect.width + 8, max(0, pageWidth - f.rect.right))
        return FormDesign.duplicate(f, fields, dx, below ? f.rect.height + 8 : 0)
    }

    /// Suggestions as fields, named uniquely; radio buttons with one name are one group, each with its own value.
    public static func acceptedFields(_ picked: [FieldSuggestion], fields: [DesignField]) -> [DesignField] {
        var names = fields.map(\.name)
        var result: [DesignField] = []
        for s in picked {
            var f = FormDesign.newField(s.kind, s.pageIndex, s.rect, names, s.name)
            f.multiline = s.multiline
            if s.kind == .radio {
                let group = fields.filter { $0.kind == .radio && $0.name == s.name } + result.filter { $0.name == s.name }
                var n = group.count + 1
                while group.contains(where: { $0.exportValue == "Choice\(n)" }) { n += 1 }
                f.name = s.name
                f.exportValue = "Choice\(n)"
            }
            names.append(f.name)
            result.append(f)
        }
        return result
    }

    /// The field to select once `f` is gone: the next in fill order (positional ids shift, so only one with its own id).
    public static func nextField(after f: DesignField, in order: [DesignField]) -> String? {
        let i = order.firstIndex { $0.id == f.id } ?? 0
        let around = order[min(i + 1, order.count)...] + order[..<i]
        return around.first { $0.id != f.id && !isPositionalId($0.id) }?.id
    }

    /// An id made from the widget's position ("p0:3"), which changes when the page's /Annots do.
    public static func isPositionalId(_ id: String) -> Bool {
        guard id.first == "p", let colon = id.firstIndex(of: ":") else { return false }
        let page = id[id.index(after: id.startIndex)..<colon], at = id[id.index(after: colon)...]
        return !page.isEmpty && !at.isEmpty && (page + at).allSatisfy(\.isNumber)
    }

    /// The page's ids with `f` swapped with its neighbor in fill order, or what to say when it is already at that end.
    public static func tabOrder(moving f: DesignField, by step: Int, in fields: [DesignField]) -> Result<[String], DesignRefusal> {
        var onPage = fields.filter { $0.pageIndex == f.pageIndex }.sorted { $0.tabIndex < $1.tabIndex }
        guard let i = onPage.firstIndex(where: { $0.id == f.id }), onPage.indices.contains(i + step) else {
            return .failure(DesignRefusal(step < 0 ? loc("This field is already filled first on its page.") : loc("This field is already filled last on its page.")))
        }
        onPage.swapAt(i, i + step)
        return .success(onPage.map(\.id))
    }

    /// Suggestions still worth showing: without those a field now covers.
    public static func stillSuggested(_ suggestions: [FieldSuggestion], fields: [DesignField]) -> [FieldSuggestion] {
        suggestions.filter { s in !fields.contains { $0.pageIndex == s.pageIndex && overlap($0.rect, s.rect) > 0.3 } }
    }

    static func overlap(_ a: RectD, _ b: RectD) -> Double {
        let i = a.intersect(b)
        return i.isEmpty ? 0 : i.width * i.height / max(1e-6, min(a.width * a.height, b.width * b.height))
    }

    // MARK: What a typed value does

    /// The name typed for `f` (trimmed), checked against the other fields; the same name changes nothing.
    public static func renamed(_ f: DesignField, to typed: String, fields: [DesignField]) throws -> DesignField {
        let name = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if name == f.name { return f }
        let others = fields.filter { $0.id != f.id && !(f.kind == .radio && $0.name == f.name) }.map { (name: $0.name, kind: $0.kind) }
        if let problem = FormDesign.nameClash(others, name, f.kind) { throw DesignRefusal(problem) }
        return f.with { $0.name = name }
    }

    public static func withMaxLength(_ f: DesignField, _ typed: String) throws -> DesignField {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return f.with { $0.maxLength = 0 } }
        guard text.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(text), n <= 100_000 else {
            throw DesignRefusal(loc("Type the most characters as a whole number (0: no limit)."))
        }
        return f.with { $0.maxLength = n }
    }

    /// The value typed for a check box or radio button; a radio button that was the group's default stays it.
    public static func withExportValue(_ f: DesignField, _ typed: String, fields: [DesignField]) throws -> DesignField {
        let v = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if v == f.exportValue { return f }
        if let problem = FormDesign.exportValueProblem(v) { throw DesignRefusal(problem) }
        if f.kind == .radio && fields.contains(where: { $0.id != f.id && $0.kind == .radio && $0.name == f.name && $0.exportValue == v }) {
            throw DesignRefusal(loc("Another button of \"{0}\" already stands for \"{1}\": give this one a value of its own.", f.name, v))
        }
        return f.with {
            $0.exportValue = v
            if f.kind == .radio && f.defaultValue == f.exportValue { $0.defaultValue = v }
        }
    }

    /// The options editor's lines: "Shown text" (the value is the same), or "Shown text = value" (Acrobat's item and export
    /// value). Repeated values keep their first line.
    public static func parseChoices(_ text: String) -> (options: [String], labels: [String]) {
        var options: [String] = [], labels: [String] = []
        for raw in text.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }
            var label = line, value = line
            if let at = line.range(of: " = ", options: .backwards), at.lowerBound > line.startIndex {
                label = line[..<at.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
                value = line[at.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if value.isEmpty { value = label }
            if options.contains(value) { continue }
            options.append(value)
            labels.append(label)
        }
        return (options, labels)
    }

    /// The options editor's text for a field's choices (see `parseChoices`).
    public static func choicesText(_ f: DesignField) -> String {
        let shown = f.shownOptions
        return f.options.enumerated().map { i, o in shown[i] == o ? o : "\(shown[i]) = \(o)" }.joined(separator: "\n")
    }

    public static func withChoices(_ f: DesignField, _ typed: String) throws -> DesignField {
        let (options, labels) = parseChoices(typed)
        if options == f.options && labels == f.shownOptions { return f }
        if options.isEmpty { throw DesignRefusal(loc("Type at least one choice.")) }
        return f.with {
            $0.options = options
            $0.optionLabels = labels == options ? [] : labels
            $0.defaultValue = options.contains(f.defaultValue) ? f.defaultValue : ""
        }
    }

    /// "Checked (or selected) by default" turned on or off.
    public static func withDefaultOn(_ f: DesignField, _ on: Bool) -> DesignField {
        f.with { $0.defaultValue = on ? f.exportValue : f.kind == .radio && f.defaultValue != f.exportValue ? f.defaultValue : "" }
    }

    /// The text size typed: "Auto" or nothing is automatic; a number from 0 to 200 ("12", "12 pt"); nil when it isn't one.
    public static func parseSize(_ typed: String) -> Double? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty || text.caseInsensitiveCompare("Auto") == .orderedSame { return 0 }
        var number = text
        while let last = number.last, last == "p" || last == "t" || last == " " { number.removeLast() }
        guard let size = Double(number), size >= 0, size <= 200 else { return nil }
        return size
    }

    public static func sizeText(_ size: Double) -> String {
        if size <= 0 || !size.isFinite { return "Auto" }
        let tenth = (size * 10).rounded() / 10
        if tenth == tenth.rounded(), let whole = Int(exactly: tenth) { return String(whole) }
        return String(tenth)
    }

    /// The change is one worth writing: the fields differ, comparing the choices as they show.
    public static func differs(_ a: DesignField, _ b: DesignField) -> Bool {
        if a.options != b.options || a.shownOptions != b.shownOptions { return true }
        return a.with {
            $0.options = b.options
            $0.optionLabels = b.optionLabels
        } != b
    }
}
