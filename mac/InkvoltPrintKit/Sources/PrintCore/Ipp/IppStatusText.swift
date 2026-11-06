/// Plain words for IPP `printer-state-reasons` keywords (RFC 8011 §5.4.12, PWG 5100.9 §5.1) and the `printer-alert`
/// codes (PWG 5100.9 §5.2, IANA PrtAlertCodeTC) that mean the same thing. Unknown keywords are de-hyphenated.
public enum IppStatusText {
    private static let known: [String: LocKey] = [
        "media-empty": LocKey("Out of paper"),
        "media-needed": LocKey("Load paper"),
        "media-low": LocKey("Paper low"),
        "media-jam": LocKey("Paper jam"),
        "media-path-jam": LocKey("Paper jam"),
        "input-tray-missing": LocKey("Paper tray missing"),
        "output-tray-missing": LocKey("Output tray missing"),
        "output-area-almost-full": LocKey("Output tray almost full"),
        "output-area-full": LocKey("Output tray full"),
        "cover-open": LocKey("A cover is open"),
        "door-open": LocKey("A door is open"),
        "interlock-open": LocKey("A cover is open"),
        "toner-low": LocKey("Toner low"),
        "toner-empty": LocKey("Toner empty"),
        "marker-supply-low": LocKey("Ink or toner low"),
        "marker-supply-empty": LocKey("Ink or toner empty"),
        "marker-supply-missing": LocKey("Cartridge missing"),
        "marker-waste-almost-full": LocKey("Waste ink or toner box almost full"),
        "marker-waste-full": LocKey("Waste ink or toner box full"),
        "marker-waste-ink-receptacle-almost-full": LocKey("Maintenance box almost full"),
        "marker-waste-ink-receptacle-full": LocKey("Maintenance box full"),
        "marker-waste-toner-receptacle-almost-full": LocKey("Waste toner box almost full"),
        "marker-waste-toner-receptacle-full": LocKey("Waste toner box full"),
        "developer-low": LocKey("Developer low"),
        "developer-empty": LocKey("Developer empty"),
        "opc-near-eol": LocKey("Drum nearly worn out"),
        "opc-life-over": LocKey("Replace the drum"),
        "fuser-over-temp": LocKey("Fuser too hot"),
        "fuser-under-temp": LocKey("Fuser warming up"),
        "paused": LocKey("Paused"),
        "moving-to-paused": LocKey("Pausing"),
        "shutdown": LocKey("Shutting down"),
        "stopping": LocKey("Stopping"),
        "stopped-partly": LocKey("Partly stopped"),
        "spool-area-full": LocKey("Printer memory full"),
        "interpreter-resource-unavailable": LocKey("Printer resource unavailable"),
        "timed-out": LocKey("Timed out"),
        "connecting-to-device": LocKey("Connecting"),
        "identify-printer-requested": LocKey("Identifying itself"),
        "offline": LocKey("Offline"),
        "deactivated": LocKey("Turned off by an administrator"),
    ]

    private static let details: [String: LocKey] = [
        "media-empty": LocKey("Load paper into the tray."),
        "media-needed": LocKey("Load the paper the printer asks for, then press OK on the printer if it asks."),
        "media-jam": LocKey("Open the covers the printer's screen points to and gently pull out the jammed paper."),
        "cover-open": LocKey("Close it to continue."),
        "door-open": LocKey("Close it to continue."),
        "toner-empty": LocKey("Replace the toner cartridge to keep printing."),
        "marker-supply-empty": LocKey("Replace or refill the empty cartridge or ink tank to keep printing."),
        "marker-waste-full": LocKey("Replace the waste ink or toner box (on inkjets: the maintenance box) to keep printing."),
        "marker-waste-ink-receptacle-full": LocKey("Replace the maintenance box to keep printing."),
        "opc-life-over": LocKey("The drum unit has reached the end of its life. Replace it to keep printing well."),
    ]

    /// Reasons that are warnings by nature: a reason sent without a severity suffix is an error per RFC 8011, except these.
    private static let warnings: Set<String> = [
        "media-low", "toner-low", "marker-supply-low", "developer-low", "opc-near-eol", "output-area-almost-full",
        "marker-waste-almost-full", "marker-waste-ink-receptacle-almost-full", "marker-waste-toner-receptacle-almost-full",
        "fuser-under-temp", "connecting-to-device", "identify-printer-requested", "moving-to-paused",
    ]

    /// printer-alert codes (IANA PrtAlertCodeTC labels) → the printer-state-reasons keyword PWG 5100.9 maps them to.
    private static let alertReasons: [String: String] = [
        "coverOpen": "cover-open",
        "doorOpen": "door-open",
        "interlockOpen": "interlock-open",
        "jam": "media-jam",
        "inputMediaTrayMissing": "input-tray-missing",
        "inputMediaSupplyLow": "media-low",
        "inputMediaSupplyEmpty": "media-empty",
        "inputMediaChangeRequest": "media-needed",
        "outputMediaTrayMissing": "output-tray-missing",
        "outputMediaTrayAlmostFull": "output-area-almost-full",
        "outputMediaTrayFull": "output-area-full",
        "markerFuserUnderTemperature": "fuser-under-temp",
        "markerFuserOverTemperature": "fuser-over-temp",
        "markerTonerEmpty": "toner-empty",
        "markerTonerAlmostEmpty": "toner-low",
        "markerInkEmpty": "marker-supply-empty",
        "markerInkAlmostEmpty": "marker-supply-low",
        "markerPrintRibbonEmpty": "marker-supply-empty",
        "markerPrintRibbonAlmostEmpty": "marker-supply-low",
        "markerDeveloperEmpty": "marker-supply-empty",
        "markerDeveloperAlmostEmpty": "marker-supply-low",
        "markerWasteTonerReceptacleAlmostFull": "marker-waste-almost-full",
        "markerWasteInkReceptacleAlmostFull": "marker-waste-almost-full",
        "markerWasteTonerReceptacleFull": "marker-waste-full",
        "markerWasteInkReceptacleFull": "marker-waste-full",
        "markerOpcLifeAlmostOver": "opc-near-eol",
        "markerOpcLifeOver": "opc-life-over",
        "markerTonerCartridgeMissing": "marker-supply-missing",
        "interpreterResourceUnavailable": "interpreter-resource-unavailable",
    ]

    public static func describe(_ reason: String) -> String { known[reason]?.text ?? LedmStatusText.humanize(reason) }

    /// One plain sentence on what to do; nil when the title says it all.
    public static func explain(_ reason: String) -> String? { details[reason]?.text }

    /// Severity of a reason keyword without its suffix.
    public static func defaultSeverity(_ reason: String) -> Severity { warnings.contains(reason) ? .warning : .error }

    /// The printer-state-reasons keyword for an alert code, or nil when PWG 5100.9 maps it to none.
    public static func reasonForAlert(_ code: String) -> String? { alertReasons[code] }
}
