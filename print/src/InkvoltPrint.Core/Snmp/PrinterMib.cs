namespace InkvoltPrint.Core.Snmp;

/// <summary>
/// The objects Inkvolt Print reads: MIB-II system (RFC 1213), Host Resources MIB device and printer tables (RFC 2790 §4),
/// and the Printer MIB v2 general, marker supplies, colorant and alert tables (RFC 3805, which keeps RFC 1759's objects).
/// Every Printer MIB table is indexed by the printer's <c>hrDeviceIndex</c> first.
/// </summary>
public static class PrinterMib
{
    public static readonly Oid SysDescr = Oid.Parse("1.3.6.1.2.1.1.1");
    public static readonly Oid SysName = Oid.Parse("1.3.6.1.2.1.1.5");
    public static readonly Oid SysLocation = Oid.Parse("1.3.6.1.2.1.1.6");

    /// <summary>hrDeviceEntry (1.3.6.1.2.1.25.3.2.1): 3 hrDeviceDescr, 5 hrDeviceStatus.</summary>
    public static readonly Oid HrDeviceDescr = Oid.Parse("1.3.6.1.2.1.25.3.2.1.3"), HrDeviceStatus = Oid.Parse("1.3.6.1.2.1.25.3.2.1.5");

    /// <summary>hrPrinterEntry (1.3.6.1.2.1.25.3.5.1): 1 hrPrinterStatus, 2 hrPrinterDetectedErrorState.</summary>
    public static readonly Oid HrPrinterStatus = Oid.Parse("1.3.6.1.2.1.25.3.5.1.1"), HrPrinterDetectedErrorState = Oid.Parse("1.3.6.1.2.1.25.3.5.1.2");

    /// <summary>prtGeneralEntry (1.3.6.1.2.1.43.5.1.1): 16 prtGeneralPrinterName, 17 prtGeneralSerialNumber (both new in RFC 3805).</summary>
    public static readonly Oid PrtGeneralPrinterName = Oid.Parse("1.3.6.1.2.1.43.5.1.1.16"), PrtGeneralSerialNumber = Oid.Parse("1.3.6.1.2.1.43.5.1.1.17");

    /// <summary>prtMarkerSuppliesEntry (1.3.6.1.2.1.43.11.1.1) columns.</summary>
    public static readonly Oid SuppliesColorantIndex = Supplies(3), SuppliesClass = Supplies(4), SuppliesType = Supplies(5),
        SuppliesDescription = Supplies(6), SuppliesMaxCapacity = Supplies(8), SuppliesLevel = Supplies(9);

    /// <summary>prtMarkerColorantEntry (1.3.6.1.2.1.43.12.1.1): 4 prtMarkerColorantValue ("black", "cyan"…).</summary>
    public static readonly Oid ColorantValue = Oid.Parse("1.3.6.1.2.1.43.12.1.1.4");

    /// <summary>prtAlertEntry (1.3.6.1.2.1.43.18.1.1) columns (1, prtAlertIndex, isn't readable).</summary>
    public static readonly Oid AlertSeverity = Alert(2), AlertGroup = Alert(4), AlertGroupIndex = Alert(5), AlertCode = Alert(7), AlertDescription = Alert(8);

    private static Oid Supplies(uint column) => Oid.Parse("1.3.6.1.2.1.43.11.1.1").Append(column);
    private static Oid Alert(uint column) => Oid.Parse("1.3.6.1.2.1.43.18.1.1").Append(column);

    /// <summary>hrDeviceStatus (RFC 2790).</summary>
    public const int DeviceUnknown = 1, DeviceRunning = 2, DeviceWarning = 3, DeviceTesting = 4, DeviceDown = 5;

    /// <summary>hrPrinterStatus (RFC 2790).</summary>
    public const int PrinterOther = 1, PrinterUnknown = 2, PrinterIdle = 3, PrinterPrinting = 4, PrinterWarmup = 5;

    /// <summary>PrtMarkerSuppliesClassTC (RFC 3805).</summary>
    public const int ClassOther = 1, ClassConsumed = 3, ClassReceptacle = 4;

    /// <summary>PrtAlertSeverityLevelTC (RFC 3805).</summary>
    public const int SeverityOther = 1, SeverityCritical = 3, SeverityWarning = 4, SeverityBinaryChangeEvent = 5;

    /// <summary>PrtAlertGroupTC (IANA-PRINTER-MIB) values used here.</summary>
    public const int GroupCover = 6, GroupInput = 8, GroupOutput = 9, GroupMarker = 10, GroupMarkerSupplies = 11, GroupMediaPath = 13;

    /// <summary>PrtMarkerSuppliesTypeTC (IANA-PRINTER-MIB) → the kind name the app uses (as IPP's marker-types).</summary>
    public static string SupplyKind(int type) => type switch
    {
        3 => "toner",
        4 => "waste-toner",
        5 => "ink",
        6 => "ink-cartridge",
        7 => "ink-ribbon",
        8 => "waste-ink",
        9 => "opc",
        10 => "developer",
        11 => "fuser-oil",
        12 => "solid-wax",
        13 => "ribbon-wax",
        14 => "waste-wax",
        15 => "fuser",
        16 => "corona-wire",
        17 => "fuser-oil-wick",
        18 => "cleaner-unit",
        19 => "fuser-cleaning-pad",
        20 => "transfer-unit",
        21 => "toner-cartridge",
        22 => "fuser-oiler",
        23 => "water",
        24 => "waste-water",
        25 => "glue-water-additive",
        26 => "waste-paper",
        27 => "binding-supply",
        28 => "banding-supply",
        29 => "stitching-wire",
        30 => "shrink-wrap",
        31 => "paper-wrap",
        32 => "staples",
        33 => "inserts",
        34 => "covers",
        35 => "matte-toner",
        36 => "matte-ink",
        _ => "supply",
    };

    /// <summary>A name for a supply that has no description: "Toner", "Waste toner box", "Drum"…</summary>
    public static string SupplyName(int type) => type switch
    {
        3 or 21 => "Toner",
        35 => "Matte toner",
        4 => "Waste toner box",
        5 or 6 => "Ink",
        36 => "Matte ink",
        7 => "Ink ribbon",
        8 => "Waste ink box",
        9 => "Drum",
        10 => "Developer",
        15 => "Fuser",
        18 => "Cleaner unit",
        20 => "Transfer unit",
        32 => "Staples",
        _ => "Supply",
    };

    /// <summary>
    /// PrtAlertCodeTC labels (IANA-PRINTER-MIB, as maintained since RFC 3805) for the codes a status can use: the generic
    /// sub-unit codes, the general printer, input, output, marker, marker supplies and media path ranges.
    /// </summary>
    public static string? AlertLabel(int code) => code switch
    {
        1 => "other", 2 => "unknown", 3 => "coverOpen", 4 => "coverClosed", 5 => "interlockOpen", 6 => "interlockClosed",
        7 => "configurationChange", 8 => "jam", 9 => "subunitMissing", 10 => "subunitLifeAlmostOver", 11 => "subunitLifeOver",
        12 => "subunitAlmostEmpty", 13 => "subunitEmpty", 14 => "subunitAlmostFull", 15 => "subunitFull", 16 => "subunitNearLimit",
        17 => "subunitAtLimit", 18 => "subunitOpened", 19 => "subunitClosed", 20 => "subunitTurnedOn", 21 => "subunitTurnedOff",
        22 => "subunitOffline", 23 => "subunitPowerSaver", 24 => "subunitWarmingUp", 25 => "subunitAdded", 26 => "subunitRemoved",
        27 => "subunitResourceAdded", 28 => "subunitResourceRemoved", 29 => "subunitRecoverableFailure",
        30 => "subunitUnrecoverableFailure", 31 => "subunitRecoverableStorageError", 32 => "subunitUnrecoverableStorageError",
        33 => "subunitMotorFailure", 34 => "subunitMemoryExhausted", 35 => "subunitUnderTemperature", 36 => "subunitOverTemperature",
        37 => "subunitTimingFailure", 38 => "subunitThermistorFailure",
        501 => "doorOpen", 502 => "doorClosed", 503 => "powerUp", 504 => "powerDown", 505 => "printerNMSReset",
        506 => "printerManualReset", 507 => "printerReadyToPrint",
        801 => "inputMediaTrayMissing", 802 => "inputMediaSizeChange", 803 => "inputMediaWeightChange", 804 => "inputMediaTypeChange",
        805 => "inputMediaColorChange", 806 => "inputMediaFormPartsChange", 807 => "inputMediaSupplyLow", 808 => "inputMediaSupplyEmpty",
        809 => "inputMediaChangeRequest", 810 => "inputManualInputRequest", 811 => "inputTrayPositionFailure",
        812 => "inputTrayElevationFailure", 813 => "inputCannotFeedSizeSelected",
        901 => "outputMediaTrayMissing", 902 => "outputMediaTrayAlmostFull", 903 => "outputMediaTrayFull",
        904 => "outputMailboxSelectFailure", 905 => "outputMediaTrayFeedError", 906 => "outputMediaTrayJam", 907 => "outputMediaTrayFailure",
        1001 => "markerFuserUnderTemperature", 1002 => "markerFuserOverTemperature", 1003 => "markerFuserTimingFailure",
        1004 => "markerFuserThermistorFailure", 1005 => "markerAdjustingPrintQuality",
        1101 => "markerTonerEmpty", 1102 => "markerInkEmpty", 1103 => "markerPrintRibbonEmpty", 1104 => "markerTonerAlmostEmpty",
        1105 => "markerInkAlmostEmpty", 1106 => "markerPrintRibbonAlmostEmpty", 1107 => "markerWasteTonerReceptacleAlmostFull",
        1108 => "markerWasteInkReceptacleAlmostFull", 1109 => "markerWasteTonerReceptacleFull", 1110 => "markerWasteInkReceptacleFull",
        1111 => "markerOpcLifeAlmostOver", 1112 => "markerOpcLifeOver", 1113 => "markerDeveloperAlmostEmpty", 1114 => "markerDeveloperEmpty",
        1115 => "markerTonerCartridgeMissing", 1116 => "markerCleanerMissing", 1117 => "markerDeveloperMissing", 1118 => "markerFuserMissing",
        1119 => "markerInkMissing", 1120 => "markerOpcMissing", 1121 => "markerPrintRibbonMissing", 1122 => "markerSupplyAlmostEmpty",
        1123 => "markerSupplyEmpty", 1124 => "markerSupplyMissing", 1125 => "markerWasteAlmostFull", 1126 => "markerWasteFull",
        1127 => "markerWasteMissing", 1128 => "markerWasteInkReceptacleMissing", 1129 => "markerWasteTonerReceptacleMissing",
        1130 => "markerTonerMissing", 1131 => "markerSupplyFailure",
        1301 => "mediaPathMediaTrayMissing", 1302 => "mediaPathMediaTrayAlmostFull", 1303 => "mediaPathMediaTrayFull",
        1304 => "mediaPathCannotDuplexMediaSelected", 1305 => "mediaPathFailure", 1306 => "mediaPathJam", 1310 => "mediaPathInputRequest",
        1311 => "mediaPathInputFeedError", 1312 => "mediaPathInputJam", 1321 => "mediaPathOutputFeedError", 1322 => "mediaPathOutputJam",
        1323 => "mediaPathOutputFull", 1331 => "mediaPathPickRollerLifeWarn", 1332 => "mediaPathPickRollerLifeOver",
        1333 => "mediaPathPickRollerFailure", 1334 => "mediaPathPickRollerMissing",
        1507 => "interpreterResourceUnavailable",
        _ => null,
    };
}
