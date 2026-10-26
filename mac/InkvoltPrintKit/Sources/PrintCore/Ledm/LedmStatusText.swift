/// Human text for LEDM status categories and alert IDs. Unknown IDs are de-camel-cased.
public enum LedmStatusText {
    private static let known: [String: (text: String, severity: Severity)] = [
        "ready": ("Ready", .info),
        "inPowerSave": ("Ready", .info),
        "initializing": ("Starting up", .info),
        "processing": ("Printing", .info),
        "copying": ("Copying", .info),
        "scanProcessing": ("Scanning", .info),
        "coolDownMode": ("Cooling down", .info),
        "cancelJob": ("Cancelling job", .info),
        "shuttingDown": ("Shutting down", .info),
        "upgrading": ("Updating firmware", .info),
        "connectingToWeb": ("Connecting to web services", .info),
        "deviceInteraction": ("Busy at the control panel", .info),
        "trayEmptyOrOpen": ("Tray empty or open", .error),
        "mediaPrompt": ("Load paper", .error),
        "unexpectedSizeInTray": ("Unexpected paper size in tray", .error),
        "manualDuplex": ("Turn the pages over for manual duplex", .warning),
        "manuallyFeed": ("Waiting for manual feed", .warning),
        "closeDoorOrCover": ("Close the door or cover", .error),
        "cartridgeLow": ("Toner low", .warning),
        "cartridgeVeryLow": ("Toner very low", .warning),
        "orderCartridge": ("Order toner soon", .warning),
        "replaceCartridgeOut": ("Replace the toner cartridge", .error),
        "cartridgeMissing": ("Toner cartridge missing", .error),
        "usedConsumable": ("Used cartridge installed", .warning),
        "nonHPSupplyDetected": ("Non-HP cartridge detected", .warning),
        "incompatibleConsumable": ("Incompatible cartridge", .error),
        "tonerSealInPlace": ("Remove the toner seal", .error),
        "jamInPrinter": ("Paper jam", .error),
        "printerMispick": ("Paper pick-up failed", .error),
        "scannerAdfJam": ("Document feeder jam", .error),
        "scannerAdfMispick": ("Document feeder pick-up failed", .error),
        "scannerAdfDoorOpen": ("Document feeder door open", .error),
        "insufficientMemory": ("Out of memory", .error),
        "printFailure": ("Print failure", .error),
        "printerError": ("Printer error", .error),
        "upgradeFailed": ("Firmware update failed", .error),
        "misprint": ("Misprint", .warning),
        "lightPipeBlocked": ("Sensor blocked", .error),
        "waitingForSupplyAssessment": ("Checking supplies", .info),
    ]

    private static let details: [String: String] = [
        "inPowerSave": "Sleeping to save power. It wakes up by itself when you print or scan.",
        "ready": "Waiting for something to print or scan.",
        "trayEmptyOrOpen": "Load paper into the tray and push it all the way in.",
        "mediaPrompt": "Load paper, then press OK on the printer if it asks.",
        "closeDoorOrCover": "A door or cover is open. Close it to continue.",
        "jamInPrinter": "Open the front door, gently pull out the jammed paper, and close the door.",
        "replaceCartridgeOut": "The toner cartridge is empty. Replace it to keep printing.",
        "cartridgeMissing": "Insert the toner cartridge and close the front door.",
        "tonerSealInPlace": "Pull the orange tab off the new toner cartridge.",
        "manualDuplex": "Take the printed pages, turn them over, and put them back in the tray.",
    ]

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
