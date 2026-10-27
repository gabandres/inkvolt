import Foundation

/// The photos on a scan of the glass, adjusted by hand before saving (the Windows app's `PhotoBoxesView` and the photo
/// commands of its `ScanViewModel`). Drag inside a box to move it, a corner to resize it, the round handle on its top edge to
/// turn it (the handle marks the photo's top); drag on the glass outside the boxes to mark a photo that wasn't found. Arrows
/// move the selected box, Shift+arrows resize it, Option+arrows turn it (half a degree; Option+Shift: five), Delete removes it.
/// Points are in units of the scan's width, y down (`PhotoBox`); `pageWidth` is the scan's drawn width in points, which sizes
/// the handles. The Windows app keeps these rules in its view; here they're PrintCore's, so they're tested.
public struct PhotoBoxEditor: Sendable {
    /// Handles' size and the turning handle's distance above the top edge, in points; a key press's step and the smallest
    /// side, in scan widths.
    public static let handle = 9.0, rotateGap = 26.0, keyStep = 0.004, minSize = 0.03

    /// What a press grabs.
    public enum Grip: Equatable, Sendable {
        case none
        /// The glass outside the boxes: a new box is drawn.
        case draw
        case move
        /// A corner of the selected box, numbered as `PhotoBox.corners()` numbers them.
        case corner(Int)
        /// The selected box's turning handle.
        case rotate
    }

    public private(set) var boxes: [PhotoBox]
    /// The selected box's index, or -1.
    public private(set) var selected: Int
    /// The scan's height in units of its width.
    public let aspect: Double

    private var grip = Grip.none
    private var start = PhotoPoint(0, 0)
    private var startBox = PhotoBox(centerX: 0, centerY: 0, width: 0, height: 0, angle: 0)
    /// Whether this drag has drawn its box yet (it appears once the pointer has moved a little).
    private var drawn = false

    public init(boxes: [PhotoBox], aspect: Double) {
        self.boxes = boxes
        self.aspect = aspect
        selected = boxes.isEmpty ? -1 : 0
    }

    public var selectedBox: PhotoBox? { boxes.indices.contains(selected) ? boxes[selected] : nil }

    public var isDragging: Bool { grip != .none }

    public mutating func select(_ index: Int) { selected = boxes.indices.contains(index) ? index : -1 }

    /// The turning handle: above the middle of the box's top edge, `rotateGap` points out.
    public static func rotateHandle(_ box: PhotoBox, pageWidth: Double) -> PhotoPoint {
        let c = box.corners()
        let gap: Double = rotateGap / pageWidth
        let radians: Double = box.angle * .pi / 180
        return PhotoPoint((c[0].x + c[1].x) / 2 + sin(radians) * gap, (c[0].y + c[1].y) / 2 - cos(radians) * gap)
    }

    /// What a press at `p` would take: the selected box's turning handle, then its corners, then any box (the selected one
    /// first, then the last drawn), else the glass.
    public func grip(at p: PhotoPoint, pageWidth: Double) -> Grip {
        if let box = selectedBox {
            if Self.distance(Self.rotateHandle(box, pageWidth: pageWidth), p) * pageWidth <= Self.handle + 2 { return .rotate }
            if let hit = box.corners().firstIndex(where: { Self.distance($0, p) * pageWidth <= Self.handle }) { return .corner(hit) }
            if box.contains(p.x, p.y) { return .move }
        }
        return boxes.contains { $0.contains(p.x, p.y) } ? .move : .draw
    }

    public mutating func press(at p: PhotoPoint, pageWidth: Double) {
        start = p
        drawn = false
        grip = grip(at: p, pageWidth: pageWidth)
        if grip == .move, !(selectedBox?.contains(p.x, p.y) ?? false) {
            selected = boxes.lastIndex { $0.contains(p.x, p.y) } ?? -1
        }
        if let box = selectedBox, grip != .draw { startBox = box }
    }

    /// The pointer moved to `p` with the button down; `snap` (Shift) turns in steps of 15°.
    public mutating func drag(to p: PhotoPoint, snap: Bool = false) {
        switch grip {
        case .none:
            return
        case .move:
            var box = startBox
            box.centerX += p.x - start.x
            box.centerY += p.y - start.y
            replace(box)
        case .corner(let corner):
            replace(startBox.withCorner(corner, p.x, p.y, min: Self.minSize))
        case .rotate:
            // The handle points at the photo's top: the angle from the centre to the pointer, a quarter back.
            var degrees: Double = atan2(p.x - startBox.centerX, -(p.y - startBox.centerY)) * 180 / .pi
            if snap { degrees = (degrees / 15).rounded() * 15 }
            var box = startBox
            box.angle = (degrees * 10).rounded() / 10
            replace(box)
        case .draw:
            let box = PhotoBox(centerX: (start.x + p.x) / 2, centerY: (start.y + p.y) / 2,
                               width: abs(p.x - start.x), height: abs(p.y - start.y), angle: 0)
            if drawn {
                replace(box)
            } else if box.width > Self.minSize / 3 || box.height > Self.minSize / 3 {
                boxes.append(box)
                selected = boxes.count - 1
                drawn = true
            }
        }
    }

    /// The button let go: a box drawn too small to be a photo goes away again.
    public mutating func release() {
        if grip == .draw, drawn, let box = selectedBox, box.width < Self.minSize || box.height < Self.minSize {
            boxes.remove(at: selected)
            selected = boxes.count - 1
        }
        grip = .none
        drawn = false
    }

    /// Tab (or Shift+Tab) through the photos; false past the last (or before the first), so the focus moves on.
    public mutating func selectNext(backwards: Bool = false) -> Bool {
        let next = selected + (backwards ? -1 : 1)
        guard boxes.indices.contains(next) else { return false }
        selected = next
        return true
    }

    /// An arrow key (`dx`, `dy`: -1, 0 or 1) on the selected box: moved a step, or resized, or turned (half a degree, five
    /// when `coarse`).
    public mutating func nudge(dx: Int, dy: Int, resize: Bool = false, turn: Bool = false, coarse: Bool = false) {
        guard var box = selectedBox, dx != 0 || dy != 0 else { return }
        let (x, y) = (Double(dx), Double(dy))
        if turn {
            box.angle = ((box.angle + (x + y) * (coarse ? 5 : 0.5)) * 10).rounded() / 10
        } else if resize {
            box.width = max(Self.minSize, box.width + x * Self.keyStep)
            box.height = max(Self.minSize, box.height + y * Self.keyStep)
        } else {
            box.centerX += x * Self.keyStep
            box.centerY += y * Self.keyStep
        }
        replace(box)
    }

    /// A box in the middle of the glass, for a photo that wasn't found (and can't be drawn: the keyboard's way).
    public mutating func add() {
        boxes.append(PhotoBox(centerX: 0.5, centerY: aspect / 2, width: 0.4, height: 0.3, angle: 0))
        selected = boxes.count - 1
    }

    public mutating func removeSelected() {
        guard selectedBox != nil else { return }
        boxes.remove(at: selected)
        selected = min(selected, boxes.count - 1)
    }

    /// The selected photo is saved turned a further quarter clockwise (a portrait print laid on its side).
    public mutating func turnSelected() {
        guard var box = selectedBox else { return }
        box.quarterTurns = (box.quarterTurns + 1) % 4
        replace(box)
    }

    /// The photos looked for again (Find Again), the changes made here dropped.
    public mutating func replaceAll(_ found: [PhotoBox]) {
        boxes = found
        selected = found.isEmpty ? -1 : 0
        grip = .none
    }

    /// "Photo 2 of 3: 6.0 × 4.0 in, straightened by 3°." for the selected photo, or how many there are; `widthInches` is the
    /// scan's width.
    public func status(widthInches: Double) -> String {
        if boxes.isEmpty { return "No photos marked: the whole scan is saved as one picture. Drag over a photo to mark it." }
        guard let b = selectedBox else {
            return boxes.count == 1 ? "1 photo, saved as its own picture." : "\(boxes.count) photos, each saved as its own picture."
        }
        let turns = b.quarterTurns % 4 == 0 ? "" : ", saved turned \(90 * b.quarterTurns)°"
        return "Photo \(selected + 1) of \(boxes.count): \(Self.oneDecimal(b.width * widthInches)) × "
            + "\(Self.oneDecimal(b.height * widthInches)) in, straightened by \(Self.degrees(b.angle))°\(turns)."
    }

    private mutating func replace(_ box: PhotoBox) {
        if boxes.indices.contains(selected) { boxes[selected] = box }
    }

    private static func distance(_ a: PhotoPoint, _ b: PhotoPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }

    private static func oneDecimal(_ value: Double) -> String { String(format: "%.1f", value) }

    /// .NET's "0.#": one decimal at most, none when it's 0.
    private static func degrees(_ value: Double) -> String {
        let r: Double = (value * 10).rounded() / 10
        if r == r.rounded() { return "\(Int(r))" }
        return String(format: "%.1f", r)
    }
}
