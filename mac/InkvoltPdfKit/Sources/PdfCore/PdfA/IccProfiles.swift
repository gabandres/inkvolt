import Foundation

/// ICC color profiles written here (no third-party profile is shipped), the Windows app's `IccProfiles`.
public enum IccProfiles {
    private static let srgbProfile = buildSrgb()

    /// An sRGB (IEC 61966-2-1) display profile, ICC version 2.1: the sRGB primaries adapted to D50 (Bradford), D65 white
    /// point, and the sRGB tone curve as a 1024-entry table. About 2.6 KB; the same bytes as Windows writes.
    public static func srgb() -> [UInt8] { srgbProfile }

    private static func buildSrgb() -> [UInt8] {
        let tags: [(sig: String, data: [UInt8])] = [
            ("desc", desc("sRGB IEC61966-2.1 (Inkvolt PDF)")),
            ("cprt", text("No copyright: the sRGB colorimetry of IEC 61966-2-1, written by Inkvolt PDF")),
            ("wtpt", xyz(0.9505, 1.0, 1.0890)),
            ("rXYZ", xyz(0.4361, 0.2225, 0.0139)),
            ("gXYZ", xyz(0.3851, 0.7169, 0.0971)),
            ("bXYZ", xyz(0.1431, 0.0606, 0.7141)),
            ("rTRC", curve()),
        ]
        // gTRC and bTRC share rTRC's data (the same offset), as ICC allows.
        let count = tags.count + 2
        let offset = 128 + 4 + 12 * count
        var table: [(sig: String, offset: Int, size: Int)] = []
        var body: [UInt8] = []
        for (sig, data) in tags {
            table.append((sig, offset + body.count, data.count))
            body += data
            while body.count % 4 != 0 { body.append(0) }
        }
        let trc = table[table.count - 1]
        table.append(("gTRC", trc.offset, trc.size))
        table.append(("bTRC", trc.offset, trc.size))

        let size = offset + body.count
        var p = [UInt8](repeating: 0, count: size)
        put32(&p, 0, size)
        put32(&p, 8, 0x0210_0000) // version 2.1
        ascii(&p, 12, "mntr")
        ascii(&p, 16, "RGB ")
        ascii(&p, 20, "XYZ ")
        for (i, v) in [(24, 2026), (26, 1), (28, 1)] { put16(&p, i, v) }
        ascii(&p, 36, "acsp")
        ascii(&p, 40, "MSFT")
        put32(&p, 64, 0) // perceptual
        s15(&p, 68, 0.9642)
        s15(&p, 72, 1.0)
        s15(&p, 76, 0.8249)
        put32(&p, 128, count)
        for (i, t) in table.enumerated() {
            let at = 132 + 12 * i
            ascii(&p, at, t.sig)
            put32(&p, at + 4, t.offset)
            put32(&p, at + 8, t.size)
        }
        p.replaceSubrange(offset..<size, with: body)
        return p
    }

    private static func put32(_ p: inout [UInt8], _ at: Int, _ v: Int) {
        let u = UInt32(truncatingIfNeeded: v)
        p[at] = UInt8(u >> 24)
        p[at + 1] = UInt8((u >> 16) & 0xFF)
        p[at + 2] = UInt8((u >> 8) & 0xFF)
        p[at + 3] = UInt8(u & 0xFF)
    }

    private static func put16(_ p: inout [UInt8], _ at: Int, _ v: Int) {
        p[at] = UInt8((v >> 8) & 0xFF)
        p[at + 1] = UInt8(v & 0xFF)
    }

    private static func ascii(_ p: inout [UInt8], _ at: Int, _ s: String) {
        for (i, b) in s.utf8.enumerated() { p[at + i] = b }
    }

    private static func s15(_ p: inout [UInt8], _ at: Int, _ v: Double) { put32(&p, at, Int((v * 65536).rounded(.toNearestOrEven))) }

    private static func xyz(_ x: Double, _ y: Double, _ z: Double) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 20)
        ascii(&b, 0, "XYZ ")
        s15(&b, 8, x)
        s15(&b, 12, y)
        s15(&b, 16, z)
        return b
    }

    private static func text(_ s: String) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 8 + s.utf8.count + 1)
        ascii(&b, 0, "text")
        ascii(&b, 8, s)
        return b
    }

    /// textDescriptionType: ASCII description, empty Unicode and ScriptCode parts.
    private static func desc(_ s: String) -> [UInt8] {
        let n = s.utf8.count
        var b = [UInt8](repeating: 0, count: 8 + 4 + n + 1 + 4 + 4 + 2 + 1 + 67)
        ascii(&b, 0, "desc")
        put32(&b, 8, n + 1)
        ascii(&b, 12, s)
        return b
    }

    /// The sRGB transfer curve (linear below 0.04045, else the 2.4 power segment), 1024 entries.
    private static func curve() -> [UInt8] {
        let n = 1024
        var b = [UInt8](repeating: 0, count: 12 + 2 * n)
        ascii(&b, 0, "curv")
        put32(&b, 8, n)
        for i in 0..<n {
            let v = Double(i) / Double(n - 1)
            let linear = v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
            put16(&b, 12 + 2 * i, Int((linear * 65535).rounded(.toNearestOrEven)))
        }
        return b
    }
}
