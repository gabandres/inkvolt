import Foundation
import Synchronization

/// Hearing a scanner's buttons stops when this is stopped (Windows' `IDisposable` from `WatchButtonsAsync`).
public protocol ButtonWatch: Sendable {
    func stop()
}

/// A USB scanner's buttons as its driver reports them (roadmap 2.2's driver half; Windows' `IWiaSystem.WatchButtonsAsync`).
/// On the Mac it is ImageCaptureCore's button presses (PrintMac's `IcaScannerButtons`); the tests and the demo use
/// `FakeScannerButtons`.
public protocol ScannerButtons: Sendable {
    /// The scan buttons the scanner's driver reports (Windows' `WiaScannerInfo.Buttons`); nil or empty: none.
    func buttons(for deviceId: String) -> [String]?

    /// Hears the scanner's buttons: `pressed` is called (on any thread) each time one of `buttons` (`ScannerButtonNames`) is
    /// pressed on `deviceId`, until the watch is stopped. Only while this app runs: nothing is registered with macOS to start it.
    /// Throws `ScannerButtonsError` when the scanner can't be heard.
    func watchButtons(_ deviceId: String, _ buttons: [String], pressed: @escaping @Sendable () -> Void) async throws -> any ButtonWatch
}

/// The scanner's buttons can't be heard (gone, or its driver refused).
public struct ScannerButtonsError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) { self.description = description }
}

/// Nothing to stop: buttons that aren't heard.
public struct NoButtons: ButtonWatch {
    public init() {}
    public func stop() {}
}

/// The scan buttons a scanner's driver may report, by the names PrintCore uses for them. ImageCaptureCore names four kinds of
/// button press (`ICButtonTypeScan`, `ICButtonTypeCopy`, `ICButtonTypeMail`, `ICButtonTypeWeb`), each asking the computer to
/// scan for a purpose, as Windows hears WIA's scan events (Scan, Scan to print, e-mail and the like). Unlike WIA,
/// ImageCaptureCore doesn't list which buttons a scanner has, so the app offers them for every USB scanner it drives.
public enum ScannerButtonNames {
    public static let scanButtons = ["scan", "copy", "mail", "web"]

    /// The scan buttons among the names a driver reported (ImageCaptureCore's `ICButtonTypeScan`, or `scan`, in any case), in
    /// `scanButtons`' spelling and order; at most four.
    public static func scanButtonsIn(_ reported: [String]) -> [String] {
        let names = Set(reported.prefix(256).map(name))
        return scanButtons.filter(names.contains)
    }

    /// `ICButtonTypeScan` → `scan`.
    public static func name(_ reported: String) -> String {
        var s = reported.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("icbuttontype") { s.removeFirst("icbuttontype".count) }
        return s
    }
}

/// Made-up scanners whose buttons can be pressed (the tests and the demo; Windows' `FakeWiaSystem` with `FakeWiaScanner.Press`).
public final class FakeScannerButtons: ScannerButtons {
    public final class Scanner: Sendable {
        public let id: String
        /// The scan buttons its driver reports; nil or empty: none.
        public let buttons: [String]?
        private let listeners = Mutex<[(id: Int, buttons: [String], pressed: @Sendable () -> Void)]>([])
        private let next = Mutex(0)

        public init(id: String, buttons: [String]?) {
            self.id = id
            self.buttons = buttons
        }

        /// Apps hearing this scanner's buttons now.
        public var listenerCount: Int { listeners.withLock { $0.count } }

        /// Its button: the driver reports `button` (Scan, by default) to those hearing it, when its `buttons` list it.
        public func press(_ button: String = "scan") {
            guard buttons?.contains(where: { $0.caseInsensitiveCompare(button) == .orderedSame }) == true else { return }
            let heard = listeners.withLock { l in l.filter { $0.buttons.contains { $0.caseInsensitiveCompare(button) == .orderedSame } }.map(\.pressed) }
            for pressed in heard { pressed() }
        }

        func listen(_ buttons: [String], _ pressed: @escaping @Sendable () -> Void) -> any ButtonWatch {
            let id = next.withLock { n in
                n += 1
                return n
            }
            listeners.withLock { $0.append((id, buttons, pressed)) }
            return Stop { [weak self] in self?.listeners.withLock { $0.removeAll { $0.id == id } } }
        }
    }

    private final class Stop: ButtonWatch {
        let action: @Sendable () -> Void
        private let done = Mutex(false)

        init(_ action: @escaping @Sendable () -> Void) { self.action = action }

        func stop() {
            if done.withLock({ d in defer { d = true }; return !d }) { action() }
        }
    }

    public let scanners: [Scanner]

    public init(_ scanners: [Scanner]) { self.scanners = scanners }

    public func buttons(for deviceId: String) -> [String]? { scanners.first { $0.id == deviceId }?.buttons }

    public func watchButtons(_ deviceId: String, _ buttons: [String], pressed: @escaping @Sendable () -> Void) async throws -> any ButtonWatch {
        guard let scanner = scanners.first(where: { $0.id == deviceId }) else { throw ScannerButtonsError("No such scanner.") }
        return scanner.listen(buttons, pressed)
    }
}

/// Who gets what a piece of work makes when its caller may stop waiting (a time limit; Windows' `WorkClaim`): the caller while
/// it waits; once it has given up (`abandon`), nobody, and the thing is undone there and then by the work that made it. Used
/// for an ImageCaptureCore session opened for a scanner's buttons, which must never be left running unowned (it would start
/// scans nobody asked for).
public final class WorkClaim<T: Sendable>: Sendable {
    private let undo: @Sendable (T) -> Void
    private let state = Mutex<(abandoned: Bool, delivered: T?)>((false, nil))

    public init(_ undo: @escaping @Sendable (T) -> Void) { self.undo = undo }

    /// By the work, with what it made: handed to the caller, or (given up on meanwhile) undone at once and nil.
    public func deliver(_ made: T) -> T? {
        let kept = state.withLock { s -> Bool in
            guard !s.abandoned else { return false }
            s.delivered = made
            return true
        }
        if kept { return made }
        undo(made)
        return nil
    }

    /// The caller gives up. What was delivered just before (the caller then undoes it), or nil: nothing yet, and nothing kept
    /// later.
    public func abandon() -> T? {
        state.withLock { s in
            s.abandoned = true
            return s.delivered
        }
    }
}
