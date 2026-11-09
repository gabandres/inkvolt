import Foundation
import PrintCore

/// One file of a split: its pages (0-based) and a label (a top-level bookmark's title, or "").
public struct SplitPart: Equatable, Sendable {
    public var pages: [Int]
    public var label: String

    public init(pages: [Int], label: String = "") {
        self.pages = pages
        self.label = label
    }
}

/// What Split Document splits by (Windows' "Split by" choices, in their order).
public enum SplitBy: Int, CaseIterable, Sendable {
    case pageCount, ranges, bookmarks
}

/// A batch of new files could not all be written: the files written before it stopped stay; the one that failed was
/// removed (Windows' `BatchWriteException`).
public struct BatchWriteError: Error, Equatable, Sendable, CustomStringConvertible {
    public var written: [String]
    public var failedPath: String
    public var reason: String
    public var description: String { loc("Couldn't write {0}: {1}", (failedPath as NSString).lastPathComponent, reason) }

    /// The message with which files were written before it stopped (Windows' `Organize.BatchFailure`).
    public var message: String {
        if written.isEmpty { return loc("{0} No files were written.", description) }
        let names = written.prefix(5).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        if written.count > 5 { return loc("{0} These files were written before it stopped: {1} and {2} more.", description, names, CoreLanguage.number(written.count - 5)) }
        return loc("{0} These files were written before it stopped: {1}.", description, names)
    }
}

/// Split Document and Extract Pages' file per page (Windows' `Organize.Split` and `Organize.Extract`, with
/// `PdfFiles.UniquePath` and `PdfFiles.WriteBatch`): the parts, every file name picked before anything is written, and
/// the writing, which never replaces a file.
public enum SplitFiles {
    /// Longest file name stem made (bookmark titles can be any length).
    static let maxStem = 120
    /// A file name's limit on APFS and HFS+, in UTF-8 bytes.
    static let maxNameBytes = 255

    /// The parts for `mode`, or the message to show (Windows' words).
    public static func parts(_ mode: SplitBy, pageCount: Int, pagesPerFile: String, ranges: String,
                             outline: [OutlineNode]) -> (parts: [SplitPart], error: String?) {
        var parts: [SplitPart] = []
        switch mode {
        case .pageCount:
            guard let n = Int(pagesPerFile.trimmingCharacters(in: .whitespaces)), n >= 1, n <= pageCount else {
                return ([], loc("Enter a page count from 1 to {0}.", CoreLanguage.number(pageCount)))
            }
            parts = PageEditor.chunksOf(pageCount, n).map { SplitPart(pages: $0) }
        case .ranges:
            for part in ranges.split(separator: ";").map({ $0.trimmingCharacters(in: .whitespaces) }) where !part.isEmpty {
                let r = PageRange.tryParse(part, pageCount)
                guard r.ok else { return ([], r.error) }
                parts.append(SplitPart(pages: r.pages))
            }
        case .bookmarks:
            if outline.isEmpty { return ([], loc("This document has no bookmarks.")) }
            let starts = Set(outline.map(\.pageIndex).filter { $0 >= 0 && $0 < pageCount } + [0]).sorted()
            for (i, start) in starts.enumerated() {
                let end = i + 1 < starts.count ? starts[i + 1] : pageCount
                let title = outline.first { $0.pageIndex == start }?.title ?? ""
                parts.append(SplitPart(pages: Array(start..<end), label: title))
            }
        }
        return parts.isEmpty ? ([], loc("Nothing to split.")) : (parts, nil)
    }

    /// Each part's file in `folder`: `pattern` with {name} (the document's name) and {n} (the part's number), a
    /// bookmark's title added; names already there, or taken by an earlier part, get " (2)", " (3)"….
    public static func targets(_ parts: [SplitPart], mode: SplitBy, folder: String, pattern: String,
                               name: String) -> (paths: [String], error: String?) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder, isDirectory: &isDir), isDir.boolValue else {
            return ([], loc("Choose an existing folder."))
        }
        let numbered = pattern.contains("{n}")
        if !numbered && mode != .bookmarks { return ([], loc("The file name must include {n} so each part gets its own file.")) }
        var reserved = Set<String>()
        var paths: [String] = []
        for (i, part) in parts.enumerated() {
            var file = pattern.replacingOccurrences(of: "{name}", with: name).replacingOccurrences(of: "{n}", with: String(i + 1))
            let label = part.label.trimmingCharacters(in: .whitespacesAndNewlines)
            if !label.isEmpty && !numbered { file = "\(name) - \(label)" } else if !label.isEmpty { file += " - \(label)" }
            paths.append(uniquePath(folder, file + ".pdf", &reserved))
        }
        return (paths, nil)
    }

    /// `fileName` made safe and unique in `folder`: "/", ":" and control characters become "_", the name is shortened
    /// to fit (never into a Windows device name: "CON_.pdf"), and a name that exists (or is in `reserved`, case ignored as the Mac's disks do) gets a number. The
    /// result is added to `reserved`, so a batch picks all its names before writing.
    public static func uniquePath(_ folder: String, _ fileName: String, _ reserved: inout Set<String>) -> String {
        let safe = String(fileName.map { $0 == "/" || $0 == ":" || ($0.asciiValue.map { $0 < 32 || $0 == 127 } ?? false) ? "_" : $0 })
        var ext = (safe as NSString).pathExtension
        if ext.count > 10 { ext = "" }
        let dotExt = ext.isEmpty ? "" : "." + ext
        var stem = ext.isEmpty ? safe : String(safe.dropLast(dotExt.count))
        stem = trimmedEnd(stem.trimmingCharacters(in: .whitespaces))
        if stem.isEmpty { stem = loc("Untitled") }
        // Room for " (999)" and the extension; a stem from a long title is cut on a character's boundary.
        if stem.count > maxStem { stem = String(stem.prefix(maxStem)) }
        while stem.utf8.count + 6 + dotExt.utf8.count > maxNameBytes { stem.removeLast() }
        stem = trimmedEnd(stem)
        if stem.isEmpty { stem = loc("Untitled") }
        // A name cut and trimmed into a device name ("CON", 200 spaces, "x" → "CON") gets "_" (Inkvolt Print's rule):
        // Windows opens CON.pdf as a device. Callers that refuse a device name outright check the name before this.
        if ReservedFileNames.isDevice(stem + dotExt) { stem += "_" }
        var path = (folder as NSString).appendingPathComponent(stem + dotExt)
        var n = 2
        while isTaken(path) || reserved.contains(path.lowercased()) {
            path = (folder as NSString).appendingPathComponent("\(stem) (\(n))\(dotExt)")
            n += 1
        }
        reserved.insert(path.lowercased())
        return path
    }

    /// Whether anything is at `path`, a symbolic link included even when it points nowhere (`fileExists` follows links,
    /// so a dangling one looked free and every retry picked its name).
    static func isTaken(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    private static func trimmedEnd(_ s: String) -> String {
        var s = s
        while s.hasSuffix(".") || s.hasSuffix(" ") { s.removeLast() }
        return s
    }

    /// Writes new files in order, each made just before it is written; never replaces a file. Stops at the first
    /// failure, removes that file (unless it was already there) and throws `BatchWriteError` with those written before.
    public static func writeBatch(_ files: [(path: String, bytes: () throws -> [UInt8])], cancel: CancelToken? = nil) throws {
        var written: [String] = []
        for (path, make) in files {
            if cancel?.isCancelled == true { throw CancellationError() }
            do {
                let bytes = try make()
                try Data(bytes).write(to: URL(fileURLWithPath: path), options: .withoutOverwriting)
                written.append(path)
            } catch {
                let existed = (error as? CocoaError)?.code == .fileWriteFileExists
                if !existed { try? FileManager.default.removeItem(atPath: path) }
                let reason = (error as? PdfEditError)?.message ?? error.localizedDescription
                throw BatchWriteError(written: written, failedPath: path, reason: existed ? loc("A file with that name is already there.") : reason)
            }
        }
    }
}
