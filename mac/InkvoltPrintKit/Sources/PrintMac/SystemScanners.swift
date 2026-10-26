import AppKit
import Foundation
import ImageCaptureCore
import PrintCore
import UniformTypeIdentifiers

/// macOS's scanners through ImageCaptureCore (the Windows app's WIA list): USB scanners with a driver, and network ones
/// (which a network printer here scans over eSCL instead). ICC's list flaps while the app browses Bonjour (the probe saw a
/// network scanner added and removed every second), so `onChange` gets it only once it has held still for `settle`.
/// USB needs `com.apple.security.device.usb`. Main thread, as ICC calls its delegates there.
@MainActor
// ICC calls its delegates on the main thread: the conformances are main-actor ones, checked at run time.
public final class SystemScanners: NSObject, @preconcurrency ICDeviceBrowserDelegate {
    public static let settle: Duration = .seconds(2)

    private let browser = ICDeviceBrowser()
    private var devices: [String: ICScannerDevice] = [:]
    private var pending: Task<Void, Never>?
    private let onChange: @MainActor ([SystemScanner]) -> Void

    /// `network`: network scanners too (checks only; the app scans those over eSCL).
    public init(network: Bool = false, onChange: @escaping @MainActor ([SystemScanner]) -> Void) {
        self.onChange = onChange
        super.init()
        browser.delegate = self
        var mask = ICDeviceTypeMask.scanner.rawValue | ICDeviceLocationTypeMask.local.rawValue
        if network { mask |= ICDeviceLocationTypeMask.bonjour.rawValue }
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: mask) ?? .scanner
    }

    public func start() { browser.start() }

    /// Every scanner ICC lists, network ones too (for checks: the app scans those over eSCL).
    public var allDevices: [(scanner: SystemScanner, device: SystemScanDevice)] {
        devices.map { id, d in (SystemScanner(id: id, name: d.name ?? "Scanner", usb: d.transportType?.contains("USB") == true), SystemScanDevice(d)) }
    }

    public func stop() { browser.stop() }

    /// The scanner to scan with (a session is opened when it's first used).
    public func device(_ id: String) -> SystemScanDevice? { devices[id].map(SystemScanDevice.init) }

    public var list: [SystemScanner] {
        devices.map { id, d in SystemScanner(id: id, name: d.name ?? "Scanner", usb: d.transportType?.contains("USB") == true) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let scanner = device as? ICScannerDevice, let id = scanner.persistentIDString ?? scanner.name else { return }
        devices[id] = scanner
        changed()
    }

    public func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {
        guard let id = device.persistentIDString ?? device.name else { return }
        devices[id] = nil
        changed()
    }

    public func didRemove(_ device: ICDevice) {}

    private func changed() {
        pending?.cancel()
        pending = Task {
            guard (try? await Task.sleep(for: Self.settle)) != nil else { return }
            onChange(list)
        }
    }
}

/// One ImageCaptureCore scanner as the Scan tab drives it: its flatbed and feeder described as eSCL describes a scanner,
/// and a scan that yields each page as JPEG. A session is opened on first use and kept.
@MainActor
public final class SystemScanDevice: NSObject, ScanDevice, @preconcurrency ICScannerDeviceDelegate {
    private let scanner: ICScannerDevice
    private var opened: CheckedContinuation<Void, any Error>?
    private var selected: CheckedContinuation<Void, any Error>?
    private var pages: AsyncThrowingStream<[UInt8], any Error>.Continuation?

    init(_ scanner: ICScannerDevice) {
        self.scanner = scanner
        super.init()
        scanner.delegate = self
    }

    // MARK: ScanDevice

    public func capabilities() async throws -> ScannerCapabilities? {
        try await open()
        // The units come once the scanner says it's available, a moment after the session opens.
        for _ in 0..<50 where scanner.availableFunctionalUnitTypes.isEmpty { try await Task.sleep(for: .milliseconds(100)) }
        let types = scanner.availableFunctionalUnitTypes.compactMap { ICScannerFunctionalUnitType(rawValue: $0.uintValue) }
        if types.isEmpty { throw ScanError("The scanner offers no glass or feeder.") }
        var platen: InputCaps?, adf: InputCaps?, duplex = false
        for type in types where type == .flatbed || type == .documentFeeder {
            try await select(type)
            let unit = scanner.selectedFunctionalUnit
            let caps = Self.caps(unit)
            if type == .flatbed { platen = caps } else {
                adf = caps
                duplex = (unit as? ICScannerFunctionalUnitDocumentFeeder)?.supportsDuplexScanning ?? false
            }
        }
        return ScannerCapabilities(makeAndModel: scanner.name, platen: platen, adf: adf, adfDuplex: duplex)
    }

    nonisolated public func scan(_ request: ScanRequest) -> AsyncThrowingStream<[UInt8], any Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    try await self.run(request, continuation)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
                Task { @MainActor in self.scanner.cancelScan() }
            }
        }
    }

    private func run(_ request: ScanRequest, _ continuation: AsyncThrowingStream<[UInt8], any Error>.Continuation) async throws {
        try await open()
        try await select(request.source == .platen ? .flatbed : .documentFeeder)
        let unit = scanner.selectedFunctionalUnit
        unit.measurementUnit = .inches
        let resolutions = Array(unit.supportedResolutions)
        unit.resolution = resolutions.min { abs($0 - request.resolution) < abs($1 - request.resolution) } ?? request.resolution
        unit.pixelDataType = request.color == .color ? .RGB : .gray
        unit.bitDepth = .depth8Bits
        let size = unit.physicalSize
        var width = CGFloat(size.width), height = CGFloat(size.height)
        if let w = request.width { width = min(CGFloat(w) / 300, width) }
        if let h = request.height { height = min(CGFloat(h) / 300, height) }
        unit.scanArea = NSRect(x: 0, y: 0, width: width, height: height)
        if let feeder = unit as? ICScannerFunctionalUnitDocumentFeeder {
            feeder.documentType = .typeDefault
            if feeder.supportsDuplexScanning { feeder.duplexScanningEnabled = request.source == .adfDuplex }
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("system-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        scanner.transferMode = .fileBased
        scanner.downloadsDirectory = folder
        scanner.documentName = "page"
        scanner.documentUTI = UTType.jpeg.identifier
        pages = continuation
        scanner.requestScan()
    }

    // MARK: Session

    private var isOpen = false

    private func open() async throws {
        if isOpen { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            opened = c
            scanner.requestOpenSession()
        }
        isOpen = true
    }

    private func select(_ type: ICScannerFunctionalUnitType) async throws {
        if scanner.selectedFunctionalUnit.type == type { return }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            selected = c
            scanner.requestSelect(type)
        }
    }

    /// A unit as eSCL would describe it: sizes in 1/300 inch, its resolutions, colour and grey.
    static func caps(_ unit: ICScannerFunctionalUnit) -> InputCaps {
        unit.measurementUnit = .inches
        let size = unit.physicalSize
        let w = Int((size.width * 300).rounded()), h = Int((size.height * 300).rounded())
        return InputCaps(minWidth: 300, maxWidth: max(w, 300), minHeight: 300, maxHeight: max(h, 300), colorModes: ["RGB24", "Grayscale8"],
                         resolutions: Array(unit.supportedResolutions))
    }

    // MARK: ICScannerDeviceDelegate

    public func device(_ device: ICDevice, didOpenSessionWithError error: (any Error)?) {
        if let error { opened?.resume(throwing: error) } else { opened?.resume() }
        opened = nil
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didSelect functionalUnit: ICScannerFunctionalUnit, error: (any Error)?) {
        if let error { selected?.resume(throwing: error) } else { selected?.resume() }
        selected = nil
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didScanTo url: URL) {
        if let data = try? Data(contentsOf: url) { pages?.yield([UInt8](data)) }
        try? FileManager.default.removeItem(at: url)
    }

    public func scannerDevice(_ scanner: ICScannerDevice, didCompleteScanWithError error: (any Error)?) {
        if let error { pages?.finish(throwing: ScanError(Self.words(error))) } else { pages?.finish() }
        pages = nil
    }

    public func device(_ device: ICDevice, didCloseSessionWithError error: (any Error)?) { isOpen = false }

    public func didRemove(_ device: ICDevice) {
        isOpen = false
        pages?.finish(throwing: ScanError("The scanner was disconnected."))
        pages = nil
    }

    /// The scanner's error in plain words.
    nonisolated static func words(_ error: any Error) -> String {
        // ImageCaptureCore's codes (ICReturnCode); it has none for an empty feeder or a jam: those come in the description.
        switch (error as NSError).code {
        case -9925, -9926: return "Someone else is using the scanner. Try again in a moment."
        case -9923, -9927, -9958: return "The scanner didn't answer. Check that it's on and connected."
        case -9924: return "The scan was stopped."
        default: return "The scanner stopped: \((error as NSError).localizedDescription)"
        }
    }
}
