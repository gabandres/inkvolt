import Foundation

/// A printer that answered CDM's identity: where (plain HTTP, or HTTPS when it sends HTTP there) and who it is.
public struct CdmProbe: Equatable, Sendable {
    public let root: URL
    public let identity: ProductInfo
}

/// HP CDM, read only (`CdmPaths`): identity, supplies and status of newer HP printers that have no LEDM. Only GETs are ever
/// sent: CDM also takes writes (resets, reboots, erases) that some firmware accepts without a password, so this client has
/// no way to send anything else.
public final class CdmClient: Sendable {
    public let http: DeviceHttp

    /// Scheme, host and port the printer answers CDM on.
    public let root: URL

    public init(_ http: DeviceHttp, root: URL) {
        self.http = http
        self.root = root
    }

    /// The identity over plain HTTP; over HTTPS (self-signed, pinned like the rest) when the printer redirects there or
    /// refuses plain HTTP. Nil when it isn't a CDM printer (404, 400 from older firmware, 401/403, or no identity in it).
    public static func probe(_ http: DeviceHttp) async throws -> CdmProbe? {
        for root in [http.httpBase, http.httpsBase] {
            let url = URL(string: CdmPaths.identity, relativeTo: root)!.absoluteURL
            let response: HttpResponse
            do {
                response = try await http.get(url)
            } catch DeviceNetworkError.refused where root == http.httpBase {
                continue // plain HTTP refused outright: some printers only answer HTTPS
            }
            if [301, 302, 307, 308].contains(response.status), root == http.httpBase, let to = response.header("Location"),
               URL(string: to).map({ $0.scheme == nil || $0.scheme == "https" }) == true {
                continue // to HTTPS on the same printer (the location's host is never followed)
            }
            guard response.isSuccess else { return nil }
            return CdmParsers.parseIdentity(response.text).map { CdmProbe(root: root, identity: $0) }
        }
        return nil
    }

    public func identity() async throws -> ProductInfo? { try await get(CdmPaths.identity).flatMap(CdmParsers.parseIdentity) }

    public func supplies() async throws -> [Consumable]? { try await get(CdmPaths.supplies).map(CdmParsers.parseSupplies) }

    /// System status, print status and alerts, one after the other (CDM printers time out under bursts of requests, as
    /// the Home Assistant clients found). Nil when the printer gives neither status.
    public func status() async throws -> PrinterStatus? {
        let system = try await get(CdmPaths.systemStatus)
        let print = system == nil ? try await get(CdmPaths.printStatus) : nil
        if system == nil && print == nil { return nil }
        let alerts = try await get(CdmPaths.alerts)
        return CdmParsers.parseStatus(system: system, print: print, alerts: alerts)
    }

    /// GET only: the body as text, nil when the printer doesn't have it (404, or 400 / 401 / 403 / 405 from firmware
    /// without it).
    private func get(_ path: String) async throws -> String? {
        let url = URL(string: path, relativeTo: root)!.absoluteURL
        let response = try await http.get(url)
        if [400, 401, 403, 404, 405].contains(response.status) { return nil }
        try DeviceHttp.ensureSuccess(response, "GET", url)
        return response.text
    }
}
