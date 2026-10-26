import Foundation
import Synchronization

/// The .NET tests' fixtures, read in place: `print/tests/InkvoltPrint.Tests/Fixtures`. Each file is read from disk once and
/// kept: reading it is blocking I/O on the test's thread, and under a full parallel run that held up the timing tests.
enum Fixtures {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath) // mac/InkvoltPrintKit/Tests/PrintCoreTests/Fixtures.swift
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("print/tests/InkvoltPrint.Tests/Fixtures")
    }()

    private static let cache = Mutex<[String: [UInt8]]>([:])

    static func text(_ path: String) throws -> String {
        String(decoding: try data(path), as: UTF8.self)
    }

    static func data(_ path: String) throws -> [UInt8] {
        if let kept = cache.withLock({ $0[path] }) { return kept }
        let bytes = Array(try Data(contentsOf: root.appendingPathComponent(path)))
        cache.withLock { $0[path] = bytes }
        return bytes
    }

    /// Reads every file of a fixture folder now, so a test that times itself doesn't wait on the disk.
    static func preload(_ folder: String) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(folder).path)) ?? []
        for name in names { _ = try? data("\(folder)/\(name)") }
    }
}

/// Bytes from hex written with spaces and line breaks, as the tests write messages by hand.
func hex(_ text: String) -> [UInt8] {
    let digits = Array(text.filter(\.isHexDigit))
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
}
