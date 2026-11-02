import Foundation

/// One read of every printer: the entries and what couldn't be read for the list as a whole (the Windows app's `FleetRead`).
public struct FleetRead: Sendable {
    public var printers: [FleetPrinter]
    public var notes: [String]

    public init(_ printers: [FleetPrinter], _ notes: [String] = []) {
        self.printers = printers
        self.notes = notes
    }
}

/// `status --all [--json] [--out file]`, for a script or a scheduled task (Inkvolt Pro): reads every printer once and writes
/// the list, most trouble first, as JSON (`print/schemas/fleet-status.schema.json`) or a line per printer (the Windows app's
/// `FleetCommand`). The reading is the caller's (`read`): on the Mac, PrintMac's queues and the printer readers; the tests
/// pass made-up reads. Exit codes are Inkvolt PDF's: a printer in trouble is what the report says, not a failure; `someFailed`
/// means the report couldn't be written.
public enum FleetCommand {
    public static let done: Int32 = 0, someFailed: Int32 = 1, wrong: Int32 = 2, stopped: Int32 = 3

    static let usage = "Usage: inkvoltprint status --all [--json] [--out file]"

    /// What the command wrote: its exit code, standard output and standard error.
    public struct Result: Equatable, Sendable {
        public var code: Int32
        public var output: String
        public var error: String
    }

    /// The arguments ask for this command, not for a window: the first one past the demo's own switches is `status`.
    public static func isFor(_ args: [String]) -> Bool {
        args.first { !["--demo", "--no-printers", "--pro-enforce"].contains($0) } == "status"
    }

    public static func run(_ args: [String], read: @Sendable () async throws -> FleetRead, now: () -> Date, _ who: Diagnostics.Identity,
                           timeZone: TimeZone = .current) async -> Result {
        guard Pro.allows(.fleetExport) else {
            return Result(code: wrong, output: "", error: Pro.locked(.fleetExport) + "\n" + Pro.howToGet + "\n")
        }
        var all = false, json = false
        var file: String?
        let rest = Array(args.filter { $0 != "--demo" }.dropFirst())
        var i = 0
        while i < rest.count {
            switch rest[i] {
            case "--all": all = true
            case "--json": json = true
            case "--out" where i + 1 < rest.count && !rest[i + 1].hasPrefix("--"):
                file = rest[i + 1]
                i += 1
            default:
                return Result(code: wrong, output: "", error: usage + "\n")
            }
            i += 1
        }
        guard all else { return Result(code: wrong, output: "", error: usage + "\n") }

        let fleet: FleetRead
        do {
            fleet = try await read()
        } catch is CancellationError {
            return Result(code: stopped, output: "", error: "Stopped before every printer was read; nothing was written.\n")
        } catch {
            return Result(code: someFailed, output: "", error: "Could not read the printers: \(error)\n")
        }
        if Task.isCancelled { return Result(code: stopped, output: "", error: "Stopped before every printer was read; nothing was written.\n") }
        let at = now()
        let text = json ? FleetExport.json(fleet.printers, fleet.notes, at, who, timeZone: timeZone) + "\n" : lines(fleet, at, who, timeZone)
        guard let file else { return Result(code: done, output: text, error: "") }
        do {
            try writeWhole(file, text)
            return Result(code: done, output: "", error: "")
        } catch {
            return Result(code: someFailed, output: "", error: "Could not write \(file): \(error.localizedDescription)\n")
        }
    }

    /// A line per printer: what a person reads in a terminal.
    private static func lines(_ fleet: FleetRead, _ now: Date, _ who: Diagnostics.Identity, _ timeZone: TimeZone) -> String {
        let printers = fleet.printers.map { FleetExport.scrubbed($0, who) }
        var lines = FleetPage.summary(printers) + "\n"
        for row in FleetPage.rows(printers, now, timeZone: timeZone) {
            let supplies = row.supplies.isEmpty ? row.noSuppliesText ?? "" : row.supplies.map(\.text).joined(separator: ", ")
            lines += [row.printer.name, row.statusLine, supplies, row.pagesText, row.firmwareText, row.lastReadText].joined(separator: " | ") + "\n"
        }
        for note in fleet.notes { lines += note + "\n" }
        return lines
    }

    /// Written beside the file and moved over it, so a script never reads half a report.
    private static func writeWhole(_ file: String, _ text: String) throws {
        let target = URL(fileURLWithPath: file)
        let temporary = target.deletingLastPathComponent().appendingPathComponent("\(target.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try Data(text.utf8).write(to: temporary)
            if FileManager.default.fileExists(atPath: target.path) {
                #if canImport(Darwin)
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
                #else
                // The tests on the Windows PC: its Foundation has no replaceItemAt.
                try FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: temporary, to: target)
                #endif
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }
}
