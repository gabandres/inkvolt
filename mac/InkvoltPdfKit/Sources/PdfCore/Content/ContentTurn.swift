import Foundation

/// Edit Text & Images' turn handle and angle box (roadmap 4.22; the Windows app's `ContentTurn`), the rules the page view
/// passes the pointer and typed text to. Angles are degrees clockwise as the page shows, -180 (excluded) to 180; the handle
/// sits out from the selection's top-right corner as shown (clear of the paragraph editor's bar, which sits above its left
/// end), and a drag turns it by how far the pointer goes round the middle of its box (Shift: to the nearest 15°). The edit
/// itself is `ContentEditor.rotateImage` or `rotateParagraph`, by `turnBy`.
public enum ContentTurn {
    /// How far out from the box's top-right corner the handle sits, across and up (view points).
    public static let handleGap = 16.0

    /// The step Shift turns by.
    public static let step = 15.0

    /// An angle as -180 (excluded) to 180, rounded to a hundredth.
    public static func normalize(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var a = degrees.truncatingRemainder(dividingBy: 360)
        if a > 180 {
            a -= 360
        } else if a <= -180 {
            a += 360
        }
        a = (a * 100).rounded(.toNearestOrEven) / 100 // .NET's Math.Round(a, 2)
        return a == -180 ? 180 : a + 0.0 // + 0.0: never -0
    }

    /// Where the handle is for a box as shown (view space, y down).
    public static func handlePoint(_ shown: RectD) -> PointD { PointD(shown.right + handleGap, shown.y - handleGap) }

    /// Whether a point (view space) is on the handle of a box as shown.
    public static func onHandle(_ shown: RectD, _ p: PointD, _ reach: Double) -> Bool {
        let h = handlePoint(shown)
        return abs(p.x - h.x) <= reach && abs(p.y - h.y) <= reach
    }

    /// The angle a drag of the handle sets: `start` turned by how far the pointer went round `center` from `from` to `to`
    /// (view space); with `steps` (Shift), the nearest multiple of `step`. A pointer on the middle itself turns nothing.
    public static func dragged(_ center: PointD, _ from: PointD, _ to: PointD, _ start: Double, steps: Bool) -> Double {
        let still = 1e-6
        if (abs(to.x - center.x) < still && abs(to.y - center.y) < still) || (abs(from.x - center.x) < still && abs(from.y - center.y) < still) {
            return normalize(start)
        }
        let a0 = atan2(from.y - center.y, from.x - center.x)
        let a1 = atan2(to.y - center.y, to.x - center.x)
        let angle = start + (a1 - a0) * 180 / .pi
        return normalize(steps ? (angle / step).rounded(.toNearestOrEven) * step : angle)
    }

    /// An angle typed in the box ("30", "-12.5", "45°", "30,5" where the comma is the decimal sign); nil when it isn't one.
    public static func parse(_ typed: String, locale: Locale = .current) -> Double? {
        var text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = text.last, last == "°" || last == "º" { text.removeLast() }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { return nil }
        func number(_ l: Locale) -> Double? {
            let f = NumberFormatter()
            f.locale = l
            f.numberStyle = .decimal
            f.usesGroupingSeparator = false
            f.isLenient = false
            guard let n = f.number(from: text) else { return nil }
            return n.doubleValue
        }
        guard let v = number(locale) ?? number(Locale(identifier: "en_US_POSIX")) ?? Double(text) else { return nil }
        return v.isFinite && abs(v) <= 100_000 ? normalize(v) : nil
    }

    /// The turn that takes something at `current` to `wanted` (the shorter way); nil when it is there already.
    public static func turnBy(_ current: Double, _ wanted: Double) -> Double? {
        let d = normalize(wanted - current)
        return abs(d) < 0.01 ? nil : d
    }

    /// An angle as the box shows it ("30°", "-12.5°").
    public static func format(_ degrees: Double, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.locale = locale
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 2
        f.minusSign = "-"
        return (f.string(from: NSNumber(value: normalize(degrees))) ?? "0") + "°"
    }

    /// A box's corners turned `degrees` about its middle (clockwise on a y-down page): the outline a turn shows while
    /// dragged.
    public static func corners(_ box: RectD, _ degrees: Double) -> [PointD] {
        let r = degrees * .pi / 180
        let s = sin(r), c = cos(r)
        let cx = box.centerX, cy = box.centerY
        return [PointD(box.x, box.y), PointD(box.right, box.y), PointD(box.right, box.bottom), PointD(box.x, box.bottom)].map { p in
            let x: Double = cx + (p.x - cx) * c - (p.y - cy) * s
            let y: Double = cy + (p.x - cx) * s + (p.y - cy) * c
            return PointD(x, y)
        }
    }
}
