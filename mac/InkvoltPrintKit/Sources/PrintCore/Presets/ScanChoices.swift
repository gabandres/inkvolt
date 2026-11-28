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

    /// Color, then grayscale, as far as the source lists them (a source listing neither gets both: eSCL falls back), then black
    /// and white when the source lists it.
    public static func colors(_ caps: ScannerCapabilities, _ source: ScanSource) -> [ScanColor] {
        let modes = caps.input(for: source)?.colorModes ?? []
        var list: [ScanColor] = []
        if modes.isEmpty || modes.contains("RGB24") { list.append(.color) }
        if modes.isEmpty || modes.contains("Grayscale8") { list.append(.grayscale) }
        if list.isEmpty { list.append(.color) }
        if modes.contains("BlackAndWhite1") { list.append(.blackAndWhite) }
        return list
    }

    /// The color mode to scan in from a remembered choice (a preset, the Scan dialog's last), as `offered` (`colors`) allows:
    /// color when wanted and offered, black and white when wanted and offered, else grey, else what the source has.
    public static func pick(_ offered: [ScanColor], color: Bool, blackAndWhite: Bool) -> ScanColor {
        if color && offered.contains(.color) { return .color }
        if !color && blackAndWhite && offered.contains(.blackAndWhite) { return .blackAndWhite }
        if offered.contains(.grayscale) { return .grayscale }
        return offered.first ?? .color
    }

    /// A scan in black and white is saved in a PDF at 1 bit too (a black-and-white page, roadmap 4.4).
    public static func savesOneBit(_ color: ScanColor) -> Bool { color == .blackAndWhite }

    /// A chosen color mode as it is remembered (`pick`'s two flags): color, or black and white, or neither (grey).
    public static func remember(_ color: ScanColor) -> (color: Bool, blackAndWhite: Bool) { (color == .color, color == .blackAndWhite) }

    public static func colorLabel(_ c: ScanColor) -> String {
        switch c {
        case .color: loc("Color")
        case .grayscale: loc("Grayscale")
        case .blackAndWhite: loc("Black and white")
        }
    }

    /// The feeder is chosen and scans one side: both sides can be had by turning the stack over (roadmap 4.1).
    public static func offersTurnStack(_ caps: ScannerCapabilities, _ source: ScanSource) -> Bool {
        source == .adf && caps.adf != nil && !caps.adfDuplex
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
