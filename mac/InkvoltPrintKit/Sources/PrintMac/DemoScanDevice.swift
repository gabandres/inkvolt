import Foundation
import PrintCore

/// Demo mode's scanners macOS would have drivers for (the Windows app's made-up WIA scanners): the USB laser's scanner part
/// (glass and feeder) and a photo flatbed that belongs to no printer. Pages are `DemoScanPage`'s; nothing is asked.
public struct DemoScanDevice: ScanDevice {
    public static let laserScanner = SystemScanner(id: "demo-usb-laser-scanner", name: "Demo Laser 2100", usb: true)
    public static let flatbed = SystemScanner(id: "demo-photo-scanner", name: "Demo Photo Scanner 40", usb: true)
    public static let all = [laserScanner, flatbed]

    private let feeder: Bool

    public init(_ scanner: SystemScanner) { feeder = scanner.id == Self.laserScanner.id }

    public func capabilities() async throws -> ScannerCapabilities? {
        let glass = InputCaps(minWidth: 300, maxWidth: 2550, minHeight: 300, maxHeight: feeder ? 3508 : 3500, colorModes: ["RGB24", "Grayscale8"],
                              resolutions: [100, 150, 200, 300, 600])
        let adf = feeder ? InputCaps(minWidth: 300, maxWidth: 2550, minHeight: 300, maxHeight: 4200, colorModes: ["RGB24", "Grayscale8"],
                                     resolutions: [150, 200, 300]) : nil
        return ScannerCapabilities(makeAndModel: feeder ? Self.laserScanner.name : Self.flatbed.name, platen: glass, adf: adf, adfDuplex: false)
    }

    public func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let pages = request.source == .platen ? [0] : [0, 1, 2]
                for page in pages {
                    try? await Task.sleep(for: .milliseconds(600))
                    if Task.isCancelled { break }
                    continuation.yield(DemoScanPage.jpeg(page, width: request.width ?? 2550, height: request.height ?? 3300))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
