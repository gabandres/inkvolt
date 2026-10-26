/// A preset matched to one scanner: the request to send, whether to run text recognition, and what had to give.
public struct PresetPlan: Equatable, Sendable {
    public var request: ScanRequest
    public var ocr: Bool
    /// Plain sentences for the status line when the scanner can't do what the preset asks.
    public var notes: [String]

    /// - Parameters:
    ///   - feederLoaded: the scanner's feeder holds pages (eSCL AdfState); nil = unknown.
    ///   - metric: the region uses A4 rather than Letter (for presets without a page size).
    public static func plan(_ preset: ScanPreset, _ caps: ScannerCapabilities, feederLoaded: Bool?, ocrAvailable: Bool, metric: Bool) -> PresetPlan {
        var notes: [String] = []
        let hasGlass = caps.platen != nil
        let hasFeeder = caps.adf != nil

        let useFeeder: Bool
        switch preset.source {
        case .glass: useFeeder = !hasGlass
        case .feeder: useFeeder = hasFeeder
        default: useFeeder = hasFeeder && (feederLoaded == true || !hasGlass)
        }
        if preset.source == .glass && !hasGlass { notes.append("This scanner has no glass: scanning from the document feeder.") }
        if preset.source == .feeder && !hasFeeder { notes.append("This scanner has no document feeder: scanning from the glass.") }

        var source = ScanSource.platen
        if useFeeder {
            source = preset.twoSided && caps.adfDuplex ? .adfDuplex : .adf
            if preset.twoSided && !caps.adfDuplex { notes.append("This scanner's feeder scans one side only.") }
        }

        let colors = ScanChoices.colors(caps, source)
        let color: ScanColor = preset.color && colors.contains(.color) ? .color : colors.contains(.grayscale) ? .grayscale : colors[0]

        // The closest the source offers; between two equally close, the sharper one.
        let supported = caps.input(for: source)?.resolutions ?? []
        let dpi = supported.isEmpty ? preset.resolution : supported.min { a, b in
            let (da, db) = (abs(a - preset.resolution), abs(b - preset.resolution))
            return da != db ? da < db : a > b
        }!

        let offered = ScanChoices.pageSizes(caps, source)
        let size = ScanChoices.defaultPageSize(offered, remembered: preset.pageSize, metric: metric)
        if let wanted = preset.pageSize, size.key != wanted, let missing = ScanChoices.pageSizes.first(where: { $0.key == wanted }) {
            notes.append("\(missing.label) doesn't fit this source: scanning \(size.label).")
        }

        let ocr = preset.fileType == .searchablePdf && ocrAvailable
        if preset.fileType == .searchablePdf && !ocrAvailable {
            notes.append("Text recognition isn't available on this Mac: the PDF won't be searchable.")
        }
        return PresetPlan(request: ScanChoices.request(source, color, dpi, size), ocr: ocr, notes: notes)
    }
}
