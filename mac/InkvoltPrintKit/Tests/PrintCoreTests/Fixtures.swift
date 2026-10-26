import Foundation

/// The .NET tests' fixtures, read in place: `print/tests/InkvoltPrint.Tests/Fixtures`.
enum Fixtures {
    static let root: URL = {
        var url = URL(fileURLWithPath: #filePath) // mac/InkvoltPrintKit/Tests/PrintCoreTests/Fixtures.swift
        for _ in 0..<5 { url.deleteLastPathComponent() }
        return url.appendingPathComponent("print/tests/InkvoltPrint.Tests/Fixtures")
    }()

    static func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    static func data(_ path: String) throws -> [UInt8] {
        Array(try Data(contentsOf: root.appendingPathComponent(path)))
    }
}

/// Bytes from hex written with spaces and line breaks, as the tests write messages by hand.
func hex(_ text: String) -> [UInt8] {
    let digits = Array(text.filter(\.isHexDigit))
    return stride(from: 0, to: digits.count, by: 2).map { UInt8(String(digits[$0...$0 + 1]), radix: 16)! }
}
