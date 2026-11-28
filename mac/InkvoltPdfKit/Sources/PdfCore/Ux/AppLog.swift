import Foundation

/// The app's plain-text log (Windows' `Log`, %LOCALAPPDATA%\InkvoltPdf\logs\inkvoltpdf.log): here
/// ~/Library/Logs/Inkvolt PDF/inkvoltpdf.log, which Console lists too. Kept under about 1 MB with one older file
/// (`.1`). Local only: never a password or a document's contents, and a file's name (`name`) rather than its path.
/// Writing never throws: the log must not take the app down. Help › Open Log Folder shows the folder, Help › Report a
/// Problem… copies its last lines (scrubbed).
public enum AppLog {
    public static let maxBytes = 1_000_000

    /// ~/Library/Logs/Inkvolt PDF (a test or the self-test may point it elsewhere).
    nonisolated(unsafe) public static var folder: URL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Inkvolt PDF", isDirectory: true)

    public static var fileURL: URL { folder.appendingPathComponent("inkvoltpdf.log") }

    private static let lock = NSLock()

    /// Just the file name of `path`, for lines that don't need the folder.
    public static func name(_ path: String?) -> String {
        guard let path, !path.isEmpty else { return "(unsaved)" }
        return (path as NSString).lastPathComponent
    }

    /// A line with the time (the computer's, to the millisecond); a message of several lines continues indented.
    public static func write(_ message: String, now: Date = Date()) {
        let text = message.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\n    ")
        let line = "\(stamp(now)) \(text)\n"
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let url = fileURL
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let old = url.appendingPathExtension("1")
            try? fm.removeItem(at: old)
            try? fm.moveItem(at: url, to: old)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    /// "2026-11-27 14:03:09.512", as Windows' lines start.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return f.string(from: date)
    }
}
