import Testing
@testable import PrintCore

/// IPP: the codec, the text fixtures, and status and supplies from Get-Printer-Attributes. Ported from IppAndPdfTests.cs
/// (IppTests), the IPP parts of OtherBrandsTests.cs, RobustnessTests.cs and MaintenanceTests.cs (Identify-Printer).
struct IppTests {
    private static func inkjetIpp() throws -> IppResponse {
        try ipp(Fixtures.text("inkjet-demo/ipp_print.ipp.txt"))
    }

    private static func ipp(_ text: String) throws -> IppResponse {
        try IppCodec.decode(IppCodec.encodeResponse(status: 0, requestId: 1, IppText.parse(text)))
    }

    /// An IPP message built by hand: groups and attributes in the RFC 8010 wire format.
    private struct Builder {
        private var b: [UInt8] = [1, 1, 0, 0, 0, 0, 0, 1]

        func group(_ tag: UInt8) -> Builder { var c = self; c.b.append(tag); return c }
        func str(_ tag: UInt8, _ name: String, _ value: String) -> Builder { attribute(tag, name, Array(value.utf8)) }
        func int(_ tag: UInt8, _ name: String, _ value: Int32) -> Builder {
            let u = UInt32(bitPattern: value)
            return attribute(tag, name, [UInt8(u >> 24), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)])
        }
        func end() -> [UInt8] { b + [3] }

        private func attribute(_ tag: UInt8, _ name: String, _ value: [UInt8]) -> Builder {
            var c = self
            let n = Array(name.utf8)
            c.b += [tag, UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n + [UInt8(value.count >> 8), UInt8(value.count & 0xFF)] + value
            return c
        }
    }

    private static func attribute(_ tag: UInt8, _ name: String, _ value: String) -> [UInt8] {
        let n = Array(name.utf8), v = Array(value.utf8)
        return [tag, UInt8(n.count >> 8), UInt8(n.count & 0xFF)] + n + [UInt8(v.count >> 8), UInt8(v.count & 0xFF)] + v
    }

    private static func count(of sub: String, in s: String) -> Int { s.components(separatedBy: sub).count - 1 }

    // MARK: Codec

    @Test func encodesGetPrinterAttributes() {
        let request = IppCodec.encodeGetPrinterAttributes("ipp://h:631/ipp/print", ["printer-state", "marker-levels"])
        #expect(Array(request.prefix(9)) == [1, 1, 0, 0x0B, 0, 0, 0, 1, 0x01])
        #expect(request.last == 0x03)
        let text = String(decoding: request, as: UTF8.self)
        #expect(Self.count(of: "requested-attributes", in: text) == 1) // additional values use empty names
        #expect(text.contains("marker-levels"))
    }

    @Test func decodesMultiValuedPrinterAttributesToStatusAndSupplies() throws {
        let response = Builder()
            .group(0x01).str(0x47, "attributes-charset", "utf-8")
            .group(0x04)
            .int(0x23, "printer-state", 3)
            .str(0x44, "printer-state-reasons", "toner-low-warning").str(0x44, "", "media-empty-error")
            .str(0x41, "marker-names", "Black Cartridge")
            .int(0x21, "marker-levels", 8)
            .int(0x21, "marker-low-levels", 10)
            .str(0x44, "marker-types", "toner")
            .end()

        let r = try IppCodec.decode(response)
        let status = IppClient.toStatus(r)
        let supplies = IppClient.toConsumables(r)

        #expect(r.ok)
        #expect(status.code == "ready")
        #expect(status.severity == .error)
        #expect(status.alerts.map(\.id) == ["toner-low", "media-empty"])
        try #require(supplies.count == 1)
        #expect(supplies[0].name == "Black Cartridge" && supplies[0].percentRemaining == 8 && supplies[0].state == "low")
        #expect(r.attributes["attributes-charset"] == nil) // operation group ignored
    }

    @Test func firmwareVersionFromIppPrefersTheMainFirmwareEntry() throws {
        let response = Builder()
            .group(0x04)
            .str(0x42, "printer-firmware-name", "boot").str(0x42, "", "system-firmware")
            .str(0x41, "printer-firmware-string-version", "1.0.2").str(0x41, "", "2.6.1")
            .end()
        let firmware = try #require(FirmwareInfo.from(nil, try IppCodec.decode(response)))
        #expect(firmware.display == "2.6.1")
        #expect(IppClient.statusAttributes.contains("printer-firmware-string-version"))
    }

    @Test func ippTruncatedReplyIsAFormatError() {
        // Header + printer group + an attribute whose declared value length runs past the end.
        let reply: [UInt8] = [1, 1, 0, 0, 0, 0, 0, 1, 0x04, 0x44, 0, 4, 0x6E, 0x61, 0x6D, 0x65, 0, 50, 0x78]
        #expect(throws: IppFormatError.self) { try IppCodec.decode(reply) }
    }

    @Test func ippReasonWithoutSuffixIsAnError() {
        let r = IppResponse(statusCode: 0, attributes: ["printer-state": [.integer(3)], "printer-state-reasons": [.text("media-jam")]])
        #expect(IppClient.toStatus(r).alerts.map(\.severity) == [.error])
    }

    @Test func identifyPrinterRequestIsEncodedByteForByte() throws {
        var expected: [UInt8] = [2, 0, 0x00, 0x3C, 0, 0, 0, 3, 0x01]
        expected += Self.attribute(0x47, "attributes-charset", "utf-8")
        expected += Self.attribute(0x48, "attributes-natural-language", "en")
        expected += Self.attribute(0x45, "printer-uri", "ipp://192.0.2.11:631/ipp/print")
        expected += Self.attribute(0x42, "requesting-user-name", "alex")
        expected += Self.attribute(0x44, "identify-actions", "flash")
        expected += Self.attribute(0x44, "", "sound")
        expected.append(0x03)

        let body = IppCodec.encodeIdentifyPrinter("ipp://192.0.2.11:631/ipp/print", userName: "alex", actions: ["flash", "sound"], requestId: 3)
        #expect(body == expected)
        let header = try IppCodec.readRequestHeader(body)
        #expect(header.operation == IppCodec.identifyPrinter && header.requestId == 3)
    }

    @Test func identifyPrinterWithoutActionsOrUserLeavesThemOut() {
        var expected: [UInt8] = [2, 0, 0x00, 0x3C, 0, 0, 0, 1, 0x01]
        expected += Self.attribute(0x47, "attributes-charset", "utf-8")
        expected += Self.attribute(0x48, "attributes-natural-language", "en")
        expected += Self.attribute(0x45, "printer-uri", "ipp://192.0.2.11:631/ipp/print")
        expected.append(0x03)
        #expect(IppCodec.encodeIdentifyPrinter("ipp://192.0.2.11:631/ipp/print", userName: nil, actions: []) == expected)
    }

    // MARK: IPP fixtures (text form)

    @Test func ippTextRoundTripsThroughTheCodec() throws {
        let r = try Self.ipp("""
            # comment
            printer-state enum 4
            printer-is-accepting-jobs boolean true
            printer-state-reasons keyword media-low-report
            printer-state-reasons keyword toner-low-warning
            printer-make-and-model text Brother Example 0000
            """)
        #expect(r.ok)
        #expect(r.int("printer-state") == 4)
        #expect(r.attributes["printer-is-accepting-jobs"] == [.boolean(true)])
        #expect(r.strs("printer-state-reasons") == ["media-low-report", "toner-low-warning"])
        #expect(r.str("printer-make-and-model") == "Brother Example 0000")
    }

    @Test(arguments: ["printer-state enum three", "printer-state", "printer-state colour 3"])
    func ippTextRejectsMalformedLines(_ line: String) {
        #expect(throws: IppFormatError.self) { try IppText.parse(line) }
    }

    @Test func ippRequestHeaderIsReadForTheFixtureServer() throws {
        let request = IppCodec.encodeGetPrinterAttributes("ipp://192.0.2.11:631/ipp/print", ["printer-state"], requestId: 7)
        let header = try IppCodec.readRequestHeader(request)
        #expect(header.operation == IppCodec.getPrinterAttributes && header.requestId == 7)
        #expect(throws: IppFormatError.self) { try IppCodec.readRequestHeader([1, 1]) }
    }

    @Test func octetStringPrinterAlertDecodesAsText() throws {
        #expect(try Self.inkjetIpp().strs("printer-alert").first?.hasPrefix("code=markerInkAlmostEmpty;") == true)
    }

    // MARK: Status

    @Test(arguments: [
        ("Idle.", "Ready", "Ready"), // ippeveprinter, CUPS
        ("idle", "Ready", "Ready"),
        (" Ready to print. ", "Ready", "Ready"),
        ("Printing.", "Printing", "Printing"),
        ("", "Ready", "Ready"),
        (nil, "Stopped", "Stopped"),
        ("Warming up.", "Printing", "Warming up"),
        ("Sleep mode. Press any key.", "Ready", "Sleep mode. Press any key."), // several sentences stay as written
    ] as [(String?, String, String)])
    func statusHeadlineFromTheStateMessage(_ message: String?, _ label: String, _ expected: String) {
        #expect(IppClient.headline(message, label) == expected)
    }

    @Test func inkjetStatusHumanizesReasonsAndUsesTheAlertDescription() throws {
        let s = IppClient.toStatus(try Self.inkjetIpp())
        #expect(s.code == "ready" && s.message == "Ready")
        // The low-ink reason and its printer-alert are one problem; a settings change isn't one.
        try #require(s.alerts.count == 1)
        #expect(s.alerts[0].id == "marker-supply-low" && s.alerts[0].severity == .warning && s.alerts[0].message == "Yellow ink is low.")
        #expect(s.severity == .warning)
    }

    @Test(arguments: [
        ("media-empty-error", "media-empty", Severity.error, "Out of paper"),
        ("media-jam-error", "media-jam", .error, "Paper jam"),
        ("toner-low", "toner-low", .warning, "Toner low"), // no suffix: RFC says error, but "low" is a warning
        ("cover-open", "cover-open", .error, "A cover is open"), // no suffix: error
        ("opc-near-eol-warning", "opc-near-eol", .warning, "Drum nearly worn out"),
        ("marker-waste-almost-full-warning", "marker-waste-almost-full", .warning, "Waste ink or toner box almost full"),
        ("com.example-vendor-thing-report", "com.example-vendor-thing", .info, "Com.example vendor thing"),
    ] as [(String, String, Severity, String)])
    func ippReasons(_ reason: String, _ id: String, _ severity: Severity, _ text: String) throws {
        let s = IppClient.toStatus(try Self.ipp("printer-state enum 3\nprinter-state-reasons keyword \(reason)"))
        try #require(s.alerts.count == 1)
        #expect(s.alerts[0].id == id && s.alerts[0].severity == severity && s.alerts[0].message == text)
    }

    @Test func severalAlertsForOneReasonKeepEveryDescription() throws {
        let s = IppClient.toStatus(try Self.ipp("""
            printer-state enum 3
            printer-state-reasons keyword marker-supply-low-warning
            printer-alert octetString code=markerInkAlmostEmpty;index=1;severity=warning
            printer-alert octetString code=markerInkAlmostEmpty;index=2;severity=warning
            printer-alert octetString code=markerInkAlmostEmpty;index=3;severity=critical
            printer-alert-description text Yellow ink is low.
            printer-alert-description text Cyan ink is low
            printer-alert-description text yellow ink is low.
            """))
        try #require(s.alerts.count == 1)
        #expect(s.alerts[0].message == "Yellow ink is low. Cyan ink is low.") // de-duplicated, in order
        #expect(s.alerts[0].severity == .error) // the critical alert raises the reason
    }

    @Test func placeholderReasonsAreNotProblems() throws {
        let s = IppClient.toStatus(try Self.ipp("printer-state enum 3\nprinter-state-reasons keyword none\nprinter-state-reasons keyword other-report"))
        #expect(s.alerts.isEmpty)
        #expect(s.severity == .info)
    }

    @Test func printerAlertWithoutAMatchingReasonIsShown() throws {
        let s = IppClient.toStatus(try Self.ipp("""
            printer-state enum 5
            printer-state-reasons keyword none
            printer-alert octetString code=jam;index=1;severity=critical;group=mediaPath
            printer-alert octetString code=subunitLifeAlmostOver;severity=warning
            printer-alert octetString code=other;severity=other
            """))
        #expect(s.code == "stopped")
        #expect(s.alerts.map(\.id) == ["media-jam", "subunitLifeAlmostOver"])
        #expect(s.alerts.map(\.message) == ["Paper jam", "Subunit life almost over"])
        #expect(s.alerts.map(\.severity) == [.error, .warning])
    }

    @Test(arguments: [
        ("code=coverOpen;severity=critical", "coverOpen", "critical"),
        ("severity=warning;code=markerTonerAlmostEmpty;index=2", "markerTonerAlmostEmpty", "warning"),
        ("index=2", nil, nil),
        ("", nil, nil),
    ] as [(String, String?, String?)])
    func printerAlertValuesParse(_ value: String, _ code: String?, _ severity: String?) {
        let a = IppAlert.parse(value)
        #expect(a?.code == code && a?.severity == severity)
    }

    // MARK: Supplies

    @Test func inkjetSuppliesHaveColorsKindsAndAMaintenanceBox() throws {
        let supplies = IppClient.toConsumables(try Self.inkjetIpp())
        #expect(supplies.map(\.name) == ["Black ink", "Cyan ink", "Magenta ink", "Yellow ink", "Maintenance box"])
        #expect(supplies.map(\.colorCode) == ["K", "C", "M", "Y", nil])
        #expect(supplies.map(\.kind) == ["ink", "ink", "ink", "ink", "waste-ink"])
        #expect(supplies.prefix(4).map(\.percentRemaining) == [72, 55, 63, 12])
        #expect(supplies[3].state == "low")
        #expect(supplies[3].isLow)
        // A waste box's level runs the other way on some printers (how full vs. room left), so no percentage is shown.
        let box = supplies[4]
        #expect(box.percentRemaining == nil && box.state == "ok" && box.isWaste)
    }

    @Test func wasteBoxStateComesFromThePrinterStateReasons() throws {
        func box(_ reason: String) throws -> String {
            try IppClient.toConsumables(Self.ipp("""
                printer-state-reasons keyword \(reason)
                marker-names name Waste toner
                marker-types keyword waste-toner
                marker-levels integer 40
                """))[0].state
        }
        #expect(try box("marker-waste-almost-full-warning") == "almostFull")
        #expect(try box("marker-waste-full-error") == "full")
        #expect(try box("none") == "ok")
    }

    @Test(arguments: [
        ("#000000", "K"), ("#00ffff", "C"), ("#FF00FF", "M"), ("#FFFF00", "Y"), ("#808080", "#808080"),
        ("#00FFFF#FF00FF#FFFF00", "#00FFFF"), // a tri-color cartridge: its first color
        ("none", nil), ("#12", nil), ("red", nil),
    ] as [(String, String?)])
    func markerColors(_ ipp: String, _ code: String?) {
        #expect(IppClient.colorCode(ipp) == code)
    }

    @Test func specialLevelsMeanUnknownOrSomeLeft() throws {
        let s = IppClient.toConsumables(try Self.ipp("""
            marker-names name Unknown
            marker-names name Some left
            marker-names name Empty
            marker-levels integer -2
            marker-levels integer -3
            marker-levels integer 0
            marker-types keyword toner
            """))
        #expect(s.map(\.state) == ["unknown", "ok", "out"])
        #expect(s.map(\.percentRemaining) == [nil, nil, 0])
        #expect(s.map(\.kind) == ["toner", "supply", "supply"]) // marker-types shorter than marker-names
    }
}
