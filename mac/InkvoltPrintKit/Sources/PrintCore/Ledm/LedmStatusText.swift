/// Human text for LEDM status categories and alert IDs. Unknown IDs are de-camel-cased.
public enum LedmStatusText {
    private static var known: [String: (text: String, severity: Severity)] {
[
        "ready": (loc("Ready"), .info),
        "inPowerSave": (loc("Ready"), .info),
        "initializing": (loc("Starting up"), .info),
        "processing": (loc("Printing"), .info),
        "copying": (loc("Copying"), .info),
        "scanProcessing": (loc("Scanning"), .info),
        "coolDownMode": (loc("Cooling down"), .info),
        "cancelJob": (loc("Cancelling job"), .info),
        "shuttingDown": (loc("Shutting down"), .info),
        "upgrading": (loc("Updating firmware"), .info),
        "connectingToWeb": (loc("Connecting to web services"), .info),
        "deviceInteraction": (loc("Busy at the control panel"), .info),
        "trayEmptyOrOpen": (loc("Tray empty or open"), .error),
        "mediaPrompt": (loc("Load paper"), .error),
        "unexpectedSizeInTray": (loc("Unexpected paper size in tray"), .error),
        "manualDuplex": (loc("Turn the pages over for manual duplex"), .warning),
        "manuallyFeed": (loc("Waiting for manual feed"), .warning),
        "closeDoorOrCover": (loc("Close the door or cover"), .error),
        "cartridgeLow": (loc("Toner low"), .warning),
        "cartridgeVeryLow": (loc("Toner very low"), .warning),
        "orderCartridge": (loc("Order toner soon"), .warning),
        "replaceCartridgeOut": (loc("Replace the toner cartridge"), .error),
        "cartridgeMissing": (loc("Toner cartridge missing"), .error),
        "usedConsumable": (loc("Used cartridge installed"), .warning),
        "nonHPSupplyDetected": (loc("Non-HP cartridge detected"), .warning),
        "incompatibleConsumable": (loc("Incompatible cartridge"), .error),
        "tonerSealInPlace": (loc("Remove the toner seal"), .error),
        "jamInPrinter": (loc("Paper jam"), .error),
        "printerMispick": (loc("Paper pick-up failed"), .error),
        "scannerAdfJam": (loc("Document feeder jam"), .error),
        "scannerAdfMispick": (loc("Document feeder pick-up failed"), .error),
        "scannerAdfDoorOpen": (loc("Document feeder door open"), .error),
        "insufficientMemory": (loc("Out of memory"), .error),
        "printFailure": (loc("Print failure"), .error),
        "printerError": (loc("Printer error"), .error),
        "upgradeFailed": (loc("Firmware update failed"), .error),
        "misprint": (loc("Misprint"), .warning),
        "lightPipeBlocked": (loc("Sensor blocked"), .error),
        "waitingForSupplyAssessment": (loc("Checking supplies"), .info),
    ]
    }

    private static var details: [String: String] {
[
        "inPowerSave": loc("Sleeping to save power. It wakes up by itself when you print or scan."),
        "ready": loc("Waiting for something to print or scan."),
        "trayEmptyOrOpen": loc("Load paper into the tray and push it all the way in."),
        "mediaPrompt": loc("Load paper, then press OK on the printer if it asks."),
        "closeDoorOrCover": loc("A door or cover is open. Close it to continue."),
        "jamInPrinter": loc("Open the front door, gently pull out the jammed paper, and close the door."),
        "replaceCartridgeOut": loc("The toner cartridge is empty. Replace it to keep printing."),
        "cartridgeMissing": loc("Insert the toner cartridge and close the front door."),
        "tonerSealInPlace": loc("Pull the orange tab off the new toner cartridge."),
        "manualDuplex": loc("Take the printed pages, turn them over, and put them back in the tray."),
    ]
    }

    public static func isKnown(_ id: String) -> Bool { known[id] != nil }

    /// One plain sentence on what the state means or what to do; nil when the title says it all.
    public static func explain(_ id: String) -> String? { details[id] }

    public static func describe(_ id: String) -> String { known[id]?.text ?? humanize(id) }

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
