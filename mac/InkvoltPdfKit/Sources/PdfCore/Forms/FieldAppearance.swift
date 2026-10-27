import Foundation

/// What a text or choice widget should show.
struct FieldLook {
    var da = "/Helv 0 Tf 0 g"
    var drBaseFont: String?
    var quadding = 0
    var multiline = false
    var comb = false
    var password = false
    var maxLen = 0
    var text = ""
    var listBox = false
    var items: [String] = []
    var selected: Set<Int> = []
    var topIndex = 0
    var colorOverride: PdfColorValue?
}

/// Builds normal appearance streams for text and choice widgets (what viewers ignoring NeedAppearances show), as the
/// Windows app's `FieldAppearance` does.
enum FieldAppearance {
    /// Beyond this a comb field (/MaxLen from the file) is drawn as plain text: a hostile /MaxLen of a billion would
    /// otherwise draw a billion cell dividers.
    private static let maxCombCells = 1000

    /// The appearance (a form XObject's reference), or nil when the widget has no usable /Rect.
    static func build(_ doc: MuDoc, _ widget: PObj, _ look: FieldLook) -> PObj? {
        guard let r = widget.array("Rect"), r.count >= 4 else { return nil }
        let rw = abs(r.num(2) - r.num(0))
        let rh = abs(r.num(3) - r.num(1))
        if !(rw > 0 && rh > 0) { return nil }

        let mk = widget.dict("MK")
        let rot = (((mk?.int("R") ?? 0) % 360) + 360) % 360
        let bg = PdfColorValue.from(mk?.array("BG"))
        let bc = PdfColorValue.from(mk?.array("BC"))
        let bs = widget.dict("BS")
        let bw: Double
        if let bs, bs.has("W") {
            bw = bs.number("W") ?? 1
        } else if let border = widget.array("Border"), border.count >= 3 {
            bw = border.num(2)
        } else {
            bw = 1
        }
        let style = bs?.name("S") ?? "S"
        let drawBorder = bc != nil && bw > 0
        let (w, h) = rot == 90 || rot == 270 ? (rh, rw) : (rw, rh)
        let f = PdfNum.f

        var ops = ""
        if let bg { ops += "q \(bg.fill) 0 0 \(f(w)) \(f(h)) re f Q\n" }
        if let bc, drawBorder {
            let half = bw / 2
            ops += "q \(bc.stroke) \(f(bw)) w "
            if style == "D" { ops += "[3] 0 d " }
            if style == "U" {
                ops += "0 \(f(half)) m \(f(w)) \(f(half)) l S"
            } else {
                ops += "\(f(half)) \(f(half)) \(f(w - bw)) \(f(h - bw)) re S"
            }
            if look.comb && look.maxLen > 1 && look.maxLen <= maxCombCells && !look.multiline {
                for i in 1..<look.maxLen {
                    let x = w * Double(i) / Double(look.maxLen)
                    ops += " \(f(x)) 0 m \(f(x)) \(f(h)) l S"
                }
            }
            ops += " Q\n"
        }

        let inset = drawBorder ? bw * (style == "B" || style == "I" ? 2 : 1) : 0
        let pad = inset + 2
        ops += "/Tx BMC\nq\n"
        ops += "\(f(inset)) \(f(inset)) \(f(max(0, w - 2 * inset))) \(f(max(0, h - 2 * inset))) re W n\n"

        let da = DefaultAppearance.parse(look.da)
        let std = StdFont.fromName(look.drBaseFont ?? da.fontName)
        let color = look.colorOverride ?? da.color
        let auto = da.size <= 0
        var size = da.size

        let painter: TextPainter
        if look.listBox {
            painter = TextPainter(std, look.items)
            if auto { size = 12 }
            let lh = size * 1.15
            var y = h - pad
            var i = max(0, look.topIndex)
            while i < look.items.count && y > 0 {
                if look.selected.contains(i) { ops += "0.6 0.75 0.85 rg \(f(inset)) \(f(y - lh)) \(f(w - 2 * inset)) \(f(lh)) re f\n" }
                let lw = painter.measure(look.items[i]) * size
                let baseline = y - lh + (lh - size * (painter.ascent - painter.descent)) / 2 - painter.descent * size
                painter.draw(look.items[i], alignX(look.quadding, lw, w, pad), baseline, size)
                y -= lh
                i += 1
            }
        } else {
            var text = look.password ? String(repeating: "*", count: look.text.unicodeScalars.count) : look.text
            painter = TextPainter(std, [text])
            let lineHeightEm = painter.ascent - painter.descent
            if look.multiline {
                let avail = max(1, w - 2 * pad)
                var lines: [String]
                if auto {
                    size = 12
                    while true {
                        lines = painter.wrap(text, avail, size)
                        if Double(lines.count) * size * 1.15 <= h - 2 * pad || size <= 4 { break }
                        size -= 0.5
                    }
                } else {
                    lines = painter.wrap(text, avail, size)
                }
                var y = h - pad - painter.ascent * size
                for line in lines {
                    painter.draw(line, alignX(look.quadding, painter.measure(line) * size, w, pad), y, size)
                    y -= size * 1.15
                }
            } else {
                text = text.replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                if look.comb && look.maxLen > 0 && look.maxLen <= maxCombCells {
                    let cell = w / Double(look.maxLen)
                    let chars = text.unicodeScalars.prefix(look.maxLen).map { String($0) }
                    if auto {
                        size = max(1, (h - 2 * pad) / lineHeightEm)
                        let widest = chars.map(painter.measure).max() ?? 0
                        if widest > 0 { size = min(size, cell * 0.9 / widest) }
                    }
                    let y = (h - size * lineHeightEm) / 2 - painter.descent * size
                    for (i, c) in chars.enumerated() {
                        painter.draw(c, Double(i) * cell + (cell - painter.measure(c) * size) / 2, y, size)
                    }
                } else {
                    let tw = painter.measure(text)
                    if auto {
                        size = max(1, (h - 2 * pad) / lineHeightEm)
                        if tw * size > w - 2 * pad && tw > 0 { size = max(4, (w - 2 * pad) / tw) }
                    }
                    let y = (h - size * lineHeightEm) / 2 - painter.descent * size
                    painter.draw(text, alignX(look.quadding, tw * size, w, pad), y, size)
                }
            }
        }

        let built = painter.build(doc, w, h, da.fontName, color)
        let content = latin1Bytes(ops) + built.ops + Array("Q\nEMC\n".utf8)
        return doc.formXObject(content, 0, 0, w, h, built.resources, matrix: rotation(doc, rot, rw, rh))
    }

    /// The /Matrix turning an appearance drawn upright in a (w, h) box into the widget's /MK /R rotation.
    static func rotation(_ doc: MuDoc, _ rot: Int, _ rw: Double, _ rh: Double) -> PObj? {
        switch rot {
        case 90: return doc.array([doc.int(0), doc.int(1), doc.int(-1), doc.int(0), doc.real(rh), doc.int(0)])
        case 180: return doc.array([doc.int(-1), doc.int(0), doc.int(0), doc.int(-1), doc.real(rw), doc.real(rh)])
        case 270: return doc.array([doc.int(0), doc.int(-1), doc.int(1), doc.int(0), doc.int(0), doc.real(rw)])
        default: return nil
        }
    }

    private static func alignX(_ q: Int, _ lineWidth: Double, _ w: Double, _ pad: Double) -> Double {
        switch q {
        case 1: return (w - lineWidth) / 2
        case 2: return w - pad - lineWidth
        default: return pad
        }
    }

    static func latin1Bytes(_ s: String) -> [UInt8] { s.unicodeScalars.map { $0.value < 256 ? UInt8($0.value) : 63 } }
}

/// A check box's or radio button's on and off faces (and pressed ones), the Windows app's `FormDesign.ButtonFaces`:
/// background and border (a circle for radio buttons), and when on, the /MK /CA ZapfDingbats symbol (✔ for check boxes)
/// or a dot for radio buttons. The usual symbols are drawn as paths: some renderers have no ZapfDingbats (poppler without
/// the base-14 fonts draws nothing for it), a path shows everywhere.
enum ButtonFaces {
    static func build(_ doc: MuDoc, _ w: PObj, radio: Bool, state: String, mark: AnnotColor) {
        guard let r = w.array("Rect"), r.count >= 4 else { return }
        let rw = abs(r.num(2) - r.num(0))
        let rh = abs(r.num(3) - r.num(1))
        if !(rw > 0 && rh > 0) { return }
        if w.dict("MK") == nil { w.set("MK", doc.dict()) }
        guard let mk = w.dict("MK") else { return }
        let rot = (((mk.int("R") ?? 0) % 360) + 360) % 360
        let (wd, ht) = rot == 90 || rot == 270 ? (rh, rw) : (rw, rh)
        let bg = PdfColorValue.from(mk.array("BG"))
        let bc = PdfColorValue.from(mk.array("BC"))
        let bs = w.dict("BS")
        let bw = bs?.has("W") == true ? bs?.number("W") ?? 1 : 1
        let ca = mk.text("CA") ?? ""
        let glyph: Character = ca.count == 1 ? ca.first! : radio ? "l" : "4"
        if !mk.has("CA") { mk.set("CA", doc.text(String(glyph))) }
        let f = PdfNum.f
        let rgb = "\(f(mark.r)) \(f(mark.g)) \(f(mark.b))"

        func frame(_ down: Bool) -> String {
            var sb = ""
            let cx = wd / 2, cy = ht / 2
            let rad = min(wd, ht) / 2
            let fill = down ? PdfColorValue(c: [0.75]) : bg
            if radio {
                if let fill { sb += "q \(fill.fill) \(circle(cx, cy, rad)) f Q\n" }
                if let bc, bw > 0 { sb += "q \(bc.stroke) \(f(bw)) w \(circle(cx, cy, rad - bw / 2)) s Q\n" }
            } else {
                if let fill { sb += "q \(fill.fill) 0 0 \(f(wd)) \(f(ht)) re f Q\n" }
                if let bc, bw > 0 { sb += "q \(bc.stroke) \(f(bw)) w \(f(bw / 2)) \(f(bw / 2)) \(f(wd - bw)) \(f(ht - bw)) re S Q\n" }
            }
            return sb
        }

        func symbol() -> String {
            let inner = min(wd, ht) - 2 * bw
            let cx = wd / 2, cy = ht / 2
            let h = max(0.5, inner * 0.36) // half the symbol's size
            func p(_ x: Double, _ y: Double) -> String { "\(f(cx + x * h)) \(f(cy + y * h))" }
            switch glyph {
            case "l":
                return "q \(rgb) rg \(circle(cx, cy, max(0.5, inner * (radio ? 0.27 : 0.3)))) f Q\n"
            case "4": // check mark
                return "q \(rgb) RG \(f(max(0.6, inner * 0.13))) w 1 J 1 j \(p(-0.8, 0)) m \(p(-0.25, -0.65)) l \(p(0.85, 0.75)) l S Q\n"
            case "8": // cross
                return "q \(rgb) RG \(f(max(0.6, inner * 0.12))) w 1 J \(p(-0.7, -0.7)) m \(p(0.7, 0.7)) l \(p(-0.7, 0.7)) m \(p(0.7, -0.7)) l S Q\n"
            case "n": // square
                return "q \(rgb) rg \(p(-0.65, -0.65)) \(f(1.3 * h)) \(f(1.3 * h)) re f Q\n"
            case "u": // diamond
                return "q \(rgb) rg \(p(0, -0.85)) m \(p(0.85, 0)) l \(p(0, 0.85)) l \(p(-0.85, 0)) l h f Q\n"
            default:
                let size = max(1, inner * 0.8)
                let advance = zapfWidth(glyph) * size
                let x = (wd - advance) / 2
                let y = (ht - size * 0.7) / 2 // ZapfDingbats symbols stand about 0.7 em tall on the baseline
                let text = String(decoding: WinAnsi.literal(String(glyph)), as: UTF8.self)
                return "q BT \(rgb) rg /ZaDb \(f(size)) Tf \(f(x)) \(f(y)) Td (\(text)) Tj ET Q\n"
            }
        }

        let usesFont = !"l48nu".contains(glyph)
        func face(_ content: String, _ withFont: Bool) -> PObj {
            let res = withFont ? doc.dict([("Font", doc.dict([("ZaDb", FontResources.standard(doc, "ZapfDingbats"))]))]) : nil
            return doc.formXObject(FieldAppearance.latin1Bytes(content), 0, 0, wd, ht, res, matrix: FieldAppearance.rotation(doc, rot, rw, rh))
        }
        func states(_ down: Bool) -> PObj {
            doc.dict([(state, face(frame(down) + symbol(), usesFont)), ("Off", face(frame(down), false))])
        }
        w.set("AP", doc.dict([("N", states(false)), ("D", states(true))]))
        if w.name("AS") != state { w.set("AS", doc.name("Off")) }
    }

    /// A circle path (four Bézier arcs) centred on (cx, cy).
    private static func circle(_ cx: Double, _ cy: Double, _ r: Double) -> String {
        let k = 0.5523
        func p(_ x: Double, _ y: Double) -> String { "\(PdfNum.f(x)) \(PdfNum.f(y))" }
        return "\(p(cx + r, cy)) m \(p(cx + r, cy + r * k)) \(p(cx + r * k, cy + r)) \(p(cx, cy + r)) c "
            + "\(p(cx - r * k, cy + r)) \(p(cx - r, cy + r * k)) \(p(cx - r, cy)) c "
            + "\(p(cx - r, cy - r * k)) \(p(cx - r * k, cy - r)) \(p(cx, cy - r)) c "
            + "\(p(cx + r * k, cy - r)) \(p(cx + r, cy - r * k)) \(p(cx + r, cy)) c h"
    }

    /// Advance widths (em) of the ZapfDingbats symbols Acrobat offers for check boxes and radio buttons.
    private static func zapfWidth(_ c: Character) -> Double {
        switch c {
        case "4": return 0.846
        case "8": return 0.838
        case "l": return 0.791
        case "n": return 0.761
        case "u": return 0.759
        case "H": return 0.816
        default: return 0.8
        }
    }
}
