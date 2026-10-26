/// The objects Inkvolt Print reads: MIB-II system (RFC 1213), Host Resources MIB device and printer tables (RFC 2790 §4),
/// and the Printer MIB v2 general, marker supplies, colorant and alert tables (RFC 3805, which keeps RFC 1759's objects).
/// Every Printer MIB table is indexed by the printer's `hrDeviceIndex` first.
public enum PrinterMib {
    public static let sysDescr: Oid = "1.3.6.1.2.1.1.1"
    public static let sysName: Oid = "1.3.6.1.2.1.1.5"
    public static let sysLocation: Oid = "1.3.6.1.2.1.1.6"

    /// hrDeviceEntry (1.3.6.1.2.1.25.3.2.1): 3 hrDeviceDescr, 5 hrDeviceStatus.
    public static let hrDeviceDescr: Oid = "1.3.6.1.2.1.25.3.2.1.3", hrDeviceStatus: Oid = "1.3.6.1.2.1.25.3.2.1.5"

    /// hrPrinterEntry (1.3.6.1.2.1.25.3.5.1): 1 hrPrinterStatus, 2 hrPrinterDetectedErrorState.
    public static let hrPrinterStatus: Oid = "1.3.6.1.2.1.25.3.5.1.1", hrPrinterDetectedErrorState: Oid = "1.3.6.1.2.1.25.3.5.1.2"

    /// prtGeneralEntry (1.3.6.1.2.1.43.5.1.1): 16 prtGeneralPrinterName, 17 prtGeneralSerialNumber (both new in RFC 3805).
    public static let prtGeneralPrinterName: Oid = "1.3.6.1.2.1.43.5.1.1.16", prtGeneralSerialNumber: Oid = "1.3.6.1.2.1.43.5.1.1.17"

    /// prtMarkerSuppliesEntry (1.3.6.1.2.1.43.11.1.1) columns.
    public static let suppliesColorantIndex = supplies(3), suppliesClass = supplies(4), suppliesType = supplies(5),
        suppliesDescription = supplies(6), suppliesMaxCapacity = supplies(8), suppliesLevel = supplies(9)

    /// prtMarkerColorantEntry (1.3.6.1.2.1.43.12.1.1): 4 prtMarkerColorantValue ("black", "cyan"…).
    public static let colorantValue: Oid = "1.3.6.1.2.1.43.12.1.1.4"

    /// prtAlertEntry (1.3.6.1.2.1.43.18.1.1) columns (1, prtAlertIndex, isn't readable).
    public static let alertSeverity = alert(2), alertGroup = alert(4), alertGroupIndex = alert(5), alertCode = alert(7),
        alertDescription = alert(8)

    private static func supplies(_ column: UInt32) -> Oid { Oid(stringLiteral: "1.3.6.1.2.1.43.11.1.1").appending(column) }
    private static func alert(_ column: UInt32) -> Oid { Oid(stringLiteral: "1.3.6.1.2.1.43.18.1.1").appending(column) }

    /// hrDeviceStatus (RFC 2790).
    public static let deviceUnknown = 1, deviceRunning = 2, deviceWarning = 3, deviceTesting = 4, deviceDown = 5

    /// hrPrinterStatus (RFC 2790).
    public static let printerOther = 1, printerUnknown = 2, printerIdle = 3, printerPrinting = 4, printerWarmup = 5

    /// PrtMarkerSuppliesClassTC (RFC 3805).
    public static let classOther = 1, classConsumed = 3, classReceptacle = 4

    /// PrtAlertSeverityLevelTC (RFC 3805).
    public static let severityOther = 1, severityCritical = 3, severityWarning = 4, severityBinaryChangeEvent = 5

    /// PrtAlertGroupTC (IANA-PRINTER-MIB) values used here.
    public static let groupCover = 6, groupInput = 8, groupOutput = 9, groupMarker = 10, groupMarkerSupplies = 11, groupMediaPath = 13

    /// PrtMarkerSuppliesTypeTC (IANA-PRINTER-MIB) → the kind name the app uses (as IPP's marker-types).
    public static func supplyKind(_ type: Int) -> String {
        let kinds = [
            3: "toner", 4: "waste-toner", 5: "ink", 6: "ink-cartridge", 7: "ink-ribbon", 8: "waste-ink", 9: "opc",
            10: "developer", 11: "fuser-oil", 12: "solid-wax", 13: "ribbon-wax", 14: "waste-wax", 15: "fuser",
            16: "corona-wire", 17: "fuser-oil-wick", 18: "cleaner-unit", 19: "fuser-cleaning-pad", 20: "transfer-unit",
            21: "toner-cartridge", 22: "fuser-oiler", 23: "water", 24: "waste-water", 25: "glue-water-additive",
            26: "waste-paper", 27: "binding-supply", 28: "banding-supply", 29: "stitching-wire", 30: "shrink-wrap",
            31: "paper-wrap", 32: "staples", 33: "inserts", 34: "covers", 35: "matte-toner", 36: "matte-ink",
        ]
        return kinds[type] ?? "supply"
    }

    /// A name for a supply that has no description: "Toner", "Waste toner box", "Drum"…
    public static func supplyName(_ type: Int) -> String {
        switch type {
        case 3, 21: "Toner"
        case 35: "Matte toner"
        case 4: "Waste toner box"
        case 5, 6: "Ink"
        case 36: "Matte ink"
        case 7: "Ink ribbon"
        case 8: "Waste ink box"
        case 9: "Drum"
        case 10: "Developer"
        case 15: "Fuser"
        case 18: "Cleaner unit"
        case 20: "Transfer unit"
        case 32: "Staples"
        default: "Supply"
        }
    }

    /// PrtAlertCodeTC labels (IANA-PRINTER-MIB, as maintained since RFC 3805) for the codes a status can use: the generic
    /// sub-unit codes, the general printer, input, output, marker, marker supplies and media path ranges.
    public static func alertLabel(_ code: Int) -> String? { alertLabels[code] }

    private static let alertLabels: [Int: String] = [
        1: "other", 2: "unknown", 3: "coverOpen", 4: "coverClosed", 5: "interlockOpen", 6: "interlockClosed",
        7: "configurationChange", 8: "jam", 9: "subunitMissing", 10: "subunitLifeAlmostOver", 11: "subunitLifeOver",
        12: "subunitAlmostEmpty", 13: "subunitEmpty", 14: "subunitAlmostFull", 15: "subunitFull", 16: "subunitNearLimit",
        17: "subunitAtLimit", 18: "subunitOpened", 19: "subunitClosed", 20: "subunitTurnedOn", 21: "subunitTurnedOff",
        22: "subunitOffline", 23: "subunitPowerSaver", 24: "subunitWarmingUp", 25: "subunitAdded", 26: "subunitRemoved",
        27: "subunitResourceAdded", 28: "subunitResourceRemoved", 29: "subunitRecoverableFailure",
        30: "subunitUnrecoverableFailure", 31: "subunitRecoverableStorageError", 32: "subunitUnrecoverableStorageError",
        33: "subunitMotorFailure", 34: "subunitMemoryExhausted", 35: "subunitUnderTemperature", 36: "subunitOverTemperature",
        37: "subunitTimingFailure", 38: "subunitThermistorFailure",
        501: "doorOpen", 502: "doorClosed", 503: "powerUp", 504: "powerDown", 505: "printerNMSReset",
        506: "printerManualReset", 507: "printerReadyToPrint",
        801: "inputMediaTrayMissing", 802: "inputMediaSizeChange", 803: "inputMediaWeightChange", 804: "inputMediaTypeChange",
        805: "inputMediaColorChange", 806: "inputMediaFormPartsChange", 807: "inputMediaSupplyLow", 808: "inputMediaSupplyEmpty",
        809: "inputMediaChangeRequest", 810: "inputManualInputRequest", 811: "inputTrayPositionFailure",
        812: "inputTrayElevationFailure", 813: "inputCannotFeedSizeSelected",
        901: "outputMediaTrayMissing", 902: "outputMediaTrayAlmostFull", 903: "outputMediaTrayFull",
        904: "outputMailboxSelectFailure", 905: "outputMediaTrayFeedError", 906: "outputMediaTrayJam", 907: "outputMediaTrayFailure",
        1001: "markerFuserUnderTemperature", 1002: "markerFuserOverTemperature", 1003: "markerFuserTimingFailure",
        1004: "markerFuserThermistorFailure", 1005: "markerAdjustingPrintQuality",
        1101: "markerTonerEmpty", 1102: "markerInkEmpty", 1103: "markerPrintRibbonEmpty", 1104: "markerTonerAlmostEmpty",
        1105: "markerInkAlmostEmpty", 1106: "markerPrintRibbonAlmostEmpty", 1107: "markerWasteTonerReceptacleAlmostFull",
        1108: "markerWasteInkReceptacleAlmostFull", 1109: "markerWasteTonerReceptacleFull", 1110: "markerWasteInkReceptacleFull",
        1111: "markerOpcLifeAlmostOver", 1112: "markerOpcLifeOver", 1113: "markerDeveloperAlmostEmpty", 1114: "markerDeveloperEmpty",
        1115: "markerTonerCartridgeMissing", 1116: "markerCleanerMissing", 1117: "markerDeveloperMissing", 1118: "markerFuserMissing",
        1119: "markerInkMissing", 1120: "markerOpcMissing", 1121: "markerPrintRibbonMissing", 1122: "markerSupplyAlmostEmpty",
        1123: "markerSupplyEmpty", 1124: "markerSupplyMissing", 1125: "markerWasteAlmostFull", 1126: "markerWasteFull",
        1127: "markerWasteMissing", 1128: "markerWasteInkReceptacleMissing", 1129: "markerWasteTonerReceptacleMissing",
        1130: "markerTonerMissing", 1131: "markerSupplyFailure",
        1301: "mediaPathMediaTrayMissing", 1302: "mediaPathMediaTrayAlmostFull", 1303: "mediaPathMediaTrayFull",
        1304: "mediaPathCannotDuplexMediaSelected", 1305: "mediaPathFailure", 1306: "mediaPathJam", 1310: "mediaPathInputRequest",
        1311: "mediaPathInputFeedError", 1312: "mediaPathInputJam", 1321: "mediaPathOutputFeedError", 1322: "mediaPathOutputJam",
        1323: "mediaPathOutputFull", 1331: "mediaPathPickRollerLifeWarn", 1332: "mediaPathPickRollerLifeOver",
        1333: "mediaPathPickRollerFailure", 1334: "mediaPathPickRollerMissing",
        1507: "interpreterResourceUnavailable",
    ]
}
