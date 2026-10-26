import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// A folder of this run's own under a root, for work kept on disk in case the app doesn't get to close normally (unsaved
/// scans; later Inkvolt PDF's recovery copies). A lock file in it is held locked while the run lives (`flock`, which the
/// system drops when the process ends in any way), so a folder whose lock nobody holds belongs to a run that ended without a
/// clean exit, and the next start can offer what it left. A clean exit (`close`) deletes the folder.
public final class RunFolder: @unchecked Sendable {
    private static let lockName = "running.lock"

    public let path: String
    private var lock: RunLock.Held?
    private let gate = NSLock()

    private init(path: String, lock: RunLock.Held) {
        self.path = path
        self.lock = lock
    }

    /// Makes this run's folder under `root` and holds its lock.
    public static func start(_ root: String) throws -> RunFolder {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(stamp.string(from: Date()))-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let path = (root as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return RunFolder(path: path, lock: try RunLock.hold((path as NSString).appendingPathComponent(lockName)))
    }

    /// The folders under `root` whose run ended without a clean exit (oldest first).
    public static func leftOver(_ root: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.sorted().map { (root as NSString).appendingPathComponent($0) }.filter { isDirectory($0) && !isRunning($0) }
    }

    /// Deletes a left-over folder (never a running one's). Best effort.
    public static func delete(_ folder: String) {
        if isDirectory(folder) && !isRunning(folder) { try? FileManager.default.removeItem(atPath: folder) }
    }

    private static func isRunning(_ folder: String) -> Bool {
        let lockPath = (folder as NSString).appendingPathComponent(lockName)
        return FileManager.default.fileExists(atPath: lockPath) && RunLock.isHeld(lockPath)
    }

    static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// Writes a file so a crash part way leaves the old one or none, never half of one.
    public static func writeAtomic(_ path: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Deletes a file, best effort.
    public static func tryDelete(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    /// Ends the run as a crash would: the lock goes (as the system drops a dead process's locks) and the folder stays.
    public func abandon() {
        gate.withLock {
            lock?.release()
            lock = nil
        }
    }

    /// A clean exit: the folder and everything in it go.
    public func close() {
        gate.withLock {
            guard let held = lock else { return }
            held.release()
            lock = nil
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    deinit { lock?.release() }
}

/// An exclusive lock on a file that the system drops when the process ends: `flock`. Platforms without it (the Windows PC's
/// test runs) get a lock within this process only, which is all one process's tests need.
enum RunLock {
    final class Held: @unchecked Sendable {
        private let release_: () -> Void
        private var released = false

        init(_ release: @escaping () -> Void) { release_ = release }

        func release() {
            guard !released else { return }
            released = true
            release_()
        }
    }

    #if canImport(Darwin) || canImport(Glibc)
    static func hold(_ path: String) throws -> Held {
        let fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: path])
        }
        return Held { _ = close(fd) }
    }

    static func isHeld(_ path: String) -> Bool {
        let fd = open(path, O_RDWR)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }
    #else
    private static let held = Mutex(Set<String>())

    static func hold(_ path: String) throws -> Held {
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        let key = path.lowercased()
        guard held.withLock({ $0.insert(key).inserted }) else { throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: path]) }
        return Held { _ = held.withLock { $0.remove(key) } }
    }

    static func isHeld(_ path: String) -> Bool { held.withLock { $0.contains(path.lowercased()) } }
    #endif
}
