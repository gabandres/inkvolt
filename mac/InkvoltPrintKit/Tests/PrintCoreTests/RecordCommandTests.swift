import Foundation
import Testing
@testable import PrintCore

/// `record <address> <folder>` as the Mac app's `--report` runs it (`--record`). Windows' developer CLI has no tests of its
/// own (Program.cs's `Record`); these check what the Mac adds: the folder is a plain name inside the app's own folder, a
/// folder already holding files is left alone without `--force`, and what it prints masks the address.
struct RecordCommandTests {
    private static let me = Diagnostics.Identity("jdoe", "JDOE-LAPTOP")

    private static func base() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-record-cmd-\(UUID().uuidString)", isDirectory: true)
    }

    /// The M234dw's fixtures answering at `at` (192.0.2.55 unless said: not the stand-in address a recording names).
    private static func demoLaser(at host: String = "192.0.2.55") -> HostRouter {
        let m234dw = Fixtures.root.appendingPathComponent("m234dw", isDirectory: true)
        return HostRouter([host: FixtureTransport(document: { name in
            FileManager.default.contents(atPath: m234dw.appendingPathComponent(name).path).map { Array($0) }
        })])
    }

    @Test func The_command_reads_its_address_folder_and_options_from_the_arguments() throws {
        let args = ["Inkvolt Print", "--report", "rec", "--record", "192.0.2.10", "laser", "--scan", "--community", "private",
                    "--escl", "http://192.0.2.10:8080/eSCL", "--ipp", "ipp://192.0.2.10/ipp/print", "--force"]
        let c = try #require(RecordCommand.parse(args, keyword: "--record"))
        #expect(c.host == "192.0.2.10")
        #expect(c.folder == "laser")
        #expect(c.scan && c.force)
        #expect(c.community == "private")
        #expect(c.esclHint?.absoluteString == "http://192.0.2.10:8080/eSCL")
        #expect(c.ippHint?.absoluteString == "ipp://192.0.2.10/ipp/print")
        #expect(RecordCommand.parse(["--report", "x"], keyword: "--record") == nil)
        let bare = try #require(RecordCommand.parse(["--record", "192.0.2.10"], keyword: "--record"))
        #expect(bare.community == SnmpClient.defaultCommunity && !bare.scan && bare.folder.isEmpty)
    }

    @Test func The_demo_laser_is_recorded_into_its_folder_and_what_is_said_masks_the_address() async throws {
        let base = Self.base()
        defer { try? FileManager.default.removeItem(at: base) }
        let lines = await RecordCommand(host: "192.0.2.55", folder: "laser").run(in: base, transport: Self.demoLaser(), snmp: nil, who: Self.me)

        #expect(lines.first?.hasPrefix("record: recorded HP LaserJet MFP M234dw (LEDM, CDM, eSCL) in ") == true, "\(lines)")
        #expect(lines.first?.hasSuffix("files in \(base.lastPathComponent)/laser") == true)
        #expect(lines.contains("  DevMgmt_ProductStatusDyn.xml"))
        #expect(lines.contains("  \(PrinterRecorder.notesFile)"))
        #expect(lines.contains { $0.hasPrefix("  scrubbed: ") })
        #expect(lines.last?.hasPrefix("  served as the printer at \(FixtureScrubber.defaultPlaceholderHost).") == true)
        #expect(!lines.joined().contains("192.0.2.55"))
        #expect(!lines.joined().contains(base.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: base.appendingPathComponent("laser").path)
        #expect(files.contains("DevMgmt_ProductStatusDyn.xml"))
    }

    @Test func A_folder_that_holds_files_is_left_alone_without_force() async throws {
        let base = Self.base()
        defer { try? FileManager.default.removeItem(at: base) }
        let folder = base.appendingPathComponent("mine", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("keep me".utf8).write(to: folder.appendingPathComponent("notes.txt"))

        let refused = await RecordCommand(host: "192.0.2.55", folder: "mine").run(in: base, transport: Self.demoLaser(), snmp: nil, who: Self.me)
        #expect(refused == ["record: \(base.lastPathComponent)/mine isn't empty: choose a new folder, or add --force to write into it."])
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == ["notes.txt"])

        var forced = RecordCommand(host: "192.0.2.55", folder: "mine")
        forced.force = true
        let lines = await forced.run(in: base, transport: Self.demoLaser(), snmp: nil, who: Self.me)
        #expect(lines.first?.hasPrefix("record: recorded ") == true)
        #expect(try String(contentsOf: folder.appendingPathComponent("notes.txt"), encoding: .utf8) == "keep me")
    }

    @Test(arguments: ["../out", "/tmp/out", "a/b", ".hidden", "..", "C:\\out", "a:b", ""])
    func A_folder_that_isnt_a_plain_name_is_refused_and_nothing_is_asked(_ folder: String) async throws {
        let base = Self.base()
        defer { try? FileManager.default.removeItem(at: base) }
        let asked = FixtureTransport(document: { _ in Issue.record("the printer was asked"); return nil })
        let lines = await RecordCommand(host: FixtureTransport.demoHost, folder: folder).run(in: base, transport: asked, snmp: nil, who: Self.me)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix(folder.isEmpty ? "Usage: " : "record: "))
        #expect(!FileManager.default.fileExists(atPath: base.path))
    }

    @Test func Nothing_answering_says_so_without_the_address() async throws {
        let base = Self.base()
        defer { try? FileManager.default.removeItem(at: base) }
        let lines = await RecordCommand(host: "192.0.2.77", folder: "none").run(in: base, transport: FixtureTransport(document: { _ in nil }), snmp: nil,
                                                                               who: Self.me)
        #expect(lines.count == 1)
        #expect(lines[0].hasPrefix("record: Nothing recorded: "), "\(lines)")
        #expect(!lines[0].contains("192.0.2.77"))
    }
}
