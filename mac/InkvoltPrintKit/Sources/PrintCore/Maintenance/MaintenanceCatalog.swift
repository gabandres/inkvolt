import Foundation

public enum MaintenanceKind: Sendable {
    case configurationPage, qualityReport, diagnosticsPage, networkPage, wirelessTest
    case cleaning, cleaningCheck, smearCleaning, alignment, identify
}

/// What the printer marks paper with, for the wording ("uses ink", "uses toner").
public enum Marking: Sendable { case unknown, ink, toner }

/// One maintenance action a printer advertised: the button's text, what it uses, the question asked before it's sent and
/// how to send it. Built only by `MaintenanceCatalog.detect`, so every job type or operation is one the printer listed and
/// Inkvolt Print knows the meaning of.
public struct MaintenanceAction: Equatable, Sendable {
    /// Stable key: `ledm:<job type>`, `ledm:align`, `ipp:identify`.
    public var id: String
    public var kind: MaintenanceKind
    public var title: String
    /// The maker whose own interface this uses ("HP"); nil for standard IPP.
    public var brand: String?
    /// What happens and what it uses (paper, ink, toner, time), as the confirmation says it.
    public var uses: String
    /// The same in a few words, under the button ("1 page · plain paper · a little toner").
    public var summary: String
    /// The confirmation button's wording ("Print", "Clean", "Align", "Identify").
    public var confirmButton: String
    /// Said once the printer took the request.
    public var sent: String
    /// Needs paper (and a printer free to print): a jam or a print job holds it back.
    public var printsPage = false
    /// Cleaning level, 1 for the first; 0 for everything else.
    public var level = 0
    /// HP LEDM internal print job type (`configurationPage`…); nil for other actions.
    public var jobType: String?
    /// LEDM: the path the request is POSTed to (InternalPrintDyn or the calibration session).
    public var target: String?
    /// Identify-Printer: the `identify-actions` asked for (empty: the printer's default).
    public var identifyActions: [String] = []
    /// Listed but can't be started from here (e.g. alignment by hand): the reason, shown with the disabled button.
    public var unavailable: String?

    /// Button text: the title, with the maker's name when it's that maker's own feature.
    public var label: String { brand.map { "\(title) (\($0))" } ?? title }

    public var confirmText: String {
        "\(label)?\n\n\(uses)" + (printsPage ? "\n\nThe printer needs to be on and free, with plain paper loaded." : "")
    }
}

/// Everything the maintenance card shows for one printer.
public struct MaintenanceOptions: Equatable, Sendable {
    public var actions: [MaintenanceAction]
    /// IPP `printer-supply-info-uri` (PWG 5100.13 §5.6.41): the printer's own page for supplies, head alignment and
    /// self-test pages, only when it's on the printer itself.
    public var supplyPage: URL?
    /// Why something isn't offered (no maintenance interface, no standard for cleaning).
    public var note: String?

    public static let none = MaintenanceOptions(actions: [], supplyPage: nil, note: nil)
}

/// What `MaintenanceClient.detect` read from the printer.
public struct MaintenanceSources: Sendable {
    public var host: String
    /// HP's LEDM interface answered.
    public var hasLedm = false
    /// A newer HP printer that answered HP's CDM interface instead (read only in Inkvolt Print).
    public var hasCdm = false
    /// Read over SNMP only (no LEDM, CDM or IPP): SNMP has no maintenance requests.
    public var hasSnmp = false
    /// Job types in the printer's InternalPrintCap document; nil when it has none (404, unreadable).
    public var ledmJobTypes: [String]?
    /// Where internal print jobs are POSTed (the InternalPrint manifest's InternalPrintDyn, else HPLIP's path).
    public var ledmDynPath: String?
    /// `dd:AlignmentMode` (automatic, semiAutomatic, manual), read only when the DiscoveryTree lists the calibration interface.
    public var alignmentMode: String?
    /// Get-Printer-Attributes with `MaintenanceClient.ippAttributes`; nil without IPP.
    public var ipp: IppResponse?
    public var marking: Marking = .unknown

    public init(host: String, hasLedm: Bool = false, hasCdm: Bool = false, hasSnmp: Bool = false, ledmJobTypes: [String]? = nil,
                ledmDynPath: String? = nil, alignmentMode: String? = nil, ipp: IppResponse? = nil, marking: Marking = .unknown) {
        self.host = host
        self.hasLedm = hasLedm
        self.hasCdm = hasCdm
        self.hasSnmp = hasSnmp
        self.ledmJobTypes = ledmJobTypes
        self.ledmDynPath = ledmDynPath
        self.alignmentMode = alignmentMode
        self.ipp = ipp
        self.marking = marking
    }
}

/// Turns what a printer advertises into actions. Sources, re-checked 2026-10 (none of it tried on hardware):
/// - HP LEDM internal pages: `GET /DevMgmt/InternalPrintCap.xml` lists `ipdyn:JobType` values; a POST of
///   `ipdyn:InternalPrintDyn` to `/DevMgmt/InternalPrintDyn.xml` runs one. HPLIP base/maint.py (cleaningPage,
///   cleaningPageLevel1/2, cleaningVerificationPage; https://developers.hp.com/hp-linux-imaging-and-printing),
///   github.com/YannKr/hp-printer-maintenance src/hpmaint/ews.py (MIT; configurationPage, pqDiagnosticsPage,
///   diagnosticsPage, cleaningPageLevel2/3) and github.com/stacksjs/ts-printers src/drivers/hp/maintenance.ts
///   (networkSummary, wirelessNetworkPage, ribSmearCleaningPage). DiscoveryTrees published in
///   github.com/manuc66/node-hp-scan-to list it as `ledm:hpLedmInternalPrintManifest`.
/// - HP alignment: `dd:AlignmentMode` in ConsumableConfigDyn, then `POST /Calibration/Session` with `cal:CalibrationState`
///   "Printing" (HPLIP maint.py dataModelHelper; the DiscoveryTree's `ledm:hpCnxCalibrationManifest`). Manual alignment
///   (choosing patterns by hand) is left to the printer.
/// - IPP: Identify-Printer (0x003C, PWG 5100.13 §4.1, "identify-actions" §5.1.4: display, flash, sound, speak) when
///   `operations-supported` lists it; `printer-supply-info-uri` (§5.6.41). IPP defines no cleaning, nozzle check or
///   alignment operation (PWG 5100.13 leaves them to the supply page), and the PWG System Service doesn't cover them.
///
/// The LaserJet MFP M234dw lists neither HP interface (its InternalPrintCap is 404), so it gets the web page only.
public enum MaintenanceCatalog {
    private static let reports = ["configurationPage", "pqDiagnosticsPage", "diagnosticsPage", "networkSummary", "wirelessNetworkPage"]
    private static let cleanings = ["cleaningPage", "cleaningPageLevel1", "cleaningPageLevel2", "cleaningPageLevel3"]

    /// Every LEDM job type Inkvolt Print may send; anything else a printer lists is ignored.
    public static let knownJobTypes: Set<String> = Set(reports + cleanings + ["cleaningVerificationPage", "ribSmearCleaningPage"])

    /// Identify-Printer actions Inkvolt Print asks for, in this order ("speak" reads a message aloud: left out).
    private static let identifyOrder = ["flash", "sound", "display"]

    public static func detect(_ s: MaintenanceSources) -> MaintenanceOptions {
        var actions: [MaintenanceAction] = []
        let supply = switch s.marking {
        case .toner: "toner"
        case .ink: "ink"
        case .unknown: "ink or toner"
        }
        if let jobs = s.ledmJobTypes, let dyn = s.ledmDynPath {
            let listed = Set(jobs)
            for job in reports where listed.contains(job) { actions.append(report(job, supply, dyn)) }
            for (i, job) in cleanings.filter(listed.contains).enumerated() { actions.append(cleaning(job, i + 1, s.marking, dyn)) }
            if listed.contains("cleaningVerificationPage") {
                actions.append(hp("cleaningVerificationPage", .cleaningCheck, "Print cleaning check page", dyn, "1 page · plain paper",
                                  "Prints 1 page on plain paper with test patterns, to see whether a cleaning helped. Uses a little \(supply).",
                                  "Print", "Sent. The printer will print the cleaning check page."))
            }
            if listed.contains("ribSmearCleaningPage") && s.marking != .toner {
                actions.append(hp("ribSmearCleaningPage", .smearCleaning, "Clean page smears", dyn, "1 sheet · a few minutes · a little ink",
                                  "Feeds a sheet of plain paper through the printer to clean ink smears off the rollers. Takes a few minutes; uses a little ink.",
                                  "Clean", "Sent. The printer will feed a sheet to clean its rollers."))
            }
        }
        if let mode = s.alignmentMode { actions.append(alignment(mode)) }
        if let ipp = s.ipp, ipp.ints("operations-supported").contains(Int(IppCodec.identifyPrinter)) { actions.append(identify(ipp)) }

        let supplyPage = s.ipp?.str("printer-supply-info-uri").flatMap { onPrinter($0, host: s.host) }
        let hpActions = actions.contains { $0.brand != nil }
        let note: String?
        if !s.hasLedm && s.hasCdm {
            note = "This newer HP printer uses HP's CDM interface, whose maintenance requests aren't publicly documented, so "
                + "Inkvolt Print doesn't start them: use its control panel or its web page."
        } else if s.hasLedm && !hpActions {
            note = "This printer doesn't offer its maintenance pages to other apps. Print a configuration page, clean or align it "
                + "from its control panel or its web page."
        } else if !s.hasLedm && s.hasSnmp {
            note = "Inkvolt Print reads this printer over SNMP, which has no maintenance requests, so it can't start "
                + "cleaning, nozzle checks or alignment: use its control panel or its web page."
        } else if !s.hasLedm {
            note = "Head cleaning, nozzle checks and alignment aren't part of the IPP printing standard, so Inkvolt Print can't start "
                + "them on this printer: use its control panel" + (supplyPage == nil ? " or its web page." : " or its maintenance page.")
        } else {
            note = nil
        }
        return MaintenanceOptions(actions: actions, supplyPage: supplyPage, note: note)
    }

    private static func report(_ job: String, _ supply: String, _ dyn: String) -> MaintenanceAction {
        switch job {
        case "configurationPage":
            hp(job, .configurationPage, "Print configuration page", dyn, "1 or 2 pages · plain paper · a little \(supply)",
               "Prints 1 or 2 pages on plain paper with the printer's settings, network address and supply status. Uses a little \(supply).",
               "Print", "Sent. The printer will print its configuration page.")
        case "pqDiagnosticsPage":
            hp(job, .qualityReport, "Print quality report", dyn, "1 page · plain paper · some \(supply)",
               "Prints 1 page on plain paper with color blocks and patterns that show streaks, faded colors or misalignment. Uses some \(supply).",
               "Print", "Sent. The printer will print its print quality report.")
        case "diagnosticsPage":
            hp(job, .diagnosticsPage, "Print diagnostics page", dyn, "Usually 1 page · plain paper",
               "Prints the printer's diagnostics page on plain paper (usually 1 page). Uses a little \(supply).",
               "Print", "Sent. The printer will print its diagnostics page.")
        case "networkSummary":
            hp(job, .networkPage, "Print network configuration page", dyn, "1 page · plain paper",
               "Prints 1 page on plain paper with the printer's network settings and addresses. Uses a little \(supply).",
               "Print", "Sent. The printer will print its network configuration page.")
        default:
            hp(job, .wirelessTest, "Print wireless test report", dyn, "Tests Wi-Fi · 1 page · plain paper",
               "The printer tests its Wi-Fi connection and prints the result on 1 page of plain paper. Uses a little \(supply).",
               "Print", "Sent. The printer will test its Wi-Fi and print the report.")
        }
    }

    private static func cleaning(_ job: String, _ level: Int, _ marking: Marking, _ dyn: String) -> MaintenanceAction {
        var action: MaintenanceAction
        if marking == .toner {
            // A LaserJet's cleaning page cleans the paper path (fuser), not a printhead.
            action = hp(job, .cleaning, level == 1 ? "Print cleaning page" : "Print cleaning page, level \(level)", dyn,
                        "1 sheet · plain paper · a little toner",
                        "Runs the printer's cleaning page: feeds a sheet of plain paper through to clean the paper path. Uses a little toner "
                            + "and takes a minute or two.", "Print", "Sent. The printer will run its cleaning page.")
        } else {
            let uses = level == 1
                ? "Cleans the printhead's nozzles and may print a test page on plain paper. Uses some ink; try it when prints are "
                    + "streaky or a color is missing."
                : "A deeper cleaning than level \(level - 1); uses more ink. Try it only when level \(level - 1) didn't fix the prints, "
                    + "and let the printer rest a few minutes in between."
            action = hp(job, .cleaning, level == 1 ? "Clean printhead" : "Clean printhead, level \(level)", dyn,
                        level == 1 ? "A few minutes · uses some ink" : "Deeper · uses more ink", uses, "Clean",
                        "Sent. The printer is cleaning its printhead; this takes a few minutes.")
        }
        action.level = level
        return action
    }

    private static func alignment(_ mode: String) -> MaintenanceAction {
        let semi = mode == "semiAutomatic"
        var a = MaintenanceAction(
            id: "ledm:align", kind: .alignment, title: "Align printhead", brand: "HP",
            uses: semi
                ? "Prints an alignment page on plain paper (uses a little ink). Then place the page face down on the scanner glass and "
                    + "follow the printer's control panel to scan it."
                : "Prints an alignment page on plain paper and adjusts the printhead from it. Uses a little ink and takes a few minutes.",
            summary: semi ? "1 page · plain paper · then scanned on the glass" : "1 page · plain paper · a few minutes",
            confirmButton: "Align",
            sent: semi
                ? "Sent. When the alignment page is out, put it face down on the scanner glass and follow the printer's control panel."
                : "Sent. The printer will print its alignment page and adjust itself.")
        a.printsPage = true
        a.target = MaintenanceRequests.calibrationSessionPath
        a.unavailable = mode == "automatic" || semi ? nil : "This printer aligns by hand (choosing patterns): use its control panel or its web page."
        return a
    }

    private static func identify(_ ipp: IppResponse) -> MaintenanceAction {
        let supported = Set(ipp.strs("identify-actions-supported"))
        let chosen = identifyOrder.filter(supported.contains)
        let what = chosen.map { a in
            switch a {
            case "flash": "flashes its lights"
            case "sound": "makes a sound"
            default: "shows a message on its control panel"
            }
        }
        var signal = chosen.isEmpty ? "Its usual signal"
            : chosen.map { a in
                switch a {
                case "flash": "lights"
                case "sound": "sound"
                default: "a message"
                }
            }.joined(separator: " and ")
        signal = signal.prefix(1).uppercased() + signal.dropFirst()
        let does = what.isEmpty ? "shows where it is the way it's set to (lights, a sound or a message)"
            : what.count == 1 ? what[0] : what.dropLast().joined(separator: ", ") + " and " + what[what.count - 1]
        var a = MaintenanceAction(id: "ipp:identify", kind: .identify, title: "Identify printer",
                                  uses: "The printer \(does), so you can tell which one it is. Uses no paper, ink or toner.",
                                  summary: "\(signal) · no paper or ink", confirmButton: "Identify", sent: "Sent. The printer \(does).")
        a.identifyActions = chosen
        return a
    }

    private static func hp(_ job: String, _ kind: MaintenanceKind, _ title: String, _ dyn: String, _ summary: String, _ uses: String,
                           _ button: String, _ sent: String) -> MaintenanceAction {
        var a = MaintenanceAction(id: "ledm:" + job, kind: kind, title: title, brand: "HP", uses: uses, summary: summary, confirmButton: button,
                                  sent: sent)
        a.printsPage = true
        a.jobType = job
        a.target = dyn
        return a
    }

    /// An http(s) URL from the printer, only when it points back at the printer itself (never another host).
    static func onPrinter(_ text: String, host: String) -> URL? {
        guard let u = URL(string: text), u.scheme == "http" || u.scheme == "https", let h = u.host,
              h.caseInsensitiveCompare(host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))) == .orderedSame,
              u.user == nil, u.password == nil else { return nil }
        return u
    }
}

/// Whether an action can be sent now, and if not, why (shown next to the disabled button).
public enum MaintenanceAvailability {
    public static func whyNot(_ action: MaintenanceAction, online: Bool, status: PrinterStatus?, busy: Bool) -> String? {
        if let reason = action.unavailable { return reason }
        if !online { return "The printer isn't answering." }
        if busy { return "Waiting for the printer to answer the last request." }
        guard action.printsPage, let status else { return nil }
        if status.severity == .error { return "Fix this first: \(trimmedPeriods(status.message))." }
        if status.code == "processing" || status.code == "printing" { return "The printer is printing; try again when it's done." }
        if busyStates.contains(status.code) { return "The printer is busy (\(trimmedPeriods(status.message))); try again when it's ready." }
        return nil
    }

    /// LEDM states (`LedmStatusText`) in which the printer can't take an internal page: it's doing something else.
    private static let busyStates: Set<String> = [
        "copying", "scanProcessing", "initializing", "coolDownMode", "cancelJob", "shuttingDown", "upgrading", "deviceInteraction",
        "manualDuplex", "manuallyFeed",
    ]

    private static func trimmedPeriods(_ s: String) -> String {
        var t = Substring(s)
        while t.hasSuffix(".") { t = t.dropLast() }
        return String(t)
    }
}
