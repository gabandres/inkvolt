import Foundation

extension SystemScanner {
    /// A network scanner macOS reaches through Apple's own AirScan (eSCL) driver: it's on the network already, so it isn't
    /// shared again (the Windows Core's `WiaDeviceInfo.IsEscl`).
    public var isEscl: Bool { !usb && !makerDriver }
}

/// A scanner macOS lists, as the app holds it while it's listed: what it is, what it offers (read once, then kept), and
/// whether a scan runs on it now (the Windows Core's `WiaScanner`). One scan at a time, whoever asks (the Scan tab, or a
/// device on the network through the shared scanner): a second one while the first runs ends at once with the scanner's
/// busy error, and the first goes on. The app keeps one per scanner, so both ask the same one.
public final class ConnectedScanner: ScanDevice, @unchecked Sendable {
    public let scanner: SystemScanner
    private let device: any ScanDevice
    private let busy = Shared(false)
    private let read: Shared<ScannerCapabilities?>

    /// `capabilities`: what it offers when already known (tests, demo mode); read from `device` on first use otherwise.
    public init(_ scanner: SystemScanner, device: any ScanDevice, capabilities: ScannerCapabilities? = nil) {
        self.scanner = scanner
        self.device = device
        read = Shared(capabilities)
    }

    /// A scan runs on it now.
    public var isBusy: Bool { busy.withLock { $0 } }

    /// The maker, when the driver said (ScannerCapabilities' `scan:Manufacturer`).
    public var manufacturer: String? { read.withLock { $0?.manufacturer } }

    public func capabilities() async throws -> ScannerCapabilities? {
        if let known = read.withLock({ $0 }) { return known }
        let caps = try await device.capabilities()
        if let caps { read.withLock { $0 = caps } }
        return caps
    }

    public func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error> {
        AsyncThrowingStream { continuation in
            let taken = busy.withLock { b -> Bool in
                if b { return false }
                b = true
                return true
            }
            guard taken else {
                continuation.finish(throwing: ScanError(loc("Someone else is using the scanner. Try again in a moment.")))
                return
            }
            let device = self.device, busy = self.busy
            let task = Task {
                var failure: (any Error)?
                do {
                    for try await page in device.scan(request) {
                        if Task.isCancelled { break }
                        continuation.yield(page)
                    }
                    if Task.isCancelled { failure = CancellationError() }
                } catch {
                    failure = error
                }
                // Free before the reader hears the end: whoever waited on it may scan at once.
                busy.withLock { $0 = false }
                if let failure { continuation.finish(throwing: failure) } else { continuation.finish() }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
