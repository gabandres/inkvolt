import Foundation

/// A recording made for a report: its folder, the .zip of it to attach, and what the recorder says about it.
public struct ReportRecordingDone: Sendable {
    public var folder: URL
    public var zip: URL
    public var result: RecordResult
}

/// Help › Report a Problem's way to `PrinterRecorder` (print/ROADMAP.md 1.2; Windows' `ReportRecording`): the same
/// recording as `record`, so the same scrubbing and the same read-only rules, never with scanned pages. The folder is new
/// each time and named by the clock, never by anything the printer says, and holds nothing if the recording fails or is
/// cancelled. Nothing is sent: the user attaches the .zip by hand. Mac difference: the .zip stores its files (`ZipArchive`).
public enum ReportRecording {
    public static let prefix = "printer-recording-"

    public static func run(_ host: String, parent: URL, _ options: RecordOptions, now: Date) async throws -> ReportRecordingDone {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let folder = newFolder(parent, now)
        let zip = zipFor(folder)
        do {
            try Task.checkCancellation()
            var o = options
            o.scan = false
            let result = try await PrinterRecorder.record(host, to: folder, o)
            try Task.checkCancellation()
            let entries = try result.files.map { ZipArchive.Entry(name: $0, bytes: Array(try Data(contentsOf: folder.appendingPathComponent($0)))) }
            try Data(try ZipArchive.stored(entries, modified: now)).write(to: zip, options: .withoutOverwriting)
            try Task.checkCancellation() // closed while the .zip was written: nothing stays
            return ReportRecordingDone(folder: folder, zip: zip, result: result)
        } catch {
            remove(folder, zip)
            throw error
        }
    }

    /// Removes a recording `run` finished after all: its folder and .zip (Report a Problem closed while the recording came
    /// back, so nothing stays, as when it's cancelled during `run`).
    public static func discard(_ done: ReportRecordingDone) { remove(done.folder, done.zip) }

    /// The line the report's details get: what was recorded and the file's name, no folder and nothing to identify the printer.
    public static func reportLine(_ done: ReportRecordingDone, _ who: Diagnostics.Identity) -> String {
        let what = Diagnostics.scrub("\(done.result.model ?? "A printer") (\(done.result.interfaces.joined(separator: ", "))), \(done.result.files.count) files", who)
        return "Printer recording: \(what), \(done.zip.lastPathComponent)"
    }

    /// Why it didn't work, as the report's scrubbing would show it: the address a message quotes stays out of what's copied.
    public static func failureText(_ error: any Error, _ who: Diagnostics.Identity) -> String {
        "Nothing recorded: " + Diagnostics.scrub(message(error), who)
    }

    static func message(_ error: any Error) -> String {
        switch error {
        case is CancellationError: "Stopped."
        case let e as RecordingError: e.description
        case let e as DeviceNetworkError: e.description
        case let e as DeviceHttpError: e.description
        default: error.localizedDescription
        }
    }

    private static func zipFor(_ folder: URL) -> URL {
        folder.deletingLastPathComponent().appendingPathComponent(folder.lastPathComponent + ".zip", isDirectory: false)
    }

    private static func newFolder(_ parent: URL, _ now: Date) -> URL {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = prefix + formatter.string(from: now)
        var folder = parent.appendingPathComponent(name, isDirectory: true)
        var i = 2
        while FileManager.default.fileExists(atPath: folder.path) || FileManager.default.fileExists(atPath: zipFor(folder).path) {
            folder = parent.appendingPathComponent("\(name)-\(i)", isDirectory: true)
            i += 1
        }
        return folder
    }

    private static func remove(_ folder: URL, _ zip: URL) {
        // The failure itself is what gets told.
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.removeItem(at: zip)
    }
}
