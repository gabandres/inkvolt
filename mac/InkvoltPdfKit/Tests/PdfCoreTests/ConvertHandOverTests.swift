import Foundation
import Testing
@testable import PdfCore

/// A later launch's `--convert-to` handed to the running copy (the pre-release review: any process of the user could post
/// the distributed notification with a command line and make the app convert any PDF to Word beside it). No Windows test to
/// port: Windows' pipe takes only this user's processes; on the Mac a token stands for it, as Inkvolt Print's `--preset`
/// (`PresetHandOverTests`).
struct ConvertHandOverTests {
    private static func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("convert-handover-\(UUID().uuidString)")
    }

    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let arguments = ["--convert-to", "word", "/Users/someone/Report.pdf", "/Users/someone/Long name, with: marks.pdf"]

    @Test func aCommandLineLeftByALaunchIsTakenOnce() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let handOver = ConvertHandOver(folder: folder)
        let token = try #require(handOver.leave(arguments, now: now))
        let file = folder.appendingPathComponent(token + ".json").path
        #expect((try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect((try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        #expect(handOver.take(token, now: now.addingTimeInterval(2)) == arguments)
        #expect(handOver.take(token, now: now.addingTimeInterval(2)) == nil) // read once: posting the token again does nothing
        // The parsed request is what the launch asked for.
        let parsed = try #require(ConvertCommand.tryParse(arguments, folder: "/").request)
        #expect(ConvertCommand.toArguments(parsed).suffix(2) == arguments.suffix(2))
    }

    @Test func aNotificationFromAnyoneElseConvertsNothing() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let handOver = ConvertHandOver(folder: folder)
        _ = handOver.leave(arguments, now: now)
        // What another process can post: a command line, a made-up token, a path.
        #expect(handOver.take("--convert-to word /Users/someone/Report.pdf", now: now) == nil)
        #expect(handOver.take(UUID().uuidString, now: now) == nil)
        #expect(handOver.take("../../x", now: now) == nil)
        #expect(handOver.take("", now: now) == nil)
    }

    @Test func anOldOrOversizedCommandLineIsNotTaken() throws {
        let folder = Self.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let handOver = ConvertHandOver(folder: folder)
        let token = try #require(handOver.leave(arguments, now: now))
        #expect(handOver.take(token, now: now.addingTimeInterval(ConvertHandOver.freshFor + 1)) == nil)
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent(token + ".json").path)) // and it's gone
        // More files than a command line takes is never left.
        let many = ["--convert-to", "word"] + (0...ConvertCommand.maxFiles).map { "/f\($0).pdf" }
        #expect(handOver.leave(many, now: now) == nil)
    }
}
