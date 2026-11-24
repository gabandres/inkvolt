import Foundation

/// WIP diagnostics for CI's LtvTests stall: INKVOLT_NET_TRACE=1 writes socket events to stderr.
enum NetTrace {
    static let on = ProcessInfo.processInfo.environment["INKVOLT_NET_TRACE"] != nil
    private static let start = Date()

    static func log(_ text: @autoclosure () -> String) {
        guard on else { return }
        let line = String(format: "[net %.3f] ", Date().timeIntervalSince(start)) + text() + "\n"
        FileHandle.standardError.write(Data(line.utf8))
    }
}
