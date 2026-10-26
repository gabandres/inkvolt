import Foundation

/// A job type outside `MaintenanceCatalog.knownJobTypes`: never sent.
public struct UnknownJobType: Error, CustomStringConvertible {
    public let jobType: String

    public var description: String { "Unknown internal print job type \"\(jobType)\"" }
}

/// HP LEDM maintenance documents: what is read to find the actions and the exact bodies sent to start one. Sources: see
/// `MaintenanceCatalog`. Namespace-agnostic when reading (LEDM namespaces drift across firmware), exact when writing.
public enum MaintenanceRequests {
    public static let internalPrintDynNs = "http://www.hp.com/schemas/imaging/con/ledm/internalprintdyn/2008/03/21"
    public static let calibrationNs = "http://www.hp.com/schemas/imaging/con/cnx/markingagentcalibration/2009/04/08"

    /// HPLIP's paths, used when the DiscoveryTree has no InternalPrint manifest saying otherwise.
    public static let internalPrintCapPath = "/DevMgmt/InternalPrintCap.xml", internalPrintDynPath = "/DevMgmt/InternalPrintDyn.xml"

    public static let calibrationStatePath = "/Calibration/State", calibrationSessionPath = "/Calibration/Session"

    /// DiscoveryTree `SupportedIfc` types (seen in published HP inkjet trees).
    public static let internalPrintManifest = "ledm:hpLedmInternalPrintManifest", calibrationManifest = "ledm:hpCnxCalibrationManifest"

    private static let declaration = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>"

    /// `<ipdyn:InternalPrintDyn><ipdyn:JobType>…</ipdyn:JobType></ipdyn:InternalPrintDyn>`, the body HP's own web page posts
    /// (as captured by hp-printer-maintenance and pqdiag). Only job types in `MaintenanceCatalog.knownJobTypes`: nothing a
    /// printer sends back is ever echoed into a request.
    public static func internalPrint(_ jobType: String) throws -> String {
        guard MaintenanceCatalog.knownJobTypes.contains(jobType) else { throw UnknownJobType(jobType: jobType) }
        return declaration + "<ipdyn:InternalPrintDyn xmlns:ipdyn=\"\(internalPrintDynNs)\"><ipdyn:JobType>\(jobType)</ipdyn:JobType></ipdyn:InternalPrintDyn>"
    }

    /// `<cal:CalibrationState>Printing</cal:CalibrationState>`: start an alignment (HPLIP maint.py).
    public static func startAlignment() -> String {
        declaration + "<cal:CalibrationState xmlns:cal=\"\(calibrationNs)\">Printing</cal:CalibrationState>"
    }

    /// Job types an InternalPrintCap lists. Firmware spells the element `JobType`, `jobType` or `InternalPrintJobType`
    /// (hp-printer-maintenance), so any element whose local name ends in "JobType" counts.
    public static func parseJobTypes(_ cap: XmlElement) -> [String] {
        var types: [String] = []
        for e in elements(cap) where e.children.isEmpty && e.name.lowercased().hasSuffix("jobtype") {
            let v = e.value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !v.isEmpty && !types.contains(v) { types.append(v) }
        }
        return types
    }

    /// `dd:AlignmentMode` from ConsumableConfigDyn (automatic, semiAutomatic, manual); nil when absent.
    public static func parseAlignmentMode(_ consumableConfigDyn: XmlElement) -> String? {
        guard let e = elements(consumableConfigDyn).first(where: { $0.name == "AlignmentMode" }) else { return nil }
        let m = e.value.trimmingCharacters(in: .whitespacesAndNewlines)
        return m.isEmpty ? nil : m
    }

    /// Ink or toner, from the consumables' `ConsumableTypeEnum`.
    public static func parseMarking(_ consumableConfigDyn: XmlElement) -> Marking {
        fromKinds(elements(consumableConfigDyn).filter { $0.name == "ConsumableTypeEnum" }.map(\.value))
    }

    /// Ink or toner from supply kinds (LEDM `ConsumableTypeEnum`, IPP `marker-types`); toner wins a mix.
    public static func fromKinds(_ kinds: some Sequence<String>) -> Marking {
        let list = kinds.map { $0.lowercased() }.filter { !$0.hasPrefix("waste") }
        if list.contains(where: { $0.contains("toner") }) { return .toner }
        if list.contains(where: { $0.contains("ink") }) { return .ink }
        return .unknown
    }

    /// What the calibration state says about starting an alignment. HPLIP base/maint.py refuses on "Printing" (one is
    /// under way) and on "ParmsRequested" (an earlier session still waits for its parameters: restart the printer);
    /// hp-printer-maintenance names "Scanning" for the scanner-based step.
    public static func readCalibration(_ state: XmlElement) -> CalibrationStatus {
        let all = elements(state)
        func leafValue(_ e: XmlElement) -> String? { e.children.isEmpty ? e.value.trimmingCharacters(in: .whitespacesAndNewlines) : nil }
        if all.contains(where: { $0.name == "ParmsRequested" || leafValue($0) == "ParmsRequested" }) { return .awaitingParameters }
        let running = all.contains { e in
            (e.name == "CalibrationState" || e.name == "State") && (leafValue(e) == "Printing" || leafValue(e) == "Scanning")
        }
        return running ? .running : .idle
    }

    /// The element and all its descendants, in document order.
    private static func elements(_ root: XmlElement) -> [XmlElement] {
        var found: [XmlElement] = []
        var stack = [root]
        while let e = stack.popLast() {
            found.append(e)
            stack.append(contentsOf: e.children.reversed())
        }
        return found
    }
}

/// What `/Calibration/State` says about starting an alignment now.
public enum CalibrationStatus: Sendable { case idle, running, awaitingParameters }
