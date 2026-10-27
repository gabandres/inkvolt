import Foundation

/// What a print queue offers for a photo job beside its papers, as IPP keywords with its defaults (CUPS's
/// `cupsCopyDestInfo`: `media-type`, `print-quality`, `print-color-mode`). The Windows app reads the same from the
/// driver's PrintCapabilities as Print Schema names.
public struct QueueJobOptions: Equatable, Sendable {
    public var mediaTypes: [String]
    public var defaultMediaType: String?
    /// IPP's `print-quality`: 3 draft, 4 normal, 5 high.
    public var qualities: [Int]
    public var defaultQuality: Int?
    public var colorModes: [String]
    public var defaultColorMode: String?

    public init(mediaTypes: [String] = [], defaultMediaType: String? = nil, qualities: [Int] = [], defaultQuality: Int? = nil,
                colorModes: [String] = [], defaultColorMode: String? = nil) {
        self.mediaTypes = mediaTypes
        self.defaultMediaType = defaultMediaType
        self.qualities = qualities
        self.defaultQuality = defaultQuality
        self.colorModes = colorModes
        self.defaultColorMode = defaultColorMode
    }

    public static let none = QueueJobOptions()
}

/// One choice in a picker: the IPP value sent, the words shown.
public struct JobChoice: Equatable, Sendable, Identifiable {
    public var value: String
    public var label: String
    public var id: String { value }

    public init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

/// The photo job's choices from a queue's IPP keywords, worded as the Windows app words its Print Schema names
/// (`PhotoPaperText`), and the CUPS options a job is sent with.
public enum QueueJobChoices {
    /// IPP media type → the Print Schema name the Windows app words: "stationery" is plain paper, "auto" the printer's
    /// choice, the rest by their words ("photographic-glossy" → "PhotographicGlossy"); a maker's own keyword without its
    /// domain and name ("com.hp-stationery-lightweight" or "com.hp.stationery-lightweight" → "StationeryLightweight").
    public static func schemaMediaType(_ keyword: String) -> String {
        var keyword = Substring(keyword)
        if let dot = keyword.firstIndex(of: ".") {
            let rest = keyword[keyword.index(after: dot)...]
            if let end = rest.firstIndex(where: { $0 == "." || $0 == "-" }) { keyword = rest[rest.index(after: end)...] }
        }
        switch keyword {
        case "stationery": return "Plain"
        case "auto": return "AutoSelect"
        default:
            return keyword.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined()
        }
    }

    /// The paper types, as the queue lists them, worded; empty ones and ones worded the same as an earlier one (a maker's
    /// copy of a standard type) left out.
    public static func mediaTypes(_ o: QueueJobOptions) -> [JobChoice] {
        var seen = Set<String>()
        return o.mediaTypes.filter { !$0.isEmpty }
            .map { JobChoice($0, PhotoPaperText.mediaType(schemaMediaType($0))) }
            .filter { seen.insert($0.label).inserted }
    }

    /// Draft, Normal, High, lowest first; values IPP doesn't define left out.
    public static func qualities(_ o: QueueJobOptions) -> [JobChoice] {
        let names = [3: "Draft", 4: "Normal", 5: "High"]
        return Set(o.qualities).sorted().compactMap { q in names[q].map { JobChoice(String(q), PhotoPaperText.quality($0)) } }
    }

    /// Color, shades of grey, black and white (IPP's `color`, `monochrome`, `bi-level`), and Automatic; the queue's order.
    public static func colors(_ o: QueueJobOptions) -> [JobChoice] {
        let names = ["color": "Color", "monochrome": "Grayscale", "bi-level": "Monochrome", "auto": "Automatic"]
        var seen = Set<String>()
        return o.colorModes.compactMap { m in
            guard let name = names[m], seen.insert(m).inserted else { return nil }
            return JobChoice(m, PhotoPaperText.color(name))
        }
    }

    /// The choice to start with: the one kept from before, else the queue's default, else the first; nil when there's none.
    public static func initial(_ choices: [JobChoice], kept: String?, queueDefault: String?) -> String? {
        if let kept, choices.contains(where: { $0.value == kept }) { return kept }
        if let queueDefault, choices.contains(where: { $0.value == queueDefault }) { return queueDefault }
        return choices.first?.value
    }

    /// The paper the job asks for: the borderless variant when asked for and offered, else the bordered one with its
    /// printable area (libcups words it as `media` or `media-col`).
    public static func media(_ paper: PhotoPaperChoice, borderless: Bool) -> QueueMedia {
        if borderless, let b = paper.borderless { return b }
        let s = paper.sheet
        return QueueMedia(name: paper.media, width: s.width, height: s.height, left: s.left, top: s.top, right: s.right, bottom: s.bottom)
    }

    /// The CUPS options for the paper type, quality and color picked (nil: the queue's default, not sent).
    public static func jobOptions(mediaType: String?, quality: String?, color: String?) -> [(name: String, value: String)] {
        var options: [(name: String, value: String)] = []
        if let mediaType { options.append(("media-type", mediaType)) }
        if let quality { options.append(("print-quality", quality)) }
        if let color { options.append(("print-color-mode", color)) }
        return options
    }
}
