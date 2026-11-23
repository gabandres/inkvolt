import Foundation

/// Whether macOS shares a queue on the network (CUPS's `printer-is-shared`).
public enum QueueSharing: Equatable, Sendable {
    case shared
    case notShared
    /// cupsd didn't say.
    case notSaid
}

/// Share a printer with phones (roadmap 4.10) on the Mac: macOS's own Printer Sharing (System Settings › General › Sharing)
/// shares a CUPS queue over IPP and Bonjour, AirPrint included, and a sandboxed app may only point to it, so this reads what
/// cupsd says of each queue; Windows' `PrinterShare` serves its queues itself. No server of ours.
public enum PrinterSharing {
    /// A queue that can be shared (Windows' `CanShare`): not one that saves a file or hands the job to an app (`file:`, a PDF
    /// writer's backend), a fax, a class, another computer's queue (`remote`) or one macOS only saw on the network.
    public static func canShare(_ d: CupsDestination) -> Bool {
        if d.isTemporary || d.has(CupsDestination.TypeBit.fax) || d.has(CupsDestination.TypeBit.remote) || d.has(CupsDestination.TypeBit.class) {
            return false
        }
        guard let uri = d.deviceUri?.trimmingCharacters(in: .whitespaces), let colon = uri.firstIndex(of: ":") else { return false }
        let scheme = uri[..<colon].lowercased()
        return !(scheme == "file" || scheme.contains("pdf"))
    }

    /// What macOS says of a queue that can be shared; nil for one that can't.
    public static func state(_ d: CupsDestination) -> QueueSharing? {
        guard canShare(d) else { return nil }
        switch d.options["printer-is-shared"] {
        case "true": return .shared
        case "false": return .notShared
        default: return .notSaid
        }
    }
}
