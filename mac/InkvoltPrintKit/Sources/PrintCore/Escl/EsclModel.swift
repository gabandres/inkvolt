import Foundation

public enum ScanSource: Sendable { case platen, adf, adfDuplex }

public struct InputCaps: Equatable, Sendable {
    public var minWidth: Int, maxWidth: Int, minHeight: Int, maxHeight: Int
    public var colorModes: [String]
    public var documentFormats: [String]
    public var resolutions: [Int]
    public var intents: [String]

    /// The source lists `scan:DocumentFormatExt`; scanners that don't may not expect it in ScanSettings either.
    public var hasDocumentFormatExt = true

    /// Inkvolt asks for JPEG pages; a source listing formats without JPEG can't be scanned from.
    public var offersJpeg: Bool { documentFormats.isEmpty || documentFormats.contains { $0.caseInsensitiveCompare("image/jpeg") == .orderedSame } }
}

public struct ScannerCapabilities: Equatable, Sendable {
    public var version: String
    public var makeAndModel: String?
    public var uuid: String?
    public var platen: InputCaps?
    public var adf: InputCaps?
    public var adfDuplex: Bool

    /// `scan:Manufacturer` (e.g. "EPSON"), when the scanner says.
    public var manufacturer: String?

    public var sources: [ScanSource] {
        var s: [ScanSource] = []
        if platen != nil { s.append(.platen) }
        if adf != nil { s.append(.adf) }
        if adf != nil && adfDuplex { s.append(.adfDuplex) }
        return s
    }

    public func input(for source: ScanSource) -> InputCaps? { source == .platen ? platen : adf }

    /// Reads ScannerCapabilities (Mopria eSCL). Handles what differs between makers: settings given inline or as a named
    /// `scan:SettingProfile` an input refers to (`ref="…"`), resolutions as a list or a range, and discrete resolutions whose
    /// X and Y differ (left out, as sane-airscan does).
    public static func parse(_ r: XmlElement) -> ScannerCapabilities {
        var named: [String: XmlElement] = [:]
        for p in r.kid("SettingProfiles")?.kids("SettingProfile") ?? [] {
            if let name = p.attributes["name"], !name.isEmpty, named[name] == nil { named[name] = p }
        }
        let adf = r.kid("Adf")
        return ScannerCapabilities(
            version: r.kidValue("Version") ?? "0",
            makeAndModel: r.kidValue("MakeAndModel"),
            uuid: r.kidValue("UUID"),
            platen: parseInput(r.kid("Platen")?.kid("PlatenInputCaps"), named),
            adf: parseInput(adf?.kid("AdfSimplexInputCaps"), named),
            adfDuplex: adf?.kid("AdfDuplexInputCaps") != nil,
            manufacturer: r.kidValue("Manufacturer"))
    }

    private static func parseInput(_ e: XmlElement?, _ named: [String: XmlElement]) -> InputCaps? {
        guard let e else { return nil }
        // Each profile is inline or a reference to a named one at the top; an unknown reference adds nothing.
        let profiles = e.kid("SettingProfiles")?.kids("SettingProfile").compactMap { p in p.attributes["ref"].map { named[$0] } ?? p } ?? []
        // No profiles at all (older layouts): read the settings from anywhere under the input.
        let scope = e.kid("SettingProfiles") == nil ? [e] : profiles
        var discrete: [Int] = []
        for d in scope.flatMap({ $0.all("DiscreteResolution") }) {
            let x = d.kidValue("XResolution").asInt ?? 0
            let y = d.kidValue("YResolution").asInt
            if x > 0 && (y == nil || y == x) { discrete.append(x) }
        }
        if discrete.isEmpty && e.kid("SettingProfiles") == nil {
            discrete = e.all("XResolution").map { $0.value.asInt ?? 0 }.filter { $0 > 0 }
        }
        let ranged = scope.flatMap { $0.all("XResolutionRange") }.flatMap {
            rangeResolutions(min: $0.kidValue("Min").asInt ?? 0, max: $0.kidValue("Max").asInt ?? 0, step: $0.kidValue("Step").asInt ?? 1,
                             normal: $0.kidValue("Normal").asInt ?? 0)
        }
        func distinct(_ values: [String]) -> [String] {
            var seen = Set<String>()
            return values.filter { seen.insert($0).inserted }
        }
        let trim = { (x: XmlElement) in x.value.trimmingCharacters(in: .whitespacesAndNewlines) }
        return InputCaps(
            minWidth: e.kidValue("MinWidth").asInt ?? 0, maxWidth: e.kidValue("MaxWidth").asInt ?? 2550,
            minHeight: e.kidValue("MinHeight").asInt ?? 0, maxHeight: e.kidValue("MaxHeight").asInt ?? 3508,
            colorModes: distinct(scope.flatMap { $0.all("ColorMode") }.map(trim)),
            documentFormats: distinct(scope.flatMap { $0.all("DocumentFormatExt") + $0.all("DocumentFormat") }.map(trim)),
            resolutions: Array(Set(discrete.isEmpty ? ranged : discrete)).sorted(), // a list wins over a range, as in sane-airscan
            intents: distinct(e.all("Intent").map(trim)),
            hasDocumentFormatExt: scope.contains { !$0.all("DocumentFormatExt").isEmpty })
    }

    private static let usualResolutions = [75, 100, 150, 200, 300, 400, 600, 1200]

    /// The resolutions to offer from a `scan:ResolutionRange`: the usual ones inside it that its step allows; when none
    /// are, the first eight values its step gives. An empty range offers its Normal resolution.
    public static func rangeResolutions(min: Int, max: Int, step: Int, normal: Int) -> [Int] {
        if min <= 0 || max < min { return normal > 0 ? [normal] : [] }
        let step = Swift.max(step, 1)
        let usual = usualResolutions.filter { $0 >= min && $0 <= max && ($0 - min) % step == 0 }
        if !usual.isEmpty { return usual }
        var stepped: [Int] = []
        var r = min
        while r <= max && stepped.count < 8 {
            stepped.append(r)
            r += step
        }
        return stepped
    }
}

public struct ScanJobInfo: Equatable, Sendable {
    public var uri: String
    public var state: String
    public var ageSeconds: Int?
}

public struct ScannerStatus: Equatable, Sendable {
    public var state: String
    public var adfState: String?
    public var jobs: [ScanJobInfo]

    public var isIdle: Bool { state == "Idle" }
    public var adfLoaded: Bool { adfState == "ScannerAdfLoaded" }

    /// Why a scan can't start now, in plain words; nil when it can. "Processing" and "Testing" (warming up) are fine: the
    /// job request waits while the scanner answers 503. For feeder scans, a reported feeder state other than loaded stops
    /// the scan with its reason (an empty feeder answers with a page error on some scanners instead).
    public func problem(feeder: Bool) -> String? {
        if feeder, let adfState, !adfLoaded {
            switch adfState {
            case "ScannerAdfJam": return "The document feeder is jammed. Clear the paper and try again."
            case "ScannerAdfDoorOpen", "ScannerAdfHatchOpen": return "The document feeder's cover is open. Close it and try again."
            case "ScannerAdfMispick", "ScannerAdfMultipickDetected":
                return "The document feeder couldn't pick up a page. Straighten the stack and try again."
            case "ScannerAdfInputTrayOverloaded": return "Too many pages in the document feeder. Take some out and try again."
            case "ScannerAdfDuplexPageTooShort", "ScannerAdfDuplexPageTooLong":
                return "This page size can't be scanned on both sides. Scan one side, or use the glass."
            default: return "Load the pages into the document feeder first."
            }
        }
        return ["Idle", "Processing", "Testing"].contains(state) ? nil : "Scanner is \(state.lowercased())."
    }

    public static func parse(_ root: XmlElement) -> ScannerStatus {
        let jobs = (root.kid("Jobs")?.kids("JobInfo") ?? [])
            .map { ScanJobInfo(uri: $0.kidValue("JobUri") ?? "", state: $0.kidValue("JobState") ?? "", ageSeconds: $0.kidValue("Age").asInt) }
            .filter { !$0.uri.isEmpty }
        return ScannerStatus(state: root.kidValue("State") ?? "Unknown", adfState: root.kidValue("AdfState"), jobs: jobs)
    }
}

/// Maker-specific eSCL behaviour, as documented by sane-airscan (airscan-escl.c): Epson scanners want the port in the Host
/// header even when it's the default; Brother feeders answer 404 if the next page is asked for too soon after the last.
public struct EsclQuirks: Equatable, Sendable {
    public var portInHost: Bool
    public var nextLoadDelay: Bool

    public static let none = EsclQuirks(portInHost: false, nextLoadDelay: false)

    public static func of(_ caps: ScannerCapabilities) -> EsclQuirks {
        let model = (caps.makeAndModel ?? "").lowercased()
        return EsclQuirks(portInHost: model.hasPrefix("epson ") || caps.manufacturer?.caseInsensitiveCompare("EPSON") == .orderedSame,
                          nextLoadDelay: model.hasPrefix("brother "))
    }

    /// Wait before asking for the next feeder page: half the last page's load time, at most a second.
    public static func nextLoadWait(_ lastLoad: Duration) -> Duration { min(max(lastLoad / 2, .zero), .seconds(1)) }
}

public enum ScanColor: Sendable { case color, grayscale }

public struct ScanRequest: Equatable, Sendable {
    public var source: ScanSource = .platen
    public var color: ScanColor = .color
    public var resolution = 300
    public var intent = "Document"
    /// Region in 1/300 inch. Nil = the source's full area, clamped to device max.
    public var width: Int?
    public var height: Int?

    public init(source: ScanSource = .platen, color: ScanColor = .color, resolution: Int = 300, intent: String = "Document", width: Int? = nil,
                height: Int? = nil) {
        self.source = source
        self.color = color
        self.resolution = resolution
        self.intent = intent
        self.width = width
        self.height = height
    }
}

public enum EsclXml {
    public static let scan = "http://schemas.hp.com/imaging/escl/2011/05/03"
    public static let pwg = "http://www.pwg.org/schemas/2010/12/sm"

    /// Always requests JPEG pages; PDF assembly and OCR happen locally so every page can be previewed.
    public static func buildScanSettings(_ request: ScanRequest, _ caps: ScannerCapabilities) -> String? {
        guard let input = caps.input(for: request.source) else { return nil }
        let width = min(max(request.width ?? input.maxWidth, input.minWidth), input.maxWidth)
        let height = min(max(request.height ?? input.maxHeight, input.minHeight), input.maxHeight)
        let resolution = input.resolutions.min { abs($0 - request.resolution) < abs($1 - request.resolution) } ?? request.resolution
        var color = request.color == .color ? "RGB24" : "Grayscale8"
        // A missing mode falls back to the other of color/grey before black-and-white (which loses too much for OCR).
        if !input.colorModes.isEmpty && !input.colorModes.contains(color) {
            color = input.colorModes.first { $0 == "RGB24" || $0 == "Grayscale8" } ?? input.colorModes[0]
        }
        // "Document" isn't offered by every source (some feeders list only TextAndGraphic and Photo).
        let intent = input.intents.isEmpty || input.intents.contains(request.intent) ? request.intent
            : input.intents.first { $0 == "TextAndGraphic" } ?? input.intents[0]
        var xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"
        xml += "<scan:ScanSettings xmlns:scan=\"\(scan)\" xmlns:pwg=\"\(pwg)\">"
        xml += "<pwg:Version>\(escape(caps.version))</pwg:Version>"
        xml += "<scan:Intent>\(escape(intent))</scan:Intent>"
        xml += "<pwg:ScanRegions><pwg:ScanRegion><pwg:Height>\(height)</pwg:Height>"
        xml += "<pwg:ContentRegionUnits>escl:ThreeHundredthsOfInches</pwg:ContentRegionUnits>"
        xml += "<pwg:Width>\(width)</pwg:Width><pwg:XOffset>0</pwg:XOffset><pwg:YOffset>0</pwg:YOffset></pwg:ScanRegion></pwg:ScanRegions>"
        xml += "<pwg:InputSource>\(request.source == .platen ? "Platen" : "Feeder")</pwg:InputSource>"
        xml += "<scan:ColorMode>\(escape(color))</scan:ColorMode>"
        xml += "<scan:XResolution>\(resolution)</scan:XResolution><scan:YResolution>\(resolution)</scan:YResolution>"
        xml += "<pwg:DocumentFormat>image/jpeg</pwg:DocumentFormat>"
        if input.hasDocumentFormatExt { xml += "<scan:DocumentFormatExt>image/jpeg</scan:DocumentFormatExt>" }
        if request.source == .adfDuplex { xml += "<scan:Duplex>true</scan:Duplex>" }
        xml += "</scan:ScanSettings>"
        return xml
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// In extensions, so the structs keep their memberwise initializers (the parsers use them).
extension InputCaps {
    /// A source described from elsewhere (a scanner macOS drives through ImageCaptureCore); sizes in 1/300 inch.
    public init(minWidth: Int, maxWidth: Int, minHeight: Int, maxHeight: Int, colorModes: [String], resolutions: [Int]) {
        self.init(minWidth: minWidth, maxWidth: maxWidth, minHeight: minHeight, maxHeight: maxHeight, colorModes: colorModes,
                  documentFormats: ["image/jpeg"], resolutions: resolutions, intents: [])
    }
}

extension ScannerCapabilities {
    /// A scanner described from elsewhere (ImageCaptureCore's functional units).
    public init(makeAndModel: String?, platen: InputCaps?, adf: InputCaps?, adfDuplex: Bool) {
        self.init(version: "ImageCaptureCore", makeAndModel: makeAndModel, uuid: nil, platen: platen, adf: adf, adfDuplex: adfDuplex, manufacturer: nil)
    }
}
