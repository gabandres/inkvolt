import Foundation
import Testing
@testable import PrintCore

/// Ported from RecentScansTests.cs: recent scans (roadmap 4.15), the last saves newest first, a file saved again moved up
/// rather than listed twice, entries whose files are gone dropped when shown, and the list read back from the state file as
/// hostile input (`RecentScans`). Adapted: paths are the Mac's (`/Users/…`, `/Volumes/…`), a settings file is the state's JSON,
/// and an entry may carry its folder's or file's security bookmark (`access`, the sandbox's way back to it).
struct RecentScansTests {
    private static let noon = Date(timeIntervalSince1970: 1_795_348_800) // 2026-11-22 12:00 UTC

    private static func scan(_ file: String, minutes: Double = 0, pages: Int = 1) -> RecentScan {
        RecentScan(files: [file], savedAt: noon.addingTimeInterval(minutes * 60), pages: pages, printer: "Demo laser", preset: "Receipts")
    }

    @Test func newestFirstAndAtMostTwenty() {
        var list: [RecentScan] = []
        for i in 0..<25 { list = RecentScans.add(list, Self.scan("/Users/me/Scans/scan \(i).pdf", minutes: Double(i))) }
        #expect(list.count == RecentScans.max)
        #expect(list[0].name == "scan 24.pdf")
        #expect(list.last?.name == "scan 5.pdf")
    }

    @Test func aFileSavedAgainMovesToTheTopOnce() {
        var list = RecentScans.add([], Self.scan("/Users/me/Scans/a.pdf"))
        list = RecentScans.add(list, Self.scan("/Users/me/Scans/b.pdf", minutes: 1))
        list = RecentScans.add(list, Self.scan("/users/me/scans/A.PDF", minutes: 2, pages: 3))
        #expect(list.map(\.name) == ["A.PDF", "b.pdf"])
        #expect(list[0].pages == 3)
        // A batch sharing one of its files with an older entry replaces it too.
        list = RecentScans.add(list, RecentScan(files: ["/Users/me/Scans/b.pdf", "/Users/me/Scans/c.pdf"], savedAt: Self.noon, pages: 4))
        #expect(list.count == 2)
        #expect(list[0].files.count == 2)
    }

    @Test func goneFilesDropOutAndAnEntryWithNoneLeftGoes() {
        var list = RecentScans.add([], RecentScan(files: ["/Users/me/Scans/p (1).jpg", "/Users/me/Scans/p (2).jpg"], savedAt: Self.noon, pages: 2))
        list = RecentScans.add(list, Self.scan("/Volumes/Away/gone.pdf", minutes: 1))
        let there: Set<String> = ["/users/me/scans/p (2).jpg"]
        let shown = RecentScans.present(list) { there.contains($0.lowercased()) }
        #expect(shown.count == 1)
        #expect(shown[0].files == ["/Users/me/Scans/p (2).jpg"])
        #expect(!shown[0].isPdf)
        // A check that throws (a share that refuses) counts as gone, never as an error.
        struct Refused: Error {}
        #expect(RecentScans.present(list) { _ in throw Refused() }.isEmpty)
    }

    @Test func droppingTheFilesFoundMissingKeepsAScanSavedSince() {
        let before = RecentScans.add([], Self.scan("/Users/me/Scans/gone.pdf"))
        let gone: Set<String> = ["/Users/me/Scans/gone.pdf"]
        let now = RecentScans.add(before, Self.scan("/Users/me/Scans/new.pdf", minutes: 1)) // saved while the disk was being checked
        #expect(RecentScans.present(now) { !gone.contains($0) }.map(\.name) == ["new.pdf"])
    }

    @Test func removeTakesOutOneEntry() {
        let list = RecentScans.add(RecentScans.add([], Self.scan("/Users/me/a.pdf")), Self.scan("/Users/me/b.pdf"))
        #expect(RecentScans.remove(list, list[0]).map(\.name) == ["a.pdf"])
    }

    @Test(arguments: [
        ("/Users/me/Scans/a.pdf", true),
        ("/Volumes/nas/scans/a.pdf", true), // a share mounted by Finder
        ("Scans/a.pdf", false), // relative
        ("~/Scans/a.pdf", false),
        ("/dev/disk0", false), // a device
        ("/dev/a.pdf", false),
        ("/Users/me/../../etc/a.pdf", false), // climbs out
        ("/Users/me/Scans/a.pdf\u{0}.txt", false),
        ("https://example.com/a.pdf", false),
        ("file:///Users/me/a.pdf", false),
        ("/Users/me/Scans/", false), // a folder
        ("", false),
        ("/Users/me/Scans/page 1.JPG", true),
        ("/Users/me/Scans/b.jpeg", true),
        ("/Users/me/Scans/Invoice 2026-03-04.docx", true), // a scan saved as Word or text (roadmap 4.14)
        ("/Users/me/Scans/Invoice 2026-03-04.txt", true),
        ("/Users/me/Scans/macro.docm", false),
        ("/Users/me/Downloads/setup.command", false), // Open hands it to Finder: only a scan's kinds of file
        ("/Volumes/share/run.app", false),
        ("/Users/me/Scans/a\".pdf", true), // a quote is an ordinary character in a Mac file name
    ])
    func onlyPlainFullPathsAreKept(_ path: String, _ kept: Bool) {
        #expect(RecentScans.usable(path) == kept)
    }

    @Test func aHandEditedSettingsFileIsBounded() throws {
        let many = (0..<500).map { "\"/Users/me/Scans/x\($0).jpg\"" }.joined(separator: ",")
        let printer = "Demo\\r\\nlaser" + String(repeating: "x", count: 500)
        let json = """
        [null, {"savedAt": 0, "pages": 1},
         {"files": [\(many), "relative.jpg"], "savedAt": 0, "pages": -5, "printer": "\(printer)", "preset": "  ",
          "access": "\(Data(count: RecentScans.maxAccess + 1).base64EncodedString())"}]
        """
        let read = RecentScans.clean(try JSONDecoder().decode([RecentScan?].self, from: Data(json.utf8)))
        #expect(read.count == 1)
        let only = try #require(read.first)
        #expect(only.files.count == RecentScans.maxFiles)
        #expect(only.pages == 0)
        #expect(only.printer?.count == RecentScans.maxText)
        #expect(only.printer?.contains("\n") == false)
        #expect(only.preset == nil)
        #expect(only.access == nil) // a bookmark too large to be one
        #expect(RecentScans.clean((0..<1000).map { Self.scan("/Users/me/s\($0).pdf") }).count == RecentScans.max)
    }

    @Test func anUnusableScanIsntAdded() {
        let list = RecentScans.add([], Self.scan("/Users/me/a.pdf"))
        #expect(RecentScans.add(list, Self.scan("not a path")).count == 1)
    }

    @Test func todayYesterdayOrEarlierByTheLocalCalendar() throws {
        let calendar = Calendar.current
        let now = try #require(calendar.date(bySettingHour: 12, minute: 0, second: 0, of: Date())) // local noon
        #expect(RecentScans.day(now.addingTimeInterval(-11 * 3600), now: now) == .today)
        #expect(RecentScans.day(try #require(calendar.date(byAdding: .day, value: -1, to: now)), now: now) == .yesterday)
        #expect(RecentScans.day(try #require(calendar.date(byAdding: .day, value: -2, to: now)), now: now) == .earlier)
    }

    @Test func pdfsPrintAsPdfsAndPicturesAsPhotos() {
        #expect(RecentScan(files: ["/Users/me/a.pdf", "/Users/me/b.PDF"], savedAt: Self.noon, pages: 2).isPdf)
        #expect(!RecentScan(files: ["/Users/me/a.pdf", "/Users/me/b.jpg"], savedAt: Self.noon, pages: 2).isPdf)
    }

    /// Mac only: the state file keeps the list and each entry's bookmark, and an older file without it still loads.
    @Test func theListRoundTripsThroughTheStateFile() throws {
        var state = PrintState()
        state.recentScans = [RecentScan(files: ["/Users/me/a.pdf"], savedAt: Self.noon, pages: 2, printer: "Demo laser", access: Data([1, 2, 3]))]
        let back = try JSONDecoder().decode(PrintState.self, from: JSONEncoder().encode(state))
        #expect(back.recentScans == state.recentScans)
        #expect(try JSONDecoder().decode(PrintState.self, from: Data("{}".utf8)).recentScans.isEmpty)
        // A broken list loses only itself.
        let broken = try JSONDecoder().decode(PrintState.self, from: Data(#"{"recentScans": 5, "selectedUuid": "x"}"#.utf8))
        #expect(broken.recentScans.isEmpty && broken.selectedUuid == "x")
    }
}
