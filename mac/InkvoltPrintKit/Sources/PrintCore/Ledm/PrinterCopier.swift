import Foundation

/// The outcome of asking the printer to copy: nil `problem` when it took the request.
public struct PrinterCopyResult: Equatable, Sendable {
    public var problem: String?

    public var ok: Bool { problem == nil }
}

/// The printer's own copier over LEDM (`LedmCopy`; Windows' `PrinterCopier`): found by reading only, and started by one PUT
/// of the start setting alone, sent exactly once (never retried: a copy sent twice uses paper twice) over HTTPS, so an admin
/// password never crosses in clear text. The printer copies with the settings on its control panel; nothing else on it is
/// changed. No macOS queue is involved.
public final class PrinterCopier: Sendable {
    private let ledm: LedmClient

    /// Where the printer's start setting is and the command written to it.
    public let start: CopyStart

    private init(_ ledm: LedmClient, _ start: CopyStart) {
        self.ledm = ledm
        self.start = start
    }

    /// The copier when the printer's tree lists the copy documents and they offer a start (GETs only); nil otherwise, also
    /// when a document can't be read.
    public static func detect(_ connection: PrinterConnection) async -> PrinterCopier? {
        guard let ledm = connection.ledm else { return nil }
        do {
            guard let tree = try await ledm.tree(), LedmCopy.listed(tree) else { return nil }
            let cap = try await ledm.get(LedmCopy.capResource)
            guard let dyn = try await ledm.get(LedmCopy.dynResource), let start = LedmCopy.read(dyn, cap) else { return nil }
            return PrinterCopier(ledm, start)
        } catch {
            return nil
        }
    }

    /// Reads the copy settings again, then sends the one PUT that starts the copy. Throws `LedmAuthRequiredError` on 401/403
    /// so the caller can ask for the admin password.
    public func copy() async throws -> PrinterCopyResult {
        let path: String
        let body: String
        do {
            guard let dynPath = try await ledm.tree()?.uri(for: LedmCopy.dynResource), let dyn = try await ledm.get(LedmCopy.dynResource) else {
                return PrinterCopyResult(problem: Self.notOffered)
            }
            path = dynPath
            body = try LedmCopy.build(dyn, start)
        } catch where DeviceFailure.isOffline(error) || DeviceFailure.isTransient(error) || error is CopyShapeChanged {
            // Nothing was sent: the settings couldn't be read, or no longer have the shape the start was found in.
            return PrinterCopyResult(problem: loc("Not sent: the printer's copy settings couldn't be read. Try again, or copy from the printer's control panel."))
        }

        do {
            try await ledm.putOnce(path: path, body)
            return PrinterCopyResult(problem: nil)
        } catch let refusal as DeviceHttpError {
            switch refusal.status {
            case 404, 405, 501: return PrinterCopyResult(problem: Self.notOffered)
            case 409, 503, 429: return PrinterCopyResult(problem: loc("The printer is busy and didn't start the copy. Try again when it's idle."))
            default: return PrinterCopyResult(problem: loc("The printer turned the copy down. Copy from its control panel instead."))
            }
        } catch let lost as DeviceNetworkError {
            // Sent, then no answer: the printer may be copying. Saying so keeps a copy from being sent twice.
            return PrinterCopyResult(problem: MaintenanceClient.neverSent(lost)
                ?? loc("The printer didn't answer, so it may already be copying. Check its control panel before copying again."))
        }
    }

    private static var notOffered: String {
        loc("The printer doesn't take copy requests from apps after all. Copy from its control panel instead.")
    }
}
