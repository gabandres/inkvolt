/// Plain words for IPP `printer-state-reasons` keywords (RFC 8011 §5.4.12, PWG 5100.9 §5.1) and the `printer-alert`
/// codes (PWG 5100.9 §5.2, IANA PrtAlertCodeTC) that mean the same thing. Unknown keywords are de-hyphenated.
public enum IppStatusText {
    private static var known: [String: String] {
[
        "media-empty": loc("Out of paper"),
        "media-needed": loc("Load paper"),
        "media-low": loc("Paper low"),
        "media-jam": loc("Paper jam"),
        "media-path-jam": loc("Paper jam"),
        "input-tray-missing": loc("Paper tray missing"),
        "output-tray-missing": loc("Output tray missing"),
        "output-area-almost-full": loc("Output tray almost full"),
        "output-area-full": loc("Output tray full"),
        "cover-open": loc("A cover is open"),
        "door-open": loc("A door is open"),
        "interlock-open": loc("A cover is open"),
        "toner-low": loc("Toner low"),
        "toner-empty": loc("Toner empty"),
        "marker-supply-low": loc("Ink or toner low"),
        "marker-supply-empty": loc("Ink or toner empty"),
        "marker-supply-missing": loc("Cartridge missing"),
        "marker-waste-almost-full": loc("Waste ink or toner box almost full"),
        "marker-waste-full": loc("Waste ink or toner box full"),
        "marker-waste-ink-receptacle-almost-full": loc("Maintenance box almost full"),
        "marker-waste-ink-receptacle-full": loc("Maintenance box full"),
        "marker-waste-toner-receptacle-almost-full": loc("Waste toner box almost full"),
        "marker-waste-toner-receptacle-full": loc("Waste toner box full"),
        "developer-low": loc("Developer low"),
        "developer-empty": loc("Developer empty"),
        "opc-near-eol": loc("Drum nearly worn out"),
        "opc-life-over": loc("Replace the drum"),
        "fuser-over-temp": loc("Fuser too hot"),
        "fuser-under-temp": loc("Fuser warming up"),
        "paused": loc("Paused"),
        "moving-to-paused": loc("Pausing"),
        "shutdown": loc("Shutting down"),
        "stopping": loc("Stopping"),
        "stopped-partly": loc("Partly stopped"),
        "spool-area-full": loc("Printer memory full"),
        "interpreter-resource-unavailable": loc("Printer resource unavailable"),
        "timed-out": loc("Timed out"),
        "connecting-to-device": loc("Connecting"),
        "identify-printer-requested": loc("Identifying itself"),
        "offline": loc("Offline"),
        "deactivated": loc("Turned off by an administrator"),
    ]
    }

    private static var details: [String: String] {
[
        "media-empty": loc("Load paper into the tray."),
        "media-needed": loc("Load the paper the printer asks for, then press OK on the printer if it asks."),
        "media-jam": loc("Open the covers the printer's screen points to and gently pull out the jammed paper."),
        "cover-open": loc("Close it to continue."),
        "door-open": loc("Close it to continue."),
        "toner-empty": loc("Replace the toner cartridge to keep printing."),
        "marker-supply-empty": loc("Replace or refill the empty cartridge or ink tank to keep printing."),
        "marker-waste-full": loc("Replace the waste ink or toner box (on inkjets: the maintenance box) to keep printing."),
        "marker-waste-ink-receptacle-full": loc("Replace the maintenance box to keep printing."),
        "opc-life-over": loc("The drum unit has reached the end of its life. Replace it to keep printing well."),
    ]
    }

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

    public static func describe(_ reason: String) -> String { known[reason] ?? LedmStatusText.humanize(reason) }

    /// One plain sentence on what to do; nil when the title says it all.
    public static func explain(_ reason: String) -> String? { details[reason] }

    /// Severity of a reason keyword without its suffix.
    public static func defaultSeverity(_ reason: String) -> Severity { warnings.contains(reason) ? .warning : .error }

    /// The printer-state-reasons keyword for an alert code, or nil when PWG 5100.9 maps it to none.
    public static func reasonForAlert(_ code: String) -> String? { alertReasons[code] }
}
