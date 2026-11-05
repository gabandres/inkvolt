import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// `status --all`: its arguments, its output, the file it writes and the Pro gate in front of it. Ported from FleetReadTests.cs,
/// its command tests, with the same names; under `ProGated`, since they read the gate. Adapted: the Windows tests read the
/// demo PC through the real readers; here the read is a made-up list in the same trouble mix (the Mac's reading is PrintMac's,
/// with the Mac's half of 2.6). The reader's own tests (hung and vanishing printers, cupsd, the scanners) and Fix all's are
/// FleetReadTests.
extension ProGated {
@Suite final class FleetCommandTests {
    init() {
        Pro.store = MemoryProStore()
        Pro.enforced = false
    }

    deinit {
        Pro.store = MemoryProStore()
        Pro.enforced = false
    }

    private static let inOrder = ["Jam", "Demo inkjet", "Front desk on demo-mac", "Off", "Laser"]

    private static func fleet() -> FleetRead {
        var shared = FleetFacts("q", "Front desk on demo-mac", .queue)
        shared.reachable = true
        shared.status = FleetTests.status("Ready")
        shared.connection = FleetConnection.shared
        shared.supplies = [FleetTests.supply("Black", 4, "low")]
        return FleetRead([
            FleetTests.printer("Laser", supplies: [FleetTests.supply("Black", 42)], pages: 12345, firmware: "2024-08-13", read: FleetTests.now),
            FleetTests.printer("Off", reachable: false),
            FleetPrinter.of(shared),
            FleetTests.printer("Demo inkjet", supplies: [FleetTests.supply("Cyan", 6, "low", color: "C")]),
            FleetTests.printer("Jam", status: FleetTests.status("Paper jam", .error)),
        ], ["The Mac's scanners couldn't be read."])
    }

    private static func status(_ args: String..., read: (@Sendable () async throws -> FleetRead)? = nil) async -> FleetCommand.Result {
        await FleetCommand.run(args, read: read ?? { fleet() }, now: { FleetTests.now }, FleetTests.me, timeZone: FleetTests.utc)
    }

    @Test func Status_all_json_writes_the_list_in_trouble_order_to_standard_output() async throws {
        let result = await Self.status("status", "--all", "--json")

        #expect(result.code == FleetCommand.done)
        #expect(result.error == "")
        guard case .array(let printers)? = try JsonValue.parse(result.output)["printers"] else { Issue.record("no printers"); return }
        // What leaves the Mac doesn't name the other computer a queue is shared from.
        #expect(printers.map { $0["name"]?.string } == Self.inOrder.map { $0 == "Front desk on demo-mac" ? "Front desk on [pc]" : $0 })
    }

    @Test func Status_all_without_json_writes_a_line_per_printer() async {
        let result = await Self.status("status", "--all")

        #expect(result.code == FleetCommand.done)
        let lines = result.output.components(separatedBy: "\n").filter { !$0.isEmpty }
        #expect(lines[0].hasPrefix("5 printers:"))
        #expect(lines[1].contains("Jam"))
        #expect(lines[2].contains("Demo inkjet"))
        #expect(lines.last == "The Mac's scanners couldn't be read.")
    }

    @Test func Status_all_out_writes_the_file_whole() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-fleet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("fleet.json").path

        let result = await Self.status("status", "--all", "--json", "--out", file)
        #expect(result.code == FleetCommand.done)
        #expect(result.output == "")
        guard case .array(let printers)? = try JsonValue.parse(String(decoding: try Data(contentsOf: URL(fileURLWithPath: file)), as: UTF8.self))["printers"] else {
            Issue.record("no printers")
            return
        }
        #expect(printers.count == 5)
        // Written again over the first: still whole, and no temporary file left.
        #expect(await Self.status("status", "--all", "--json", "--out", file).code == FleetCommand.done)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["fleet.json"])

        let failed = await Self.status("status", "--all", "--json", "--out", folder.appendingPathComponent("no/such/folder.json").path)
        #expect(failed.code == FleetCommand.someFailed)
        #expect(failed.error.contains("Could not write"))
    }

    @Test(arguments: [["status"], ["status", "--json"], ["status", "--all", "--bad"], ["status", "--all", "--out"]])
    func Status_with_the_wrong_arguments_says_how_and_reads_nothing(_ args: [String]) async {
        let reads = Mutex(0)
        let result = await FleetCommand.run(args, read: { reads.withLock { $0 += 1 }; return Self.fleet() }, now: { FleetTests.now }, FleetTests.me)

        #expect(result.code == FleetCommand.wrong)
        #expect(result.output == "")
        #expect(result.error.contains("status --all"))
        #expect(reads.withLock { $0 } == 0)
    }

    @Test(arguments: [
        (["status", "--all", "--json"], true), (["--demo", "status", "--all"], true), (["--demo", "--pro-enforce", "status", "--all"], true),
        (["--demo", "--no-printers", "status", "--all"], true), (["status"], true), (["status.pdf"], false), (["--snapshot", "status"], false),
        ([], false),
    ])
    func The_app_tells_the_command_from_a_file_to_open(_ args: [String], _ expected: Bool) {
        #expect(FleetCommand.isFor(args) == expected)
    }

    @Test func Without_a_licence_status_all_says_where_to_get_one_and_reads_nothing() async {
        Pro.enforced = true
        let reads = Mutex(0)

        let result = await FleetCommand.run(["status", "--all", "--json"], read: { reads.withLock { $0 += 1 }; return Self.fleet() },
                                            now: { FleetTests.now }, FleetTests.me)

        #expect(result.code == FleetCommand.wrong)
        #expect(result.output == "")
        #expect(result.error.contains(Pro.locked(.fleetExport)))
        #expect(result.error.contains(Pro.buyUrl))
        #expect(reads.withLock { $0 } == 0)
    }

    @Test func Stopped_partway_says_so() async {
        let result = await Self.status("status", "--all") { throw CancellationError() }

        #expect(result.code == FleetCommand.stopped)
        #expect(result.output == "")
    }

    @Test func The_export_is_behind_the_same_gate() {
        Pro.enforced = false
        #expect(FleetExport.allowed)
        Pro.enforced = true
        #expect(!FleetExport.allowed)
    }
}
}
