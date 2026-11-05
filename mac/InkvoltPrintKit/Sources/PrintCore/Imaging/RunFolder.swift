import Foundation
import Synchronization

/// A folder of this run's own under a root, for work kept on disk in case the app doesn't get to close normally (unsaved
/// scans; later Inkvolt PDF's recovery copies). A lock file in it is held locked while the run lives (`FileLock`, which the
/// system drops when the process ends in any way), so a folder whose lock nobody holds belongs to a run that ended without a
/// clean exit, and the next start can offer what it left. A clean exit (`close`) deletes the folder.
public final class RunFolder: Sendable {
    private static let lockName = "running.lock"

    public let path: String
    private let lock: Mutex<FileLock?>

    private init(path: String, lock: FileLock) {
        self.path = path
        self.lock = Mutex(lock)
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
        let lockPath = (path as NSString).appendingPathComponent(lockName)
        guard let lock = try FileLock.hold(lockPath, create: true) else { throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: lockPath]) }
        return RunFolder(path: path, lock: lock)
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
        return FileManager.default.fileExists(atPath: lockPath) && FileLock.isHeld(lockPath)
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
        lock.withLock {
            $0?.release()
            $0 = nil
        }
    }

    /// A clean exit: the folder and everything in it go.
    public func close() {
        lock.withLock {
            guard let held = $0 else { return }
            held.release()
            $0 = nil
            try? FileManager.default.removeItem(atPath: path)
        }
    }
}
