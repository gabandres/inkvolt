import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// What a folder that files land in needs (Windows' `DropFolder`, which Inkvolt PDF's watched folder shares there; on the Mac
/// Inkvolt PDF's `WatchedFolder` has its own copy, in another package, with the same names): a file is complete when its size
/// and time have stayed the same for a while (`DropFolderLook`) and nobody holds a lock on it; it is then moved into
/// "working" (a rename, so no other watcher or later look can take it again). Everything lives in the folder, so a restart
/// picks up where it was. A lock file keeps a second watcher off the same folder, Inkvolt PDF's included.
///
/// Mac difference: "nobody holds it" is a `flock` nobody else has (an app that locks the files it writes; macOS has no
/// Windows sharing modes, so a plain copy in progress is caught by the quiet period and the end-of-file check instead).
public enum DropFolder {
    public static let doneFolder = "done", failedFolder = "failed", workingFolder = "working"

    /// The one lock file, whichever app watches: both use "working", and each takes what's left there as interrupted.
    public static let lockName = ".inkvolt-watch.lock"

    /// The files at the top of the folder that `isSupported` takes: not hidden, not a link, not Office's "~$" owner files.
    public static func candidates(_ folder: String, _ isSupported: (String) -> Bool) -> [String] {
        // The folder away for a moment (a network drop): nothing now, look again next time.
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: folder) else { return [] }
        var files: [String] = []
        for name in names where isSupported(name) && !name.hasPrefix(".") && !name.hasPrefix("~$") {
            let path = (folder as NSString).appendingPathComponent(name)
            guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType, type == .typeRegular else { continue }
            files.append(path)
        }
        return files
    }

    /// Takes a complete file: lock it (fails while anyone holds it), then move it into "working". Nil: not now (still held,
    /// or gone).
    public static func claim(_ path: String, _ working: String) -> String? {
        guard let held = hold(path, create: false) else { return nil }
        defer { held.release() }
        let target = free(working, (path as NSString).lastPathComponent)
        do {
            try FileManager.default.moveItem(atPath: path, toPath: target)
            return target
        } catch {
            return nil
        }
    }

    /// Moves a file to `folder` under a free name, waiting a moment when it can't be moved yet. Nil: it couldn't be moved or
    /// is gone.
    public static func moveTo(_ path: String, _ folder: String, _ name: String) -> String? {
        for _ in 0..<20 {
            let to = free(folder, name)
            do {
                try FileManager.default.moveItem(atPath: path, toPath: to)
                return to
            } catch {
                if !FileManager.default.fileExists(atPath: path) { return nil }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        return nil
    }

    /// Adds a line to the folder's log. One that can't be written (read-only, not ours) is left: the log is a record, and what
    /// it records has happened.
    public static func appendLog(_ path: String, _ line: String) {
        let bytes = Array((line + "\n").utf8)
        #if canImport(Darwin) || canImport(Glibc)
        let fd = open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = bytes.withUnsafeBufferPointer { write(fd, $0.baseAddress, $0.count) }
        #else
        if !FileManager.default.fileExists(atPath: path) {
            _ = FileManager.default.createFile(atPath: path, contents: Data(bytes))
            return
        }
        guard let handle = FileHandle(forWritingAtPath: path) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(bytes))
        #endif
    }

    /// A path for `name` in `folder` that isn't taken ("report (2).pdf").
    public static func free(_ folder: String, _ name: String) -> String {
        let stem = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 1
        while true {
            let candidate = n == 1 ? name : (ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)")
            let path = (folder as NSString).appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: path) { return path }
            n += 1
        }
    }

    /// The folder's lock file, held for the watch (the system lets go of it if the process ends) and deleted, while still held,
    /// when let go (`FileLock`). Nil: another watcher has the folder.
    public static func lock(_ folder: String) -> Held? {
        (try? FileLock.hold((folder as NSString).appendingPathComponent(lockName), create: true, deleteOnRelease: true)) ?? nil
    }

    /// A lock on one file (`FileLock`: what Inkvolt PDF's watched folder and apps that lock their files hold), for as long as
    /// it is held. Nil: someone else holds it, or the file can't be opened.
    public static func hold(_ path: String, create: Bool = false) -> Held? {
        (try? FileLock.hold(path, create: create)) ?? nil
    }

    public typealias Held = FileLock
}

/// Which of a folder's files have stopped changing: each one's size and time when last looked at, since when they have been
/// so, and when it was first seen.
public final class DropFolderLook {
    private let quiet: TimeInterval
    private var seen: [String: (size: Int64, written: Date, since: Date, first: Date)] = [:]

    public init(_ quiet: Duration) { self.quiet = DropFolderLook.seconds(quiet) }

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    /// Looks at the folder's files now; returns those that have been the same for the quiet period.
    public func ready(_ files: [String], _ now: Date) -> [String] {
        var ready: [String] = []
        var present = Set<String>()
        for file in files {
            present.insert(file)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: file),
                  let size = (attributes[.size] as? NSNumber)?.int64Value, let written = attributes[.modificationDate] as? Date else { continue }
            if let last = seen[file] {
                if last.size != size || last.written != written {
                    seen[file] = (size, written, now, last.first)
                } else if now.timeIntervalSince(last.since) >= quiet {
                    ready.append(file)
                }
            } else {
                seen[file] = (size, written, now, now)
            }
        }
        for gone in seen.keys where !present.contains(gone) { seen[gone] = nil }
        return ready
    }

    /// The file was taken: it starts afresh if it ever comes back.
    public func forget(_ path: String) { seen[path] = nil }

    /// Since when the file has had this size and time, or nil.
    public func unchangedSince(_ path: String) -> Date? { seen[path]?.since }

    /// Every file there has been seen for at least `time` (one still growing or held waits for the next run).
    public func allSeenFor(_ time: Duration, _ now: Date) -> Bool {
        let t = Self.seconds(time)
        return seen.values.allSatisfy { now.timeIntervalSince($0.first) >= t }
    }
}
