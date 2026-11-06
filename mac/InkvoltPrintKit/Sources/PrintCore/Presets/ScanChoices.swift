/// A scan area in 1/300 inch (eSCL units). Nil size = the source's whole area.
public struct ScanPageSize: Equatable, Sendable {
    public let key: String
    /// The label, kept in English (`label` in the interface's language).
    public let name: LocKey
    public let width: Int?
    public let height: Int?

    public var label: String { name.text }
}

/// The scan options a dialog offers for a scanner, from its eSCL capabilities, and the `ScanRequest` they make. Shared by
/// Inkvolt Print's Scan tab (page sizes) and, later, Inkvolt PDF's Scan dialog.
public enum ScanChoices {
    public static let pageSizes: [ScanPageSize] = [
        ScanPageSize(key: "letter", name: LocKey("Letter (8.5 × 11 in)"), width: 2550, height: 3300),
        ScanPageSize(key: "a4", name: LocKey("A4 (210 × 297 mm)"), width: 2480, height: 3508),
        ScanPageSize(key: "legal", name: LocKey("Legal (8.5 × 14 in)"), width: 2550, height: 4200),
        ScanPageSize(key: "full", name: LocKey("Whole scanning area"), width: nil, height: nil),
    ]

    /// Document resolutions offered by Inkvolt PDF: enough for text and OCR, small files.
    public static let documentResolutions = [150, 200, 300]

    public static func sourceLabel(_ s: ScanSource) -> String {
        switch s {
        case .platen: loc("Scanner glass")
        case .adf: loc("Document feeder")
        case .adfDuplex: loc("Document feeder (both sides)")
        }
    }

    /// Color, then grayscale, as far as the source lists them (a source listing neither gets both: eSCL falls back).
    public static func colors(_ caps: ScannerCapabilities, _ source: ScanSource) -> [ScanColor] {
        let modes = caps.input(for: source)?.colorModes ?? []
        var list: [ScanColor] = []
        if modes.isEmpty || modes.contains("RGB24") { list.append(.color) }
        if modes.isEmpty || modes.contains("Grayscale8") { list.append(.grayscale) }
        return list.isEmpty ? [.color] : list
    }

    /// The `wanted` resolutions the source supports; when it lists resolutions but none of these, its closest one to each
    /// (distinct). A source that lists none accepts the wanted values as they are.
    public static func resolutions(_ caps: ScannerCapabilities, _ source: ScanSource, wanted: [Int] = documentResolutions) -> [Int] {
        let supported = caps.input(for: source)?.resolutions ?? []
        if supported.isEmpty { return wanted }
        return Array(Set(wanted.compactMap { w in supported.min { abs($0 - w) < abs($1 - w) } })).sorted()
    }

    /// Sizes the source can scan (a few pixels of tolerance), whole area last.
    public static func pageSizes(_ caps: ScannerCapabilities, _ source: ScanSource) -> [ScanPageSize] {
        guard let input = caps.input(for: source) else { return [pageSizes[pageSizes.count - 1]] }
        return pageSizes.filter { p in
            guard let w = p.width, let h = p.height else { return true }
            return w <= input.maxWidth + 5 && h <= input.maxHeight + 5
        }
    }

    /// The page size to preselect: the remembered key if still offered, else Letter or A4 by region.
    public static func defaultPageSize(_ offered: [ScanPageSize], remembered: String?, metric: Bool) -> ScanPageSize {
        offered.first { $0.key == remembered } ?? offered.first { $0.key == (metric ? "a4" : "letter") } ?? offered[0]
    }

    public static func request(_ source: ScanSource, _ color: ScanColor, _ dpi: Int, _ size: ScanPageSize?) -> ScanRequest {
        ScanRequest(source: source, color: color, resolution: dpi, width: size?.width, height: size?.height)
    }
}
