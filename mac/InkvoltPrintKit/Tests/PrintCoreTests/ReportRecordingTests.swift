import Foundation
import Synchronization
import Testing
@testable import PrintCore

/// Help › Report a Problem's recording (roadmap 1.2): as `record`, through the demo's and the tests' fixtures. No printer.
/// Ported from ReportRecordingTests.cs with the same names.
struct ReportRecordingTests {
    private static let host = "10.20.30.40"
    private static let me = Diagnostics.Identity("jdoe", "JDOE-LAPTOP")
    private static let now: Date = {
        var c = DateComponents(year: 2026, month: 11, day: 1, hour: 17, minute: 30, second: 5)
        c.calendar = Calendar(identifier: .gregorian)
        c.timeZone = .current
        return c.date!
    }()

    /// A fresh parent folder for one test's recordings, removed by the caller.
    private static func parent() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-report-rec-\(UUID().uuidString)", isDirectory: true)
    }

    private static func fixtureDir(_ name: String) -> URL { Fixtures.root.appendingPathComponent(name, isDirectory: true) }

    private static func read(_ dir: URL, _ name: String) -> [UInt8]? {
        FileManager.default.contents(atPath: dir.appendingPathComponent(name).path).map { Array($0) }
    }

    private static func entries(_ dir: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }

    private static func at(_ host: String, _ printer: any HttpTransport) -> HostRouter { HostRouter([host: printer]) }

    private static func planted() -> FixtureTransport {
        let m234dw = fixtureDir("m234dw")
        return FixtureTransport(document: { name in
            if name == "ipp_print.ipp.txt" { return Array(RecordingTests.plantedIpp.utf8) }
            guard let bytes = read(m234dw, name) else { return nil }
            return Array(RecordingTests.plant(name, String(decoding: bytes, as: UTF8.self)).utf8)
        })
    }

    private static func options(_ printer: any HttpTransport) throws -> RecordOptions {
        var o = RecordOptions(transport: at(host, printer), snmp: SnmpAgent(try SnmpAgent.parseWalk(RecordingTests.plantedWalk())))
        o.who = me
        return o
    }

    private static func plain(_ transport: any HttpTransport) -> RecordOptions {
        var o = RecordOptions(transport: transport)
        o.who = me
        return o
    }

    @Test func The_report_path_scrubs_as_the_command_does_in_the_folder_the_zip_and_the_line_copied() async throws {
        let parent = Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let done = try await ReportRecording.run(Self.host, parent: parent, try Self.options(Self.planted()), now: Self.now)

        #expect(done.folder == parent.appendingPathComponent("printer-recording-20261101-173005", isDirectory: true))
        #expect(done.zip.lastPathComponent == done.folder.lastPathComponent + ".zip")
        #expect(done.zip.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
        #expect(done.result.files.count > 5)
        for file in Self.entries(done.folder) {
            Self.assertClean(file, String(decoding: Self.read(done.folder, file) ?? [], as: UTF8.self))
        }

        let zip = try ZipArchive.entries(Array(try Data(contentsOf: done.zip)))
        #expect(done.result.files.sorted() == zip.map(\.name).sorted())
        for entry in zip { Self.assertClean(entry.name, String(decoding: entry.bytes, as: UTF8.self)) }

        let line = ReportRecording.reportLine(done, Self.me)
        Self.assertClean("the line", line)
        #expect(line.contains("HP LaserJet MFP M234dw"))
        #expect(line.contains("printer-recording-20261101-173005.zip"))
        #expect(!line.contains(parent.path))
    }

    private static func assertClean(_ place: String, _ text: String) {
        for planted in RecordingTests.planted {
            #expect(text.range(of: planted, options: .caseInsensitive) == nil, "\(planted) left in \(place)")
        }
    }

    @Test func The_demo_printer_records_and_reads_back_with_no_printer_on_this_pc() async throws {
        let parent = Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let host = FixtureTransport.demoHost
        let m234dw = Self.fixtureDir("m234dw")
        let done = try await ReportRecording.run(host, parent: parent, Self.plain(Self.at(host, FixtureTransport(document: { Self.read(m234dw, $0) }))),
                                                 now: Self.now)
        #expect(done.result.model == "HP LaserJet MFP M234dw")
        #expect(done.result.files.contains("DevMgmt_ProductStatusDyn.xml"))
        #expect(done.result.files.contains(PrinterRecorder.notesFile))
        #expect(!done.result.files.contains { $0.hasSuffix(".jpg") }) // never scans, whatever asked
    }

    @Test func It_never_scans_even_if_the_options_say_so() async throws {
        let parent = Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        var options = try Self.options(Self.planted())
        options.scan = true
        let done = try await ReportRecording.run(Self.host, parent: parent, options, now: Self.now)
        #expect(!done.result.files.contains { $0.lowercased().hasSuffix(".jpg") })
    }

    @Test func Two_recordings_in_one_second_get_their_own_folders() async throws {
        let parent = Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let first = try await ReportRecording.run(Self.host, parent: parent, try Self.options(Self.planted()), now: Self.now)
        let second = try await ReportRecording.run(Self.host, parent: parent, try Self.options(Self.planted()), now: Self.now)
        #expect(first.folder != second.folder)
        #expect(FileManager.default.fileExists(atPath: first.zip.path))
        #expect(FileManager.default.fileExists(atPath: second.zip.path))
    }

    @Test func What_a_printer_calls_itself_doesnt_name_the_folder() async throws {
        let parent = Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let m234dw = Self.fixtureDir("m234dw")
        let hostile = FixtureTransport(document: { name in
            guard let bytes = Self.read(m234dw, name) else { return nil }
            return Array(String(decoding: bytes, as: UTF8.self).replacingOccurrences(of: "HP LaserJet MFP M234dw", with: "../../LaunchAgents/evil").utf8)
        })
        let done = try await ReportRecording.run(Self.host, parent: parent, try Self.options(hostile), now: Self.now)
        #expect(done.folder.deletingLastPathComponent().standardizedFileURL == parent.standardizedFileURL)
        let folders = Self.entries(parent).filter { !$0.hasSuffix(".zip") }
        #expect(folders == [done.folder.lastPathComponent])
    }

    @Test func Nothing_answering_leaves_nothing_and_the_message_doesnt_quote_the_address() async throws {
        let parent = Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let empty = FixtureTransport(document: { _ in nil })
        var failure: (any Error)?
        do {
            _ = try await ReportRecording.run(Self.host, parent: parent, Self.plain(Self.at(Self.host, empty)), now: Self.now)
        } catch {
            failure = error
        }
        #expect(failure is RecordingError)
        #expect(Self.entries(parent).isEmpty)
        let text = ReportRecording.failureText(try #require(failure), Self.me)
        #expect(text.hasPrefix("Nothing recorded: "))
        #expect(!text.contains(Self.host))
    }

    @Test func Cancelling_leaves_nothing() async throws {
        let parent = Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let options = try Self.options(Self.planted())
        let task = Task { try await ReportRecording.run(Self.host, parent: parent, options, now: Self.now) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Self.entries(parent).isEmpty)
    }

    // MARK: Names a printer's discovery tree can make the recorder ask for

    @Test(arguments: [
        ("/DevMgmt/ProductStatusDyn.xml", "DevMgmt_ProductStatusDyn.xml"),
        ("/cdm/system/v1/identity", "cdm_system_v1_identity.json"),
        ("/eSCL/ScannerCapabilities", "eSCL_ScannerCapabilities.xml"),
        ("/C:/Windows/evil", "C__Windows_evil.xml"), // would be drive-relative on Windows
        ("/a:b.xml", "a_b.xml"), // a stream of file "a" on Windows; a colon Finder shows as a slash
        ("/x%5C..%5Cevil.xml", "x_5C.._5Cevil.xml"),
        ("/CON", "CON.xml"),
        ("/../../evil.xml", ".._.._evil.xml"),
    ])
    func A_replys_file_name_stays_a_plain_name_in_the_folder(_ path: String, _ name: String) {
        #expect(PrinterRecorder.keptName(path) == name)
        let folder = URL(fileURLWithPath: "/tmp/folder", isDirectory: true)
        let kept = folder.appendingPathComponent(PrinterRecorder.keptName(path) ?? "")
        #expect(kept.deletingLastPathComponent() == folder)
        #expect(kept.lastPathComponent == name)
    }

    @Test(arguments: [
        "/run.bat", "/page.hta", "/page.html", "/a.lnk", "/a.exe", "/a.ps1",
        "/a.command", "/a.sh", "/a.app", "/a.webloc", // what runs or opens something on a Mac
        "/recording.tsv", // the notes are ours
        "/snmp.txt", // so is the walk
        "/SNMP.TXT", // the same file on this disk
        "/.xml",
    ])
    func A_printer_cant_put_a_file_that_runs_or_ours_in_a_recording(_ path: String) {
        #expect(PrinterRecorder.keptName(path) == nil)
    }

    @Test(arguments: ["http://192.0.2.200/secret.xml", "//192.0.2.200/secret.xml"])
    func A_printer_cant_point_the_recorder_at_another_computer(_ href: String) async throws {
        let parent = Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let m234dw = Self.fixtureDir("m234dw")
        let tree = String(decoding: Self.read(m234dw, "DevMgmt_DiscoveryTree.xml") ?? [], as: UTF8.self)
            .replacingOccurrences(of: "/DevMgmt/ProductStatusDyn.xml", with: href)
        #expect(tree.contains(href))
        let printer = FixtureTransport(document: { name in name == "DevMgmt_DiscoveryTree.xml" ? Array(tree.utf8) : Self.read(m234dw, name) })
        let other = Mutex(false)
        let router = HostRouter([
            Self.host: printer,
            "192.0.2.200": FixtureTransport(document: { _ in
                other.withLock { $0 = true }
                return Array("<x>router admin page</x>".utf8)
            }),
        ])
        let done = try await ReportRecording.run(Self.host, parent: parent, Self.plain(router), now: Self.now)

        #expect(!other.withLock { $0 }, "the recording asked another computer")
        #expect(!done.result.files.contains { $0.range(of: "secret", options: .caseInsensitive) != nil })
    }

    @Test(arguments: [("/run.bat", "run.bat"), ("/C:/Users/Public/evil.xml", "C:_Users_Public_evil.xml")])
    func A_printer_pointing_the_recorder_at_a_strange_path_stays_in_the_folder_and_keeps_nothing_that_runs(_ href: String, _ served: String) async throws {
        // Its discovery tree says the status document is somewhere else: the app asks there, as it must to read the printer.
        let parent = Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let m234dw = Self.fixtureDir("m234dw")
        let tree = String(decoding: Self.read(m234dw, "DevMgmt_DiscoveryTree.xml") ?? [], as: UTF8.self)
            .replacingOccurrences(of: "/DevMgmt/ProductStatusDyn.xml", with: href)
        #expect(tree.contains(href))
        let asked = Mutex(false)
        let printer = FixtureTransport(document: { name in
            if name == "DevMgmt_DiscoveryTree.xml" { return Array(tree.utf8) }
            if name == served {
                asked.withLock { $0 = true }
                return Self.read(m234dw, "DevMgmt_ProductStatusDyn.xml")
            }
            return Self.read(m234dw, name)
        })
        let done = try await ReportRecording.run(Self.host, parent: parent, Self.plain(Self.at(Self.host, printer)), now: Self.now)

        #expect(asked.withLock { $0 })
        #expect(Self.entries(parent).filter { !$0.hasSuffix(".zip") } == [done.folder.lastPathComponent])
        for file in Self.entries(done.folder) {
            #expect([".xml", ".json", ".txt", ".tsv"].contains { file.hasSuffix($0) }, "\(file)")
        }
        #expect(!FileManager.default.fileExists(atPath: done.folder.appendingPathComponent("run.bat").path))
    }

    // MARK: The .zip (Mac: written by PrintCore, stored; Windows deflates through .NET's ZipFile)

    @Test func The_zip_holds_each_file_as_it_is_and_is_read_back_whole() throws {
        let files = [ZipArchive.Entry(name: "a.xml", bytes: Array("<a/>".utf8)), ZipArchive.Entry(name: "recording.tsv", bytes: []),
                     ZipArchive.Entry(name: "b.json", bytes: (0..<70_000).map { UInt8($0 % 251) })]
        let zip = try ZipArchive.stored(files, modified: Self.now)
        #expect(try ZipArchive.entries(zip) == files)
        #expect(zip.starts(with: [0x50, 0x4B, 0x03, 0x04]))
        // A byte changed in a file's data fails its CRC; a cut archive fails too.
        var damaged = zip
        damaged[36] ^= 0xFF // inside a.xml's data
        #expect(throws: ZipArchive.Damaged.self) { try ZipArchive.entries(damaged) }
        #expect(throws: ZipArchive.Damaged.self) { try ZipArchive.entries(Array(zip.prefix(zip.count - 10))) }
        #expect(throws: ZipArchive.Damaged.self) { try ZipArchive.entries([]) }
    }

    @Test func The_end_record_is_looked_for_only_where_a_comment_could_put_it() throws {
        let zip = try ZipArchive.stored([ZipArchive.Entry(name: "a.xml", bytes: Array("<a/>".utf8))], modified: Self.now)
        // Up to a 65,535-byte comment after it is still an archive; an end record further back than that isn't this one's.
        let commented = Array(zip.dropLast(2)) + [0xFF, 0xFF] + [UInt8](repeating: 0x20, count: 0xFFFF)
        #expect(try ZipArchive.entries(commented).map(\.name) == ["a.xml"])
        #expect(throws: ZipArchive.Damaged.self) { try ZipArchive.entries(zip + [UInt8](repeating: 0, count: 0x1_0000)) }
    }

    @Test func The_checksum_is_zips_crc_32() {
        #expect(Crc32.of(Array("123456789".utf8)) == 0xCBF4_3926)
        #expect(Crc32.of([]) == 0)
        #expect(Crc32.update(Crc32.update(0xFFFF_FFFF, Array("1234".utf8)), Array("56789".utf8)) ^ 0xFFFF_FFFF == 0xCBF4_3926)
    }

    @Test func A_recording_kept_after_the_window_closed_is_discarded_whole() async throws {
        let parent = Self.parent()
        defer { try? FileManager.default.removeItem(at: parent) }
        let done = try await ReportRecording.run(Self.host, parent: parent, try Self.options(Self.planted()), now: Self.now)
        #expect(Self.entries(parent).count == 2)
        ReportRecording.discard(done)
        #expect(Self.entries(parent).isEmpty)
    }
}
