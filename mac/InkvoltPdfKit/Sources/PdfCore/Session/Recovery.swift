import Darwin
import Foundation

/// What a recovery copy is of: the tab's name, the file it came from (nil for a document never saved, such as a combined
/// or scanned one), that file's size and time when the copy was made, when it was made, and the page in view.
public struct RecoveryInfo: Codable, Equatable, Sendable {
    public var displayName: String
    public var originalPath: String?
    public var originalLength: Int64?
    public var originalWriteTime: Date?
    public var saved: Date
    public var page: Int

    public init(displayName: String, originalPath: String?, originalLength: Int64?, originalWriteTime: Date?, saved: Date, page: Int) {
        self.displayName = displayName
        self.originalPath = originalPath
        self.originalLength = originalLength
        self.originalWriteTime = originalWriteTime
        self.saved = saved
        self.page = page
    }
}

/// A recovery copy a run left behind: the copy's bytes are in `pdfPath`.
public struct LeftOverDocument: Equatable, Sendable {
    public var pdfPath: String
    public var info: RecoveryInfo
    public var folder: String
}

/// Copies of documents with unsaved changes, so they can be offered back after Inkvolt PDF closes without saving them (a
/// crash, a killed process, a power cut) (the Windows app's `RecoveryStore`). They live in this run's `RunFolder`: a copy
/// is the document's bytes as Save would write them (a password-protected document stays protected), written atomically,
/// with a small description beside it. A clean exit removes the folder.
public final class RecoveryStore: @unchecked Sendable {
    private let run: RunFolder
    private let gate = NSLock()
    private var ended = false

    private init(_ run: RunFolder) { self.run = run }

    /// Starts this run's folder under `root`.
    public static func start(_ root: String) throws -> RecoveryStore { RecoveryStore(try RunFolder.start(root)) }

    private static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    private static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    /// Writes (or replaces) the copy for `id`. Safe from any thread; one write at a time.
    public func write(_ id: String, _ data: [UInt8], _ info: RecoveryInfo) throws {
        try gate.withLock {
            if ended { return }
            try RunFolder.writeAtomic((run.path as NSString).appendingPathComponent(id + ".pdf"), data)
            try RunFolder.writeAtomic((run.path as NSString).appendingPathComponent(id + ".json"), Array(Self.encoder().encode(info)))
        }
    }

    /// Removes the copy for `id` (saved, back to its saved state, or closed).
    public func remove(_ id: String) {
        gate.withLock {
            RunFolder.tryDelete((run.path as NSString).appendingPathComponent(id + ".json"))
            RunFolder.tryDelete((run.path as NSString).appendingPathComponent(id + ".pdf"))
        }
    }

    /// Copies left by runs that ended without a clean exit, complete ones only: a copy without its description, or a
    /// description that can't be read, is skipped.
    public static func findLeftOver(_ root: String) -> [LeftOverDocument] {
        var found: [LeftOverDocument] = []
        for folder in RunFolder.leftOver(root) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []
            for name in names.sorted() where name.hasSuffix(".json") {
                let description = (folder as NSString).appendingPathComponent(name)
                let pdf = (description as NSString).deletingPathExtension + ".pdf"
                guard FileManager.default.fileExists(atPath: pdf),
                      let bytes = FileManager.default.contents(atPath: description),
                      let info = try? decoder().decode(RecoveryInfo.self, from: bytes), !info.displayName.isEmpty else { continue }
                found.append(LeftOverDocument(pdfPath: pdf, info: info, folder: folder))
            }
        }
        return found
    }

    /// Deletes the folders the documents were left in (the user declined them).
    public static func discard(_ documents: [LeftOverDocument]) {
        for folder in Set(documents.map(\.folder)) { RunFolder.delete(folder) }
    }

    /// Deletes one left-over copy (restored, or found unreadable); its folder goes with the last one.
    public static func remove(_ document: LeftOverDocument) {
        RunFolder.tryDelete((document.pdfPath as NSString).deletingPathExtension + ".json")
        RunFolder.tryDelete(document.pdfPath)
        if !hasDescriptions(document.folder) { RunFolder.delete(document.folder) }
    }

    /// Deletes left-over folders that hold nothing to offer (a run that crashed with every document saved).
    public static func discardEmpty(_ root: String) {
        for folder in RunFolder.leftOver(root) where !hasDescriptions(folder) { RunFolder.delete(folder) }
    }

    private static func hasDescriptions(_ folder: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).contains { $0.hasSuffix(".json") }
    }

    /// Ends the run as a crash would: the copies stay (tests).
    func abandon() {
        gate.withLock {
            ended = true
            run.abandon()
        }
    }

    /// A clean exit: every copy and the run's folder go.
    public func close() {
        gate.withLock {
            ended = true
            run.close()
        }
    }
}

/// A folder of this run's own under a root (Inkvolt Print's `RunFolder`, the same rules): a lock file in it is held
/// locked while the run lives (`flock`, which the system drops when the process ends in any way), so a folder whose lock
/// nobody holds belongs to a run that ended without a clean exit. A clean exit (`close`) deletes the folder.
final class RunFolder: @unchecked Sendable {
    private static let lockName = "running.lock"

    let path: String
    private var fd: Int32?
    private let gate = NSLock()

    private init(path: String, fd: Int32) {
        self.path = path
        self.fd = fd
    }

    /// Makes this run's folder under `root` and holds its lock.
    static func start(_ root: String) throws -> RunFolder {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        let name = "\(stamp.string(from: Date()))-\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())"
        let path = (root as NSString).appendingPathComponent(name)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        let lock = (path as NSString).appendingPathComponent(lockName)
        let fd = open(lock, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: lock]) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(fd)
            throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: lock])
        }
        return RunFolder(path: path, fd: fd)
    }

    /// The folders under `root` whose run ended without a clean exit (oldest first).
    static func leftOver(_ root: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root) else { return [] }
        return names.sorted().map { (root as NSString).appendingPathComponent($0) }.filter { isDirectory($0) && !isRunning($0) }
    }

    /// Deletes a left-over folder (never a running one's). Best effort.
    static func delete(_ folder: String) {
        if isDirectory(folder) && !isRunning(folder) { try? FileManager.default.removeItem(atPath: folder) }
    }

    private static func isRunning(_ folder: String) -> Bool {
        let lock = (folder as NSString).appendingPathComponent(lockName)
        let fd = open(lock, O_RDWR)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
    }

    private static func isDirectory(_ path: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &dir) && dir.boolValue
    }

    /// Writes a file so a crash part way leaves the old one or none, never half of one.
    static func writeAtomic(_ path: String, _ bytes: [UInt8]) throws {
        try Data(bytes).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// Deletes a file, best effort.
    static func tryDelete(_ path: String) { try? FileManager.default.removeItem(atPath: path) }

    /// Ends the run as a crash would: the lock goes (as the system drops a dead process's locks) and the folder stays.
    func abandon() {
        gate.withLock {
            if let fd { Darwin.close(fd) }
            fd = nil
        }
    }

    /// A clean exit: the folder and everything in it go.
    func close() {
        gate.withLock {
            guard let held = fd else { return }
            Darwin.close(held)
            fd = nil
            try? FileManager.default.removeItem(atPath: path)
        }
    }

    deinit {
        if let fd { Darwin.close(fd) }
    }
}
