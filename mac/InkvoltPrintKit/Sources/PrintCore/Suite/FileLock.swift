import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// An exclusive lock on a file, held until `release` (or until it's gone): `flock`, which the system drops when the process
/// ends in any way, and which Inkvolt PDF for Mac's watched folder and apps that lock the files they write hold too. The one
/// lock both apps take: a run's folder (`RunFolder`), a watched folder's lock file and a file being claimed from it
/// (`DropFolder`, Inkvolt PDF's `WatchedFolder`). Platforms without `flock` (the Windows PC's test runs) get a lock within
/// this process only, which is all one process's tests need.
///
/// A lock file deleted when let go (`deleteOnRelease`, Windows' `FileOptions.DeleteOnClose`) is deleted while still held,
/// and every lock taken checks that the file it locked is still the one at the path: one opened just before its last holder
/// deleted it is a file nobody else will ever open, so a lock on it would keep nobody out while the next watcher made a new
/// one. That lock is let go and the file at the path opened again.
public final class FileLock: Sendable {
    #if canImport(Darwin) || canImport(Glibc)
    private typealias Handle = Int32
    #else
    private typealias Handle = String
    #endif

    public let path: String
    private let deleteOnRelease: Bool
    private let handle: Mutex<Handle?>

    private init(_ path: String, _ handle: Handle, deleteOnRelease: Bool) {
        self.path = path
        self.deleteOnRelease = deleteOnRelease
        self.handle = Mutex(handle)
    }

    /// Takes the lock on `path`, made first when `create`. Nil: someone else holds it (or, without `create`, the file is gone or
    /// was replaced while it was being locked). Throws when the file can't be opened.
    public static func hold(_ path: String, create: Bool = false, deleteOnRelease: Bool = false) throws -> FileLock? {
        try hold(path, create: create, deleteOnRelease: deleteOnRelease, opened: nil)
    }

    /// `opened` runs between opening the file and locking it (the tests' moment for another holder to let go).
    static func hold(_ path: String, create: Bool, deleteOnRelease: Bool, opened: (() -> Void)?) throws -> FileLock? {
        #if canImport(Darwin) || canImport(Glibc)
        for _ in 0..<8 {
            let fd = create ? open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644) : open(path, O_RDONLY | O_CLOEXEC)
            if fd < 0 {
                if !create && errno == ENOENT { return nil }
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            opened?()
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                close(fd)
                return nil
            }
            if same(fd, path) { return FileLock(path, fd, deleteOnRelease: deleteOnRelease) }
            close(fd)
            if !create { return nil }
        }
        return nil // made and deleted again and again under it: someone else is at it
        #else
        if create { _ = FileManager.default.fileExists(atPath: path) || FileManager.default.createFile(atPath: path, contents: nil) }
        guard FileManager.default.fileExists(atPath: path) else {
            if create { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
            return nil
        }
        opened?()
        let key = key(path)
        guard heldHere.withLock({ $0.insert(key).inserted }) else { return nil }
        return FileLock(path, key, deleteOnRelease: deleteOnRelease)
        #endif
    }

    /// True while someone holds the lock on `path` (false when there's no file).
    public static func isHeld(_ path: String) -> Bool {
        #if canImport(Darwin) || canImport(Glibc)
        let fd = open(path, O_RDONLY | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return errno == EWOULDBLOCK }
        flock(fd, LOCK_UN)
        return false
        #else
        return heldHere.withLock { $0.contains(key(path)) }
        #endif
    }

    /// Lets go (once; later calls do nothing). A `deleteOnRelease` file is deleted first, while still held.
    public func release() {
        guard let h = handle.withLock({ h -> Handle? in
            defer { h = nil }
            return h
        }) else { return }
        #if canImport(Darwin) || canImport(Glibc)
        if deleteOnRelease { unlink(path) }
        close(h)
        #else
        if deleteOnRelease { try? FileManager.default.removeItem(atPath: path) }
        _ = Self.heldHere.withLock { $0.remove(h) }
        #endif
    }

    deinit { release() }

    #if canImport(Darwin) || canImport(Glibc)
    /// The open file is the one at `path` now (not deleted, not replaced since it was opened).
    private static func same(_ fd: Int32, _ path: String) -> Bool {
        var held = stat(), now = stat()
        return fstat(fd, &held) == 0 && stat(path, &now) == 0 && held.st_dev == now.st_dev && held.st_ino == now.st_ino
    }
    #else
    private static let heldHere = Mutex(Set<String>())

    /// One file however its path is spelt ("C:\a" and "/C:/a", as Foundation's URLs give it here).
    private static func key(_ path: String) -> String {
        var key = path.lowercased().replacingOccurrences(of: "\\", with: "/")
        if key.hasPrefix("/"), key.dropFirst().dropFirst().first == ":" { key.removeFirst() }
        return key
    }
    #endif
}
