import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// What a shared scanner calls itself on the network: its name, maker and the eSCL UUID kept for it on this Mac (the
/// Windows Core's `ShareIdentity`).
public struct ShareIdentity: Equatable, Sendable {
    public var name: String
    public var manufacturer: String?
    public var uuid: UUID

    public init(_ name: String, _ manufacturer: String?, _ uuid: UUID) {
        self.name = name
        self.manufacturer = manufacturer
        self.uuid = uuid
    }

    /// The UUID as eSCL and DNS-SD write it: lower case, with dashes (.NET's "D").
    public var uuidText: String { uuid.uuidString.lowercased() }
}

/// The scan an eSCL client asked for (its ScanSettings), as this Mac's scanner will run it. `format`: what each page is sent
/// as, `image/jpeg` or `application/pdf` (one page per document).
public struct ShareScanSettings: Equatable, Sendable {
    public var request: ScanRequest
    public var format: String
}

/// A client's ScanSettings this Mac won't run: `status` is the HTTP answer (400 malformed, 409 not offered).
public struct ShareRequestError: Error, Equatable, CustomStringConvertible {
    public let status: Int
    public let description: String

    init(_ status: Int, _ reason: String) {
        self.status = status
        description = reason
    }
}

/// The eSCL documents a shared scanner serves (Mopria eSCL 2.6x, as `ScannerCapabilities.parse` and sane-airscan read
/// them) and the one it reads: a client's ScanSettings, which comes from any device on the network and is read as hostile
/// (the Windows Core's `ShareXml`).
public enum ShareXml {
    public static let version = "2.63"
    public static let jpeg = "image/jpeg"
    public static let pdf = ScannerPdf.mediaType

    /// Every page goes out as JPEG, or a PDF of it.
    public static let formats = [jpeg, pdf]

    /// The intents listed; ImageCaptureCore has no such setting, so each scans the same.
    public static let intents = ["Document", "TextAndGraphic", "Photo", "Preview"]

    /// The longest ScanSettings read (a real one is under 2 KB).
    public static let maxSettingsBytes = 16 * 1024

    /// The most elements a ScanSettings may hold, and how deep (a real one has about 20, four deep).
    public static let maxElements = 200, maxDepth = 8

    /// The longest text an element may hold.
    public static let maxText = 128

    /// The most pixels a page may have across or down (JPEG's own limit), whatever the scanner offers.
    public static let maxPixels = 65_000

    private static let scan = EsclXml.scan, pwg = EsclXml.pwg

    /// ScannerCapabilities for `caps` (the scanner's own: sources, sizes, color modes, resolutions).
    public static func capabilities(_ caps: ScannerCapabilities, _ id: ShareIdentity) -> [UInt8] {
        var x = "<scan:ScannerCapabilities xmlns:scan=\"\(scan)\" xmlns:pwg=\"\(pwg)\">"
        x += element("pwg:Version", version) + element("pwg:MakeAndModel", id.name) + element("scan:UUID", id.uuidText)
        if let maker = id.manufacturer, !maker.isEmpty { x += element("scan:Manufacturer", maker) }
        if let platen = caps.platen { x += "<scan:Platen>" + input("PlatenInputCaps", platen) + "</scan:Platen>" }
        if let adf = caps.adf {
            x += "<scan:Adf>" + input("AdfSimplexInputCaps", adf)
            if caps.adfDuplex { x += input("AdfDuplexInputCaps", adf) }
            x += "</scan:Adf>"
        }
        return bytes(x + "</scan:ScannerCapabilities>")
    }

    private static func input(_ name: String, _ input: InputCaps) -> String {
        let offered = resolutions(input)
        let most = offered.max() ?? 300
        var x = "<scan:\(name)>"
        x += element("scan:MinWidth", "\(input.minWidth)") + element("scan:MaxWidth", "\(input.maxWidth)")
        x += element("scan:MinHeight", "\(input.minHeight)") + element("scan:MaxHeight", "\(input.maxHeight)")
        x += element("scan:MaxScanRegions", "1")
        x += "<scan:SettingProfiles><scan:SettingProfile>"
        x += "<scan:ColorModes>" + input.colorModes.map { element("scan:ColorMode", $0) }.joined() + "</scan:ColorModes>"
        x += "<scan:DocumentFormats>" + formats.map { element("pwg:DocumentFormat", $0) }.joined()
            + formats.map { element("scan:DocumentFormatExt", $0) }.joined() + "</scan:DocumentFormats>"
        let discrete = offered.map { r in "<scan:DiscreteResolution>" + element("scan:XResolution", "\(r)") + element("scan:YResolution", "\(r)")
            + "</scan:DiscreteResolution>" }
        x += "<scan:SupportedResolutions><scan:DiscreteResolutions>" + discrete.joined() + "</scan:DiscreteResolutions></scan:SupportedResolutions>"
        x += "<scan:ColorSpaces><scan:ColorSpace>sRGB</scan:ColorSpace></scan:ColorSpaces>"
        x += "</scan:SettingProfile></scan:SettingProfiles>"
        x += "<scan:SupportedIntents>" + intents.map { element("scan:Intent", $0) }.joined() + "</scan:SupportedIntents>"
        x += element("scan:MaxOpticalXResolution", "\(most)") + element("scan:MaxOpticalYResolution", "\(most)")
        for side in ["Left", "Right", "Top", "Bottom"] { x += element("scan:Risky\(side)Margin", "0") }
        return x + "</scan:\(name)>"
    }

    /// One job as ScannerStatus lists it. `path`: the job's address on this server (`/eSCL/ScanJobs/…`); `state`: eSCL's
    /// job state, Pending, Processing, Completed, Canceled or Aborted.
    public struct JobLine: Equatable, Sendable {
        public var path: String
        public var uuid: UUID
        public var state: String
        public var ageSeconds: Int
        public var imagesCompleted: Int
        public var reason: String?
    }

    /// ScannerStatus: `state` (Idle or Processing), the feeder's state when known, and the asker's jobs.
    public static func status(_ state: String, adfState: String?, _ jobs: [JobLine]) -> [UInt8] {
        var x = "<scan:ScannerStatus xmlns:scan=\"\(scan)\" xmlns:pwg=\"\(pwg)\">"
        x += element("pwg:Version", version) + element("pwg:State", state)
        if let adfState { x += element("scan:AdfState", adfState) }
        if !jobs.isEmpty {
            x += "<scan:Jobs>"
            for j in jobs {
                x += "<scan:JobInfo>" + element("pwg:JobUri", j.path) + element("pwg:JobUuid", j.uuid.uuidString.lowercased())
                x += element("scan:Age", "\(j.ageSeconds)") + element("pwg:ImagesCompleted", "\(j.imagesCompleted)")
                x += element("pwg:ImagesToTransfer", j.state == "Pending" || j.state == "Processing" ? "1" : "0")
                x += element("pwg:JobState", j.state)
                if let reason = j.reason { x += "<pwg:JobStateReasons>" + element("pwg:JobStateReason", reason) + "</pwg:JobStateReasons>" }
                x += "</scan:JobInfo>"
            }
            x += "</scan:Jobs>"
        }
        return bytes(x + "</scan:ScannerStatus>")
    }

    /// ScanImageInfo for the last page sent: its size in pixels.
    public static func imageInfo(_ path: String, _ uuid: UUID, width: Int, height: Int, components: Int) -> [UInt8] {
        var x = "<scan:ScanImageInfo xmlns:scan=\"\(scan)\" xmlns:pwg=\"\(pwg)\">"
        x += element("pwg:JobUri", path) + element("pwg:JobUuid", uuid.uuidString.lowercased())
        x += element("scan:ActualWidth", "\(width)") + element("scan:ActualHeight", "\(height)")
        x += element("scan:ActualBytesPerLine", "\(Int64(width) * Int64(max(components, 1)))")
        return bytes(x + "</scan:ScanImageInfo>")
    }

    private static func element(_ name: String, _ text: String) -> String { "<\(name)>\(EsclXml.escape(text))</\(name)>" }

    private static func bytes(_ root: String) -> [UInt8] { Array(("<?xml version=\"1.0\" encoding=\"UTF-8\"?>" + root).utf8) }

    /// A client's ScanSettings as a scan this scanner can run, or `ShareRequestError`: 400 for a body that isn't one (too
    /// long, a DTD, too many or too deeply nested elements, a number that isn't one or out of range, a region in other
    /// units), 409 for one asking what the scanner doesn't offer (a source, a color mode, a format, a resolution). Unknown
    /// elements are left alone, as eSCL asks; the region is kept inside the source and the page's pixels bounded.
    /// **Mac difference:** black and white (`BlackAndWhite1`) is never offered (the Mac scans color or grey), so it is 409.
    public static func readSettings(_ body: [UInt8], _ caps: ScannerCapabilities) throws -> ShareScanSettings {
        guard !body.isEmpty, body.count <= maxSettingsBytes else { throw ShareRequestError(400, "ScanSettings missing or too long.") }
        // No DTD at all: nothing declared, nothing expanded, nothing fetched (`XmlReaderSettings.DtdProcessing.Prohibit`). The
        // bytes are read as UTF-8 only (a UTF-16 or otherwise declared body would hide a DTD from this check), and the reader
        // stops at any declaration that still gets through.
        guard isPlainUtf8Xml(body), body.firstRange(of: Array("<!DOCTYPE".utf8)) == nil, body.firstRange(of: Array("<!ENTITY".utf8)) == nil else {
            throw ShareRequestError(400, "ScanSettings isn't well-formed XML.")
        }
        let reader = SettingsReader()
        let parser = XMLParser(data: Data(body))
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        let parsed = parser.parse()
        if let refused = reader.refused { throw refused }
        guard parsed else { throw ShareRequestError(400, "ScanSettings isn't well-formed XML.") }
        guard reader.rootName == "ScanSettings", reader.rootNamespace == scan else { throw ShareRequestError(400, "Not an eSCL ScanSettings.") }
        return try settings(reader.values, caps)
    }

    /// A body read as UTF-8 and nothing else: "<" first (after a UTF-8 BOM), no NUL (UTF-16 without a BOM), and an XML
    /// declaration, if any, naming UTF-8 or US-ASCII only.
    static func isPlainUtf8Xml(_ body: [UInt8]) -> Bool {
        let text = body.starts(with: [0xEF, 0xBB, 0xBF]) ? body.dropFirst(3) : body[...]
        guard text.first == UInt8(ascii: "<"), !text.contains(0) else { return false }
        guard text.starts(with: Array("<?xml".utf8)) else { return true }
        let head = text.prefix(200)
        guard let end = head.firstRange(of: Array("?>".utf8)) else { return false }
        let declaration = String(decoding: head[..<end.lowerBound], as: UTF8.self).lowercased()
        guard let at = declaration.range(of: "encoding") else { return true }
        let named = declaration[at.upperBound...].drop { $0 == " " || $0 == "=" || $0 == "\"" || $0 == "'" }
            .prefix { $0 != "\"" && $0 != "'" && $0 != " " }
        return named == "utf-8" || named == "utf8" || named == "us-ascii"
    }

    private static func settings(_ values: [String: String], _ caps: ScannerCapabilities) throws -> ShareScanSettings {
        let duplex = ["true", "True", "1"].contains(values["Duplex"] ?? "")
        let source: ScanSource
        switch values["InputSource"] ?? "" {
        case "":
            // No source named: the glass, or the feeder of a scanner that has only one.
            source = caps.platen == nil && caps.adf != nil ? (duplex && caps.adfDuplex ? .adfDuplex : .adf) : .platen
        case "Platen": source = .platen
        case "Feeder": source = duplex ? .adfDuplex : .adf
        default: throw ShareRequestError(409, "Source not offered.")
        }
        guard caps.sources.contains(source), let input = caps.input(for: source) else { throw ShareRequestError(409, "Source not offered.") }

        let color: ScanColor
        switch values["ColorMode"] ?? "" {
        case "": color = input.colorModes.contains("RGB24") || input.colorModes.isEmpty ? .color : .grayscale
        case "RGB24", "RGB48": color = .color
        case "Grayscale8", "Grayscale16": color = .grayscale
        default: throw ShareRequestError(409, "Color mode not offered.")
        }
        let mode = color == .color ? "RGB24" : "Grayscale8"
        if !input.colorModes.isEmpty && !input.colorModes.contains(mode) { throw ShareRequestError(409, "Color mode not offered.") }

        var format = values["DocumentFormatExt"].flatMap { $0.isEmpty ? nil : $0 } ?? values["DocumentFormat"] ?? jpeg
        format = String(format.split(separator: ";", omittingEmptySubsequences: false).first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if format.isEmpty { format = jpeg }
        guard formats.contains(format) else { throw ShareRequestError(409, "Format not offered.") }

        // Only a resolution the capabilities list (both directions the same): a scanner whose driver gives none lists 300 dpi.
        let offered = resolutions(input)
        let xRes = try number(values, "XResolution", 1, 19_200)
        let yRes = try number(values, "YResolution", 1, 19_200)
        if let rx = xRes, let ry = yRes, rx != ry { throw ShareRequestError(409, "Resolution not offered.") }
        let resolution = xRes ?? yRes ?? (offered.contains(300) ? 300 : offered[0])
        guard offered.contains(resolution) else { throw ShareRequestError(409, "Resolution not offered.") }

        let units = values["ContentRegionUnits"] ?? ""
        guard ["", "escl:ThreeHundredthsOfInches", "ThreeHundredthsOfInches"].contains(units) else {
            throw ShareRequestError(400, "Region units not ThreeHundredthsOfInches.")
        }
        let maxRegion = 300 * 1000 // 1,000 inches: what a number may be at all
        var width = try number(values, "Width", 1, maxRegion)
        var height = try number(values, "Height", 1, maxRegion)
        var x = try number(values, "XOffset", 0, maxRegion)
        var y = try number(values, "YOffset", 0, maxRegion)
        // Kept inside the source before anything is planned (a client's rounding may overshoot by a little), and the page's
        // pixels bounded.
        x = x.map { min($0, max(input.maxWidth - 1, 0)) }
        y = y.map { min($0, max(input.maxHeight - 1, 0)) }
        width = width.map { min($0, max(input.maxWidth - (x ?? 0), 1)) }
        height = height.map { min($0, max(input.maxHeight - (y ?? 0), 1)) }
        if pixels(width ?? input.maxWidth, resolution) > maxPixels || pixels(height ?? input.maxHeight, resolution) > maxPixels {
            throw ShareRequestError(409, "Region too large at that resolution.")
        }
        let asked = values["Intent"] ?? ""
        let intent = (1...32).contains(asked.count) && asked.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) } ? asked : "Document"
        let request = ScanRequest(source: source, color: color, resolution: resolution, intent: intent, width: width, height: height,
                                  xOffset: x == 0 ? nil : x, yOffset: y == 0 ? nil : y)
        return ShareScanSettings(request: request, format: format)
    }

    /// The resolutions ScannerCapabilities lists for a source (300 dpi when the driver gives none).
    public static func resolutions(_ input: InputCaps) -> [Int] { input.resolutions.isEmpty ? [300] : input.resolutions }

    private static func pixels(_ threeHundredths: Int, _ dpi: Int) -> Int64 { Int64(threeHundredths) * Int64(dpi) / 300 }

    /// A whole number of digits only (no sign, no exponent) in `min...max`; nil when the element isn't there or is empty.
    private static func number(_ values: [String: String], _ name: String, _ min: Int, _ max: Int) throws -> Int? {
        guard let text = values[name], !text.isEmpty else { return nil }
        guard text.count <= 10, text.allSatisfy(\.isASCIIDigit), let n = Int(text), n >= min, n <= max else {
            throw ShareRequestError(400, "\(name) out of range.")
        }
        return n
    }

    /// Reads a ScanSettings' elements: the root's name and namespace, and each element's text by its local name (the
    /// first one of each name wins: one region is all this scanner takes), refusing too many, too deep or too long.
    /// Reads ScanSettings' values; refuses (and stops) a body too large, too deep or declaring anything.
    final class SettingsReader: NSObject, XMLParserDelegate {
        var values: [String: String] = [:]
        var rootName: String?
        var rootNamespace: String?
        var refused: ShareRequestError?
        private var elements = 0
        private var open: [(name: String, text: String)] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            elements += 1
            if elements > ShareXml.maxElements || open.count >= ShareXml.maxDepth { return refuse(parser, ShareRequestError(400, "ScanSettings too large.")) }
            if rootName == nil {
                rootName = elementName
                rootNamespace = namespaceURI ?? ""
            }
            open.append((elementName, ""))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { add(parser, string) }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { add(parser, String(decoding: CDATABlock, as: UTF8.self)) }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName: String?) {
            guard let last = open.popLast() else { return }
            let text = last.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if text.count > ShareXml.maxText { return refuse(parser, ShareRequestError(400, "ScanSettings value too long.")) }
            if !text.isEmpty && values[last.name] == nil { values[last.name] = text }
        }

        func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { nil }

        // Any declaration that still reaches the parser (the byte checks are the first line): stopped there.
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { declared(parser) }

        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
            declared(parser)
        }

        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?,
                    notationName: String?) { declared(parser) }

        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) { declared(parser) }

        func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String,
                    type: String?, defaultValue: String?) { declared(parser) }

        func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) {
            declared(parser)
        }

        private func declared(_ parser: XMLParser) { refuse(parser, ShareRequestError(400, "ScanSettings isn't well-formed XML.")) }

        private func add(_ parser: XMLParser, _ text: String) {
            guard !open.isEmpty else { return }
            open[open.count - 1].text += text
            // Long before the end tag: a value can't be longer than this, whitespace included, in a body this size.
            if open[open.count - 1].text.utf8.count > ShareXml.maxSettingsBytes {
                refuse(parser, ShareRequestError(400, "ScanSettings value too long."))
            }
        }

        private func refuse(_ parser: XMLParser, _ error: ShareRequestError) {
            if refused == nil { refused = error }
            parser.abortParsing()
        }
    }
}
