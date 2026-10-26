import Foundation

/// The outcome of one maintenance request, in words for the card.
public struct MaintenanceResult: Equatable, Sendable {
    public let ok: Bool
    public let message: String

    public init(_ ok: Bool, _ message: String) {
        self.ok = ok
        self.message = message
    }
}

/// Finds a printer's maintenance actions (reads only: GETs and IPP Get-Printer-Attributes) and sends one when asked. A
/// request is sent exactly once, never retried: a cleaning sent twice uses ink twice.
public struct MaintenanceClient: Sendable {
    /// What Get-Printer-Attributes asks for: Identify-Printer support and the printer's maintenance page.
    public static let ippAttributes = ["operations-supported", "identify-actions-supported", "identify-actions-default", "printer-supply-info-uri",
                                       "marker-types"]

    static let postTimeout: Duration = .seconds(15)

    public let connection: PrinterConnection
    /// Identify-Printer's `requesting-user-name` (the Mac user's name); nil leaves it out.
    public let userName: String?

    public init(_ connection: PrinterConnection, userName: String? = nil) {
        self.connection = connection
        self.userName = userName
    }

    private var http: DeviceHttp { connection.http }

    /// Throws only what isn't the printer's doing (cancellation); a printer that doesn't answer or answers garbage offers less.
    public func detect() async throws -> MaintenanceOptions {
        async let ledm = readLedm()
        async let ipp = readIpp()
        var l = try await ledm
        let attributes = try await ipp
        if l.marking == .unknown, let attributes { l.marking = MaintenanceRequests.fromKinds(attributes.strs("marker-types")) }
        return MaintenanceCatalog.detect(MaintenanceSources(
            host: http.host, hasLedm: l.hasLedm, hasCdm: connection.cdm != nil, hasSnmp: connection.snmp != nil, ledmJobTypes: l.jobs,
            ledmDynPath: l.dynPath, alignmentMode: l.alignment, ipp: attributes, marking: l.marking))
    }

    private struct LedmFindings {
        var hasLedm = false
        var jobs: [String]?
        var dynPath: String?
        var alignment: String?
        var marking: Marking = .unknown
    }

    private func readLedm() async throws -> LedmFindings {
        guard let ledm = connection.ledm, let tree = try await Self.attempt({ try await ledm.tree() }) else { return LedmFindings() }

        // Paths from the InternalPrint manifest when the tree lists one, else HPLIP's fixed paths (a 404 there means none).
        var capPath = MaintenanceRequests.internalPrintCapPath, dynPath = MaintenanceRequests.internalPrintDynPath
        if let manifestPath = tree.manifest(for: MaintenanceRequests.internalPrintManifest),
           let manifest = try await Self.attempt({ try await ledm.get(path: manifestPath) }) {
            let entries = LedmManifest.entries(manifest)
            capPath = entries.first { $0.type.hasSuffix("InternalPrintCap") }?.path ?? capPath
            dynPath = entries.first { $0.type.hasSuffix("InternalPrintDyn") }?.path ?? dynPath
        }
        async let consumables = Self.attempt { try await ledm.get(LedmResource.consumableConfigDyn) }
        let readCap = capPath
        let cap = try await Self.attempt { try await ledm.get(path: readCap) }
        let jobs = cap.map(MaintenanceRequests.parseJobTypes)
        let cc = try await consumables
        let alignment = tree.manifest(for: MaintenanceRequests.calibrationManifest) != nil ? cc.flatMap(MaintenanceRequests.parseAlignmentMode) : nil
        return LedmFindings(hasLedm: true, jobs: jobs?.isEmpty == false ? jobs : nil, dynPath: dynPath, alignment: alignment,
                            marking: cc.map(MaintenanceRequests.parseMarking) ?? .unknown)
    }

    private func readIpp() async throws -> IppResponse? {
        guard let ipp = connection.ipp, let r = try await Self.attempt({ try await ipp.printerAttributes(Self.ippAttributes) }), r.ok else { return nil }
        return r
    }

    /// Sends the action once. LEDM requests go over HTTPS (the admin password, when the printer has one, never crosses in
    /// clear text) and throw `LedmAuthRequiredError` on 401/403 so the caller can ask for it (then `DeviceHttp.setCredentials`
    /// and run it again).
    public func run(_ action: MaintenanceAction) async throws -> MaintenanceResult {
        do {
            switch action.kind {
            case .identify: return try await identify(action)
            case .alignment: return try await align(action)
            default:
                guard let job = action.jobType, let target = action.target else {
                    return MaintenanceResult(false, "The printer doesn't offer this to apps after all. Use its control panel or web page.")
                }
                return try await postLedm(action, target, try MaintenanceRequests.internalPrint(job))
            }
        } catch let error as DeviceNetworkError {
            if let why = Self.neverSent(error) { return MaintenanceResult(false, why) }
            // Sent, then no answer: the printer may well be doing it. Saying so keeps a cleaning from being sent twice.
            return MaintenanceResult(false, "The printer didn't answer, so the request may have started anyway. Check the printer before trying again.")
        }
    }

    /// Why this request's own failure proves nothing reached the printer, or nil when it may have. Writes go on a connection
    /// of their own (`DeviceHttp.sendOnce`), so a refused connection happened before a byte of the request was sent. Decided
    /// from the error alone: `DeviceHttp.certificateChanged` is sticky and shared by every port. A failed TLS handshake is
    /// `DeviceNetworkError.failed` like a lost answer, so it counts as maybe sent (the Windows app can tell them apart).
    static func neverSent(_ error: DeviceNetworkError) -> String? {
        switch error {
        case .refused: "Not sent: the printer refused the connection. Check that it's on, then try again."
        case .timedOut, .failed: nil
        }
    }

    private func align(_ action: MaintenanceAction) async throws -> MaintenanceResult {
        if let ledm = connection.ledm, let state = try await Self.attempt({ try await ledm.get(path: MaintenanceRequests.calibrationStatePath) }) {
            switch MaintenanceRequests.readCalibration(state) {
            case .running:
                return MaintenanceResult(false, "An alignment is already under way on the printer. Finish it there first.")
            case .awaitingParameters:
                // HPLIP base/maint.py: "ParmsRequested" → "Restart device and start alignment".
                return MaintenanceResult(false, "An earlier alignment is still waiting to be finished on the printer. Finish it on the "
                    + "printer's control panel, or turn the printer off and on again, then try again.")
            case .idle:
                break
            }
        }
        return try await postLedm(action, action.target ?? MaintenanceRequests.calibrationSessionPath, MaintenanceRequests.startAlignment())
    }

    private func postLedm(_ action: MaintenanceAction, _ path: String, _ body: String) async throws -> MaintenanceResult {
        let target = http.https(path)
        // Newer HP web servers (nginx) check these against cross-site requests (hp-printer-maintenance, ews.py _post_xml).
        var origin = http.httpsBase.absoluteString
        while origin.hasSuffix("/") { origin.removeLast() }
        let request = HttpRequest("POST", target, headers: [
            "Content-Type": "text/xml; charset=utf-8",
            "Origin": origin,
            "Referer": origin + "/",
            "X-Requested-With": "XMLHttpRequest",
        ], body: Array(body.utf8), timeout: Self.postTimeout)
        let response = try await http.sendOnce(request)
        switch response.status {
        case 401, 403: throw LedmAuthRequiredError(credentialsWereSent: http.hasCredentials)
        case 200..<300: return MaintenanceResult(true, action.sent)
        case 404, 405, 501: return MaintenanceResult(false, "The printer doesn't offer this to apps after all. Use its control panel or web page.")
        case 409, 503, 429: return MaintenanceResult(false, "The printer is busy and didn't start it. Try again when it's idle.")
        case let s: return MaintenanceResult(false, "The printer refused it (HTTP \(s)).")
        }
    }

    private func identify(_ action: MaintenanceAction) async throws -> MaintenanceResult {
        guard let ipp = connection.ipp else { return MaintenanceResult(false, "The printer doesn't answer IPP any more.") }
        let r: IppResponse
        do {
            r = try await ipp.identifyPrinter(actions: action.identifyActions, userName: userName)
        } catch let error as DeviceHttpError {
            return MaintenanceResult(false, "The printer refused it (\(error)).")
        } catch let error as IppFormatError {
            return MaintenanceResult(false, "The printer refused it (\(error)).")
        }
        switch r.statusCode {
        case ..<0x0100: return MaintenanceResult(true, action.sent)
        // PWG 5100.13 §4.1: a printer SHOULD ask for an authenticated user and answers with one of these when it does.
        case 0x0401, 0x0402, 0x0403: return MaintenanceResult(false, "The printer only does this for a signed-in user. Use its control panel or web page.")
        case 0x0501: return MaintenanceResult(false, "The printer doesn't offer this after all.")
        case let s: return MaintenanceResult(false, "The printer refused it (IPP status 0x\(String(format: "%04X", Int(s)))).")
        }
    }

    /// A read that may fail: nil when the printer doesn't answer, answers with an error or sends something unreadable.
    private static func attempt<T: Sendable>(_ read: () async throws -> T?) async throws -> T? {
        do {
            return try await read()
        } catch where DeviceFailure.isOffline(error) || DeviceFailure.isTransient(error) {
            return nil
        }
    }
}
