import Foundation
import Testing
@testable import PrintCore

/// The one file lock (`FileLock`): a run's folder, a watched folder's lock file (Inkvolt PDF for Mac's too) and a file claimed
/// from it. No Windows equivalent: Windows' FileShare.None with DeleteOnClose can't be taken on a file being deleted.
@Suite(.serialized)
struct FileLockTests {
    static func folder() throws -> String {
        let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("inkvolt-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    @Test func One_holder_at_a_time_and_the_next_once_it_lets_go() throws {
        let f = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: f) }
        let path = (f as NSString).appendingPathComponent("a.lock")
        let first = try #require(try FileLock.hold(path, create: true))
        #expect(FileLock.isHeld(path))
        #expect(try FileLock.hold(path, create: true) == nil)
        first.release()
        first.release() // once
        #expect(!FileLock.isHeld(path))
        let second = try #require(try FileLock.hold(path, create: true))
        second.release()
        #expect(try FileLock.hold((f as NSString).appendingPathComponent("missing"), create: false) == nil)
    }

    /// A watcher opens the lock file just as its holder deletes it and lets go: its lock is on a file nobody else will open,
    /// and the next watcher makes a new one. Without the check both would hold "the" lock and watch the same folder.
    @Test func A_lock_file_its_last_holder_deleted_is_never_held_by_two() throws {
        let f = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: f) }
        let path = (f as NSString).appendingPathComponent(DropFolder.lockName)
        let first = try #require(try FileLock.hold(path, create: true, deleteOnRelease: true))
        let second = try FileLock.hold(path, create: true, deleteOnRelease: true, opened: { first.release() })
        let third = try FileLock.hold(path, create: true, deleteOnRelease: true)
        #expect(second != nil)
        #expect(third == nil, "two watchers hold the folder's lock")
        #expect(DropFolder.lock(f) == nil)
        second?.release()
        #expect(!FileManager.default.fileExists(atPath: path)) // deleted when let go, as Windows' DeleteOnClose
        #expect(DropFolder.lock(f) != nil)
    }

    /// A file being claimed that is moved away or replaced while it is locked isn't taken: it's no longer the file it was.
    @Test func A_file_replaced_while_being_locked_is_not_taken() throws {
        let f = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: f) }
        let path = (f as NSString).appendingPathComponent("scan.pdf")
        _ = FileManager.default.createFile(atPath: path, contents: Data("one".utf8))
        let taken = try FileLock.hold(path, create: false, deleteOnRelease: false, opened: {
            try? FileManager.default.removeItem(atPath: path)
            _ = FileManager.default.createFile(atPath: path, contents: Data("two".utf8))
        })
        #if canImport(Darwin) || canImport(Glibc)
        #expect(taken == nil)
        #endif
        taken?.release()
        #expect(DropFolder.hold(path) != nil) // the file there now
    }

    /// A symbolic link planted at a lock's path (a watched folder anyone can write to) is never followed: no file is made
    /// or locked at its target, and neither is a lock path that isn't a plain file (a FIFO would block the open).
    @Test func A_symlink_or_other_non_file_at_the_lock_path_is_refused() throws {
        #if canImport(Darwin) || canImport(Glibc)
        let f = try Self.folder()
        defer { try? FileManager.default.removeItem(atPath: f) }
        let target = (f as NSString).appendingPathComponent("elsewhere")
        let path = (f as NSString).appendingPathComponent(DropFolder.lockName)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)
        #expect(throws: (any Error).self) { _ = try FileLock.hold(path, create: true, deleteOnRelease: true) }
        #expect(!FileManager.default.fileExists(atPath: target), "a file was made at the link's target")
        #expect(DropFolder.lock(f) == nil)
        #expect(!FileManager.default.fileExists(atPath: target))

        // A link to a file that exists: not locked either, and the file is left as it was.
        _ = FileManager.default.createFile(atPath: target, contents: Data("theirs".utf8))
        #expect(throws: (any Error).self) { _ = try FileLock.hold(path, create: false) }
        #expect(!FileLock.isHeld(path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: target)) == Data("theirs".utf8))

        let fifo = (f as NSString).appendingPathComponent("pipe.lock")
        #expect(mkfifo(fifo, 0o644) == 0)
        #expect(throws: (any Error).self) { _ = try FileLock.hold(fifo, create: true) }
        #expect(throws: (any Error).self) { _ = try FileLock.hold(fifo, create: false) }
        #expect(!FileLock.isHeld(fifo))
        #endif
    }
}
