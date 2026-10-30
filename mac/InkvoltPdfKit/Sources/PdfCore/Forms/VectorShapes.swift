import Foundation

/// A visible straight line or rectangle drawn on a page (page space), as `VectorShapes` finds them. `isLine`: a horizontal
/// rule (a stroked segment, or a filled rectangle no thicker than 3 pt); otherwise a box.
public struct PageShape: Equatable, Sendable {
    public var box: RectD
    public var isLine: Bool

    public init(_ box: RectD, _ isLine: Bool) {
        self.box = box
        self.isLine = isLine
    }
}

/// Reads the rectangles and horizontal rules a page's content draws (including inside form XObjects), for
/// `FieldDetection` (the Windows app's `VectorShapes`): `re` rectangles and closed four-sided axis-aligned paths, stroked
/// horizontal segments, and thin filled bars. Curves, clipping paths, invisible (unpainted or white-on-nothing) paths and
/// turned shapes are left out. Coordinates follow the current transformation matrix, so shapes drawn under `cm` or in a
/// scaled form land where they show.
public enum VectorShapes {
    private static let maxOperators = 400_000
    private static let maxShapes = 20_000
    private static let maxDepth = 8

    public static func read(_ data: [UInt8], _ password: String?, _ pageIndex: Int, cancel: CancelToken? = nil) throws -> [PageShape] {
        try read(PdfEdit.open(data, password, failure: "This PDF's pages can't be read"), pageIndex, cancel: cancel)
    }

    static func read(_ doc: MuDoc, _ pageIndex: Int, cancel: CancelToken? = nil) throws -> [PageShape] {
        try Annotations.checkPage(doc, pageIndex)
        let page = doc.page(pageIndex)
        let walker = Walker(page, cancel)
        // Malformed content keeps what was found up to there; the lexer stops at what it can't read.
        try walker.run(ContentEditor.contentBytes(page), FormEditor.inherited(page, "Resources"), State(ctm: .identity), 0)
        return walker.shapes
    }

    private struct Matrix {
        var a: Double, b: Double, c: Double, d: Double, e: Double, f: Double
        static let identity = Matrix(a: 1, b: 0, c: 0, d: 1, e: 0, f: 0)

        /// This transform followed by `m` (PDF: CTM' = this × CTM when this is the cm operand).
        func then(_ m: Matrix) -> Matrix {
            Matrix(a: a * m.a + b * m.c, b: a * m.b + b * m.d,
                   c: c * m.a + d * m.c, d: c * m.b + d * m.d,
                   e: e * m.a + f * m.c + m.e, f: e * m.b + f * m.d + m.f)
        }

        func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) { (a * x + c * y + e, b * x + d * y + f) }

        /// How much lengths grow (the geometric mean of the axes' scales).
        var scale: Double { abs(a * d - b * c).squareRoot() }
    }

    private struct State {
        var ctm: Matrix
        var lineWidth = 1.0
        var strokeWhite = false, fillWhite = false
    }

    private struct SubPath {
        var points: [(x: Double, y: Double)] = []
        var closed = false, curved = false, isRect = false
    }

    private final class Walker {
        var shapes: [PageShape] = []
        private let frame: PageFrame
        private let cancel: CancelToken?
        private var forms: [UInt: [COp]] = [:]
        private var ops = 0

        init(_ page: PObj, _ cancel: CancelToken?) {
            frame = PageBoxes.frame(page)
            self.cancel = cancel
        }

        /// Walks a content stream starting from `state` (a form XObject inherits its caller's).
        func run(_ content: [UInt8], _ resources: PObj?, _ state: State, _ depth: Int) throws {
            try run(ContentLexer.parse(content, cancel: cancel), resources, state, depth)
        }

        private func run(_ list: [COp], _ resources: PObj?, _ start: State, _ depth: Int) throws {
            var state = start
            var stack: [State] = []
            var path: [SubPath] = []
            var current: Int? // the sub-path `m` began, in `path`

            for op in list {
                ops += 1
                if ops > VectorShapes.maxOperators || shapes.count >= VectorShapes.maxShapes { return }
                if ops & 1023 == 0 { try cancel?.check() }
                let n = op.operands.filter { $0.kind == .number }.map(\.num)
                switch op.name {
                case "q":
                    stack.append(state)
                case "Q":
                    if let top = stack.popLast() { state = top }
                case "cm" where n.count >= 6:
                    state.ctm = Matrix(a: n[0], b: n[1], c: n[2], d: n[3], e: n[4], f: n[5]).then(state.ctm)
                case "w" where n.count >= 1:
                    state.lineWidth = n[0]
                case "G" where n.count >= 1:
                    state.strokeWhite = n[0] >= 0.98
                case "g" where n.count >= 1:
                    state.fillWhite = n[0] >= 0.98
                case "RG" where n.count >= 3:
                    state.strokeWhite = n[0] >= 0.98 && n[1] >= 0.98 && n[2] >= 0.98
                case "rg" where n.count >= 3:
                    state.fillWhite = n[0] >= 0.98 && n[1] >= 0.98 && n[2] >= 0.98
                case "K" where n.count >= 4:
                    state.strokeWhite = n[0] <= 0.02 && n[1] <= 0.02 && n[2] <= 0.02 && n[3] <= 0.02
                case "k" where n.count >= 4:
                    state.fillWhite = n[0] <= 0.02 && n[1] <= 0.02 && n[2] <= 0.02 && n[3] <= 0.02
                case "SC", "SCN", "CS":
                    state.strokeWhite = false // a color we don't read: count it as visible
                case "sc", "scn", "cs":
                    state.fillWhite = false
                case "m" where n.count >= 2:
                    path.append(SubPath(points: [(n[0], n[1])]))
                    current = path.count - 1
                case "l" where n.count >= 2 && current != nil:
                    path[current!].points.append((n[0], n[1]))
                case "c" where n.count >= 6 && current != nil:
                    path[current!].curved = true
                    path[current!].points.append((n[4], n[5]))
                case "v" where n.count >= 4 && current != nil, "y" where n.count >= 4 && current != nil:
                    path[current!].curved = true
                    path[current!].points.append((n[2], n[3]))
                case "h" where current != nil:
                    path[current!].closed = true
                case "re" where n.count >= 4:
                    path.append(SubPath(points: [(n[0], n[1]), (n[0] + n[2], n[1]), (n[0] + n[2], n[1] + n[3]), (n[0], n[1] + n[3])], closed: true, isRect: true))
                    current = nil
                case "S", "s", "f", "F", "f*", "B", "B*", "b", "b*", "n":
                    let closes = op.name == "s" || op.name == "b" || op.name == "b*"
                    if closes, let current { path[current].closed = true }
                    let stroke = ["S", "s", "B", "B*", "b", "b*"].contains(op.name) && !state.strokeWhite
                    let fill = ["f", "F", "f*", "B", "B*", "b", "b*"].contains(op.name) && !state.fillWhite
                    if stroke || fill {
                        for sub in path { emit(sub, state, stroke, fill) }
                    }
                    path.removeAll(keepingCapacity: true)
                    current = nil
                case "Do" where depth < VectorShapes.maxDepth && op.operands.first?.kind == .name:
                    try runForm(resources, op.operands[0].name, state, depth)
                default:
                    break
                }
            }
        }

        private func runForm(_ resources: PObj?, _ name: String, _ state: State, _ depth: Int) throws {
            guard let form = resources?.dict("XObject")?.dict(name), form.name("Subtype") == "Form" else { return }
            var m = Matrix.identity
            if let a = form.array("Matrix"), a.count == 6 {
                m = Matrix(a: a.num(0), b: a.num(1), c: a.num(2), d: a.num(3), e: a.num(4), f: a.num(5))
            }
            // Read once: a form can be drawn many times, and its content (comments, say) cost more than its operators.
            let key = form.identity
            let list: [COp]
            if let known = forms[key] {
                list = known
            } else {
                list = try ContentLexer.parse(form.streamData ?? [], cancel: cancel)
                forms[key] = list
            }
            if list.isEmpty { return }
            var inner = state
            inner.ctm = m.then(state.ctm)
            try run(list, form.dict("Resources") ?? resources, inner, depth + 1)
        }

        private func emit(_ sub: SubPath, _ state: State, _ stroke: Bool, _ fill: Bool) {
            if sub.curved || sub.points.count < 2 { return }
            let pts = sub.points.map { p -> (x: Double, y: Double) in
                let u = state.ctm.apply(p.x, p.y)
                return frame.toPage(u.x, u.y)
            }
            let thickness = max(0.5, state.lineWidth * state.ctm.scale)

            // A closed four-sided path (or `re`) whose corners line up with the axes: a box (or a bar, when thin).
            let corners = pts.count == 5 && Self.near(pts[0], pts[4]) ? Array(pts.prefix(4)) : pts
            if (sub.isRect || sub.closed || pts.count == 5) && corners.count == 4 && Self.axisAligned(corners) {
                let xs = corners.map(\.x), ys = corners.map(\.y)
                let box = RectD.fromEdges(xs.min()!, ys.min()!, xs.max()!, ys.max()!)
                if box.width < 0.5 && box.height < 0.5 { return }
                if box.height <= 3 && box.width >= 6 && (fill || box.height < 0.5) {
                    var line = box
                    if box.height < thickness { line.height = max(box.height, 0.5) }
                    add(PageShape(line, true))
                } else if box.width >= 3 && box.height > 3 {
                    add(PageShape(box, false))
                }
                return
            }
            if !stroke { return }
            // Open (or other) paths: each horizontal segment is a rule.
            for i in 1..<(pts.count + (sub.closed ? 1 : 0)) {
                let a = pts[i - 1], b = pts[i % pts.count]
                if abs(a.y - b.y) > 0.5 || abs(a.x - b.x) < 6 { continue }
                add(PageShape(RectD(min(a.x, b.x), (a.y + b.y) / 2 - thickness / 2, abs(a.x - b.x), thickness), true))
            }
        }

        private func add(_ s: PageShape) {
            if shapes.count < VectorShapes.maxShapes { shapes.append(s) }
        }

        private static func near(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Bool { abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 }

        /// Four corners in order, each edge horizontal or vertical.
        private static func axisAligned(_ c: [(x: Double, y: Double)]) -> Bool {
            for i in 0..<4 {
                let a = c[i], b = c[(i + 1) % 4]
                if abs(a.x - b.x) > 0.5 && abs(a.y - b.y) > 0.5 { return false }
            }
            return true
        }
    }
}
