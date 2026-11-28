import Foundation
import Testing
@testable import PdfCore

/// The app's log (Windows' `Log`, app code without tests there): a line per message with the time, more lines indented,
/// one older file past about 1 MB, nothing thrown where it can't write. Mac additions; serialized, since the folder is
/// one setting for the process.
@Suite(.serialized)
struct AppLogTests {
    private func withFolder(_ body: (URL) throws -> Void) rethrows {
        let saved = AppLog.folder
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-log-\(UUID().uuidString)")
        AppLog.folder = dir
        defer {
            AppLog.folder = saved
            try? FileManager.default.removeItem(at: dir)
        }
        try body(dir)
    }

    private func lines(_ url: URL) -> [String] {
        ((try? String(contentsOf: url, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    @Test func eachMessageIsALineWithItsTimeAndMoreLinesAreIndented() {
        withFolder { dir in
            let at = Date(timeIntervalSince1970: 0)
            AppLog.write("Opened a.pdf", now: at)
            AppLog.write("Export failed\nsecond line", now: at)
            let written = lines(dir.appendingPathComponent("inkvoltpdf.log"))
            let stamp = AppLog.stamp(at)
            #expect(written == ["\(stamp) Opened a.pdf", "\(stamp) Export failed", "    second line"])
            #expect(stamp.count == 23 && stamp.dropFirst(10).first == " ")
        }
    }

    @Test func pastItsSizeTheLogStartsAgainAndKeepsOneOlderFile() throws {
        try withFolder { dir in
            let log = dir.appendingPathComponent("inkvoltpdf.log")
            AppLog.write("first")
            try Data(repeating: 0x41, count: AppLog.maxBytes + 1).write(to: log)
            AppLog.write("after")
            #expect(lines(log).count == 1 && lines(log)[0].hasSuffix(" after"))
            let old = (try? Data(contentsOf: dir.appendingPathComponent("inkvoltpdf.log.1")))?.count
            #expect(old == AppLog.maxBytes + 1)
        }
    }

    @Test func aFolderThatCantBeMadeLosesTheLineQuietly() throws {
        let saved = AppLog.folder
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("inkvolt-log-file-\(UUID().uuidString)")
        try Data([1]).write(to: file)
        defer {
            AppLog.folder = saved
            try? FileManager.default.removeItem(at: file)
        }
        AppLog.folder = file.appendingPathComponent("sub") // under a file: no folder can be made
        AppLog.write("lost")
        #expect(!FileManager.default.fileExists(atPath: AppLog.fileURL.path))
    }

    @Test func aPathIsLoggedByItsNameOnly() {
        #expect(AppLog.name("/Users/someone/Documents/Contract.pdf") == "Contract.pdf")
        #expect(AppLog.name(nil) == "(unsaved)")
    }
}
