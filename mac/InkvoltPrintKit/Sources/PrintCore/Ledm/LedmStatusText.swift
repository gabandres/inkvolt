/// LEDM status words. Only `humanize` so far, which IPP's words fall back on; the rest comes with the LEDM port (P3).
public enum LedmStatusText {
    /// "inPowerSave" → "In power save", "media-jam" → "Media jam".
    public static func humanize(_ camel: String) -> String {
        guard let first = camel.first else { return camel }
        var result = first.uppercased()
        var previous = first
        for c in camel.dropFirst() {
            if c == "_" || c == "-" {
                result.append(" ")
            } else if c.isUppercase && !previous.isUppercase {
                result.append(" ")
                result += c.lowercased()
            } else {
                result.append(c)
            }
            previous = c
        }
        return result
    }
}
