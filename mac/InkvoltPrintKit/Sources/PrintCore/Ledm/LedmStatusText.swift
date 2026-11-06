/// Human text for LEDM status categories and alert IDs. Unknown IDs are de-camel-cased.
public enum LedmStatusText {
    private static let known: [String: (text: LocKey, severity: Severity)] = [
        "ready": (LocKey("Ready"), .info),
        "inPowerSave": (LocKey("Ready"), .info),
        "initializing": (LocKey("Starting up"), .info),
        "processing": (LocKey("Printing"), .info),
        "copying": (LocKey("Copying"), .info),
        "scanProcessing": (LocKey("Scanning"), .info),
        "coolDownMode": (LocKey("Cooling down"), .info),
        "cancelJob": (LocKey("Cancelling job"), .info),
        "shuttingDown": (LocKey("Shutting down"), .info),
        "upgrading": (LocKey("Updating firmware"), .info),
        "connectingToWeb": (LocKey("Connecting to web services"), .info),
        "deviceInteraction": (LocKey("Busy at the control panel"), .info),
        "trayEmptyOrOpen": (LocKey("Tray empty or open"), .error),
        "mediaPrompt": (LocKey("Load paper"), .error),
        "unexpectedSizeInTray": (LocKey("Unexpected paper size in tray"), .error),
        "manualDuplex": (LocKey("Turn the pages over for manual duplex"), .warning),
        "manuallyFeed": (LocKey("Waiting for manual feed"), .warning),
        "closeDoorOrCover": (LocKey("Close the door or cover"), .error),
        "cartridgeLow": (LocKey("Toner low"), .warning),
        "cartridgeVeryLow": (LocKey("Toner very low"), .warning),
        "orderCartridge": (LocKey("Order toner soon"), .warning),
        "replaceCartridgeOut": (LocKey("Replace the toner cartridge"), .error),
        "cartridgeMissing": (LocKey("Toner cartridge missing"), .error),
        "usedConsumable": (LocKey("Used cartridge installed"), .warning),
        "nonHPSupplyDetected": (LocKey("Non-HP cartridge detected"), .warning),
        "incompatibleConsumable": (LocKey("Incompatible cartridge"), .error),
        "tonerSealInPlace": (LocKey("Remove the toner seal"), .error),
        "jamInPrinter": (LocKey("Paper jam"), .error),
        "printerMispick": (LocKey("Paper pick-up failed"), .error),
        "scannerAdfJam": (LocKey("Document feeder jam"), .error),
        "scannerAdfMispick": (LocKey("Document feeder pick-up failed"), .error),
        "scannerAdfDoorOpen": (LocKey("Document feeder door open"), .error),
        "insufficientMemory": (LocKey("Out of memory"), .error),
        "printFailure": (LocKey("Print failure"), .error),
        "printerError": (LocKey("Printer error"), .error),
        "upgradeFailed": (LocKey("Firmware update failed"), .error),
        "misprint": (LocKey("Misprint"), .warning),
        "lightPipeBlocked": (LocKey("Sensor blocked"), .error),
        "waitingForSupplyAssessment": (LocKey("Checking supplies"), .info),
    ]

    private static let details: [String: LocKey] = [
        "inPowerSave": LocKey("Sleeping to save power. It wakes up by itself when you print or scan."),
        "ready": LocKey("Waiting for something to print or scan."),
        "trayEmptyOrOpen": LocKey("Load paper into the tray and push it all the way in."),
        "mediaPrompt": LocKey("Load paper, then press OK on the printer if it asks."),
        "closeDoorOrCover": LocKey("A door or cover is open. Close it to continue."),
        "jamInPrinter": LocKey("Open the front door, gently pull out the jammed paper, and close the door."),
        "replaceCartridgeOut": LocKey("The toner cartridge is empty. Replace it to keep printing."),
        "cartridgeMissing": LocKey("Insert the toner cartridge and close the front door."),
        "tonerSealInPlace": LocKey("Pull the orange tab off the new toner cartridge."),
        "manualDuplex": LocKey("Take the printed pages, turn them over, and put them back in the tray."),
    ]

    public static func isKnown(_ id: String) -> Bool { known[id] != nil }

    /// One plain sentence on what the state means or what to do; nil when the title says it all.
    public static func explain(_ id: String) -> String? { details[id]?.text }

    public static func describe(_ id: String) -> String { known[id]?.text.text ?? humanize(id) }

    public static func severityOf(_ id: String) -> Severity { known[id]?.severity ?? .warning }

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
