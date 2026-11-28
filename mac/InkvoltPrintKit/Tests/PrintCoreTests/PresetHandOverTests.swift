import Foundation
import Testing
@testable import PrintCore

/// A second launch's `--preset` handed to the running copy (the pre-release review: any process could post the distributed
/// notification and make the app scan). No Windows test to port: Windows' pipe takes only this user's processes, and the Mac
/// has no such channel, so a token in the app's own container stands for it.
struct PresetHandOverTests {
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("handover-\(UUID().uuidString)")
    }

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func aPresetLeftByThisAppIsTakenOnce() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let handOver = PresetHandOver(folder: folder)
        let token = try #require(handOver.leave("Receipts", now: now))
        #expect(handOver.take(token, now: now.addingTimeInterval(2)) == "Receipts")
        #expect(handOver.take(token, now: now.addingTimeInterval(2)) == nil) // read once: posting the token again does nothing
    }

    @Test func aNotificationFromAnyoneElseRunsNothing() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let handOver = PresetHandOver(folder: folder)
        _ = handOver.leave("Receipts", now: now)
        // What another process can post: a preset's name or id, a made-up token, a path.
        #expect(handOver.take("Receipts", now: now) == nil)
        #expect(handOver.take(UUID().uuidString, now: now) == nil)
        #expect(handOver.take("../../Receipts", now: now) == nil)
        #expect(handOver.take("", now: now) == nil)
    }

    @Test func anOldPresetIsNotRun() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let handOver = PresetHandOver(folder: folder)
        let token = try #require(handOver.leave("Receipts", now: now))
        #expect(handOver.take(token, now: now.addingTimeInterval(PresetHandOver.freshFor + 1)) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(token + ".json").path)) // and it's gone
    }

    @Test func leftFilesNeverPileUp() {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let handOver = PresetHandOver(folder: folder)
        for i in 0..<40 { _ = handOver.leave("p\(i)", now: now) }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0 <= PresetHandOver.kept)
    }

    @Test func aPresetFromOutsideAsksBeforeItScans() {
        #expect(PresetOrigin.outside.asksFirst)
        #expect(!PresetOrigin.insideApp.asksFirst) // the Dock menu, Scan With and the palette: the person's own click
    }
}
